#!/usr/bin/env bash
set -uo pipefail

ROOT_CURRENT="${ROOT_CURRENT:-/home/wangshaoyan/proJect/C-GpuStreamGraph-CG}"
ROOT_BASELINE="${ROOT_BASELINE:-/home/wangshaoyan/proJect/CG/C-GpuStreamGraph}"
DATA_ROOT="${DATA_ROOT:-/home/wangshaoyan/proJect/CG/Grapin-CG/data}"
GPU_INDEX="${GPU_INDEX:-2}"
MAX_BATCHES="${MAX_BATCHES:-10}"
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-7200}"
RUN_DIR="${RUN_DIR:-${ROOT_CURRENT}/logs/current_vs_cgpustreamgraph_$(date +%Y%m%d_%H%M%S)}"

CURRENT_BIN="${ROOT_CURRENT}/build/hybrid_sssp"
BASELINE_BIN="${ROOT_BASELINE}/build/hybrid_sssp"
SUMMARY="${RUN_DIR}/summary.tsv"
COMPARISON="${RUN_DIR}/comparison.tsv"
RUNNER_LOG="${RUN_DIR}/runner.log"

mkdir -p "${RUN_DIR}"
printf '%s\n' "$$" >"${RUN_DIR}/runner.pid"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${RUNNER_LOG}"
}

fail() {
    log "fatal: $*"
    exit 1
}

for required in "${CURRENT_BIN}" "${BASELINE_BIN}"; do
    [[ -x "${required}" ]] || fail "missing executable: ${required}"
done
command -v nvidia-smi >/dev/null 2>&1 || fail "nvidia-smi is unavailable"
command -v python3 >/dev/null 2>&1 || fail "python3 is unavailable"

GPU_UUID="$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader,nounits |
    awk -F',' -v gpu_index="${GPU_INDEX}" '{gsub(/ /, "", $1); gsub(/ /, "", $2); if ($1 == gpu_index) print $2}')"
[[ -n "${GPU_UUID}" ]] || fail "GPU index ${GPU_INDEX} does not exist"

gpu_snapshot() {
    nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader,nounits |
        awk -F',' -v gpu_index="${GPU_INDEX}" '
            {
                gsub(/ /, "", $1);
                gsub(/ /, "", $2);
                gsub(/ /, "", $3);
                if ($1 == gpu_index) print $2 " " $3;
            }'
}

gpu_process_count() {
    nvidia-smi --query-compute-apps=gpu_uuid --format=csv,noheader,nounits 2>/dev/null |
        awk -v uuid="${GPU_UUID}" '{gsub(/ /, "", $0); if ($0 == uuid) count++} END {print count + 0}'
}

wait_for_idle_gpu() {
    local stable=0
    local memory_used utilization process_count
    while (( stable < 3 )); do
        read -r memory_used utilization < <(gpu_snapshot)
        process_count="$(gpu_process_count)"
        if [[ -n "${memory_used:-}" ]] &&
           (( process_count == 0 && memory_used <= 64 && utilization <= 5 )); then
            ((stable += 1))
            log "gpu=${GPU_INDEX} idle_sample=${stable}/3 memory_mib=${memory_used} utilization=${utilization}%"
        else
            stable=0
            log "gpu=${GPU_INDEX} busy; waiting memory_mib=${memory_used:-unknown} utilization=${utilization:-unknown}% processes=${process_count}"
        fi
        if (( stable < 3 )); then
            sleep 5
        fi
    done
}

dataset_paths() {
    local dataset="$1"
    case "${dataset}" in
        twitter_10k)
            printf '%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_twitter_10k.txt" \
                "${DATA_ROOT}/update_twitter_10k.txt" \
                "${DATA_ROOT}/stream_size_twitter_10k.txt" 0
            ;;
        twitter_100k)
            printf '%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_twitter_100k.txt" \
                "${DATA_ROOT}/update_twitter_100k.txt" \
                "${DATA_ROOT}/stream_size_twitter_100k.txt" 0
            ;;
        friendster_10k)
            printf '%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_friendster_50p_10k.txt" \
                "${DATA_ROOT}/update_friendster_50p_10k.txt" \
                "${DATA_ROOT}/stream_size_friendster_50p_10k.txt" 0
            ;;
        friendster_100k)
            printf '%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_friendster_50p_100k.txt" \
                "${DATA_ROOT}/update_friendster_50p_100k.txt" \
                "${DATA_ROOT}/stream_size_friendster_50p_100k.txt" 0
            ;;
        *)
            return 1
            ;;
    esac
}

extract_metrics() {
    python3 - "$1" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(errors="ignore")
times = [
    float(value)
    for value in re.findall(
        r"\[P0-TIMER\]\[SSSP\]\[batch\s+\d+\]\s+total_batch:\s+([0-9.]+)",
        text,
    )
]
final = ""
matches = re.findall(r"final_reachable=(\d+)", text)
if not matches:
    matches = re.findall(r"final_result_count:\s*(\d+)", text)
if matches:
    final = matches[-1]
total = sum(times)
average = total / len(times) if times else 0.0
print(f"{total:.3f}\t{len(times)}\t{average:.3f}\t{final}")
PY
}

run_one() {
    local system="$1"
    local dataset="$2"
    local graph update stream_size source
    IFS=$'\t' read -r graph update stream_size source < <(dataset_paths "${dataset}") ||
        fail "unknown dataset: ${dataset}"

    for input in "${graph}" "${update}" "${stream_size}"; do
        [[ -f "${input}" ]] || fail "missing dataset file: ${input}"
    done

    local binary root
    local -a system_args
    case "${system}" in
        current)
            binary="${CURRENT_BIN}"
            root="${ROOT_CURRENT}"
            system_args=(--hybrid=0 --sssp_cpu_partition_capacity=0)
            ;;
        cgpustreamgraph)
            binary="${BASELINE_BIN}"
            root="${ROOT_BASELINE}"
            system_args=(--hybrid=1)
            ;;
        *)
            fail "unknown system: ${system}"
            ;;
    esac

    local log_file="${RUN_DIR}/${dataset}_${system}.log"
    local cmd_file="${RUN_DIR}/${dataset}_${system}.cmd"
    local -a command=(
        "${binary}"
        "--graphfile=${graph}"
        --format=market_big
        --weight_num=1
        --weight=1
        "--updatefile=${update}"
        "--update_size=${stream_size}"
        "--source_node=${source}"
        --SEGMENT=512
        --n_stream=3
        --cache=2
        --check=false
        --verbose=false
        "--sssp_max_batches=${MAX_BATCHES}"
        "${system_args[@]}"
    )

    {
        printf 'cd %q\n' "${root}"
        printf 'CUDA_VISIBLE_DEVICES=%q timeout %q' "${GPU_INDEX}" "${RUN_TIMEOUT_SECONDS}"
        printf ' %q' "${command[@]}"
        printf '\n'
    } >"${cmd_file}"

    wait_for_idle_gpu
    log "start system=${system} dataset=${dataset} gpu=${GPU_INDEX}"
    local rc
    (
        cd "${root}" || exit 125
        CUDA_VISIBLE_DEVICES="${GPU_INDEX}" timeout "${RUN_TIMEOUT_SECONDS}" "${command[@]}"
    ) >"${log_file}" 2>&1
    rc=$?

    local status="ok"
    if (( rc == 124 )); then
        status="timeout"
    elif (( rc != 0 )); then
        status="failed"
    elif grep -qiE 'out of memory|cudaErrorMemoryAllocation|std::bad_alloc' "${log_file}"; then
        status="oom"
    fi

    local metrics total batches average final
    metrics="$(extract_metrics "${log_file}")"
    IFS=$'\t' read -r total batches average final <<<"${metrics}"
    if (( batches != MAX_BATCHES )) && [[ "${status}" == "ok" ]]; then
        status="incomplete"
    fi
    printf '%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${system}" "${dataset}" "${rc}" "${status}" "${total}" \
        "${batches}" "${average}" "${final}" "${log_file}" >>"${SUMMARY}"
    log "done system=${system} dataset=${dataset} rc=${rc} status=${status} paper_algorithm_ms=${total} batches=${batches}"
}

write_comparison() {
    python3 - "${SUMMARY}" "${COMPARISON}" <<'PY'
import csv
import pathlib
import sys

summary_path = pathlib.Path(sys.argv[1])
comparison_path = pathlib.Path(sys.argv[2])
rows = list(csv.DictReader(summary_path.open(), delimiter="\t"))
indexed = {(row["dataset"], row["system"]): row for row in rows}
datasets = ["twitter_10k", "twitter_100k", "friendster_10k", "friendster_100k"]
with comparison_path.open("w") as output:
    output.write(
        "dataset\tcurrent_ms\tcgpustreamgraph_ms\t"
        "baseline_over_current_speedup\tcurrent_reduction_percent\tstatus\n"
    )
    for dataset in datasets:
        current = indexed.get((dataset, "current"))
        baseline = indexed.get((dataset, "cgpustreamgraph"))
        if not current or not baseline:
            output.write(f"{dataset}\t\t\t\t\tmissing\n")
            continue
        current_ms = float(current["paper_algorithm_ms"])
        baseline_ms = float(baseline["paper_algorithm_ms"])
        valid = (
            current["status"] == "ok"
            and baseline["status"] == "ok"
            and current_ms > 0
            and baseline_ms > 0
        )
        if valid:
            speedup = baseline_ms / current_ms
            reduction = (baseline_ms - current_ms) * 100.0 / baseline_ms
            status = "ok"
            speedup_text = f"{speedup:.4f}"
            reduction_text = f"{reduction:.2f}"
        else:
            speedup_text = ""
            reduction_text = ""
            status = f"current={current['status']},baseline={baseline['status']}"
        output.write(
            f"{dataset}\t{current_ms:.3f}\t{baseline_ms:.3f}\t"
            f"{speedup_text}\t{reduction_text}\t{status}\n"
        )
PY
}

printf 'system\tdataset\treturncode\tstatus\tpaper_algorithm_ms\tbatches\taverage_batch_ms\tfinal_reachable\tlog\n' >"${SUMMARY}"
log "run_dir=${RUN_DIR} gpu=${GPU_INDEX} uuid=${GPU_UUID} max_batches=${MAX_BATCHES}"
nvidia-smi >"${RUN_DIR}/nvidia-smi.start.txt" 2>&1 || true

for dataset in twitter_10k twitter_100k friendster_10k friendster_100k; do
    run_one current "${dataset}"
    run_one cgpustreamgraph "${dataset}"
done

write_comparison
nvidia-smi >"${RUN_DIR}/nvidia-smi.end.txt" 2>&1 || true
log "all done summary=${SUMMARY} comparison=${COMPARISON}"
