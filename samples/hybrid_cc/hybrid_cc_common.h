#ifndef HYBRID_CC_COMMON_H
#define HYBRID_CC_COMMON_H

#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <vector>
#include <groute/graphs/source_local_chunk_store.h>
#include <framework/undirected_input.h>

using label_t = uint32_t;
#define IDENTITY_ELEMENT UINT32_MAX

// CC consumes an undirected multigraph stored as paired directed occurrences.
// Keep this contract explicit instead of silently computing directed reachability.
void ValidateSymmetricGraph(const sepgraph::topology::SourceLocalChunkStore &graph,
                            uint32_t nodes);
uint64_t CCCheck(const sepgraph::topology::SourceLocalChunkStore &graph,
                 const std::vector<label_t> &labels);
bool CCOutput(const char *path, const std::vector<label_t> &labels);

template<class Edges>
void ValidateSymmetricUpdates(const Edges &edges, size_t begin, size_t count,
                              uint32_t nodes) {
    std::vector<uint64_t> forward, reverse;
    forward.reserve(count);
    reverse.reserve(count);
    for (size_t i = begin; i < begin + count; ++i) {
        const auto &e = edges[i];
        if (e.u >= nodes || e.v >= nodes)
            throw std::invalid_argument("CC update endpoint outside graph");
        forward.push_back((uint64_t(e.u) << 32) | e.v);
        reverse.push_back((uint64_t(e.v) << 32) | e.u);
    }
    std::sort(forward.begin(), forward.end());
    std::sort(reverse.begin(), reverse.end());
    if (forward != reverse)
        throw std::invalid_argument("CC requires paired (u,v)/(v,u) occurrences in each update phase");
}
#endif
