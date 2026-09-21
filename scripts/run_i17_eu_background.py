#!/usr/bin/env python3
"""Bounded EU cost probe with atomic status and automatic bottleneck summary."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]

def now():
    return datetime.now(timezone.utc).isoformat()

def save(path, obj):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + '\n')
    temporary.replace(path)

def fields(content, tag):
    return [dict((k, float(v)) for k, v in re.findall(r'(\w+)=([\d.]+)', line))
            for line in content.splitlines() if f'[{tag}]' in line]

def summarize(path):
    result = json.loads((path / 'summary.json').read_text())
    content = (path / 'run.log').read_text()
    repair = fields(content, 'B2-GPU-REPAIR')
    insertion = fields(content, 'E4-R1-CLOSURE')
    attrs = fields(content, 'P0-ATTR')
    total = sum(result['paper_ms'])
    result.update(paper_total_ms=total, reverse_total_ms=sum(result['reverse_ms']),
                  deletion_repair=repair, insertion_work=insertion,
                  stages_ms={key: sum(row.get(key, 0) for row in attrs)
                             for key in ('deletion', 'add', 'hotness', 'candidate', 'eviction', 'compact', 'cache_load')})
    result['repair_closure_ms'] = sum(row.get('closure_ms', 0) for row in repair)
    result['materialize_ms'] = sum(row.get('topology_ms', 0) for row in repair)
    result['repair_fraction'] = result['repair_closure_ms'] / total if total else None
    result['insertion_fraction'] = result['stages_ms']['add'] / total if total else None
    result['distance_checksums'] = re.findall(r'distance_checksum=(\d+)', '\n'.join(result['checks']))
    rss = re.search(r'Maximum resident set size \(kbytes\): (\d+)', (path / 'time.log').read_text())
    result['max_rss_KiB'] = int(rss.group(1)) if rss else None
    return result

def write_report(root, results, comparisons):
    lines = ['# EU 定向性能结果', '', '每项仅两批、check=false；不做稳定性重复，checksum 不代替完整 correctness。', '',
             '| run | paper s | reverse s | deletion closure s | insertion stage s | materialize s |',
             '|---|---:|---:|---:|---:|---:|']
    for name, r in results.items():
        lines.append(f"| {name} | {r['paper_total_ms']/1000:.3f} | {r['reverse_total_ms']/1000:.3f} | {r['repair_closure_ms']/1000:.3f} | {r['stages_ms']['add']/1000:.3f} | {r['materialize_ms']/1000:.3f} |")
    for size, row in comparisons.items():
        lines += ['', f"{size}: 64/1 分片 paper 变化 {row['paper_change_percent']:+.2f}%；distance checksum 相同：{row['checksum_match']}。"]
    lines += ['', '详细传播轮数、处理边数、RSS、原始分项见 results.json；历史十批单列于 historical.json，不与本轮两批混算。']
    (root / 'report.md').write_text('\n'.join(lines) + '\n')

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    root = args.output.resolve()
    plan = json.loads((root / 'plan.json').read_text())
    status = dict(state='running', pid=os.getpid(), started_utc=now(), updated_utc=now(),
                  completed=[], active=None, total_runs=len(plan['runs']))
    results, comparisons, child = {}, {}, None
    def interrupted(signum, frame):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    try:
        for run in plan['runs']:
            name = run['name']
            path = root / name
            command = ['python3', plan['probe_script'],
                       '--binary', plan['binary'], '--output', str(path),
                       '--manifest', str(root / run['manifest']), '--batches', '2',
                       '--shards', str(run['shards']), '--timeout', '7200']
            start = time.monotonic()
            status.update(active=name, active_log=str(path / 'run.log'), active_elapsed_seconds=0,
                          completed_batches_in_active=0, updated_utc=now())
            save(root / 'status.json', status)
            with (root / (name + '.driver.log')).open('w') as output:
                child = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                         start_new_session=True)
                status['child_pid'] = child.pid
                while True:
                    rc = child.poll()
                    log = path / 'run.log'
                    content = log.read_text(errors='replace') if log.exists() else ''
                    status.update(updated_utc=now(), active_elapsed_seconds=round(time.monotonic()-start, 1),
                                  completed_batches_in_active=len(re.findall(r'\[P0-TIMER\]', content)),
                                  last_log_line=content.splitlines()[-1] if content else 'Loading / initialization; no log output yet')
                    save(root / 'status.json', status)
                    if rc is not None:
                        break
                    time.sleep(10)
            if rc:
                raise RuntimeError(f'{name} exited {rc}; see {name}.driver.log and {name}/run.log')
            results[name] = summarize(path)
            status['completed'].append(name)
            for size in ('100k', '1000k'):
                a, b = f'eu_{size}_s1', f'eu_{size}_s64'
                if a in results and b in results:
                    comparisons[size] = dict(paper_change_percent=(results[b]['paper_total_ms']/results[a]['paper_total_ms']-1)*100,
                                             checksum_match=bool(results[a]['distance_checksums']) and results[a]['distance_checksums']==results[b]['distance_checksums'])
            save(root / 'results.json', dict(runs=results, comparisons=comparisons))
            write_report(root, results, comparisons)
            if any(not row['checksum_match'] for row in comparisons.values()):
                raise RuntimeError('Distance checksum differs between shard modes; inspect results.json')
        status.update(state='completed', active=None, child_pid=None, finished_utc=now())
    except BaseException as error:
        if child is not None and child.poll() is None:
            child.send_signal(signal.SIGINT)  # probe kills its own GPU process group
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        status.update(state='cancelled' if isinstance(error, KeyboardInterrupt) else 'failed',
                      error=str(error) or type(error).__name__, finished_utc=now())
    finally:
        status['updated_utc'] = now()
        save(root / 'status.json', status)
    return 0 if status['state'] == 'completed' else 1

if __name__ == '__main__':
    raise SystemExit(main())
