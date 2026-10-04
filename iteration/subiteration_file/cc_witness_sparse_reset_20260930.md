# CC witness scratch reset: diagnosis and performance handoff

## Two different bottlenecks

CC here means directed minimum reachable label (minimum vertex ID that can
reach a vertex). Changing to undirected union-find is not an equivalent fix.
Unlike positive-distance SSSP/BFS dependencies, equal-label CC dependencies can
cycle. The conservative deletion rule follows equal-label edges, including
large regions whose labels ultimately do not change. Simply restoring the
original's parent-only invalidation would need a separate correctness argument.

The supplied witness A/B logs show, over ten WK/100k batches:

| Measurement | Witness off | Witness on |
|---|---:|---:|
| P0 total, ms | 52343.332 | 16575.610 |
| Affected vertices, sum | 80613375 | 2516 |
| Repair wall time, ms | 47682.883 | 3.154 |
| Witness time, ms | 0 | 15691.067 |

Thus the latest CC *already has* a small repair worklist. Its host proof phase
consumes 94.66% of P0. WK hybrid=2 rerun reproduces slow batches 3, 4, 7 with
unchanged search counts. Switching hybrid mode does not resolve that bottleneck.

## Concrete implementation defect and fix

`DirectedLabelWitness::Prove` formerly called `child_.clear()` for every query.
libstdc++ `_Hashtable::clear()` deallocates live entries **and memsets the full
retained bucket array**. A high-indegree search can insert many neighbors even
when it expands few vertices. All subsequent small queries then repeatedly
zero a peak-sized array. Neither searched_edges nor searched_vertices reports
this work. Cost is driven by the largest previous search and its position in
the batch, not just graph size or final affected count.

Replace clear with iterator erasure of live entries, retaining bucket capacity
without zeroing unused buckets on every query. Reset work now follows actual
search entries. Proof ordering, budgets, certification and repair semantics are
unchanged. `[CC-WITNESS-SCRATCH]` logs actual reset entries and the bucket slots
that the previous clear operation would have zeroed; these are container-work
counters, not hardware traffic measurements.

An isolated before/after benchmark with a 300k-wide search followed by 50k tiny
queries reports 4488.17 ms before versus 31.798 ms after. Both execute 350001
edge visits, 50002 vertex expansions and 50001 successful proofs. Artifacts:
`logs/cc_witness_sparse_reset_20260930/reset_benchmark.*`.
This proves the container reset pathology; real WK/FS speedups remain pending.

## Why the WK/FS observation needs qualification

The user's FS A/B runs with hybrid=2 both failed at queue allocation before
batch 0. The later completed hybrid=0 retry reports 10768.924 ms witness-on
versus 193329.413 ms witness-off; affected counts are 4801 versus 646757684.
The large conservative CC invalidation exists on FS too. Witness fixes most
of it on both datasets, while WK has particularly pronounced proof-time spikes.

The older FS witness-on run has stable 833–904 ms proof times rather than WK's
roughly 3.7–4.0 s spikes. Different search-width histories can explain this
without a larger WK repair frontier. New scratch counters and same-machine
measurements are needed to confirm how much each real workload pays for resets.

`logs/cc_100k_20260930T075203Z/original_comparison.json` explicitly has no FS
original measurement. Therefore the supplied artifacts do not establish that
the current implementation beats original on FS. WK historical original averages
5079.626 ms, but used GPU0/NUMA0; current used GPU2/NUMA1.

## Validation and user-directed handoff

The implementation builds and the binary contains the new scratch log marker.
Before the user's performance-only steering, the existing 63897 randomized
witness checks plus a new wide-then-small regression and reverse-index tests
passed. No new GPU correctness campaign is run after that steering.

`scripts/run_cc_witness_reset_perf.py` prepares performance-only runs, with
`--check=false` and final checksum printing disabled. Each dataset runs fixed,
the user's frozen before binary, and original sequentially on the same GPU/NUMA.
WK uses hybrid=2; all FS variants use hybrid=0 to avoid the known hybrid=2 OOM.
All use cache=2 and the same ten-batch input. Binary hashes, source hashes,
input metadata and command/environment manifests are saved with results.

The runner checks GPU occupancy once, then uses blocking subprocess waits with
no timeouts, polling or periodic log reads. It writes status at case boundaries
and results after exits. It does not resume the paused paper experiment.
The user will launch it in the background and notify us when it completes.
No real-data post-fix speedup or correctness equivalence is claimed yet.
