#ifndef SEPGRAPH_SOURCE_LOCAL_CHUNK_STORE_H
#define SEPGRAPH_SOURCE_LOCAL_CHUNK_STORE_H

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <stdexcept>
#include <unordered_map>
#include <utility>
#include <vector>

#include <cuda_runtime_api.h>

#include <framework/topology_replay.h>
#include <groute/graphs/topology_contract.cuh>

namespace sepgraph {
namespace topology {

struct ChunkArenaOptions {
    uint64_t capacity_edges = 0;
    uint64_t slab_capacity_edges = 1ULL << 20;
    index_t minimum_chunk_edges = 4;
    bool pinned = true;
};

struct ChunkStoreBatchMetrics {
    uint64_t epoch = 0;
    uint64_t touched_sources = 0;
    uint64_t changed_sources = 0;
    uint64_t missing_deletes = 0;
    uint64_t invalid_additions = 0;
    uint64_t mutation_written_bytes = 0;
    uint64_t relocation_copied_bytes = 0;
    uint64_t allocations = 0;
    uint64_t reused_blocks = 0;
    uint64_t retired_blocks = 0;
    double group_ms = 0.0;
    double mutation_ms = 0.0;
    double allocation_ms = 0.0;
};

struct ChunkArenaStats {
    uint64_t capacity_edges = 0;
    uint64_t high_water_edges = 0;
    uint64_t live_capacity_edges = 0;
    uint64_t retired_capacity_edges = 0;
    uint64_t free_capacity_edges = 0;
    uint64_t allocation_count = 0;
    uint64_t reuse_count = 0;
    uint64_t reclaimed_count = 0;
    bool pinned = false;
};

class SourceLocalChunkStore {
public:
    static constexpr uint32_t kInvalidSlab = std::numeric_limits<uint32_t>::max();

    SourceLocalChunkStore(index_t node_count, ChunkArenaOptions options)
        : sources_(node_count), options_(options), allocation_slab_cursor_(0),
          logical_edge_count_(0), materialized_edge_count_(0),
          published_epoch_(0), pending_epoch_(0), batch_pending_(false) {
        if (options_.capacity_edges == 0) {
            throw std::invalid_argument("chunk arena capacity must be non-zero");
        }
        if (options_.slab_capacity_edges == 0) {
            throw std::invalid_argument("chunk slab capacity must be non-zero");
        }
        if (options_.minimum_chunk_edges == 0) options_.minimum_chunk_edges = 1;
        try {
            uint64_t remaining = options_.capacity_edges;
            while (remaining != 0) {
                const uint64_t slab_edges = std::min(remaining, options_.slab_capacity_edges);
                slabs_.push_back(AllocateSlab(slab_edges));
                remaining -= slab_edges;
            }
        } catch (...) {
            ReleaseSlabs();
            throw;
        }
        stats_.capacity_edges = options_.capacity_edges;
        stats_.pinned = options_.pinned;
    }

    SourceLocalChunkStore(const SourceLocalChunkStore &) = delete;
    SourceLocalChunkStore &operator=(const SourceLocalChunkStore &) = delete;

    ~SourceLocalChunkStore() {
        ReleaseSlabs();
    }

    static uint64_t RequiredChunkCapacity(uint64_t degree,
                                          index_t minimum_chunk_edges = 4) {
        if (degree == 0) return 0;
        uint64_t capacity = std::max<uint64_t>(degree, minimum_chunk_edges);
        --capacity;
        capacity |= capacity >> 1;
        capacity |= capacity >> 2;
        capacity |= capacity >> 4;
        capacity |= capacity >> 8;
        capacity |= capacity >> 16;
        capacity |= capacity >> 32;
        return capacity + 1;
    }

    void LoadSource(index_t source, const std::vector<index_t> &neighbors) {
        EnsureNoPendingBatch();
        SourceState &state = Source(source);
        if (state.materialized) throw std::logic_error("source already materialized");
        state.materialized = true;
        if (!neighbors.empty()) {
            const uint64_t capacity = RequiredChunkCapacity(
                neighbors.size(), options_.minimum_chunk_edges);
            const Allocation allocation = Allocate(capacity);
            std::memcpy(BlockData(allocation.block), neighbors.data(),
                        neighbors.size() * sizeof(index_t));
            state.block = allocation.block;
            state.descriptor.index = allocation.block.offset;
            state.descriptor.degree = static_cast<index_t>(neighbors.size());
            state.descriptor.slab_id = allocation.block.slab_id;
        }
        materialized_edge_count_ += neighbors.size();
    }

    void FinalizeLoad(uint64_t graph_edge_count = std::numeric_limits<uint64_t>::max()) {
        EnsureNoPendingBatch();
        logical_edge_count_ = graph_edge_count == std::numeric_limits<uint64_t>::max()
            ? materialized_edge_count_
            : graph_edge_count;
    }

    ChunkStoreBatchMetrics ApplyBatch(const TopologyMutationBatch &batch) {
        EnsureNoPendingBatch();
        const auto group_begin = Clock::now();
        std::unordered_map<index_t, SourceMutations> grouped;
        grouped.reserve(batch.deletions.size() + batch.additions.size());
        for (const auto &mutation : batch.deletions) {
            grouped[mutation.source].deletions.push_back(mutation.destination);
        }
        for (const auto &mutation : batch.additions) {
            grouped[mutation.source].additions.push_back(mutation.destination);
        }
        std::vector<index_t> sources;
        sources.reserve(grouped.size());
        for (const auto &entry : grouped) sources.push_back(entry.first);
        std::sort(sources.begin(), sources.end());

        ChunkStoreBatchMetrics metrics;
        metrics.epoch = published_epoch_ + 1;
        metrics.touched_sources = sources.size();
        metrics.group_ms = Milliseconds(group_begin, Clock::now());

        const auto mutation_begin = Clock::now();
        std::vector<PreparedSource> prepared;
        prepared.reserve(sources.size());
        std::vector<uint64_t> required_allocations;
        int64_t edge_delta = 0;
        for (const index_t source : sources) {
            auto group_it = grouped.find(source);
            if (source >= sources_.size() || !sources_[source].materialized) {
                metrics.missing_deletes += group_it->second.deletions.size();
                metrics.invalid_additions += group_it->second.additions.size();
                continue;
            }

            std::vector<index_t> updated = Neighbors(source);
            uint64_t successful_deletes = 0;
            for (const index_t destination : group_it->second.deletions) {
                const auto position = std::find(
                    updated.begin(), updated.end(), destination);
                if (position == updated.end()) {
                    ++metrics.missing_deletes;
                } else {
                    updated.erase(position);
                    --edge_delta;
                    ++successful_deletes;
                }
            }
            edge_delta += group_it->second.additions.size();
            const uint64_t final_degree =
                updated.size() + group_it->second.additions.size();
            if (successful_deletes == 0 && group_it->second.additions.empty()) continue;

            ++metrics.changed_sources;
            PreparedSource update;
            update.source = source;
            if (final_degree > sources_[source].block.capacity) {
                update.expansion = true;
                updated.insert(updated.end(),
                               group_it->second.additions.begin(),
                               group_it->second.additions.end());
                update.expanded_neighbors = std::move(updated);
                required_allocations.push_back(RequiredChunkCapacity(
                    final_degree, options_.minimum_chunk_edges));
            }
            prepared.push_back(std::move(update));
        }
        EnsureAllocationsFit(required_allocations);
        pending_epoch_ = metrics.epoch;
        batch_pending_ = true;
        logical_edge_count_ = static_cast<uint64_t>(
            static_cast<int64_t>(logical_edge_count_) + edge_delta);
        for (const auto &update : prepared) {
            if (update.expansion) {
                ExpandSource(update.source, update.expanded_neighbors, metrics);
            } else {
                MutateSourceInPlace(
                    update.source, grouped.at(update.source), metrics);
            }
        }
        metrics.mutation_ms = Milliseconds(mutation_begin, Clock::now());
        return metrics;
    }

    uint64_t Publish() {
        if (!batch_pending_) throw std::logic_error("no chunk-store batch to publish");
        published_epoch_ = pending_epoch_;
        batch_pending_ = false;
        return published_epoch_;
    }

    uint64_t ReclaimThrough(uint64_t completed_epoch) {
        uint64_t reclaimed = 0;
        auto output = retired_.begin();
        for (auto current = retired_.begin(); current != retired_.end(); ++current) {
            if (current->epoch <= completed_epoch) {
                free_blocks_[current->block.capacity].push_back(current->block);
                stats_.retired_capacity_edges -= current->block.capacity;
                stats_.free_capacity_edges += current->block.capacity;
                ++stats_.reclaimed_count;
                ++reclaimed;
            } else {
                *output++ = *current;
            }
        }
        retired_.erase(output, retired_.end());
        return reclaimed;
    }

    std::vector<index_t> Neighbors(index_t source) const {
        const SourceState &state = Source(source);
        if (!state.materialized) throw std::logic_error("source is not materialized");
        if (state.descriptor.degree == 0) return {};
        return std::vector<index_t>(
            slabs_.at(state.descriptor.slab_id).data + state.descriptor.index,
            slabs_.at(state.descriptor.slab_id).data +
                state.descriptor.index + state.descriptor.degree);
    }

    SourceTopologyDigest Digest(index_t source) const {
        return DigestSource(source, Neighbors(source));
    }

    const TopologyDescriptor &Descriptor(index_t source) const {
        return Source(source).descriptor;
    }

    bool IsMaterialized(index_t source) const {
        return source < sources_.size() && sources_[source].materialized;
    }

    uint64_t EdgeCount() const { return logical_edge_count_; }
    uint64_t PublishedEpoch() const { return published_epoch_; }
    uint64_t PendingEpoch() const { return pending_epoch_; }
    bool IsPublished() const { return !batch_pending_ && published_epoch_ == pending_epoch_; }
    const ChunkArenaStats &ArenaStats() const { return stats_; }
    size_t SlabCount() const { return slabs_.size(); }
    const index_t *SlabData(uint32_t slab_id) const { return slabs_.at(slab_id).data; }
    uint64_t MetadataBytes() const { return sources_.size() * sizeof(SourceState); }

private:
    using Clock = std::chrono::steady_clock;

    struct Block {
        uint32_t slab_id = kInvalidSlab;
        uint64_t offset = 0;
        uint64_t capacity = 0;
    };

    struct Slab {
        index_t *data = nullptr;
        uint64_t capacity = 0;
        uint64_t bump = 0;
    };

    struct Allocation {
        Block block;
        bool reused = false;
    };

    struct RetiredBlock {
        Block block;
        uint64_t epoch;
    };

    struct SourceState {
        TopologyDescriptor descriptor{0, 0, kInvalidSlab, 0};
        Block block;
        bool materialized = false;
    };

    struct SourceMutations {
        std::vector<index_t> deletions;
        std::vector<index_t> additions;
    };

    struct PreparedSource {
        index_t source = 0;
        bool expansion = false;
        std::vector<index_t> expanded_neighbors;
    };

    static double Milliseconds(Clock::time_point begin, Clock::time_point end) {
        return std::chrono::duration<double, std::milli>(end - begin).count();
    }

    SourceState &Source(index_t source) {
        if (source >= sources_.size()) throw std::out_of_range("source exceeds node count");
        return sources_[source];
    }

    const SourceState &Source(index_t source) const {
        if (source >= sources_.size()) throw std::out_of_range("source exceeds node count");
        return sources_[source];
    }

    void EnsureNoPendingBatch() const {
        if (batch_pending_) throw std::logic_error("publish pending chunk-store batch first");
    }

    Slab AllocateSlab(uint64_t capacity) {
        Slab slab;
        slab.capacity = capacity;
        const size_t bytes = static_cast<size_t>(capacity) * sizeof(index_t);
        if (options_.pinned) {
            const cudaError_t status = cudaHostAlloc(
                reinterpret_cast<void **>(&slab.data), bytes,
                cudaHostAllocMapped | cudaHostAllocPortable);
            if (status != cudaSuccess) {
                throw std::runtime_error(
                    std::string("cudaHostAlloc for chunk slab failed: ") +
                    cudaGetErrorString(status));
            }
        } else {
            slab.data = new index_t[capacity];
        }
        return slab;
    }

    void ReleaseSlabs() {
        for (auto &slab : slabs_) {
            if (options_.pinned) cudaFreeHost(slab.data);
            else delete[] slab.data;
        }
        slabs_.clear();
    }

    index_t *BlockData(const Block &block) {
        return slabs_.at(block.slab_id).data + block.offset;
    }

    void EnsureAllocationsFit(const std::vector<uint64_t> &capacities) const {
        std::unordered_map<uint64_t, size_t> free_counts;
        for (const auto &entry : free_blocks_) {
            free_counts.emplace(entry.first, entry.second.size());
        }
        std::vector<uint64_t> remaining;
        remaining.reserve(slabs_.size());
        for (const auto &slab : slabs_) remaining.push_back(slab.capacity - slab.bump);
        size_t cursor = allocation_slab_cursor_;
        for (const uint64_t capacity : capacities) {
            auto free_it = free_counts.find(capacity);
            if (free_it != free_counts.end() && free_it->second != 0) {
                --free_it->second;
                continue;
            }
            bool found = false;
            for (size_t attempt = 0; attempt < remaining.size(); ++attempt) {
                const size_t slab_id = (cursor + attempt) % remaining.size();
                if (capacity <= remaining[slab_id]) {
                    remaining[slab_id] -= capacity;
                    cursor = slab_id;
                    found = true;
                    break;
                }
            }
            if (!found) {
                throw std::runtime_error(
                    "source-local chunk arena exhausted; increase its load-stage reservation");
            }
        }
    }

    Allocation Allocate(uint64_t capacity) {
        auto free_it = free_blocks_.find(capacity);
        Allocation allocation;
        if (free_it != free_blocks_.end() && !free_it->second.empty()) {
            allocation.block = free_it->second.back();
            free_it->second.pop_back();
            allocation.reused = true;
            stats_.free_capacity_edges -= capacity;
            ++stats_.reuse_count;
        } else {
            bool found = false;
            for (size_t attempt = 0; attempt < slabs_.size(); ++attempt) {
                const size_t slab_id =
                    (allocation_slab_cursor_ + attempt) % slabs_.size();
                Slab &slab = slabs_[slab_id];
                if (capacity <= slab.capacity - slab.bump) {
                    allocation.block = {
                        static_cast<uint32_t>(slab_id), slab.bump, capacity};
                    slab.bump += capacity;
                    allocation_slab_cursor_ = slab_id;
                    found = true;
                    break;
                }
            }
            if (!found) {
                throw std::runtime_error(
                    "source-local chunk arena exhausted; increase its load-stage reservation");
            }
            stats_.high_water_edges += capacity;
        }
        stats_.live_capacity_edges += capacity;
        ++stats_.allocation_count;
        return allocation;
    }

    void Retire(Block block, uint64_t epoch) {
        if (block.capacity == 0) return;
        retired_.push_back({block, epoch});
        stats_.live_capacity_edges -= block.capacity;
        stats_.retired_capacity_edges += block.capacity;
    }

    void MutateSourceInPlace(index_t source,
                             const SourceMutations &mutations,
                             ChunkStoreBatchMetrics &metrics) {
        SourceState &state = Source(source);
        index_t *edges = state.block.capacity == 0 ? nullptr : BlockData(state.block);
        uint64_t degree = state.descriptor.degree;
        for (const index_t destination : mutations.deletions) {
            if (degree == 0) continue;
            index_t *position = std::find(edges, edges + degree, destination);
            if (position == edges + degree) continue;
            const uint64_t trailing = (edges + degree) - (position + 1);
            if (trailing != 0) {
                std::memmove(position, position + 1, trailing * sizeof(index_t));
            }
            metrics.mutation_written_bytes += trailing * sizeof(index_t);
            --degree;
        }
        if (!mutations.additions.empty()) {
            std::memcpy(edges + degree, mutations.additions.data(),
                        mutations.additions.size() * sizeof(index_t));
            metrics.mutation_written_bytes +=
                mutations.additions.size() * sizeof(index_t);
            degree += mutations.additions.size();
        }
        state.descriptor.degree = static_cast<index_t>(degree);
        ++state.descriptor.version;
    }

    void ExpandSource(index_t source,
                      const std::vector<index_t> &neighbors,
                      ChunkStoreBatchMetrics &metrics) {
        SourceState &state = Source(source);
        const uint64_t capacity = RequiredChunkCapacity(
            neighbors.size(), options_.minimum_chunk_edges);
        const auto allocation_begin = Clock::now();
        const Allocation allocation = Allocate(capacity);
        metrics.allocation_ms += Milliseconds(allocation_begin, Clock::now());
        ++metrics.allocations;
        if (allocation.reused) ++metrics.reused_blocks;
        metrics.relocation_copied_bytes +=
            static_cast<uint64_t>(state.descriptor.degree) * sizeof(index_t);
        std::memcpy(BlockData(allocation.block), neighbors.data(),
                    neighbors.size() * sizeof(index_t));
        if (state.block.capacity != 0) {
            Retire(state.block, pending_epoch_);
            ++metrics.retired_blocks;
        }
        state.block = allocation.block;
        state.descriptor.index = allocation.block.offset;
        state.descriptor.slab_id = allocation.block.slab_id;
        state.descriptor.degree = static_cast<index_t>(neighbors.size());
        ++state.descriptor.version;
        metrics.mutation_written_bytes += neighbors.size() * sizeof(index_t);
    }

    std::vector<SourceState> sources_;
    ChunkArenaOptions options_;
    std::vector<Slab> slabs_;
    size_t allocation_slab_cursor_;
    std::unordered_map<uint64_t, std::vector<Block>> free_blocks_;
    std::vector<RetiredBlock> retired_;
    ChunkArenaStats stats_;
    uint64_t logical_edge_count_;
    uint64_t materialized_edge_count_;
    uint64_t published_epoch_;
    uint64_t pending_epoch_;
    bool batch_pending_;
};

} // namespace topology
} // namespace sepgraph

#endif // SEPGRAPH_SOURCE_LOCAL_CHUNK_STORE_H
