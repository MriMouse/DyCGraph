# Dynamic CPU–GPU CC

`hybrid_cc` computes connected components of an undirected multigraph. The result
for each vertex is the **minimum vertex ID in its component**. Isolated vertices
keep their own IDs. Edge weights and `--source_node` do not affect the result.
Output has two columns: `vertex component_label`.

The input may be directed or already symmetric. By default, the loader normalizes
it to an undirected adjacency in memory: each non-self pair is emitted in both
directions and multiplicity is `max(count(u,v), count(v,u))`. Self-loops are emitted
once. Update batch sizes may therefore count one directed record per logical edge;
they are normalized before mutation. Pass `--cc_input_symmetric=true` only when the
base graph and every update phase already contain paired occurrences; this skips
normalization and validation is then enabled. Input weights are ignored, but use
`--weight=true` for the shared update reader and supply the third update column.

```sh
cmake --build build-bfs --target hybrid_cc -j2
CUDA_VISIBLE_DEVICES=2 CG_MUTATION_WORKERS=2 CG_REVERSE_SHARDS=64 \
CG_BATCH_MAINTENANCE=auto CG_ORDERED_REPAIR=0 \
build-bfs/hybrid_cc --graphfile=GRAPH --format=market_big --weight_num=1 \
  --updatefile=UPDATES --update_size=BATCH_SIZES --weight=true \
  --SEGMENT=32 --n_stream=3 --hybrid=0 --cache=2 \
  --cc_max_batches=10 --check=true --cc_print_checksum=true --output=labels.txt
```

For static CC, omit both update paths or set `--cc_max_batches=0`.
`--check=true` runs an independent union-find reference after each deletion,
after each insertion, and at completion. It detects stale labels in disconnected
cycles, which checking only equal labels across edges cannot detect. Disable
checks and traces for timing runs.

## Incremental semantics and retained performance paths

Initialization seeds every vertex with its own ID. Insertion propagates only
strictly smaller labels. Traversal, CPU closure, direct added-edge seeding,
boundary messages, and both deletion repair executors use zero edge cost.

SSSP's parent witness is not a maintained CC spanning forest: equal-label cycles
and asynchronous witness updates make subtree-only deletion invalidation unsafe.
For CC, deletion marks old components touched by non-self deletions, collects
their vertices on the GPU, and resets those vertices to their own IDs. Repair
uses the current symmetric adjacency only on that affected set. A missing
delete between distinct old components cannot affect CC and is skipped.
Other missing deletions and surviving parallel edges may conservatively trigger
repair. This is intentional; a label can increase after deletion.

The default GPU deletion executor now unions the affected vertices directly over
the current chunk adjacency and flattens roots to minimum-ID labels. It avoids
materializing/uploading an entire incoming adjacency and does not copy the
affected queue to the CPU. Sparse deletion descriptors are staged before repair.
Unchanged rows reuse GPU cache; changed rows bypass their stale cache and read
the current chunks. The merged insertion publication still owns cache and epoch
publication. `CG_CC_REPAIR=pull` selects the previous executor for comparison.
Explicit ordered repair, a fixed CPU domain map, and component tracing retain
their previous repair path. This reduces recomputation cost; it does not yet
maintain a dynamic spanning forest or eliminate collection of whole old components.

The union executor now first samples up to two current neighbors per affected
vertex and freezes the resulting component roots in the existing buffer array.
A 256-vertex sample selects one component whose rows can be skipped in the
finishing scan. Edges internal to any sampled component are already certified;
cut edges of the skipped component are processed from their other endpoint,
including the orientation that ordinary `u < v` filtering would discard.
Consequently, sampling changes work, not the exact result. A poor sample only
reduces the speedup. Final flattening still produces minimum-ID labels for every
affected vertex. This needs no additional device allocation and does not use
old labels as evidence of connectivity after deletion.

`CG_CC_SAMPLED_REPAIR=0` disables this optimization for an A/B comparison;
the default is `1`. It applies only to `CG_CC_REPAIR=union`; the pull/CPU/ordered
repair paths retain their existing semantics. The sampled roots remain immutable
through the finishing kernel, and changed rows bypass stale cache in both passes.

For the tested OK 100K-record-per-phase workload, the existing combination
`CG_BATCH_MAINTENANCE=large CG_MERGE_PUBLICATION_SOURCES=1` further reduces CPU
preparation/publication time. It is explicitly configurable; the shared default
maintenance threshold is unchanged. See the [measured configurations and correctness
report](../../iteration/subiteration_file/cc_sampled_repair_20260924.md) before
comparing results from different modes.

The implementation retains the source-local chunk store, grouped regular/large
batch maintenance, topology publication merging, cache patching
and refresh gate, hotness accounting, exact insertion frontier, cooperative
block/thread/ordered insertion, ordered GPU repair, CPU ownership/boundary
runtime, P0 timing, and communication ledger/window. Existing `CG_*` controls
remain available. CPU ownership controls keep the shared names
`--sssp_cpu_partition_capacity` and `--sssp_cpu_domain_map`. For CC, the normalized
forward adjacency is also the incoming view used by deletion repair, so no second
base reverse array or reverse delta overlay is allocated. Weighted I16 replay
snapshots are rejected because their format does not encode CC semantics.

Deletion marking reuses root buffers, adding no permanent GPU array. Collection
scans O(V) labels per nonempty deletion batch, and repair can touch an entire old
giant component. Retaining the performance infrastructure does **not** establish
SSSP-equivalent batch time: workloads with giant components need separate CC
benchmarks. Normalization is one-time input work plus per-batch in-memory canonicalization,
outside P0 batch timing. Already symmetric inputs can skip this with
`--cc_input_symmetric=true`.

For memory-constrained large graphs, use the current `--hybrid=0` path as in the
example. Legacy `--hybrid=2` allocates additional explicit/compaction buffers
proportional to the symmetric edge count and can exhaust a 16 GB device during
initialization. Report this mode change explicitly in comparisons.

## Regression

```sh
python3 tests/cc_dynamic_smoke.py --binary build-bfs/hybrid_cc \
  --gpu 2 --output logs/cc_new_run
cmake --build build-bfs --target cc_sampled_repair_test
CUDA_VISIBLE_DEVICES=2 ctest --test-dir build-bfs -R cc_sampled_repair_test --output-on-failure
```

The opt-in test compares every final label and every phase checksum against an
independent Python flood fill. It covers component splitting/merging, cycles,
bridges, parallel occurrences, self-loops, isolated vertices, missing deletions,
empty phases, random mixed batches, non-unit weights, regular/large/auto modes,
block/thread/ordered schedules, cache on/off, and CPU partition/domain ownership.
