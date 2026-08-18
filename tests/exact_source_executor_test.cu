#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <cuda_runtime.h>

#include <framework/exact_source_frontier.h>
#include <groute/graphs/source_local_chunk_store.h>

using sepgraph::runtime::ExactSourceFrontier;
using sepgraph::topology::ChunkArenaOptions;
using sepgraph::topology::SourceLocalChunkStore;
using sepgraph::topology::TopologyDescriptor;
using sepgraph::topology::TopologyMutationBatch;

struct DeviceSourceEvent { index_t source; uint32_t version; };

__global__ void ProcessVersionedSources(const DeviceSourceEvent *events,
        uint32_t count, const TopologyDescriptor *descriptors,
        uint32_t *processed_versions, unsigned long long *processed_edges,
        unsigned long long *accepted, unsigned long long *stale) {
    const uint32_t event_index = blockIdx.x;
    if (event_index >= count) return;
    const DeviceSourceEvent event = events[event_index];
    if (threadIdx.x == 0) {
        const uint32_t previous = atomicMax(
            &processed_versions[event.source], event.version);
        if (event.version <= previous) atomicAdd(stale, 1ULL);
        else {
            atomicAdd(accepted, 1ULL);
            atomicAdd(processed_edges,
                static_cast<unsigned long long>(descriptors[event.source].degree));
        }
    }
}

__global__ void ExpandExactSources(const index_t *sources, uint32_t count,
        const TopologyDescriptor *descriptors, index_t *const *slabs,
        unsigned long long *processed_edges, unsigned long long *edge_sum) {
    const uint32_t source_index = blockIdx.x;
    if (source_index >= count) return;
    const index_t source = sources[source_index];
    const TopologyDescriptor descriptor = descriptors[source];
    for (uint32_t edge = threadIdx.x; edge < descriptor.degree;
         edge += blockDim.x) {
        const index_t destination =
            slabs[descriptor.slab_id][descriptor.index + edge];
        atomicAdd(processed_edges, 1ULL);
        atomicAdd(edge_sum, static_cast<unsigned long long>(destination));
    }
}

static void Check(cudaError_t status) { if (status != cudaSuccess) std::abort(); }

int main() {
    int devices = 0;
    if (cudaGetDeviceCount(&devices) != cudaSuccess || devices == 0) return 0;
    ChunkArenaOptions options;
    options.capacity_edges = 64;
    options.slab_capacity_edges = 64;
    options.minimum_chunk_edges = 1;
    options.pinned = true;
    SourceLocalChunkStore store(5, options);
    store.LoadSource(0, {1, 2});
    store.LoadSource(1, {2});
    store.LoadSource(2, {0, 1, 3});
    store.LoadSource(3, {});
    store.LoadSource(4, {0, 2});
    store.FinalizeLoad(8);

    ExactSourceFrontier frontier(5);
    frontier.BeginEpoch(1);
    frontier.Offer({4, 1, 1});
    frontier.Offer({0, 1, 1});
    frontier.Offer({2, 1, 1});
    frontier.Offer({2, 1, 2});
    const auto sources = frontier.Seal(
        [&](index_t source) { return store.Descriptor(source).degree; });

    std::vector<TopologyDescriptor> descriptors(5);
    for (index_t source = 0; source < descriptors.size(); ++source)
        descriptors[source] = store.Descriptor(source);
    std::vector<index_t *> mapped_slabs(store.SlabCount());
    for (uint32_t slab = 0; slab < mapped_slabs.size(); ++slab)
        Check(cudaHostGetDevicePointer(reinterpret_cast<void **>(&mapped_slabs[slab]),
            const_cast<index_t *>(store.SlabData(slab)), 0));

    index_t *device_sources = nullptr;
    TopologyDescriptor *device_descriptors = nullptr;
    index_t **device_slabs = nullptr;
    unsigned long long *device_processed = nullptr, *device_sum = nullptr;
    Check(cudaMalloc(&device_sources, sources.size() * sizeof(index_t)));
    Check(cudaMalloc(&device_descriptors,
                     descriptors.size() * sizeof(TopologyDescriptor)));
    Check(cudaMalloc(&device_slabs, mapped_slabs.size() * sizeof(index_t *)));
    Check(cudaMalloc(&device_processed, sizeof(unsigned long long)));
    Check(cudaMalloc(&device_sum, sizeof(unsigned long long)));
    Check(cudaMemcpy(device_sources, sources.data(), sources.size() * sizeof(index_t),
                     cudaMemcpyHostToDevice));
    Check(cudaMemcpy(device_descriptors, descriptors.data(),
        descriptors.size() * sizeof(TopologyDescriptor), cudaMemcpyHostToDevice));
    Check(cudaMemcpy(device_slabs, mapped_slabs.data(),
        mapped_slabs.size() * sizeof(index_t *), cudaMemcpyHostToDevice));
    Check(cudaMemset(device_processed, 0, sizeof(unsigned long long)));
    Check(cudaMemset(device_sum, 0, sizeof(unsigned long long)));
    ExpandExactSources<<<sources.size(), 128>>>(device_sources, sources.size(),
        device_descriptors, device_slabs, device_processed, device_sum);
    Check(cudaDeviceSynchronize());
    unsigned long long processed = 0, sum = 0;
    Check(cudaMemcpy(&processed, device_processed, sizeof(processed),
                     cudaMemcpyDeviceToHost));
    Check(cudaMemcpy(&sum, device_sum, sizeof(sum), cudaMemcpyDeviceToHost));
    if (processed != frontier.Metrics().logical_edges || processed != 7 || sum != 9)
        std::abort();

    TopologyMutationBatch mutations;
    mutations.deletions = {{2, 1}};
    mutations.additions = {{2, 4}, {2, 2}};
    store.ApplyBatch(mutations);
    store.Publish();
    descriptors[2] = store.Descriptor(2);
    Check(cudaMemcpy(device_descriptors + 2, &descriptors[2],
        sizeof(TopologyDescriptor), cudaMemcpyHostToDevice));
    frontier.BeginEpoch(2);
    frontier.Offer({2, 2, 3});
    const auto updated_sources = frontier.Seal(
        [&](index_t source) { return store.Descriptor(source).degree; });
    Check(cudaMemcpy(device_sources, updated_sources.data(),
        updated_sources.size() * sizeof(index_t), cudaMemcpyHostToDevice));
    Check(cudaMemset(device_processed, 0, sizeof(unsigned long long)));
    Check(cudaMemset(device_sum, 0, sizeof(unsigned long long)));
    ExpandExactSources<<<updated_sources.size(), 128>>>(device_sources,
        updated_sources.size(), device_descriptors, device_slabs,
        device_processed, device_sum);
    Check(cudaDeviceSynchronize());
    Check(cudaMemcpy(&processed, device_processed, sizeof(processed),
                     cudaMemcpyDeviceToHost));
    Check(cudaMemcpy(&sum, device_sum, sizeof(sum), cudaMemcpyDeviceToHost));
    if (processed != frontier.Metrics().logical_edges || processed != 4 || sum != 9) {
        std::fprintf(stderr,
            "updated exact-source mismatch processed=%llu logical=%llu sum=%llu degree=%u slab=%u offset=%llu\n",
            processed,
            static_cast<unsigned long long>(frontier.Metrics().logical_edges),
            sum, descriptors[2].degree, descriptors[2].slab_id,
            static_cast<unsigned long long>(descriptors[2].index));
        std::abort();
    }

    DeviceSourceEvent *device_events = nullptr;
    uint32_t *device_processed_versions = nullptr;
    unsigned long long *device_accepted = nullptr, *device_stale = nullptr;
    Check(cudaMalloc(&device_events, 3 * sizeof(DeviceSourceEvent)));
    Check(cudaMalloc(&device_processed_versions, 5 * sizeof(uint32_t)));
    Check(cudaMalloc(&device_accepted, sizeof(unsigned long long)));
    Check(cudaMalloc(&device_stale, sizeof(unsigned long long)));
    Check(cudaMemset(device_processed_versions, 0, 5 * sizeof(uint32_t)));
    Check(cudaMemset(device_processed, 0, sizeof(unsigned long long)));
    Check(cudaMemset(device_accepted, 0, sizeof(unsigned long long)));
    Check(cudaMemset(device_stale, 0, sizeof(unsigned long long)));
    const DeviceSourceEvent first_wave[] = {{2, 1}, {4, 1}};
    Check(cudaMemcpy(device_events, first_wave, sizeof(first_wave),
                     cudaMemcpyHostToDevice));
    ProcessVersionedSources<<<2, 32>>>(device_events, 2, device_descriptors,
        device_processed_versions, device_processed, device_accepted,
        device_stale);
    const DeviceSourceEvent second_wave[] = {{2, 1}, {2, 2}, {4, 1}};
    Check(cudaMemcpy(device_events, second_wave, sizeof(second_wave),
                     cudaMemcpyHostToDevice));
    ProcessVersionedSources<<<3, 32>>>(device_events, 3, device_descriptors,
        device_processed_versions, device_processed, device_accepted,
        device_stale);
    Check(cudaDeviceSynchronize());
    unsigned long long accepted = 0, stale = 0;
    Check(cudaMemcpy(&processed, device_processed, sizeof(processed),
                     cudaMemcpyDeviceToHost));
    Check(cudaMemcpy(&accepted, device_accepted, sizeof(accepted),
                     cudaMemcpyDeviceToHost));
    Check(cudaMemcpy(&stale, device_stale, sizeof(stale),
                     cudaMemcpyDeviceToHost));
    if (accepted != 3 || stale != 2 || processed != 10) std::abort();

    cudaFree(device_sources);
    cudaFree(device_descriptors);
    cudaFree(device_slabs);
    cudaFree(device_processed);
    cudaFree(device_sum);
    cudaFree(device_events);
    cudaFree(device_processed_versions);
    cudaFree(device_accepted);
    cudaFree(device_stale);
    return 0;
}
