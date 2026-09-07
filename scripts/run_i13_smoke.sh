#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$ROOT/build/hybrid_sssp}"
RUN_DIR="${RUN_DIR:-$ROOT/logs/i13_cleanup_20260906}"
DATA_ROOT="${DATA_ROOT:-/home/wangshaoyan/proJect/CG/Grapin-CG/data}"
GPU_INDEX="${GPU_INDEX:-0}"
LABEL="${LABEL:-current}"
CHECK="${CHECK:-true}"
BATCHES="${BATCHES:-2}"
mkdir -p "$RUN_DIR"
for dataset in twitter friendster; do
    stem=twitter_100k
    if [[ "$dataset" == friendster ]]; then stem=friendster_50p_100k; fi
    log="$RUN_DIR/${LABEL}_${dataset}_${CHECK}.log"
    /usr/bin/time -f '[I13-RESOURCE] max_rss_kb=%M wall_seconds=%e' \
      timeout 1800 env CUDA_VISIBLE_DEVICES="$GPU_INDEX" CG_MUTATION_WORKERS=20 \
      "$BIN" --graphfile="$DATA_ROOT/input_$stem.txt" --format=market_big \
      --weight_num=1 --weight=1 --updatefile="$DATA_ROOT/update_$stem.txt" \
      --update_size="$DATA_ROOT/stream_size_$stem.txt" --source_node=0 \
      --SEGMENT=512 --n_stream=3 --hybrid=0 --cache=2 \
      --sssp_cpu_partition_capacity=0 --check="$CHECK" --verbose=false \
      --sssp_max_batches="$BATCHES" --sssp_print_checksum=true >"$log" 2>&1
    [[ "$(rg -c '\[P0-TIMER\]' "$log")" == "$BATCHES" ]]
    if [[ "$LABEL" != i12 ]]; then
        [[ "$(rg -c '\[C3-PUBLISH\]' "$log")" == "$BATCHES" ]]
        [[ "$(rg -c '\[E4-R1-CLOSURE\]' "$log")" == "$BATCHES" ]]
        if rg -q 'I12-TRANSACTION|I12-INVALIDATION|I12-BOUNDARY' "$log"; then exit 1; fi
    fi
    if [[ "$CHECK" == true ]]; then
        [[ "$(rg -c '\[SSSP-DELETE-STAGE-CHECK\].* passed' "$log")" == "$BATCHES" ]]
        [[ "$(rg -c '\[SSSP-BATCH-CHECK\].* passed' "$log")" == "$BATCHES" ]]
        rg -q '\[SSSP-BELLMAN-CHECK\] passed' "$log"
        rg -q 'Overall: Test passed' "$log"
        if rg -q '(gpu_cpu_hash_mismatches|stale_version_rejects)=[1-9]' "$log"; then exit 1; fi
    fi
    printf '%s %s complete: %s\n' "$LABEL" "$dataset" "$log"
done
