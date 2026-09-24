#!/usr/bin/env python3
"""Export the 2026-09-21 timing sweep to a flat, plotting-friendly CSV."""

import argparse
import csv
import json
from pathlib import Path


NULL = "NULL"
MAX_BATCHES = 10


def value_or_null(value):
    return NULL if value is None else value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    rows = json.loads(args.input.read_text())
    fields = [
        "run_id", "group", "dataset", "update_k", "system", "cache_gb",
        "ordered_mode", "maintenance_mode", "repeat", "expected_batches",
        "measured_batches", "timing_complete", "status", "returncode",
    ]
    fields += [f"batch_{batch}_ms" for batch in range(1, MAX_BATCHES + 1)]
    fields += ["measured_total_ms", "complete_total_ms", "wall_s"]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for run_id, source in enumerate(rows):
            batch_ms = source.get("batch_ms") or []
            expected = source["batches"]
            complete = len(batch_ms) == expected
            row = {
                "run_id": run_id,
                "group": source["group"],
                "dataset": source["dataset"],
                "update_k": source["k"],
                "system": source["side"],
                "cache_gb": source["cache"],
                "ordered_mode": source["road"],
                "maintenance_mode": source["large"],
                "repeat": source["repeat"],
                "expected_batches": expected,
                "measured_batches": len(batch_ms),
                "timing_complete": int(complete),
                "status": source["status"],
                "returncode": value_or_null(source.get("returncode")),
                "measured_total_ms": sum(batch_ms) if batch_ms else NULL,
                "complete_total_ms": sum(batch_ms) if complete else NULL,
                "wall_s": value_or_null(source.get("wall_s")),
            }
            for batch in range(1, MAX_BATCHES + 1):
                row[f"batch_{batch}_ms"] = (
                    batch_ms[batch - 1] if batch <= len(batch_ms) else NULL
                )
            writer.writerow(row)


if __name__ == "__main__":
    main()
