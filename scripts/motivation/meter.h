#pragma once
// Compiled out unless the isolated experiment build explicitly enables it.
#ifdef CG_MOTIVATION_METER
#include <cuda_runtime.h>
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <cstdlib>
#include <cstdint>
#include <limits>
#include <set>
#include <string>
#include <vector>
namespace cgmot {
inline const std::string &mode() {
    static const std::string value = std::getenv("CG_MOTIVATION_MODE") ? std::getenv("CG_MOTIVATION_MODE") : "off";
    return value;
}
inline bool counts() { return mode() == "counts"; }
inline bool timing() { return mode() == "timing"; }
inline void sync() { auto e = cudaDeviceSynchronize(); if (e != cudaSuccess) { std::fprintf(stderr,"motivation CUDA error: %s\n", cudaGetErrorString(e)); std::abort(); } }
inline double now() { return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
struct Location { uint64_t base, offset, degree; };
struct State {
    bool active = false, computing = false;
    unsigned batch = 0;
    uint64_t nnodes=0, updated=0, relocated=0, relocated_untouched=0, descriptor_bytes=0, affected=0, initial_wl=0, seeds_prebatch=0, seeds_preinsert=0;
    double compute_ms=0, rebuild_ms=0;
    uint64_t rebuild_groups=0;
    std::vector<Location> locations;
    std::vector<uint32_t> values;
    std::set<uint32_t> sources;
    std::vector<std::pair<uint32_t,uint32_t>> added;
};
inline State &state() { static State s; return s; }
inline void begin(unsigned batch, uint64_t n) { state() = State{}; auto &s=state(); s.active=counts()||timing(); s.batch=batch; s.nnodes=n; }
inline std::vector<uint32_t> read_values(const uint32_t *ptr, size_t n) {
    std::vector<uint32_t> values(n);
    auto e=cudaMemcpy(values.data(),ptr,n*sizeof(uint32_t),cudaMemcpyDeviceToHost);
    if(e!=cudaSuccess) { std::fprintf(stderr,"motivation CUDA error: %s\n",cudaGetErrorString(e)); std::abort(); }
    return values;
}
inline uint64_t seeds(const std::vector<uint32_t> &values) {
    std::set<uint32_t> destinations;
    for(auto edge: state().added) {
        const uint32_t u=edge.first,v=edge.second;
        if(values[u]!=UINT32_MAX && uint64_t(values[u]) + ((u+v)%128+1) < values[v]) destinations.insert(v);
    }
    return destinations.size();
}
// Wall time of a complete multi-stream group, not the sum of overlapping streams.
struct Timer {
    double started=0; bool running=false, rebuild=false;
    explicit Timer(bool is_rebuild=false):rebuild(is_rebuild) { resume(); }
    void resume() { if(timing() && state().active && (!rebuild || state().computing) && !running) { sync(); started=now(); running=true; if(!rebuild) state().computing=true; } }
    void stop() { if(running) { sync(); const double elapsed=now()-started; if(rebuild) {state().rebuild_ms+=elapsed; ++state().rebuild_groups;} else {state().compute_ms+=elapsed; state().computing=false;} running=false; } }
    ~Timer() { stop(); }
};
inline void finish() {
    auto &s=state(); if(!s.active) return;
    std::printf("[MOTIVATION] {\"batch\":%u,\"mode\":\"%s\",\"vertices\":%llu,\"updated_sources\":%llu,\"relocated_sources\":%llu,\"relocated_untouched_sources\":%llu,\"descriptor_bytes\":%llu,\"invalidated_vertices\":%llu,\"initial_insertion_worklist\":%llu,\"seeds_prebatch\":%llu,\"seeds_preinsert\":%llu,\"compute_ms\":%.6f,\"rebuild_ms\":%.6f,\"rebuild_groups\":%llu}\n",s.batch,mode().c_str(),(unsigned long long)s.nnodes,(unsigned long long)s.updated,(unsigned long long)s.relocated,(unsigned long long)s.relocated_untouched,(unsigned long long)s.descriptor_bytes,(unsigned long long)s.affected,(unsigned long long)s.initial_wl,(unsigned long long)s.seeds_prebatch,(unsigned long long)s.seeds_preinsert,s.compute_ms,s.rebuild_ms,(unsigned long long)s.rebuild_groups);
    std::fflush(stdout); s.active=false;
}
}
#define CG_MOT(...) do { __VA_ARGS__; } while(0)
#else
#define CG_MOT(...) do {} while(0)
#endif
