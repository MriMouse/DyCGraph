#!/usr/bin/env python3
"""Extract round-level cooperative mechanism attribution from SSSP logs."""

import argparse
import re
import sys


KV_RE = re.compile(r"([A-Za-z0-9_]+)=([^ \n]+)")
BATCH_TIMER_RE = re.compile(
    r"\[P0-TIMER\]\[SSSP\]\[batch ([0-9]+)\] ([A-Za-z0-9_]+): ([0-9.]+) ms"
)


def parse_kv_line(line):
    return {key: value for key, value in KV_RE.findall(line)}


def main():
    parser = argparse.ArgumentParser(
        description="Convert verbose CPU-owned packet logs to TSV."
    )
    parser.add_argument("logfile", help="Path to a hybrid_sssp log, or '-' for stdin.")
    parser.add_argument("--dataset", default="", help="Dataset label to write in TSV.")
    parser.add_argument("--cache", default="", help="Cache configuration label.")
    parser.add_argument("--mode", default="", help="Run mode label, e.g. off or hybrid.")
    args = parser.parse_args()

    lines = sys.stdin if args.logfile == "-" else open(args.logfile, "r", encoding="utf-8")
    rows = {}
    batch_timers = {}

    with lines:
        for line in lines:
            timer_match = BATCH_TIMER_RE.search(line)
            if timer_match:
                batch = int(timer_match.group(1))
                timer_name = timer_match.group(2)
                timer_ms = timer_match.group(3)
                batch_timers.setdefault(batch, {})[f"{timer_name}_ms"] = timer_ms
                continue

            if "[COOP-SKIP-AUDIT]" in line:
                fields = parse_kv_line(line)
                key = (int(fields.get("seq", 0)), int(fields.get("round", 0)))
                row = rows.setdefault(key, {})
                row.update(fields)
                continue

            if "[COOP-ATTRIBUTION]" in line:
                fields = parse_kv_line(line)
                key = (int(fields.get("seq", 0)), int(fields.get("round", 0)))
                row = rows.setdefault(key, {})
                row.update(fields)

    columns = [
        "dataset",
        "cache",
        "mode",
        "source_policy",
        "batch",
        "round",
        "frontier_active_sources",
        "active_segments",
        "cpu_edges",
        "skipped_sources",
        "skipped_edges_est",
        "merge_success",
        "merge_success_per_edge",
        "merge_success_per_compressed",
        "cpu_ms",
        "merge_ms",
        "postbw_ms",
        "cache_ms",
        "dirty_segments",
        "dirty_ratio",
        "postbw_active_count",
        "cached_active_sources",
        "non_cached_active_sources",
        "cached_edges",
        "non_cached_edges",
        "merge_prefilter_enabled",
        "merge_prefilter_input",
        "merge_prefilter_kept",
        "merge_prefilter_dropped",
        "merge_prefilter_ms",
        "owner_merge_postbw_fixed_tax_ms",
    ]
    print("\t".join(columns))

    for _, row in sorted(rows.items()):
        batch = row.get("batch", "")
        batch_cache_ms = ""
        if batch != "":
            batch_cache_ms = batch_timers.get(int(batch), {}).get("hot_cache_refresh_ms", "")
        output = {
            "dataset": args.dataset,
            "cache": args.cache,
            "mode": args.mode,
            "source_policy": row.get("source_policy", ""),
            "batch": batch,
            "round": row.get("round", ""),
            "frontier_active_sources": row.get("frontier_active_sources", ""),
            "active_segments": row.get("active_segments", ""),
            "cpu_edges": row.get("cpu_covered_edges", ""),
            "skipped_sources": row.get("gpu_skipped_sources", ""),
            "skipped_edges_est": row.get("skipped_edges_est", ""),
            "merge_success": row.get("merge_success", ""),
            "merge_success_per_edge": row.get("merge_success_per_edge", ""),
            "merge_success_per_compressed": row.get("merge_success_per_compressed", ""),
            "cpu_ms": row.get("cpu_generate_ms", ""),
            "merge_ms": row.get("merge_wall_ms", ""),
            "postbw_ms": row.get("postbw_ms", ""),
            "cache_ms": batch_cache_ms,
            "dirty_segments": row.get("dirty_segments", ""),
            "dirty_ratio": row.get("dirty_ratio", ""),
            "postbw_active_count": row.get("postbw_active_count", ""),
            "cached_active_sources": row.get("cached_active_sources", ""),
            "non_cached_active_sources": row.get("non_cached_active_sources", ""),
            "cached_edges": row.get("cached_edges", ""),
            "non_cached_edges": row.get("non_cached_edges", ""),
            "merge_prefilter_enabled": row.get("merge_prefilter_enabled", ""),
            "merge_prefilter_input": row.get("merge_prefilter_input", ""),
            "merge_prefilter_kept": row.get("merge_prefilter_kept", ""),
            "merge_prefilter_dropped": row.get("merge_prefilter_dropped", ""),
            "merge_prefilter_ms": row.get("merge_prefilter_ms", ""),
            "owner_merge_postbw_fixed_tax_ms": row.get(
                "owner_merge_postbw_fixed_tax_ms", ""
            ),
        }
        print("\t".join(str(output[column]) for column in columns))


if __name__ == "__main__":
    main()
