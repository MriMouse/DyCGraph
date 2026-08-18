#!/usr/bin/env python3
"""Analyze E0-B source-owned propagation traces without changing runtime state."""

import argparse
import bisect
import collections
import csv
import math


def parse_trace(path):
    rounds = {}
    segments = None
    region_ends = []
    with open(path, "r", encoding="utf-8") as trace:
        for raw in trace:
            if raw.startswith("#"):
                for field in raw.split():
                    if field.startswith("segments="):
                        segments = int(field.split("=", 1)[1])
                continue
            fields = raw.rstrip("\n").split("\t")
            if not fields or len(fields) < 3:
                continue
            kind = fields[0]
            if kind == "V":
                region_ends.append(int(fields[3]))
                continue
            epoch, round_id = int(fields[1]), int(fields[2])
            record = rounds.setdefault(
                (epoch, round_id), {"active": [], "edges": [], "summary": None})
            if kind == "S":
                record["active"].append((int(fields[3]), int(fields[4])))
            elif kind == "E":
                record["edges"].append((int(fields[3]), int(fields[4])))
            elif kind == "R":
                record["summary"] = {
                    "active": int(fields[3]),
                    "scan": int(fields[4]),
                    "success": int(fields[5]),
                    "gpu_ms": float(fields[6]),
                    "wall_ms": float(fields[7]),
                }
    if segments is None:
        raise ValueError("trace header does not contain segment count")
    if len(region_ends) != segments:
        raise ValueError("trace does not contain a complete vertex-region map")
    return segments, region_ends, rounds


def parse_aggregates(path, segments):
    work = [0] * segments
    active = [0] * segments
    flow = collections.Counter()
    rounds = collections.defaultdict(lambda: {"events": [], "sources": set()})
    with open(path, "r", encoding="utf-8") as trace:
        for raw in trace:
            if raw.startswith("#"):
                continue
            fields = raw.rstrip("\n").split("\t")
            if len(fields) < 3:
                continue
            kind = fields[0]
            if kind == "V":
                continue
            epoch, round_id = int(fields[1]), int(fields[2])
            key = (epoch, round_id)
            if kind == "A":
                region = int(fields[3])
                active[region] += int(fields[4])
                work[region] += int(fields[5])
            elif kind == "P":
                flow[(int(fields[3]), int(fields[4]))] += int(fields[5])
            elif kind == "S":
                rounds[key]["sources"].add(int(fields[3]))
            elif kind == "E":
                rounds[key]["events"].append((int(fields[3]), int(fields[4])))
    return work, active, flow, rounds


def causal_closure_metrics(selected, region_ends, exact_rounds):
    def in_cpu(vertex):
        region = bisect.bisect_right(region_ends, vertex)
        return region < len(region_ends) and region in selected

    chain_events = 0
    maximum_depth = 0
    depth = {}
    current_epoch = None
    for (epoch, round_id) in sorted(exact_rounds):
        if epoch != current_epoch:
            depth.clear()
            current_epoch = epoch
        record = exact_rounds[(epoch, round_id)]
        next_depth = {}
        for src, dst in record["events"]:
            if not in_cpu(src) or not in_cpu(dst):
                continue
            edge_depth = depth.get(src, 0) + 1
            next_depth[dst] = max(next_depth.get(dst, 0), edge_depth)
            maximum_depth = max(maximum_depth, edge_depth)
            if depth.get(src, 0) > 0:
                chain_events += 1
        depth = next_depth
    return chain_events, maximum_depth


def choose_cpu_regions(work, flow, count):
    candidates = [region for region, value in enumerate(work) if value]
    if not candidates:
        return set()
    count = min(count, len(candidates))
    incident = [0] * len(work)
    for (src, dst), weight in flow.items():
        incident[src] += weight
        incident[dst] += weight
    seeds = sorted(candidates, key=lambda r: (work[r], incident[r]), reverse=True)[:16]
    best_set, best_score = set(), -math.inf
    for seed in seeds:
        selected = {seed}
        while len(selected) < count:
            best_region, best_gain = None, -math.inf
            for region in candidates:
                if region in selected:
                    continue
                internal_gain = sum(
                    flow[(region, other)] + flow[(other, region)]
                    for other in selected)
                boundary_gain = incident[region] - 2 * internal_gain
                work_term = math.log1p(work[region])
                gain = 4.0 * internal_gain - boundary_gain + work_term
                if gain > best_gain:
                    best_region, best_gain = region, gain
            selected.add(best_region)
        internal = sum(
            weight for (src, dst), weight in flow.items()
            if src in selected and dst in selected)
        boundary = sum(
            weight for (src, dst), weight in flow.items()
            if (src in selected) != (dst in selected))
        selected_work = sum(work[r] for r in selected)
        score = 4.0 * internal - boundary + math.log1p(selected_work)
        if score > best_score:
            best_set, best_score = selected, score
    return best_set


def evaluate(selected, work, flow, total_gpu_ms):
    total_work = sum(work)
    cpu_work = sum(work[r] for r in selected)
    internal = g2c = c2g = 0
    for (src, dst), weight in flow.items():
        src_cpu, dst_cpu = src in selected, dst in selected
        if src_cpu and dst_cpu:
            internal += weight
        elif not src_cpu and dst_cpu:
            g2c += weight
        elif src_cpu and not dst_cpu:
            c2g += weight
    boundary = g2c + c2g
    return {
        "cpu_regions": len(selected),
        "cpu_scan_edges": cpu_work,
        "cpu_scan_share": cpu_work / total_work if total_work else 0.0,
        "internal_success": internal,
        "gpu_to_cpu_success": g2c,
        "cpu_to_gpu_success": c2g,
        "boundary_per_internal": boundary / internal if internal else math.inf,
        "edge_proportional_removed_gpu_ms": (
            total_gpu_ms * cpu_work / total_work if total_work else 0.0),
        "regions": ",".join(str(value) for value in sorted(selected)),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace")
    parser.add_argument("--capacities", default="8,16,32,64")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    segments, region_ends, rounds = parse_trace(args.trace)
    work, active, flow, exact_rounds = parse_aggregates(args.trace, segments)
    total_gpu_ms = sum(
        record["summary"]["gpu_ms"]
        for record in rounds.values() if record["summary"])
    total_success = sum(flow.values())
    diagonal_success = sum(flow[(region, region)] for region in range(segments))
    rows = []
    for capacity in [int(value) for value in args.capacities.split(",")]:
        selected = choose_cpu_regions(work, flow, capacity)
        row = evaluate(selected, work, flow, total_gpu_ms)
        chain_events, maximum_depth = causal_closure_metrics(
            selected, region_ends, exact_rounds)
        row.update({
            "segments": segments,
            "rounds": len(rounds),
            "total_scan_edges": sum(work),
            "total_success": total_success,
            "base_diagonal_success_share": (
                diagonal_success / total_success if total_success else 0.0),
            "total_gpu_service_ms": total_gpu_ms,
            "internal_chain_events": chain_events,
            "maximum_local_chain_depth": maximum_depth,
        })
        rows.append(row)

    fieldnames = [
        "segments", "rounds", "total_scan_edges", "total_success",
        "base_diagonal_success_share", "total_gpu_service_ms", "cpu_regions",
        "cpu_scan_edges", "cpu_scan_share", "internal_success",
        "gpu_to_cpu_success", "cpu_to_gpu_success", "boundary_per_internal",
        "edge_proportional_removed_gpu_ms", "regions",
        "internal_chain_events", "maximum_local_chain_depth",
    ]
    with open(args.output, "w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
