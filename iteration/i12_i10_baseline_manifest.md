# I12 Entry Baseline Manifest

Date: 2026-09-05 UTC

This manifest freezes the exact pre-I12 workspace state. The repository was
already dirty; no existing changes were reverted or committed while recording
the baseline.

## Source And Build Identity

- Git HEAD: `6ef292c88be07f9507c363c1bb0b8f1a7f0c0e65`
- Tracked working-tree diff SHA-256:
  `c5c5a24153602ccc1c3f59cdf8f5c570a67329337b2d3b571879ee0c02123542`
- Build directory: `build/`
- CMake generator: `Unix Makefiles`
- `build/hybrid_sssp` SHA-256:
  `0bb0e6b160d1758261896c2ff89e67ed43941e3692c7f1877e012dbd585f573e`
- Rebuild command: `cmake --build build --target hybrid_sssp -j`

The diff hash covers tracked changes only. The accompanying `git status`
record below identifies the untracked I6--I11 artifacts that are also part of
the pre-I12 evidence state.

## Entry Verification

Command:

```bash
ctest --test-dir build --output-on-failure
```

Result: `22/22` tests passed in `1.26 s`, including
`cache_tail_fallback_test`, `source_local_chunk_store_test`,
`dynamic_reverse_index_test`, and `final_state_repair_model_test`.

The cache-tail crash reported by `iteration/fable5结论.md` is therefore not
reproducible in this frozen workspace and is not an active I12 blocker.

## Pre-I12 Working Tree

Tracked modifications:

```text
CMakeLists.txt
include/framework/framework.cuh
include/groute/graphs/source_local_chunk_store.h
iteration/cggraph_cpu_gpu_dev_implementation_plan.md
tests/source_local_chunk_store_test.cpp
```

Important untracked implementation/evidence files:

```text
include/utils/fixed_worker_pool.h
iteration/cggraph_cpu_gpu_progress_report.md
iteration/fable5结论.md
iteration/i11_final_state_repair_semantics.md
iteration/paper_plan_and_research_directions.md
scripts/analyze_i11_final_state_upper_bound.py
scripts/analyze_i8_mutation_ablation.py
scripts/analyze_i9_critical_path.py
scripts/audit_i4_hotness_semantics.py
scripts/diagnose_i0_failures.py
scripts/generate_uk2007_datasets.py
scripts/run_i10_topology_contract.sh
scripts/run_i6_overlap_observation.sh
scripts/run_i7_mutation_ablation.sh
scripts/run_i8_mutation_repeats.sh
scripts/run_i9_critical_path_audit.sh
tests/final_state_repair_model_test.cpp
```

## Frozen Performance Evidence

- I10 correctness/resource baseline:
  `logs/i10_topology_contract_20260827T094010Z/`
- I9 critical-path baseline:
  `logs/i9_critical_path_20260827T082919Z/`
- I8 repeated mutation baseline:
  `logs/i8_mutation_repeats_20260827T031043Z/`

I12 development screening must use the same Twitter/Friendster graph, update,
source, `cache=2`, 100k mixed-update, and batch-count settings recorded by
these artifacts. I11's `46.1%/33.7%` covered regions are admission upper bounds,
not expected speedups.
