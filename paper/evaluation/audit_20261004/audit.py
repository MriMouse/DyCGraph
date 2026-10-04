#!/usr/bin/env python3
"""Recompute historical paper results from logs; never modify benchmark data."""
import csv
import hashlib
import json
import re
import statistics
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent
RAW = ROOT / 'paper/evaluation/raw'


def fields(line):
    return dict(re.findall(r'(\w+)=([^\s]+)', line))


def main():
    rows = []
    issues = []
    for directory in ('sssp_bfs_20260927', 'cc_pr_20260928'):
        base = RAW / directory
        for stored in csv.DictReader((base / 'runs.csv').open()):
            a, d, s, side, rep = (stored[k] for k in
                                  ('algorithm', 'dataset', 'scale', 'system', 'repeat'))
            stem = f'{a}_{d}_{s}_{side}_r{rep}'
            log = base / (stem + '.log')
            content = log.read_text(errors='replace')
            timers = re.findall(r'\[P0-TIMER\]\[' + a +
                                r'\]\[batch (\d+)\] (?:total_batch:|paper_algorithm_ms=)\s*([\d.]+)', content)
            times = [float(t) for _, t in timers]
            total = sum(times)
            if [int(b) for b, _ in timers] != list(range(10)):
                issues.append(f'{stem}: timer sequence invalid')
            if abs(total - float(stored['paper_algorithm_ms'])) > 0.00001:
                issues.append(f'{stem}: runs.csv sum differs')
            batch_path = base / (stem + '.batches.json')
            if batch_path.exists():
                batches = json.loads(batch_path.read_text())
                if [x['batch'] for x in batches] != list(range(10)) or any(
                        abs(x['paper_algorithm_ms'] - t) > 0.00001 for x, t in zip(batches, times)):
                    issues.append(f'{stem}: batches.json differs')
            else:
                issues.append(f'{stem}: batches.json missing (log still audited)')
            command = json.loads((base / (stem + '.command.json')).read_text())
            binary = command.get('binary', {})
            if binary.get('sha256') and Path(binary['path']).exists():
                actual = hashlib.sha256(Path(binary['path']).read_bytes()).hexdigest()
                if actual != binary['sha256']:
                    issues.append(f'{stem}: executable no longer matches per-run hash')
            row = dict(algorithm=a, dataset=d, scale=s, system=side, repeat=rep,
                       total_ms=total, timer_count=len(times), wall_seconds=stored['wall_seconds'],
                       status=stored['status'], log=str(log),
                       binary_sha256=binary.get('sha256', 'not_recorded_per_run'))
            attrs = [fields(x) for x in content.splitlines() if f'[P0-ATTR][{a}]' in x]
            for k in ('deletion', 'add', 'hotness', 'candidate', 'eviction', 'compact', 'cache_load', 'residual'):
                row[k + '_ms'] = sum(float(x.get(k, 0)) for x in attrs) if attrs else ''
            row['attr_total_ms'] = sum(float(x['total']) for x in attrs) if attrs else ''
            if attrs and (len(attrs) != 10 or abs(row['attr_total_ms'] - total) > 0.00001):
                issues.append(f'{stem}: P0-ATTR totals differ')
            effective = [fields(x) for x in content.splitlines() if '[C3-EFFECTIVE]' in x]
            for phase in ('delete', 'add'):
                row[phase + '_effective_records'] = sum(int(x['records']) for x in effective
                                                        if x.get('phase', '').rstrip(']') == phase)
            repair = [fields(x) for x in content.splitlines() if '[B2-GPU-REPAIR]' in x]
            row['repair_entries'] = len(repair)
            row['repair_affected_sum'] = sum(int(x['affected']) for x in repair)
            closure = [fields(x) for x in content.splitlines() if '[E4-R1-CLOSURE]' in x]
            row['insertion_closure_edges_sum'] = sum(int(x['processed_edges']) for x in closure)
            row['cache_refreshes'] = sum(int(x['refresh']) for x in
                                        (fields(x) for x in content.splitlines() if '[F1-CACHE-PUBLISH]' in x))
            row['reverse_build_ms'] = sum(map(float, re.findall(r'\[CPU-REVERSE-INDEX\].*?build_ms=([\d.]+)', content)))
            reach = re.findall(r'final_reachable=(\d+)', content)
            row['final_reachable'] = reach[-1] if reach else ''
            stops = [fields(x) for x in content.splitlines() if '[PR-BATCH]' in x]
            initial = [fields(x) for x in content.splitlines() if '[PR-CONVERGE]' in x]
            row['pr_limited_batches'] = sum(x.get('stop') == 'iteration_limit' for x in stops)
            row['pr_limited_initial'] = sum(x.get('stop') == 'iteration_limit' for x in initial)
            row['pr_rounds_sum'] = sum(int(x['rounds']) for x in stops)
            row['original_compact_ms'] = sum(map(float, re.findall(r'cache\(compact time\): ([\d.]+)', content)))
            row['original_evict_ms'] = sum(map(float, re.findall(r'缓存逐出时间 ([\d.]+)', content)))
            rows.append(row)
    performance = list(csv.DictReader((ROOT / 'paper/evaluation/data/performmance.csv').open()))
    comparisons = []
    for p in performance:
        key = tuple(p[k] for k in ('algorithm', 'dataset', 'scale'))
        group = [r for r in rows if tuple(r[k] for k in ('algorithm', 'dataset', 'scale')) == key]
        result = {k: p[k] for k in ('algorithm', 'dataset', 'scale')}
        for side in ('current', 'original'):
            g = [r for r in group if r['system'] == side]
            if sorted(r['repeat'] for r in g) != ['1', '2'] or any(r['status'] != 'ok' for r in g):
                issues.append(f'{key}/{side}: repeat identities/status invalid')
            values = [r['total_ms'] for r in g]
            mean = statistics.mean(values)
            result[side + '_ms'] = mean
            result[side + '_repeat_spread_pct'] = (max(values) - min(values)) / mean * 100
            walls = [float(r['wall_seconds']) for r in g if r['wall_seconds']]
            result[side + '_wall_mean_seconds'] = statistics.mean(walls) if len(walls) == 2 else ''
            if abs(mean - float(p[side + '_mean_total_10batch_ms'])) > 0.000051:
                issues.append(f'{key}/{side}: performance mean differs')
        result['speedup'] = result['original_ms'] / result['current_ms']
        if abs(result['speedup'] - float(p['original_over_current'])) > 0.000051:
            issues.append(f'{key}: performance ratio differs')
        if result['current_wall_mean_seconds'] and result['original_wall_mean_seconds']:
            result['wall_speedup'] = result['original_wall_mean_seconds'] / result['current_wall_mean_seconds']
        else:
            result['wall_speedup'] = ''
        comparisons.append(result)
    for name, data in [('runs_recomputed.csv', rows), ('comparisons_recomputed.csv', comparisons)]:
        with (OUT / name).open('w', newline='') as f:
            writer = csv.DictWriter(f, fieldnames=list(data[0]))
            writer.writeheader()
            writer.writerows(data)
    summary = dict(runs=len(rows), performance_rows=len(performance), timer_values=sum(r['timer_count'] for r in rows),
                   issues=issues, statuses=dict(Counter(r['status'] for r in rows)),
                   pr_limited_batches={side: sum(r['pr_limited_batches'] for r in rows if r['system'] == side)
                                       for side in ('current', 'original')},
                   pr_limited_initial={side: sum(r['pr_limited_initial'] for r in rows if r['system'] == side)
                                       for side in ('current', 'original')})
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
