# Dynamic CPU–GPU BFS

`hybrid_bfs` computes directed, unweighted hop distances. Every edge has cost 1,
including updates, regardless of input weights. Unreachable vertices are
`UINT32_MAX`; output columns are vertex, hop distance, parent, internal relaxation buffer.
The fourth column is diagnostic state, not an edge weight or a distance change.
Reachable non-source parents are checked as graph edges satisfying
`distance[parent] + 1 == distance[vertex]`; ties can select different valid parents.

The implementation shares the current SSSP chunk store, reverse index, GPU
deletion repair, insertion closure, hotness/cache maintenance and timers.
`TraversalEdgeWeight` and `DeletionEdgeWeight` specialize to constants at compile
time; the SSSP default weight and scheduling remain unchanged.

Build with the same CUDA 12.x toolchain as SSSP (the V100 target is sm_70):

```sh
cmake --build build-bfs --target hybrid_bfs -j2
```

Example (select an idle GPU/NUMA node before running):

```sh
CUDA_VISIBLE_DEVICES=2 CG_MUTATION_WORKERS=2 CG_REVERSE_SHARDS=64 \
CG_BATCH_MAINTENANCE=auto CG_ORDERED_REPAIR=0 \
numactl --physcpubind=24,25 --membind=1 build-bfs/hybrid_bfs \
  --graphfile=GRAPH --updatefile=UPDATES --update_size=BATCH_SIZES \
  --format=market_big --weight_num=1 --weight=1 --source_node=0 \
  --SEGMENT=512 --n_stream=3 --hybrid=0 --cache=2 \
  --bfs_max_batches=10 --check=false --bfs_print_checksum=true
```

Application flags use `bfs_`: `bfs_max_batches`, `bfs_print_checksum`,
`bfs_hotness_audit`. The shared experimental ownership controls retain their
existing names: `sssp_cpu_partition_capacity` and `sssp_cpu_domain_map` (default
off). Weighted I16 repair snapshots are rejected rather than mislabeled.

`CG_INSERTION_SCHEDULE=block` remains the default. `thread` and `ordered` are
available for explicit comparison; `CG_ORDERED_REPAIR=1` also selects ordered
insertion. Weighted SSSP's large-diameter performance conclusions do not establish
which BFS schedule is fastest. Publication merge and other topology options are
inherited without changing production defaults.

Opt-in GPU regression (never part of automatic CTest):

```sh
numactl --physcpubind=24,25 --membind=1 python3 tests/bfs_dynamic_smoke.py \
  --binary build-bfs/hybrid_bfs --gpu 2 --output logs/bfs_smoke_new
```

This compares three schedules against a separate FIFO BFS after each deletion
and insertion phase, and checks every final distance and reachable parent edge.
It refuses to run on a GPU reporting occupied memory or active utilization.
Run correctness separately from performance; `--check=true` deliberately adds
full-graph validation work. No large-graph BFS performance claim is implied by
this small regression.

The large-batch mode is `CG_BATCH_MAINTENANCE=large` (or `auto`, which
selects large for at least 1,000,000 total updates). Do not use the historical
`--large_batch` flag to select it: that flag belongs to the unconnected PMA
experiment. Road mode is `CG_ORDERED_REPAIR=1`; it combines ordered deletion
repair and ordered insertion and can be used with either maintenance mode.

For a small, synthetic performance screen, run `scripts/run_bfs_mode_screen.py`
with `--binary build-bfs/hybrid_bfs --cache=2 --output=NEW_LOG_DIRECTORY` under
`numactl --physcpubind=24,25 --membind=1 nice -n 15 ionice -c 3`.
This opt-in runner uses GPU 2 only, six serial runs, two batches each, two workers,
SEGMENT=32 and `check=false`. It generates inputs in `/dev/shm`, checks resource
availability, and stops its own child on resource contention or timeout.
Results are complete P0 batch-time sums, not initial traversal or process wall
time. Synthetic screens do not establish performance on real road/social graphs.

A discriminating semantics test is available as `tests/bfs_semantics_test.py`
with the same `--binary`, `--gpu`, and fresh `--output` arguments as the smoke
test. It checks initial-only output and deletion/insertion/disconnection/repair
on a graph where BFS gives 2 hops while weighted shortest paths give 3 or 8.
It deliberately parses non-unit graph weights (`weight_num=0`) and non-unit
update weights; both are ignored by the BFS operators. The shared `--weight=true`
flag describes the update file format, not weighted shortest-path semantics.
