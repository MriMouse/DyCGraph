#!/usr/bin/env python3
"""Serial diagnostic snapshots and CPU candidate-index lower-bound screening."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import traceback

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'logs/i15_pairing_fix_20260907/validation'
EXPECTED = {'twitter': '12687655862474487153', 'friendster': '12734023534853680802'}


def idle_gpu():
    usage = subprocess.check_output(['nvidia-smi', '-i', '0',
        '--query-gpu=memory.used,utilization.gpu', '--format=csv,noheader,nounits'], text=True)
    if tuple(map(int, usage.strip().split(','))) != (0, 0):
        raise RuntimeError('GPU 0 is occupied; no workload started')
    processes = subprocess.check_output(['nvidia-smi', '-i', '0',
        '--query-compute-apps=pid', '--format=csv,noheader,nounits'], text=True)
    if processes.strip():
        raise RuntimeError('GPU 0 has a compute process; no workload started')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--binary', type=Path, required=True,
                        help='Frozen diagnostic hybrid_sssp with the archived candidate capture patch')
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    status = directory / 'status.json'
    results = {}
    try:
        if status.exists():
            raise RuntimeError('Use a fresh run directory')
        for relative in ('status.json', 'audit/status.json'):
            if json.loads((BASELINE / relative).read_text())['state'] != 'complete':
                raise RuntimeError('Corrected baseline is incomplete')
        audit = json.loads((BASELINE / 'audit/audit.json').read_text())
        for dataset in EXPECTED:
            if [row['batch'] for row in audit[dataset]] != list(range(-1, 10)):
                raise RuntimeError('Incomplete baseline audit')
            if any(row[key] for row in audit[dataset]
                   for key in ('score_id_mismatches', 'permuted_ids', 'invalid_ids')):
                raise RuntimeError('Baseline pairing audit failed')
        binaries = {}
        for name in ('hybrid_sssp', 'hotness_candidate_replay'):
            target = directory / name
            if target.exists():
                raise RuntimeError('Frozen executable already exists')
            source = args.binary if name == 'hybrid_sssp' else ROOT / 'build' / name
            shutil.copy2(source, target)
            binaries[name] = hashlib.sha256(target.read_bytes()).hexdigest()
        commands = json.loads((BASELINE / 'manifest.json').read_text())['commands'][:2]
        means = json.loads((BASELINE / 'substages.json').read_text())['means']
        manifest = {'baseline': str(BASELINE), 'binaries': binaries, 'commands': [],
                    'gpu': 0, 'workers': 20, 'diagnostic_only': True,
                    'event_source': 'full snapshot differences; excludes event capture cost'}
        for (dataset, checksum), original in zip(EXPECTED.items(), commands):
            trace = directory / f'{dataset}.bin'
            command = [str(directory / 'hybrid_sssp')] + original[1:] + [
                '--sssp_hotness_audit=true', f'--sssp_candidate_trace={trace}']
            manifest['commands'].append(command)
            (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2))
            idle_gpu()
            status.write_text(json.dumps({'state': 'capture', 'dataset': dataset, 'pid': os.getpid()}))
            print(f'Starting capture {dataset}', flush=True)
            graph_log = directory / f'{dataset}.log'
            with graph_log.open('w') as output:
                subprocess.run(command, env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0',
                    'CG_MUTATION_WORKERS': '20'}, stdout=output, stderr=subprocess.STDOUT,
                    timeout=2400, check=True)
            content = graph_log.read_text()
            if re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', content) != [checksum]:
                raise RuntimeError(f'{dataset}: distance checksum mismatch')
            if content.count('[C3-PUBLISH]') != 10:
                raise RuntimeError(f'{dataset}: publication count mismatch')
            if re.findall(r'\[I15-CANDIDATE-TRACE\] batch=(-?\d+)', content) != list(map(str, range(-1, 10))):
                raise RuntimeError(f'{dataset}: incomplete candidate trace')
            audits = [line for line in content.splitlines() if '[I15-HOTNESS-AUDIT]' in line]
            if len(audits) != 11 or any(re.search(
                    r'(score_id_mismatches|permuted_ids|invalid_ids)=[1-9]', line) for line in audits):
                raise RuntimeError(f'{dataset}: pairing failure')
            status.write_text(json.dumps({'state': 'replay', 'dataset': dataset, 'pid': os.getpid()}))
            print(f'Starting replay {dataset}', flush=True)
            replay_log = directory / f'{dataset}_replay.log'
            with replay_log.open('w') as output:
                subprocess.run([str(directory / 'hotness_candidate_replay'), str(trace)],
                    stdout=output, stderr=subprocess.STDOUT, timeout=2400, check=True)
            rows = [{key: float(value) for key, value in re.findall(r'(\w+)=(-?[\d.]+)', line)}
                    for line in replay_log.read_text().splitlines() if line.startswith('[I15-INDEX]')]
            if [row['batch'] for row in rows] != list(range(-1, 10)):
                raise RuntimeError(f'{dataset}: incomplete replay')
            update_ms = sum(row['update_ms'] + row['query_ms'] for row in rows[1:])
            budget_ms = means[dataset]['hotness_candidate_ms'] * 10
            results[dataset] = {'samples': rows, 'stream_index_ms': update_ms,
                'baseline_hotness_candidate_ms': budget_ms,
                'lower_bound_exceeds_budget': update_ms >= budget_ms,
                'trace_bytes': trace.stat().st_size,
                'note': 'Excludes capture, communication, desired output, refresh and allocator costs; not end-to-end speedup'}
            (directory / 'replay.json').write_text(json.dumps(results, indent=2))
            print(f'Completed {dataset}: index={update_ms:.3f} ms budget={budget_ms:.3f} ms', flush=True)
        status.write_text(json.dumps({'state': 'complete', 'datasets': 2, 'pid': os.getpid()}))
    except Exception as error:
        status.write_text(json.dumps({'state': 'failed', 'error': str(error), 'pid': os.getpid()}))
        traceback.print_exc()
        raise


if __name__ == '__main__':
    main()
