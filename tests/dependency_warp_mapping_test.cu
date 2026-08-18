#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <limits>
#include <vector>

#include <cuda_runtime.h>

#include <framework/destination_local_dependency_store.h>

using sepgraph::runtime::DependencyChunkDescriptor;
using sepgraph::runtime::DependencyChunkOptions;
using sepgraph::runtime::DestinationLocalDependencyStore;

__global__ void WarpDestinationMin(
        const index_t *affected,
        uint32_t affected_count,
        const DependencyChunkDescriptor *descriptors,
        index_t *const *slabs,
        const uint32_t *source_values,
        uint32_t *output,
        unsigned long long *processed_edges) {
    const uint32_t global_thread = blockIdx.x * blockDim.x + threadIdx.x;
    const uint32_t warp = global_thread >> 5;
    const uint32_t lane = threadIdx.x & 31;
    if (warp >= affected_count) return;
    const index_t destination = affected[warp];
    const DependencyChunkDescriptor descriptor = descriptors[destination];
    uint32_t best = UINT32_MAX;
    for (uint32_t offset = lane; offset < descriptor.degree; offset += 32) {
        const index_t source = slabs[descriptor.slab_id][descriptor.offset + offset];
        best = min(best, source_values[source]);
        atomicAdd(processed_edges, 1ULL);
    }
    for (uint32_t delta = 16; delta != 0; delta >>= 1) {
        best = min(best, __shfl_down_sync(0xffffffff, best, delta));
    }
    if (lane == 0) output[warp] = best;
}

static void Check(cudaError_t status) { if (status != cudaSuccess) std::abort(); }

int main() {
    int devices = 0;
    if (cudaGetDeviceCount(&devices) != cudaSuccess || devices == 0) return 0;
    DependencyChunkOptions options;
    options.capacity_edges = 256;
    options.slab_capacity_edges = 256;
    options.pinned = true;
    DestinationLocalDependencyStore store(6, options);
    store.LoadDestination(0, {});
    store.LoadDestination(1, {0, 2, 3});
    store.LoadDestination(2, {1});
    store.LoadDestination(3, {0, 1, 2, 3, 4, 5});
    store.LoadDestination(4, {});
    store.LoadDestination(5, {4, 2});
    store.FinalizeLoad(12);

    std::vector<index_t> affected{1, 2, 3, 4, 5};
    std::vector<uint32_t> values{90, 40, 70, 10, 30, 80};
    std::vector<uint32_t> expected;
    for (index_t destination : affected) {
        const auto sources = store.Sources(destination);
        uint32_t best = std::numeric_limits<uint32_t>::max();
        for (index_t source : sources) best = std::min(best, values[source]);
        expected.push_back(best);
    }

    index_t *affected_device = nullptr;
    uint32_t *values_device = nullptr;
    uint32_t *output_device = nullptr;
    index_t **slabs_device = nullptr;
    unsigned long long *processed_device = nullptr;
    Check(cudaMalloc(&affected_device, affected.size() * sizeof(index_t)));
    Check(cudaMalloc(&values_device, values.size() * sizeof(uint32_t)));
    Check(cudaMalloc(&output_device, expected.size() * sizeof(uint32_t)));
    Check(cudaMalloc(&slabs_device, store.SlabCount() * sizeof(index_t *)));
    Check(cudaMalloc(&processed_device, sizeof(unsigned long long)));
    Check(cudaMemcpy(affected_device, affected.data(),
        affected.size() * sizeof(index_t), cudaMemcpyHostToDevice));
    Check(cudaMemcpy(values_device, values.data(),
        values.size() * sizeof(uint32_t), cudaMemcpyHostToDevice));
    std::vector<index_t *> mapped_slabs(store.SlabCount());
    for (uint32_t slab = 0; slab < store.SlabCount(); ++slab)
        mapped_slabs[slab] = store.MappedSlabDeviceData(slab);
    Check(cudaMemcpy(slabs_device, mapped_slabs.data(),
        mapped_slabs.size() * sizeof(index_t *), cudaMemcpyHostToDevice));
    Check(cudaMemset(processed_device, 0, sizeof(unsigned long long)));

    constexpr uint32_t kThreads = 128;
    const uint32_t blocks = (affected.size() * 32 + kThreads - 1) / kThreads;
    WarpDestinationMin<<<blocks, kThreads>>>(
        affected_device, affected.size(), store.MappedDescriptorDeviceData(),
        slabs_device, values_device, output_device, processed_device);
    Check(cudaDeviceSynchronize());
    std::vector<uint32_t> output(expected.size());
    unsigned long long processed = 0;
    Check(cudaMemcpy(output.data(), output_device,
        output.size() * sizeof(uint32_t), cudaMemcpyDeviceToHost));
    Check(cudaMemcpy(&processed, processed_device,
        sizeof(processed), cudaMemcpyDeviceToHost));
    if (output != expected || processed != 12) std::abort();

    cudaFree(affected_device);
    cudaFree(values_device);
    cudaFree(output_device);
    cudaFree(slabs_device);
    cudaFree(processed_device);
    return 0;
}
