#include <framework/dynamic_reverse_index.h>
#include <groute/graphs/source_local_chunk_store.h>
#include <stdexcept>
#include <vector>
using namespace sepgraph::topology;
struct EmptyGraph {
  index_t nnodes = 8;
  struct View {
    uint64_t Degree(index_t) const { return 0; }
    index_t EdgeAt(index_t, uint64_t) const { return 0; }
  };
  View adjacency_view() const { return {}; }
};
void require(bool b) {
  if (!b)
    throw std::runtime_error("I19 work counter mismatch");
}
int main() {
  SourceLocalChunkStore store(8, {128, 128, 4, false, 1});
  store.LoadSource(0, {1, 2, 3, 4});
  store.FinalizeLoad(4);
  sepgraph::runtime::DynamicReverseIndex reverse;
  reverse.Build(EmptyGraph{}, 1);
  TopologyMutationBatch first;
  first.deletions = {{0, 2}};
  first.additions = {{0, 5}};
  GroupedUpdateBatch grouped(first);
  auto d = store.ApplyGroupedPhase(grouped, UpdatePhase::Delete, reverse);
  require(d.deletion_match_reads == 2 && d.mutation_edge_reads == 2 &&
          d.mutation_written_bytes == 8);
  require(reverse.LastPrepareMetrics().overlay_records == 1 &&
          reverse.LastPrepareMetrics().old_records_read == 0);
  auto a = store.ApplyGroupedPhase(grouped, UpdatePhase::Add, reverse);
  require(a.deletion_match_reads == 0 && a.mutation_edge_reads == 0 &&
          a.mutation_written_bytes == 4);
  require(reverse.LastPrepareMetrics().overlay_records == 2);
  store.ReclaimThrough(store.Publish());
  TopologyMutationBatch next;
  next.deletions = {{0, 5}};
  next.additions = {{0, 2}, {0, 6}};
  GroupedUpdateBatch grouped_next(next);
  d = store.ApplyGroupedPhase(grouped_next, UpdatePhase::Delete, reverse);
  require(d.deletion_match_reads == 4 && d.mutation_edge_reads == 0);
  require(reverse.LastPrepareMetrics().old_records_read == 1 &&
          reverse.LastPrepareMetrics().overlay_records == 1);
  a = store.ApplyGroupedPhase(grouped_next, UpdatePhase::Add, reverse);
  require(a.mutation_edge_reads == 3 && a.relocation_copied_bytes == 12 &&
          a.mutation_written_bytes == 20);
  require(reverse.LastPrepareMetrics().old_records_read == 1 &&
          reverse.LastPrepareMetrics().overlay_records == 1);
}
