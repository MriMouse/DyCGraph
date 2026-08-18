#ifndef SEPGRAPH_DESTINATION_LOCAL_DEPENDENCY_STORE_H
#define SEPGRAPH_DESTINATION_LOCAL_DEPENDENCY_STORE_H

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

#include <cuda_runtime_api.h>

#include <framework/topology_replay.h>

namespace sepgraph { namespace runtime {

struct DependencyChunkOptions {
    uint64_t capacity_edges = 0;
    uint64_t slab_capacity_edges = 1ULL << 24;
    uint32_t growth_numerator = 5;
    uint32_t growth_denominator = 4;
    uint32_t growth_alignment_edges = 8;
    bool pinned = true;
};

struct DependencyChunkDescriptor {
    uint64_t offset = 0;
    uint32_t degree = 0;
    uint32_t capacity = 0;
    uint32_t slab_id = std::numeric_limits<uint32_t>::max();
    uint32_t version = 0;
};

static_assert(sizeof(DependencyChunkDescriptor) == 24,
              "dependency descriptor is a mapped ABI");

struct DependencyChunkMetrics {
    uint64_t epoch = 0;
    uint64_t touched_destinations = 0;
    uint64_t scanned_incoming_edges = 0;
    uint64_t written_edges = 0;
    uint64_t relocation_edges = 0;
    uint64_t missing_deletes = 0;
    uint64_t allocations = 0;
    uint64_t reused_blocks = 0;
    uint64_t retired_blocks = 0;
    double plan_ms = 0.0;
    double commit_ms = 0.0;
};

struct DependencyMemoryModel {
    uint64_t logical_edges = 0;
    uint64_t live_capacity_edges = 0;
    uint64_t retired_capacity_edges = 0;
    uint64_t arena_capacity_edges = 0;
    uint64_t descriptor_bytes = 0;
    uint64_t resident_bytes = 0;
    double live_amplification = 0.0;
};

class DestinationLocalDependencyStore {
public:
    static constexpr uint32_t kInvalidSlab =
        std::numeric_limits<uint32_t>::max();

    DestinationLocalDependencyStore(index_t node_count,
                                    DependencyChunkOptions options)
        : states_(node_count), options_(options) {
        if (options_.capacity_edges == 0 ||
            options_.slab_capacity_edges == 0 ||
            options_.growth_denominator == 0 ||
            options_.growth_numerator <= options_.growth_denominator ||
            options_.growth_alignment_edges == 0) {
            throw std::invalid_argument("invalid dependency chunk options");
        }
        uint64_t remaining = options_.capacity_edges;
        try {
            AllocateDescriptors(node_count);
            while (remaining != 0) {
                const uint64_t capacity =
                    std::min(remaining, options_.slab_capacity_edges);
                slabs_.push_back(AllocateSlab(capacity));
                remaining -= capacity;
            }
        } catch (...) {
            Release();
            throw;
        }
    }

    ~DestinationLocalDependencyStore() { Release(); }
    DestinationLocalDependencyStore(const DestinationLocalDependencyStore &) = delete;
    DestinationLocalDependencyStore &operator=(
        const DestinationLocalDependencyStore &) = delete;

    // Static topology is exact-sized. Slack is introduced only after a
    // destination actually expands under streaming updates.
    void LoadDestination(index_t destination,
                         const std::vector<index_t> &sources) {
        EnsureNoPendingBatch();
        State &state = StateAt(destination);
        if (state.loaded) throw std::logic_error("destination already loaded");
        state.loaded = true;
        if (!sources.empty()) {
            const Allocation allocation = Allocate(sources.size());
            std::memcpy(Data(allocation.block), sources.data(),
                        sources.size() * sizeof(index_t));
            state.block = allocation.block;
            descriptors_[destination] = {allocation.block.offset,
                static_cast<uint32_t>(sources.size()),
                static_cast<uint32_t>(allocation.block.capacity),
                allocation.block.slab_id, 0};
            live_capacity_edges_ += allocation.block.capacity;
        }
        logical_edges_ += sources.size();
    }

    void FinalizeLoad(uint64_t expected_edges =
            std::numeric_limits<uint64_t>::max()) {
        EnsureNoPendingBatch();
        for (const State &state : states_) {
            if (!state.loaded) throw std::logic_error("destination not loaded");
        }
        if (expected_edges != std::numeric_limits<uint64_t>::max() &&
            expected_edges != logical_edges_) {
            throw std::invalid_argument("dependency edge count mismatch");
        }
    }

    static uint64_t ExpandedCapacity(uint64_t old_capacity,
                                     uint64_t required,
                                     const DependencyChunkOptions &options) {
        if (required <= old_capacity) return old_capacity;
        if (old_capacity == 0) return required;
        const uint64_t grown =
            (old_capacity * options.growth_numerator +
             options.growth_denominator - 1) / options.growth_denominator;
        uint64_t capacity = std::max(required, grown);
        const uint64_t alignment = options.growth_alignment_edges;
        capacity = ((capacity + alignment - 1) / alignment) * alignment;
        if (capacity > std::numeric_limits<uint32_t>::max()) {
            throw std::overflow_error("dependency chunk exceeds uint32 capacity");
        }
        return capacity;
    }

    DependencyChunkMetrics ApplyBatch(
            const topology::TopologyMutationBatch &batch) {
        PrepareBatch(batch);
        DependencyChunkMetrics metrics = ApplyPreparedDeletions();
        const DependencyChunkMetrics additions = ApplyPreparedAdditions();
        AccumulateCommitMetrics(metrics, additions);
        return metrics;
    }

    DependencyChunkMetrics PrepareBatch(
            const topology::TopologyMutationBatch &batch) {
        EnsureNoPendingBatch();
        const auto plan_begin = Clock::now();
        std::unordered_map<index_t, Mutations> grouped;
        grouped.reserve(batch.deletions.size() + batch.additions.size());
        for (const auto &mutation : batch.deletions) {
            CheckMutation(mutation);
            grouped[mutation.destination].deletions.push_back(mutation.source);
        }
        for (const auto &mutation : batch.additions) {
            CheckMutation(mutation);
            grouped[mutation.destination].additions.push_back(mutation.source);
        }

        DependencyChunkMetrics metrics;
        metrics.epoch = published_epoch_ + 1;
        if (metrics.epoch > std::numeric_limits<uint32_t>::max())
            throw std::overflow_error("dependency epoch exhausted");
        std::vector<std::pair<index_t, Mutations *>> work;
        work.reserve(grouped.size());
        for (auto &entry : grouped) work.push_back({entry.first, &entry.second});
        prepared_.clear();
        prepared_.resize(work.size());
        std::atomic<size_t> next_work{0};
        std::atomic<uint64_t> scanned_edges{0};
        std::atomic<uint64_t> missing_deletes{0};
        const uint32_t hardware_workers = std::thread::hardware_concurrency();
        const uint32_t worker_count = std::max<uint32_t>(1,
            std::min<uint32_t>(20, std::min<size_t>(
                work.size(), hardware_workers == 0 ? 1 : hardware_workers)));
        std::vector<std::thread> workers;
        workers.reserve(worker_count);
        for (uint32_t worker = 0; worker < worker_count; ++worker) {
            workers.emplace_back([&]() {
                for (;;) {
                    const size_t work_index = next_work.fetch_add(1);
                    if (work_index >= work.size()) break;
                    const index_t destination = work[work_index].first;
                    Mutations &mutations = *work[work_index].second;
                    const State &state = StateAt(destination);
                    Prepared update;
                    update.destination = destination;
                    update.additions = std::move(mutations.additions);
                    const uint32_t old_degree = descriptors_[destination].degree;
                    uint64_t local_scanned = 0;
                    uint64_t local_missing = 0;
                    if (!mutations.deletions.empty()) {
                        const index_t *sources = Data(state.block);
                        std::vector<uint8_t> matched(
                            mutations.deletions.size(), 0);
                        for (uint32_t position = 0; position < old_degree;
                             ++position) {
                            for (size_t deletion = 0;
                                 deletion < mutations.deletions.size();
                                 ++deletion) {
                                if (!matched[deletion] &&
                                    sources[position] ==
                                        mutations.deletions[deletion]) {
                                    matched[deletion] = 1;
                                    update.deletion_positions.push_back(position);
                                    break;
                                }
                            }
                        }
                        local_scanned += old_degree;
                        local_missing += mutations.deletions.size() -
                            update.deletion_positions.size();
                    }
                    std::sort(update.deletion_positions.rbegin(),
                              update.deletion_positions.rend());
                    update.deleted_degree = old_degree -
                        update.deletion_positions.size();
                    update.final_degree = update.deleted_degree +
                        update.additions.size();
                    update.capacity = ExpandedCapacity(
                        state.block.capacity, update.final_degree, options_);
                    update.expands = update.capacity > state.block.capacity;
                    update.has_deletions = !update.deletion_positions.empty();
                    update.has_additions = !update.additions.empty();
                    prepared_[work_index] = std::move(update);
                    scanned_edges.fetch_add(local_scanned,
                                            std::memory_order_relaxed);
                    missing_deletes.fetch_add(local_missing,
                                              std::memory_order_relaxed);
                }
            });
        }
        for (auto &worker : workers) worker.join();
        metrics.scanned_incoming_edges = scanned_edges.load();
        metrics.missing_deletes = missing_deletes.load();
        std::vector<uint64_t> allocations;
        for (const Prepared &update : prepared_) {
            if (update.expands && update.capacity != 0)
                allocations.push_back(update.capacity);
        }
        EnsureFit(allocations);
        metrics.touched_destinations = prepared_.size();
        metrics.plan_ms = Milliseconds(plan_begin, Clock::now());
        pending_epoch_ = metrics.epoch;
        pending_ = true;
        phase_ = PendingPhase::kPrepared;
        prepared_metrics_ = metrics;
        return metrics;
    }

    DependencyChunkMetrics ApplyPreparedDeletions() {
        EnsurePhase(PendingPhase::kPrepared, "dependency batch is not prepared");
        DependencyChunkMetrics metrics = prepared_metrics_;
        const auto commit_begin = Clock::now();
        for (Prepared &update : prepared_) {
            if (!update.has_deletions) continue;
            const uint64_t old_degree = descriptors_[update.destination].degree;
            index_t *sources = Data(StateAt(update.destination).block);
            uint32_t degree = static_cast<uint32_t>(old_degree);
            for (const uint32_t position : update.deletion_positions) {
                --degree;
                if (position != degree) sources[position] = sources[degree];
            }
            logical_edges_ -= update.deletion_positions.size();
            metrics.written_edges += update.deletion_positions.size();
            WriteDescriptor(update.destination, update.deleted_degree);
        }
        metrics.commit_ms = Milliseconds(commit_begin, Clock::now());
        phase_ = PendingPhase::kDeletionsApplied;
        return metrics;
    }

    DependencyChunkMetrics ApplyPreparedAdditions() {
        EnsurePhase(PendingPhase::kDeletionsApplied,
                    "prepared dependency deletions are not applied");
        DependencyChunkMetrics metrics;
        metrics.epoch = pending_epoch_;
        const auto commit_begin = Clock::now();
        for (Prepared &update : prepared_) {
            if (!update.has_additions) continue;
            State &state = StateAt(update.destination);
            const uint64_t old_degree = descriptors_[update.destination].degree;
            if (update.expands) {
                const Allocation allocation = Allocate(update.capacity);
                index_t *output = Data(allocation.block);
                if (old_degree != 0) {
                    std::memcpy(output, Data(state.block),
                                old_degree * sizeof(index_t));
                }
                std::copy(update.additions.begin(), update.additions.end(),
                          output + old_degree);
                metrics.relocation_edges += old_degree;
                ++metrics.allocations;
                metrics.reused_blocks += allocation.reused ? 1 : 0;
                if (state.block.capacity != 0) {
                    Retire(state.block, metrics.epoch);
                    ++metrics.retired_blocks;
                }
                state.block = allocation.block;
                live_capacity_edges_ += allocation.block.capacity;
            } else {
                std::copy(update.additions.begin(), update.additions.end(),
                          Data(state.block) + old_degree);
            }
            logical_edges_ += update.additions.size();
            metrics.written_edges += update.additions.size();
            WriteDescriptor(update.destination, update.final_degree);
        }
        metrics.commit_ms = Milliseconds(commit_begin, Clock::now());
        phase_ = PendingPhase::kAdditionsApplied;
        return metrics;
    }

    uint64_t Publish() {
        if (!pending_) throw std::logic_error("no pending dependency batch");
        EnsurePhase(PendingPhase::kAdditionsApplied,
                    "dependency additions are not applied");
        published_epoch_ = pending_epoch_;
        pending_ = false;
        phase_ = PendingPhase::kNone;
        prepared_.clear();
        return published_epoch_;
    }

    uint64_t ReclaimThrough(uint64_t completed_epoch) {
        EnsureNoPendingBatch();
        uint64_t reclaimed = 0;
        auto output = retired_.begin();
        for (auto current = retired_.begin(); current != retired_.end(); ++current) {
            if (current->epoch <= completed_epoch) {
                free_[current->block.capacity].push_back(current->block);
                retired_capacity_edges_ -= current->block.capacity;
                ++reclaimed;
            } else *output++ = *current;
        }
        retired_.erase(output, retired_.end());
        return reclaimed;
    }

    std::vector<index_t> Sources(index_t destination) const {
        const State &state = StateAt(destination);
        if (!state.loaded) throw std::logic_error("destination not loaded");
        if (descriptors_[destination].degree == 0) return {};
        const index_t *begin = slabs_.at(state.block.slab_id).data + state.block.offset;
        return {begin, begin + descriptors_[destination].degree};
    }

    const DependencyChunkDescriptor &Descriptor(index_t destination) const {
        StateAt(destination);
        return descriptors_[destination];
    }
    const DependencyChunkDescriptor *MappedDescriptorDeviceData() const {
        return device_descriptors_;
    }
    index_t *MappedSlabDeviceData(uint32_t slab) const {
        if (!options_.pinned) return nullptr;
        index_t *device = nullptr;
        const cudaError_t status = cudaHostGetDevicePointer(
            reinterpret_cast<void **>(&device), slabs_.at(slab).data, 0);
        if (status != cudaSuccess) throw std::runtime_error(
            std::string("dependency slab mapping: ") + cudaGetErrorString(status));
        return device;
    }
    const index_t *SlabData(uint32_t slab) const { return slabs_.at(slab).data; }
    size_t SlabCount() const { return slabs_.size(); }
    uint64_t PublishedEpoch() const { return published_epoch_; }
    bool HasPendingBatch() const { return pending_; }
    bool DeletionsApplied() const {
        return phase_ == PendingPhase::kDeletionsApplied ||
               phase_ == PendingPhase::kAdditionsApplied;
    }

    DependencyMemoryModel MemoryModel() const {
        DependencyMemoryModel model;
        model.logical_edges = logical_edges_;
        model.live_capacity_edges = live_capacity_edges_;
        model.retired_capacity_edges = retired_capacity_edges_;
        model.arena_capacity_edges = options_.capacity_edges;
        model.descriptor_bytes = states_.size() * sizeof(DependencyChunkDescriptor);
        model.resident_bytes = options_.capacity_edges * sizeof(index_t) +
                               model.descriptor_bytes;
        model.live_amplification = logical_edges_ == 0 ? 1.0 :
            static_cast<double>(live_capacity_edges_) / logical_edges_;
        return model;
    }

private:
    using Clock = std::chrono::steady_clock;
    struct Block { uint32_t slab_id = kInvalidSlab; uint64_t offset = 0, capacity = 0; };
    struct Slab { index_t *data = nullptr; uint64_t capacity = 0, bump = 0; };
    struct Allocation { Block block; bool reused = false; };
    struct Retired { Block block; uint64_t epoch = 0; };
    struct State { Block block; bool loaded = false; };
    struct Mutations { std::vector<index_t> deletions, additions; };
    struct Prepared {
        index_t destination = 0;
        std::vector<uint32_t> deletion_positions;
        std::vector<index_t> additions;
        uint32_t deleted_degree = 0;
        uint32_t final_degree = 0;
        uint64_t capacity = 0;
        bool expands = false;
        bool has_deletions = false;
        bool has_additions = false;
    };
    enum class PendingPhase { kNone, kPrepared, kDeletionsApplied,
                              kAdditionsApplied };

    static double Milliseconds(Clock::time_point begin, Clock::time_point end) {
        return std::chrono::duration<double, std::milli>(end - begin).count();
    }
    void CheckMutation(const topology::TopologyMutation &mutation) const {
        if (mutation.source >= states_.size() || mutation.destination >= states_.size())
            throw std::out_of_range("dependency mutation vertex");
    }
    State &StateAt(index_t destination) {
        if (destination >= states_.size()) throw std::out_of_range("destination");
        return states_[destination];
    }
    const State &StateAt(index_t destination) const {
        if (destination >= states_.size()) throw std::out_of_range("destination");
        return states_[destination];
    }
    void EnsureNoPendingBatch() const {
        if (pending_) throw std::logic_error("publish pending dependency batch");
    }
    void EnsurePhase(PendingPhase expected, const char *message) const {
        if (!pending_ || phase_ != expected) throw std::logic_error(message);
    }
    void WriteDescriptor(index_t destination, uint64_t degree) {
        const State &state = StateAt(destination);
        descriptors_[destination] = {state.block.offset,
            static_cast<uint32_t>(degree),
            static_cast<uint32_t>(state.block.capacity), state.block.slab_id,
            static_cast<uint32_t>(pending_epoch_)};
    }
    static void AccumulateCommitMetrics(DependencyChunkMetrics &target,
                                        const DependencyChunkMetrics &source) {
        target.written_edges += source.written_edges;
        target.relocation_edges += source.relocation_edges;
        target.allocations += source.allocations;
        target.reused_blocks += source.reused_blocks;
        target.retired_blocks += source.retired_blocks;
        target.commit_ms += source.commit_ms;
    }
    Slab AllocateSlab(uint64_t capacity) {
        Slab slab; slab.capacity = capacity;
        if (options_.pinned) {
            const cudaError_t status = cudaHostAlloc(
                reinterpret_cast<void **>(&slab.data), capacity * sizeof(index_t),
                cudaHostAllocMapped | cudaHostAllocPortable);
            if (status != cudaSuccess) throw std::runtime_error(
                std::string("dependency slab allocation: ") + cudaGetErrorString(status));
        } else slab.data = new index_t[capacity];
        return slab;
    }
    void AllocateDescriptors(index_t count) {
        const size_t entries = std::max<index_t>(count, 1);
        if (options_.pinned) {
            const cudaError_t status = cudaHostAlloc(
                reinterpret_cast<void **>(&descriptors_),
                entries * sizeof(*descriptors_),
                cudaHostAllocMapped | cudaHostAllocPortable);
            if (status != cudaSuccess) throw std::runtime_error(
                std::string("dependency descriptor allocation: ") +
                cudaGetErrorString(status));
            const cudaError_t mapped = cudaHostGetDevicePointer(
                reinterpret_cast<void **>(&device_descriptors_), descriptors_, 0);
            if (mapped != cudaSuccess) throw std::runtime_error(
                std::string("dependency descriptor mapping: ") +
                cudaGetErrorString(mapped));
        } else descriptors_ = new DependencyChunkDescriptor[entries];
        std::fill(descriptors_, descriptors_ + entries,
                  DependencyChunkDescriptor{});
    }
    void Release() {
        for (Slab &slab : slabs_) {
            if (options_.pinned) cudaFreeHost(slab.data); else delete[] slab.data;
        }
        slabs_.clear();
        if (descriptors_ != nullptr) {
            if (options_.pinned) cudaFreeHost(descriptors_);
            else delete[] descriptors_;
        }
        descriptors_ = nullptr;
        device_descriptors_ = nullptr;
    }
    index_t *Data(const Block &block) {
        return slabs_.at(block.slab_id).data + block.offset;
    }
    void EnsureFit(const std::vector<uint64_t> &capacities) const {
        std::unordered_map<uint64_t, size_t> free_counts;
        for (const auto &entry : free_) free_counts[entry.first] = entry.second.size();
        std::vector<uint64_t> remaining;
        for (const Slab &slab : slabs_) remaining.push_back(slab.capacity - slab.bump);
        for (uint64_t capacity : capacities) {
            auto found = free_counts.find(capacity);
            if (found != free_counts.end() && found->second != 0) {
                --found->second; continue;
            }
            bool fits = false;
            for (uint64_t &space : remaining) {
                if (capacity <= space) { space -= capacity; fits = true; break; }
            }
            if (!fits) throw std::runtime_error("dependency chunk arena exhausted");
        }
    }
    Allocation Allocate(uint64_t capacity) {
        auto reusable = free_.find(capacity);
        if (reusable != free_.end() && !reusable->second.empty()) {
            Block block = reusable->second.back(); reusable->second.pop_back();
            return {block, true};
        }
        for (uint32_t slab_id = 0; slab_id < slabs_.size(); ++slab_id) {
            Slab &slab = slabs_[slab_id];
            if (capacity <= slab.capacity - slab.bump) {
                Block block{slab_id, slab.bump, capacity};
                slab.bump += capacity;
                return {block, false};
            }
        }
        throw std::runtime_error("dependency chunk arena exhausted");
    }
    void Retire(Block block, uint64_t epoch) {
        retired_.push_back({block, epoch});
        live_capacity_edges_ -= block.capacity;
        retired_capacity_edges_ += block.capacity;
    }

    std::vector<State> states_;
    DependencyChunkDescriptor *descriptors_ = nullptr;
    DependencyChunkDescriptor *device_descriptors_ = nullptr;
    DependencyChunkOptions options_;
    std::vector<Slab> slabs_;
    std::unordered_map<uint64_t, std::vector<Block>> free_;
    std::vector<Retired> retired_;
    std::vector<Prepared> prepared_;
    DependencyChunkMetrics prepared_metrics_;
    uint64_t logical_edges_ = 0;
    uint64_t live_capacity_edges_ = 0;
    uint64_t retired_capacity_edges_ = 0;
    uint64_t published_epoch_ = 0;
    uint64_t pending_epoch_ = 0;
    bool pending_ = false;
    PendingPhase phase_ = PendingPhase::kNone;
};

} }
#endif
