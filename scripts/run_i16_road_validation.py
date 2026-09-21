#!/usr/bin/env python3
"""I16 E0/E1: frozen, serial road correctness screening, never a speedup run."""
import argparse
import csv
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def write_json(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(path)


def fields(line):
    return {key: (float(value) if '.' in value else int(value))
            for key, value in re.findall(r'\b(\w+)=([0-9.]+)', line)}


def parse_log(content, batches=1, cpu_pq=False):
    if 'protocol_error=' in content or 'I12-TRANSACTION' in content:
        raise ValueError('Runtime protocol failure or wrong execution path')
    rows = {}
    repair_tag = 'I16-CPU-REPAIR' if cpu_pq else 'B2-GPU-REPAIR'
    for tag in ('SSSP-DELETE-STAGE-CHECK', 'SSSP-BATCH-CHECK', 'C3-PUBLISH',
                'I14-BATCH', repair_tag, 'P0-TIMER', 'P0-ATTR'):
        found = []
        for line in content.splitlines():
            if '[' + tag + ']' not in line:
                continue
            match = re.search(r'\[batch (\d+)\]', line)
            if not match:
                raise ValueError('Missing batch ID: ' + tag)
            row = fields(line)
            row['batch'] = int(match[1])
            if tag in ('SSSP-DELETE-STAGE-CHECK', 'SSSP-BATCH-CHECK'):
                if ('] passed ' not in line or row.get('source_ok') != 1 or
                    row.get('relaxable_edges') != 0 or row.get('missing_tight_witnesses') != 0
                    or 'distance_checksum' not in row):
                    raise ValueError('Distance/tight-witness failure: ' + tag)
            if tag == 'C3-PUBLISH':
                if any(row.get(key) != 0 for key in ('stale_version_rejects', 'gpu_cpu_hash_mismatches')):
                    raise ValueError('Publication protocol failure')
            if tag == 'B2-GPU-REPAIR':
                if 'affected' not in row or (row['affected'] and
                    any(key not in row for key in ('iterations', 'incoming_edges', 'closure_ms'))):
                    raise ValueError('Incomplete repair metrics')
            if tag == 'I16-CPU-REPAIR':
                if 'affected' not in row or (row['affected'] and
                    (any(key not in row for key in ('incoming_edges', 'internal_scans', 'service_ms',
                         'gather_ms', 'setup_ms', 'closure_ms', 'parent_ms', 'scatter_ms',
                         'temporary_device_bytes', 'avoided_incoming_device_bytes')) or
                     row['temporary_device_bytes'] > row['avoided_incoming_device_bytes'])):
                    raise ValueError('Incomplete CPU service metrics or staging budget violation')
            if tag == 'P0-TIMER':
                timer = re.search(r'total_batch: ([0-9.]+) ms', line)
                if not timer:
                    raise ValueError('Missing batch timer')
                row['total_ms'] = float(timer[1])
            found.append(row)
        if [row['batch'] for row in found] != list(range(batches)):
            raise ValueError('Incomplete or duplicate batch sequence: ' + tag)
        rows[tag] = found
    final = [fields(line) for line in content.splitlines() if '[SSSP-BELLMAN-CHECK]' in line]
    if (len(final) != 1 or final[0].get('relaxable_edges') != 0 or
        final[0].get('missing_tight_witnesses') != 0 or
        '[SSSP-BELLMAN-CHECK] passed' not in content or 'Overall: Test passed' not in content or
        'Overall: Test failed' in content):
        raise ValueError('Missing final checker success')
    checksums = re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', content)
    if len(checksums) != 1 or int(checksums[0]) != rows['SSSP-BATCH-CHECK'][-1]['distance_checksum']:
        raise ValueError('Final checksum disagrees with last batch')
    for timer, attr in zip(rows['P0-TIMER'], rows['P0-ATTR']):
        keys = ('deletion', 'add', 'hotness', 'candidate', 'eviction', 'compact', 'cache_load', 'residual')
        if any(key not in attr for key in keys) or abs(sum(attr[k] for k in keys) - timer['total_ms']) > max(.03, timer['total_ms'] * .02):
            raise ValueError('Timer attribution mismatch')
    return {'checks': rows, 'final': final[0], 'distance_checksum': int(checksums[0]),
            'has_repair_work': any(row['affected'] > 0 for row in rows[repair_tag]),
            'parent_contract': 'stored-parent diagnostics reported, not required to be zero'}


def audit_file(path, kind):
    before = path.stat()
    digest = hashlib.sha256()
    count = 0
    minimum, maximum = None, 0
    incident = {str(v): {'in': 0, 'out': 0} for v in (0, 1)}
    operations = {'a': 0, 'd': 0}
    batch_sizes = []
    # NumPy parses bounded blocks; avoid a Python object per edge on large EU.
    import numpy as np
    with path.open('rb') as source:
        while True:
            lines = list(itertools.islice(source, 100000))
            if not lines:
                break
            raw = b''.join(lines)
            digest.update(raw)
            if kind == 'graph':
                if any(len(line.split()) != 2 for line in lines):
                    raise ValueError(f'{path}: graph record is not a two-column edge')
                values = np.fromstring(raw.decode('ascii'), sep=' ', dtype=np.int64)
                if values.size != len(lines) * 2 or np.any(values < 0) or np.any(values >= 2**32 - 1):
                    raise ValueError(f'{path}: invalid vertex IDs')
                edges = values.reshape(-1, 2)
            elif kind == 'updates':
                parsed = []
                for line in lines:
                    parts = line.split()
                    if len(parts) != 4 or parts[0] not in (b'a', b'd') or int(parts[3]) != 1:
                        raise ValueError(f'{path}: invalid update record')
                    operations[parts[0].decode()] += 1
                    parsed.append((int(parts[1]), int(parts[2])))
                edges = np.asarray(parsed, dtype=np.int64)
                if np.any(edges < 0) or np.any(edges >= 2**32 - 1):
                    raise ValueError(f'{path}: invalid update IDs')
            else:
                for line in lines:
                    parts = [int(x) for x in line.split()]
                    if len(parts) != 2 or min(parts) < 0:
                        raise ValueError(f'{path}: invalid batch sizes')
                    batch_sizes.append(parts)
                count += len(lines)
                continue
            lo, hi = int(edges.min()), int(edges.max())
            minimum = lo if minimum is None else min(minimum, lo)
            maximum = max(maximum, hi)
            for vertex in (0, 1):
                incident[str(vertex)]['out'] += int(np.count_nonzero(edges[:, 0] == vertex))
                incident[str(vertex)]['in'] += int(np.count_nonzero(edges[:, 1] == vertex))
            count += len(lines)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError('Input changed during audit: ' + str(path))
    return {'path': str(path.resolve()), 'bytes': before.st_size, 'mtime_ns': before.st_mtime_ns,
            'sha256': digest.hexdigest(), 'records': count, 'min_id': minimum, 'max_id': maximum,
            'source_incidence': incident, 'operations': operations, 'batch_sizes': batch_sizes}


def gpu_idle():
    query = subprocess.check_output(['nvidia-smi', '-i', '0',
        '--query-gpu=memory.used,utilization.gpu', '--format=csv,noheader,nounits'], text=True)
    processes = subprocess.check_output(['nvidia-smi', '-i', '0',
        '--query-compute-apps=pid', '--format=csv,noheader,nounits'], text=True)
    return tuple(map(int, query.strip().split(','))) == (0, 0) and not processes.strip()


def datasets_for(suite):
    if suite == 'connected50':
        root = ROOT / 'data/road_connected_v2'
        return [(label + '50_connected_v2', root / name / '50p', name + '_50p_100k', (1,))
                for label, name in (('eu', 'europe_osm'), ('usa', 'road_usa'))]
    return [('eu50_raw', ROOT / 'data', 'europe_osm_50p_100k', (0, 1)),
            ('usa50_raw', ROOT / 'data/road_usa', 'road_usa_50p_100k', (0, 1)),
            ('eu99_sym', ROOT / 'data/europe_symmetric_99p', 'europe_osm_99p_100k', (1,))]


def validate_connected(data, paths, audits):
    dataset = data.parent
    checksums = json.loads((dataset / 'checksums.json').read_text())
    verification_path = dataset / 'verification.json'
    expected = checksums['verification.json']['sha256']
    if hashlib.sha256(verification_path.read_bytes()).hexdigest() != expected:
        raise ValueError('Connectivity certificate hash mismatch')
    verification = json.loads(verification_path.read_text())
    ratio = next(row for row in verification['ratios'] if row['percent'] == 50)
    config = next(row for row in ratio['configs'] if row['scale'] == 100000)
    if (verification['state'] != 'passed' or ratio['active_vertices'] != ratio['source_reachable_vertices']
        or len(config['batches']) != 10 or any(not row['connectivity_preserved'] or
            row['effective_delete_pairs'] != 25000 or row['effective_add_pairs'] != 25000 or
            row['source_reachable_delete_pairs'] != 25000 or row['source_reachable_add_pairs'] != 25000
            for row in config['batches'])):
        raise ValueError('Connected workload certificate failed')
    for path, audit in zip(paths, audits):
        expected = checksums[str(path.relative_to(dataset))]
        if audit['sha256'] != expected['sha256'] or audit['bytes'] != expected['bytes']:
            raise ValueError('Generated workload hash mismatch: ' + str(path))
    return {'verification_sha256': checksums['verification.json']['sha256'],
            'source_node': 1, 'source_reachable_vertices': ratio['source_reachable_vertices'],
            'deletion_sampling': 'non-protected edges only; random Kruskal backbone',
            'certificate': ratio}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--timeout', type=int, default=7200)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--suite', choices=['legacy', 'connected50'], default='legacy')
    parser.add_argument('--batches', type=int, choices=range(1, 11), default=1)
    parser.add_argument('--capture', action='store_true', help='First-batch snapshot and CPU oracle (connected50 only)')
    parser.add_argument('--cpu-pq', action='store_true')
    args = parser.parse_args()
    if args.cpu_pq:
        parser.error('CPU road runtime retired; use archived runner and binary for historical reproduction')
    if args.capture and args.suite != 'connected50':
        parser.error('--capture requires --suite connected50')
    if args.cpu_pq and (args.capture or args.suite != 'connected50'):
        parser.error('--cpu-pq requires connected50 without capture')
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    lock = (directory / 'runner.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit('Runner already active in this directory')
    status = directory / 'status.json'
    if status.exists() and not args.resume:
        raise SystemExit('Use a fresh directory; existing status preserved')
    results = {}
    if args.resume:
        previous = json.loads(status.read_text())
        if previous['state'] != 'blocked_resource':
            raise SystemExit('Resume is only allowed after blocked_resource')
        results = previous['results']
    def state(value, **extra):
        write_json(status, {'state': value, 'pid': os.getpid(), 'results': results, **extra})
    try:
        state('freezing')
        binary = directory / 'hybrid_sssp'
        if not args.resume:
            shutil.copy2(ROOT / 'build/hybrid_sssp', binary)
        manifest = {'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
            'git_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
            'gpu': 0, 'workers': 20, 'batches': args.batches, 'timeout_seconds': args.timeout,
            'diagnostic_only': True, 'commands': [], 'files': {}}
        manifest['suite'] = args.suite
        manifest['capture'] = args.capture
        manifest['cpu_pq'] = args.cpu_pq
        if args.resume:
            manifest = json.loads((directory / 'manifest.json').read_text())
            if args.suite != manifest.get('suite', 'legacy') or args.timeout != manifest['timeout_seconds']:
                raise ValueError('Resume must use the frozen suite and timeout')
            if args.batches != manifest['batches'] or args.capture != manifest.get('capture', False):
                raise ValueError('Resume must use frozen batches and capture mode')
            if args.cpu_pq != manifest.get('cpu_pq', False):
                raise ValueError('Resume must use frozen repair mode')
            if hashlib.sha256(binary.read_bytes()).hexdigest() != manifest['binary_sha256']:
                raise ValueError('Frozen executable changed')
            shutil.copy2(__file__, directory / 'runner_resume.py')
        else:
            (directory / 'workspace.diff').write_bytes(subprocess.check_output(['git', 'diff', 'HEAD'], cwd=ROOT))
            shutil.copy2(__file__, directory / 'runner.py')
        if args.capture:
            oracle = directory / 'i16_repair_oracle'
            if not args.resume:
                shutil.copy2(ROOT / 'build/i16_repair_oracle', oracle)
                manifest['oracle_sha256'] = hashlib.sha256(oracle.read_bytes()).hexdigest()
                for source_path in ('include/framework/i16_repair_snapshot.h', 'src/i16_repair_oracle.cpp',
                                    'include/framework/framework.cuh', 'samples/hybrid_sssp/hybrid_sssp.cu'):
                    target = directory / 'sources' / source_path
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / source_path, target)
            elif hashlib.sha256(oracle.read_bytes()).hexdigest() != manifest['oracle_sha256']:
                raise ValueError('Frozen oracle changed')
        datasets = datasets_for(args.suite)
        if args.cpu_pq and not args.resume:
            reference = json.loads((ROOT/'logs/i16_e2_capture_20260907/correctness.json').read_text())
            write_json(directory/'baseline_correctness.json', reference)
            for source_path in ('include/framework/i16_cpu_repair.h', 'include/framework/i16_repair_snapshot.h',
                                'include/framework/framework.cuh', 'samples/hybrid_sssp/hybrid_sssp.cu'):
                target=directory/'sources'/source_path
                target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(ROOT/source_path,target)
        for name, data, stem, sources in datasets:
            paths = [data / f'{prefix}_{stem}.txt' for prefix in ('input', 'update', 'stream_size')]
            state('auditing', cohort=name)
            print('Auditing ' + name, flush=True)
            audits = []
            for path, kind in zip(paths, ('graph', 'updates', 'sizes')):
                cached = manifest['files'].get(str(path))
                if args.resume and cached and args.suite == 'legacy':
                    current = path.stat()
                    if (current.st_size, current.st_mtime_ns) != (cached['bytes'], cached['mtime_ns']):
                        raise ValueError('Audited input changed before resume')
                    audits.append(cached)
                else:
                    audits.append(audit_file(path, kind))
                manifest['files'][str(path)] = audits[-1]
                write_json(directory / 'manifest.json', manifest)
            graph, updates, sizes = audits
            if args.suite == 'connected50':
                manifest.setdefault('connected_certificates', {})[name] = validate_connected(data, paths, audits)
                write_json(directory / 'manifest.json', manifest)
            if (not sizes['batch_sizes'] or len(sizes['batch_sizes']) != 10 or
                any(pair != [50000, 50000] for pair in sizes['batch_sizes']) or
                updates['operations'] != {'a': 500000, 'd': 500000} or
                updates['max_id'] > graph['max_id']):
                raise ValueError('Unexpected 100k stream contract: ' + name)
            for source in sources:
                cohort = name + '_s' + str(source)
                if cohort in results:
                    continue
                if source > graph['max_id']:
                    raise ValueError('Source would be clamped')
                command = [str(binary), f'--graphfile={paths[0]}', f'--updatefile={paths[1]}',
                    f'--update_size={paths[2]}', '--format=market_big', '--weight_num=1', '--weight=1',
                    f'--source_node={source}', '--SEGMENT=512', '--n_stream=3', '--hybrid=0', '--cache=2',
                    '--sssp_cpu_partition_capacity=0', '--check=true', '--verbose=false',
                    f'--sssp_max_batches={args.batches}', '--sssp_print_checksum=true']
                snapshot = directory / (cohort + '.snapshot.bin')
                if args.capture:
                    command.append('--i16_repair_snapshot=' + str(snapshot))
                if args.cpu_pq:
                    command.append('--i16_cpu_pq=true')
                manifest['commands'] = [entry for entry in manifest['commands'] if entry['cohort'] != cohort]
                manifest['commands'].append({'cohort': cohort, 'argv': command})
                write_json(directory / 'manifest.json', manifest)
                if not gpu_idle():
                    state('blocked_resource', cohort=cohort)
                    return 2
                for path, record in zip(paths, audits):
                    current = path.stat()
                    if (current.st_size, current.st_mtime_ns) != (record['bytes'], record['mtime_ns']):
                        raise ValueError('Audited file changed')
                state('running', cohort=cohort)
                print('Starting ' + cohort, flush=True)
                start = time.monotonic()
                log = directory / (cohort + '.log')
                with log.open('w') as output:
                    child = subprocess.Popen(command, env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0',
                        'CG_MUTATION_WORKERS': '20'}, stdout=output, stderr=subprocess.STDOUT,
                        start_new_session=True)
                    state('running', cohort=cohort, child_pid=child.pid)
                    try:
                        code = child.wait(timeout=args.timeout)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()
                        state('timeout', cohort=cohort)
                        return 3
                if code:
                    raise ValueError(f'{cohort}: process exit {code}')
                result = parse_log(log.read_text(), args.batches, args.cpu_pq)
                if args.cpu_pq:
                    reference=json.loads((directory/'baseline_correctness.json').read_text())[cohort]
                    for phase in ('SSSP-DELETE-STAGE-CHECK','SSSP-BATCH-CHECK'):
                        compared=min(args.batches,len(reference['checks'][phase]))
                        if [row['distance_checksum'] for row in result['checks'][phase]][:compared] != [row['distance_checksum'] for row in reference['checks'][phase]][:compared]:
                            raise ValueError('CPU continuous-stage distances disagree with baseline')
                if args.suite == 'connected50':
                    expected_reachable = manifest['connected_certificates'][name]['source_reachable_vertices']
                    if (result['final'].get('reachable') != expected_reachable or
                        any(row.get('updates') != 100000 for row in result['checks']['I14-BATCH'])):
                        raise ValueError('Runtime reachability/update count disagrees with connected workload')
                if args.capture:
                    reference = json.loads((ROOT / 'logs/i16_connected50_validation_20260907/correctness.json').read_text())[cohort]
                    for phase in ('SSSP-DELETE-STAGE-CHECK', 'SSSP-BATCH-CHECK'):
                        if result['checks'][phase][0]['distance_checksum'] != reference['checks'][phase][0]['distance_checksum']:
                            raise ValueError('Captured first-batch distance differs from frozen E1 baseline')
                    report = directory / (cohort + '.oracle.json')
                    oracle_command = [str(oracle), str(snapshot), str(report)]
                    manifest.setdefault('oracle_commands', {})[cohort] = oracle_command
                    write_json(directory / 'manifest.json', manifest)
                    state('oracle', cohort=cohort)
                    with (directory / (cohort + '.oracle.log')).open('w') as output:
                        subprocess.run(oracle_command, stdout=output, stderr=subprocess.STDOUT,
                                       check=True, timeout=args.timeout)
                    result['oracle'] = json.loads(report.read_text())
                    if result['oracle']['state'] != 'passed' or result['oracle']['distance_mismatches'] != 0:
                        raise ValueError('Same-state oracle mismatch')
                    digest = hashlib.sha256()
                    with snapshot.open('rb') as input_file:
                        for block in iter(lambda: input_file.read(8*1024*1024), b''):
                            digest.update(block)
                    result['snapshot_sha256'] = digest.hexdigest()
                results[cohort] = result
                results[cohort]['wall_seconds'] = time.monotonic() - start
                write_json(directory / 'correctness.json', results)
                with (directory / 'work_summary.csv').open('w') as output:
                    writer = csv.DictWriter(output, fieldnames=['cohort', 'batch', 'executor', 'affected', 'incoming_edges',
                        'internal_scans', 'repair_service_ms',
                        'iterations', 'logical_incoming_checks', 'closure_ms', 'total_batch_ms', 'reachable'])
                    writer.writeheader()
                    for key, result in results.items():
                        for batch, repair in enumerate(result['checks']['I16-CPU-REPAIR' if args.cpu_pq else 'B2-GPU-REPAIR']):
                            writer.writerow({'cohort': key, 'batch': batch, 'executor': 'cpu_pq' if args.cpu_pq else 'gpu_pull',
                                'affected': repair['affected'], 'internal_scans': repair.get('internal_scans', ''),
                                'repair_service_ms': repair.get('service_ms', ''),
                                'incoming_edges': repair.get('incoming_edges', 0), 'iterations': repair.get('iterations', 0),
                                'logical_incoming_checks': repair.get('incoming_edges', 0) * repair.get('iterations', 0),
                                'closure_ms': repair.get('closure_ms', 0),
                                'total_batch_ms': result['checks']['P0-TIMER'][batch]['total_ms'],
                                'reachable': result['final'].get('reachable')})
                print('Passed ' + cohort, flush=True)
                # Let this process's CUDA context teardown settle before the
                # next strict idle check; no workload runs during this delay.
                time.sleep(3)
        state('completed', cohorts=len(results),
              repair_candidates=[key for key, result in results.items() if result['has_repair_work']],
              next_gate=('Review CPU full-service correctness then no-trace paired performance and memory gate' if args.cpu_pq else
                         'E2 GPU frontier same-state prototype; not yet implemented' if args.capture else
                         'E2 same-state capture/oracle'))
        return 0
    except Exception as error:
        state('failed', error=str(error))
        raise


if __name__ == '__main__':
    raise SystemExit(main())
