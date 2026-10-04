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
        std::vector<index_t> prefix;
        reverse.ForEachIncomingWhile(dst, [&](index_t src) {
            prefix.push_back(src);
            return false;
        });
        Require(prefix.size() == (expected.empty() ? 0 : 1));
        if (!prefix.empty()) Require(prefix.front() == expected.front());
        prefix.clear();
        reverse.ForEachIncomingWhile(dst, [&](index_t src) {
            prefix.push_back(src);
            return true;
        });
        Require(prefix == expected);
        std::vector<uint64_t> offsets;
        const auto metrics = reverse.MaterializeIncoming({dst}, offsets, actual);
        Require(actual == expected);
        Require(offsets == std::vector<uint64_t>({0, expected.size()}));
        Require(metrics.output_sources == expected.size());
    }
}

static void RunBatch(TestGraph &graph, SourceLocalChunkStore &store,
                     DynamicReverseIndex &reverse, const TopologyMutationBatch &input) {
    // Change the strategy on one persistent store/reverse pair across epochs.
    setenv("CG_BATCH_MAINTENANCE", store.PublishedEpoch() % 2 ? "regular" : "large", 1);
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
    Require(reverse.LastPrepareMetrics().input_copy_bytes ==
        (grouped.LargeMaintenance() ? 0 : deleted.effective_records * sizeof(EffectiveEdgeDelta)));
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

static void TestEffectivePhases(uint32_t shards) {
    TestGraph graph{5, {{2, 2, 3}, {2}, {3}, {}, {2}}};
    SourceLocalChunkStore store(5, ChunkArenaOptions{16384, 16384, 4, false, 3});
    for (index_t src = 0; src < graph.nnodes; ++src) store.LoadSource(src, graph.edges[src]);
    store.FinalizeLoad();
    DynamicReverseIndex reverse;
    reverse.Build(graph, 2, shards);
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

static void TestPreflightFailure(uint32_t shards) {
    TestGraph graph{3, {{1}, {}, {}}};
    SourceLocalChunkStore store(3, ChunkArenaOptions{4, 4, 1, false, 1});
    store.LoadSource(0, graph.edges[0]);
    store.LoadSource(1, {}); // Source 2 deliberately unmaterialized.
    store.FinalizeLoad();
    DynamicReverseIndex reverse;
    reverse.Build(graph, 1, shards);
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

static void TestManyDestinations(uint32_t shards) {
    TestGraph graph{33001, std::vector<std::vector<index_t>>(33001)};
    DynamicReverseIndex reverse;
    reverse.Build(graph, 4, shards);
    std::vector<EffectiveEdgeDelta> records;
    for (index_t dst = 0; dst < graph.nnodes; ++dst) {
        records.push_back({(dst + 1) % graph.nnodes, dst, 2});
        records.push_back({(dst + 1) % graph.nnodes, dst, -1});
    }
    for (int phase = 0; phase < 3; ++phase) {
        reverse.Prepare(records);
        reverse.Prepare({}); // Abandon all prepared targets before visibility.
        reverse.Commit();
        for (index_t dst = 0; dst < graph.nnodes; ++dst)
            reverse.ForEachIncoming(dst, [](index_t) { Require(false); });
        reverse.Prepare(records);
        reverse.Commit();
        for (index_t dst = 0; dst < graph.nnodes; ++dst) {
            std::vector<index_t> incoming;
            reverse.ForEachIncoming(dst, [&](index_t src) { incoming.push_back(src); });
            Require(incoming == std::vector<index_t>{(dst + 1) % graph.nnodes});
        }
        auto inverse = records;
        for (auto &record : inverse) record.count = -record.count;
        reverse.Prepare(inverse);
        reverse.Commit();
    }
}

static void TestGrowingOverlay(uint32_t shards) {
    TestGraph graph{4099, std::vector<std::vector<index_t>>(4099)};
    DynamicReverseIndex reverse;
    reverse.Build(graph, 4, shards);
    for (index_t begin = 0; begin < graph.nnodes; begin += 251) {
        const index_t end = std::min<index_t>(begin + 251, graph.nnodes);
        std::vector<EffectiveEdgeDelta> records;
        for (index_t dst = begin; dst < end; ++dst)
            records.push_back({(dst + 1) % graph.nnodes, dst, 1});
        reverse.Prepare(records);
        for (index_t dst = begin; dst < end; ++dst)
            reverse.ForEachIncoming(dst, [](index_t) { Require(false); });
        reverse.Commit();
        for (index_t dst = 0; dst < end; ++dst) {
            std::vector<index_t> incoming;
            reverse.ForEachIncoming(dst, [&](index_t src) { incoming.push_back(src); });
            Require(incoming == std::vector<index_t>{(dst + 1) % graph.nnodes});
        }
    }
    // Cancellation of every entry must still reclaim the overlay after growth.
    std::vector<EffectiveEdgeDelta> inverse;
    for (index_t dst = 0; dst < graph.nnodes; ++dst)
        inverse.push_back({(dst + 1) % graph.nnodes, dst, -1});
    reverse.Prepare(inverse);
    reverse.Prepare({});
    reverse.Commit();
    for (index_t dst = 0; dst < graph.nnodes; ++dst) {
        std::vector<index_t> incoming;
        reverse.ForEachIncoming(dst, [&](index_t src) { incoming.push_back(src); });
        Require(incoming == std::vector<index_t>{(dst + 1) % graph.nnodes});
    }
    reverse.Prepare(inverse);
    reverse.Commit();
    for (index_t dst = 0; dst < graph.nnodes; ++dst)
        reverse.ForEachIncoming(dst, [](index_t) { Require(false); });
}

static void TestDeltaSort() {
    std::mt19937 random(541);
    sepgraph::concurrency::FixedWorkerPool sort_pool(4);
    for (bool parallel : {false, true})
    for (bool source_ordered : {false, true})
    for (size_t size : {size_t(0), size_t(4095), size_t(4096), size_t(65535), size_t(65536), size_t(65537), size_t(500000)}) {
        std::vector<EffectiveEdgeDelta> records;
        for (size_t i = 0; i < size; ++i)
            records.push_back({static_cast<index_t>(random()),
                static_cast<index_t>(random()), static_cast<int64_t>(i) - 100});
        if (size > 2) {
            records[0] = {0xffffffffU, 0xffffffffU, -3};
            records[1] = records[0];
            records[2] = {0, 0, 7};
        }
        if (source_ordered) std::stable_sort(records.begin(), records.end(),
            [](const EffectiveEdgeDelta &a, const EffectiveEdgeDelta &b) {
                return a.source < b.source;
            });
        auto expected = records;
        const auto less = [](const EffectiveEdgeDelta &a, const EffectiveEdgeDelta &b) {
            if (a.destination != b.destination) return a.destination < b.destination;
            if (a.source != b.source) return a.source < b.source;
            return a.count < b.count;
        };
        std::sort(expected.begin(), expected.end(), less);
        auto stable_expected = records;
        std::stable_sort(stable_expected.begin(), stable_expected.end(),
            [](const EffectiveEdgeDelta &a, const EffectiveEdgeDelta &b) {
                return a.destination < b.destination ||
                    (a.destination == b.destination && a.source < b.source);
            });
        SortEffectiveDeltas(records, parallel ? &sort_pool : nullptr);
        if (size >= 4096) for (size_t i = 0; i < size; ++i) {
            Require(records[i].source == stable_expected[i].source);
            Require(records[i].destination == stable_expected[i].destination);
            Require(records[i].count == stable_expected[i].count);
        }
        Require(std::is_sorted(records.begin(), records.end(),
            [](const EffectiveEdgeDelta &a, const EffectiveEdgeDelta &b) {
                return a.destination < b.destination ||
                    (a.destination == b.destination && a.source < b.source);
            }));
        std::sort(records.begin(), records.end(), less);
        for (size_t i = 0; i < size; ++i) {
            Require(records[i].source == expected[i].source);
            Require(records[i].destination == expected[i].destination);
            Require(records[i].count == expected[i].count);
        }
    }
}

static void TestMaterializeTiles(uint32_t shards) {
    TestGraph graph{127, std::vector<std::vector<index_t>>(127)};
    for (index_t src = 0; src < graph.nnodes; ++src)
        graph.edges[src] = {src, (src + 1) % graph.nnodes, src};
    DynamicReverseIndex serial, parallel;
    serial.Build(graph, 1, shards);
    parallel.Build(graph, 4, shards);
    const std::vector<EffectiveEdgeDelta> delta{{0, 0, -2}, {1, 0, 3}, {2, 1, 1}};
    for (auto *reverse : {&serial, &parallel}) {
        reverse->Prepare(delta);
        reverse->Commit();
    }
    for (size_t size : {size_t(0), size_t(4095), size_t(4096), size_t(4097), size_t(17001)}) {
        std::vector<index_t> destinations(size);
        for (size_t i = 0; i < size; ++i) destinations[i] = (i * 31) % 130;
        std::vector<index_t> expected, actual;
        std::vector<uint64_t> expected_offsets, actual_offsets;
        const auto a = serial.MaterializeIncoming(destinations, expected_offsets, expected);
        const auto b = parallel.MaterializeIncoming(destinations, actual_offsets, actual);
        Require(expected == actual && expected_offsets == actual_offsets);
        Require(a.base_edges_scanned == b.base_edges_scanned);
        Require(a.delta_records_scanned == b.delta_records_scanned);
        Require(a.output_sources == b.output_sources);
    }
}

int main() {
    TestDeltaSort();
    for (uint32_t shards : {1U, 64U}) {
        TestMaterializeTiles(shards);
        TestManyDestinations(shards);
        TestEffectivePhases(shards);
        TestPreflightFailure(shards);
        TestGrowingOverlay(shards);
    }
    sepgraph::concurrency::FixedWorkerPool pool(4);
    for (size_t grain : {size_t(0), size_t(1), size_t(16), size_t(256)}) {
        std::vector<unsigned> visits(1031, 0);
        pool.Run(visits.size(), [&](size_t i) { ++visits[i]; }, grain);
        for (auto count : visits) Require(count == 1);
        bool rejected = false;
        try {
            pool.Run(visits.size(), [&](size_t i) {
                if (i == 17) throw std::runtime_error("injected worker failure");
            }, grain);
        } catch (const std::runtime_error &) { rejected = true; }
        Require(rejected);
        pool.Run(visits.size(), [&](size_t i) { ++visits[i]; }, grain);
        for (auto count : visits) Require(count == 2);
    }
}
