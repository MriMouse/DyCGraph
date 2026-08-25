#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <iostream>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <cuda_runtime.h>
#include <framework/affected_component_trace.h>
#include <framework/f1_replay_state.h>

namespace {

using Clock = std::chrono::steady_clock;
using State = sepgraph::f1_replay::StateRecord;
constexpr uint32_t kInfinity = std::numeric_limits<uint32_t>::max();

double Ms(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

void Check(cudaError_t status, const char *what) {
    if (status != cudaSuccess) throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(status));
}

struct Dsu {
    explicit Dsu(size_t n) : p(n), size(n, 1) { for (size_t i = 0; i < n; ++i) p[i] = i; }
    size_t Find(size_t x) { while (p[x] != x) { p[x] = p[p[x]]; x = p[x]; } return x; }
    void Join(size_t a, size_t b) { a = Find(a); b = Find(b); if (a == b) return; if (size[a] < size[b]) std::swap(a,b); p[b] = a; size[a] += size[b]; }
    std::vector<size_t> p, size;
};

struct Candidate {
    std::vector<uint8_t> owned;
    uint64_t vertices = 0, service = 0;
};

Candidate ChooseIndependentComponent(const sepgraph::affected_component::Batch &batch,
                                     const std::unordered_map<index_t, uint32_t> &affected) {
    const size_t n = batch.affected_vertices.size();
    Dsu dsu(n);
    for (size_t dst = 0; dst < n; ++dst)
        for (uint64_t e = batch.incoming_offsets[dst]; e < batch.incoming_offsets[dst + 1]; ++e) {
            const auto it = affected.find(batch.incoming_sources[e]);
            if (it != affected.end()) dsu.Join(dst, it->second);
        }
    std::vector<uint64_t> service(n), vertices(n);
    for (size_t i = 0; i < n; ++i) {
        const size_t r = dsu.Find(i);
        ++vertices[r];
        // A service unit is incoming reduce + commit + non-sink expansion.
        service[r] += (batch.incoming_offsets[i + 1] - batch.incoming_offsets[i]) + 1 +
                      (batch.affected_out_degrees[i] == 0 ? 0 : batch.affected_out_degrees[i]);
    }
    size_t best = n;
    for (size_t i = 0; i < n; ++i) if (vertices[i] &&
        (best == n || service[i] > service[best])) best = i;
    Candidate result; result.owned.assign(n, 0);
    if (best == n) return result;
    for (size_t i = 0; i < n; ++i) if (dsu.Find(i) == best) result.owned[i] = 1;
    result.vertices = vertices[best]; result.service = service[best];
    return result;
}

void PullClosure(const std::vector<uint64_t> &offsets, const std::vector<uint32_t> &sources,
                 const std::vector<index_t> &vertices, const std::vector<uint8_t> &owned,
                 std::vector<State> &state) {
    bool changed;
    do {
        changed = false;
        for (size_t dst_i = 0; dst_i < vertices.size(); ++dst_i) {
            if (!owned[dst_i]) continue;
            const uint32_t dst_state = vertices[dst_i];
            uint32_t best = state[dst_state].value;
            index_t parent = state[dst_state].parent;
            for (uint64_t edge = offsets[dst_i]; edge < offsets[dst_i + 1]; ++edge) {
                const State &src = state[sources[edge]];
                if (src.value == kInfinity) continue;
                const uint64_t value = static_cast<uint64_t>(src.value) +
                                       (src.vertex + state[dst_state].vertex) % 128 + 1;
                if (value < best) { best = static_cast<uint32_t>(value); parent = src.vertex; }
            }
            if (best < state[dst_state].value) {
                state[dst_state].value = best; state[dst_state].parent = parent; changed = true;
            }
        }
    } while (changed);
}

class PersistentCpuWorker {
public:
    PersistentCpuWorker() : worker([this] { Loop(); }) {}
    ~PersistentCpuWorker() { { std::lock_guard<std::mutex> lock(mutex); stop = true; ready = true; } wake.notify_one(); worker.join(); }
    void Start(const std::vector<uint64_t> &offsets, const std::vector<uint32_t> &sources,
               const std::vector<index_t> &vertices, const std::vector<uint8_t> &owned,
               std::vector<State> &state) {
        std::lock_guard<std::mutex> lock(mutex); this->offsets=&offsets; this->sources=&sources;
        this->vertices=&vertices; this->owned=&owned; this->state=&state; done=false; ready=true; wake.notify_one();
    }
    double Wait() { std::unique_lock<std::mutex> lock(mutex); complete.wait(lock,[this]{return done;}); return elapsed; }
private:
    void Loop() { for (;;) { std::unique_lock<std::mutex> lock(mutex); wake.wait(lock,[this]{return ready;}); if(stop) return; ready=false; const auto begin=Clock::now(); auto *o=offsets; auto *s=sources; auto *v=vertices; auto *own=owned; auto *st=state; lock.unlock(); PullClosure(*o,*s,*v,*own,*st); const double ms=Ms(begin); lock.lock(); elapsed=ms; done=true; complete.notify_one(); } }
    std::thread worker; std::mutex mutex; std::condition_variable wake, complete; bool ready=false, done=false, stop=false;
    const std::vector<uint64_t> *offsets=nullptr; const std::vector<uint32_t> *sources=nullptr; const std::vector<index_t> *vertices=nullptr; const std::vector<uint8_t> *owned=nullptr; std::vector<State> *state=nullptr; double elapsed=0;
};

__global__ void GpuPull(const uint64_t *offsets, const uint32_t *sources, const uint32_t *vertices,
                        const uint8_t *cpu_owned, uint32_t count, uint32_t *values,
                        index_t *parents, const index_t *ids, uint32_t *changed) {
    const uint32_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count || cpu_owned[i]) return;
    const uint32_t dst = vertices[i]; uint32_t best = values[dst]; index_t parent = parents[dst];
    for (uint64_t e = offsets[i]; e < offsets[i + 1]; ++e) {
        const uint32_t src = sources[e]; const uint32_t v = values[src];
        if (v == kInfinity) continue;
        const uint64_t candidate = static_cast<uint64_t>(v) + (ids[src] + ids[dst]) % 128 + 1;
        if (candidate < best) { best = static_cast<uint32_t>(candidate); parent = ids[src]; }
    }
    if (best < values[dst]) { values[dst] = best; parents[dst] = parent; atomicExch(changed, 1u); }
}

struct GpuClosure {
    double Run(const std::vector<uint64_t> &offsets, const std::vector<uint32_t> &sources,
               const std::vector<uint32_t> &vertices, const std::vector<uint8_t> &owned,
               const std::vector<State> &input, std::vector<State> &output) {
        uint64_t *d_offsets; uint32_t *d_sources, *d_vertices, *d_values, *d_changed; uint8_t *d_owned;
        index_t *d_ids, *d_parents; const size_t n = input.size(), m = sources.size(), a = vertices.size();
        Check(cudaMalloc(&d_offsets, sizeof(uint64_t) * offsets.size()), "cudaMalloc offsets");
        Check(cudaMalloc(&d_sources, sizeof(uint32_t) * std::max<size_t>(1,m)), "cudaMalloc sources");
        Check(cudaMalloc(&d_vertices, sizeof(uint32_t) * std::max<size_t>(1,a)), "cudaMalloc vertices");
        Check(cudaMalloc(&d_owned, sizeof(uint8_t) * std::max<size_t>(1,a)), "cudaMalloc owners");
        Check(cudaMalloc(&d_values, sizeof(uint32_t) * n), "cudaMalloc values");
        Check(cudaMalloc(&d_parents, sizeof(index_t) * n), "cudaMalloc parents");
        Check(cudaMalloc(&d_ids, sizeof(index_t) * n), "cudaMalloc ids"); Check(cudaMalloc(&d_changed, sizeof(uint32_t)), "cudaMalloc changed");
        std::vector<uint32_t> values(n); std::vector<index_t> parents(n), ids(n);
        for (size_t i=0;i<n;++i) { values[i]=input[i].value; parents[i]=input[i].parent; ids[i]=input[i].vertex; }
        Check(cudaMemcpy(d_offsets, offsets.data(), sizeof(uint64_t)*offsets.size(), cudaMemcpyHostToDevice), "copy offsets");
        if (m) Check(cudaMemcpy(d_sources, sources.data(), sizeof(uint32_t)*m, cudaMemcpyHostToDevice), "copy sources");
        if (a) { Check(cudaMemcpy(d_vertices, vertices.data(), sizeof(uint32_t)*a, cudaMemcpyHostToDevice), "copy vertices"); Check(cudaMemcpy(d_owned, owned.data(), sizeof(uint8_t)*a, cudaMemcpyHostToDevice), "copy owners"); }
        Check(cudaMemcpy(d_values, values.data(), sizeof(uint32_t)*n, cudaMemcpyHostToDevice), "copy values"); Check(cudaMemcpy(d_parents, parents.data(), sizeof(index_t)*n, cudaMemcpyHostToDevice), "copy parents"); Check(cudaMemcpy(d_ids, ids.data(), sizeof(index_t)*n, cudaMemcpyHostToDevice), "copy ids");
        const auto begin=Clock::now(); uint32_t changed;
        do { changed=0; Check(cudaMemcpy(d_changed,&changed,sizeof(changed),cudaMemcpyHostToDevice),"reset changed"); GpuPull<<<(a+255)/256,256>>>(d_offsets,d_sources,d_vertices,d_owned,a,d_values,d_parents,d_ids,d_changed); Check(cudaGetLastError(),"GpuPull"); Check(cudaMemcpy(&changed,d_changed,sizeof(changed),cudaMemcpyDeviceToHost),"read changed"); } while(changed);
        const double elapsed=Ms(begin); Check(cudaMemcpy(values.data(),d_values,sizeof(uint32_t)*n,cudaMemcpyDeviceToHost),"read values"); Check(cudaMemcpy(parents.data(),d_parents,sizeof(index_t)*n,cudaMemcpyDeviceToHost),"read parents");
        output=input; for(size_t i=0;i<n;++i){output[i].value=values[i];output[i].parent=parents[i];}
        cudaFree(d_offsets); cudaFree(d_sources); cudaFree(d_vertices); cudaFree(d_owned); cudaFree(d_values); cudaFree(d_parents); cudaFree(d_ids); cudaFree(d_changed); return elapsed;
    }
};

int Main(int argc, char **argv) {
    if (argc != 3) throw std::runtime_error("usage: f1_crossover_replay COMPONENTS.bin STATES.bin");
    const auto components=sepgraph::affected_component::ReadTrace(argv[1]); const auto states=sepgraph::f1_replay::ReadTrace(argv[2]);
    if (components.size()!=states.size()) throw std::runtime_error("component/state batch count mismatch");
    GpuClosure gpu; PersistentCpuWorker cpu_worker; uint64_t value_mismatches=0, parent_ties=0;
    for(size_t b=0;b<components.size();++b) {
        const auto &trace=components[b]; const auto &capture=states[b];
        if(trace.batch!=capture.batch || trace.affected_vertices.size()!=capture.final_affected_states.size()) throw std::runtime_error("unaligned batch capture");
        const auto snapshot_begin=Clock::now();
        std::unordered_map<index_t,uint32_t> state_index; state_index.reserve(capture.input_states.size());
        for(uint32_t i=0;i<capture.input_states.size();++i) state_index.emplace(capture.input_states[i].vertex,i);
        std::unordered_map<index_t,uint32_t> affected; affected.reserve(trace.affected_vertices.size());
        std::vector<uint32_t> vertices(trace.affected_vertices.size()), sources; sources.reserve(trace.incoming_sources.size());
        for(uint32_t i=0;i<trace.affected_vertices.size();++i) { auto it=state_index.find(trace.affected_vertices[i]); if(it==state_index.end()) throw std::runtime_error("missing affected input state"); vertices[i]=it->second; affected.emplace(trace.affected_vertices[i],i); }
        for(index_t source:trace.incoming_sources) { auto it=state_index.find(source); if(it==state_index.end()) throw std::runtime_error("missing incoming input state"); sources.push_back(it->second); }
        const Candidate candidate=ChooseIndependentComponent(trace,affected); std::vector<State> cpu=capture.input_states,gpu_state;
        const double snapshot_ms=Ms(snapshot_begin);
        cpu_worker.Start(trace.incoming_offsets,sources,vertices,candidate.owned,cpu);
        const double gpu_ms=gpu.Run(trace.incoming_offsets,sources,vertices,candidate.owned,capture.input_states,gpu_state); const double cpu_ms=cpu_worker.Wait();
        const auto fence=Clock::now(); std::unordered_map<index_t,State> final;
        for(size_t i=0;i<trace.affected_vertices.size();++i) final.emplace(trace.affected_vertices[i],candidate.owned[i]?cpu[vertices[i]]:gpu_state[vertices[i]]);
        uint64_t batch_value_mismatches=0, batch_parent_ties=0; for(const State &expected:capture.final_affected_states) { const State actual=final.at(expected.vertex); if(actual.value!=expected.value) { if (batch_value_mismatches == 0) std::cout << "[F1-CROSSOVER-VALUE-MISMATCH] batch=" << trace.batch << " vertex=" << expected.vertex << " expected_value=" << expected.value << " actual_value=" << actual.value << "\n"; ++batch_value_mismatches; } else if(actual.parent!=expected.parent) ++batch_parent_ties; }
        value_mismatches+=batch_value_mismatches; parent_ties+=batch_parent_ties; const double fence_ms=Ms(fence); const double window=snapshot_ms+std::max(cpu_ms,gpu_ms)+fence_ms;
        std::cout<<"[F1-CROSSOVER] batch="<<trace.batch<<" candidate_vertices="<<candidate.vertices<<" candidate_service="<<candidate.service<<" successor_cut=0 snapshot_ms="<<snapshot_ms<<" cpu_service_ms="<<cpu_ms<<" gpu_independent_ms="<<gpu_ms<<" final_fence_ms="<<fence_ms<<" independent_window_ms="<<window<<" value_mismatches="<<batch_value_mismatches<<" parent_ties="<<batch_parent_ties<<"\n";
    }
    std::cout<<"[F1-CROSSOVER] overall_value_mismatches="<<value_mismatches<<" overall_parent_ties="<<parent_ties<<" batches="<<components.size()<<"\n"; return value_mismatches?2:0;
}
}
int main(int argc,char **argv) { try { return Main(argc,argv); } catch(const std::exception &e) { std::cerr<<"f1_crossover_replay: "<<e.what()<<"\n"; return 1; } }
