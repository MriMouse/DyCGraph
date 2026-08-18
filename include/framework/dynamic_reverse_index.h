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

    template <typename PMAGraph>
    void Build(const PMAGraph &graph, uint32_t requested_workers) {
        nnodes_ = graph.nnodes;
        offsets_.assign(static_cast<size_t>(nnodes_) + 1, 0);
        sources_.clear();
        edge_count_deltas_.clear();
        delta_sources_by_dst_.clear();

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

    void ApplyInsert(index_t src, index_t dst) {
        ApplyCountDelta(src, dst, 1);
    }

    void ApplyDelete(index_t src, index_t dst) {
        ApplyCountDelta(src, dst, -1);
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

    static uint64_t EdgeKey(index_t src, index_t dst) {
        return (static_cast<uint64_t>(src) << 32) | static_cast<uint64_t>(dst);
    }

    void ApplyCountDelta(index_t src, index_t dst, int64_t delta) {
        if (src >= nnodes_ || dst >= nnodes_) {
            return;
        }
        const uint64_t key = EdgeKey(src, dst);
        if (edge_count_deltas_.find(key) == edge_count_deltas_.end()) {
            delta_sources_by_dst_[dst].push_back(src);
        }
        edge_count_deltas_[key] += delta;
    }

    template <typename Visitor>
    void MergeIncoming(index_t dst, Visitor visitor,
                       MaterializeMetrics *metrics) const {
        if (dst >= nnodes_) return;
        const uint64_t begin = offsets_[dst];
        const uint64_t end = offsets_[static_cast<size_t>(dst) + 1];
        if (metrics != nullptr) metrics->base_edges_scanned += end - begin;

        const auto delta_it = delta_sources_by_dst_.find(dst);
        std::vector<index_t> sorted_delta;
        if (delta_it != delta_sources_by_dst_.end()) sorted_delta = delta_it->second;
        std::sort(sorted_delta.begin(), sorted_delta.end());
        if (metrics != nullptr) {
            metrics->delta_records_scanned += sorted_delta.size();
        }

        uint64_t base_pos = begin;
        size_t delta_pos = 0;
        while (base_pos < end || delta_pos < sorted_delta.size()) {
            const index_t base_src = base_pos < end
                ? sources_[base_pos] : std::numeric_limits<index_t>::max();
            const index_t delta_src = delta_pos < sorted_delta.size()
                ? sorted_delta[delta_pos] : std::numeric_limits<index_t>::max();
            const index_t src = std::min(base_src, delta_src);
            int64_t count = 0;
            while (base_pos < end && sources_[base_pos] == src) {
                ++count;
                ++base_pos;
            }
            if (delta_pos < sorted_delta.size() && sorted_delta[delta_pos] == src) {
                const auto count_it = edge_count_deltas_.find(EdgeKey(src, dst));
                if (count_it != edge_count_deltas_.end()) count += count_it->second;
                ++delta_pos;
            }
            if (count > 0) visitor(src);
        }
    }

    index_t nnodes_;
    std::vector<uint64_t> offsets_;
    std::vector<index_t> sources_;
    std::unordered_map<uint64_t, int64_t> edge_count_deltas_;
    std::unordered_map<index_t, std::vector<index_t>> delta_sources_by_dst_;
};

} // namespace runtime
} // namespace sepgraph

#endif
