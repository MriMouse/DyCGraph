#ifndef SEPGRAPH_EFFECTIVE_UPDATE_BATCH_H
#define SEPGRAPH_EFFECTIVE_UPDATE_BATCH_H

#include <algorithm>
#include <vector>
#include <framework/topology_replay.h>

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
    explicit GroupedUpdateBatch(const TopologyMutationBatch &batch = {}) {
        struct Record { index_t source, destination; bool addition; };
        std::vector<Record> records;
        records.reserve(batch.deletions.size() + batch.additions.size());
        for (const auto &edge : batch.deletions)
            records.push_back({edge.source, edge.destination, false});
        for (const auto &edge : batch.additions)
            records.push_back({edge.source, edge.destination, true});
        std::stable_sort(records.begin(), records.end(),
            [](const Record &a, const Record &b) { return a.source < b.source; });
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
    }

    SourceMutationView View(size_t i, UpdatePhase phase) const {
        const auto &group = groups_[i];
        const auto *data = destinations_.data() + group.offset;
        return {{data, phase == UpdatePhase::Add ? 0 : group.deletes},
                {data + group.deletes, phase == UpdatePhase::Delete ? 0 : group.adds}};
    }

    std::vector<index_t> sources;

private:
    struct Group { size_t offset, deletes, adds; };
    std::vector<Group> groups_;
    std::vector<index_t> destinations_;
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
