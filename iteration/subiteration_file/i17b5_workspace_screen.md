# I17-B5.1 workspace screening

2026-09-09: reject the record workspace reuse candidate. B5 remains open;
destination merge profiling and parallel preparation have not been evaluated.

## Protocol

FS 1000k, first two consecutive mixed batches, source=0, hybrid=2, cache=2,
CG_MUTATION_WORKERS=20, CUDA_VISIBLE_DEVICES=0, check=false. Each batch contains
500000 effective deletions and 500000 additions. No graph loading in paper time.
Four runs use baseline-candidate-candidate-baseline order. Each process takes
about seven minutes including graph loading. Three topology contract CTests pass.

Baseline: frozen stage binary SHA256
`f131eac169fdf268b92b341d3b868d743b69806cc23319ffd0a87ca1fdbdc80f`.
Candidate: `logs/i17b5_20260909/build_release/hybrid_sssp`, SHA256
`acc444f662daad0eb9d04175f45ce3f20b0b836d14d316bcdd252b4ec9114c61`.
Both use Release, GCC-12 and CUDA 12.1, with identical batch completion fences.
Compared SSSP/framework source files match except the reverse records workspace.
Inputs and original command are identified by the stage manifest and
`performance.friendster.1000k.current.c2.h2.w20.r0` in stage runs.json.

## Results

All time values below sum both batches (reverse sums both phases).

| Run | Paper ms | Reverse prepare ms | Peak RSS KiB |
|---|---:|---:|---:|
| baseline 0 | 3665.925 | 1159.995 | 57960648 |
| candidate 1 | 3737.998 | 1202.657 | 57960716 |
| candidate 2 | 3942.651 | 1228.523 | 57960772 |
| baseline 3 | 3706.755 | 1195.897 | 57959500 |

Paper mean increases 4.18%; reverse mean increases 3.20%. Baseline pair spread
is 1.11% of its mean, candidate spread 5.33%. Adjacent comparisons regress
1.97% and 6.36%; this does not establish a precise slowdown, but fails the
stable-improvement gate. Records still need copying, sorting and per-destination
merging; allocation reuse alone provides no observed benefit.

All four final distance checksums equal 4613270879134330002. Parent checksums
differ, which is allowed for tie witnesses, but these check=false runs do not
validate those witnesses. No expanded correctness or ten-batch campaign is
warranted for this rejected candidate. Peak RSS is dominated by graph setup;
it cannot resolve an 8 MB (500000 * 16 bytes) retained records buffer. No new
pinned/device buffers are introduced. Longer-term workspace growth was not tested.

## Evidence and Disposition

Raw `.log` and `.time` files: `logs/i17b5_20260909/screen/0_baseline` through
`3_baseline`. These four raw logs are authoritative: the interrupted early
runner left results.json without candidate 2. The candidate process itself
completed with exit status 0 in its time file. Candidate binary is preserved;
production workspace reuse was reverted. Timing fences remain.

An initial wrong source/mode run and a non-Release candidate attempt are excluded.
The earlier claim that a batch exceeded 30 seconds was incorrect: it was graph
loading. Neither excluded attempt measures batch performance.

`scripts/run_i17b5_screen.py --output <new-empty-directory> --candidate <binary>`
repeats the four-run protocol using the frozen baseline. Full B5 closure requires
the planned reverse substage profile and a decision on grouped parallel merge;
this experiment closes only the existing B5.1 workspace candidate.
