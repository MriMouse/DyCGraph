#ifndef SEPGRAPH_DYNAMIC_REVERSE_INDEX_H
#define SEPGRAPH_DYNAMIC_REVERSE_INDEX_H

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <limits>
#include <memory>
#include <thread>
#include <unordered_map>
#include <vector>

#include <groute/graphs/common.h>
#include <framework/effective_update_batch.h>

namespace sepgraph {
namespace runtime {

class DynamicReverseIndex {
public:
    struct MaterializeMetrics {
        uint64_t base_edges_scanned = 0;
        uint64_t delta_records_scanned = 0;
        uint64_t output_sources = 0;
    };

    DynamicReverseIndex() : nnodes_(0) {}
    DynamicReverseIndex(const DynamicReverseIndex &) = delete;
    DynamicReverseIndex &operator=(const DynamicReverseIndex &) = delete;

    template <typename PMAGraph>
    void Build(const PMAGraph &graph, uint32_t requested_workers) {
        nnodes_ = graph.nnodes;
        offsets_.assign(static_cast<size_t>(nnodes_) + 1, 0);
        sources_.clear();
        deltas_.clear();
        pending_.clear();

        if (nnodes_ == 0) {
            return;
        }

        const uint32_t workers = std::max<uint32_t>(
            1, std::min<uint32_t>(requested_workers, nnodes_));
        std::unique_ptr<std::atomic<uint32_t>[]> incoming_counts(
            new std::atomic<uint32_t>[nnodes_]);
        for (index_t node = 0; node < nnodes_; ++node) {
            incoming_counts[node].store(0, std::memory_order_relaxed);
        }

        ParallelForVertexRanges(graph, workers, [&](index_t, index_t dst) {
            if (dst < nnodes_) {
                incoming_counts[dst].fetch_add(1, std::memory_order_relaxed);
            }
        });

        for (index_t node = 0; node < nnodes_; ++node) {
            offsets_[static_cast<size_t>(node) + 1] =
                offsets_[node] + incoming_counts[node].load(std::memory_order_relaxed);
        }
        sources_.resize(offsets_.back());

        std::unique_ptr<std::atomic<uint64_t>[]> write_offsets(
            new std::atomic<uint64_t>[nnodes_]);
        for (index_t node = 0; node < nnodes_; ++node) {
            write_offsets[node].store(offsets_[node], std::memory_order_relaxed);
        }
        ParallelForVertexRanges(graph, workers, [&](index_t src, index_t dst) {
            if (dst < nnodes_) {
                const uint64_t position =
                    write_offsets[dst].fetch_add(1, std::memory_order_relaxed);
                sources_[position] = src;
            }
        });
        for (index_t dst = 0; dst < nnodes_; ++dst) {
            std::sort(sources_.begin() + offsets_[dst],
                      sources_.begin() + offsets_[static_cast<size_t>(dst) + 1]);
        }
    }

    // Only forward-authorized deltas enter here. Prepare leaves the visible
    // reverse topology unchanged; Commit performs allocation-free vector swaps.
    void Prepare(const std::vector<topology::EffectiveEdgeDelta> &effective) {
        for (const auto &update : pending_) {
            const auto found = deltas_.find(update.destination);
            if (found != deltas_.end() && found->second.empty()) deltas_.erase(found);
        }
        pending_.clear();
        auto records = effective;
        records.erase(std::remove_if(records.begin(), records.end(),
            [&](const topology::EffectiveEdgeDelta &edge) {
                return edge.source >= nnodes_ || edge.destination >= nnodes_ || edge.count == 0;
            }), records.end());
        std::sort(records.begin(), records.end(),
            [](const topology::EffectiveEdgeDelta &a, const topology::EffectiveEdgeDelta &b) {
                return a.destination < b.destination ||
                    (a.destination == b.destination && a.source < b.source);
            });
        for (size_t begin = 0; begin < records.size();) {
            const auto dst = records[begin].destination;
            size_t end = begin + 1;
            while (end < records.size() && records[end].destination == dst) ++end;
            const auto found = deltas_.find(dst);
            const std::vector<Delta> empty;
            const auto &old = found == deltas_.end() ? empty : found->second;
            std::vector<Delta> merged;
            merged.reserve(old.size() + end - begin);
            size_t i = 0, j = begin;
            while (i < old.size() || j < end) {
                const auto src = std::min(i < old.size() ? old[i].source :
                    std::numeric_limits<index_t>::max(), j < end ? records[j].source :
                    std::numeric_limits<index_t>::max());
                int64_t count = 0;
                if (i < old.size() && old[i].source == src) count += old[i++].count;
                while (j < end && records[j].source == src) count += records[j++].count;
                if (count) merged.push_back({src, count});
            }
            pending_.push_back({dst, nullptr, std::move(merged)});
            begin = end;
        }
        // Inserting empty destination slots does not change incoming edges.
        // References remain valid across unordered_map rehashes.
        for (auto &update : pending_) update.target = &deltas_[update.destination];
    }

    void Commit() noexcept {
        for (auto &update : pending_) update.target->swap(update.records);
        for (const auto &update : pending_) {
            if (update.target->empty()) deltas_.erase(update.destination);
        }
        pending_.clear();
    }

    template <typename Visitor>
    void ForEachIncoming(index_t dst, Visitor visitor) const {
        MergeIncoming(dst, visitor, nullptr);
    }

    MaterializeMetrics MaterializeIncoming(
                             const std::vector<index_t> &destinations,
                             std::vector<uint64_t> &offsets,
                             std::vector<index_t> &sources) const {
        MaterializeMetrics metrics;
        offsets.assign(destinations.size() + 1, 0);
        sources.clear();
        for (size_t i = 0; i < destinations.size(); ++i) {
            MergeIncoming(destinations[i], [&](index_t src) {
                sources.push_back(src);
            }, &metrics);
            offsets[i + 1] = sources.size();
        }
        metrics.output_sources = sources.size();
        return metrics;
    }

    uint64_t BaseEdgeCount() const { return sources_.size(); }

private:
    template <typename PMAGraph, typename Visitor>
    static void ParallelForVertexRanges(const PMAGraph &graph,
                                        uint32_t workers,
                                        Visitor visitor) {
        const auto adjacency = graph.adjacency_view();
        std::vector<std::thread> threads;
        threads.reserve(workers);
        for (uint32_t worker = 0; worker < workers; ++worker) {
            const index_t begin_node = static_cast<index_t>(
                (static_cast<uint64_t>(graph.nnodes) * worker) / workers);
            const index_t end_node = static_cast<index_t>(
                (static_cast<uint64_t>(graph.nnodes) * (worker + 1)) / workers);
            threads.emplace_back([adjacency, begin_node, end_node, &visitor]() {
                for (index_t src = begin_node; src < end_node; ++src) {
                    const uint64_t degree = adjacency.Degree(src);
                    for (uint64_t offset = 0; offset < degree; ++offset) {
                        visitor(src, adjacency.EdgeAt(src, offset));
                    }
                }
            });
        }
        for (auto &thread : threads) {
            thread.join();
        }
    }

    template <typename Visitor>
    void MergeIncoming(index_t dst, Visitor visitor,
                       MaterializeMetrics *metrics) const {
        if (dst >= nnodes_) return;
        const uint64_t begin = offsets_[dst];
        const uint64_t end = offsets_[static_cast<size_t>(dst) + 1];
        if (metrics != nullptr) metrics->base_edges_scanned += end - begin;

        const auto delta_it = deltas_.find(dst);
        const std::vector<Delta> empty;
        const auto &sorted_delta = delta_it == deltas_.end() ? empty : delta_it->second;
        if (metrics != nullptr) {
            metrics->delta_records_scanned += sorted_delta.size();
        }

        uint64_t base_pos = begin;
        size_t delta_pos = 0;
        while (base_pos < end || delta_pos < sorted_delta.size()) {
            const index_t base_src = base_pos < end
                ? sources_[base_pos] : std::numeric_limits<index_t>::max();
            const index_t delta_src = delta_pos < sorted_delta.size()
                ? sorted_delta[delta_pos].source : std::numeric_limits<index_t>::max();
            const index_t src = std::min(base_src, delta_src);
            int64_t count = 0;
            while (base_pos < end && sources_[base_pos] == src) {
                ++count;
                ++base_pos;
            }
            if (delta_pos < sorted_delta.size() && sorted_delta[delta_pos].source == src) {
                count += sorted_delta[delta_pos++].count;
            }
            if (count > 0) visitor(src);
        }
    }

    index_t nnodes_;
    std::vector<uint64_t> offsets_;
    std::vector<index_t> sources_;
    struct Delta { index_t source; int64_t count; };
    struct PendingDestination {
        index_t destination;
        std::vector<Delta> *target;
        std::vector<Delta> records;
    };
    std::unordered_map<index_t, std::vector<Delta>> deltas_;
    std::vector<PendingDestination> pending_;
};

} // namespace runtime
} // namespace sepgraph

#endif
