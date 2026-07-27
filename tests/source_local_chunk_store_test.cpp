#include <cassert>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

#include <groute/graphs/source_local_chunk_store.h>

namespace {

using sepgraph::topology::ChunkArenaOptions;
using sepgraph::topology::SourceLocalChunkStore;
using sepgraph::topology::TopologyMutationBatch;

void TestBatchOrderingAndDuplicates() {
    SourceLocalChunkStore store(4, ChunkArenaOptions{128, 128, 4, false});
    store.LoadSource(0, {1, 1, 2});
    store.LoadSource(1, {});
    store.LoadSource(2, std::vector<index_t>(32, 7));
    store.LoadSource(3, {});
    store.FinalizeLoad();

    TopologyMutationBatch batch;
    batch.deletions = {{0, 1}, {1, 99}, {2, 7}};
    batch.additions = {{0, 3}, {1, 4}, {0, 1}};
    const auto metrics = store.ApplyBatch(batch);
    assert(!store.IsPublished());
    assert(metrics.touched_sources == 3);
    assert(metrics.changed_sources == 3);
    assert(metrics.missing_deletes == 1);
    assert((store.Neighbors(0) == std::vector<index_t>{1, 2, 3, 1}));
    assert((store.Neighbors(1) == std::vector<index_t>{4}));
    assert(store.Neighbors(2).size() == 31);
    assert(store.EdgeCount() == 36);
    const uint64_t published = store.Publish();
    assert(published == 1);
    assert(store.IsPublished());
}

void TestSourceIsolationAndExpansion() {
    SourceLocalChunkStore store(3, ChunkArenaOptions{128, 128, 2, false});
    store.LoadSource(0, {1, 2});
    store.LoadSource(1, {8, 9});
    store.LoadSource(2, {});
    store.FinalizeLoad();

    const auto untouched_before = store.Descriptor(1);
    const auto untouched_neighbors = store.Neighbors(1);
    const auto old_source_offset = store.Descriptor(0).index;
    TopologyMutationBatch batch;
    batch.additions = {{0, 3}, {0, 4}, {0, 5}};
    const auto metrics = store.ApplyBatch(batch);
    assert(metrics.changed_sources == 1);
    assert(metrics.allocations == 1);
    assert(metrics.relocation_copied_bytes == 2 * sizeof(index_t));
    assert(store.Descriptor(0).index != old_source_offset);
    assert(store.Descriptor(1).index == untouched_before.index);
    assert(store.Descriptor(1).degree == untouched_before.degree);
    assert(store.Descriptor(1).slab_id == untouched_before.slab_id);
    assert(store.Descriptor(1).version == untouched_before.version);
    assert(store.Neighbors(1) == untouched_neighbors);
    const uint64_t published = store.Publish();
    assert(published == 1);
}

void TestEpochDelayedReuse() {
    SourceLocalChunkStore store(4, ChunkArenaOptions{64, 64, 4, false});
    store.LoadSource(0, {1, 2, 3, 4});
    store.LoadSource(1, {});
    store.LoadSource(2, {});
    store.LoadSource(3, {});
    store.FinalizeLoad();
    const uint64_t retired_offset = store.Descriptor(0).index;

    TopologyMutationBatch grow;
    grow.additions = {{0, 5}};
    store.ApplyBatch(grow);
    const uint64_t first_epoch = store.Publish();
    assert(first_epoch == 1);
    assert(store.ArenaStats().retired_capacity_edges == 4);

    TopologyMutationBatch before_reclaim;
    before_reclaim.additions = {{1, 9}};
    store.ApplyBatch(before_reclaim);
    assert(store.Descriptor(1).index != retired_offset);
    const uint64_t second_epoch = store.Publish();
    assert(second_epoch == 2);

    assert(store.ReclaimThrough(0) == 0);
    assert(store.ReclaimThrough(1) == 1);
    TopologyMutationBatch after_reclaim;
    after_reclaim.additions = {{2, 10}};
    const auto metrics = store.ApplyBatch(after_reclaim);
    assert(metrics.reused_blocks == 1);
    assert(store.Descriptor(2).index == retired_offset);
    const uint64_t third_epoch = store.Publish();
    assert(third_epoch == 3);
}

void TestHighDegreeExpansionAndMultipleEpochs() {
    SourceLocalChunkStore store(2, ChunkArenaOptions{8192, 8192, 4, false});
    store.LoadSource(0, std::vector<index_t>(1024, 7));
    store.LoadSource(1, {});
    store.FinalizeLoad();

    TopologyMutationBatch batch;
    batch.additions.resize(1025, {0, 8});
    const auto first = store.ApplyBatch(batch);
    assert(first.allocations == 1);
    assert(store.Neighbors(0).size() == 2049);
    const uint64_t first_epoch = store.Publish();
    assert(first_epoch == 1);
    assert(store.ReclaimThrough(1) == 1);

    TopologyMutationBatch second;
    second.deletions = {{0, 7}, {0, 8}};
    store.ApplyBatch(second);
    const uint64_t second_epoch = store.Publish();
    assert(second_epoch == 2);
    assert(store.PublishedEpoch() == 2);
}

void TestFixedArenaExhaustion() {
    SourceLocalChunkStore store(1, ChunkArenaOptions{4, 4, 4, false});
    store.LoadSource(0, {1, 2, 3, 4});
    store.FinalizeLoad();
    TopologyMutationBatch batch;
    batch.additions = {{0, 5}};
    bool failed = false;
    try {
        store.ApplyBatch(batch);
    } catch (const std::runtime_error &) {
        failed = true;
    }
    assert(failed);
    assert(store.IsPublished());
    assert((store.Neighbors(0) == std::vector<index_t>{1, 2, 3, 4}));
}

void TestPinnedArena() {
    SourceLocalChunkStore store(1, ChunkArenaOptions{64, 64, 4, true});
    store.LoadSource(0, {1, 2});
    store.FinalizeLoad();
    assert(store.ArenaStats().pinned);
}

} // namespace

int main() {
    TestBatchOrderingAndDuplicates();
    TestSourceIsolationAndExpansion();
    TestEpochDelayedReuse();
    TestHighDegreeExpansionAndMultipleEpochs();
    TestFixedArenaExhaustion();
    TestPinnedArena();
    std::cout << "source_local_chunk_store_test: passed\n";
    return 0;
}
