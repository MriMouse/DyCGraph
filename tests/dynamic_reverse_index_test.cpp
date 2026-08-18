#include <cstdlib>
#include <vector>

#include <framework/dynamic_reverse_index.h>

static void Require(bool condition) { if (!condition) std::abort(); }

struct TestGraph {
    struct View {
        const std::vector<std::vector<index_t>> *edges;
        uint64_t Degree(index_t src) const { return (*edges)[src].size(); }
        index_t EdgeAt(index_t src, uint64_t offset) const {
            return (*edges)[src][offset];
        }
    };

    index_t nnodes;
    std::vector<std::vector<index_t>> edges;
    View adjacency_view() const { return View{&edges}; }
};

int main() {
    TestGraph graph{5, {{2, 2, 3}, {2}, {3}, {}, {2}}};
    sepgraph::runtime::DynamicReverseIndex index;
    index.Build(graph, 2);
    Require(index.BaseEdgeCount() == 6);

    std::vector<uint64_t> offsets;
    std::vector<index_t> sources;
    auto metrics = index.MaterializeIncoming({2, 3}, offsets, sources);
    Require((offsets == std::vector<uint64_t>{0, 3, 5}));
    Require((sources == std::vector<index_t>{0, 1, 4, 0, 2}));
    Require(metrics.base_edges_scanned == 6);
    Require(metrics.delta_records_scanned == 0);
    Require(metrics.output_sources == 5);

    index.ApplyDelete(0, 2);  // one duplicate remains
    index.ApplyDelete(1, 2);  // source disappears
    index.ApplyInsert(3, 2);  // new source
    index.ApplyDelete(4, 3);  // missing delete stays absent
    index.ApplyDelete(2, 3);
    index.ApplyInsert(2, 3);  // delete-before-add cancels
    metrics = index.MaterializeIncoming({2, 3}, offsets, sources);
    Require((offsets == std::vector<uint64_t>{0, 3, 5}));
    Require((sources == std::vector<index_t>{0, 3, 4, 0, 2}));
    Require(metrics.base_edges_scanned == 6);
    Require(metrics.delta_records_scanned == 5);
    Require(metrics.output_sources == 5);

    index.ApplyDelete(0, 2);  // remove final duplicate occurrence
    index.ApplyInsert(3, 2);  // duplicate insert still emits one dependency source
    metrics = index.MaterializeIncoming({2}, offsets, sources);
    Require((offsets == std::vector<uint64_t>{0, 2}));
    Require((sources == std::vector<index_t>{3, 4}));
    Require(metrics.base_edges_scanned == 4);
    Require(metrics.delta_records_scanned == 3);
    return 0;
}
