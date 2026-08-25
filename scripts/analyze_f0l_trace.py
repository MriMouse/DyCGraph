#!/usr/bin/env python3
import argparse
import json
import pathlib
import re
import statistics
import sys


TASKS = (
    "deletion",
    "add",
    "hotness",
    "candidate",
    "eviction",
    "compact",
    "cache_load",
)


def values(pattern, text):
    return [float(value) for value in re.findall(pattern, text)]


def totals_by_field(tag, fields, text):
    result = {}
    lines = re.findall(rf"\[{tag}\][^\n]+", text)
    for field in fields:
        samples = []
        for line in lines:
            match = re.search(rf"\b{field}=([0-9.]+)", line)
            if match:
                samples.append(float(match.group(1)))
        result[field] = sum(samples)
    result["records"] = len(lines)
    return result


def parse_log(path, expected_batches):
    text = path.read_text(errors="ignore")
    totals = values(
        r"\[P0-TIMER\]\[SSSP\]\[batch\s+\d+\]\s+total_batch:\s+([0-9.]+)",
        text,
    )
    rows = re.findall(r"\[P0-ATTR\]\[SSSP\]\[batch (\d+)\]([^\n]+)", text)
    per_task = {task: [] for task in TASKS}
    residuals = []
    for _, fields in rows:
        for task in TASKS:
            match = re.search(rf"\b{task}=([0-9.]+)", fields)
            if match:
                per_task[task].append(float(match.group(1)))
        match = re.search(r"\bresidual=([-0-9.]+)", fields)
        if match:
            residuals.append(float(match.group(1)))
    attributed = sum(sum(samples) for samples in per_task.values())
    paper = sum(totals)
    residual = paper - attributed
    residual_percent = abs(residual) * 100.0 / paper if paper else float("inf")
    errors = re.findall(
        r"protocol_error|out of memory|cudaError|std::bad_alloc|Segmentation fault",
        text,
        re.IGNORECASE,
    )
    repair = totals_by_field(
        "B2-GPU-REPAIR",
        ("affected", "incoming_edges", "base_edges_scanned", "delta_records_scanned",
         "merge_output_sources", "topology_ms", "allocation_ms", "h2d_bytes", "h2d_ms",
         "iterations", "closure_ms"),
        text,
    )
    mutation = totals_by_field(
        "C3-CPU-MUTATION",
        ("touched", "changed", "written_bytes", "relocation_bytes", "mutation_ms", "allocation_ms"),
        text,
    )
    publication = totals_by_field(
        "C3-PUBLISH",
        ("patch_records", "patch_bytes", "h2d_count", "publication_ms", "cache_invalidations",
         "zc_cold_edges"),
        text,
    )
    insertion = totals_by_field(
        "INSERTION-STAGE",
        ("reset_ms", "cpu_mutation_ms", "topology_publication_audit_ms", "initial_rebuild_ms",
         "seed_ms", "converge_ms"),
        text,
    )
    return {
        "log": str(path),
        "valid": len(totals) == expected_batches and len(rows) == expected_batches and not errors,
        "batches": len(totals),
        "paper_algorithm_ms": paper,
        "attributed_ms": attributed,
        "residual_ms": residual,
        "residual_percent": residual_percent,
        "closure_pass": residual_percent <= 2.0,
        "tasks_ms": {task: sum(samples) for task, samples in per_task.items()},
        "gpu_affected_repair": repair,
        "topology_mutation": mutation,
        "topology_publication": publication,
        "insertion_stage": insertion,
        "errors": len(errors),
    }


def main():
    parser = argparse.ArgumentParser(description="Summarize F0-L production traces")
    parser.add_argument("logs", nargs="+", type=pathlib.Path)
    parser.add_argument("--expected-batches", type=int, default=10)
    parser.add_argument("--json", type=pathlib.Path)
    args = parser.parse_args()
    runs = [parse_log(path, args.expected_batches) for path in args.logs]
    valid = [run for run in runs if run["valid"]]
    medians = {}
    if valid:
        paper = statistics.median(run["paper_algorithm_ms"] for run in valid)
        for task in TASKS:
            task_ms = statistics.median(run["tasks_ms"][task] for run in valid)
            share = task_ms * 100.0 / paper if paper else 0.0
            medians[task] = {"baseline_window_ms": task_ms, "paper_share_percent": share}
    report = {
        "runs": runs,
        "valid_runs": len(valid),
        "all_closed_within_2_percent": bool(valid) and all(run["closure_pass"] for run in valid),
        "task_medians": medians,
        "screening_candidates": [
            task for task, metric in medians.items() if metric["paper_share_percent"] >= 10.0
        ],
        "mechanism_medians": {},
    }
    if valid:
        for section in ("gpu_affected_repair", "topology_mutation", "topology_publication", "insertion_stage"):
            keys = valid[0][section].keys()
            report["mechanism_medians"][section] = {
                key: statistics.median(run[section][key] for run in valid) for key in keys
            }
    output = json.dumps(report, indent=2, sort_keys=True)
    if args.json:
        args.json.write_text(output + "\n")
    print(output)
    if len(valid) != len(runs) or not report["all_closed_within_2_percent"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
