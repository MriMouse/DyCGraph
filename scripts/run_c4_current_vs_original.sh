#!/usr/bin/env bash
set -uo pipefail

# C4 screening benchmark. This runner is intentionally self-contained so it can
# be launched under nohup/setsid and continue after the controlling SSH session
# disappears.

ROOT_CURRENT="${ROOT_CURRENT:-/home/wangshaoyan/proJect/C-GpuStreamGraph-CG}"
ROOT_BASELINE="${ROOT_BASELINE:-/home/wangshaoyan/proJect/CG/C-GpuStreamGraph}"
REFERENCE_NAME="${REFERENCE_NAME:-original}"
REFERENCE_HYBRID="${REFERENCE_HYBRID:-1}"
REFERENCE_CPU_PARTITION_CAPACITY="${REFERENCE_CPU_PARTITION_CAPACITY:-}"
DATA_ROOT="${DATA_ROOT:-/home/wangshaoyan/proJect/CG/Grapin-CG/data}"
GPU_INDEX="${GPU_INDEX:-0}"
CACHE="${CACHE:-2}"
MAX_BATCHES="${MAX_BATCHES:-10}"
SCREENING_REPEATS="${SCREENING_REPEATS:-3}"
RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-10800}"
GPU_SAMPLE_SECONDS="${GPU_SAMPLE_SECONDS:-1}"
IDLE_MEMORY_MIB="${IDLE_MEMORY_MIB:-64}"
IDLE_UTIL_PERCENT="${IDLE_UTIL_PERCENT:-5}"
DATASETS="${DATASETS:-orkut_100k wiki_100k twitter_100k friendster_100k}"
RUN_DIR="${RUN_DIR:-${ROOT_CURRENT}/logs/c4_current_vs_original_$(date +%Y%m%d_%H%M%S)}"

CURRENT_BIN="${CURRENT_BIN:-${ROOT_CURRENT}/build/hybrid_sssp}"
BASELINE_BIN="${BASELINE_BIN:-${ROOT_BASELINE}/build/hybrid_sssp}"
RUNS_TSV="${RUN_DIR}/runs.tsv"
AGGREGATE_TSV="${RUN_DIR}/aggregate.tsv"
COMPARISON_TSV="${RUN_DIR}/comparison.tsv"
MANIFEST="${RUN_DIR}/manifest.txt"
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

on_exit() {
    local rc=$?
    printf '%s\n' "${rc}" >"${RUN_DIR}/runner.exitcode"
    log "runner exit rc=${rc}"
}
trap on_exit EXIT

for required in "${CURRENT_BIN}" "${BASELINE_BIN}" /usr/bin/time; do
    [[ -x "${required}" ]] || fail "missing executable: ${required}"
done
for tool in nvidia-smi python3 timeout; do
    command -v "${tool}" >/dev/null 2>&1 || fail "required command is unavailable: ${tool}"
done
[[ "${MAX_BATCHES}" =~ ^[1-9][0-9]*$ ]] || fail "MAX_BATCHES must be a positive integer"
[[ "${SCREENING_REPEATS}" =~ ^[1-9][0-9]*$ ]] || fail "SCREENING_REPEATS must be a positive integer"
[[ "${CACHE}" =~ ^[0-9]+$ ]] || fail "CACHE must be a non-negative integer"
[[ "${REFERENCE_NAME}" =~ ^[a-z0-9_]+$ ]] || fail "REFERENCE_NAME must contain only lowercase letters, digits, and underscores"
[[ "${REFERENCE_HYBRID}" =~ ^[0-9]+$ ]] || fail "REFERENCE_HYBRID must be a non-negative integer"
if [[ -n "${REFERENCE_CPU_PARTITION_CAPACITY}" ]]; then
    [[ "${REFERENCE_CPU_PARTITION_CAPACITY}" =~ ^[0-9]+$ ]] ||
        fail "REFERENCE_CPU_PARTITION_CAPACITY must be empty or a non-negative integer"
fi

GPU_UUID="$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader,nounits |
    awk -F',' -v gpu_index="${GPU_INDEX}" '
        {gsub(/ /, "", $1); gsub(/ /, "", $2); if ($1 == gpu_index) print $2}')"
[[ -n "${GPU_UUID}" ]] || fail "GPU index ${GPU_INDEX} does not exist"

dataset_paths() {
    case "$1" in
        orkut_100k)
            printf '%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_orkut_50p_100k.txt" \
                "${DATA_ROOT}/update_orkut_50p_100k.txt" \
                "${DATA_ROOT}/stream_size_orkut_50p_100k.txt" 377664
            ;;
        wiki_100k)
            printf '%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_wiki_50p_100k.txt" \
                "${DATA_ROOT}/update_wiki_50p_100k.txt" \
                "${DATA_ROOT}/stream_size_wiki_50p_100k.txt" 134151
            ;;
        twitter_100k)
            printf '%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_twitter_100k.txt" \
                "${DATA_ROOT}/update_twitter_100k.txt" \
                "${DATA_ROOT}/stream_size_twitter_100k.txt" 0
            ;;
        friendster_100k)
            printf '%s\t%s\t%s\t%s\n' \
                "${DATA_ROOT}/input_friendster_50p_100k.txt" \
                "${DATA_ROOT}/update_friendster_50p_100k.txt" \
                "${DATA_ROOT}/stream_size_friendster_50p_100k.txt" 0
            ;;
        *) return 1 ;;
    esac
}

gpu_snapshot() {
    nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader,nounits |
        awk -F',' -v gpu_index="${GPU_INDEX}" '
            {gsub(/ /, "", $1); gsub(/ /, "", $2); gsub(/ /, "", $3);
             if ($1 == gpu_index) print $2 " " $3}'
}

gpu_process_count() {
    nvidia-smi --query-compute-apps=gpu_uuid --format=csv,noheader,nounits 2>/dev/null |
        awk -v uuid="${GPU_UUID}" \
            '{gsub(/ /, "", $0); if ($0 == uuid) count++} END {print count + 0}'
}

wait_for_idle_gpu() {
    local stable=0 memory_used utilization process_count
    while (( stable < 3 )); do
        read -r memory_used utilization < <(gpu_snapshot)
        process_count="$(gpu_process_count)"
        if [[ -n "${memory_used:-}" ]] &&
           (( process_count == 0 && memory_used <= IDLE_MEMORY_MIB && utilization <= IDLE_UTIL_PERCENT )); then
            ((stable += 1))
            log "gpu=${GPU_INDEX} idle=${stable}/3 memory_mib=${memory_used} utilization=${utilization}%"
        else
            stable=0
            log "gpu=${GPU_INDEX} busy; wait memory_mib=${memory_used:-unknown} utilization=${utilization:-unknown}% processes=${process_count}"
        fi
        (( stable == 3 )) || sleep 5
    done
}

# Keep the parser in one Python invocation per run. Empty fields mean that the
# corresponding system does not emit that metric.
parse_run() {
    python3 - "$1" "$2" "$3" <<'PY'
import pathlib
import re
import sys

log_path = pathlib.Path(sys.argv[1])
gpu_path = pathlib.Path(sys.argv[2])
expected = int(sys.argv[3])
text = log_path.read_text(errors="ignore")

def values(pattern, group=1):
    return [float(x) for x in re.findall(pattern, text)]

def ints(pattern, group=1):
    return [int(x) for x in re.findall(pattern, text)]

def total(pattern):
    found = values(pattern)
    return f"{sum(found):.3f}" if found else ""

def total_int(pattern):
    found = ints(pattern)
    return str(sum(found)) if found else ""

paper = values(r"\[P0-TIMER\]\[SSSP\]\[batch\s+\d+\]\s+total_batch:\s+([0-9.]+)")
wall = values(r"\[C4-WALL\]\s+elapsed_seconds=([0-9.]+)")
rss = ints(r"\[C4-WALL\].*max_rss_kb=(\d+)")
gpu_peak = 0
if gpu_path.exists():
    for line in gpu_path.read_text(errors="ignore").splitlines()[1:]:
        fields = line.split("\t")
        if len(fields) >= 2 and fields[1].isdigit():
            gpu_peak = max(gpu_peak, int(fields[1]))

attrs = {
    name: total(rf"\[P0-ATTR\]\[SSSP\]\[batch \d+\].*?\b{name}=([0-9.]+)")
    for name in ("deletion", "add", "hotness", "candidate", "eviction", "compact", "cache_load", "residual")
}
cache_parts = [attrs[name] for name in ("hotness", "candidate", "eviction", "compact", "cache_load")]
cache_refresh = ""
if all(cache_parts):
    cache_refresh = f"{sum(map(float, cache_parts)):.3f}"

insert = {
    name: total(rf"\[INSERTION-STAGE\]\s+batch=\d+.*?\b{name}=([0-9.]+)")
    for name in ("reset_ms", "cpu_mutation_ms", "topology_publication_audit_ms",
                 "initial_rebuild_ms", "seed_ms", "converge_ms")
}
delete = {
    name: total(rf"\[P0-DELETE-ATTR\]\[batch \d+\].*?\b{name}=([0-9.]+)")
    for name in ("reset_seed_ms", "invalidation_ms", "pma_delete_ms", "repair_wall_ms", "residual_ms")
}

mutation_ms = total(r"\[C3-CPU-MUTATION\]\[batch \d+ phase=(?:add|delete)\].*?mutation_ms=([0-9.]+)")
allocation_ms = total(r"\[C3-CPU-MUTATION\]\[batch \d+ phase=add\].*?allocation_ms=([0-9.]+)")
publication_ms = total(r"\[C3-PUBLISH\]\[batch \d+\].*?publication_ms=([0-9.]+)")
chunk = re.findall(
    r"\[C3-CHUNK-LOAD\]\s+edges=(\d+)\s+capacity_edges=(\d+)\s+slabs=(\d+)\s+metadata_bytes=(\d+)", text)
chunk_edges, chunk_capacity, chunk_slabs, chunk_metadata = chunk[-1] if chunk else ("", "", "", "")
chunk_amplification = ""
if chunk_edges and int(chunk_edges):
    chunk_amplification = f"{int(chunk_capacity) / int(chunk_edges):.6f}"

transfer_h2d = total_int(r"transfer_h2d_bytes:\s*(\d+)")
transfer_d2h = total_int(r"transfer_d2h_bytes:\s*(\d+)")
patch_bytes = total_int(r"\[C3-PUBLISH\]\[batch \d+\].*?patch_bytes=(\d+)")
b2_h2d = total_int(r"\[B2-GPU-REPAIR\]\[batch \d+\].*?h2d_bytes=(\d+)")

checksums = re.findall(r"(?:distance_checksum=|checksum:\s*)(\d+)", text)
if not checksums:
    checksums = re.findall(r"checksum:\s*(\d+)", text)
reachable = re.findall(r"(?:final_reachable=|final_result_count:\s*)(\d+)", text)
protocol_errors = len(re.findall(r"protocol_error|gpu_cpu_hash_mismatches=[1-9]\d*|stale_version_rejects=[1-9]\d*", text))
runtime_errors = len(re.findall(r"out of memory|cudaError|std::bad_alloc|Segmentation fault", text, re.I))

paper_ms = sum(paper)
wall_seconds = wall[-1] if wall else 0.0
nonpaper_ms = max(0.0, wall_seconds * 1000.0 - paper_ms) if wall else 0.0
result = [
    f"{paper_ms:.3f}", str(len(paper)), f"{wall_seconds:.3f}" if wall else "",
    f"{nonpaper_ms:.3f}" if wall else "", str(rss[-1]) if rss else "", str(gpu_peak),
    attrs["deletion"], attrs["add"], cache_refresh, attrs["hotness"], attrs["candidate"],
    attrs["eviction"], attrs["compact"], attrs["cache_load"], attrs["residual"],
    mutation_ms, allocation_ms, publication_ms,
    insert["initial_rebuild_ms"], insert["seed_ms"], insert["converge_ms"],
    delete["reset_seed_ms"], delete["invalidation_ms"], delete["pma_delete_ms"],
    delete["repair_wall_ms"], delete["residual_ms"],
    total(r"\[B2-GPU-REPAIR\]\[batch \d+\].*?topology_ms=([0-9.]+)"),
    total(r"\[B2-GPU-REPAIR\]\[batch \d+\].*?allocation_ms=([0-9.]+)"),
    total(r"\[B2-GPU-REPAIR\]\[batch \d+\].*?h2d_ms=([0-9.]+)"),
    total(r"\[B2-GPU-REPAIR\]\[batch \d+\].*?closure_ms=([0-9.]+)"),
    total_int(r"\[C3-CPU-MUTATION\]\[batch \d+ phase=(?:add|delete)\].*?written_bytes=(\d+)"),
    total_int(r"\[C3-CPU-MUTATION\]\[batch \d+ phase=add\].*?relocation_bytes=(\d+)"),
    total_int(r"\[C3-PUBLISH\]\[batch \d+\].*?patch_records=(\d+)"), patch_bytes,
    total_int(r"\[C3-PUBLISH\]\[batch \d+\].*?h2d_count=(\d+)"),
    total_int(r"\[C3-PUBLISH\]\[batch \d+\].*?cache_invalidations=(\d+)"),
    total_int(r"\[C3-PUBLISH\]\[batch \d+\].*?zc_cold_edges=(\d+)"),
    b2_h2d, transfer_h2d, transfer_d2h,
    chunk_edges, chunk_capacity, chunk_slabs, chunk_metadata, chunk_amplification,
    checksums[-1] if checksums else "", reachable[-1] if reachable else "",
    str(protocol_errors), str(runtime_errors),
]
print("\t".join(result))
PY
}

run_one() {
    local repeat="$1" system="$2" dataset="$3"
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
        "${REFERENCE_NAME}")
            binary="${BASELINE_BIN}"
            root="${ROOT_BASELINE}"
            system_args=("--hybrid=${REFERENCE_HYBRID}")
            if [[ -n "${REFERENCE_CPU_PARTITION_CAPACITY}" ]]; then
                system_args+=("--sssp_cpu_partition_capacity=${REFERENCE_CPU_PARTITION_CAPACITY}")
            fi
            ;;
        *) fail "unknown system: ${system}" ;;
    esac

    local prefix="${RUN_DIR}/r${repeat}_${dataset}_${system}"
    local log_file="${prefix}.log" cmd_file="${prefix}.cmd" gpu_file="${prefix}.gpu.tsv"
    local -a command=(
        "${binary}"
        "--graphfile=${graph}" --format=market_big --weight_num=1 --weight=1
        "--updatefile=${update}" "--update_size=${stream_size}" "--source_node=${source}"
        --SEGMENT=512 --n_stream=3 "--cache=${CACHE}" --check=false --verbose=false
        "--sssp_max_batches=${MAX_BATCHES}" "${system_args[@]}"
    )
    {
        printf 'cd %q\n' "${root}"
        printf 'CUDA_VISIBLE_DEVICES=%q timeout %q' "${GPU_INDEX}" "${RUN_TIMEOUT_SECONDS}"
        printf ' %q' "${command[@]}"
        printf '\n'
    } >"${cmd_file}"

    wait_for_idle_gpu
    log "start repeat=${repeat} system=${system} dataset=${dataset}"
    printf 'unix_seconds\tmemory_mib\tutilization_percent\n' >"${gpu_file}"
    (
        cd "${root}" || exit 125
        /usr/bin/time -f '[C4-WALL] elapsed_seconds=%e max_rss_kb=%M' \
            timeout "${RUN_TIMEOUT_SECONDS}" env CUDA_VISIBLE_DEVICES="${GPU_INDEX}" "${command[@]}"
    ) >"${log_file}" 2>&1 &
    local command_pid=$!
    while kill -0 "${command_pid}" 2>/dev/null; do
        local snapshot memory utilization
        snapshot="$(gpu_snapshot 2>/dev/null || true)"
        if [[ -n "${snapshot}" ]]; then
            read -r memory utilization <<<"${snapshot}"
            printf '%s\t%s\t%s\n' "$(date +%s)" "${memory}" "${utilization}" >>"${gpu_file}"
        fi
        sleep "${GPU_SAMPLE_SECONDS}"
    done
    local rc
    wait "${command_pid}"
    rc=$?

    local status=ok
    if (( rc == 124 )); then
        status=timeout
    elif (( rc != 0 )); then
        status=failed
    elif grep -qiE 'out of memory|cudaError|std::bad_alloc|Segmentation fault' "${log_file}"; then
        status=runtime_error
    fi

    local metrics batches protocol_errors runtime_errors
    metrics="$(parse_run "${log_file}" "${gpu_file}" "${MAX_BATCHES}")"
    batches="$(cut -f2 <<<"${metrics}")"
    protocol_errors="$(cut -f48 <<<"${metrics}")"
    runtime_errors="$(cut -f49 <<<"${metrics}")"
    if [[ "${status}" == ok ]] && (( batches != MAX_BATCHES )); then status=incomplete; fi
    if [[ "${status}" == ok ]] && (( protocol_errors != 0 || runtime_errors != 0 )); then status=invalid; fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${repeat}" "${system}" "${dataset}" "${rc}" "${status}" "${metrics}" "${log_file}" "${cmd_file}" >>"${RUNS_TSV}"
    log "done repeat=${repeat} system=${system} dataset=${dataset} rc=${rc} status=${status} paper_ms=$(cut -f1 <<<"${metrics}") wall_s=$(cut -f3 <<<"${metrics}")"
}

write_aggregate() {
    python3 - "${RUNS_TSV}" "${AGGREGATE_TSV}" "${COMPARISON_TSV}" "${REFERENCE_NAME}" <<'PY'
import csv
import math
import pathlib
import statistics
import sys

runs_path, aggregate_path, comparison_path = map(pathlib.Path, sys.argv[1:4])
reference_name = sys.argv[4]
rows = list(csv.DictReader(runs_path.open(), delimiter="\t"))
metrics = [
    "wall_seconds", "nonpaper_wall_ms", "paper_algorithm_ms",
    "deletion_ms", "add_ms", "cache_refresh_ms", "hotness_ms", "candidate_ms",
    "eviction_ms", "compact_ms", "cache_load_ms", "p0_residual_ms",
    "cpu_mutation_ms", "allocation_ms", "topology_publication_ms",
    "initial_rebuild_ms", "seed_ms", "converge_ms", "delete_reset_seed_ms",
    "delete_invalidation_ms", "physical_delete_ms", "delete_repair_ms",
    "delete_residual_ms", "b2_topology_ms", "b2_allocation_ms", "b2_h2d_ms",
    "b2_closure_ms", "mutation_written_bytes", "relocation_bytes", "patch_records",
    "patch_bytes", "patch_h2d_count", "cache_invalidations", "zc_cold_edges",
    "b2_h2d_bytes", "legacy_h2d_bytes", "legacy_d2h_bytes", "max_rss_kb",
    "gpu_peak_memory_mib", "chunk_edges", "chunk_capacity_edges", "chunk_slabs",
    "chunk_metadata_bytes", "chunk_capacity_amplification",
]

def percentile95(samples):
    ordered = sorted(samples)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]

with aggregate_path.open("w") as out:
    out.write("system\tdataset\tvalid_runs\tmetric\tmedian\tp95\tmin\tmax\n")
    for system in ("current", reference_name):
        for dataset in ("orkut_100k", "wiki_100k", "twitter_100k", "friendster_100k"):
            selected = [r for r in rows if r["system"] == system and r["dataset"] == dataset and r["status"] == "ok"]
            for metric in metrics:
                samples = [float(r[metric]) for r in selected if r[metric] != ""]
                if samples:
                    out.write(f"{system}\t{dataset}\t{len(selected)}\t{metric}\t{statistics.median(samples):.3f}\t{percentile95(samples):.3f}\t{min(samples):.3f}\t{max(samples):.3f}\n")
            combined = [
                float(r["cpu_mutation_ms"]) + float(r["topology_publication_ms"])
                for r in selected
                if r["cpu_mutation_ms"] != "" and r["topology_publication_ms"] != ""
            ]
            if combined:
                out.write(f"{system}\t{dataset}\t{len(selected)}\tcpu_mutation_plus_publication_ms\t{statistics.median(combined):.3f}\t{percentile95(combined):.3f}\t{min(combined):.3f}\t{max(combined):.3f}\n")

indexed = {(r["system"], r["dataset"], r["metric"]): r for r in csv.DictReader(aggregate_path.open(), delimiter="\t")}
with comparison_path.open("w") as out:
    out.write(f"dataset\tmetric\tcurrent_median\t{reference_name}_median\t{reference_name}_over_current\tcurrent_reduction_percent\tfinal_reachable_match\tcurrent_gpu_peak_mib\t{reference_name}_gpu_peak_mib\tgpu_memory_not_increased\tstatus\n")
    for dataset in ("orkut_100k", "wiki_100k", "twitter_100k", "friendster_100k"):
        current_outputs = {r["final_reachable"] for r in rows if r["system"] == "current" and r["dataset"] == dataset and r["status"] == "ok" and r["final_reachable"]}
        reference_outputs = {r["final_reachable"] for r in rows if r["system"] == reference_name and r["dataset"] == dataset and r["status"] == "ok" and r["final_reachable"]}
        output_match = "yes" if len(current_outputs) == 1 and current_outputs == reference_outputs else "no"
        current_gpu = indexed.get(("current", dataset, "gpu_peak_memory_mib"))
        reference_gpu = indexed.get((reference_name, dataset, "gpu_peak_memory_mib"))
        current_gpu_text = current_gpu["median"] if current_gpu else ""
        reference_gpu_text = reference_gpu["median"] if reference_gpu else ""
        gpu_ok = bool(current_gpu and reference_gpu and float(current_gpu_text) <= float(reference_gpu_text))
        gpu_ok_text = "yes" if gpu_ok else "no"
        for metric in ("wall_seconds", "paper_algorithm_ms"):
            current = indexed.get(("current", dataset, metric))
            reference = indexed.get((reference_name, dataset, metric))
            if not current or not reference:
                out.write(f"{dataset}\t{metric}\t\t\t\t\t{output_match}\t{current_gpu_text}\t{reference_gpu_text}\t{gpu_ok_text}\tmissing\n")
                continue
            cur, old = float(current["median"]), float(reference["median"])
            speedup = old / cur if cur else 0.0
            reduction = (old - cur) * 100.0 / old if old else 0.0
            enough = int(current["valid_runs"]) >= 3 and int(reference["valid_runs"]) >= 3
            if not enough:
                status = "insufficient_runs"
            elif output_match != "yes":
                status = "output_mismatch"
            elif not gpu_ok:
                status = "gpu_memory_regression"
            else:
                status = "ok"
            out.write(f"{dataset}\t{metric}\t{cur:.3f}\t{old:.3f}\t{speedup:.4f}\t{reduction:.2f}\t{output_match}\t{current_gpu_text}\t{reference_gpu_text}\t{gpu_ok_text}\t{status}\n")
PY
}

if [[ "${AGGREGATE_ONLY:-false}" == true ]]; then
    [[ -f "${RUNS_TSV}" ]] || fail "cannot aggregate missing file: ${RUNS_TSV}"
    write_aggregate
    log "aggregate-only complete aggregate=${AGGREGATE_TSV} comparison=${COMPARISON_TSV}"
    exit 0
fi

printf '%s\n' \
    $'repeat\tsystem\tdataset\treturncode\tstatus\tpaper_algorithm_ms\tbatches\twall_seconds\tnonpaper_wall_ms\tmax_rss_kb\tgpu_peak_memory_mib\tdeletion_ms\tadd_ms\tcache_refresh_ms\thotness_ms\tcandidate_ms\teviction_ms\tcompact_ms\tcache_load_ms\tp0_residual_ms\tcpu_mutation_ms\tallocation_ms\ttopology_publication_ms\tinitial_rebuild_ms\tseed_ms\tconverge_ms\tdelete_reset_seed_ms\tdelete_invalidation_ms\tphysical_delete_ms\tdelete_repair_ms\tdelete_residual_ms\tb2_topology_ms\tb2_allocation_ms\tb2_h2d_ms\tb2_closure_ms\tmutation_written_bytes\trelocation_bytes\tpatch_records\tpatch_bytes\tpatch_h2d_count\tcache_invalidations\tzc_cold_edges\tb2_h2d_bytes\tlegacy_h2d_bytes\tlegacy_d2h_bytes\tchunk_edges\tchunk_capacity_edges\tchunk_slabs\tchunk_metadata_bytes\tchunk_capacity_amplification\tfinal_checksum\tfinal_reachable\tprotocol_errors\truntime_errors\tlog\tcommand' >"${RUNS_TSV}"

log "run_dir=${RUN_DIR} gpu=${GPU_INDEX} uuid=${GPU_UUID} repeats=${SCREENING_REPEATS} batches=${MAX_BATCHES} datasets=${DATASETS}"
{
    printf 'started_utc=%s\n' "$(date -u '+%FT%TZ')"
    printf 'host=%s\n' "$(hostname)"
    printf 'gpu_index=%s\ngpu_uuid=%s\ncache=%s\nmax_batches=%s\nrepeats=%s\ndatasets=%s\nreference_name=%s\nreference_hybrid=%s\nreference_cpu_partition_capacity=%s\n' \
        "${GPU_INDEX}" "${GPU_UUID}" "${CACHE}" "${MAX_BATCHES}" "${SCREENING_REPEATS}" "${DATASETS}" \
        "${REFERENCE_NAME}" "${REFERENCE_HYBRID}" "${REFERENCE_CPU_PARTITION_CAPACITY}"
    printf 'current_root=%s\ncurrent_head=%s\n' "${ROOT_CURRENT}" "$(git -C "${ROOT_CURRENT}" rev-parse HEAD 2>/dev/null || true)"
    printf 'reference_root=%s\nreference_head=%s\n' "${ROOT_BASELINE}" "$(git -C "${ROOT_BASELINE}" rev-parse HEAD 2>/dev/null || true)"
    sha256sum "${CURRENT_BIN}" "${BASELINE_BIN}"
    printf '\n[current status]\n'
    git -C "${ROOT_CURRENT}" status --short 2>/dev/null || true
    printf '\n[reference status]\n'
    git -C "${ROOT_BASELINE}" status --short 2>/dev/null || true
} >"${MANIFEST}"
nvidia-smi >"${RUN_DIR}/nvidia-smi.start.txt" 2>&1 || true
for dataset in ${DATASETS}; do
    dataset_paths "${dataset}" >/dev/null || fail "unknown dataset in DATASETS: ${dataset}"
done

for ((repeat = 1; repeat <= SCREENING_REPEATS; ++repeat)); do
    for dataset in ${DATASETS}; do
        if (( repeat % 2 == 1 )); then
            run_one "${repeat}" current "${dataset}"
            run_one "${repeat}" "${REFERENCE_NAME}" "${dataset}"
        else
            run_one "${repeat}" "${REFERENCE_NAME}" "${dataset}"
            run_one "${repeat}" current "${dataset}"
        fi
        write_aggregate
    done
done

write_aggregate
nvidia-smi >"${RUN_DIR}/nvidia-smi.end.txt" 2>&1 || true
log "all done runs=${RUNS_TSV} aggregate=${AGGREGATE_TSV} comparison=${COMPARISON_TSV}"
