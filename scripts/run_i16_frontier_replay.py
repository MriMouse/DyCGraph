#!/usr/bin/env python3
"""Freeze and replay the two existing I16 snapshots on GPU 0 serially."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
from run_i16_road_validation import ROOT, gpu_idle, write_json


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8*1024*1024), b''):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    lock = (directory/'runner.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if (directory/'status.json').exists():
        raise SystemExit('Use a new directory; previous results preserved')
    results = {}
    def state(value, **extra):
        write_json(directory/'status.json', {'state': value, 'pid': os.getpid(), 'results': results, **extra})
    try:
        state('freezing')
        capture = ROOT/'logs/i16_e2_capture_20260907'
        reference = json.loads((capture/'correctness.json').read_text())
        binary = directory/'i16_frontier_replay'
        shutil.copy2(ROOT/'build/i16_frontier_replay', binary)
        for relative in ('src/i16_frontier_replay.cu', 'include/framework/i16_repair_snapshot.h',
                         'scripts/run_i16_frontier_replay.py', 'scripts/run_i16_road_validation.py'):
            target = directory/'sources'/relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT/relative, target)
        write_json(directory/'reference.json', reference)
        manifest = {'binary_sha256': sha(binary), 'gpu': 0, 'timeout_seconds': 7200,
                    'diagnostic_only': True, 'snapshots': {}, 'commands': {}}
        for name in ('eu50_connected_v2_s1', 'usa50_connected_v2_s1'):
            state('hashing', cohort=name)
            snapshot = capture/(name+'.snapshot.bin')
            before = snapshot.stat()
            digest = sha(snapshot)
            if digest != reference[name]['snapshot_sha256']:
                raise ValueError('Snapshot hash mismatch')
            manifest['snapshots'][name] = {'path': str(snapshot), 'sha256': digest, 'bytes': before.st_size}
            report = directory/(name+'.json')
            command = [str(binary), str(snapshot), str(report)]
            manifest['commands'][name] = command
            write_json(directory/'manifest.json', manifest)
            if not gpu_idle():
                state('blocked_resource', cohort=name)
                return 2
            now = snapshot.stat()
            if (before.st_size, before.st_mtime_ns) != (now.st_size, now.st_mtime_ns):
                raise ValueError('Snapshot changed after hashing')
            with (directory/(name+'.log')).open('w') as output:
                child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT,
                    env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0'}, start_new_session=True)
                state('running', cohort=name, child_pid=child.pid)
                try:
                    code = child.wait(timeout=7200)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait()
                    state('timeout', cohort=name)
                    return 3
            if code:
                raise ValueError(f'{name}: replay exit {code}')
            result = json.loads(report.read_text())
            baseline = reference[name]['checks']['B2-GPU-REPAIR'][0]
            if (result['state'] != 'passed' or result['distance_mismatches'] or result['invalid_parents'] or
                result['affected'] != baseline['affected'] or result['incoming'] != baseline['incoming_edges']):
                raise ValueError('Frontier correctness/state identity failed')
            result['baseline_pull_closure_ms'] = baseline['closure_ms']
            result['baseline_repair_device_bytes'] = baseline['device_bytes']
            result['reported_repair_payload_budget_passed'] = result['repair_only_device_bytes'] <= baseline['device_bytes']
            result['memory_comparison_scope'] = 'Excludes common affected IDs/distances; baseline metric omits other resident allocations, not whole-program peak'
            result['offline_service_lower'] = result['service_ms'] < baseline['closure_ms']
            result['baseline_logical_incoming_checks'] = baseline['incoming_edges']*baseline['iterations']
            results[name] = result
            write_json(directory/'results.json', results)
            print('Passed '+name, flush=True)
            time.sleep(3)
        state('completed', next_gate='Review offline service and allocation ledger before any production integration')
        return 0
    except Exception as error:
        state('failed', error=str(error))
        raise


if __name__ == '__main__':
    raise SystemExit(main())
