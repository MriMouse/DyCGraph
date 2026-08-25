#include <cassert>
#include <cstdint>

#include <cuda_runtime.h>

#include <framework/cache_refresh_gate.h>
#include <groute/graphs/csr_graph.cuh>

using groute::graphs::host::vertex_element;

__global__ void ExerciseTailFallback(vertex_element *vertices, index_t *cache_tail,
        unsigned long long *invalidations, index_t cache_capacity) {
    if (blockIdx.x != 0 || threadIdx.x != 0) return;
    auto &vertex = vertices[0];
    groute::graphs::single::ReserveCachePatchOrInvalidate(
        vertex, 3, cache_capacity, cache_tail, invalidations);
}

int main() {
    int devices = 0;
    if (cudaGetDeviceCount(&devices) != cudaSuccess || devices == 0) return 0;

    vertex_element host_vertex{};
    host_vertex.cache = true;
    host_vertex.virtual_start = 1;
    host_vertex.virtual_degree = 1;
    index_t host_tail = 3;
    unsigned long long host_invalidations = 0;

    vertex_element *device_vertex = nullptr;
    index_t *device_tail = nullptr;
    unsigned long long *device_invalidations = nullptr;
    assert(cudaMalloc(&device_vertex, sizeof(host_vertex)) == cudaSuccess);
    assert(cudaMalloc(&device_tail, sizeof(host_tail)) == cudaSuccess);
    assert(cudaMalloc(&device_invalidations, sizeof(host_invalidations)) == cudaSuccess);
    assert(cudaMemcpy(device_vertex, &host_vertex, sizeof(host_vertex), cudaMemcpyHostToDevice) == cudaSuccess);
    assert(cudaMemcpy(device_tail, &host_tail, sizeof(host_tail), cudaMemcpyHostToDevice) == cudaSuccess);
    assert(cudaMemcpy(device_invalidations, &host_invalidations, sizeof(host_invalidations), cudaMemcpyHostToDevice) == cudaSuccess);

    ExerciseTailFallback<<<1, 1>>>(device_vertex, device_tail, device_invalidations, 4);
    assert(cudaDeviceSynchronize() == cudaSuccess);
    assert(cudaMemcpy(&host_vertex, device_vertex, sizeof(host_vertex), cudaMemcpyDeviceToHost) == cudaSuccess);
    assert(cudaMemcpy(&host_tail, device_tail, sizeof(host_tail), cudaMemcpyDeviceToHost) == cudaSuccess);
    assert(cudaMemcpy(&host_invalidations, device_invalidations, sizeof(host_invalidations), cudaMemcpyDeviceToHost) == cudaSuccess);

    assert(!host_vertex.cache);
    assert(host_vertex.virtual_degree == 0);
    assert(host_tail == 6);
    assert(host_invalidations == 1);

    sepgraph::cache_patch::RefreshGate gate;
    assert(gate.Observe(1, true));
    gate.Publish();
    assert(!gate.Observe(1, false));
    assert(gate.Observe(1, true));

    cudaFree(device_invalidations);
    cudaFree(device_tail);
    cudaFree(device_vertex);
    return 0;
}
