#ifndef SEPGRAPH_EFFECTIVE_UPDATE_BATCH_H
#define SEPGRAPH_EFFECTIVE_UPDATE_BATCH_H

#include <algorithm>
#include <array>
#include <cstdlib>
#include <chrono>
#include <string>
#include <stdexcept>
#include <vector>
#include <framework/topology_replay.h>
#include <utils/fixed_worker_pool.h>

namespace sepgraph {
namespace topology {

enum class UpdatePhase { Mixed, Delete, Add };

struct DestinationRange {
    const index_t *first = nullptr;
    size_t count = 0;
    const index_t *begin() const { return first; }
    const index_t *end() const { return count ? first + count : first; }
    const index_t *data() const { return first; }
    size_t size() const { return count; }
    bool empty() const { return count == 0; }
    index_t front() const { return *first; }
};

struct SourceMutationView {
    DestinationRange deletions;
    DestinationRange additions;
};

// One source ordering for both phases; stable order preserves append semantics.
class GroupedUpdateBatch {
public:
    explicit GroupedUpdateBatch(const TopologyMutationBatch &batch = {},
                                concurrency::FixedWorkerPool* workers = nullptr) {
        const char *setting = std::getenv("CG_BATCH_MAINTENANCE");
        const std::string mode = setting ? setting : "regular";
        if (mode != "regular" && mode != "large" && mode != "auto")
            throw std::invalid_argument("CG_BATCH_MAINTENANCE must be regular, large or auto");
        large_ = mode == "large" || (mode == "auto" &&
            batch.deletions.size() + batch.additions.size() >= 1000000);
        const char *positions = std::getenv("CG_REUSE_DELETE_POSITIONS");
        if (positions && std::string(positions) != "0" && std::string(positions) != "1")
            throw std::invalid_argument("CG_REUSE_DELETE_POSITIONS must be 0 or 1");
        reuse_delete_positions_ = large_ && positions && std::string(positions) == "1";
        const char* parallel = std::getenv("CG_PARALLEL_SOURCE_RADIX");
        if (parallel && std::string(parallel) != "0" && std::string(parallel) != "1")
            throw std::invalid_argument("CG_PARALLEL_SOURCE_RADIX must be 0 or 1");
        parallel_radix_ = workers && workers->WorkerCount() > 1 && parallel &&
            std::string(parallel) == "1" &&
            batch.deletions.size() + batch.additions.size() >= 4096;
        const char* bulk = std::getenv("CG_BULK_SOURCE_GROUPS");
        if (bulk && std::string(bulk) != "0" && std::string(bulk) != "1")
            throw std::invalid_argument("CG_BULK_SOURCE_GROUPS must be 0 or 1");
        bulk_groups_ = workers && workers->WorkerCount() > 1 && bulk &&
            std::string(bulk) == "1" &&
            batch.deletions.size() + batch.additions.size() >= 4096;
        using Clock = std::chrono::steady_clock;
        auto start = Clock::now();
        const auto elapsed = [&]() {
            return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
        };
        struct Record { index_t source, destination; bool addition; };
        std::vector<Record> records;
        records.reserve(batch.deletions.size() + batch.additions.size());
        for (const auto &edge : batch.deletions)
            records.push_back({edge.source, edge.destination, false});
        for (const auto &edge : batch.additions)
            records.push_back({edge.source, edge.destination, true});
        record_ms_ = elapsed();
        start = Clock::now();
        if (records.size() < 4096) {
            std::stable_sort(records.begin(), records.end(),
                [](const Record &a, const Record &b) { return a.source < b.source; });
        } else {
            static_assert(sizeof(index_t) == sizeof(uint32_t), "source radix requires 32-bit IDs");
            std::vector<Record> scratch(records.size());
            // Stable passes preserve input order within each source, including
            // duplicate destinations and the delete-before-add boundary.
            const size_t partitions = parallel_radix_ ? workers->WorkerCount() : 0;
            std::vector<std::array<size_t, 256>> histograms(partitions);
            for (unsigned shift = 0; shift < 32; shift += 8) {
                if (parallel_radix_) {
                    // Contiguous logical partitions, independent of worker scheduling.
                    // Bucket prefixes follow partition order to preserve stability.
                    workers->Run(partitions, [&](size_t part) {
                        auto& counts = histograms[part];
                        counts.fill(0);
                        for (size_t i = records.size() * part / partitions;
                             i < records.size() * (part + 1) / partitions; ++i)
                            ++counts[(records[i].source >> shift) & 255U];
                    }, 1);
                    size_t offset = 0;
                    for (size_t bucket = 0; bucket < 256; ++bucket)
                        for (size_t part = 0; part < partitions; ++part) {
                            const size_t count = histograms[part][bucket];
                            histograms[part][bucket] = offset;
                            offset += count;
                        }
                    workers->Run(partitions, [&](size_t part) {
                        auto& offsets = histograms[part];
                        for (size_t i = records.size() * part / partitions;
                             i < records.size() * (part + 1) / partitions; ++i) {
                            const auto& record = records[i];
                            scratch[offsets[(record.source >> shift) & 255U]++] = record;
                        }
                    }, 1);
                    records.swap(scratch);
                    continue;
                }
                std::array<size_t, 256> offsets{};
                for (const auto &record : records) ++offsets[(record.source >> shift) & 255U];
                size_t total = 0;
                for (auto &offset : offsets) {
                    const size_t count = offset;
                    offset = total;
                    total += count;
                }
                for (const auto &record : records)
                    scratch[offsets[(record.source >> shift) & 255U]++] = record;
                records.swap(scratch);
            }
        }
        sort_ms_ = elapsed();
        start = Clock::now();
        if (bulk_groups_) {
            const size_t parts = workers->WorkerCount();
            std::vector<size_t> offsets(parts + 1, 0);
            workers->Run(parts, [&](size_t p) {
                size_t count = 0;
                for (size_t i = records.size() * p / parts;
                     i < records.size() * (p + 1) / parts; ++i)
                    count += i == 0 || records[i - 1].source != records[i].source;
                offsets[p + 1] = count;
            }, 1);
            for (size_t p = 0; p < parts; ++p) offsets[p + 1] += offsets[p];
            sources.resize(offsets.back());
            groups_.resize(offsets.back());
            destinations_.resize(records.size());
            workers->Run(parts, [&](size_t p) {
                size_t group = offsets[p];
                for (size_t i = records.size() * p / parts;
                     i < records.size() * (p + 1) / parts; ++i) {
                    destinations_[i] = records[i].destination;
                    if (i == 0 || records[i - 1].source != records[i].source) {
                        sources[group] = records[i].source;
                        groups_[group++].offset = i;
                    }
                }
            }, 1);
            // A record partition can split a source. Only the group owner counts
            // its complete range after all offsets are visible.
            std::vector<size_t> dels(parts + 1, 0), adds(parts + 1, 0);
            workers->Run(parts, [&](size_t p) {
                size_t nd = 0, na = 0;
                for (size_t g = groups_.size() * p / parts;
                     g < groups_.size() * (p + 1) / parts; ++g) {
                    auto& group = groups_[g];
                    const size_t end = g + 1 < groups_.size() ? groups_[g + 1].offset : records.size();
                    // Stable sorting places deletions before additions.
                    const auto first_add = std::partition_point(records.begin() + group.offset,
                        records.begin() + end, [](const Record& r) { return !r.addition; });
                    group.deletes = first_add - (records.begin() + group.offset);
                    group.adds = end - group.offset - group.deletes;
                    nd += group.deletes != 0;
                    na += group.adds != 0;
                }
                dels[p + 1] = nd;
                adds[p + 1] = na;
            }, 1);
            for (size_t p = 0; p < parts; ++p) {
                dels[p + 1] += dels[p];
                adds[p + 1] += adds[p];
            }
            delete_indices_.resize(dels.back());
            add_indices_.resize(adds.back());
            workers->Run(parts, [&](size_t p) {
                size_t d = dels[p], a = adds[p];
                for (size_t g = groups_.size() * p / parts;
                     g < groups_.size() * (p + 1) / parts; ++g) {
                    if (groups_[g].deletes) delete_indices_[d++] = g;
                    if (groups_[g].adds) add_indices_[a++] = g;
                }
            }, 1);
            materialize_ms_ = elapsed();
            return;
        }
        destinations_.reserve(records.size());
        for (const auto &record : records) {
            if (sources.empty() || sources.back() != record.source) {
                sources.push_back(record.source);
                groups_.push_back({destinations_.size(), 0, 0});
            }
            destinations_.push_back(record.destination);
            if (record.addition) ++groups_.back().adds;
            else ++groups_.back().deletes;
        }
        for (size_t i = 0; i < groups_.size(); ++i) {
            if (groups_[i].deletes) delete_indices_.push_back(i);
            if (groups_[i].adds) add_indices_.push_back(i);
        }
        materialize_ms_ = elapsed();
    }

    bool BulkSourceGroups() const { return bulk_groups_; }
    double RecordMs() const { return record_ms_; }
    double SortMs() const { return sort_ms_; }
    double MaterializeMs() const { return materialize_ms_; }

    SourceMutationView View(size_t i, UpdatePhase phase) const {
        const auto &group = groups_[i];
        const auto *data = destinations_.data() + group.offset;
        return {{data, phase == UpdatePhase::Add ? 0 : group.deletes},
                {data + group.deletes, phase == UpdatePhase::Delete ? 0 : group.adds}};
    }

    size_t PhaseSize(UpdatePhase phase) const {
        return phase == UpdatePhase::Mixed ? sources.size()
            : (phase == UpdatePhase::Delete ? delete_indices_.size() : add_indices_.size());
    }
    size_t SourceIndex(size_t i, UpdatePhase phase) const {
        return phase == UpdatePhase::Mixed ? i
            : (phase == UpdatePhase::Delete ? delete_indices_[i] : add_indices_[i]);
    }

    bool ParallelSourceRadix() const { return parallel_radix_; }
    bool LargeMaintenance() const { return large_; }
    bool ReuseDeletePositions() const { return reuse_delete_positions_; }
    size_t RequestCount() const { return destinations_.size(); }
    size_t DestinationOffset(size_t i) const { return groups_[i].offset; }

    std::vector<index_t> sources;

private:
    bool bulk_groups_ = false;
    double record_ms_ = 0, sort_ms_ = 0, materialize_ms_ = 0;
    bool parallel_radix_ = false;
    bool large_ = false;
    bool reuse_delete_positions_ = false;
    struct Group { size_t offset, deletes, adds; };
    std::vector<Group> groups_;
    std::vector<index_t> destinations_;
    std::vector<size_t> delete_indices_, add_indices_;
};

struct EffectiveEdgeDelta {
    index_t source;
    index_t destination;
    int64_t count;
};

struct IgnoreEffectiveUpdates {
    void Prepare(const std::vector<EffectiveEdgeDelta> &) {}
    void Commit() noexcept {}
};

} // namespace topology
} // namespace sepgraph
#endif
