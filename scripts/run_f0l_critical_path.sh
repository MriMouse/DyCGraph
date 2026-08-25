#!/usr/bin/env bash
set -uo pipefail

ROOT="${ROOT:-/home/wangshaoyan/proJect/C-GpuStreamGraph-CG}"
DATA_ROOT="${DATA_ROOT:-/home/wangshaoyan/proJect/CG/Grapin-CG/data}"
EU_DATA_ROOT="${EU_DATA_ROOT:-/home/wangshaoyan/proJect/gunrock/examples/data}"
BIN="${BIN:-${ROOT}/build/hybrid_sssp}"
GPU_INDEX="${GPU_INDEX:-0}"
CACHE="${CACHE:-2}"
REPEATS="${REPEATS:-3}"
MAX_BATCHES="${MAX_BATCHES:-10}"
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-10800}"
RUN_DIR="${RUN_DIR:-${ROOT}/logs/f0l_$(date +%Y%m%d_%H%M%S)}"

fail() { printf 'fatal: %s\n' "$*" >&2; exit 1; }
[[ -x "${BIN}" ]] || fail "missing executable: ${BIN}"
[[ "${REPEATS}" =~ ^[1-9][0-9]*$ ]] || fail "REPEATS must be positive"
[[ "${MAX_BATCHES}" == 10 ]] || fail "F0-L requires MAX_BATCHES=10"
[[ "${CACHE}" =~ ^[0-9]+$ ]] || fail "CACHE must be non-negative"
mkdir -p "${RUN_DIR}"

dataset_paths() {
    case "$1" in
        twitter) printf '%s\t%s\t%s\t%s\n' "${DATA_ROOT}/input_twitter_100k.txt" "${DATA_ROOT}/update_twitter_100k.txt" "${DATA_ROOT}/stream_size_twitter_100k.txt" 0 ;;
        friendster) printf '%s\t%s\t%s\t%s\n' "${DATA_ROOT}/input_friendster_50p_100k.txt" "${DATA_ROOT}/update_friendster_50p_100k.txt" "${DATA_ROOT}/stream_size_friendster_50p_100k.txt" 0 ;;
        europe) printf '%s\t%s\t%s\t%s\n' "${EU_DATA_ROOT}/input_eu_100k.mtx" "${EU_DATA_ROOT}/update_eu_100k.txt" "${EU_DATA_ROOT}/stream_size_eu_100k.txt" 0 ;;
        *) return 1 ;;
    esac
}

run_one() {
    local repeat="$1" dataset="$2" graph update stream source
    IFS=$'\t' read -r graph update stream source < <(dataset_paths "${dataset}") || fail "unknown dataset ${dataset}"
    for input in "${graph}" "${update}" "${stream}"; do [[ -f "${input}" ]] || fail "missing input ${input}"; done
    local log="${RUN_DIR}/r${repeat}_${dataset}.log"
    local cmd="${RUN_DIR}/r${repeat}_${dataset}.cmd"
    local -a args=(
        "${BIN}" "--graphfile=${graph}" --format=market_big --weight_num=1 --weight=1
        "--updatefile=${update}" "--update_size=${stream}" "--source_node=${source}"
        --SEGMENT=512 --n_stream=3 "--cache=${CACHE}" --hybrid=0
        --sssp_cpu_partition_capacity=0 --check=false --verbose=false
        "--sssp_max_batches=${MAX_BATCHES}"
    )
    printf 'CUDA_VISIBLE_DEVICES=%q timeout %q' "${GPU_INDEX}" "${RUN_TIMEOUT_SECONDS}" >"${cmd}"
    printf ' %q' "${args[@]}" >>"${cmd}"
    printf '\n' >>"${cmd}"
    printf '[F0-L] start repeat=%s dataset=%s\n' "${repeat}" "${dataset}"
    (cd "${ROOT}" && timeout "${RUN_TIMEOUT_SECONDS}" env CUDA_VISIBLE_DEVICES="${GPU_INDEX}" "${args[@]}") >"${log}" 2>&1
    python3 "${ROOT}/scripts/analyze_f0l_trace.py" --expected-batches "${MAX_BATCHES}" "${log}" >/dev/null ||
        fail "invalid or unclosed trace: ${log}"
}

{
    printf 'started_utc=%s\n' "$(date -u '+%FT%TZ')"
    printf 'head=%s\ngpu_index=%s\ncache=%s\nrepeats=%s\n' "$(git -C "${ROOT}" rev-parse HEAD)" "${GPU_INDEX}" "${CACHE}" "${REPEATS}"
    printf 'data_root=%s\neu_data_root=%s\n' "${DATA_ROOT}" "${EU_DATA_ROOT}"
} >"${RUN_DIR}/manifest.txt"

datasets=(twitter friendster europe)
for ((repeat = 1; repeat <= REPEATS; ++repeat)); do
    if (( repeat % 2 == 0 )); then order=(europe friendster twitter); else order=(twitter friendster europe); fi
    for dataset in "${order[@]}"; do run_one "${repeat}" "${dataset}"; done
done

for dataset in "${datasets[@]}"; do
    python3 "${ROOT}/scripts/analyze_f0l_trace.py" --expected-batches "${MAX_BATCHES}" \
        --json "${RUN_DIR}/${dataset}_summary.json" "${RUN_DIR}"/r*_${dataset}.log >/dev/null ||
        fail "dataset audit failed: ${dataset}"
done
printf '[F0-L] complete run_dir=%s\n' "${RUN_DIR}"
