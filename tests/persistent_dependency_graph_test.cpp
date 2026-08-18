#include <algorithm>
#include <cstdlib>
#include <cstdio>
#include <stdexcept>
#include <vector>

#include <framework/persistent_dependency_graph.h>

using sepgraph::runtime::DependencyOwner;
using sepgraph::runtime::PersistentDependencyGraph;
using sepgraph::topology::TopologyMutationBatch;

static void RequireAt(bool condition, int line) {
    if (!condition) {
        std::fprintf(stderr, "requirement failed at line %d\n", line);
        std::abort();
    }
}
#define Require(condition) RequireAt((condition), __LINE__)

static std::vector<index_t> Incoming(const PersistentDependencyGraph &graph,
                                     index_t destination) {
    std::vector<index_t> result;
    graph.ForEachIncoming(destination, [&](index_t source) { result.push_back(source); });
    return result;
}

static std::vector<index_t> SortedIncoming(
        const PersistentDependencyGraph &graph, index_t destination) {
    auto result = Incoming(graph, destination);
    std::sort(result.begin(), result.end());
    return result;
}

int main() {
    PersistentDependencyGraph graph;
    graph.Build({{1, 1, 2}, {2}, {}, {0}}, {1, 0, 0, 1});
    Require(graph.LiveRecordCount() == 5);
    Require((Incoming(graph, 1) == std::vector<index_t>{0, 0}));

    std::vector<index_t> cross;
    graph.ForEachCrossDomainDependency(0, [&](index_t dst, DependencyOwner owner) {
        Require(owner == DependencyOwner::GPU);
        cross.push_back(dst);
    });
    Require((cross == std::vector<index_t>{1, 1, 2}));

    TopologyMutationBatch deletions;
    deletions.deletions = {{0, 1}, {0, 1}, {0, 1}};
    const auto delete_metrics = graph.ApplyBatch(deletions);
    Require(delete_metrics.epoch == 1);
    Require(delete_metrics.retired_records == 2);
    Require(delete_metrics.missing_deletes == 1);
    Require(Incoming(graph, 1).empty());

    TopologyMutationBatch additions;
    additions.additions = {{2, 1}, {0, 1}};
    const auto add_metrics = graph.ApplyPendingAdditions(additions);
    Require(add_metrics.epoch == 1);
    Require((SortedIncoming(graph, 1) == std::vector<index_t>{0, 2}));
    const uint64_t published = graph.Publish();
    Require(published == 1);
    const uint64_t reclaimed = graph.ReclaimThrough(1);
    Require(reclaimed == 2);
    Require(graph.LiveRecordCount() == 5);

    const uint64_t epoch = graph.PublishedEpoch();
    const uint64_t live = graph.LiveRecordCount();
    TopologyMutationBatch invalid;
    invalid.additions = {{99, 0}};
    bool rejected = false;
    try { graph.ApplyBatch(invalid); }
    catch (const std::out_of_range &) { rejected = true; }
    Require(rejected);
    Require(graph.PublishedEpoch() == epoch);
    Require(!graph.HasPendingBatch());
    Require(graph.LiveRecordCount() == live);

    bool owner_rejected = false;
    try {
        graph.ForEachOwnerIncoming(DependencyOwner::CPU, 1, [](index_t) {});
    } catch (const std::invalid_argument &) { owner_rejected = true; }
    Require(owner_rejected);
    return 0;
}
