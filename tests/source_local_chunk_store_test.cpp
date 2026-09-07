#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

#include <groute/graphs/source_local_chunk_store.h>

namespace {

using sepgraph::topology::ChunkArenaOptions;
using sepgraph::topology::HashSequence;
using sepgraph::topology::SourceLocalChunkStore;
using sepgraph::topology::TopologyReplayModel;
using sepgraph::topology::TopologyMutationBatch;

void AssertArenaAccounting(const SourceLocalChunkStore &store) {
    const auto &stats = store.ArenaStats();
    assert(stats.live_capacity_edges + stats.retired_capacity_edges +
           stats.free_capacity_edges == stats.high_water_edges);
    assert(stats.high_water_edges <= stats.capacity_edges);
}

void AssertMatchesOracle(SourceLocalChunkStore &store,
                         const TopologyReplayModel &oracle,
                         index_t source) {
    assert(store.Neighbors(source) == oracle.Neighbors(source));
    assert(store.OrderedHash(source) == HashSequence(oracle.Neighbors(source)));
}

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
    AssertArenaAccounting(store);

    TopologyMutationBatch before_reclaim;
    before_reclaim.additions = {{1, 9}};
    store.ApplyBatch(before_reclaim);
    assert(store.Descriptor(1).index != retired_offset);
    const uint64_t second_epoch = store.Publish();
    assert(second_epoch == 2);

    assert(store.ReclaimThrough(0) == 0);
    assert(store.ReclaimThrough(1) == 1);
    AssertArenaAccounting(store);
    TopologyMutationBatch after_reclaim;
    after_reclaim.additions = {{2, 10}};
    const auto metrics = store.ApplyBatch(after_reclaim);
    assert(metrics.reused_blocks == 1);
    assert(store.Descriptor(2).index == retired_offset);
    const uint64_t third_epoch = store.Publish();
    assert(third_epoch == 3);
    AssertArenaAccounting(store);
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
    AssertArenaAccounting(store);
}

void TestTwoPhaseBatchVisibility() {
    SourceLocalChunkStore store(2, ChunkArenaOptions{64, 64, 4, false});
    store.LoadSource(0, {1, 1});
    store.LoadSource(1, {});
    store.FinalizeLoad();

    TopologyMutationBatch deletions;
    deletions.deletions = {{0, 1}};
    const auto deletion_metrics = store.ApplyBatch(deletions);
    assert(deletion_metrics.epoch == 1);
    assert((store.Neighbors(0) == std::vector<index_t>{1}));
    assert(store.Descriptor(0).version == 1);
    assert(!store.IsPublished());

    TopologyMutationBatch additions;
    additions.additions = {{0, 0}, {1, 0}};
    const auto addition_metrics = store.ApplyPendingAdditions(additions);
    assert(addition_metrics.epoch == 1);
    assert((store.Neighbors(0) == std::vector<index_t>{1, 0}));
    assert((store.Neighbors(1) == std::vector<index_t>{0}));
    assert(store.Descriptor(0).version == 1);
    assert(store.Descriptor(1).version == 1);
    assert(store.Publish() == 1);
    assert(store.IsPublished());
}

void TestSingleCompactWithRepeatedAndMissingDeletes() {
    SourceLocalChunkStore store(1, ChunkArenaOptions{64, 64, 8, false});
    const std::vector<index_t> initial{1, 2, 1, 3, 1, 4};
    store.LoadSource(0, initial);
    store.FinalizeLoad();
    TopologyReplayModel oracle({initial});

    TopologyMutationBatch batch;
    batch.deletions = {{0, 1}, {0, 1}, {0, 9}, {0, 2}};
    batch.additions = {{0, 5}, {0, 1}};
    oracle.ApplyBatch(batch);
    const auto metrics = store.ApplyBatch(batch);

    AssertMatchesOracle(store, oracle, 0);
    assert((store.Neighbors(0) == std::vector<index_t>{3, 1, 4, 5, 1}));
    assert(metrics.missing_deletes == 1);
    assert(metrics.allocations == 0);
    assert(metrics.relocation_copied_bytes == 0);
    assert(metrics.mutation_written_bytes == 5 * sizeof(index_t));
    store.Publish();
}

void TestDirectCowRewriteAfterDeletes() {
    SourceLocalChunkStore store(1, ChunkArenaOptions{64, 64, 4, false});
    const std::vector<index_t> initial{1, 2, 2, 3};
    store.LoadSource(0, initial);
    store.FinalizeLoad();
    TopologyReplayModel oracle({initial});

    TopologyMutationBatch batch;
    batch.deletions = {{0, 2}, {0, 2}};
    batch.additions = {{0, 4}, {0, 5}, {0, 6}};
    oracle.ApplyBatch(batch);
    const auto metrics = store.ApplyBatch(batch);

    AssertMatchesOracle(store, oracle, 0);
    assert((store.Neighbors(0) == std::vector<index_t>{1, 3, 4, 5, 6}));
    assert(metrics.allocations == 1);
    assert(metrics.retired_blocks == 1);
    assert(metrics.relocation_copied_bytes == 2 * sizeof(index_t));
    assert(metrics.mutation_written_bytes == 5 * sizeof(index_t));
    store.Publish();
}

void TestHighDegreeCompactWritesOnce() {
    constexpr uint64_t kDegree = 4096;
    constexpr uint64_t kDeletes = 1000;
    SourceLocalChunkStore store(1, ChunkArenaOptions{8192, 8192, 4, false});
    std::vector<index_t> initial(kDegree, 7);
    store.LoadSource(0, initial);
    store.FinalizeLoad();
    TopologyReplayModel oracle({initial});

    TopologyMutationBatch batch;
    batch.deletions.resize(kDeletes, {0, 7});
    for (index_t destination = 0; destination < 10; ++destination) {
        batch.additions.push_back({0, destination});
    }
    oracle.ApplyBatch(batch);
    const auto metrics = store.ApplyBatch(batch);

    AssertMatchesOracle(store, oracle, 0);
    assert(metrics.allocations == 0);
    assert(metrics.mutation_written_bytes ==
           (kDegree - kDeletes + batch.additions.size()) * sizeof(index_t));
    store.Publish();
}

void TestBatchPreflightFailureIsAtomic() {
    SourceLocalChunkStore store(2, ChunkArenaOptions{16, 16, 4, false});
    const std::vector<index_t> source0{1, 2, 3, 4};
    const std::vector<index_t> source1{5, 6, 7, 8};
    store.LoadSource(0, source0);
    store.LoadSource(1, source1);
    store.FinalizeLoad();
    const auto descriptor0 = store.Descriptor(0);
    const auto descriptor1 = store.Descriptor(1);

    TopologyMutationBatch batch;
    batch.additions = {{0, 9}, {1, 10}};
    bool failed = false;
    try {
        store.ApplyBatch(batch);
    } catch (const std::runtime_error &) {
        failed = true;
    }
    assert(failed);
    assert(store.IsPublished());
    assert(store.Neighbors(0) == source0);
    assert(store.Neighbors(1) == source1);
    assert(store.Descriptor(0).index == descriptor0.index);
    assert(store.Descriptor(1).index == descriptor1.index);
    assert(store.Descriptor(0).version == descriptor0.version);
    assert(store.Descriptor(1).version == descriptor1.version);
}

void TestParallelMatchesSingleWorker() {
    ChunkArenaOptions serial_options{4096, 4096, 4, false};
    serial_options.mutation_workers = 1;
    ChunkArenaOptions parallel_options = serial_options;
    parallel_options.mutation_workers = 4;
    SourceLocalChunkStore serial(64, serial_options);
    SourceLocalChunkStore parallel(64, parallel_options);
    for (index_t source = 0; source < 64; ++source) {
        std::vector<index_t> neighbors;
        for (index_t edge = 0; edge < source % 11; ++edge) {
            neighbors.push_back((source * 7 + edge) % 64);
        }
        serial.LoadSource(source, neighbors);
        parallel.LoadSource(source, neighbors);
    }
    serial.FinalizeLoad();
    parallel.FinalizeLoad();

    TopologyMutationBatch deletions;
    TopologyMutationBatch additions;
    for (index_t source = 0; source < 64; ++source) {
        if (source % 11 != 0) {
            deletions.deletions.push_back({source, (source * 7) % 64});
        }
        additions.additions.push_back({source, (source + 31) % 64});
        additions.additions.push_back({source, (source + 47) % 64});
    }
    const auto serial_delete = serial.ApplyBatch(deletions);
    const auto parallel_delete = parallel.ApplyBatch(deletions);
    const auto serial_add = serial.ApplyPendingAdditions(additions);
    const auto parallel_add = parallel.ApplyPendingAdditions(additions);
    assert(serial_delete.changed_sources == parallel_delete.changed_sources);
    assert(serial_delete.missing_deletes == parallel_delete.missing_deletes);
    assert(serial_add.changed_sources == parallel_add.changed_sources);
    assert(serial_delete.worker_count == 1);
    assert(parallel_delete.worker_count == 4);
    for (index_t source = 0; source < 64; ++source) {
        assert(serial.Neighbors(source) == parallel.Neighbors(source));
        assert(serial.OrderedHash(source) == parallel.OrderedHash(source));
        assert(serial.Descriptor(source).degree == parallel.Descriptor(source).degree);
        assert(serial.Descriptor(source).slab_id == parallel.Descriptor(source).slab_id);
        assert(serial.Descriptor(source).index == parallel.Descriptor(source).index);
        assert(serial.Descriptor(source).version == parallel.Descriptor(source).version);
    }
    assert(serial.Publish() == parallel.Publish());
    assert(serial.EdgeCount() == parallel.EdgeCount());
    AssertArenaAccounting(serial);
    AssertArenaAccounting(parallel);
}

void TestEpochPublicationRejectsInvalidTransitions() {
    SourceLocalChunkStore store(1, ChunkArenaOptions{32, 32, 4, false});
    store.LoadSource(0, {1});
    store.FinalizeLoad();
    bool publish_without_batch_failed = false;
    try {
        store.Publish();
    } catch (const std::logic_error &) {
        publish_without_batch_failed = true;
    }
    assert(publish_without_batch_failed);

    TopologyMutationBatch deletions;
    deletions.deletions = {{0, 1}};
    const auto delete_metrics = store.ApplyBatch(deletions);
    assert(delete_metrics.epoch == 1);
    assert(store.PendingEpoch() == 1);
    assert(store.PublishedEpoch() == 0);
    assert(!store.IsPublished());

    TopologyMutationBatch additions;
    additions.additions = {{0, 2}};
    const auto add_metrics = store.ApplyPendingAdditions(additions);
    assert(add_metrics.epoch == delete_metrics.epoch);
    assert(store.Publish() == 1);
    assert(store.PublishedEpoch() == store.PendingEpoch());
    assert(store.IsPublished());
    AssertArenaAccounting(store);
}


} // namespace

int main() {
    TestBatchOrderingAndDuplicates();
    TestSourceIsolationAndExpansion();
    TestEpochDelayedReuse();
    TestHighDegreeExpansionAndMultipleEpochs();
    TestFixedArenaExhaustion();
    TestPinnedArena();
    TestTwoPhaseBatchVisibility();
    TestSingleCompactWithRepeatedAndMissingDeletes();
    TestDirectCowRewriteAfterDeletes();
    TestHighDegreeCompactWritesOnce();
    TestBatchPreflightFailureIsAtomic();
    TestParallelMatchesSingleWorker();
    TestEpochPublicationRejectsInvalidTransitions();
    std::cout << "source_local_chunk_store_test: passed\n";
    return 0;
}
