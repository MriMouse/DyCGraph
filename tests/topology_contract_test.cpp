#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <iostream>
#include <unordered_map>
#include <vector>

#include <framework/topology_replay.h>
#include <groute/graphs/csr_graph.cuh>
#include <groute/graphs/topology_contract.cuh>

namespace {

struct LegacyDescriptor {
    uint64_t index;
    index_t degree;
};

void TestAdjacencyView() {
    const LegacyDescriptor descriptors[] = {{0, 3}, {4, 0}, {4, 2}};
    const index_t edges[] = {4, 5, 6, 999, 7, 8};
    const sepgraph::topology::ContiguousAdjacencyView<LegacyDescriptor, index_t> view{
        descriptors, edges, 3};

    assert(view.Contains(2));
    assert(!view.Contains(3));
    assert(view.Begin(0) == 0);
    assert(view.Degree(1) == 0);
    assert(view.EdgeAt(0, 2) == 6);
    assert(view.EdgeAt(2, 1) == 8);
}

void TestEpochContract() {
    sepgraph::topology::TopologyEpochContract epoch;
    assert(epoch.IsPublished());
    assert(epoch.PublishedEpoch() == 0);
    assert(epoch.MarkMutation() == 1);
    assert(!epoch.IsPublished());
    assert(epoch.MarkMutation() == 1);
    assert(epoch.MarkPublished() == 1);
    assert(epoch.IsPublished());
    assert(epoch.MarkPublished() == 1);
    assert(epoch.MarkMutation() == 2);
}

void TestReplaySemantics() {
    std::vector<std::vector<index_t>> adjacency = {
        {1, 1, 2},
        {},
        {9},
        std::vector<index_t>(1024, 7),
    };
    sepgraph::topology::TopologyReplayModel replay(std::move(adjacency));
    assert(replay.EdgeCount() == 1028);

    sepgraph::topology::TopologyMutationBatch batch;
    batch.deletions = {{0, 1}, {1, 99}, {3, 7}};
    batch.additions = {{0, 3}, {1, 4}, {0, 1}};
    const std::vector<index_t> touched = batch.TouchedSources();
    assert((touched == std::vector<index_t>{0, 1, 3}));

    replay.ApplyBatch(batch);
    assert((replay.Neighbors(0) == std::vector<index_t>{1, 2, 3, 1}));
    assert((replay.Neighbors(1) == std::vector<index_t>{4}));
    assert(replay.Neighbors(3).size() == 1023);
    assert(replay.EdgeCount() == 1029);

    const auto digest = replay.Digest(0);
    assert(digest.degree == 4);
    assert(digest.ordered_hash != digest.multiset_hash);
}

void TestLegacyPmaAdapterAndDuplicateDelete() {
    groute::graphs::host::vertex_sync_element descriptors[] = {
        {0, 3},
        {4, 0},
    };
    index_t edges[] = {1, 1, 2, static_cast<index_t>(-1)};
    groute::graphs::host::PMAGraph graph;
    graph.nnodes = 2;
    graph.segment_size = 1;
    graph.segment_count = 2;
    graph.sync_vertices_ = descriptors;
    graph.edges_ = edges;

    const auto before = graph.adjacency_view();
    assert((sepgraph::topology::MaterializeNeighbors(before, 0) ==
            std::vector<index_t>{1, 1, 2}));
    assert(graph.del_edge(0, 1, 0));
    assert(!graph.topology_epoch().IsPublished());
    assert((sepgraph::topology::MaterializeNeighbors(graph.adjacency_view(), 0) ==
            std::vector<index_t>{1, 2}));
    assert(!graph.del_edge(1, 7, 0));
}

void TestSparseReplayBatchSemantics() {
    std::unordered_map<index_t, std::vector<index_t>> adjacency = {
        {0, {1, 1, 2}},
        {3, {}},
    };
    sepgraph::topology::SparseTopologyReplayModel replay(
        std::move(adjacency), 3);
    sepgraph::topology::TopologyMutationBatch batch;
    batch.deletions = {{0, 1}};
    batch.additions = {{0, 4}, {3, 5}};
    replay.ApplyBatch(batch);
    assert((replay.Neighbors(0) == std::vector<index_t>{1, 2, 4}));
    assert((replay.Neighbors(3) == std::vector<index_t>{5}));
    assert(replay.EdgeCount() == 4);
}

} // namespace

int main() {
    TestAdjacencyView();
    TestEpochContract();
    TestReplaySemantics();
    TestLegacyPmaAdapterAndDuplicateDelete();
    TestSparseReplayBatchSemantics();
    std::cout << "topology_contract_test: passed\n";
    return 0;
}
