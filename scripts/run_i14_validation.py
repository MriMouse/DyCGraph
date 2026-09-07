#!/usr/bin/env python3
"""Serial correctness gate followed by the existing ten-batch profile runner."""
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
BASELINE = ROOT / 'logs/i14_host_attribution_20260906'
CHECKSUMS = {'twitter': '10309345756053454404', 'friendster': '1221435124879239400'}


def validate(log, dataset):
    content = log.read_text()
    for tag in ('SSSP-DELETE-STAGE-CHECK', 'SSSP-BATCH-CHECK'):
        checks = re.findall(r'\[' + tag + r'\]\[batch (\d+)\] passed[^\n]*distance_checksum=(\d+)', content)
        reference = (ROOT / f'logs/i13_cleanup_20260906/current_{dataset}_true.log').read_text()
        expected = re.findall(r'\[' + tag + r'\]\[batch (\d+)\] passed[^\n]*distance_checksum=(\d+)', reference)[:2]
        if len(checks) != 2 or checks != expected:
            raise RuntimeError(f'{log}: {tag} mismatch: {checks} vs {expected}')
    if re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', content) != [CHECKSUMS[dataset]]:
        raise RuntimeError(f'{log}: final checksum mismatch')
    for tag in ('C3-PUBLISH', 'TOPOLOGY-AUDIT', 'I14-BATCH'):
        if content.count('[' + tag + ']') != 2:
            raise RuntimeError(f'{log}: wrong {tag} count')
    if (re.search(r'(gpu_cpu_hash_mismatches|stale_version_rejects|mismatched_sources)=[1-9]', content)
            or 'protocol_error=' in content or 'I12-TRANSACTION' in content):
        raise RuntimeError(f'{log}: topology protocol failure')
    if '[SSSP-BELLMAN-CHECK] passed' not in content or 'Overall: Test passed' not in content:
        raise RuntimeError(f'{log}: missing full checker success')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('run_dir', type=Path)
    parser.add_argument('--gpu', default='0')
    args = parser.parse_args()
    run_dir = args.run_dir.resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    status = run_dir / 'status.json'
    try:
        binary = run_dir / 'hybrid_sssp'
        if binary.exists():
            raise RuntimeError('Use a fresh run directory; frozen binary already exists')
        shutil.copy2(ROOT / 'build/hybrid_sssp', binary)
        manifest = {'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                    'baseline': str(BASELINE), 'gpu': args.gpu, 'workers': 20,
                    'correctness_batches': 2, 'commands': []}
        baseline = json.loads((BASELINE / 'manifest.json').read_text())
        for dataset, original in zip(CHECKSUMS, baseline['commands'][:2]):
            usage = subprocess.check_output(['nvidia-smi', '-i', args.gpu,
                '--query-gpu=memory.used,utilization.gpu', '--format=csv,noheader,nounits'], text=True)
            memory, utilization = map(int, usage.strip().split(','))
            if memory > 64 or utilization > 5:
                raise RuntimeError(f'GPU {args.gpu} is busy')
            cmd = [str(binary)] + [arg.replace('--check=false', '--check=true').replace(
                '--sssp_max_batches=10', '--sssp_max_batches=2') for arg in original[1:]]
            cmd.append('--topology_replay_audit=true')
            manifest['commands'].append(cmd)
            (run_dir / 'correctness_manifest.json').write_text(json.dumps(manifest, indent=2))
            status.write_text(json.dumps({'state': 'correctness', 'run': dataset, 'pid': os.getpid()}))
            print(f'Starting correctness {dataset}', flush=True)
            path = run_dir / f'check_{dataset}.log'
            with path.open('w') as log:
                subprocess.run(cmd, env={**os.environ, 'CUDA_VISIBLE_DEVICES': args.gpu,
                    'CG_MUTATION_WORKERS': '20'}, stdout=log, stderr=subprocess.STDOUT,
                    timeout=1800, check=True)
            validate(path, dataset)
            print(f'Passed correctness {dataset}', flush=True)
        (run_dir / 'correctness_status.json').write_text(json.dumps({'state': 'passed',
            'datasets': list(CHECKSUMS), 'batches_each': 2,
            'contract': 'distance, tight witnesses and topology; not stored parent tree validity'}))
        subprocess.run(['python3', str(ROOT / 'scripts/profile_current_runtime.py'),
                        str(run_dir), '--gpu', args.gpu, '--binary', str(binary)], check=True)
    except Exception as error:
        status.write_text(json.dumps({'state': 'failed', 'error': str(error), 'pid': os.getpid()}))
        traceback.print_exc()
        raise


if __name__ == '__main__':
    main()
