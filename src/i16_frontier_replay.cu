#include <framework/i16_repair_snapshot.h>
#include <nlohmann/json.hpp>
#include <cuda_runtime.h>
#include <chrono>
#include <iostream>
#include <sys/resource.h>

using Clock = std::chrono::steady_clock;
double Ms(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }
void Require(bool v,const char *m) { if (!v) throw std::runtime_error(m); }
void Check(cudaError_t e) { if (e!=cudaSuccess) throw std::runtime_error(cudaGetErrorString(e)); }
template<class T> struct Device {
    T *p=nullptr; size_t count;
    explicit Device(size_t n):count(n) { if (n) Check(cudaMalloc(&p,n*sizeof(T))); }
    ~Device() { if(p) cudaFree(p); }
    void Copy(const std::vector<T> &v) { Require(v.size()<=count,"Copy exceeds capacity"); if(!v.empty()) Check(cudaMemcpy(p,v.data(),v.size()*sizeof(T),cudaMemcpyHostToDevice)); }
};
struct Counters { unsigned long long edges,successes,duplicates; uint32_t count,overflow; };
__global__ void Expand(const uint32_t *frontier,uint32_t count,const uint64_t *offsets,
                       const uint32_t *outgoing,const uint32_t *ids,uint32_t *distance,
                       uint32_t *queued,uint32_t epoch,uint32_t *next,uint32_t capacity,Counters *stats) {
    for (uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;i<count;i+=blockDim.x*gridDim.x) {
        const auto u=frontier[i];
        const uint32_t value=atomicAdd(distance+u,0u);
        unsigned long long edges=0,success=0,duplicate=0;
        for (uint64_t e=offsets[u];e<offsets[u+1];++e) {
            ++edges; const auto v=outgoing[e];
            const uint64_t candidate=uint64_t(value)+((ids[u]+ids[v])%128+1);
            if (candidate>=UINT32_MAX) continue;
            if (candidate<atomicMin(distance+v,uint32_t(candidate))) {
                ++success;
                if (atomicExch(queued+v,epoch)!=epoch) {
                    const auto pos=atomicAdd(&stats->count,1u);
                    if(pos<capacity) next[pos]=v; else atomicExch(&stats->overflow,1u);
                } else ++duplicate;
            }
        }
        atomicAdd(&stats->edges,edges); atomicAdd(&stats->successes,success); atomicAdd(&stats->duplicates,duplicate);
    }
}

int main(int argc,char **argv) {
    try {
        Require(argc==3,"Usage: i16_frontier_replay SNAPSHOT REPORT.json");
        auto total=Clock::now(); const auto s=i16::Load(argv[1]); const double read_ms=Ms(total);
        auto service=Clock::now(); auto stage=Clock::now();
        Require(s.nodes && s.source<s.nodes && s.affected.size()<UINT32_MAX,"Invalid dimensions");
        const uint32_t n=s.affected.size();
        Require(s.offsets.size()==size_t(n)+1 && s.offsets.front()==0 && s.offsets.back()==s.incoming.size() &&
                std::is_sorted(s.offsets.begin(),s.offsets.end()),"Invalid incoming CSR");
        Require(s.before.size()==s.after.size(),"State count mismatch");
        std::vector<uint32_t> local(s.nodes,UINT32_MAX),values(s.nodes,UINT32_MAX),distance(n),parent(n,UINT32_MAX);
        std::vector<uint8_t> seen(s.nodes,0);
        for (uint32_t i=0;i<n;++i) { auto v=s.affected[i]; Require(v<s.nodes && local[v]==UINT32_MAX,"Invalid affected ID"); local[v]=i; }
        for (size_t i=0;i<s.before.size();++i) {
            const auto a=s.before[i],b=s.after[i];
            Require(a.vertex<s.nodes && !seen[a.vertex] && a.vertex==b.vertex,"Invalid state IDs");
            seen[a.vertex]=1; values[a.vertex]=a.value;
            if (local[a.vertex]==UINT32_MAX) Require(a.value==b.value && a.buffer==b.buffer && a.parent==b.parent,"Changed external state");
            else Require(b.buffer==b.value,"Invalid final buffer");
        }
        Require(seen[s.source] && values[s.source]==0,"Missing/invalid source state");
        std::vector<uint64_t> offsets(size_t(n)+1,0);
        uint64_t internal=0,boundary=0;
        for (uint32_t i=0;i<n;++i) {
            auto dst=s.affected[i]; Require(seen[dst],"Missing affected state"); distance[i]=values[dst];
            for (uint64_t e=s.offsets[i];e<s.offsets[i+1];++e) {
                const auto src=s.incoming[e]; Require(src<s.nodes && seen[src],"Missing incoming state");
                if(local[src]!=UINT32_MAX) { ++offsets[local[src]+1]; ++internal; }
                else {
                    ++boundary;
                    const uint64_t candidate=uint64_t(values[src])+i16::Weight(src,dst);
                    if(candidate<distance[i]) distance[i]=candidate;
                }
            }
        }
        for(uint32_t i=0;i<n;++i) offsets[i+1]+=offsets[i];
        auto cursor=offsets; std::vector<uint32_t> outgoing(internal),initial;
        for(uint32_t i=0;i<n;++i) {
            if(distance[i]!=UINT32_MAX) initial.push_back(i);
            for(uint64_t e=s.offsets[i];e<s.offsets[i+1];++e) {
                auto src=s.incoming[e]; if(local[src]!=UINT32_MAX) outgoing[cursor[local[src]]++]=i;
            }
        }
        const double setup_ms=Ms(stage); stage=Clock::now();
        Check(cudaSetDevice(0)); Check(cudaFree(nullptr));
        size_t free_before,total_device; Check(cudaMemGetInfo(&free_before,&total_device));
        Device<uint64_t> d_offsets(offsets.size()); Device<uint32_t> d_outgoing(internal),d_ids(n),d_distance(n),q1(n),q2(n),queued(n);
        Device<Counters> counters(1);
        size_t free_after; Check(cudaMemGetInfo(&free_after,&total_device));
        const double allocation_ms=Ms(stage); stage=Clock::now();
        d_offsets.Copy(offsets); d_outgoing.Copy(outgoing); d_ids.Copy(s.affected); d_distance.Copy(distance); q1.Copy(initial);
        if(n) Check(cudaMemset(queued.p,0,size_t(n)*4)); Check(cudaDeviceSynchronize());
        const double h2d_ms=Ms(stage); stage=Clock::now();
        uint32_t count=initial.size(),epoch=0; uint32_t *current=q1.p,*next=q2.p;
        uint64_t scans=0,successes=0,duplicates=0,enqueued=count,peak=count,processed=0;
        while(count) {
            Require(epoch<UINT32_MAX,"Queue epoch overflow"); ++epoch;
            processed+=count;
            Check(cudaMemset(counters.p,0,sizeof(Counters)));
            const uint32_t blocks=std::min<uint64_t>(65535,(uint64_t(count)+255)/256);
            Expand<<<blocks,256>>>(current,count,d_offsets.p,d_outgoing.p,d_ids.p,d_distance.p,queued.p,epoch,next,n,counters.p);
            Check(cudaGetLastError()); Counters stats{};
            Check(cudaMemcpy(&stats,counters.p,sizeof(stats),cudaMemcpyDeviceToHost));
            Require(!stats.overflow && stats.count<=n,"Frontier queue overflow");
            scans+=stats.edges; successes+=stats.successes; duplicates+=stats.duplicates;
            count=stats.count; enqueued+=count; peak=std::max<uint64_t>(peak,count); std::swap(current,next);
        }
        const double closure_ms=Ms(stage); stage=Clock::now();
        if(n) Check(cudaMemcpy(distance.data(),d_distance.p,size_t(n)*4,cudaMemcpyDeviceToHost));
        const double d2h_ms=Ms(stage); stage=Clock::now();
        // Reconstruct parents from converged distances; no distance/parent race.
        uint64_t missing_parent=0,parent_ties=0;
        for(uint32_t i=0;i<n;++i) {
            const auto dst=s.affected[i];
            if(dst==s.source) { Require(distance[i]==0,"Wrong source distance"); parent[i]=dst; continue; }
            if(distance[i]==UINT32_MAX) continue;
            uint64_t tight=0;
            for(uint64_t e=s.offsets[i];e<s.offsets[i+1];++e) {
                const auto src=s.incoming[e]; const auto value=local[src]==UINT32_MAX?values[src]:distance[local[src]];
                if(value!=UINT32_MAX && uint64_t(value)+i16::Weight(src,dst)==distance[i]) { parent[i]=std::min(parent[i],src); ++tight; }
            }
            missing_parent+=!tight; parent_ties+=tight>1;
        }
        const double parent_ms=Ms(stage),service_ms=Ms(service);
        uint64_t mismatches=0;
        for(const auto &state:s.after) if(local[state.vertex]!=UINT32_MAX) mismatches+=distance[local[state.vertex]]!=state.value;
        // Verify the selected parent against actual incoming edges independently.
        uint64_t invalid_parent=0;
        for(uint32_t i=0;i<n;++i) {
            const auto dst=s.affected[i]; if(dst==s.source || distance[i]==UINT32_MAX) continue;
            bool valid=false;
            for(uint64_t e=s.offsets[i];e<s.offsets[i+1];++e) if(s.incoming[e]==parent[i]) {
                const auto src=parent[i],value=local[src]==UINT32_MAX?values[src]:distance[local[src]];
                valid=value!=UINT32_MAX && uint64_t(value)+i16::Weight(src,dst)==distance[i];
            }
            invalid_parent+=!valid;
        }
        const uint64_t allocated=8*offsets.size()+4*internal+20*uint64_t(n)+sizeof(Counters);
        struct rusage usage{}; getrusage(RUSAGE_SELF,&usage);
        nlohmann::json report={{"state",(mismatches||invalid_parent)?"failed":"passed"},{"affected",n},{"incoming",s.incoming.size()},
            {"internal",internal},{"boundary",boundary},{"seed_vertices",initial.size()},{"iterations",epoch},
            {"internal_edge_scans",scans},{"successful_relaxations",successes},{"duplicate_enqueues_avoided",duplicates},
            {"enqueued_vertices",enqueued},{"processed_vertices",processed},{"queue_peak",peak},
            {"distance_mismatches",mismatches},{"missing_tight_parents",missing_parent},{"invalid_parents",invalid_parent},
            {"parent_tie_vertices",parent_ties},{"read_ms",read_ms},{"setup_ms",setup_ms},{"allocation_context_ms",allocation_ms},
            {"h2d_ms",h2d_ms},{"closure_ms",closure_ms},{"d2h_ms",d2h_ms},{"parent_reconstruction_ms",parent_ms},
            {"service_ms",service_ms},{"total_ms",Ms(total)},{"allocated_device_bytes",allocated},
            {"repair_only_device_bytes",allocated-8*uint64_t(n)},
            {"common_affected_ids_and_distances_bytes",8*uint64_t(n)},
            {"cuda_free_memory_delta_bytes",free_before>=free_after?free_before-free_after:0},{"peak_rss_kib",usage.ru_maxrss},
            {"parent_output_location","host; GPU scatter not included"},
            {"scope","offline instrumented prototype; excludes production snapshot acquisition and result scatter; not end-to-end speedup"}};
        std::ofstream output(argv[2]); output<<report.dump(2)<<'\n'; Require(bool(output),"Report write failed");
        std::cout<<report.dump()<<'\n'; return mismatches||invalid_parent?2:0;
    } catch(const std::exception &e) { std::cerr<<e.what()<<'\n'; return 1; }
}
