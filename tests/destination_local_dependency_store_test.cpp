#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <framework/destination_local_dependency_store.h>

using sepgraph::runtime::DependencyChunkOptions;
using sepgraph::runtime::DestinationLocalDependencyStore;
using sepgraph::topology::TopologyMutationBatch;

static void RequireAt(bool condition, int line) {
    if (!condition) {
        std::fprintf(stderr, "requirement failed at line %d\n", line);
        std::abort();
    }
}
#define Require(condition) RequireAt((condition), __LINE__)

static bool SameMultiset(std::vector<index_t> lhs,
                         std::vector<index_t> rhs) {
    std::sort(lhs.begin(), lhs.end());
    std::sort(rhs.begin(), rhs.end());
    return lhs == rhs;
}

int main() {
    DependencyChunkOptions options;
    options.capacity_edges = 256;
    options.slab_capacity_edges = 256;
    options.pinned = false;
    DestinationLocalDependencyStore store(5, options);
    store.LoadDestination(0, {3});
    store.LoadDestination(1, {0, 0, 2});
    store.LoadDestination(2, {});
    store.LoadDestination(3, {1, 4});
    store.LoadDestination(4, {});
    store.FinalizeLoad(6);

    Require(store.Descriptor(1).capacity == 3);
    Require(store.MemoryModel().live_capacity_edges == 6);
    Require(store.MemoryModel().live_amplification == 1.0);

    TopologyMutationBatch batch;
    batch.deletions = {{0, 1}, {0, 1}, {0, 1}};
    batch.additions = {{3, 1}, {4, 1}, {2, 2}};
    const auto metrics = store.ApplyBatch(batch);
    Require(metrics.missing_deletes == 1);
    Require(metrics.touched_destinations == 2);
    Require(metrics.scanned_incoming_edges == 3);
    Require(metrics.allocations == 1);
    Require(store.Descriptor(1).capacity == 3);
    Require(store.Descriptor(2).capacity == 1);
    Require((store.Sources(1) == std::vector<index_t>{2, 3, 4}));
    Require((store.Sources(2) == std::vector<index_t>{2}));
    Require(store.Publish() == 1);

    TopologyMutationBatch growth;
    growth.additions = {{0, 1}, {1, 1}};
    const auto growth_metrics = store.ApplyBatch(growth);
    Require(growth_metrics.allocations == 1);
    Require(store.Descriptor(1).capacity == 8);
    Require(store.MemoryModel().live_amplification < 2.0);
    Require(store.Publish() == 2);
    Require(store.ReclaimThrough(2) == 1);

    DependencyChunkOptions growth_options = options;
    Require(DestinationLocalDependencyStore::ExpandedCapacity(
        1000, 1001, growth_options) == 1256);
    Require(DestinationLocalDependencyStore::ExpandedCapacity(
        1024, 1025, growth_options) == 1280);
    Require(DestinationLocalDependencyStore::ExpandedCapacity(
        8, 9, growth_options) == 16);

    TopologyMutationBatch invalid;
    invalid.additions = {{99, 0}};
    const auto before = store.Sources(0);
    bool rejected = false;
    try { store.ApplyBatch(invalid); }
    catch (const std::out_of_range &) { rejected = true; }
    Require(rejected);
    Require(!store.HasPendingBatch());
    Require(store.Sources(0) == before);

    DependencyChunkOptions phased_options = options;
    phased_options.capacity_edges = 64;
    phased_options.slab_capacity_edges = 64;
    DestinationLocalDependencyStore phased(5, phased_options);
    phased.LoadDestination(0, {});
    phased.LoadDestination(1, {0, 0, 2});
    phased.LoadDestination(2, {});
    phased.LoadDestination(3, {});
    phased.LoadDestination(4, {});
    phased.FinalizeLoad(3);
    TopologyMutationBatch phased_batch;
    phased_batch.deletions = {{0, 1}};
    phased_batch.additions = {{3, 1}, {4, 2}};
    const auto plan = phased.PrepareBatch(phased_batch);
    Require(plan.epoch == 1);
    Require(phased.HasPendingBatch());
    Require((phased.Sources(1) == std::vector<index_t>{0, 0, 2}));
    bool wrong_phase = false;
    try { phased.ApplyPreparedAdditions(); }
    catch (const std::logic_error &) { wrong_phase = true; }
    Require(wrong_phase);
    phased.ApplyPreparedDeletions();
    Require(phased.DeletionsApplied());
    Require(SameMultiset(phased.Sources(1), {0, 2}));
    Require(phased.Sources(2).empty());
    wrong_phase = false;
    try { phased.ReclaimThrough(0); }
    catch (const std::logic_error &) { wrong_phase = true; }
    Require(wrong_phase);
    phased.ApplyPreparedAdditions();
    Require(SameMultiset(phased.Sources(1), {0, 2, 3}));
    Require((phased.Sources(2) == std::vector<index_t>{4}));
    Require(phased.PublishedEpoch() == 0);
    Require(phased.Publish() == 1);
    wrong_phase = false;
    try { phased.ApplyPreparedDeletions(); }
    catch (const std::logic_error &) { wrong_phase = true; }
    Require(wrong_phase);

    // Empty phases still advance the explicit state machine. This matters for
    // insertion-only and deletion-only production batches.
    TopologyMutationBatch insertion_only;
    insertion_only.additions = {{1, 0}};
    phased.PrepareBatch(insertion_only);
    phased.ApplyPreparedDeletions();
    Require(phased.Sources(0).empty());
    phased.ApplyPreparedAdditions();
    Require((phased.Sources(0) == std::vector<index_t>{1}));
    Require(phased.Publish() == 2);

    TopologyMutationBatch deletion_only;
    deletion_only.deletions = {{1, 0}};
    phased.PrepareBatch(deletion_only);
    phased.ApplyPreparedDeletions();
    Require(phased.Sources(0).empty());
    phased.ApplyPreparedAdditions();
    Require(phased.Publish() == 3);

    TopologyMutationBatch empty_batch;
    phased.PrepareBatch(empty_batch);
    phased.ApplyPreparedDeletions();
    phased.ApplyPreparedAdditions();
    Require(phased.Publish() == 4);

    // A high-degree destination freezes the 5/4 growth rule and 8-edge
    // alignment independently of the small examples above.
    DependencyChunkOptions high_degree_options = options;
    high_degree_options.capacity_edges = 3000;
    high_degree_options.slab_capacity_edges = 3000;
    DestinationLocalDependencyStore high_degree(1002, high_degree_options);
    std::vector<index_t> thousand(1000);
    for (index_t i = 0; i < thousand.size(); ++i) thousand[i] = i;
    high_degree.LoadDestination(0, thousand);
    for (index_t destination = 1; destination < 1002; ++destination)
        high_degree.LoadDestination(destination, {});
    high_degree.FinalizeLoad(1000);
    TopologyMutationBatch high_degree_growth;
    high_degree_growth.additions = {{1000, 0}};
    high_degree.ApplyBatch(high_degree_growth);
    Require(high_degree.Descriptor(0).capacity == 1256);
    Require(high_degree.MemoryModel().live_capacity_edges == 1256);
    Require(high_degree.MemoryModel().live_amplification < 1.255);
    high_degree.Publish();

    // Allocation is preflighted for the entire batch. Failure must leave all
    // destinations and epoch state untouched.
    DependencyChunkOptions tight_options = options;
    tight_options.capacity_edges = 20;
    tight_options.slab_capacity_edges = 20;
    DestinationLocalDependencyStore tight(3, tight_options);
    tight.LoadDestination(0, {0, 1});
    tight.LoadDestination(1, {0, 1});
    tight.LoadDestination(2, {});
    tight.FinalizeLoad(4);
    TopologyMutationBatch too_large;
    for (int i = 0; i < 7; ++i) {
        too_large.additions.push_back({2, 0});
        too_large.additions.push_back({2, 1});
    }
    rejected = false;
    try { tight.ApplyBatch(too_large); }
    catch (const std::runtime_error &) { rejected = true; }
    Require(rejected);
    Require(!tight.HasPendingBatch());
    Require((tight.Sources(0) == std::vector<index_t>{0, 1}));
    Require((tight.Sources(1) == std::vector<index_t>{0, 1}));
    Require(tight.PublishedEpoch() == 0);

    // The full mixed batch is preflighted before deletion visibility changes.
    TopologyMutationBatch phased_too_large;
    phased_too_large.deletions = {{0, 0}};
    for (int i = 0; i < 7; ++i) {
        phased_too_large.additions.push_back({2, 0});
        phased_too_large.additions.push_back({2, 1});
    }
    rejected = false;
    try { tight.PrepareBatch(phased_too_large); }
    catch (const std::runtime_error &) { rejected = true; }
    Require(rejected);
    Require(!tight.HasPendingBatch());
    Require((tight.Sources(0) == std::vector<index_t>{0, 1}));

    // Reclaimed blocks are reused only by an exact-size request.
    DependencyChunkOptions reuse_options = options;
    reuse_options.capacity_edges = 40;
    reuse_options.slab_capacity_edges = 40;
    DestinationLocalDependencyStore reuse(3, reuse_options);
    reuse.LoadDestination(0, {0, 1, 2, 0, 1, 2, 0, 1});
    reuse.LoadDestination(1, {});
    reuse.LoadDestination(2, {});
    reuse.FinalizeLoad(8);
    TopologyMutationBatch relocate;
    relocate.additions = {{0, 0}};
    reuse.ApplyBatch(relocate);
    reuse.Publish();
    Require(reuse.ReclaimThrough(1) == 1);
    TopologyMutationBatch exact_reuse;
    for (int i = 0; i < 8; ++i) exact_reuse.additions.push_back({0, 1});
    const auto reuse_metrics = reuse.ApplyBatch(exact_reuse);
    Require(reuse_metrics.reused_blocks == 1);
    Require(reuse.Descriptor(1).capacity == 8);
    reuse.Publish();
    return 0;
}
