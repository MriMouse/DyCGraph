# CC repair topology memory bound (2026-09-30)

## Scope and evidence

The CC/PR paper controller (PID 91239) and its active original CC child
(PID 329594) were stopped with SIGSTOP at the user's request. Both remain
paused. The experiment directory contains `pause_20260930.json`, recording the
previous status and active command; `status.json` now says `paused`.
Existing paper binaries, sources, timing logs, and performance CSVs are preserved.
A resumed active run must not count paused wall time as an uninterrupted run.

The archived TW current logs failed at `EnsureGpuAffectedRepairCapacity`'s
source `cudaMalloc`, after collecting about 49.23 million affected vertices.
`RunGpuAffectedRepair` is shared by SSSP, BFS and the current directed CC app:
this was an unbounded allocation in the common path, not a CC-only upload.
CC's equal-label invalidation can make that affected region much larger.

## What origin does, and what we retain

Inspected the exact paper baseline in
`paper/evaluation/raw/cc_pr_20260928/original_src` (the source path in
`original_build/CMakeCache.txt`), especially:

- `include/framework/framework.cuh`: `del_edge`, `update_tree_del`,
  `ExecutePolicy_del_con` and the insertion/convergence path.
- `include/groute/graphs/csr_graph.cuh`: `SwitchZC` and mapped adjacency.
- `samples/hybrid_cc/hybrid_cc.cu`: application operators and batch sequence.

Origin propagates invalidation/convergence over its existing forward graph and
cache/zero-copy paths; it does not build the extra full incoming device CSR
used by current. Its partition scans, parent-based invalidation and iteration
cap are not adopted. Current's directed CC semantics, cycle-safe equal-label
invalidation, vertex seeds, parallel reverse materialization, warp cooperative
pull, owner-local CPU/GPU protocol, grouped mutation, merged publication,
hotness/cache maintenance and insertion schedules remain intact.

## Minimal fix

`include/framework/repair_topology_storage.cuh` provides a shared storage policy:

1. Budget = min(4 GiB, (free device bytes + reusable repair bytes - 512 MiB) / 2),
   floored at zero. `CG_REPAIR_TOPOLOGY_MB` overrides the cap; zero forces mapping.
2. Row offsets receive device budget first. Sources that fit retain device
   access and reusable allocations; arrays that exceed the remaining budget
   are registered in place with `cudaHostRegisterMapped`.
3. A device allocation that races into CUDA OOM falls back to registration.
4. A scoped lease synchronizes and unregisters mapped memory before host
   vectors can be resized, including exception unwinding. Device buffers are
   retained for subsequent batches and bounded by the current budget.
5. Ordered repair's temporary outgoing adjacency uses the same storage class
   and only the remaining topology budget. Its per-vertex queues/state remain
   on device. No repair kernel or CC operator changes are required.

The original source/offset `cudaMalloc` and unconditional edge H2D are removed.
Mapped sources do not require another host copy. The existing host reverse index
and affected incoming materialization remain; this is a bound on additional
repair topology VRAM, not on total VRAM, host RAM, or GPU per-vertex state.

This intentionally preserves device bandwidth for WK-sized repairs that fit.
Always mapping every repair would unnecessarily move repeated small/medium
pull rounds onto PCIe. A new CC-specific push repair would require changing
boundary seeding, ownership and frontier convergence; it is outside this
minimal memory fix. Large mapped repairs still pay PCIe access cost.

## Validation

Artifacts are under `logs/cc_repair_budget_20260930/` (separate from paper data).

- Release builds: hybrid_cc, hybrid_bfs, hybrid_sssp, repair_topology_storage_test.
- Storage CUDA regression: device/mixed/mapped transitions, growing/empty
  vectors, device readback correctness, budget accounting, exception cleanup.
  CUDA compute-sanitizer memcheck: zero errors.
- CC: ten execution configurations plus six stream/input contract cases under
  automatic residency and forced zero-copy (262 recorded phase checks per run);
  independent directed flood-fill checks, all final labels and phase checksums.
  Includes cycles losing bridges, parallel edges, empty phases, cache off,
  sparse initialization, ordered repair, CPU partitions and mixed domain map.
- BFS and SSSP: automatic and forced zero-copy, block/thread/ordered schedules;
  FIFO/Dijkstra phase oracles and final parent witnesses (18 phase checks per run).
- Mixed residency fixture: 8192 vertices, 540607 edges before deletion,
  1 MiB budget, device offsets plus mapped sources over three batches;
  six independent phase checks and all final labels passed.

Real TW first-batch validation and WK before/after performance results are
recorded below once complete. These checks do not resume the paper campaign.

### WK residency/performance sanity check

Same GPU 3 and flags, three batches on WK/1k, before/after binaries retained or
hashed in the verification report. Both runs exited 0, reported application
success and identical final checksum `10205551745150220878`.

| Metric | Before | After |
|---|---:|---:|
| Three batch total | 16247.398 ms | 16648.460 ms |
| Repair closure total | 9838.838 ms | 9064.513 ms |
| Repair iterations | 105 | 97 |
| Closure per iteration | 93.70 ms | 93.45 ms |

The after run used 1,811,610,248–1,811,610,336 device topology bytes,
zero mapped bytes, within its 4 GiB cap. Thus the repeated pull remained on
GPU memory. Total batch time was +2.47% in this single pair; asynchronous
iteration counts and host materialization time vary. TW was loading on another
GPU during these checks. This is a residency/performance sanity check, not a
statistical speedup claim or a replacement for paper measurements.

### User handoff

The user requested no further polling while TW completes. Periodic GPU sampling
and process polling were stopped. TW application PID 364808 continues.
`logs/cc_repair_budget_20260930/wait_tw.py` waits on a pidfd exit event (no periodic
polling) and writes `TW_supervision.json` with the three oracle checks and final
application marker. The original test timeout supervisor was suspended to allow
the two long input scans; its eventual wrapper exit status may reflect that
deadline, so the explicit validation report records actual application checks.
The paper controller and paper original CC child remain paused independently.
Real TW results have not yet been assessed; no claim of a completed TW validation
is made in this handoff.
