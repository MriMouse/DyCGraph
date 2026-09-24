// Exactness of sampled connectivity with deliberately stale cached rows.
#include <cuda_runtime.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <algorithm>
#include <numeric>
#include <random>
#include <vector>
#include <framework/cc_union_repair.cuh>
#define CUDA(call) do { auto e = (call); if (e != cudaSuccess) { \
    std::fprintf(stderr, "%s:%d %s\n", __FILE__, __LINE__, cudaGetErrorString(e)); std::exit(1); } } while (0)
template<class T> T *copy(const std::vector<T> &h) {
    T *p; CUDA(cudaMalloc(&p, std::max(size_t(1), h.size()) * sizeof(T)));
    if (!h.empty()) CUDA(cudaMemcpy(p, h.data(), h.size()*sizeof(T), cudaMemcpyHostToDevice));
    return p;
}
struct Vertex { bool cache; unsigned virtual_degree, virtual_start; };
struct Graph {
    unsigned *offsets, *edges;
    Vertex *vertices_;
    __device__ unsigned begin_edge(unsigned u) const { return offsets[u]; }
    __device__ unsigned end_edge(unsigned u) const { return offsets[u+1]; }
    __device__ unsigned edge_dest(unsigned e) const { return edges[e]; }
};
void run(std::vector<std::vector<unsigned>> rows, unsigned seed, bool shuffle = true) {
    const unsigned n = rows.size();
    std::vector<unsigned> offsets(1,0), edges, cache, ids(n), witness(n,UINT32_MAX), expected(n);
    std::vector<Vertex> vertices;
    std::iota(ids.begin(),ids.end(),0); expected=ids;
    auto root = [&](unsigned v) { while (expected[v]!=v) v=expected[v]; return v; };
    for (unsigned u=0;u<n;++u) for (auto v: rows[u]) {
        unsigned a=root(u),b=root(v); expected[std::max(a,b)]=std::min(a,b);
    }
    std::mt19937 rng(seed);
    for (unsigned u=0;u<n;++u) {
        if (shuffle) std::shuffle(rows[u].begin(),rows[u].end(),rng);
        vertices.push_back({true,unsigned(rows[u].size()),unsigned(cache.size())});
        if (u%5==0) vertices.back().virtual_degree /= 2;
        if (u%7==0) vertices.back().cache = false;
        edges.insert(edges.end(),rows[u].begin(),rows[u].end());
        cache.insert(cache.end(),rows[u].begin(),rows[u].end());
        // Changed rows contain poisoned stale neighbors in cache. They MUST use chunks.
        if (u%3==0) {
            witness[u]=0;
            for (size_t j=offsets.back();j<cache.size();++j) cache[j]=(u+n/2)%n;
        }
        offsets.push_back(edges.size());
    }
    auto d_ids=copy(ids), parents=copy(ids), buffers=copy(ids), d_witness=copy(witness), d_cache=copy(cache);
    auto selected=copy(std::vector<unsigned>(2));
    bool *reset; CUDA(cudaMalloc(&reset,n)); CUDA(cudaMemset(reset,1,n));
    Graph graph{copy(offsets),copy(edges),copy(vertices)};
    using namespace sepgraph::cc_repair;
    Sample<<<32,256>>>(graph,d_ids,n,parents,d_witness,d_cache);
    Snapshot<<<32,256>>>(d_ids,n,parents,buffers);
    SelectComponent<<<1,256>>>(d_ids,n,buffers,selected);
    Hook<true><<<32,256>>>(graph,d_ids,n,parents,d_witness,d_cache,buffers,selected);
    Flatten<<<32,256>>>(d_ids,n,parents,buffers,reset,d_witness);
    CUDA(cudaGetLastError()); CUDA(cudaDeviceSynchronize());
    std::vector<unsigned> actual(n); CUDA(cudaMemcpy(actual.data(),parents,n*4,cudaMemcpyDeviceToHost));
    for (unsigned u=0;u<n;++u) if (actual[u]!=root(u)) {
        std::fprintf(stderr,"seed=%u vertex=%u got=%u expected=%u\n",seed,u,actual[u],root(u)); std::exit(1);
    }
    CUDA(cudaMemcpy(actual.data(),buffers,n*4,cudaMemcpyDeviceToHost));
    for (unsigned u=0;u<n;++u) if(actual[u]!=root(u)) std::exit(2);
    void *allocations[] = {d_ids,parents,buffers,d_witness,d_cache,selected,
                           reset,graph.offsets,graph.edges,graph.vertices_};
    for (void *p: allocations) CUDA(cudaFree(p));
}
int main() {
    // Both endpoints have at least two earlier internal neighbors, so the
    // only bridge survives to the finishing scan. Its skipped endpoint has
    // the smaller ID: retaining an unconditional u<v filter loses this edge.
    std::vector<std::vector<unsigned>> cut(64);
    for (unsigned base : {0U, 32U})
        for (unsigned u=base;u<base+30;++u)
            for (unsigned v=u+1;v<base+30;++v) {
                cut[u].push_back(v); cut[v].push_back(u);
            }
    cut[28].push_back(60); cut[60].push_back(28);
    run(cut, 100, false);
    for (unsigned seed=0;seed<100;++seed) {
        const unsigned n=seed<4 ? seed+1 : 1024;
        std::vector<std::vector<unsigned>> rows(n);
        auto edge=[&](unsigned u,unsigned v) {rows[u].push_back(v); rows[v].push_back(u);};
        std::mt19937 rng(seed);
        for(unsigned i=0;i<n*4;++i) {
            unsigned u=rng()%n,v=rng()%n;
            // Multiple large components, isolates, self-loops, parallel occurrences.
            if(u/128==v/128 && u%17 && v%17) edge(u,v);
        }
        if(n>512) {
            // Dense sampled component with a remaining cut edge in either ID orientation.
            for(unsigned u=0;u<100;++u) for(unsigned v=u+1;v<100;++v) edge(u,v);
            for(unsigned u=500;u<600;++u) for(unsigned v=u+1;v<600;++v) edge(u,v);
            edge(90,510); edge(510,511); edge(511,900);
        }
        run(rows,seed);
    }
    std::puts("CC sampled repair: 101 graphs match independent exact components");
}
