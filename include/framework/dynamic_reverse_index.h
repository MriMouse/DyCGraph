#ifndef SEPGRAPH_DYNAMIC_REVERSE_INDEX_H
#define SEPGRAPH_DYNAMIC_REVERSE_INDEX_H

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <memory>
#include <thread>
#include <unordered_map>
#include <vector>

#include <groute/graphs/common.h>

namespace sepgraph {
namespace runtime {

class DynamicReverseIndex {
public:
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
    }

    void ApplyInsert(index_t src, index_t dst) {
        ApplyCountDelta(src, dst, 1);
    }

    void ApplyDelete(index_t src, index_t dst) {
        ApplyCountDelta(src, dst, -1);
    }

    template <typename Visitor>
    void ForEachIncoming(index_t dst, Visitor visitor) const {
        if (dst >= nnodes_) {
            return;
        }
        const uint64_t begin = offsets_[dst];
        const uint64_t end = offsets_[static_cast<size_t>(dst) + 1];
        std::unordered_map<index_t, uint32_t> base_counts;
        base_counts.reserve(static_cast<size_t>(end - begin));
        for (uint64_t edge = begin; edge < end; ++edge) {
            ++base_counts[sources_[edge]];
        }
        for (const auto &entry : base_counts) {
            const index_t src = entry.first;
            const auto delta_it = edge_count_deltas_.find(EdgeKey(src, dst));
            const int64_t delta = delta_it == edge_count_deltas_.end()
                                      ? 0
                                      : delta_it->second;
            if (static_cast<int64_t>(entry.second) + delta > 0) {
                visitor(src);
            }
        }

        const auto delta_it = delta_sources_by_dst_.find(dst);
        if (delta_it == delta_sources_by_dst_.end()) {
            return;
        }
        for (const index_t src : delta_it->second) {
            if (base_counts.find(src) != base_counts.end()) {
                continue;
            }
            const auto count_it = edge_count_deltas_.find(EdgeKey(src, dst));
            if (count_it != edge_count_deltas_.end() && count_it->second > 0) {
                visitor(src);
            }
        }
    }

    void MaterializeIncoming(const std::vector<index_t> &destinations,
                             std::vector<uint64_t> &offsets,
                             std::vector<index_t> &sources) const {
        offsets.assign(destinations.size() + 1, 0);
        sources.clear();
        for (size_t i = 0; i < destinations.size(); ++i) {
            ForEachIncoming(destinations[i], [&](index_t src) {
                sources.push_back(src);
            });
            offsets[i + 1] = sources.size();
        }
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

    index_t nnodes_;
    std::vector<uint64_t> offsets_;
    std::vector<index_t> sources_;
    std::unordered_map<uint64_t, int64_t> edge_count_deltas_;
    std::unordered_map<index_t, std::vector<index_t>> delta_sources_by_dst_;
};

} // namespace runtime
} // namespace sepgraph

#endif
