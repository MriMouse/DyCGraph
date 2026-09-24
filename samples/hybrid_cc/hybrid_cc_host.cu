#include "hybrid_cc_common.h"
#include <fstream>
#include <numeric>

using sepgraph::topology::SourceLocalChunkStore;

void ValidateSymmetricGraph(const SourceLocalChunkStore &graph, uint32_t nodes) {
    std::vector<uint8_t> sorted(nodes);
    for (uint32_t u = 0; u < nodes; ++u) {
        const auto &d = graph.Descriptor(u);
        if (d.degree == 0) continue;
        const auto *row = graph.SlabData(d.slab_id) + d.index;
        sorted[u] = std::is_sorted(row, row + d.degree);
    }
    for (uint32_t u = 0; u < nodes; ++u) {
        const auto &d = graph.Descriptor(u);
        if (d.degree == 0) continue;
        const auto *row = graph.SlabData(d.slab_id) + d.index;
        for (uint32_t i = 0; i < d.degree; ++i) {
            const uint32_t v = row[i];
            if (v >= nodes) throw std::invalid_argument("CC graph endpoint outside graph");
            if (u == v || (sorted[u] && i && row[i-1] == v)) continue;
            const auto &r = graph.Descriptor(v);
            if (r.degree == 0) throw std::invalid_argument("CC requires symmetric graph adjacency");
            const auto *back = graph.SlabData(r.slab_id) + r.index;
            auto count = [](const uint32_t *p, uint32_t n, uint32_t value, bool ordered) {
                if (!ordered) return std::count(p, p+n, value);
                const auto range = std::equal_range(p, p+n, value);
                return range.second - range.first;
            };
            if (count(row, d.degree, v, sorted[u]) != count(back, r.degree, u, sorted[v]))
                throw std::invalid_argument("CC requires symmetric graph adjacency (paired edge occurrences)");
        }
    }
}

// Independent union-find oracle: equal labels along edges alone cannot detect
// stale labels in disconnected cycles after deletion.
uint64_t CCCheck(const SourceLocalChunkStore &graph, const std::vector<label_t> &labels) {
    std::vector<uint32_t> parent(labels.size()), rank(labels.size(), 0);
    std::iota(parent.begin(), parent.end(), 0);
    auto root = [&](uint32_t v) {
        while (v != parent[v]) { parent[v] = parent[parent[v]]; v = parent[v]; }
        return v;
    };
    for (uint32_t u = 0; u < labels.size(); ++u) {
        const auto &d = graph.Descriptor(u);
        if (d.degree == 0) continue;
        const auto *row = graph.SlabData(d.slab_id) + d.index;
        for (uint32_t i = 0; i < d.degree; ++i) {
            uint32_t a = root(u), b = root(row[i]);
            if (a == b) continue;
            if (rank[a] < rank[b]) std::swap(a, b);
            parent[b] = a;
            rank[a] += rank[a] == rank[b];
        }
    }
    std::vector<label_t> minimum(labels.size(), UINT32_MAX);
    for (uint32_t u = 0; u < labels.size(); ++u) minimum[root(u)] = std::min(minimum[root(u)], u);
    uint64_t errors = 0;
    for (uint32_t u = 0; u < labels.size(); ++u) errors += labels[u] != minimum[root(u)];
    return errors;
}

bool CCOutput(const char *path, const std::vector<label_t> &labels) {
    std::ofstream output(path);
    for (size_t u = 0; u < labels.size(); ++u) output << u << ' ' << labels[u] << '\n';
    output.close();
    return !output.fail();
}
