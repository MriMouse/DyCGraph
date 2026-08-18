#ifndef SEPGRAPH_PERSISTENT_DEPENDENCY_GRAPH_H
#define SEPGRAPH_PERSISTENT_DEPENDENCY_GRAPH_H

#include <algorithm>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <unordered_map>
#include <vector>

#include <framework/topology_replay.h>

namespace sepgraph { namespace runtime {

enum class DependencyOwner : uint8_t { CPU = 0, GPU = 1 };

struct DependencyBatchMetrics {
    uint64_t epoch = 0;
    uint64_t touched_records = 0;
    uint64_t inserted_records = 0;
    uint64_t retired_records = 0;
    uint64_t missing_deletes = 0;
};

// E4-A1 protocol model. It freezes record/owner/epoch semantics independently
// of the production storage selected by E4-A2.
class PersistentDependencyGraph {
public:
    template <typename Graph>
    void Build(const Graph &graph, const std::vector<uint8_t> &owners = {}) {
        Reset(graph.nnodes, owners);
        const auto adjacency = graph.adjacency_view();
        for (index_t source = 0; source < node_count_; ++source) {
            for (uint64_t edge = 0; edge < adjacency.Degree(source); ++edge) {
                Add(source, adjacency.EdgeAt(source, edge), 0);
            }
        }
        RebuildIndexes();
    }

    void Build(const std::vector<std::vector<index_t>> &adjacency,
               const std::vector<uint8_t> &owners = {}) {
        Reset(static_cast<index_t>(adjacency.size()), owners);
        for (index_t source = 0; source < node_count_; ++source) {
            for (index_t destination : adjacency[source]) Add(source, destination, 0);
        }
        RebuildIndexes();
    }

    void SetOwners(const std::vector<uint8_t> &owners) {
        ValidateOwners(owners); owners_ = owners; RebuildCrossIndex();
    }

    DependencyBatchMetrics ApplyBatch(const topology::TopologyMutationBatch &batch) {
        if (pending_) throw std::logic_error("dependency batch already pending");
        return ApplyPhase(batch, true);
    }

    DependencyBatchMetrics ApplyPendingAdditions(
            const topology::TopologyMutationBatch &batch) {
        if (!pending_) throw std::logic_error("no pending dependency batch");
        if (!batch.deletions.empty())
            throw std::invalid_argument("pending phase accepts additions only");
        return ApplyPhase(batch, false);
    }

    uint64_t Publish() {
        if (!pending_) throw std::logic_error("no pending dependency batch");
        published_epoch_ = pending_epoch_; pending_ = false; return published_epoch_;
    }

    uint64_t ReclaimThrough(uint64_t completed_epoch) {
        if (pending_) throw std::logic_error("cannot reclaim a pending epoch");
        if (completed_epoch > published_epoch_)
            throw std::invalid_argument("completed epoch is not published");
        const size_t before = records_.size();
        records_.erase(std::remove_if(records_.begin(), records_.end(),
            [completed_epoch](const Record &record) {
                return record.retired != 0 && record.retired <= completed_epoch;
            }), records_.end());
        RebuildIndexes();
        return before - records_.size();
    }

    template <typename Visitor>
    void ForEachIncoming(index_t destination, Visitor visitor) const {
        Check(destination);
        for (size_t id : incoming_[destination]) {
            if (records_[id].retired == 0) visitor(records_[id].source);
        }
    }

    template <typename Visitor>
    void ForEachOwnerIncoming(DependencyOwner owner, index_t destination,
                              Visitor visitor) const {
        if (Owner(destination) != owner)
            throw std::invalid_argument("destination does not belong to owner");
        ForEachIncoming(destination, visitor);
    }

    template <typename Visitor>
    void ForEachCrossDomainDependency(index_t source, Visitor visitor) const {
        Check(source);
        for (size_t id : cross_[source]) {
            const Record &record = records_[id];
            if (record.retired == 0)
                visitor(record.destination, Owner(record.destination));
        }
    }

    DependencyOwner Owner(index_t vertex) const {
        Check(vertex);
        return owners_[vertex] ? DependencyOwner::CPU : DependencyOwner::GPU;
    }
    uint64_t PublishedEpoch() const { return published_epoch_; }
    uint64_t PendingEpoch() const { return pending_epoch_; }
    bool HasPendingBatch() const { return pending_; }
    size_t RecordCount() const { return records_.size(); }
    uint64_t LiveRecordCount() const {
        return std::count_if(records_.begin(), records_.end(),
            [](const Record &record) { return record.retired == 0; });
    }

private:
    struct Record { index_t source, destination; uint64_t born, retired; };
    static uint64_t Key(index_t source, index_t destination) {
        return (static_cast<uint64_t>(source) << 32) | destination;
    }
    void Reset(index_t count, const std::vector<uint8_t> &owners) {
        node_count_ = count; records_.clear(); pending_ = false;
        published_epoch_ = pending_epoch_ = 0;
        if (owners.empty()) owners_.assign(count, 0);
        else { ValidateOwners(owners); owners_ = owners; }
        incoming_.assign(count, {}); cross_.assign(count, {}); active_.clear();
    }
    void ValidateOwners(const std::vector<uint8_t> &owners) const {
        if (owners.size() != node_count_) throw std::invalid_argument("owner size");
        for (uint8_t owner : owners)
            if (owner > 1) throw std::invalid_argument("invalid owner");
    }
    void Check(index_t vertex) const {
        if (vertex >= node_count_) throw std::out_of_range("dependency vertex");
    }
    size_t Add(index_t source, index_t destination, uint64_t epoch) {
        Check(source); Check(destination);
        records_.push_back({source, destination, epoch, 0});
        return records_.size() - 1;
    }
    DependencyBatchMetrics ApplyPhase(
            const topology::TopologyMutationBatch &batch, bool begin) {
        for (const auto &m : batch.deletions) { Check(m.source); Check(m.destination); }
        for (const auto &m : batch.additions) { Check(m.source); Check(m.destination); }
        DependencyBatchMetrics metrics;
        metrics.epoch = begin ? published_epoch_ + 1 : pending_epoch_;
        if (metrics.epoch == 0 || metrics.epoch == std::numeric_limits<uint64_t>::max())
            throw std::overflow_error("dependency epoch exhausted");
        if (begin) { pending_epoch_ = metrics.epoch; pending_ = true; }
        for (const auto &m : batch.deletions) {
            auto found = active_.find(Key(m.source, m.destination));
            if (found == active_.end() || found->second.empty()) {
                ++metrics.missing_deletes; continue;
            }
            size_t id = found->second.back(); found->second.pop_back();
            records_[id].retired = metrics.epoch;
            ++metrics.retired_records; ++metrics.touched_records;
        }
        for (const auto &m : batch.additions) {
            size_t id = Add(m.source, m.destination, metrics.epoch);
            incoming_[m.destination].push_back(id);
            active_[Key(m.source, m.destination)].push_back(id);
            if (Owner(m.source) != Owner(m.destination)) cross_[m.source].push_back(id);
            ++metrics.inserted_records; ++metrics.touched_records;
        }
        return metrics;
    }
    void RebuildIndexes() {
        incoming_.assign(node_count_, {}); active_.clear();
        for (size_t id = 0; id < records_.size(); ++id) {
            const Record &record = records_[id];
            incoming_[record.destination].push_back(id);
            if (record.retired == 0)
                active_[Key(record.source, record.destination)].push_back(id);
        }
        RebuildCrossIndex();
    }
    void RebuildCrossIndex() {
        cross_.assign(node_count_, {});
        for (size_t id = 0; id < records_.size(); ++id) {
            const Record &record = records_[id];
            if (record.retired == 0 && Owner(record.source) != Owner(record.destination))
                cross_[record.source].push_back(id);
        }
    }
    index_t node_count_ = 0;
    std::vector<uint8_t> owners_;
    std::vector<Record> records_;
    std::vector<std::vector<size_t>> incoming_, cross_;
    std::unordered_map<uint64_t, std::vector<size_t>> active_;
    uint64_t published_epoch_ = 0, pending_epoch_ = 0;
    bool pending_ = false;
};

} }
#endif
