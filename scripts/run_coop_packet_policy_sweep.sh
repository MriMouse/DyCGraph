#!/usr/bin/env bash
set -u

ROOT_CURRENT="${ROOT_CURRENT:-/home/wangshaoyan/proJect/C-GpuStreamGraph-CG}"
DATA_DIR="${DATA_DIR:-/home/wangshaoyan/proJect/CG/Grapin-CG/data}"
RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${RUN_DIR:-$ROOT_CURRENT/logs/coop_packet_policy_sweep_${RUN_TAG}}"
GPU="${CUDA_VISIBLE_DEVICES:-0}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-7200}"
BATCHES="${BATCHES:-1}"
VERBOSE="${VERBOSE:-true}"
PREFILTER="${PREFILTER:-false}"
CACHES="${CACHES:-2}"
GRAPHS="${GRAPHS:-friendster}"
DATASETS="${DATASETS:-1k 10k 100k}"
POLICIES="${POLICIES:-active_frontier degree_desc noncached_degree cache_aware hybrid_score}"

mkdir -p "$RUN_DIR"

SUMMARY="$RUN_DIR/summary.tsv"
STATUS_LOG="$RUN_DIR/runner.log"
printf 'graph\tdataset\tcache\tpolicy\treturncode\tstatus\tpaper_algorithm_ms_sum\tpaper_algorithm_batches\tfinal_count\tchecksum\tlog\tmechanism_tsv\n' > "$SUMMARY"

log_status() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$STATUS_LOG"
}

classify_status() {
  local rc="$1"
  local log="$2"
  if [[ "$rc" == "0" ]]; then
    printf 'ok'
  elif grep -qiE 'out of memory|cudaErrorMemoryAllocation|oom|std::bad_alloc' "$log"; then
    printf 'oom'
  elif [[ "$rc" == "124" ]]; then
    printf 'timeout'
  else
    printf 'failed'
  fi
}

extract_metrics() {
  local log="$1"
  python3 - "$log" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="ignore")
timers = [float(x) for x in re.findall(r"\[P0-TIMER\]\[SSSP\]\[batch\s+\d+\]\s+total_batch:\s+([0-9.]+)", text)]
final_count = ""
checksum = ""
m = re.findall(r"final_result_count:\s*(\d+)", text)
if m:
    final_count = m[-1]
m = re.findall(r"final_reachable=(\d+)", text)
if m and not final_count:
    final_count = m[-1]
m = re.findall(r"checksum:\s*(\d+)", text)
if m:
    checksum = m[-1]
print(f"{sum(timers):.3f}\t{len(timers)}\t{final_count}\t{checksum}")
PY
}

dataset_files() {
  local graph="$1"
  local dataset="$2"
  case "$graph" in
    friendster)
      printf '%s\n' \
        "$DATA_DIR/input_friendster_50p_${dataset}.txt" \
        "$DATA_DIR/update_friendster_50p_${dataset}.txt" \
        "$DATA_DIR/stream_size_friendster_50p_${dataset}.txt" \
        "friendster_${dataset}"
      ;;
    twitter)
      printf '%s\n' \
        "$DATA_DIR/input_twitter_${dataset}.txt" \
        "$DATA_DIR/update_twitter_${dataset}.txt" \
        "$DATA_DIR/stream_size_twitter_${dataset}.txt" \
        "twitter_${dataset}"
      ;;
    *)
      return 1
      ;;
  esac
}

run_one() {
  local graph_name="$1"
  local dataset="$2"
  local cache="$3"
  local policy="$4"
  local bin="$ROOT_CURRENT/build/hybrid_sssp"
  local graph_file update stream dataset_label
  mapfile -t files < <(dataset_files "$graph_name" "$dataset")
  graph_file="${files[0]}"
  update="${files[1]}"
  stream="${files[2]}"
  dataset_label="${files[3]}"
  local log="$RUN_DIR/${dataset_label}_cache${cache}_${policy}.log"
  local tsv="$RUN_DIR/${dataset_label}_cache${cache}_${policy}.mechanism.tsv"
  local cmdfile="$RUN_DIR/${dataset_label}_cache${cache}_${policy}.cmd"

  if [[ ! -x "$bin" ]]; then
    log_status "missing binary: $bin"
    printf '%s\t%s\t%s\t%s\t127\tmissing_binary\t0.000\t0\t\t\t%s\t%s\n' "$graph_name" "$dataset_label" "$cache" "$policy" "$log" "$tsv" >> "$SUMMARY"
    return 127
  fi
  if [[ ! -f "$graph_file" || ! -f "$update" || ! -f "$stream" ]]; then
    log_status "missing input for graph=$graph_name dataset=$dataset"
    printf '%s\t%s\t%s\t%s\t66\tmissing_input\t0.000\t0\t\t\t%s\t%s\n' "$graph_name" "$dataset_label" "$cache" "$policy" "$log" "$tsv" >> "$SUMMARY"
    return 66
  fi

  local cmd=(
    "$bin"
    "--graphfile=$graph_file"
    "--format=market_big"
    "--weight_num=1"
    "--weight=1"
    "--updatefile=$update"
    "--update_size=$stream"
    "--source_node=0"
    "--SEGMENT=512"
    "--n_stream=3"
    "--hybrid=0"
    "--cache=$cache"
    "--check=false"
    "--verbose=$VERBOSE"
    "--sssp_max_batches=$BATCHES"
    "--coop_mode=hybrid"
    "--coop_split_mode=cpu_home"
    "--coop_packet_skip_audit=true"
    "--coop_packet_source_policy=$policy"
    "--coop_merge_light_prefilter=$PREFILTER"
  )

  printf 'cd %q\n' "$ROOT_CURRENT" > "$cmdfile"
  printf 'CUDA_VISIBLE_DEVICES=%q timeout %q' "$GPU" "$TIMEOUT_SECONDS" >> "$cmdfile"
  printf ' %q' "${cmd[@]}" >> "$cmdfile"
  printf '\n' >> "$cmdfile"

  log_status "start dataset=friendster_$dataset cache=$cache policy=$policy"
  (
    cd "$ROOT_CURRENT"
    CUDA_VISIBLE_DEVICES="$GPU" timeout "$TIMEOUT_SECONDS" "${cmd[@]}"
  ) > "$log" 2>&1
  local rc=$?
  local status
  status="$(classify_status "$rc" "$log")"
  if [[ "$VERBOSE" == "true" ]]; then
    "$ROOT_CURRENT/scripts/extract_coop_mechanism_tsv.py" "$log" \
      --dataset="$dataset_label" \
      --cache="cache$cache" \
      --mode="hybrid" > "$tsv" || true
  fi
  local metrics
  metrics="$(extract_metrics "$log")"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$graph_name" "$dataset_label" "$cache" "$policy" "$rc" "$status" "$metrics" "$log" "$tsv" >> "$SUMMARY"
  log_status "done graph=$graph_name dataset=$dataset_label cache=$cache policy=$policy rc=$rc status=$status"
  return "$rc"
}

main() {
  log_status "run_dir=$RUN_DIR"
  log_status "gpu=$GPU timeout=${TIMEOUT_SECONDS}s batches=$BATCHES verbose=$VERBOSE prefilter=$PREFILTER graphs=$GRAPHS datasets=$DATASETS caches=$CACHES policies=$POLICIES"
  nvidia-smi > "$RUN_DIR/nvidia-smi.start.txt" 2>&1 || true
  for graph_name in $GRAPHS; do
    for cache in $CACHES; do
      for dataset in $DATASETS; do
        for policy in $POLICIES; do
          run_one "$graph_name" "$dataset" "$cache" "$policy" || true
        done
      done
    done
  done
  nvidia-smi > "$RUN_DIR/nvidia-smi.end.txt" 2>&1 || true
  log_status "all done summary=$SUMMARY"
}

main "$@"
