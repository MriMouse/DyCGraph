# Evaluation data status and remaining experiments (2026-09-22)

## Current timing export

`data/timing_modes_20260921.csv` contains all 204 scheduled runs from the
2026-09-21 timing sweep. Of these, 170 have complete P0 timing, 16 have useful
partial P0 timing, and 18 produced no P0 timer. Missing values are `NULL`.

The current data can support a preliminary evaluation draft:

- update-size trends on OK, WK, TW, and FS at cache=2;
- cache=2 versus cache=4 screening on OK, WK, and TW;
- ordered versus unordered screening on EU, USA, and TW;
- regular, large, and auto maintenance screening around the 1M boundary;
- capacity/failure reporting for FS cache=4 and UK.

It is not yet a final overall-performance result. The paper cohort has one run
per configuration, the mode cohorts have two screening repeats, and the
original/current systems do not yet share a validated result oracle.

## P0: blockers before publishing cross-system speedup

1. Establish a common correctness oracle for original and current binaries.
   Compare initial, deletion-stage, and final topology/distance state on a small
   graph against CPU recomputation. Use the same distance digest implementation
   on both systems and locate the first divergent batch/vertex. Preserve the
   unmodified original result and identify any repaired baseline separately.
2. Resolve original-run nondeterminism seen in the earlier matrix. Repeats that
   produce different final states cannot be summarized by median time as one
   valid baseline.
3. Fix or explicitly exclude the FS ordered-path `invalid configuration
   argument` failure. Reproduce the known 2-batch/5-batch prefixes, identify the
   CUDA call, and run a full 10-batch regression after the fix.
4. Freeze the final SSSP binary and the mode-selection rule before formal runs.
   A defensible rule is graph/workload based (for example, ordered on declared
   road graphs), selected before seeing the final timing repeats. Report both
   modes in the applicability study.

## P1: experiments required for the main paper claims

### Overall SSSP performance

- Use at least OK, WK, TW, FS, EU, and USA; report UK as a measured capacity
  failure unless a same-resource feasible configuration is designed for both
  systems.
- Compare the current system with the original Grapin baseline under identical
  graph, updates, source, weight rule, cache budget, NUMA placement, and timing
  boundary. Add full GPU recomputation as a simple reference if it is available.
- Use 10 batches and at least three interleaved independent process repeats;
  five repeats are preferable for the main 100K result. Report median and
  dispersion and retain the first batch.
- Run correctness separately on the same frozen binaries and input sequence so
  checking overhead is not mixed into performance.
- Add the missing original/current road-graph comparisons for EU and USA. The
  present mode data is current-only and cannot support external speedup.

### Component ablation on the final implementation

Each ablation needs the same input and convergence semantics, a correctness
gate, complete P0 time, and mechanism-specific work counters.

1. Compact affected-only deletion recovery versus the correct wider preparation
   path: report affected vertices, incoming edges/bytes, repair work, and P0.
2. Exact-source device closure versus the correct all-vertex/partition seed
   path: report seeded/processed sources and edges, waves/synchronizations, and
   P0.
3. Source-local topology maintenance plus sparse publication: compare a valid
   equivalent maintenance path, or report traffic/work scaling if no safe off
   switch exists. Include changed sources, descriptor bytes, mutation,
   publication, CPU RSS, pinned memory, and GPU peak memory.
4. Ordered versus unordered propagation: use EU/USA as positive cases and
   TW/FS as counterexamples. Separate deletion and insertion effects if the
   implementation can expose correct independent switches; otherwise state
   that the current switch controls both.
5. Large-batch shared maintenance versus regular: run representative 1M and
   10M social workloads with the same cohort for both modes. The present 1M
   two-batch results are screening evidence, not a long-sequence result.

### Breakdown and mechanism evidence

- Give a P0 breakdown for at least one social graph and one road graph:
  topology mutation/publication, deletion recovery, insertion propagation,
  hotness/candidate selection, and cache eviction/compaction/load.
- Pair time with work amplification: affected ratio, changed sources, prepared
  incoming edges, processed edges, successful relaxations, repeated vertex or
  source processing, and wave count. This is needed to explain why ordered mode
  helps road graphs and hurts TW.
- Do not sum nested timers. Reconcile the breakdown with the outer P0 total and
  report the residual.

### Scalability and resources

- Batch-size scaling: 1K, 10K, 100K, 1M, and a legal 10M cohort where feasible.
  Use the same base graph and batch semantics within a curve.
- Graph-size scaling: use controlled R-MAT or sampled graph sizes so graph size
  changes while the update rule remains fixed.
- Resource table: GPU peak memory, CPU RSS, pinned memory, initialization time,
  and per-batch temporary peak. Include FS cache=4 and UK OOM as capacity limits.
- Cache-budget sensitivity should use budgets feasible for both systems. Current
  4GB failures on a 16GB V100 cannot be treated as timing results.

## P1 scope decision: algorithm coverage

The design text currently describes a framework broader than SSSP. BFS now has
small/synthetic correctness and single-run mode screening, but it lacks formal
real-graph performance and an external baseline. CC has no equivalent final
evidence.

Choose one of these before submission:

- retain the general incremental-graph claim and add real-graph BFS plus CC
  correctness, overall performance, and representative ablations; or
- scope the paper and contribution statements explicitly to dynamic SSSP, using
  BFS only as preliminary generality evidence and making no CC performance
  claim.

The first option is stronger but much more expensive. The second is currently
better supported by the implementation and evidence.

## P2: useful strengthening experiments

- Source sensitivity: repeat representative graphs with multiple reachable
  sources or justify a deterministic source-selection policy.
- Update sensitivity: vary insertion/deletion ratio and locality; keep actual
  effective updates visible because requested updates can be invalid/no-op.
- Cache patch/gate ablation on the final binary, if it remains in the paper;
  otherwise keep it as an implementation detail.
- CPU mutation worker sensitivity (1 versus 20 is sufficient) on the final
  version if parallel mutation is claimed as a performance contribution.
- A second GPU generation or machine improves external validity but is not a
  prerequisite if the single-machine limitation is stated clearly.
- Long-sequence stability beyond 10 batches for reverse-index growth, cache
  churn, arena capacity, and memory reclamation.

## Recommended execution order

1. Resolve the common-oracle/baseline mismatch and FS ordered crash.
2. Freeze binary, datasets, cache budget, timing boundary, and mode policy.
3. Run correctness qualification for every configuration used in headline
   plots.
4. Run interleaved overall SSSP repeats.
5. Run only the ablations that correspond to retained paper claims.
6. Collect breakdown/work counters and resource peaks.
7. Add BFS/CC experiments only after the paper scope decision.

This order prevents a large timing rerun from becoming unusable after a
correctness or configuration change.
