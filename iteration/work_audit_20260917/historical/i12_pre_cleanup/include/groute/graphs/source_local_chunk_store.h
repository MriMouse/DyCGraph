#ifndef SEPGRAPH_SOURCE_LOCAL_CHUNK_STORE_H
#define SEPGRAPH_SOURCE_LOCAL_CHUNK_STORE_H

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <string>
#include <stdexcept>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <cuda_runtime_api.h>

#include <framework/topology_replay.h>
#include <groute/graphs/topology_contract.cuh>
#include <utils/fixed_worker_pool.h>

namespace sepgraph {
namespace topology {

struct ChunkArenaOptions {
    uint64_t capacity_edges = 0;
    uint64_t slab_capacity_edges = 1ULL << 20;
    index_t minimum_chunk_edges = 4;
    bool pinned = true;
    uint32_t mutation_workers = 0;
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
    uint64_t update_count = 0;
    uint64_t source_work = 0;
    uint64_t max_source_updates = 0;
    uint64_t max_source_work = 0;
    uint64_t worker_count = 0;
    double group_ms = 0.0;
    double prepare_ms = 0.0;
    double preflight_ms = 0.0;
    double commit_ms = 0.0;
    double apply_ms = 0.0;
    double retire_ms = 0.0;
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
        uint32_t worker_count = options_.mutation_workers;
        if (worker_count == 0) {
            const uint32_t hardware_workers = std::thread::hardware_concurrency();
            worker_count = std::max<uint32_t>(
                1, std::min<uint32_t>(20, hardware_workers == 0 ? 1 : hardware_workers));
        }
        mutation_workers_.reset(new concurrency::FixedWorkerPool(worker_count));
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
        return ApplyMutationPhase(batch, true);
    }

    void PrepareTransaction(const TopologyMutationBatch &batch) {
        EnsureNoPendingBatch();
        PrepareTransactionImpl(batch);
    }

    ChunkStoreBatchMetrics CommitPreparedTransaction() {
        if (!prepared_transaction_) {
            throw std::logic_error("no prepared chunk-store transaction");
        }
        auto transaction = std::move(prepared_transaction_);
        auto &metrics = transaction->metrics;
        const auto commit_begin = Clock::now();
        pending_epoch_ = metrics.epoch;
        batch_pending_ = true;
        logical_edge_count_ = static_cast<uint64_t>(
            static_cast<int64_t>(logical_edge_count_) + transaction->edge_delta);
        for (auto &update : transaction->prepared) {
            SourceState &state = Source(update.source);
            const Block old_block = state.block;
            state.block = update.allocation.block;
            state.descriptor.index = update.allocation.block.offset;
            state.descriptor.slab_id = update.allocation.block.slab_id;
            state.descriptor.degree = static_cast<index_t>(update.final_degree);
            state.descriptor.version = static_cast<uint32_t>(pending_epoch_);
            if (old_block.capacity != 0) {
                Retire(old_block, pending_epoch_);
                ++metrics.retired_blocks;
            }
        }
        metrics.commit_ms = Milliseconds(commit_begin, Clock::now());
        metrics.retire_ms = metrics.commit_ms;
        metrics.mutation_ms = Milliseconds(
            transaction->mutation_begin, Clock::now());
        return metrics;
    }

    bool HasPreparedTransaction() const {
        return prepared_transaction_ != nullptr;
    }

    const TopologyMutationBatch &PreparedReverseDelta() const {
        if (!prepared_transaction_) {
            throw std::logic_error("no prepared chunk-store transaction");
        }
        return prepared_transaction_->effective_batch;
    }

    // Deletion repair needs the host graph after deletions but before additions.
    // This appends the addition phase to the same unpublished topology epoch.
    ChunkStoreBatchMetrics ApplyPendingAdditions(
            const TopologyMutationBatch &additions) {
        if (!batch_pending_) {
            throw std::logic_error("no pending chunk-store batch");
        }
        if (!additions.deletions.empty()) {
            throw std::invalid_argument(
                "pending chunk-store phase accepts additions only");
        }
        return ApplyMutationPhase(additions, false);
    }

private:
    void PrepareTransactionImpl(const TopologyMutationBatch &batch) {
        const auto group_begin = Clock::now();
        std::unique_ptr<PreparedTransaction> transaction(new PreparedTransaction);
        auto &groups = transaction->groups;
        auto &prepared = transaction->prepared;
        auto &metrics = transaction->metrics;
        transaction->mutation_begin = group_begin;
        groups.reserve(batch.deletions.size() + batch.additions.size());
        transaction->effective_batch.deletions.reserve(batch.deletions.size());
        transaction->effective_batch.additions.reserve(batch.additions.size());
        transaction->sorted_deletions = batch.deletions;
        transaction->sorted_additions = batch.additions;
        const auto by_source = [](const TopologyMutation &lhs,
                                  const TopologyMutation &rhs) {
            return lhs.source < rhs.source;
        };
        std::sort(transaction->sorted_deletions.begin(),
                  transaction->sorted_deletions.end(), by_source);
        std::sort(transaction->sorted_additions.begin(),
                  transaction->sorted_additions.end(), by_source);
        transaction->deletion_destinations.reserve(
            transaction->sorted_deletions.size());
        for (const auto &mutation : transaction->sorted_deletions) {
            transaction->deletion_destinations.push_back(mutation.destination);
        }
        transaction->addition_destinations.reserve(
            transaction->sorted_additions.size());
        for (const auto &mutation : transaction->sorted_additions) {
            transaction->addition_destinations.push_back(mutation.destination);
        }
        size_t deletion = 0;
        size_t addition = 0;
        while (deletion < transaction->sorted_deletions.size() ||
               addition < transaction->sorted_additions.size()) {
            const index_t deletion_source =
                deletion < transaction->sorted_deletions.size()
                    ? transaction->sorted_deletions[deletion].source
                    : std::numeric_limits<index_t>::max();
            const index_t addition_source =
                addition < transaction->sorted_additions.size()
                    ? transaction->sorted_additions[addition].source
                    : std::numeric_limits<index_t>::max();
            TransactionSourceMutations group;
            group.source = std::min(deletion_source, addition_source);
            group.deletion_begin = deletion;
            while (deletion < transaction->sorted_deletions.size() &&
                   transaction->sorted_deletions[deletion].source == group.source) {
                ++deletion;
            }
            group.deletion_count = deletion - group.deletion_begin;
            group.addition_begin = addition;
            while (addition < transaction->sorted_additions.size() &&
                   transaction->sorted_additions[addition].source == group.source) {
                ++addition;
            }
            group.addition_count = addition - group.addition_begin;
            groups.push_back(group);
        }

        metrics.epoch = published_epoch_ + 1;
        if (metrics.epoch > std::numeric_limits<uint32_t>::max()) {
            throw std::overflow_error("topology source version exhausted");
        }
        metrics.touched_sources = groups.size();
        metrics.worker_count = mutation_workers_->WorkerCount();
        metrics.update_count = batch.deletions.size() + batch.additions.size();
        for (size_t source_index = 0; source_index < groups.size(); ++source_index) {
            const auto &mutations = groups[source_index];
            const index_t source = mutations.source;
            const uint64_t source_updates =
                mutations.deletion_count + mutations.addition_count;
            metrics.max_source_updates = std::max(
                metrics.max_source_updates, source_updates);
            const uint64_t source_work = source_updates +
                (source < sources_.size() && sources_[source].materialized
                    ? sources_[source].descriptor.degree
                    : 0);
            metrics.source_work += source_work;
            metrics.max_source_work = std::max(
                metrics.max_source_work, source_work);
        }
        metrics.group_ms = Milliseconds(group_begin, Clock::now());

        const auto prepare_begin = Clock::now();
        prepared.reserve(groups.size());
        std::vector<PreparedResult> results(groups.size());
        mutation_workers_->Run(groups.size(), [&](size_t source_index) {
            const auto &mutations = groups[source_index];
            const index_t source = mutations.source;
            PreparedResult &result = results[source_index];
            if (source >= sources_.size() || !sources_[source].materialized) {
                result.missing_deletes = mutations.deletion_count;
                result.invalid_additions = mutations.addition_count;
                return;
            }
            result.update.source = source;
            result.update.group_index = source_index;
            BuildDeletionPlan(source,
                transaction->deletion_destinations.data() +
                    mutations.deletion_begin,
                mutations.deletion_count, result.update);
            const uint64_t successful_deletes = result.update.successful_deletes;
            result.missing_deletes =
                mutations.deletion_count - successful_deletes;
            result.edge_delta = static_cast<int64_t>(mutations.addition_count) -
                                static_cast<int64_t>(successful_deletes);
            const uint64_t final_degree = sources_[source].descriptor.degree -
                successful_deletes + mutations.addition_count;
            if (final_degree > std::numeric_limits<index_t>::max()) {
                throw std::overflow_error("source degree exceeds index_t");
            }
            if (successful_deletes == 0 && mutations.addition_count == 0) return;
            result.changed = true;
            result.update.final_degree = final_degree;
            result.update.expansion = true;
        });

        std::vector<uint64_t> required_allocations;
        required_allocations.reserve(prepared.size());
        for (auto &result : results) {
            metrics.missing_deletes += result.missing_deletes;
            metrics.invalid_additions += result.invalid_additions;
            transaction->edge_delta += result.edge_delta;
            if (!result.changed) continue;
            AppendEffectiveDeletions(
                result.update, transaction->effective_batch.deletions);
            const auto &group = groups[result.update.group_index];
            for (size_t offset = 0; offset < group.addition_count; ++offset) {
                transaction->effective_batch.additions.push_back(
                    transaction->sorted_additions[group.addition_begin + offset]);
            }
            ++metrics.changed_sources;
            if (result.update.final_degree != 0) {
                required_allocations.push_back(RequiredChunkCapacity(
                    result.update.final_degree, options_.minimum_chunk_edges));
            }
            prepared.push_back(std::move(result.update));
        }
        metrics.prepare_ms = Milliseconds(prepare_begin, Clock::now());

        const auto preflight_begin = Clock::now();
        EnsureAllocationsFit(required_allocations);
        metrics.preflight_ms = Milliseconds(preflight_begin, Clock::now());
        for (auto &update : prepared) {
            if (update.final_degree == 0) continue;
            const auto allocation_begin = Clock::now();
            update.allocation = Allocate(RequiredChunkCapacity(
                update.final_degree, options_.minimum_chunk_edges));
            metrics.allocation_ms += Milliseconds(allocation_begin, Clock::now());
            ++metrics.allocations;
            if (update.allocation.reused) ++metrics.reused_blocks;
        }

        try {
            const auto apply_begin = Clock::now();
            std::vector<ChunkStoreBatchMetrics> apply_metrics(prepared.size());
            mutation_workers_->Run(prepared.size(), [&](size_t update_index) {
                MaterializePreparedSource(
                    prepared[update_index],
                    transaction->addition_destinations.data() +
                        groups[prepared[update_index].group_index].addition_begin,
                    groups[prepared[update_index].group_index].addition_count,
                    apply_metrics[update_index]);
            });
            metrics.apply_ms = Milliseconds(apply_begin, Clock::now());
            for (const auto &local : apply_metrics) {
                metrics.mutation_written_bytes += local.mutation_written_bytes;
                metrics.relocation_copied_bytes += local.relocation_copied_bytes;
            }
            prepared_transaction_ = std::move(transaction);
        } catch (...) {
            for (const auto &update : prepared) {
                if (update.allocation.block.capacity != 0) {
                    free_blocks_[update.allocation.block.capacity].push_back(
                        update.allocation.block);
                    stats_.live_capacity_edges -= update.allocation.block.capacity;
                    stats_.free_capacity_edges += update.allocation.block.capacity;
                }
            }
            throw;
        }
    }

    ChunkStoreBatchMetrics ApplyMutationPhase(const TopologyMutationBatch &batch,
                                              bool begin_epoch) {
        const auto group_begin = Clock::now();
        std::vector<index_t> sources;
        sources.reserve(batch.deletions.size() + batch.additions.size());
        for (const auto &mutation : batch.deletions) {
            sources.push_back(mutation.source);
        }
        for (const auto &mutation : batch.additions) {
            sources.push_back(mutation.source);
        }
        std::sort(sources.begin(), sources.end());
        sources.erase(std::unique(sources.begin(), sources.end()), sources.end());
        std::vector<SourceMutations> grouped(sources.size());
        for (const auto &mutation : batch.deletions) {
            const size_t source_index = std::lower_bound(
                sources.begin(), sources.end(), mutation.source) - sources.begin();
            grouped[source_index].deletions.push_back(mutation.destination);
        }
        for (const auto &mutation : batch.additions) {
            const size_t source_index = std::lower_bound(
                sources.begin(), sources.end(), mutation.source) - sources.begin();
            grouped[source_index].additions.push_back(mutation.destination);
        }

        ChunkStoreBatchMetrics metrics;
        metrics.epoch = begin_epoch ? published_epoch_ + 1 : pending_epoch_;
        if (metrics.epoch > std::numeric_limits<uint32_t>::max()) {
            throw std::overflow_error("topology source version exhausted");
        }
        metrics.touched_sources = sources.size();
        metrics.worker_count = mutation_workers_->WorkerCount();
        metrics.update_count = batch.deletions.size() + batch.additions.size();
        for (size_t source_index = 0; source_index < sources.size(); ++source_index) {
            const index_t source = sources[source_index];
            const auto &mutations = grouped[source_index];
            const uint64_t source_updates =
                mutations.deletions.size() + mutations.additions.size();
            metrics.max_source_updates = std::max(
                metrics.max_source_updates, source_updates);
            const uint64_t source_work = source_updates +
                (source < sources_.size() && sources_[source].materialized
                    ? sources_[source].descriptor.degree
                    : 0);
            metrics.source_work += source_work;
            metrics.max_source_work = std::max(
                metrics.max_source_work, source_work);
        }
        metrics.group_ms = Milliseconds(group_begin, Clock::now());

        const auto mutation_begin = Clock::now();
        std::vector<PreparedResult> results(sources.size());
        mutation_workers_->Run(sources.size(), [&](size_t source_index) {
            const index_t source = sources[source_index];
            const auto &mutations = grouped[source_index];
            PreparedResult &result = results[source_index];
            if (source >= sources_.size() || !sources_[source].materialized) {
                result.missing_deletes = mutations.deletions.size();
                result.invalid_additions = mutations.additions.size();
                return;
            }

            result.update.source = source;
            result.update.group_index = source_index;
            BuildDeletionPlan(source, mutations.deletions, result.update);
            const uint64_t successful_deletes = result.update.successful_deletes;
            result.missing_deletes =
                mutations.deletions.size() - successful_deletes;
            result.edge_delta = static_cast<int64_t>(mutations.additions.size()) -
                                static_cast<int64_t>(successful_deletes);
            const uint64_t final_degree = sources_[source].descriptor.degree -
                successful_deletes + mutations.additions.size();
            if (final_degree > std::numeric_limits<index_t>::max()) {
                throw std::overflow_error("source degree exceeds index_t");
            }
            if (successful_deletes == 0 && mutations.additions.empty()) return;
            result.changed = true;
            result.update.final_degree = final_degree;
            result.update.expansion = final_degree > sources_[source].block.capacity;
        });

        std::vector<PreparedSource> prepared;
        prepared.reserve(sources.size());
        std::vector<uint64_t> required_allocations;
        int64_t edge_delta = 0;
        for (auto &result : results) {
            metrics.missing_deletes += result.missing_deletes;
            metrics.invalid_additions += result.invalid_additions;
            edge_delta += result.edge_delta;
            if (!result.changed) continue;
            ++metrics.changed_sources;
            if (result.update.expansion) {
                required_allocations.push_back(RequiredChunkCapacity(
                    result.update.final_degree, options_.minimum_chunk_edges));
            }
            prepared.push_back(std::move(result.update));
        }
        const auto prepare_end = Clock::now();
        metrics.prepare_ms = Milliseconds(mutation_begin, prepare_end);
        const auto preflight_begin = Clock::now();
        EnsureAllocationsFit(required_allocations);
        metrics.preflight_ms = Milliseconds(preflight_begin, Clock::now());
        for (auto &update : prepared) {
            if (!update.expansion) continue;
            const auto allocation_begin = Clock::now();
            update.allocation = Allocate(RequiredChunkCapacity(
                update.final_degree, options_.minimum_chunk_edges));
            metrics.allocation_ms += Milliseconds(allocation_begin, Clock::now());
            ++metrics.allocations;
            if (update.allocation.reused) ++metrics.reused_blocks;
        }
        const auto commit_begin = Clock::now();
        if (begin_epoch) {
            pending_epoch_ = metrics.epoch;
            batch_pending_ = true;
        }
        logical_edge_count_ = static_cast<uint64_t>(
            static_cast<int64_t>(logical_edge_count_) + edge_delta);
        metrics.commit_ms = Milliseconds(commit_begin, Clock::now());
        const auto apply_begin = Clock::now();
        std::vector<ChunkStoreBatchMetrics> apply_metrics(prepared.size());
        mutation_workers_->Run(prepared.size(), [&](size_t update_index) {
            auto &update = prepared[update_index];
            if (update.expansion) {
                RewriteSourceToNewBlock(
                    update, grouped[update.group_index], apply_metrics[update_index]);
            } else {
                CompactSourceInPlace(
                    update, grouped[update.group_index], apply_metrics[update_index]);
            }
        });
        const auto apply_end = Clock::now();
        metrics.apply_ms = Milliseconds(apply_begin, apply_end);
        const auto retire_begin = Clock::now();
        for (size_t index = 0; index < prepared.size(); ++index) {
            const auto &local = apply_metrics[index];
            metrics.mutation_written_bytes += local.mutation_written_bytes;
            metrics.relocation_copied_bytes += local.relocation_copied_bytes;
            if (prepared[index].retired_block.capacity != 0) {
                Retire(prepared[index].retired_block, pending_epoch_);
                ++metrics.retired_blocks;
            }
        }
        const auto mutation_end = Clock::now();
        metrics.retire_ms = Milliseconds(retire_begin, mutation_end);
        metrics.mutation_ms = Milliseconds(mutation_begin, mutation_end);
        return metrics;
    }

public:

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

    uint64_t OrderedHash(index_t source) const {
        const SourceState &state = Source(source);
        uint64_t hash = 1469598103934665603ULL;
        if (state.descriptor.degree != 0) {
            const index_t *edges = slabs_.at(state.descriptor.slab_id).data +
                                   state.descriptor.index;
            for (uint64_t offset = 0; offset < state.descriptor.degree; ++offset) {
                hash ^= static_cast<uint64_t>(edges[offset]);
                hash *= 1099511628211ULL;
            }
        }
        hash ^= static_cast<uint64_t>(state.descriptor.degree);
        hash *= 1099511628211ULL;
        return hash;
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

    struct TransactionSourceMutations {
        index_t source = 0;
        size_t deletion_begin = 0;
        size_t deletion_count = 0;
        size_t addition_begin = 0;
        size_t addition_count = 0;
    };

    struct DeletionRun {
        index_t destination = 0;
        uint64_t requested = 0;
        uint64_t matched = 0;
        uint64_t removed = 0;
        uint64_t first_match_offset = std::numeric_limits<uint64_t>::max();
    };

    struct PreparedSource {
        index_t source = 0;
        size_t group_index = 0;
        bool expansion = false;
        bool has_deletions = false;
        uint64_t successful_deletes = 0;
        uint64_t final_degree = 0;
        DeletionRun first_deletion;
        std::vector<DeletionRun> remaining_deletions;
        Allocation allocation;
        Block retired_block;
    };

    struct PreparedResult {
        PreparedSource update;
        uint64_t missing_deletes = 0;
        uint64_t invalid_additions = 0;
        int64_t edge_delta = 0;
        bool changed = false;
    };

    struct PreparedTransaction {
        std::vector<TopologyMutation> sorted_deletions;
        std::vector<TopologyMutation> sorted_additions;
        std::vector<index_t> deletion_destinations;
        std::vector<index_t> addition_destinations;
        std::vector<TransactionSourceMutations> groups;
        std::vector<PreparedSource> prepared;
        TopologyMutationBatch effective_batch;
        ChunkStoreBatchMetrics metrics;
        int64_t edge_delta = 0;
        Clock::time_point mutation_begin;
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
        if (prepared_transaction_) {
            throw std::logic_error("commit prepared chunk-store transaction first");
        }
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

    static DeletionRun *FindDeletionRun(
            PreparedSource &update,
            index_t destination) {
        if (!update.has_deletions) return nullptr;
        if (update.first_deletion.destination == destination) {
            return &update.first_deletion;
        }
        const auto found = std::lower_bound(
            update.remaining_deletions.begin(),
            update.remaining_deletions.end(), destination,
            [](const DeletionRun &run, index_t value) {
                return run.destination < value;
            });
        return found != update.remaining_deletions.end() &&
                found->destination == destination
            ? &*found
            : nullptr;
    }

    void BuildDeletionPlan(index_t source,
                           const std::vector<index_t> &deletions,
                           PreparedSource &update) const {
        BuildDeletionPlan(source, deletions.data(), deletions.size(), update);
    }

    void BuildDeletionPlan(index_t source,
                           const index_t *deletions,
                           size_t deletion_count,
                           PreparedSource &update) const {
        if (deletion_count == 0) return;
        update.has_deletions = true;
        const SourceState &state = Source(source);
        const index_t *edges = state.descriptor.degree == 0
            ? nullptr
            : slabs_.at(state.descriptor.slab_id).data + state.descriptor.index;
        if (deletion_count == 1) {
            update.first_deletion = {deletions[0], 1, 0, 0};
            if (state.descriptor.degree != 0) {
                const index_t *found = std::find(
                    edges, edges + state.descriptor.degree,
                    deletions[0]);
                if (found != edges + state.descriptor.degree) {
                    update.first_deletion.matched = 1;
                    update.first_deletion.first_match_offset = found - edges;
                    update.successful_deletes = 1;
                }
            }
            return;
        } else {
            std::vector<index_t> sorted;
            sorted.reserve(deletion_count);
            for (size_t i = 0; i < deletion_count; ++i) {
                sorted.push_back(deletions[i]);
            }
            std::sort(sorted.begin(), sorted.end());
            update.first_deletion = {sorted.front(), 1, 0, 0};
            update.remaining_deletions.reserve(sorted.size() - 1);
            for (size_t i = 1; i < sorted.size(); ++i) {
                const index_t destination = sorted[i];
                if (destination == update.first_deletion.destination) {
                    ++update.first_deletion.requested;
                } else if (update.remaining_deletions.empty() ||
                           update.remaining_deletions.back().destination !=
                               destination) {
                    update.remaining_deletions.push_back(
                        {destination, 1, 0, 0});
                } else {
                    ++update.remaining_deletions.back().requested;
                }
            }
        }

        for (uint64_t offset = 0; offset < state.descriptor.degree; ++offset) {
            DeletionRun *run = FindDeletionRun(update, edges[offset]);
            if (run != nullptr && run->matched < run->requested) {
                if (run->matched == 0) run->first_match_offset = offset;
                ++run->matched;
                ++update.successful_deletes;
                if (update.successful_deletes == deletion_count) break;
            }
        }
    }

    static bool ShouldDelete(PreparedSource &update,
                             index_t destination) {
        DeletionRun *run = FindDeletionRun(update, destination);
        if (run == nullptr || run->removed == run->matched) return false;
        ++run->removed;
        return true;
    }

    static void AppendEffectiveDeletions(
            const PreparedSource &update,
            std::vector<TopologyMutation> &deletions) {
        if (!update.has_deletions) return;
        for (uint64_t occurrence = 0;
             occurrence < update.first_deletion.matched; ++occurrence) {
            deletions.push_back(
                {update.source, update.first_deletion.destination});
        }
        for (const auto &run : update.remaining_deletions) {
            for (uint64_t occurrence = 0; occurrence < run.matched; ++occurrence) {
                deletions.push_back({update.source, run.destination});
            }
        }
    }

    void CompactSourceInPlace(PreparedSource &update,
                              const SourceMutations &mutations,
                              ChunkStoreBatchMetrics &metrics) {
        SourceState &state = Source(update.source);
        index_t *edges = state.block.capacity == 0 ? nullptr : BlockData(state.block);
        const uint64_t old_degree = state.descriptor.degree;
        uint64_t write_offset = old_degree;
        if (update.successful_deletes == 1 &&
            update.first_deletion.requested == 1 &&
            update.remaining_deletions.empty()) {
            const uint64_t deleted_offset =
                update.first_deletion.first_match_offset;
            const uint64_t trailing = old_degree - deleted_offset - 1;
            if (trailing != 0) {
                std::memmove(edges + deleted_offset, edges + deleted_offset + 1,
                             trailing * sizeof(index_t));
                metrics.mutation_written_bytes += trailing * sizeof(index_t);
            }
            write_offset = old_degree - 1;
            update.first_deletion.removed = 1;
        } else if (update.successful_deletes != 0) {
            write_offset = 0;
            for (uint64_t read_offset = 0; read_offset < old_degree;
                 ++read_offset) {
                const index_t destination = edges[read_offset];
                if (ShouldDelete(update, destination)) continue;
                if (write_offset != read_offset) {
                    edges[write_offset] = destination;
                    metrics.mutation_written_bytes += sizeof(index_t);
                }
                ++write_offset;
            }
        }
        if (!mutations.additions.empty()) {
            std::memcpy(edges + write_offset, mutations.additions.data(),
                        mutations.additions.size() * sizeof(index_t));
            metrics.mutation_written_bytes +=
                mutations.additions.size() * sizeof(index_t);
            write_offset += mutations.additions.size();
        }
        if (write_offset != update.final_degree) {
            throw std::logic_error("source compaction degree mismatch");
        }
        state.descriptor.degree = static_cast<index_t>(write_offset);
        state.descriptor.version = static_cast<uint32_t>(pending_epoch_);
    }

    void RewriteSourceToNewBlock(PreparedSource &update,
                                 const SourceMutations &mutations,
                                 ChunkStoreBatchMetrics &metrics) {
        SourceState &state = Source(update.source);
        const Allocation &allocation = update.allocation;

        const index_t *old_edges = state.descriptor.degree == 0
            ? nullptr
            : BlockData(state.block);
        index_t *new_edges = BlockData(allocation.block);
        uint64_t write_offset = state.descriptor.degree;
        if (update.successful_deletes == 0) {
            if (write_offset != 0) {
                std::memcpy(new_edges, old_edges,
                            write_offset * sizeof(index_t));
            }
        } else if (update.successful_deletes == 1 &&
                   update.first_deletion.requested == 1 &&
                   update.remaining_deletions.empty()) {
            const uint64_t deleted_offset =
                update.first_deletion.first_match_offset;
            const uint64_t trailing = state.descriptor.degree -
                deleted_offset - 1;
            if (deleted_offset != 0) {
                std::memcpy(new_edges, old_edges,
                            deleted_offset * sizeof(index_t));
            }
            if (trailing != 0) {
                std::memcpy(new_edges + deleted_offset,
                            old_edges + deleted_offset + 1,
                            trailing * sizeof(index_t));
            }
            --write_offset;
            update.first_deletion.removed = 1;
        } else {
            write_offset = 0;
            for (uint64_t read_offset = 0;
                 read_offset < state.descriptor.degree; ++read_offset) {
                const index_t destination = old_edges[read_offset];
                if (ShouldDelete(update, destination)) continue;
                new_edges[write_offset++] = destination;
            }
        }
        metrics.relocation_copied_bytes += write_offset * sizeof(index_t);
        metrics.mutation_written_bytes += write_offset * sizeof(index_t);
        if (!mutations.additions.empty()) {
            std::memcpy(new_edges + write_offset, mutations.additions.data(),
                        mutations.additions.size() * sizeof(index_t));
            metrics.mutation_written_bytes +=
                mutations.additions.size() * sizeof(index_t);
            write_offset += mutations.additions.size();
        }
        if (write_offset != update.final_degree) {
            throw std::logic_error("source rewrite degree mismatch");
        }
        if (state.block.capacity != 0) {
            update.retired_block = state.block;
        }
        state.block = allocation.block;
        state.descriptor.index = allocation.block.offset;
        state.descriptor.slab_id = allocation.block.slab_id;
        state.descriptor.degree = static_cast<index_t>(write_offset);
        state.descriptor.version = static_cast<uint32_t>(pending_epoch_);
    }

    void MaterializePreparedSource(PreparedSource &update,
                                   const index_t *additions,
                                   size_t addition_count,
                                   ChunkStoreBatchMetrics &metrics) {
        const SourceState &state = Source(update.source);
        const index_t *old_edges = state.descriptor.degree == 0
            ? nullptr
            : BlockData(state.block);
        index_t *new_edges = update.final_degree == 0
            ? nullptr
            : BlockData(update.allocation.block);
        uint64_t write_offset = state.descriptor.degree;
        if (update.successful_deletes == 0) {
            if (write_offset != 0) {
                std::memcpy(new_edges, old_edges,
                            write_offset * sizeof(index_t));
            }
        } else if (update.successful_deletes == 1 &&
                   update.first_deletion.requested == 1 &&
                   update.remaining_deletions.empty()) {
            const uint64_t deleted_offset =
                update.first_deletion.first_match_offset;
            const uint64_t trailing = state.descriptor.degree -
                deleted_offset - 1;
            if (deleted_offset != 0) {
                std::memcpy(new_edges, old_edges,
                            deleted_offset * sizeof(index_t));
            }
            if (trailing != 0) {
                std::memcpy(new_edges + deleted_offset,
                            old_edges + deleted_offset + 1,
                            trailing * sizeof(index_t));
            }
            --write_offset;
            update.first_deletion.removed = 1;
        } else {
            write_offset = 0;
            for (uint64_t read_offset = 0;
                 read_offset < state.descriptor.degree; ++read_offset) {
                const index_t destination = old_edges[read_offset];
                if (ShouldDelete(update, destination)) continue;
                new_edges[write_offset++] = destination;
            }
        }
        metrics.relocation_copied_bytes += write_offset * sizeof(index_t);
        metrics.mutation_written_bytes += write_offset * sizeof(index_t);
        if (addition_count != 0) {
            std::memcpy(new_edges + write_offset, additions,
                        addition_count * sizeof(index_t));
            metrics.mutation_written_bytes += addition_count * sizeof(index_t);
            write_offset += addition_count;
        }
        if (write_offset != update.final_degree) {
            throw std::logic_error("prepared source degree mismatch");
        }
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
    std::unique_ptr<concurrency::FixedWorkerPool> mutation_workers_;
    std::unique_ptr<PreparedTransaction> prepared_transaction_;
};

} // namespace topology
} // namespace sepgraph

#endif // SEPGRAPH_SOURCE_LOCAL_CHUNK_STORE_H
