#!/usr/bin/env python3
"""Bounded read-only hotness audit. Diagnostic times are not performance results."""
import hashlib
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import traceback

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--binary', type=Path, default=ROOT / 'build/hybrid_sssp')
    parser.add_argument('--require-paired', action='store_true')
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    status = directory / 'status.json'
    try:
        binary = directory / 'hybrid_sssp'
        if binary.exists():
            raise RuntimeError('Frozen executable already exists; use a fresh directory')
        shutil.copy2(args.binary, binary)
        baseline = json.loads((ROOT / 'logs/i14_effective_batch_20260906/manifest.json').read_text())
        manifest = {'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                    'commands': [], 'gpu': '0', 'workers': 20, 'diagnostic_only': True}
        results = {}
        for dataset, expected, original in zip(('twitter', 'friendster'),
                ('12687655862474487153', '12734023534853680802'), baseline['commands'][:2]):
            usage = subprocess.check_output(['nvidia-smi', '-i', '0',
                '--query-gpu=memory.used,utilization.gpu', '--format=csv,noheader,nounits'], text=True)
            memory, utilization = map(int, usage.strip().split(','))
            if memory > 64 or utilization > 5:
                raise RuntimeError('GPU 0 is busy')
            command = [str(binary)] + original[1:] + ['--sssp_hotness_audit=true']
            manifest['commands'].append(command)
            (directory / 'manifest.json').write_text(json.dumps(manifest, indent=2))
            status.write_text(json.dumps({'state': 'running', 'dataset': dataset, 'pid': os.getpid()}))
            print(f'Starting {dataset}', flush=True)
            path = directory / (dataset + '.log')
            with path.open('w') as log:
                subprocess.run(command, env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0',
                    'CG_MUTATION_WORKERS': '20'}, stdout=log, stderr=subprocess.STDOUT,
                    check=True, timeout=1800)
            content = path.read_text()
            if re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', content) != [expected]:
                raise RuntimeError(f'{dataset}: distance checksum mismatch')
            rows = []
            for line in content.splitlines():
                match = re.search(r'\[I15-HOTNESS-AUDIT\]\[batch (-?\d+)\]', line)
                if match:
                    rows.append({'batch': int(match[1]), **{key: float(value) for key, value in
                        re.findall(r'\b([a-z_]+)=([0-9.]+)', line)}})
            if [row['batch'] for row in rows] != list(range(-1, 10)):
                raise RuntimeError(f'{dataset}: incomplete audit sequence')
            if content.count('[C3-PUBLISH]') != 10 or any(row['invalid_ids'] for row in rows):
                raise RuntimeError(f'{dataset}: publication count or invalid ID failure')
            results[dataset] = rows
            (directory / 'audit.json').write_text(json.dumps(results, indent=2))
            if args.require_paired and any(row['score_id_mismatches'] or row['permuted_ids'] for row in rows):
                raise RuntimeError(f'{dataset}: score/ID pairing regression')
            print(f'Completed {dataset}', flush=True)
        status.write_text(json.dumps({'state': 'complete', 'datasets': 2, 'pid': os.getpid()}))
    except Exception as error:
        status.write_text(json.dumps({'state': 'failed', 'error': str(error), 'pid': os.getpid()}))
        traceback.print_exc()
        raise


if __name__ == '__main__':
    main()
