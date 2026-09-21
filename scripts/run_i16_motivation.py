#!/usr/bin/env python3
"""I16 mechanism measurements: paired cost, same-state work and repair profiling."""
import argparse
import csv
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import time

from run_i16_road_validation import ROOT, fields, gpu_idle, parse_log, validate_connected, write_json
from run_i16_paired import memory_sample, parse_performance, process_has_token, sha


def profile_stats(content):
    tables, table, header = {}, None, None
    for row in csv.reader(content.splitlines()):
        if row and row[0].startswith('Processing ['):
            table = next((name for name in ('cuda_api_sum', 'cuda_gpu_kern_sum', 'cuda_gpu_mem_time_sum')
                          if name+'.py' in row[0]), None)
            header = None
        elif row and row[0] == 'Time (%)':
            header = row
            if table:
                tables[table] = []
        elif table and header and len(row) == len(header):
            tables[table].append(dict(zip(header, row)))
    if any(not tables.get(name) for name in ('cuda_api_sum', 'cuda_gpu_kern_sum', 'cuda_gpu_mem_time_sum')):
        raise ValueError('Profiler report missing CUDA events')
    return {'tables': tables,
            'total_ms': {name: sum(int(row['Total Time (ns)']) for row in rows)/1e6
                         for name, rows in tables.items()},
            'scope': 'First repair only; API/kernel/copy times overlap and must not be added'}


def batch_updates(path, batches=3):
    rows = [line.split() for line in path.read_text().splitlines() if line.strip()]
    if len(rows) < batches or any(len(row) != 2 for row in rows):
        raise ValueError('Invalid batch-size file')
    values = [[int(v) for v in row] for row in rows]
    if any(v < 0 for row in values for v in row):
        raise ValueError('Negative batch size')
    return [sum(row) for row in values[:batches]]


def details(text, result):
    rows = [dict(fields(line), batch=int(re.search(r'\[batch (\d+)\]', line)[1]))
            for line in text.splitlines() if '[I16-CPU-DETAIL]' in line]
    repair = result['checks'].get('I16-CPU-REPAIR', [])
    expected = [r['batch'] for r in repair if r['affected']]
    if [r['batch'] for r in rows] != expected:
        raise ValueError('Missing or duplicate CPU cost detail')
    for row, service in zip(rows, [r for r in repair if r['affected']]):
        for key in ('nodes', 'union_vertices', 'ids_ms', 'allocation_ms', 'gather_transfer_ms',
                    'index_ms', 'boundary_ms', 'transpose_ms', 'repair_workers'):
            if key not in row or row[key] < 0:
                raise ValueError('Invalid CPU cost detail: ' + key)
        if row['repair_workers'] != 1 or row['union_vertices'] > row['nodes']:
            raise ValueError('Unexpected repair worker/state contract')
        for total, parts in ((service['gather_ms'], ('ids_ms', 'allocation_ms', 'gather_transfer_ms')),
                             (service['setup_ms'], ('index_ms', 'boundary_ms', 'transpose_ms'))):
            if abs(total-sum(row[k] for k in parts)) > max(.1, total*.02):
                raise ValueError('CPU timer decomposition mismatch')
    result['cpu_detail'] = rows
    return result


def compare_stages(a, b):
    for tag in ('SSSP-DELETE-STAGE-CHECK', 'SSSP-BATCH-CHECK'):
        if [r['distance_checksum'] for r in a['checks'][tag]] != [r['distance_checksum'] for r in b['checks'][tag]]:
            raise ValueError('CPU/GPU incremental stage distance mismatch: ' + tag)


def summarize(results, cohort, blocks):
    ratios, cpu, gpu = [], [], []
    for block in range(blocks):
        runs = [results[f'{cohort}.p{block}.{i}'] for i in range(4)]
        ratios += [runs[1]['sum_batch_ms']/runs[0]['sum_batch_ms'],
                   runs[2]['sum_batch_ms']/runs[3]['sum_batch_ms']]
        gpu += [runs[0], runs[3]]
        cpu += runs[1:3]
    cr = [r for run in cpu for r in run['checks']['I16-CPU-REPAIR'] if r['affected']]
    gr = [r for run in gpu for r in run['checks']['B2-GPU-REPAIR'] if r['affected']]
    mean = lambda key: statistics.mean(r.get(key, 0) for r in cr) if cr else 0
    service = mean('service_ms')
    pq_fraction = mean('closure_ms')/service if service else 0
    cpu_total = sum(r['sum_batch_ms'] for r in cpu)
    pq_batch_fraction = sum(r.get('closure_ms', 0) for r in cr)/cpu_total if cpu_total else 0
    fractions = [repair['affected']/detail['nodes']
                 for run in cpu for repair, detail in zip(
                     [r for r in run['checks']['I16-CPU-REPAIR'] if r['affected']], run['cpu_detail'])]
    return {'cpu_over_gpu_pairs': ratios, 'median_pair_ratio': statistics.median(ratios),
            'all_pairs_cpu_faster': all(r < 1 for r in ratios),
            'cpu_service_mean_ms': service, 'pq_service_fraction': pq_fraction,
            'affected_over_allocated_nodes': fractions,
            'preparation_service_fraction': (mean('gather_ms')+mean('setup_ms'))/service if service else 0,
            'pq_batch_fraction': pq_batch_fraction,
            'ideal_20way_pq_batch_speedup_bound': 1/(1-pq_batch_fraction+pq_batch_fraction/20),
            'cpu_internal_scans_per_internal_edge': mean('internal_scans')/mean('internal_edges') if mean('internal_edges') else None,
            'cpu_stale_per_push': mean('stale_pops')/mean('pq_pushes') if mean('pq_pushes') else None,
            'gpu_pull_iterations': [r['iterations'] for r in gr],
            'gpu_pull_logical_checks': [r['incoming_edges']*r['iterations'] for r in gr],
            'cpu_detail': [r for run in cpu for r in run['cpu_detail']],
            'cpu_memory': [{key: r.get(key) for key in ('max_rss_kib', 'sampled_gpu_peak_mib')} for r in cpu],
            'gpu_memory': [{key: r.get(key) for key in ('max_rss_kib', 'sampled_gpu_peak_mib')} for r in gpu],
            'optimization_decision': 'Profile/optimize preparation first' if pq_fraction < .5 else 'Evaluate integer priority queue before parallel solver',
            'worker_decision': 'Dedicated worker alone has no overlap benefit; bound assumes perfect PQ parallelism, not measured scaling',
            'scope': 'Full mixed batch excludes graph loading/checking; CPU repair is affected-only, temporary index is O(V)'}


def cohorts(smoke, directory):
    if smoke:
        root = directory/'fixture'
        root.mkdir()
        graph, update, sizes = [root/(s+'.txt') for s in ('graph', 'updates', 'sizes')]
        edges = sorted({(u, (u+1) % 2048) for u in range(2048)} |
                       {((u+1) % 2048, u) for u in range(2048)})
        graph.write_text(''.join(f'{u} {v}\n' for u, v in edges))
        forward = 'd 0 1 1\nd 1 0 1\na 0 2 1\na 2 0 1\n'
        reverse = 'd 0 2 1\nd 2 0 1\na 0 1 1\na 1 0 1\n'
        update.write_text(''.join(forward if i % 2 == 0 else reverse for i in range(10)))
        sizes.write_text('2 2\n'*10)
        return {'smoke': (graph, update, sizes, 0, 4)}
    external = Path('/home/wangshaoyan/proJect/CG/Grapin-CG/data')
    specs = [('twitter', external, 'twitter_100k', 0),
             ('friendster', external, 'friendster_50p_100k', 0),
             ('eu', ROOT/'data/road_connected_v2/europe_osm/50p', 'europe_osm_50p_100k', 1),
             ('usa', ROOT/'data/road_connected_v2/road_usa/50p', 'road_usa_50p_100k', 1)]
    return {name: (*(root/(prefix+stem+'.txt') for prefix in ('input_', 'update_', 'stream_size_')), source, 100000)
            for name, root, stem, source in specs}


def main():
    raise SystemExit('CPU road runtime retired; historical runner/binary are archived in logs/i16_mechanism_20260908')


if __name__ == '__main__':
    main()
