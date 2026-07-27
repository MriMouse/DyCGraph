#!/usr/bin/env bash
set -uo pipefail

ROOT_CURRENT="${ROOT_CURRENT:-/home/wangshaoyan/proJect/C-GpuStreamGraph-CG}"
DATA_ROOT="${DATA_ROOT:-/home/wangshaoyan/proJect/CG/Grapin-CG/data}"
GPU_INDEX="${GPU_INDEX:-2}"
MAX_BATCHES="${MAX_BATCHES:-5}"
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-3600}"
RUN_DIR="${RUN_DIR:-${ROOT_CURRENT}/logs/iterB2_$(date +%Y%m%d_%H%M%S)}"
DATASETS="${DATASETS:-wiki_100k twitter_100k friendster_100k}"

mkdir -p "${RUN_DIR}"
SUMMARY="${RUN_DIR}/summary.tsv"
printf 'dataset\tstatus\tbatches\tdelete_checks\tbatch_checks\tpaper_ms\tdelete_ms\trepair_ms\tinvalidation_ms\taffected_vertices\td2h_bytes\th2d_bytes\tmetadata_device_bytes\tfinal_reachable\tdistance_checksum\tlog\n' >"${SUMMARY}"

dataset_args() {
    case "$1" in
        wiki_100k)
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_wiki_50p_100k.txt" \
                "${DATA_ROOT}/update_wiki_50p_100k.txt" \
                "${DATA_ROOT}/stream_size_wiki_50p_100k.txt" 134151 0
            ;;
        twitter_100k)
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_twitter_100k.txt" \
                "${DATA_ROOT}/update_twitter_100k.txt" \
                "${DATA_ROOT}/stream_size_twitter_100k.txt" 0 2
            ;;
        friendster_100k)
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_friendster_50p_100k.txt" \
                "${DATA_ROOT}/update_friendster_50p_100k.txt" \
                "${DATA_ROOT}/stream_size_friendster_50p_100k.txt" 0 2
            ;;
        *) return 1 ;;
    esac
}

extract_metrics() {
    python3 - "$1" "$2" <<'PY'
import pathlib
import re
import sys

path, expected_text = sys.argv[1:]
expected = int(expected_text)
text = pathlib.Path(path).read_text(errors="ignore")

def total_float(pattern):
    return sum(map(float, re.findall(pattern, text)))

def total_int(pattern):
    return sum(map(int, re.findall(pattern, text)))

batches = len(re.findall(r"\[P0-TIMER\]\[SSSP\]\[batch \d+\]", text))
delete_checks = len(re.findall(r"\[SSSP-DELETE-STAGE-CHECK\]\[batch \d+\] passed", text))
batch_checks = len(re.findall(r"\[SSSP-BATCH-CHECK\]\[batch \d+\] passed", text))
paper = total_float(r"\[P0-TIMER\]\[SSSP\]\[batch \d+\] total_batch: ([0-9.]+)")
delete = total_float(r"\[P0-DELETE-ATTR\][^\n]*?total_ms=([0-9.]+)")
repair = total_float(r"\[P0-DELETE-ATTR\][^\n]*?repair_wall_ms=([0-9.]+)")
invalidation = total_float(r"\[P0-DELETE-ATTR\][^\n]*?invalidation_ms=([0-9.]+)")
affected = total_int(r"\[B2-AFFECTED\]\[batch \d+\] vertices=(\d+)")
d2h = total_int(r"\[B2-AFFECTED\][^\n]*?d2h_bytes=(\d+)")
h2d = total_int(r"\[B2-GPU-REPAIR\][^\n]*?h2d_bytes=(\d+)")
metadata = max(map(int, re.findall(r"\[B2-AFFECTED\][^\n]*?metadata_device_bytes=(\d+)", text)), default=0)
reachable = re.findall(r"\[SSSP-FINAL-CHECK\] final_reachable=(\d+)", text)
checksums = re.findall(r"\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)", text)
failed = bool(re.search(r"protocol_error|Bellman failed|CHECK\][^\n]*failed|Overall: Test failed", text, re.I))
ok = batches == expected and delete_checks == expected and batch_checks == expected and not failed

print("\t".join(map(str, [
    "ok" if ok else "failed", batches, delete_checks, batch_checks,
    f"{paper:.3f}", f"{delete:.3f}", f"{repair:.3f}", f"{invalidation:.3f}",
    affected, d2h, h2d, metadata,
    reachable[-1] if reachable else "",
    checksums[-1] if checksums else "",
])))
PY
}

run_one() {
    local dataset="$1"
    local graph update sizes source cache
    IFS=$'\t' read -r graph update sizes source cache < <(dataset_args "${dataset}") || return 2
    local log="${RUN_DIR}/${dataset}.log"
    local -a command=(
        "${ROOT_CURRENT}/build/hybrid_sssp"
        "--graphfile=${graph}" --format=market_big --weight_num=1 --weight=1
        "--updatefile=${update}" "--update_size=${sizes}" "--source_node=${source}"
        --SEGMENT=512 --n_stream=3 "--cache=${cache}" --check=true --verbose=false
        "--sssp_max_batches=${MAX_BATCHES}" --hybrid=0 --sssp_cpu_partition_capacity=0
        --sssp_print_checksum=true
    )
    printf '%q ' "${command[@]}" >"${RUN_DIR}/${dataset}.cmd"
    printf '\n' >>"${RUN_DIR}/${dataset}.cmd"
    echo "[B2-RUN] start dataset=${dataset}"
    local rc=0
    (cd "${ROOT_CURRENT}" && CUDA_VISIBLE_DEVICES="${GPU_INDEX}" timeout "${RUN_TIMEOUT_SECONDS}" "${command[@]}") >"${log}" 2>&1 || rc=$?
    local metrics status
    metrics="$(extract_metrics "${log}" "${MAX_BATCHES}")"
    status="${metrics%%$'\t'*}"
    if (( rc != 0 )); then status="rc_${rc}"; fi
    printf '%s\t%s\t%s\t%s\n' "${dataset}" "${status}" "${metrics#*$'\t'}" "${log}" >>"${SUMMARY}"
    echo "[B2-RUN] done dataset=${dataset} status=${status}"
}

for dataset in ${DATASETS}; do
    run_one "${dataset}"
done

echo "[B2-RUN] summary=${SUMMARY}"
