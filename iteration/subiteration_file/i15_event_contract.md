# I15 hotness/candidate event contract

Status (2026-09-07): corrected production baseline accepted; both status files in
`logs/i15_pairing_fix_20260907/validation/` are complete and all 22 audit samples
have zero pairing errors. TW/FS mean batch times are 52.0702/346.0386 ms. This
contract and its CPU model do not replace production candidate selection.

## Sampling and window semantics

The observable sample is after initial SSSP (batch -1), then after both deletion
repair and insertion closure of each batch. `compute_hot_vertices_sssp()` scores
before `reset_hotness()` shifts the four byte counters. For sample t:

```
c_t(v) = number of existing hotness[0] increments in sample t modulo 256
w_t(v) = c_t(v) + c_(t-1)(v) + c_(t-2)(v) + c_(t-3)(v)
score_t(v) = buffer_t(v) == UINT32_MAX ? 0 : w_t(v)
```

The sum is in [0, 1020]; only individual counters wrap. Initial counter state
is zero (`PMAGraph` allocates vertices with calloc). Initialization participates
as a full sample and expires at batch 3. The ring slot from four samples ago is
subtracted before adding the current counter. Masking must retain unmasked
window history, since a vertex may become reachable again before expiry.

## Authoritative Events

| Event | Existing source | Required behavior |
|---|---|---|
| Counter write | Active hotness increment sites in `variants/sync_push_dd.cuh` | Preserve actual writes and modulo-256 multiplicity, including cached/uncached branches and deletion invalidation traversal. A 256-increment sample is an event with a zero final counter. |
| Expiry | Sample recorded four samples earlier | Subtract the expired byte even if no new traversal or topology event touches this vertex. Zero byte records need no expiry work. |
| Mask change | Final `m_node_buffer_datum[v] == UINT32_MAX` at the sampling fence | Recompute the masked score without destroying history. Finite distance changes alone do not change the mask. |
| Degree change | Effective topology publication to `sync_vertices_[v].degree` | Update candidate edge weight even if score, reachability and rank are unchanged. Use final authoritative degree after both phases. |
| Initial state | Initial SSSP, initial degrees and buffer mask | Materialize every vertex, including untouched zero-score vertices. Account for its later expiry inside batch timing. |

The current `RunExactGpuClosure()` and `RunGpuAffectedRepair()` do not increment
hotness. Their distance changes can create mask events, but are not counter
events. `RelaxCTADB_del()` does increment hotness when visiting its work source,
without a successful-combine predicate. Consequently, neither “all successful
distance changes” nor “all affected vertices” is an exact counter event stream.
An implementation must instrument actual counter writers, not inferred work
counts. Existing path behavior is the oracle; adding new hotness increments to
these closures would require another semantic baseline.

At each sampling fence, the dirty union is current counter writers, nonzero
expiry records, final mask changes and final degree changes. Duplicate events
must coalesce by vertex; coalescing counter writers must not drop multiplicity.
Transient mask/degree changes can coalesce to their final value. An event queue
must have a proven capacity and producer ordering before replacing the scan;
the host topology touched set alone is insufficient.

## Candidate Oracle

`comp_hotness_sssp()` regenerates identity IDs. Stable CUB descending sort thus
orders `(score descending, vertex ID ascending)`. All vertices participate,
including zero-score, unreachable and zero-degree vertices. Degree comes from
`sync_vertices_`, not cached virtual degree.

For sorted vertices `p[0..n)`, let `S(k)` be the degree sum through rank k.
With nonzero capacity C, candidates are the ranks before the first k where
`S(k) >= C`. If the total sum is less than C, all vertices are candidates. Empty
graphs and C=0 admit none. This is a strict prefix: an exactly fitting vertex is
excluded, and a later small vertex cannot bypass an oversized earlier one.
Zero-degree vertices before the boundary are admitted. For degrees `[0,2,0,3]`,
capacities 0/2/3/5/6 admit 0/1/3/3/4 vertices respectively.

The current scan uses `index_t` (uint32_t), so this mathematical prefix assumes
the total degree fits uint32_t, as in the current TW/FS cohort. Overflow handling
is unresolved outside that domain; an incremental index must not silently claim
equivalence there. Group totals should use uint64_t, and any wider-domain
production change needs explicit oracle coverage.

Desired membership then enters the existing `cache_patch::RefreshGate`: first
publication, a missing desired resident, or a changed desired count requires a
refresh. Topology invalidation remains relevant even when score and degree are
unchanged. The I15 index must preserve this admission/eviction behavior and must
not treat a rank change by itself as a request to rebuild the cache.

## Executable Model and Remaining Gate

`tests/hotness_event_model_test.cpp` compares a dense byte-window oracle with
event replay maintaining running sums and a four-slot sparse expiry ring. Both
still use a full sort at the output boundary: this deliberately tests event
sufficiency, not an incremental candidate data structure or its cost. It covers
wrap to zero, maximum sum, mask/unmask without traversal, degree-only changes,
initial expiry, no-event samples, zero-score ties, strict capacity boundaries,
empty/singleton graphs, and 2,560 reproducible randomized snapshots. Its observed
increments are synthetic; it does not prove real GPU event capture completeness.

Verification: `ctest --test-dir build -R '^hotness_event_model_test$'
--output-on-failure` passed on 2026-09-07 without GPU use.

The accepted baseline binary is frozen. Before production integration,
validate captured GPU events against full production
scores, IDs, degree prefix, desired membership and refresh decisions at every
sample. Count initial expiry and zero-score desired output in the work report.
Finite-score groups alone do not eliminate the large ascending-ID zero-score
population or full desired-membership search. No runtime replacement is
authorized by the model alone: complete TW/FS batch time and the existing GPU
peak-memory ceiling remain the acceptance criteria. Reuse or replace existing
buffers rather than adding permanent device queues/state on top of the baseline.

## Independent Index Screening

`WeightedScoreIndex` is a standalone host index, not an alternative production
path. It maintains an intrusive treap ordered by ID for each score, including
zero, with subtree degree sums and vertex counts. Ascending-ID Cartesian
construction is O(V); individual final-state changes take expected O(log V)
under hashed priorities; capacity queries take O(1021 + log V). The fixed hash
makes replay deterministic, but does not give worst-case balance against
adversarial score populations. Index storage is 32 bytes/vertex plus 1021 roots;
construction and validation need additional temporary CPU storage. No new GPU
state is allocated.

As an early rejection screen, the archived diagnostic `--sssp_candidate_trace` copies
production sorted IDs, scores and degrees to the host, emits only final-state
score/degree changes, and records independent full-order and desired-prefix
hashes. `CacheCandidateCount()` is checked against the captured strict prefix.
This full snapshot differencing is intentionally diagnostic and does not prove
complete writer-event capture or incremental communication. It cannot distinguish
256 counter writes from no writes, masked history changes, or unchanged-degree
topology invalidations. Those events remain necessary for any production system.

The replay measures index changes and capacity queries separately from complete
oracle traversal. All ten update samples include batch 3's large initial expiry;
initial construction at batch -1 is reported separately. No sample is discarded
for having a large event set. The producer's current score already contains the
complete production window/mask effect. This supplies optimistic index inputs:
the measured maintenance cost excludes writer capture, history maintenance,
communication, output generation and refresh. If even this cost exceeds the
corrected stage budget (TW 180.304 ms / FS 467.7815 ms per ten batches), stop the
CPU tree prototype. Passing this screen would still require all missing costs
and correctness gates. Failure applies to this prototype, not all possible
finite-domain algorithms.

`weighted_score_index_test` checks 6,400 reproducible randomized states against
full stable sorting plus empty groups, zero-degree ties, strict capacity, invalid
records and 64-bit group sums. `hotness_trace_test` and
`hotness_candidate_replay_fixture` cover binary trace round-trip, degree-only and
score changes, unchanged samples and truncated-field rejection. Four applications
build and 27/27 CTest pass. Real TW/FS capture/replay is scripted in
`scripts/run_i15_candidate_replay.py`, with results in
`logs/i15_candidate_index_20260907/`.

Both screens rejected this tree prototype: TW/FS index updates and queries alone
cost 11,200.956/27,544.501 ms versus 180.304/467.7815 ms ten-batch budgets. The production capture
entry point and flag have been removed, preserving the frozen diagnostic binary
and source patch for reproducibility. Both graphs match all eleven states;
see [screening results](i15_candidate_index_results.md). Only the independent
index/trace replay artifacts remain in the source tree.
