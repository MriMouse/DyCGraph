#!/usr/bin/env python3
"""EU/USA ordered GPU bucket-selection ablation; no production integration."""
import argparse
import fcntl
import json
import math
import os
from pathlib import Path
import shutil
import signal
import statistics
import subprocess
import time

from run_i16_road_validation import ROOT, gpu_idle, write_json
from run_i16_paired import memory_sample, process_has_token, sha
from run_i16_motivation import profile_stats


def validate(result, reference, mode):
    if (not isinstance(result, dict) or result.get('state') != 'passed' or
        result.get('bucket_mode') != mode or result.get('delta') != 128 or
        any(result.get(key) != 0 for key in ('distance_mismatches', 'invalid_parents', 'missing_tight_parents')) or
        result.get('affected') != reference['affected'] or result.get('incoming') != reference['incoming_edges']):
        raise ValueError('Ordered replay state/algorithm contract failed')
    if abs(result['selection_ms']+result['expansion_ms']-result['closure_ms']) > max(1, result['closure_ms']*.01):
        raise ValueError('Closure timer attribution mismatch')
    if result.get('service_accounting_version') == 2:
        parts = ('setup_ms', 'allocation_context_ms', 'h2d_ms', 'closure_ms', 'd2h_ms',
                 'parent_reconstruction_ms', 'device_release_ms', 'host_release_ms')
        if any(not math.isfinite(result[k]) or result[k] < 0 for k in (*parts, 'complete_service_ms')):
            raise ValueError('Invalid service timing')
        if abs(sum(result[k] for k in parts)-result['complete_service_ms']) > max(1, result['complete_service_ms']*.01):
            raise ValueError('Complete service attribution mismatch')
        if result['enqueued_vertices'] != result['processed_vertices'] or result['queue_peak'] > result['affected']:
            raise ValueError('Queue drain/capacity contract failed')
        if mode in ('device-control', 'compact', 'reuse') and result['control_d2h_calls'] != result['iterations']:
            raise ValueError('Device control contract failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--skip-profile', action='store_true')
    parser.add_argument('--paired-directory', type=Path, help='Reuse completed same-binary pairs; run only profiling')
    parser.add_argument('--baseline', default='dense', choices=('dense', 'sparse', 'device-control', 'compact'))
    parser.add_argument('--candidate', default='sparse', choices=('sparse', 'device-control', 'compact', 'reuse'))
    args = parser.parse_args()
    gpu_lock = (ROOT/'build/i17_replay_gpu.lock').open('a')
    fcntl.flock(gpu_lock, fcntl.LOCK_EX)
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    lock = (directory/'runner.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if (directory/'status.json').exists():
        raise SystemExit('Use a new directory')
    results, analysis = {}, {}
    baseline, candidate = args.baseline, args.candidate
    if baseline == candidate:
        raise ValueError('Identical comparison modes')
    manifest = {'delta': 128, 'order': [baseline, candidate, candidate, baseline],
                'commands': {}, 'snapshots': {}, 'scope': 'offline service, not complete batch',
                'timeout_seconds': 7200}

    def state(value, **extra):
        write_json(directory/'status.json', {'state': value, 'pid': os.getpid(), 'completed_runs': list(results), **extra})

    def stop(signum, frame):
        raise KeyboardInterrupt('Signal '+str(signum))
    signal.signal(signal.SIGTERM, stop)

    def run(name, command):
        manifest['commands'][name] = command
        write_json(directory/'manifest.json', manifest)
        state('waiting_gpu', run=name)
        while not gpu_idle():
            time.sleep(5)
        token = f'{os.getpid()}:{name}:{time.monotonic_ns()}'
        child = None
        start = time.monotonic()
        samples = []
        try:
            with (directory/(name+'.log')).open('w') as output:
                child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True,
                    env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0', 'CG_I16_RUN_TOKEN': token})
                state('running', run=name, child_pid=child.pid)
                while child.poll() is None:
                    if time.monotonic()-start > 7200:
                        raise TimeoutError(name)
                    memory, foreign = memory_sample(child.pid, token)
                    samples.append({'elapsed': time.monotonic()-start, 'mib': memory})
                    if foreign:
                        raise RuntimeError('Foreign GPU process: '+str(foreign))
                    time.sleep(.5)
                if child.returncode:
                    raise RuntimeError(f'{name}: exit {child.returncode}')
        finally:
            if child and child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            for entry in Path('/proc').iterdir():
                if entry.name.isdigit() and process_has_token(int(entry.name), token):
                    try:
                        os.kill(int(entry.name), signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            write_json(directory/(name+'.memory.json'), samples)

    try:
        state('freezing')
        binary = directory/'i17a_delta_replay'
        shutil.copy2(ROOT/'build/i17a_delta_replay', binary)
        for relative in ('src/i17a_delta_replay.cu', 'include/framework/i16_repair_snapshot.h',
                         'tests/i17a_sparse_test.py',
                         'scripts/run_i17a_sparse.py', 'scripts/run_i16_motivation.py',
                         'scripts/run_i16_paired.py', 'scripts/run_i16_road_validation.py'):
            target = directory/'sources'/relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT/relative, target)
        manifest['binary_sha256'] = sha(binary)
        if args.paired_directory:
            prior = args.paired_directory.resolve()
            if json.loads((prior/'status.json').read_text())['state'] != 'completed':
                raise ValueError('Paired prerequisite incomplete')
            prior_manifest = json.loads((prior/'manifest.json').read_text())
            if prior_manifest['binary_sha256'] != manifest['binary_sha256']:
                raise ValueError('Paired binary differs')
            if prior_manifest['order'] != manifest['order']:
                raise ValueError('Paired order differs')
            results.update(json.loads((prior/'results.json').read_text()))
            manifest['paired_source'] = str(prior)
        capture = ROOT/'logs/i16_e2_capture_20260907'
        reference = json.loads((capture/'correctness.json').read_text())
        for cohort in ('eu50_connected_v2_s1', 'usa50_connected_v2_s1'):
            snapshot = capture/(cohort+'.snapshot.bin')
            state('hashing', run=cohort)
            digest = sha(snapshot)
            if digest != reference[cohort]['snapshot_sha256']:
                raise ValueError('Snapshot hash mismatch')
            stat = snapshot.stat()
            manifest['snapshots'][cohort] = {'path': str(snapshot), 'sha256': digest}
            if args.paired_directory and prior_manifest['snapshots'][cohort]['sha256'] != digest:
                raise ValueError('Paired snapshot differs')
            modes = manifest['order']+([] if args.skip_profile else [baseline, candidate])
            for index, mode in enumerate(modes):
                if args.paired_directory and index < 4:
                    continue
                profile = index >= 4
                name = f'{cohort}.{index}.{mode}'
                report = directory/(name+'.json')
                command = [str(binary), str(snapshot), str(report), mode]
                if profile:
                    command = ['nsys', 'profile', '--trace=cuda', '--sample=none', '--cpuctxsw=none',
                               '--output='+str(directory/name)]+command
                now = snapshot.stat()
                if (now.st_size, now.st_mtime_ns) != (stat.st_size, stat.st_mtime_ns):
                    raise ValueError('Snapshot changed')
                run(name, command)
                result = json.loads(report.read_text())
                validate(result, reference[cohort]['checks']['B2-GPU-REPAIR'][0], mode)
                if profile:
                    with (directory/(name+'.stats.csv')).open('w') as output:
                        subprocess.run(['nsys', 'stats', '--report=cuda_api_sum,cuda_gpu_kern_sum,cuda_gpu_mem_time_sum',
                                        '--format=csv', str(directory/(name+'.nsys-rep'))],
                                       stdout=output, stderr=subprocess.STDOUT, timeout=300, check=True)
                    result['profile'] = profile_stats((directory/(name+'.stats.csv')).read_text())
                result['diagnostic_only'] = profile
                results[name] = result
                write_json(directory/'results.json', results)
                print('Completed '+name, flush=True)
            runs = [results[f'{cohort}.{i}.{mode}'] for i, mode in enumerate(manifest['order'])]
            row = {'candidate_over_baseline_closure_pairs': [runs[1]['closure_ms']/runs[0]['closure_ms'],
                                                       runs[2]['closure_ms']/runs[3]['closure_ms']]}
            for mode in (baseline, candidate):
                matching = [r for r in runs if r['bucket_mode'] == mode]
                row[mode] = {key: statistics.mean(r[key] for r in matching) for key in
                             ('closure_ms', 'selection_ms', 'expansion_ms', 'service_ms', 'internal_edge_scans',
                              'selection_vertex_checks', 'control_d2h_bytes', 'control_d2h_calls',
                              'allocated_device_bytes', 'repair_only_device_bytes', 'iterations')}
                for key in ('complete_service_ms', 'device_release_ms', 'host_index_ms', 'host_boundary_count_ms',
                            'host_transpose_ms', 'setup_ms', 'parent_reconstruction_ms', 'peak_rss_kib',
                            'host_workspace_bytes', 'host_cursor_bytes', 'host_release_ms', 'deferred_copy_entries'):
                    if all(key in r for r in matching):
                        row[mode][key] = statistics.mean(r[key] for r in matching)
            if all('complete_service_ms' in r for r in runs):
                row['candidate_over_baseline_complete_service_pairs'] = [
                    runs[1]['complete_service_ms']/runs[0]['complete_service_ms'],
                    runs[2]['complete_service_ms']/runs[3]['complete_service_ms']]
            row['limits'] = ['No production gather/scatter or cross-batch maintenance; no full-batch speedup claim',
                             'Accounting v2 includes host/device workspace frees; excludes snapshot I/O/destruction and validation',
                             'Selection and expansion include host synchronization, not pure GPU kernel time',
                             'Profiler runs excluded from paired timings']
            analysis[cohort] = row
            write_json(directory/'analysis.json', analysis)
        state('completed', analysis='analysis.json')
    except BaseException as error:
        state('failed', error=str(error))
        raise


if __name__ == '__main__':
    main()
