# Dynamic CPU–GPU directed CC labels

`hybrid_cc` uses the original C-GpuStreamGraph directed label propagation
semantics: each vertex starts with its own ID, and an edge `u -> v` carries
`label[u]` to `v`. The final label of `v` is the smallest ID that can reach `v`,
including `v` itself. This is not weakly or strongly connected components on
arbitrary directed input. On symmetric input, static labels equal undirected CC.
Edge weights and `--source_node` do not affect the labels.

Graphs and update records are consumed as supplied, just like the other apps.
There is no automatic reverse-edge insertion, pair normalization or symmetric
validation. `--cc_input_symmetric` has been removed. Each batch count describes
exactly the records in the original update stream. Output remains two columns:
`vertex label`. The result log reports `label_roots`, not a component count.

```sh
cmake --build build-bfs --target hybrid_cc -j2
CUDA_VISIBLE_DEVICES=0 CG_MUTATION_WORKERS=20 CG_REVERSE_SHARDS=64 \
CG_BATCH_MAINTENANCE=regular CG_ORDERED_REPAIR=0 \
build-bfs/hybrid_cc --graphfile=GRAPH --format=market_big --weight_num=1 \
  --updatefile=UPDATES --update_size=BATCH_SIZES --weight=true \
  --SEGMENT=32 --n_stream=3 --hybrid=0 --cache=2 \
  --cc_max_batches=10 --check=true --cc_print_checksum=true --output=labels.txt
```

Omit both update paths or set `--cc_max_batches=0` for a static run.
The shared update reader requires `--weight=true`; numeric weights are ignored.

Insertion retains grouped mutation, chunk storage, merged publication, cache
maintenance and the CPU/GPU execution paths. It propagates strict label decreases
only along the stored edge direction. Deletion repairs use the same dynamic
reverse index and incoming-edge executor as SSSP/BFS, with zero edge cost and
one seed per vertex. The reverse index consumes host memory but does not insert
reverse records into the forward graph or double the input/update workload.

Deletion first commits the grouped mutation and checks candidate endpoints for
**rooted surviving paths** using the existing dynamic reverse index. A path from
`old_label[v]` to `v` in the post-delete graph proves that `v` keeps its label;
such a deletion does not seed invalidation. All edges in the batch are removed
before this check, with duplicate-edge multiplicities handled by the reverse
index. Proofs are cached only within that deletion phase. Equal-label cycles
without a surviving root path cannot certify themselves.

Unproven endpoints start a local forward frontier over current source-local
chunks. The same rooted proof is applied at its boundary, so a lost branch does
not flood a still-supported giant label region. The resulting affected list is
uploaded to the existing SSSP/BFS reset and incoming repair executor, including
CPU/GPU ownership handling. Reverse witness queries stop scanning a row as soon
as they find a certified predecessor.

The proof search is bounded (at least one million incoming edge visits / 100,000
search vertices per batch, scaled by candidate count); forward screening also
has an edge budget and a 100,000-affected-vertex cutoff. If screening cannot
finish within its budget, its partial list is discarded and the original GPU
invalidation frontier completes the work from the uncertified deletion seeds. The CC dependency operator follows equal-label outgoing edges rather than
relying only on a parent witness: zero-cost cycles can keep a stale tight parent
after their incoming bridge is deleted. Self-seeded labels stop invalidation.
Affected vertices reset to their own IDs instead of infinity;
all propagation uses zero edge cost. No whole-label-group scan, symmetric
adjacency alias, union or sampled CC repair runs. `CG_CC_REPAIR` and
`CG_CC_SAMPLED_REPAIR` no longer select this app's executor. Generic scheduling,
CPU ownership, cache and mutation controls remain available.

`[CC-ROOTED-WITNESS]` reports candidate/proven/fallback counts, searched vertices
and edges, label-state D2H bytes, and proof time (inside the batch timer).
`fallback` counts uncertified initial seeds, not necessarily a fallback of the
whole executor. `[CC-WITNESS-FRONTIER] closed=1` indicates a completed screened
frontier; `closed=0` selects ordinary GPU invalidation.
Candidates are screened on GPU; batches with no candidates avoid the full label
copy. Batches with candidates currently copy the label array once to the host.
`CG_CC_ROOTED_WITNESS=0` disables only this optimization for a controlled
comparison. This does not change directed CC answers. Difficult cuts or search
budget exhaustion can still invoke the conservative large-region repair; this
optimization does not promise small work for every possible deletion batch.

The shared SSSP/BFS/CC repair topology has a bounded device budget. By default
it is the smaller of 4 GiB and half the available device memory after reserving
512 MiB (including reusable repair allocations). Row offsets have priority;
incoming sources that do not fit are accessed through mapped host memory.
Small repairs retain their reusable device allocations and the existing warp
pull kernel. Large repairs register the already materialized host vectors,
without making another host or device edge copy. Registrations are released
before the next batch can resize the vectors. The forward hot cache and all
insertion/mutation/CPU ownership paths remain shared with SSSP/BFS.

`CG_REPAIR_TOPOLOGY_MB` sets the upper bound in MiB; `0` forces mapped topology
for validation. The free-memory bound still applies to nonzero overrides.
Ordered repair shares the same budget for its temporary outgoing adjacency;
its per-vertex queues/state still use device memory. This bounds additional
repair **topology**, not total device memory or host reverse-index memory.
`[B2-REPAIR-STORAGE]` reports budget, actual retained device bytes, mapped bytes,
and explicit H2D bytes. Mapped accesses still generate PCIe traffic during
kernels; they are not counted as explicit H2D copies.

`--check=true` compares every deletion phase, insertion phase and final result
against an independent directed flood-fill oracle. Checks and output remain
outside the P0 batch timer. Paper timing runs should use `--check=false` after
separate validation. Old symmetric-input timings must not be mixed with these
runs; both baseline and current must read the same original input and updates.

```sh
python3 tests/cc_dynamic_smoke.py --binary build-bfs/hybrid_cc \
  --gpu 0 --output logs/cc_directed_smoke
```

The regression checks all labels and per-phase checksums for directed chains,
incoming-only edges, cycles losing their incoming bridge, parallel records,
self-loops, missing deletions, isolated vertices, empty phases, random batches,
non-unit weights, cache on/off, and the production insertion/repair schedules.

Force the OOM-safe path, including ordered and mixed CPU/GPU repair:

```sh
python3 tests/cc_dynamic_smoke.py --binary build-bfs/hybrid_cc \
  --gpu 1 --repair-topology-mb 0 --output logs/cc_mapped_smoke
python3 tests/bfs_dynamic_smoke.py --algorithm sssp --binary build-bfs/hybrid_sssp \
  --gpu 1 --repair-topology-mb 0 --output logs/sssp_mapped_smoke
CUDA_VISIBLE_DEVICES=1 build-bfs/repair_topology_storage_test
```
