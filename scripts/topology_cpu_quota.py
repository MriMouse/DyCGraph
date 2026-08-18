#!/usr/bin/env python3
"""Choose CPU source shards from static topology, then evaluate with E0-B."""

import argparse
import bisect
import collections
import csv
import array

import analyze_e0b_trace


def scan_topology(path, region_ends):
    edge_volume = [0] * len(region_ends)
    flow = collections.Counter()
    with open(path, "r", encoding="utf-8") as graph:
        for line_number, raw in enumerate(graph, 1):
            fields = raw.split()
            if not fields or fields[0].startswith("%"):
                continue
            if len(fields) < 2:
                raise ValueError(f"{path}:{line_number}: expected source destination")
            src, dst = int(fields[0]), int(fields[1])
            src_region = bisect.bisect_right(region_ends, src)
            dst_region = bisect.bisect_right(region_ends, dst)
            if src_region >= len(region_ends) or dst_region >= len(region_ends):
                raise ValueError(f"{path}:{line_number}: vertex outside trace region map")
            edge_volume[src_region] += 1
            flow[(src_region, dst_region)] += 1
    return edge_volume, flow


def read_topology_counts(path, segments):
    edge_volume = [0] * segments
    flow = collections.Counter()
    with open(path, "r", encoding="utf-8") as counts:
        for raw in counts:
            fields = raw.split()
            if fields[0] == "E":
                edge_volume[int(fields[1])] = int(fields[2])
            elif fields[0] == "F":
                flow[(int(fields[1]), int(fields[2]))] = int(fields[3])
    return edge_volume, flow


def read_vertex_regions(path):
    mapping = array.array("H")
    with open(path, "rb") as source:
        size = source.seek(0, 2)
        source.seek(0)
        mapping.fromfile(source, size // mapping.itemsize)
    return mapping


def replay_with_mapping(path, mapping, segments):
    work = [0] * segments
    flow = collections.Counter()
    rounds = collections.defaultdict(lambda: {"events": []})
    total_gpu_ms = 0.0
    with open(path, "r", encoding="utf-8") as trace:
        for raw in trace:
            fields = raw.rstrip("\n").split("\t")
            if not fields or fields[0].startswith("#") or fields[0] == "V":
                continue
            kind = fields[0]
            epoch, round_id = int(fields[1]), int(fields[2])
            if kind == "S":
                work[mapping[int(fields[3])]] += int(fields[4])
            elif kind == "E":
                src, dst = int(fields[3]), int(fields[4])
                sr, dr = mapping[src], mapping[dst]
                flow[(sr, dr)] += 1
                rounds[(epoch, round_id)]["events"].append((src, dst))
            elif kind == "R":
                total_gpu_ms += float(fields[6])
    return work, flow, rounds, total_gpu_ms


def causal_metrics_with_mapping(selected, mapping, exact_rounds):
    chain_events = maximum_depth = 0
    depth = {}
    current_epoch = None
    for (epoch, round_id) in sorted(exact_rounds):
        if epoch != current_epoch:
            depth.clear()
            current_epoch = epoch
        next_depth = {}
        for src, dst in exact_rounds[(epoch, round_id)]["events"]:
            if mapping[src] not in selected or mapping[dst] not in selected:
                continue
            edge_depth = depth.get(src, 0) + 1
            next_depth[dst] = max(next_depth.get(dst, 0), edge_depth)
            maximum_depth = max(maximum_depth, edge_depth)
            if depth.get(src, 0):
                chain_events += 1
        depth = next_depth
    return chain_events, maximum_depth


def grow_low_boundary_set(edge_volume, flow, target_share):
    """Grow a connected CPU domain until its source-edge quota is reached."""
    total_edges = sum(edge_volume)
    target_edges = max(1, int(total_edges * target_share))
    incident = [0] * len(edge_volume)
    neighbors = [set() for _ in edge_volume]
    for (src, dst), count in flow.items():
        if src == dst:
            continue
        incident[src] += count
        incident[dst] += count
        neighbors[src].add(dst)
        neighbors[dst].add(src)

    candidates = [i for i, volume in enumerate(edge_volume) if volume]
    # A topology-only seed: strongest self-locality, then larger edge volume.
    seed = min(candidates, key=lambda r: (
        incident[r] / edge_volume[r], -edge_volume[r], r))
    selected = {seed}
    selected_edges = edge_volume[seed]
    while selected_edges < target_edges and len(selected) < len(candidates):
        frontier = set().union(*(neighbors[r] for r in selected)) - selected
        pool = frontier or (set(candidates) - selected)

        def marginal(region):
            to_selected = sum(
                flow[(region, other)] + flow[(other, region)]
                for other in selected)
            boundary_delta = incident[region] - 2 * to_selected
            return (boundary_delta / edge_volume[region],
                    abs(target_edges - selected_edges - edge_volume[region]),
                    region)

        chosen = min(pool, key=marginal)
        selected.add(chosen)
        selected_edges += edge_volume[chosen]
    return selected


def topology_metrics(selected, edge_volume, flow):
    internal = boundary = 0
    for (src, dst), count in flow.items():
        src_cpu, dst_cpu = src in selected, dst in selected
        if src_cpu and dst_cpu:
            internal += count
        elif src_cpu != dst_cpu:
            boundary += count
    cpu_edges = sum(edge_volume[r] for r in selected)
    return {
        "static_cpu_edges": cpu_edges,
        "static_cpu_share": cpu_edges / sum(edge_volume),
        "static_internal_edges": internal,
        "static_boundary_edges": boundary,
        "static_boundary_per_internal": boundary / internal if internal else float("inf"),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--graph", required=True)
    parser.add_argument("--topology-counts")
    parser.add_argument("--vertex-region-map")
    parser.add_argument("--trace", required=True)
    parser.add_argument("--cpu-shares", default="0.05,0.10,0.15,0.20")
    parser.add_argument("--selected-regions")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    segments, region_ends, trace_rounds = analyze_e0b_trace.parse_trace(args.trace)
    mapping = None
    if args.vertex_region_map:
        mapping = read_vertex_regions(args.vertex_region_map)
        work, successful_flow, exact_rounds, total_gpu_ms = replay_with_mapping(
            args.trace, mapping, segments)
    else:
        work, _, successful_flow, exact_rounds = analyze_e0b_trace.parse_aggregates(
            args.trace, segments)
        total_gpu_ms = sum(
            record["summary"]["gpu_ms"] for record in trace_rounds.values()
            if record["summary"])
    if args.topology_counts:
        edge_volume, topology_flow = read_topology_counts(
            args.topology_counts, segments)
    else:
        edge_volume, topology_flow = scan_topology(args.graph, region_ends)

    rows = []
    for share in (float(value) for value in args.cpu_shares.split(",")):
        if args.selected_regions:
            selected = {int(value) for value in args.selected_regions.split(",")}
        else:
            selected = grow_low_boundary_set(edge_volume, topology_flow, share)
        row = {"target_cpu_share": share}
        row.update(topology_metrics(selected, edge_volume, topology_flow))
        row.update(analyze_e0b_trace.evaluate(
            selected, work, successful_flow, total_gpu_ms))
        if mapping is None:
            chains, depth = analyze_e0b_trace.causal_closure_metrics(
                selected, region_ends, exact_rounds)
        else:
            chains, depth = causal_metrics_with_mapping(
                selected, mapping, exact_rounds)
        row["internal_chain_events"] = chains
        row["maximum_local_chain_depth"] = depth
        rows.append(row)

    with open(args.output, "w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]), delimiter="\t")
        writer.writeheader()
        writer.writerows(rows)


if __name__ == "__main__":
    main()
