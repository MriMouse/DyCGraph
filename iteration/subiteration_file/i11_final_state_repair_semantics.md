# I11 Final-State Repair Semantics

## Scope

The externally visible state is the SSSP fixed point after an entire mixed
batch. The deletion-only intermediate graph is not externally visible. I11
therefore evaluates this execution order:

1. derive invalid vertices from the old shortest-path tree and final edge
   multiplicities;
2. construct the final topology in a pending source-local epoch;
3. invalidate the affected old-tree subtree;
4. publish the final topology once;
5. seed boundary recovery and added-edge improvements together;
6. run one monotone closure on the final topology.

CPU remains the topology constructor. GPU remains the only authoritative SSSP
state executor.

## Preconditions And Invariants

Let `G_e` be the current directed weighted multigraph, `d_e` its valid SSSP
fixed point, `T_e` one tight-parent witness tree, and `G_f` the graph obtained
by applying every deletion and then every addition in input order.

The model requires non-negative edge weights and batch-final visibility.

1. Before the transaction, every finite non-source vertex has a tight parent
   edge in `G_e`.
2. An old tree dependency `parent_e(v) -> v` is broken only when its edge
   multiplicity in `G_f` is zero. Merely appearing in the deletion list is not
   sufficient: another duplicate may remain, or the edge may be re-added.
3. The affected set is the descendant closure in `T_e` of all vertices with a
   broken old tree dependency. Every vertex outside the affected set retains a
   valid path of length `d_e(v)` in `G_f`.
4. Affected values are reset to infinity. Unaffected values are safe upper
   bounds for final distances; insertions may only decrease them.
5. The first unified frontier is the union of:
   - final edges from finite vertices into affected vertices;
   - added edges whose source currently has a finite value.
6. Once an affected source is recovered, ordinary outgoing relaxation covers
   affected-to-affected edges and added edges whose source was initially
   invalid. Closure ends only when the device frontier is empty.

## Why The Seed Set Is Complete

Consider any final shortest path whose destination value differs from the
retained state.

- If the path first enters the affected set, its first crossing edge is a
  boundary-recovery seed. All later edges are reached by closure.
- If the path never enters the affected set but improves an old value, it must
  contain at least one added edge. The first such edge is an addition seed; its
  suffix is reached by closure.
- If an added edge starts at an initially affected source, that source must
  first be recovered through a boundary edge. Its outgoing edges, including
  the addition, are then examined by closure.

Thus no deletion-only fixed point is needed. At quiescence, every final edge
satisfies the Bellman inequality, and every finite non-source value has a
tight witness. This is the SSSP fixed point for `G_f`.

## Epoch Fence

```text
GPU old reader: G_e descriptors + old SPT invalidation
CPU prepare:    private next chunks + compact reverse delta for G_f
                         |
                 join old readers and CPU prepare
                         |
commit:         publish sorted touched-source descriptors as epoch e+1
                         |
GPU closure:    only G_f descriptors; boundary U addition seeds
reclaim:        old touched chunks after final reader completion
```

Prepare cannot mutate current descriptors, current chunk contents, or the
published reverse view. Commit is the only visibility transition. Temporary
versioned storage is bounded by the changed sources, not by the full graph.

## Oracle Evidence

`final_state_repair_model_test` compares the unified model with full Dijkstra
on the final multigraph. It covers named cases for delete-then-readd, duplicate
edge counts, alternate tight predecessors, cross-domain shortcuts, additions
whose source is initially affected, empty phases, and unreachable components.
It also performs 20,000 deterministic random mixed-batch trials. Distances and
existential tight witnesses must match; parent identity may differ on ties.

## Existing-Log Structural Bound

`scripts/analyze_i11_final_state_upper_bound.py` reuses I9 logs and does not run
the GPU. The structural region is deliberately conservative as an admission
signal, not a speedup prediction:

| dataset | paper ms | physical delete ms | deletion repair ms | addition CPU window ms | covered region |
|---|---:|---:|---:|---:|---:|
| Twitter | 568.991 | 115.084 | 46.455 | 100.617 | 262.156 (46.074%) |
| Friendster | 3989.362 | 500.178 | 148.705 | 695.150 | 1344.033 (33.690%) |

Not all covered time is removable. I12 must separately measure one-pass source
materialization, compact reverse-delta construction, overlap, publication, and
the final unified closure. Both datasets exceed the I11 10% admission gate.

## Decision

I11 passes. I12 may implement the single transactional path. A sequential
repair fallback, a full-graph second topology, or a CPU propagation owner is
not authorized by this result.
