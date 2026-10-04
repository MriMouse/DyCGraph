# CC structural fix — 2026-10-01

Times are the P0 sum of ten incremental batches (ms), excluding graph loading and initialization. Semantics: directed_min_label. New runs: one repeat per case; do not infer statistical significance.

| Dataset | Scale | Before current | Original reference | Fixed | Original / fixed | Mean affected |
|---|---|---:|---:|---:|---:|---:|
| TW | 1k | 179,182.702 | 12,278.171 | 3,235.654 | 3.795x | 1.3 |
| TW | 10k | 279,560.743 | 12,569.368 | 4,264.223 | 2.948x | 13.0 |
| TW | 100k | 739,973.759 | 14,535.432 | 8,662.055 | 1.678x | 140.0 |
| FS | 100k | 11,330.930 | 14,216.200 | 11,080.608 | 1.283x | 480.1 |

TW: GPU 0 / NUMA 0, check=false; original reference is the two-repeat historical mean on the same GPU. FS: both fixed and original rerun on GPU 1 / NUMA 0, check=false, one repeat each. Before-current values are historical two-repeat means. Original remains a timing reference, not a correctness oracle.

Correctness: TW/100k and FS/100k each pass 20 independent full-graph phase checks and the final full-graph check (GPU 2/3, NUMA 1, check=true). Their diagnostic timings are excluded from this table. CC small-graph suite: 18 configurations / 406 phase checks. Witness: 64,057 randomized queries. BFS, SSSP and PR regressions also pass.

Detailed evidence: logs/cc_tw_structural_20261001/verification_summary.json; root-cause analysis: iteration/subiteration_file/cc_tw_structural_fix_20261001.md.
