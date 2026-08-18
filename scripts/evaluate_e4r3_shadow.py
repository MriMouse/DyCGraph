#!/usr/bin/env python3
import argparse, csv

def calibration(path):
    rows = list(csv.DictReader(open(path), delimiter="\t"))
    return {r["metric"]: float(r["value"]) for r in rows}

def topology(path):
    edges, flow = {}, {}
    for raw in open(path):
        f = raw.split()
        if f[0] == "E": edges[int(f[1])] = int(f[2])
        elif f[0] == "F": flow[int(f[1]), int(f[2])] = int(f[3])
    return edges, flow

def cost(c, cpu, gpu, boundary, placement, dependency, delta):
    cpu_ms = cpu / c["cpu_edges_per_ms"]
    gpu_ms = gpu / c["gpu_edges_per_ms"]
    event_ms = boundary / c["boundary_events_per_ms"]
    dependency_ms = dependency / c["cpu_edges_per_ms"]
    topology_ms = delta / c["cpu_edges_per_ms"]
    placement_ms = placement * c["placement_ns_per_edge"] / 1e6
    return cpu_ms, gpu_ms, event_ms, dependency_ms, topology_ms, placement_ms, max(cpu_ms, gpu_ms)+event_ms+dependency_ms+topology_ms+placement_ms

p = argparse.ArgumentParser()
p.add_argument("--calibration", required=True)
p.add_argument("--topology", required=True)
p.add_argument("--work", required=True)
p.add_argument("--dataset", required=True)
p.add_argument("--dependency-edges", type=int, default=0)
p.add_argument("--delta-records", type=int, default=0)
p.add_argument("--max-host-edges", type=int, default=0)
p.add_argument("--output", required=True)
a = p.parse_args(); c = calibration(a.calibration); edges, flow = topology(a.topology)
work = next(csv.DictReader(open(a.work), delimiter="\t"))
static_total = sum(edges.values()); static_cpu = edges.get(0, 0)
cpu = int(work["cpu_scan_edges"])
exact_total = round(cpu / float(work["cpu_scan_share"]))
gpu = exact_total - cpu
boundary = int(work["gpu_to_cpu_success"]) + int(work["cpu_to_gpu_success"])
plans = [
    ("all_gpu", 0, exact_total, 0, 0),
    ("edge_cut", cpu, gpu, boundary, 0),
    ("placement_only", cpu, gpu, 0, cpu),
    ("full", cpu, gpu, boundary, cpu),
]
rows = []
with open(a.output,"w",newline="") as out:
    w=csv.writer(out,delimiter="\t"); w.writerow(["dataset","plan","cpu_edges","gpu_edges","boundary_events","cpu_ms","gpu_ms","event_ms","dependency_ms","topology_ms","placement_ms","total_ms"])
    for name,ce,ge,be,pe in plans:
        dep = a.dependency_edges if name in ("all_gpu","full") else 0
        delta = a.delta_records if name in ("all_gpu","full") else 0
        values = cost(c,ce,ge,be,pe,dep,delta)
        eligible = name == "all_gpu" or not a.max_host_edges or static_cpu <= a.max_host_edges
        total_cost = values[-1] if eligible else float("inf")
        rows.append((name, eligible, total_cost))
        w.writerow([a.dataset,name,ce,ge,be,*[f"{x:.6f}" for x in values]])
winner = min((row for row in rows if row[0] in ("all_gpu", "full")),
             key=lambda row: row[2])
with open(a.output + ".decision", "w") as out:
    out.write(f"dataset\twinner\tmemory_eligible\ttotal_ms\n{a.dataset}\t{winner[0]}\t{int(winner[1])}\t{winner[2]:.6f}\n")
