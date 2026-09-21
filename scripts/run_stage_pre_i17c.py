#!/usr/bin/env python3
"""Detached, resumable SSSP matrix; equal cache and serial GPU 0 execution."""
import argparse
import csv
import datetime
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import signal
import statistics
import subprocess
import time
from run_i16_road_validation import parse_log

ROOT = Path(os.environ.get('CG_STAGE_ROOT', Path(__file__).resolve().parents[1])).resolve()
SIZES = (1, 10, 100, 1000)


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_json(path, obj):
    tmp = Path(str(path)+'.tmp')
    tmp.write_text(json.dumps(obj, indent=2, allow_nan=False)+'\n')
    tmp.replace(path)


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(8 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def fields(line):
    return {k: float(v) if '.' in v else int(v)
            for k, v in re.findall(r'\b(\w+)=(-?[0-9]+(?:\.[0-9]+)?)', line)}


def discover():
    data = ROOT/'data'
    definitions = [(n, data, stem, stem, source, 'primary') for n, stem, source in (
        ('orkut', 'orkut_50p', 377664), ('wiki', 'wiki_50p', 134151),
        ('friendster', 'friendster_50p', 0), ('rmat', 'rmat_fs_like_50p', 0))]
    definitions.append(('uk2007', data, 'uk-2007-05_50p', 'uk-2007-05', 0, 'primary'))
    definitions.insert(2, ('twitter', Path(os.environ.get('CG_STAGE_TWITTER', ROOT/'data/twitter_stage_true')),
                          'twitter_stage', 'twitter_stage', 0, 'primary'))
    for graph, label in (('europe_osm', 'eu'), ('road_usa', 'usa')):
        for ratio in (50, 75, 99):
            stem = f'{graph}_{ratio}p'
            definitions.append((f'{label}_connected{ratio}', data/'road_connected_v2'/graph/f'{ratio}p',
                                stem, stem, 1, 'primary' if ratio == 50 else 'supplement'))
    definitions += [
        ('twitter_legacy', data, 'twitter', 'twitter', 0, 'legacy'),
        ('twitter_original_ids', data, 'twitter_original', 'twitter_original', 0, 'legacy'),
        ('eu_raw50', data, 'europe_osm_50p', 'europe_osm_50p', 1, 'legacy'),
        ('usa_raw50', data/'road_usa', 'road_usa_50p', 'road_usa_50p', 1, 'legacy'),
        ('eu_symmetric50', data/'europe_symmetric', 'europe_osm_50p', 'europe_osm_50p', 1, 'legacy'),
        ('eu_symmetric99', data/'europe_symmetric_99p', 'europe_osm_99p', 'europe_osm_99p', 1, 'legacy')]
    datasets = []
    for name, folder, graph_stem, update_stem, source, group in definitions:
        configs, missing = {}, []
        for size in SIZES:
            files = [folder/f'input_{graph_stem}_{size}k.txt', folder/f'update_{update_stem}_{size}k.txt',
                     folder/f'stream_size_{update_stem}_{size}k.txt']
            if not all(p.is_file() for p in files):
                missing.append(size)
                continue
            batches = [[int(x) for x in line.split()] for line in files[2].read_text().splitlines() if line.strip()]
            update_lines = sum(1 for line in files[1].open() if line.strip())
            if len(batches) != 10 or any(len(b) != 2 or min(b) < 0 for b in batches):
                raise ValueError(f'Invalid 10-batch update sizes: {files[2]}')
            if sum(map(sum, batches)) != update_lines:
                raise ValueError(f'Batch sizes do not match update records: {files[1]}')
            configs[str(size)] = dict(zip(('graph', 'updates', 'sizes'), map(lambda p: str(p.resolve()), files)))
            configs[str(size)]['batch_sizes'] = batches
            configs[str(size)]['actual_updates_per_batch'] = list(map(sum, batches))
            configs[str(size)]['filename_scale_matches'] = all(sum(b) == size*1000 for b in batches)
        datasets.append({'name': name, 'source': source, 'group': group, 'configs': configs, 'missing_sizes_k': missing})
    return datasets


def parse_run(text, side, check, batches):
    if re.search(r'out of memory|cudaErrorMemoryAllocation|std::bad_alloc', text, re.I):
        raise ValueError('oom')
    if re.search(r'Max iterations reached|Max iteration reached:\s*YES|protocol_error=|Overall: Test failed|illegal memory access', text, re.I):
        raise ValueError('runtime_contract_failure')
    timers = re.findall(r'\[P0-TIMER\]\[SSSP\]\[batch (\d+)\] total_batch: ([0-9.]+) ms', text)
    if [int(i) for i, _ in timers] != list(range(batches)):
        raise ValueError('incomplete_or_duplicate_batch_timers')
    values = [float(t) for _, t in timers]
    if any(not math.isfinite(v) or v <= 0 for v in values):
        raise ValueError('invalid_timer')
    if not check and ('[SSSP-DELETE-STAGE-CHECK]' in text or '[SSSP-BATCH-CHECK]' in text):
        raise ValueError('correctness_enabled_in_performance')
    if 'Overall: Test passed' not in text:
        raise ValueError('missing_normal_completion')
    result = {'paper_algorithm_ms': sum(values), 'batch_ms': values, 'batches': batches,
              'mean_batch_ms': statistics.mean(values)}
    if side == 'current':
        attrs = [dict(fields(line), batch=int(re.search(r'\[batch (\d+)\]', line)[1]))
                 for line in text.splitlines() if '[P0-ATTR]' in line]
        if [r['batch'] for r in attrs] != list(range(batches)):
            raise ValueError('incomplete_attribution')
        keys = ('deletion', 'add', 'hotness', 'candidate', 'eviction', 'compact', 'cache_load', 'residual')
        for row, ms in zip(attrs, values):
            if abs(sum(row[k] for k in keys)-ms) > max(.05, ms*.02):
                raise ValueError('timer_attribution_mismatch')
        result['stages_ms'] = {k: sum(row[k] for row in attrs) for k in keys}
        result['repair'] = [fields(line) for line in text.splitlines() if '[B2-GPU-REPAIR]' in line]
        result['effective_updates'] = [fields(line).get('updates') for line in text.splitlines() if '[I14-BATCH]' in line]
        for line in text.splitlines():
            if '[C3-PUBLISH]' in line:
                publish = fields(line)
                if publish.get('stale_version_rejects', 0) or publish.get('gpu_cpu_hash_mismatches', 0):
                    raise ValueError('publication_failure')
        result['distance_checksum'] = (re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', text) or [None])[-1]
        if check:
            verified = parse_log(text, batches=batches)
            result['correctness'] = verified
            result['stored_parent_diagnostics'] = [r.get('invalid_parent_witness', 0)
                for tag in ('SSSP-DELETE-STAGE-CHECK', 'SSSP-BATCH-CHECK') for r in verified['checks'][tag]]
    else:
        result['legacy_result_summary'] = re.findall(r'\[P0-INFO\]\[GPU_ONLY\] final_result_count: (\d+), checksum: (\d+)', text)
    return result


def select(pilot):
    configs = {}
    for cache in (2, 3):
        per_side = {}
        for side in ('current', 'original'):
            valid = [r for r in pilot if r['cache'] == cache and r['side'] == side and r['status'] == 'passed']
            if valid:
                best = min(valid, key=lambda r: r['paper_algorithm_ms'])
                per_side[side] = {'hybrid': best['hybrid'], 'pilot_ms': best['paper_algorithm_ms']}
        if len(per_side) == 2:
            configs[cache] = per_side
    if not configs:
        current = [r for r in pilot if r['side'] == 'current' and r['status'] == 'passed']
        best = min(current, key=lambda r: r['paper_algorithm_ms']) if current else {'cache': 2, 'hybrid': 0}
        return {'status': 'no_common_configuration', 'cache': best['cache'],
                'current': {'hybrid': best['hybrid']}, 'original': {'hybrid': 2}}
    cache = 2 if 2 in configs else 3
    if len(configs) == 2 and math.sqrt(math.prod(configs[3][s]['pilot_ms']/configs[2][s]['pilot_ms']
                                                for s in ('current', 'original'))) < .97:
        cache = 3
    return {'status': 'selected', 'cache': cache, **configs[cache],
            'rule': 'equal cache; fastest feasible hybrid per side; cache3 needs geometric mean ratio <0.97'}


class Matrix:
    def __init__(self, args):
        self.args, self.directory = args, args.directory.resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.lock = (self.directory/'runner.lock').open('a')
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.results = json.loads((self.directory/'runs.json').read_text()) if (self.directory/'runs.json').exists() else {}
        self.manifest = json.loads((self.directory/'manifest.json').read_text()) if (self.directory/'manifest.json').exists() else {}
        self.child = None

    def state(self, state, **extra):
        write_json(self.directory/'status.json', {'state': state, 'pid': os.getpid(), 'updated_utc': now(),
            'finished_runs': len(self.results), 'failed_runs': sum(r['status'] == 'failed' for r in self.results.values()), **extra})

    def persist(self):
        write_json(self.directory/'runs.json', self.results)
        self.report()

    def verify_file(self, path):
        p = Path(path)
        st = p.stat()
        identity = [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns]
        entry = self.manifest.setdefault('files', {}).get(path)
        if entry:
            if entry['identity'] != identity:
                raise ValueError('Input changed: '+path)
            return
        self.state('hashing_input', file=path)
        equivalent = next((v for v in self.manifest['files'].values() if v['identity'] == identity), None)
        digest = equivalent['sha256'] if equivalent else sha(p)
        end = p.stat()
        if identity != [end.st_dev, end.st_ino, end.st_size, end.st_mtime_ns]:
            raise ValueError('Input changed while hashing: '+path)
        self.manifest['files'][path] = {'identity': identity, 'sha256': digest}
        write_json(self.directory/'manifest.json', self.manifest)

    def gpu(self):
        status = subprocess.check_output(['nvidia-smi', '-i', '0', '--query-gpu=memory.used,utilization.gpu',
                                         '--format=csv,noheader,nounits'], text=True, timeout=15)
        procs = subprocess.check_output(['nvidia-smi', '-i', '0', '--query-compute-apps=pid,used_gpu_memory',
                                        '--format=csv,noheader,nounits'], text=True, timeout=15)
        return tuple(int(v.strip()) for v in status.strip().split(',')), [tuple(int(v.strip()) for v in line.split(','))
                for line in procs.strip().splitlines() if line.strip()]

    def idle(self, key):
        self.state('waiting_gpu', active=key)
        while True:
            status, processes = self.gpu()
            if status == (0, 0) and not processes:
                return
            time.sleep(10)

    def stop_child(self):
        if self.child and self.child.poll() is None:
            os.killpg(self.child.pid, signal.SIGTERM)
            try:
                self.child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(self.child.pid, signal.SIGKILL)
                self.child.wait()
        self.child = None

    def run(self, ds, size, phase, side, cache, hybrid, repeat=0, workers=20, batches=10):
        key = f'{phase}.{ds["name"]}.{size}k.{side}.c{cache}.h{hybrid}.w{workers}.r{repeat}'
        if key in self.results:
            return self.results[key]
        cfg = ds['configs'][str(size)]
        for field in ('graph', 'updates', 'sizes'):
            self.verify_file(cfg[field])
        check = phase == 'correctness'
        binary = self.directory/'bin'/side
        if sha(binary) != self.manifest['binaries'][side]:
            raise ValueError('Frozen binary changed')
        cmd = [str(binary), '--graphfile='+cfg['graph'], '--format=market_big', '--weight_num=1', '--weight=1',
               '--updatefile='+cfg['updates'], '--update_size='+cfg['sizes'], f'--source_node={ds["source"]}',
               '--SEGMENT=512', '--n_stream=3', f'--hybrid={hybrid}', f'--cache={cache}',
               '--check='+str(check).lower(), '--verbose=false', f'--sssp_max_batches={batches}']
        if side == 'current':
            cmd += ['--sssp_cpu_partition_capacity=0', '--sssp_print_checksum=true']
        env = {k: v for k, v in os.environ.items() if not k.startswith('CG_')}
        env.update(CUDA_VISIBLE_DEVICES='0', CG_MUTATION_WORKERS=str(workers))
        row = {'key': key, 'phase': phase, 'dataset': ds['name'], 'size_k': size, 'side': side, 'cache': cache,
               'hybrid': hybrid, 'workers': workers, 'repeat': repeat, 'check': check, 'expected_batches': batches,
               'command': cmd, 'started_utc': now(), 'status': 'failed'}
        row['actual_updates_per_batch'] = cfg['actual_updates_per_batch'][:batches]
        prior_failure = next((r for r in self.results.values() if phase == 'performance' and
            all(r.get(k) == row[k] for k in ('phase', 'dataset', 'size_k', 'side', 'cache', 'hybrid', 'workers'))
            and r['status'] == 'failed'), None)
        if prior_failure:
            row.update(status='skipped_after_failure', error='prior_failure:'+prior_failure.get('error', 'unknown'),
                       prior_run=prior_failure['key'])
            self.results[key] = row
            self.persist()
            return row
        (self.directory/'runs').mkdir(exist_ok=True)
        prefix = self.directory/'runs'/key
        write_json(Path(str(prefix)+'.command.json'), {'argv': cmd, 'env': {k: env[k] for k in
            ('CUDA_VISIBLE_DEVICES', 'CG_MUTATION_WORKERS')}, 'cwd': str(self.directory)})
        gpu_lock = (ROOT/'build/i17_replay_gpu.lock').open('a')
        fcntl.flock(gpu_lock, fcntl.LOCK_EX)
        try:
            attempt = 0
            while Path(str(prefix)+f'.attempt{attempt}.log').exists():
                attempt += 1
            while True:
                self.idle(key)
                for field in ('graph', 'updates', 'sizes'):
                    self.verify_file(cfg[field])
                logfile = Path(str(prefix)+f'.attempt{attempt}.log')
                timefile = Path(str(prefix)+f'.attempt{attempt}.time')
                peak, samples, start, reason = 0, [], time.monotonic(), None
                with logfile.open('w') as output:
                    self.child = subprocess.Popen(['/usr/bin/time', '-f', 'wall_seconds=%e max_rss_kib=%M',
                        '-o', str(timefile), *cmd], cwd=self.directory, env=env, stdin=subprocess.DEVNULL,
                        stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
                    self.state('running', active=key, child_pid=self.child.pid, log=str(logfile))
                    last_status = start
                    try:
                        while self.child.poll() is None:
                            elapsed = time.monotonic()-start
                            _, processes = self.gpu()
                            foreign, memory = [], 0
                            for pid, mib in processes:
                                try:
                                    own = os.getpgid(pid) == self.child.pid
                                except ProcessLookupError:
                                    continue
                                if own:
                                    memory += mib
                                else:
                                    foreign.append(pid)
                            samples.append([round(elapsed, 1), memory])
                            peak = max(peak, memory)
                            if foreign or elapsed > self.args.timeout:
                                reason = 'resource_conflict' if foreign else 'timeout'
                                break
                            if time.monotonic()-last_status > 30:
                                self.state('running', active=key, child_pid=self.child.pid, elapsed_seconds=elapsed,
                                           gpu_peak_mib=peak, log=str(logfile))
                                last_status = time.monotonic()
                            time.sleep(2)
                        if reason:
                            self.stop_child()
                            rc = 124 if reason == 'timeout' else 125
                        else:
                            rc = self.child.wait()
                            self.child = None
                    finally:
                        self.stop_child()
                write_json(Path(str(prefix)+f'.attempt{attempt}.memory.json'), samples)
                if reason == 'resource_conflict':
                    attempt += 1
                    continue
                row.update(returncode=rc, log=str(logfile), elapsed_seconds=time.monotonic()-start,
                           sampled_gpu_peak_mib=peak, attempts=attempt+1)
                rss = re.search(r'max_rss_kib=(\d+)', timefile.read_text() if timefile.exists() else '')
                row['max_rss_kib'] = int(rss[1]) if rss else None
                text = logfile.read_text(errors='replace')
                try:
                    metrics = parse_run(text, side, check, batches)
                    if rc:
                        raise ValueError(reason or f'exit_{rc}')
                    if side == 'current' and metrics['effective_updates'] != row['actual_updates_per_batch']:
                        raise ValueError('processed_update_count_mismatch')
                    row.update(metrics, status='passed')
                except (ValueError, KeyError) as error:
                    row['error'] = reason or str(error)
                    if re.search(r'out of memory|cudaErrorMemoryAllocation|std::bad_alloc', text, re.I):
                        row['error'] = 'oom'
                self.results[key] = row
                self.persist()
                print(now(), key, row['status'], row.get('error', row.get('paper_algorithm_ms')), flush=True)
                return row
        finally:
            gpu_lock.close()

    def report(self):
        comparison, correctness, bottlenecks = [], [], []
        for ds in self.manifest.get('datasets', []):
            name = ds['name']
            selected = self.manifest.get('selections', {}).get(name, {})
            matching_checks = [r for r in self.results.values() if r['phase'] == 'correctness'
                               and r['dataset'] == name and r['cache'] == selected.get('cache')]
            for size in SIZES:
                row = {'dataset': name, 'group': ds['group'], 'size_k': size, 'cache': selected.get('cache'),
                       'status': 'missing_input' if str(size) not in ds['configs'] else 'pending'}
                row['actual_updates_per_batch'] = ds['configs'].get(str(size), {}).get('actual_updates_per_batch', [])
                row['current_100k_check'] = matching_checks[-1]['status'] if matching_checks else 'pending'
                for side in ('current', 'original'):
                    runs = [r for r in self.results.values() if r['phase'] == 'performance' and r['dataset'] == name
                            and r['size_k'] == size and r['side'] == side and r['cache'] == selected.get('cache')]
                    valid = [r for r in runs if r['status'] == 'passed']
                    row[side+'_passed'] = len(valid)
                    row[side+'_errors'] = ';'.join(sorted({r.get('error', '') for r in runs if r['status'] != 'passed'}))
                    row[side+'_median_ms'] = statistics.median(r['paper_algorithm_ms'] for r in valid) if valid else None
                    if valid and side == 'current':
                        means = {k: statistics.mean(r['stages_ms'][k] for r in valid) for k in valid[0]['stages_ms']}
                        total = statistics.mean(r['paper_algorithm_ms'] for r in valid)
                        repair = [x for r in valid for x in r['repair']]
                        bottlenecks.append({'dataset': name, 'size_k': size, 'cache': selected.get('cache'),
                            'stage_fraction': {k: v/total for k, v in means.items()},
                            'repair_closure_fraction': sum(x.get('closure_ms', 0) for x in repair)/(total*len(valid)),
                            'pull_logical_checks': [x.get('incoming_edges', 0)*x.get('iterations', 0) for x in repair],
                            'repair_iterations': [x.get('iterations', 0) for x in repair],
                            'note': 'Logical checks, not measured DRAM bytes; no overlap assumptions'})
                if row['status'] != 'missing_input':
                    if all(row[s+'_passed'] == self.args.repeats for s in ('current', 'original')):
                        row['status'] = 'measured'
                        row['original_over_current'] = row['original_median_ms']/row['current_median_ms']
                        if matching_checks and matching_checks[-1]['status'] != 'passed':
                            row['status'] = 'measured_but_current_correctness_failed'
                            del row['original_over_current']
                    elif any(row[s+'_errors'] for s in ('current', 'original')):
                        row['status'] = 'failed_or_partial'
                    if selected.get('status') == 'no_common_configuration':
                        row['status'] = 'no_common_configuration'
                comparison.append(row)
            checks = [r for r in self.results.values() if r['phase'] == 'correctness' and r['dataset'] == name]
            true100 = all(v == 100000 for v in ds['configs'].get('100', {}).get('actual_updates_per_batch', [0]))
            correctness.append({'dataset': name, 'true_100k': true100,
                                'status': (checks[-1]['status'] if true100 else 'legacy_non100k_'+checks[-1]['status']) if checks else 'pending',
                                'result': checks[-1] if checks else None})
        write_json(self.directory/'comparison.json', comparison)
        write_json(self.directory/'correctness.json', correctness)
        write_json(self.directory/'bottlenecks.json', bottlenecks)
        with (self.directory/'comparison.csv').open('w', newline='') as out:
            keys = list(dict.fromkeys(k for row in comparison for k in row))
            writer = csv.DictWriter(out, fieldnames=keys)
            writer.writeheader()
            writer.writerows(comparison)
        lines = ['# Pre-I17-C Stage Results', '', 'Updated: '+now(), '',
            'Performance: 10 batch P0-TIMER sum, excludes initialization and checks. Equal cache per cohort.',
            'Independent pilot-selected hybrid; 3 runs/side. Baseline correctness is not certified by exit status.', '',
            '| Dataset | Group | Actual updates/batch | Cache | Current ms | Original ms | Original/current | Status |',
            '|---|---|---:|---:|---:|---:|---:|---|']
        fmt = lambda v: '-' if v is None else f'{v:.3f}'
        for row in comparison:
            actual = row['actual_updates_per_batch']
            scale = str(actual[0]) if actual and len(set(actual)) == 1 else '-'
            lines.append(f'| {row["dataset"]} | {row["group"]} | {scale} | {row["cache"] or "-"} | '
                f'{fmt(row["current_median_ms"])} | {fmt(row["original_median_ms"])} | '
                f'{fmt(row.get("original_over_current"))} | {row["status"]} |')
        lines += ['', '## Current 100k Correctness', '', '| Dataset | Status |', '|---|---|']
        lines += [f'| {r["dataset"]} | {r["status"]} |' for r in correctness]
        lines += ['', 'Requires 10 deletion checks, 10 batch checks, final Bellman/overall pass.',
                  'Stored-parent diagnostics are separate under the existing existential-witness contract.', '',
                  '## Bottlenecks', '', 'bottlenecks.json: stage shares and repair work amplification.',
                  'worker_probe.json: 1 vs 20 mutation workers, diagnostic only, excluded from comparison.']
        probes = [r for r in self.results.values() if r['phase'] == 'worker_probe']
        summary = {}
        for dataset in ('twitter', 'friendster'):
            a = [r for r in probes if r['dataset'] == dataset and r['workers'] == 1 and r['status'] == 'passed']
            b = [r for r in probes if r['dataset'] == dataset and r['workers'] == 20 and r['status'] == 'passed']
            if len(a) == len(b) == 2:
                ratio = statistics.mean(r['paper_algorithm_ms'] for r in b)/statistics.mean(r['paper_algorithm_ms'] for r in a)
                summary[dataset] = {'workers20_over_workers1': ratio,
                    'distance_checksum_agrees': len({r['distance_checksum'] for r in a+b}) == 1,
                    'interpretation': 'CPU mutation scaling diagnostic; all GPU propagation and cache unchanged'}
                lines.append(f'- {dataset}: 20/1 worker service ratio {ratio:.4f}; checksum agreement {summary[dataset]["distance_checksum_agrees"]}.')
        write_json(self.directory/'worker_probe.json', {'runs': probes, 'summary': summary})
        (self.directory/'report.md').write_text('\n'.join(lines)+'\n')

    def fallback(self, ds):
        rows = [r for r in self.results.values() if r['dataset'] == ds['name'] and r['phase'] == 'pilot' and r['cache'] == 2]
        chosen = select(rows)
        chosen['fallback_reason'] = 'cache3 full-run OOM; redo comparison with cache2, keep old attempts'
        self.manifest['selections'][ds['name']] = chosen
        write_json(self.directory/'manifest.json', self.manifest)
        return chosen

    def execute(self):
        self.state('preflight')
        if not self.manifest:
            self.manifest = {'created_utc': now(), 'datasets': discover(), 'selections': {}, 'files': {},
                'binaries': {side: sha(self.directory/'bin'/side) for side in ('current', 'original')},
                'gpu': 0, 'repeats': self.args.repeats, 'timeout_seconds': self.args.timeout,
                'metric': '10 batch P0-TIMER sum; initial SSSP/cache and checks excluded',
                'current_modes': [0, 2], 'original_modes': [1, 2], 'pilot_batches': 2,
                'primary': 'connected-v2 50p roads; other versions explicitly separate',
                'scope': 'SSSP only; ordered replay not production and not included'}
            write_json(self.directory/'manifest.json', self.manifest)
        if self.manifest['repeats'] != self.args.repeats:
            raise ValueError('Repeat count changed on resume')
        if not any(d['name'] == 'twitter' and '100' in d['configs'] for d in self.manifest['datasets']):
            raise ValueError('True-100k Twitter preparation is required')
        self.report()
        for ds in self.manifest['datasets']:
            if not ds['configs']:
                continue
            name = ds['name']
            if name not in self.manifest['selections']:
                pilot_size = 100 if '100' in ds['configs'] else min(map(int, ds['configs']))
                pilot = []
                for cache in (2, 3):
                    for side, modes in (('current', (0, 2)), ('original', (1, 2))):
                        prior = [r for r in pilot if r['side'] == side and r['cache'] == 2 and r['status'] == 'passed']
                        if cache == 3 and not prior:
                            continue
                        for hybrid in modes:
                            if cache == 3 and hybrid != min(prior, key=lambda r: r['paper_algorithm_ms'])['hybrid']:
                                continue
                            pilot.append(self.run(ds, pilot_size, 'pilot', side, cache, hybrid, batches=2))
                self.manifest['selections'][name] = select(pilot)
                write_json(self.directory/'manifest.json', self.manifest)
                self.persist()
            chosen = self.manifest['selections'][name]
            if '100' in ds['configs']:
                outcome = self.run(ds, 100, 'correctness', 'current', chosen['cache'], chosen['current']['hybrid'])
                if outcome.get('error') == 'oom' and chosen['cache'] == 3:
                    chosen = self.fallback(ds)
                    self.run(ds, 100, 'correctness', 'current', 2, chosen['current']['hybrid'])
            if chosen['status'] != 'selected':
                # Preserve standalone current measurements when only the baseline is infeasible.
                viable = any(r['dataset'] == name and r['phase'] == 'pilot' and r['side'] == 'current'
                             and r['status'] == 'passed' for r in self.results.values())
                if viable:
                    for size in sorted(map(int, ds['configs'])):
                        for repeat in range(self.args.repeats):
                            self.run(ds, size, 'performance', 'current', chosen['cache'], chosen['current']['hybrid'], repeat)
                self.persist()
                continue
            # If cache3 overflows at a larger batch, repeat all sizes with one common cache2.
            while True:
                retry = False
                for size in sorted(map(int, ds['configs'])):
                    for repeat in range(self.args.repeats):
                        order = ('current', 'original') if repeat % 2 == 0 else ('original', 'current')
                        for side in order:
                            outcome = self.run(ds, size, 'performance', side, chosen['cache'], chosen[side]['hybrid'], repeat)
                            if outcome.get('error') == 'oom' and chosen['cache'] == 3:
                                chosen = self.fallback(ds)
                                retry = True
                                break
                        if retry:
                            break
                    if retry:
                        break
                if not retry:
                    break
            if '100' in ds['configs']:
                self.run(ds, 100, 'correctness', 'current', chosen['cache'], chosen['current']['hybrid'])
            if name in ('twitter', 'friendster'):
                for repeat, workers in enumerate((1, 20, 20, 1)):
                    self.run(ds, 100, 'worker_probe', 'current', chosen['cache'], chosen['current']['hybrid'],
                             repeat, workers=workers, batches=3)
        self.persist()
        needed = [r for r in self.results.values() if r['phase'] in ('performance', 'correctness')]
        state = 'completed_with_failures' if any(r['status'] != 'passed' for r in needed) or any(
            r['status'] != 'selected' for r in self.manifest['selections'].values()) else 'completed'
        self.state(state, report=str(self.directory/'report.md'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--timeout', type=int, default=21600)
    parser.add_argument('--inventory-only', action='store_true')
    args = parser.parse_args()
    if args.repeats < 1 or args.timeout < 1:
        parser.error('positive repeats and timeout required')
    if args.inventory_only:
        print(json.dumps(discover(), indent=2))
        return
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    matrix = Matrix(args)
    def stop(signum, frame):
        raise KeyboardInterrupt('signal '+str(signum))
    signal.signal(signal.SIGTERM, stop)
    try:
        matrix.execute()
    except BaseException as error:
        matrix.stop_child()
        matrix.state('interrupted' if isinstance(error, KeyboardInterrupt) else 'failed', error=str(error))
        raise


if __name__ == '__main__':
    main()
