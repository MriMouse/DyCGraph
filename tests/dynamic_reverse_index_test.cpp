#include <algorithm>
#include <cstdlib>
#include <random>
#include <stdexcept>
#include <vector>

#include <framework/dynamic_reverse_index.h>
#include <groute/graphs/source_local_chunk_store.h>

static void Require(bool condition) { if (!condition) std::abort(); }
using namespace sepgraph::topology;
using sepgraph::runtime::DynamicReverseIndex;

struct TestGraph {
    struct View {
        const std::vector<std::vector<index_t>> *edges;
        uint64_t Degree(index_t src) const { return (*edges)[src].size(); }
        index_t EdgeAt(index_t src, uint64_t offset) const { return (*edges)[src][offset]; }
    };
    index_t nnodes;
    std::vector<std::vector<index_t>> edges;
    View adjacency_view() const { return View{&edges}; }
};

static void Check(const TestGraph &graph, const SourceLocalChunkStore &store,
                  const DynamicReverseIndex &reverse) {
    uint64_t edges = 0;
    for (index_t src = 0; src < graph.nnodes; ++src) {
        if (store.IsMaterialized(src)) Require(store.Neighbors(src) == graph.edges[src]);
        edges += graph.edges[src].size();
    }
    Require(store.EdgeCount() == edges);
    for (index_t dst = 0; dst < graph.nnodes; ++dst) {
        std::vector<index_t> expected, actual;
        for (index_t src = 0; src < graph.nnodes; ++src) {
            const auto &out = graph.edges[src];
            if (std::find(out.begin(), out.end(), dst) != out.end()) expected.push_back(src);
        }
        reverse.ForEachIncoming(dst, [&](index_t src) { actual.push_back(src); });
        Require(actual == expected);
        std::vector<uint64_t> offsets;
        const auto metrics = reverse.MaterializeIncoming({dst}, offsets, actual);
        Require(actual == expected);
        Require(offsets == std::vector<uint64_t>({0, expected.size()}));
        Require(metrics.output_sources == expected.size());
    }
}

static void RunBatch(TestGraph &graph, SourceLocalChunkStore &store,
                     DynamicReverseIndex &reverse, const TopologyMutationBatch &input) {
    GroupedUpdateBatch grouped(input);
    uint64_t missing = 0, invalid = 0;
    for (const auto &edge : input.deletions) {
        if (!store.IsMaterialized(edge.source)) { ++missing; continue; }
        auto &out = graph.edges[edge.source];
        const auto found = std::find(out.begin(), out.end(), edge.destination);
        if (found == out.end()) ++missing;
        else out.erase(found);
    }
    const auto deleted = store.ApplyGroupedPhase(grouped, UpdatePhase::Delete, reverse);
    Require(deleted.missing_deletes == missing);
    Require(!store.IsPublished());
    Check(graph, store, reverse); // No additions may be visible to deletion repair.
    for (const auto &edge : input.additions) {
        if (!store.IsMaterialized(edge.source)) { ++invalid; continue; }
        graph.edges[edge.source].push_back(edge.destination);
    }
    const auto added = store.ApplyGroupedPhase(grouped, UpdatePhase::Add, reverse);
    Require(added.invalid_additions == invalid);
    Require(added.epoch == deleted.epoch);
    Check(graph, store, reverse);
    Require(store.Publish() == deleted.epoch);
    store.ReclaimThrough(store.PublishedEpoch());
}

static void TestEffectivePhases() {
    TestGraph graph{5, {{2, 2, 3}, {2}, {3}, {}, {2}}};
    SourceLocalChunkStore store(5, ChunkArenaOptions{16384, 16384, 4, false, 3});
    for (index_t src = 0; src < graph.nnodes; ++src) store.LoadSource(src, graph.edges[src]);
    store.FinalizeLoad();
    DynamicReverseIndex reverse;
    reverse.Build(graph, 2);
    Require(reverse.BaseEdgeCount() == 6);
    Check(graph, store, reverse);
    RunBatch(graph, store, reverse, {{{0,2}, {1,2}, {4,3}, {2,3}}, {{3,2}, {2,3}}});
    RunBatch(graph, store, reverse, {{{0,2}, {0,2}}, {{0,2}, {3,2}, {4,3}}});
    RunBatch(graph, store, reverse, {});
    RunBatch(graph, store, reverse, {{}, {{0,4}, {0,1}, {0,4}, {0,3}}});
    RunBatch(graph, store, reverse, {{{0,4}, {0,4}, {0,4}}, {}});
    std::mt19937 random(14);
    for (int batch = 0; batch < 300; ++batch) {
        TopologyMutationBatch input;
        for (int i = 0; i < 20; ++i) {
            input.deletions.push_back({static_cast<index_t>(random() % 7), static_cast<index_t>(random() % 7)});
            if (i < 12) input.additions.push_back({static_cast<index_t>(random() % 7), static_cast<index_t>(random() % 7)});
        }
        RunBatch(graph, store, reverse, input);
    }
}

static void TestPreflightFailure() {
    TestGraph graph{3, {{1}, {}, {}}};
    SourceLocalChunkStore store(3, ChunkArenaOptions{4, 4, 1, false, 1});
    store.LoadSource(0, graph.edges[0]);
    store.LoadSource(1, {}); // Source 2 deliberately unmaterialized.
    store.FinalizeLoad();
    DynamicReverseIndex reverse;
    reverse.Build(graph, 1);
    RunBatch(graph, store, reverse, {{{2,1}}, {{2,1}}});

    struct FailingObserver {
        DynamicReverseIndex &reverse;
        void Prepare(const std::vector<EffectiveEdgeDelta> &records) {
            reverse.Prepare(records);
            throw std::runtime_error("injected reverse preflight failure");
        }
        void Commit() noexcept { std::abort(); }
    } failure{reverse};
    const GroupedUpdateBatch remove(TopologyMutationBatch{{{0,1}}, {}});
    bool rejected = false;
    try { store.ApplyGroupedPhase(remove, UpdatePhase::Delete, failure); }
    catch (const std::runtime_error &) { rejected = true; }
    Require(rejected && store.IsPublished());
    Check(graph, store, reverse);
    RunBatch(graph, store, reverse, {}); // Abandon prepared reverse changes safely.

    TopologyMutationBatch large;
    large.additions.assign(10, {0,2});
    const GroupedUpdateBatch grouped(large);
    store.ApplyGroupedPhase(grouped, UpdatePhase::Delete, reverse);
    rejected = false;
    try { store.ApplyGroupedPhase(grouped, UpdatePhase::Add, reverse); }
    catch (const std::runtime_error &) { rejected = true; }
    Require(rejected && !store.IsPublished());
    Check(graph, store, reverse);
    store.ApplyGroupedPhase(GroupedUpdateBatch{}, UpdatePhase::Add, reverse);
    store.Publish();
    Check(graph, store, reverse);
}

int main() {
    TestEffectivePhases();
    TestPreflightFailure();
}
