#!/usr/bin/env bash
set -u

ROOT_CURRENT="/home/wangshaoyan/proJect/C-GpuStreamGraph-CG"
ROOT_BASELINE="/home/wangshaoyan/proJect/CG/C-GpuStreamGraph"
DATA_DIR="/home/wangshaoyan/proJect/CG/Grapin-CG/data"

RUN_TAG="${RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${RUN_DIR:-$ROOT_CURRENT/logs/friendster_stage_cache12_${RUN_TAG}}"
GPU="${CUDA_VISIBLE_DEVICES:-0}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-7200}"
BATCHES="${BATCHES:-10}"
CACHES="${CACHES:-1 2}"
CONFIGS="${CONFIGS:-baseline_hybrid1 current_coopoff current_coophybrid}"

mkdir -p "$RUN_DIR"

SUMMARY="$RUN_DIR/summary.tsv"
STATUS_LOG="$RUN_DIR/runner.log"

printf 'system\tdataset\tcache\treturncode\tstatus\tpaper_algorithm_ms_sum\tpaper_algorithm_batches\tfinal_count\tchecksum\tlog\n' > "$SUMMARY"

log_status() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$STATUS_LOG"
}

dataset_suffix() {
  case "$1" in
    1k) printf '1k' ;;
    10k) printf '10k' ;;
    100k) printf '100k' ;;
    *) printf '%s\n' "$1"; return 1 ;;
  esac
}

binary_for_config() {
  case "$1" in
    current_*) printf '%s/build/hybrid_sssp\n' "$ROOT_CURRENT" ;;
    baseline_*) printf '%s/build/hybrid_sssp\n' "$ROOT_BASELINE" ;;
    *) return 1 ;;
  esac
}

cwd_for_config() {
  case "$1" in
    current_*) printf '%s\n' "$ROOT_CURRENT" ;;
    baseline_*) printf '%s\n' "$ROOT_BASELINE" ;;
    *) return 1 ;;
  esac
}

append_config_flags() {
  local config="$1"
  case "$config" in
    baseline_hybrid1)
      printf '%s\n' "--hybrid=1"
      ;;
    current_coopoff)
      printf '%s\n' "--hybrid=0"
      printf '%s\n' "--coop_mode=off"
      ;;
    current_coophybrid)
      printf '%s\n' "--hybrid=0"
      printf '%s\n' "--coop_mode=hybrid"
      ;;
    *)
      return 1
      ;;
  esac
}

classify_status() {
  local rc="$1"
  local log="$2"
  if [[ "$rc" == "0" ]]; then
    printf 'ok'
    return
  fi
  if grep -qiE 'out of memory|cudaErrorMemoryAllocation|oom|std::bad_alloc' "$log"; then
    printf 'oom'
    return
  fi
  if [[ "$rc" == "124" ]]; then
    printf 'timeout'
    return
  fi
  printf 'failed'
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

run_one() {
  local config="$1"
  local dataset="$2"
  local cache="$3"
  local suffix
  suffix="$(dataset_suffix "$dataset")"
  local bin
  bin="$(binary_for_config "$config")"
  local cwd
  cwd="$(cwd_for_config "$config")"
  local log="$RUN_DIR/${config}_friendster_${suffix}_cache${cache}.log"
  local cmdfile="$RUN_DIR/${config}_friendster_${suffix}_cache${cache}.cmd"

  local graph="$DATA_DIR/input_friendster_50p_${suffix}.txt"
  local update="$DATA_DIR/update_friendster_50p_${suffix}.txt"
  local stream="$DATA_DIR/stream_size_friendster_50p_${suffix}.txt"

  if [[ ! -x "$bin" ]]; then
    log_status "missing binary: $bin"
    printf '%s\tfriendster_%s\t%s\t127\tmissing_binary\t0.000\t0\t\t\t%s\n' "$config" "$suffix" "$cache" "$log" >> "$SUMMARY"
    return 127
  fi

  local cmd=(
    "$bin"
    "--graphfile=$graph"
    "--format=market_big"
    "--weight_num=1"
    "--weight=1"
    "--updatefile=$update"
    "--update_size=$stream"
    "--source_node=0"
    "--SEGMENT=512"
    "--n_stream=3"
    "--cache=$cache"
    "--check=false"
    "--verbose=false"
    "--sssp_max_batches=$BATCHES"
  )
  local config_flag
  while IFS= read -r config_flag; do
    cmd+=("$config_flag")
  done < <(append_config_flags "$config")

  printf 'cd %q\n' "$cwd" > "$cmdfile"
  printf 'CUDA_VISIBLE_DEVICES=%q timeout %q' "$GPU" "$TIMEOUT_SECONDS" >> "$cmdfile"
  printf ' %q' "${cmd[@]}" >> "$cmdfile"
  printf '\n' >> "$cmdfile"

  log_status "start config=$config dataset=friendster_$suffix cache=$cache gpu=$GPU"
  (
    cd "$cwd"
    CUDA_VISIBLE_DEVICES="$GPU" timeout "$TIMEOUT_SECONDS" "${cmd[@]}"
  ) > "$log" 2>&1
  local rc=$?
  local status
  status="$(classify_status "$rc" "$log")"
  local metrics
  metrics="$(extract_metrics "$log")"
  printf '%s\tfriendster_%s\t%s\t%s\t%s\t%s\t%s\n' "$config" "$suffix" "$cache" "$rc" "$status" "$metrics" "$log" >> "$SUMMARY"
  log_status "done config=$config dataset=friendster_$suffix cache=$cache rc=$rc status=$status"
  return "$rc"
}

main() {
  log_status "run_dir=$RUN_DIR"
  log_status "gpu=$GPU timeout=${TIMEOUT_SECONDS}s batches=$BATCHES caches=$CACHES configs=$CONFIGS"
  nvidia-smi > "$RUN_DIR/nvidia-smi.start.txt" 2>&1 || true

  local datasets=(1k 10k 100k)

  for config in $CONFIGS; do
    for cache in $CACHES; do
      log_status "config=$config cache=$cache guarded sweep"
      local first_cache_rc=0
      run_one "$config" 1k "$cache" || first_cache_rc=$?
      if [[ "$first_cache_rc" != "0" ]]; then
        log_status "config=$config cache=$cache first run failed rc=$first_cache_rc; skip 10k/100k cache=$cache"
        printf '%s\tfriendster_10k\t%s\t%s\tskipped_after_1k_cache_failure\t0.000\t0\t\t\t\n' "$config" "$cache" "$first_cache_rc" >> "$SUMMARY"
        printf '%s\tfriendster_100k\t%s\t%s\tskipped_after_1k_cache_failure\t0.000\t0\t\t\t\n' "$config" "$cache" "$first_cache_rc" >> "$SUMMARY"
        continue
      fi
      run_one "$config" 10k "$cache" || true
      run_one "$config" 100k "$cache" || true
    done
  done

  nvidia-smi > "$RUN_DIR/nvidia-smi.end.txt" 2>&1 || true
  log_status "all done summary=$SUMMARY"
}

main "$@"
