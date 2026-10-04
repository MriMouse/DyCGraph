# Directed CC deletion fast path (2026-09-30)

## Diagnosis and choice

Choose option 1: retain the shared SSSP/BFS engine and fix CC deletion seeding and invalidation boundaries.
The existing CC insertion path already uses grouped mutation, source-local
chunks, merged publication, strict-decrease frontiers, CPU/GPU ownership and
cache maintenance. Copying the SSSP sample does not remove the cause:
positive-distance parent dependencies become cyclic at zero traversal cost.
The directed CC contract remains minimum ID reaching each vertex, not an
undirected union operation.

The previous WK/1k logs invalidate about 8.06 million vertices and materialize
about 436.8 million incoming edges per batch. This dominates the batch, despite
only 500 deleted records. Equal-label dependency flooding is conservative and
correct, but unnecessary when another rooted route survives.

## Change

- `CC::kRootedDeletionWitness` opts only directed CC into a pre-invalidation
  proof; SSSP, BFS and PR default to false.
- Commit the whole grouped deletion phase first, preserving the effective
  reverse index's multiplicity and missing-delete semantics.
- Screen deletion endpoints on GPU. If none are potential equal-label
  dependencies, do not copy the full labels to the host.
- For candidate endpoints, copy old labels once. Search incoming edges for an
  actual path from the old minimum-label root. Cache only proven paths, only
  within this phase. Search sorted incoming rows toward low-ID vertices first.
- Suppress certified invalidation seeds. Expand the remaining seeds over current
  forward chunks, proving still-live boundary vertices before crossing them.
  Upload this closed affected set to the shared reset and GPU/CPU affected repair
  executor, including its bounded device/mapped topology storage.
- Reverse existence queries stop immediately on a witness or edge-budget limit.
  The old callback scanned the rest of a high-indegree row even after finding
  the witness; this exhausted the budget on WK and was explicitly corrected.
- If the screening budget is exhausted, discard its partial frontier and use
  the existing cycle-safe GPU invalidation from the uncertified seeds. No new
  repair edge mirror is built.
- `CG_CC_ROOTED_WITNESS=0` selects the old seeding path for comparisons.
  `[CC-ROOTED-WITNESS]` reports proof work and time. All proof/mutation work is
  inside the existing P0 timer. Independent oracle checks remain outside it.

Proof budget is max(1,000,000, candidates * 4096) incoming visits and
max(100,000, candidates * 128) expanded vertices per deletion phase. Budget is
enforced through early termination of reverse queries. Forward screening has
an edge budget and a 100,000-affected-vertex cutoff; exhaustion discards its
partial region and runs the ordinary GPU invalidation. Exhaustion never guesses
labels. `[CC-WITNESS-FRONTIER] closed` distinguishes completed screening from
fallback; `[CC-ROOTED-WITNESS] fallback` counts initial uncertified seeds.

## Why this is safe

Deleting edges cannot lower a minimum reachable label. A surviving path from
old_label[v] to v proves the matching upper bound, so v's answer is unchanged.
Every cached proof is rooted in the post-delete graph; equal-label cycles do
not certify themselves. Any invalid old-label path crosses a deleted edge.
Its endpoint is either certified (and can provide a surviving suffix witness)
or seeds the same conservative invalidation as before. Thus suppressed seeds
cannot hide a necessary label increase. Proofs never survive into another batch
or across an insertion phase.

This is a minimal redundant-deletion fast path, not a guarantee that arbitrary
large directed cuts become as cheap as sparse SSSP repairs. Unproven cuts can
still use the expensive conservative repair. Candidate batches also retain an
O(V) label D2H copy; no-candidate batches avoid that copy.

## Validation artifacts

`logs/cc_witness_20260930/` is independent of the paused paper campaign. Existing
paper logs, frozen sources and published timing data are not overwritten.
`manifest.json` records source/binary hashes, run flags and configurations.

- `directed_label_witness_test`: 63,897 randomized before/after-cut queries
  against an independent fixed-point oracle, rooted/disconnected cycles, and
  exhausted search budgets. Assertions are enabled in Release builds.
- CC GPU smoke: all labels and each phase checksum against independent directed
  flood fill; block/thread/ordered, cache off, mixed CPU/GPU, sparse init,
  automatic and mapped repair, and optimization disabled.
- Added directed diamonds with a surviving alternative, last-route cuts,
  simultaneous multi-edge cuts into cycles, and insertion followed by deletion
  to reject stale cross-batch proofs.
- BFS and SSSP: independent phase oracles and final parent witnesses.

Performance and real-WK checked results are appended after runs finish.

### User handoff

At the user's request, periodic monitoring stops here. Final code is implemented
and built. `frontier_smoke` and `frontier_mapped` pass all labels and phase
checksums (including CPU ownership and screening disabled). Random affected-set
checks also pass for all 2,000 graph/cut trials. The reverse-index early-exit
regression passes. BFS/SSSP have been rebuilt; their earlier oracle regressions
passed, before the final CC-only frontier screening and reverse early-exit API.

The final-version WK/100k run is PID 642434 on GPU 2, three batches with
`--check=true`, logging to `logs/cc_witness_20260930/WK_100k_frontier.log`.
`wait_final.py` waits once on a pidfd exit event (no periodic polling) and writes
`final_validation.json`, checking six phase oracles, the final oracle, completion
marker, batch timings and screened frontier sizes. No claim of completed real-WK
GPU performance validation is made yet. `manifest_final.json` records the loaded
binary hash and the final workspace hashes.

A CPU diagnostic on WK/100k's first batch found 47,699 candidate seeds, 47,485
rooted proofs and a closed affected set of 251 vertices after 1,630 forward edge
visits. This supports the work-reduction hypothesis but is not a GPU timing.
Other WK logs in this directory were generated before the final frontier fix.
Do not report them as the final version's performance.

The default `/usr/local/cuda/bin/compute-sanitizer` reports `Device not supported`;
the app's checks passed during that attempt, but no sanitizer pass is claimed.

### Completed final WK/100k validation

Six phase oracles and the final oracle passed (zero errors), with application success. The event reporter did not leave its promised JSON; final_validation.json was reconstructed directly from the completed log at user follow-up.

Three batches: [1284.061, 954.152, 1210.96] ms, mean 1149.724 ms. Historical r1 matching batches: previous current 5678.168 ms, original 473.994 ms. Observed improvement 4.94x, still 2.43x slower than original. Final check=true versus historical check=false limits strict timing comparability.

Affected vertices: 251, 279, 257; incoming repair edges: 123, 133, 116; GPU closure: 0.191, 0.197, 0.194 ms. All screened frontiers closed without fallback. Rooted witness processing averages 908.402 ms (79.0% of total). The near-global GPU repair bottleneck is fixed, but end-to-end high-performance parity with origin/SSSP/BFS is not achieved. Further optimization must target host witness processing and state transfer, not the now-submillisecond GPU closure.
