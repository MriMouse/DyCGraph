#!/usr/bin/env python3
"""Run a bounded background profile and summarize non-overlapping batch timers."""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import traceback

from analyze_current_substages import parse as parse_substages

ROOT = Path(__file__).resolve().parents[1]
STAGES = ('deletion', 'add', 'hotness', 'candidate', 'eviction', 'compact', 'cache_load', 'residual')
EXPECTED = {'twitter': '12687655862474487153', 'friendster': '12734023534853680802'}


def fields(line):
    return {k: float(v) for k, v in re.findall(r'\b([a-z_]+)=([0-9.]+)', line)}


def summarize(run_dir):
    rows = []
    work = []
    for log in sorted(run_dir.glob('r*_*.log')):
        dataset = log.stem.split('_', 1)[1]
        lines = log.read_text(errors='replace').splitlines()
        attrs = [fields(x) for x in lines if '[P0-ATTR][SSSP]' in x]
        timers = [float(x.split('total_batch:')[1].split()[0]) for x in lines if '[P0-TIMER][SSSP]' in x]
        checksums = re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', '\n'.join(lines))
        if len(attrs) != 10 or len(timers) != 10 or checksums != [EXPECTED[dataset]]:
            raise RuntimeError(f'{log.name}: incomplete run or distance checksum mismatch')
        if sum('[C3-PUBLISH]' in x for x in lines) != 10:
            raise RuntimeError(f'{log.name}: publication count mismatch')
        if any('I12-TRANSACTION' in x for x in lines):
            raise RuntimeError(f'{log.name}: wrong execution path')
        for i, (attr, timer) in enumerate(zip(attrs, timers)):
            if abs(sum(attr[k] for k in STAGES) - timer) > max(0.02, timer * 0.02):
                raise RuntimeError(f'{log.name}: timer mismatch at batch {i}')
            rows.append({'run': log.stem, 'dataset': dataset, 'batch': i, 'total': timer,
                         **{k: attr[k] for k in STAGES}})
        for line in lines:
            if '[B2-GPU-REPAIR]' in line and 'closure_ms=' in line:
                f = fields(line)
                work.append({'run': log.stem, **f})
    if not rows:
        return
    with (run_dir / 'batches.csv').open('w') as out:
        writer = csv.DictWriter(out, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (run_dir / 'repair_work.json').write_text(json.dumps(work, indent=2))
    substages = {log.stem: parse_substages(log) for log in sorted(run_dir.glob('r*_*.log'))}
    means = {}
    for ds in EXPECTED:
        selected = [values for name, values in substages.items() if name.endswith('_' + ds)]
        if selected:
            means[ds] = {key: sum(v[key] for v in selected) / len(selected)
                         for key in selected[0]}
    (run_dir / 'substages.json').write_text(json.dumps({'runs': substages, 'means': means}, indent=2))
    report = ['# Current Runtime Profile', '',
              'Development screening: check=false, ten batches per run; loading and correctness checks excluded.',
              'Substage repair/mutation timers overlap parent stages and must not be added to stage percentages.', '',
              '| Dataset | Runs | Mean batch ms | Run mean range ms | Dominant stages |',
              '|---|---:|---:|---|---|']
    for ds in EXPECTED:
        subset = [r for r in rows if r['dataset'] == ds]
        if not subset:
            continue
        total = sum(r['total'] for r in subset)
        means = [sum(r['total'] for r in subset if r['run'] == name) / 10
                 for name in sorted({r['run'] for r in subset})]
        shares = sorted(((k, 100 * sum(r[k] for r in subset) / total) for k in STAGES),
                        key=lambda x: -x[1])
        report.append(f'| {ds} | {len(means)} | {total / len(subset):.3f} | '
                      f'{min(means):.3f}--{max(means):.3f} | ' +
                      ', '.join(f'{k} {v:.1f}%' for k, v in shares[:4]) + ' |')
        report += ['', f'## {ds}', '', '| Stage | Mean ms/batch | Percent |', '|---|---:|---:|']
        for k, percent in shares:
            report.append(f'| {k} | {sum(r[k] for r in subset)/len(subset):.3f} | {percent:.2f}% |')
        report += ['', 'Per-batch evolution: see batches.csv; do not infer steady-state cache behavior from the first two batches.', '']
    report += ['## Iteration Decision Inputs', '',
               'Prioritize removal of whole-graph work only after checking the ten-batch stage shares.',
               'Hotness/candidate work requires complete traversal and window-expiry events, not topology-touched sources alone.',
               'A large deletion share is not evidence of expensive GPU closure: inspect repair_work.json and mutation subtimers first.',
               'Road-mode and GPU frontier repair remain algorithm candidates; this TW/FS run does not measure Europe or prove a CPU advantage.',
               'If cache dominates Friendster, first separate actual resident churn from relocation-driven rebuilding; do not restart the rejected extent allocator.',
               'No runtime selector, external baseline, or paper-level repetition is required by this screening.', '']
    (run_dir / 'summary.md').write_text('\n'.join(report))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('run_dir', type=Path)
    parser.add_argument('--gpu', default='0')
    parser.add_argument('--binary', type=Path, default=ROOT / 'build/hybrid_sssp')
    parser.add_argument('--summarize-only', action='store_true')
    args = parser.parse_args()
    run_dir = args.run_dir.resolve()
    if args.summarize_only:
        summarize(run_dir)
        return
    run_dir.mkdir(parents=True, exist_ok=True)
    status = run_dir / 'status.json'
    try:
        binary = run_dir / 'hybrid_sssp'
        import shutil
        if args.binary.resolve() != binary:
            shutil.copy2(args.binary, binary)
        manifest = {'gpu': args.gpu, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                    'batches': 10, 'repeats': 2, 'check': False, 'workers': 20,
                    'updates_per_batch': {'twitter': 20000, 'friendster': 100000}, 'commands': []}
        data = Path('/home/wangshaoyan/proJect/CG/Grapin-CG/data')
        for repeat in (1, 2):
            for ds, stem in [('twitter', 'twitter_100k'), ('friendster', 'friendster_50p_100k')]:
                gpu = subprocess.check_output(['nvidia-smi', '-i', args.gpu, '--query-gpu=memory.used,utilization.gpu', '--format=csv,noheader,nounits'], text=True)
                memory, utilization = map(int, gpu.strip().split(','))
                if memory > 64 or utilization > 5:
                    raise RuntimeError(f'GPU {args.gpu} is busy; stop before starting another run')
                name = f'r{repeat}_{ds}'
                manifest.setdefault('inputs', {})[ds] = {
                    str(path): {'bytes': path.stat().st_size, 'mtime_ns': path.stat().st_mtime_ns}
                    for path in (data / f'input_{stem}.txt', data / f'update_{stem}.txt',
                                 data / f'stream_size_{stem}.txt')}
                cmd = [str(binary), f'--graphfile={data}/input_{stem}.txt', '--format=market_big',
                       '--weight_num=1', '--weight=1', f'--updatefile={data}/update_{stem}.txt',
                       f'--update_size={data}/stream_size_{stem}.txt', '--source_node=0', '--SEGMENT=512',
                       '--n_stream=3', '--hybrid=0', '--cache=2', '--sssp_cpu_partition_capacity=0',
                       '--check=false', '--verbose=false', '--sssp_max_batches=10', '--sssp_print_checksum=true']
                manifest['commands'].append(cmd)
                (run_dir / 'manifest.json').write_text(json.dumps(manifest, indent=2))
                status.write_text(json.dumps({'state': 'running', 'run': name, 'pid': os.getpid()}))
                print(f'Starting {name}', flush=True)
                with (run_dir / f'{name}.log').open('w') as log:
                    subprocess.run(cmd, env={**os.environ, 'CUDA_VISIBLE_DEVICES': args.gpu, 'CG_MUTATION_WORKERS': '20'},
                                   stdout=log, stderr=subprocess.STDOUT, timeout=1800, check=True)
                summarize(run_dir)
                print(f'Completed {name}', flush=True)
        status.write_text(json.dumps({'state': 'complete', 'runs': 4, 'pid': os.getpid()}))
    except Exception as error:
        status.write_text(json.dumps({'state': 'failed', 'error': str(error), 'pid': os.getpid()}))
        traceback.print_exc()
        raise


if __name__ == '__main__':
    main()
