#!/usr/bin/env python3
"""Detached queue: uncapped origin road rerun, then frozen communication continuation."""
import argparse
import fcntl
import itertools
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import traceback

from run_road_communication_20261003 import ROOT, module, save, sha
from rerun_road_original_converged import SOURCE

DEFAULT = ROOT / 'paper/evaluation/raw/road_origin_then_communication_20261005'


def audit(source):
    cells = []
    for a, d, k, rep in itertools.product(('SSSP', 'BFS'), ('EU', 'USA'), ('1k', '10k', '100k'), (1, 2)):
        commands = {s: json.loads((source / f'road_{a}_{d}_{k}_{s}_r{rep}.command.json').read_text())
                    for s in ('current', 'original')}
        options = {s: dict(x[2:].split('=', 1) for x in c['argv'][3:] if x.startswith('--') and '=' in x)
                   for s, c in commands.items()}
        for name in ('format', 'weight_num', 'weight', 'SEGMENT', 'n_stream', 'cache',
                     'check', 'verbose', 'graphfile', 'updatefile', 'update_size', 'source_node'):
            if options['current'][name] != options['original'][name]:
                raise ValueError(f'Unexplained road parameter mismatch: {a} {d} {k} {name}')
        if commands['current']['argv'][:2] != commands['original']['argv'][:2]:
            raise ValueError('NUMA mismatch')
        for name in ('CUDA_VISIBLE_DEVICES', 'OMP_NUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
            if commands['current']['env_overrides'][name] != commands['original']['env_overrides'][name]:
                raise ValueError('Resource mismatch: ' + name)
        if (options['current']['hybrid'], options['original']['hybrid']) != ('0', '2'):
            raise ValueError('Unexpected baseline execution modes')
        cells.append(dict(algorithm=a, dataset=d, scale=k, repeat=rep, shared_parameters='matched'))
    for name, expected in json.loads((source / 'binaries.json').read_text()).items():
        if name not in ('current_SSSP', 'current_BFS', 'original_SSSP', 'original_BFS',
                        'comm_original_SSSP', 'comm_original_BFS'):
            continue  # Calibration/converter executables are not used in either queued phase.
        if sha(source / 'bin' / name) != expected:
            raise ValueError('Frozen binary changed: ' + name)
    identities = json.loads((source / 'inputs.json').read_text())
    for item in identities:
        p = Path(item['path'])
        st = p.stat()
        if (st.st_size, st.st_mtime_ns) != (item['bytes'], item['mtime_ns']):
            raise ValueError('Input changed: ' + str(p))
        # Large communication base graphs were originally identified by stat only.
        if 'sha256' in item and sha(p) != item['sha256']:
            raise ValueError('Input hash changed: ' + str(p))
    comparisons = json.loads((source / 'communication_comparisons.json').read_text())
    return dict(road_commands=cells, frozen_binary_hashes='passed', input_identities='passed',
                completed_communication_cells=len(comparisons),
                ineligible_completed_cells=[{k: c[k] for k in ('algorithm', 'dataset', 'scale')}
                                           for c in comparisons if not c['eligible']],
                limitations=[
                    'Road convergence does not prove per-batch shortest-path correctness; origin check flag has no independent checker in this frozen application.',
                    'Origin BFS is unit-weight SSSP specialization, not an author-supplied native BFS implementation.',
                    'Origin is rerun later than current/ingress; no new interleaved three-system timing comparison is claimed.',
                    'Current hybrid=0 and origin hybrid=2 are their existing baseline modes, not an identical implementation.',
                    'Road dataset protects a spanning forest; deletion sampling is not uniform over all edges.',
                    'Communication checksum mismatch or poor sampling blocks ratios; checksum equality alone is not a per-batch proof.',
                    'NVML measures device-wide traffic; no precise zero-copy decomposition is claimed.',
                    'Large communication base identity retains the original size/mtime contract, not a cryptographic hash.'])


def resume_communication(source, out):
    frozen = module('frozen_road_resume', out / 'frozen_communication/run_road_communication_20261003.py')
    class ResumeRunner(frozen.Runner):
        def child(self, argv, env, log, sample=False, timeout=float('inf')):
            return super().child(argv, env, log, sample=sample, timeout=timeout)
    runner = ResumeRunner(source)
    runner.rows = json.loads((source / 'results.json').read_text())
    runner.identities = {x['path']: x for x in json.loads((source / 'inputs.json').read_text())}
    comparisons = json.loads((source / 'communication_comparisons.json').read_text())
    completed = {(c['algorithm'], c['dataset'], c['scale']) for c in comparisons}
    # Restart the whole interrupted cell so AB/BA pairs come from the same session.
    pending = {(a, d, k) for a, d, k in itertools.product(('SSSP', 'BFS'), ('TW', 'FS'), ('1k', '10k', '100k'))} - completed
    archive = out / 'communication_before_resume'
    archive.mkdir()
    for name in ('results.json', 'runs.csv', 'status.json', 'communication_comparisons.json', 'direct_measurement_plans.json'):
        shutil.copy2(source / name, archive / name)
    for a, d, k in pending:
        for p in source.glob(f'comm_{a}_{d}_{k}_*'):
            if p.is_file():
                shutil.copy2(p, archive / p.name)
    runner.rows = [r for r in runner.rows if not (r['group'] == 'communication' and
                   (r['algorithm'], r['dataset'], r['scale']) in pending)]
    save(source / 'results.json', runner.rows)
    save(out / 'communication_resume_plan.json', dict(restart_cells=sorted(pending),
         completed_cells_preserved=sorted(completed), archive=str(archive),
         policy='No rerun of completed cells; restart incomplete cells using existing shared cycle count; retain eligibility gates'))
    try:
        runner.communications()
        runner.active = {}
        runner.state('complete')
    except BaseException:
        runner.state('failed', error=traceback.format_exc())
        raise


def worker(source, out):
    # Hold the existing experiment lock throughout both phases.
    lock = (source / 'runner.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    child = None
    def status(state, **details):
        save(out / 'status.json', dict(state=state, pid=os.getpid(), updated_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), **details))
    def terminate(*_):
        if child is not None and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait()
        raise SystemExit('Queue terminated')
    signal.signal(signal.SIGTERM, terminate)
    try:
        status('auditing')
        save(out / 'fairness_audit.json', audit(source))
        command = [sys.executable, '-u', str(out / 'scripts/rerun_road_original_converged.py'),
                   '--source', str(source), '--out', str(out / 'road'), '--run']
        child = subprocess.Popen(command, cwd=ROOT, start_new_session=True)
        while True:
            status('road', child_pid=child.pid, phase_status=str(out / 'road/status.json'))
            try:
                code = child.wait(timeout=15)
                break
            except subprocess.TimeoutExpired:
                pass
        if code:
            raise RuntimeError(f'Origin phase failed: exit {code}; communication not started')
        status('communication', phase_status=str(source / 'status.json'))
        # Recheck the old experiment before consuming its completion records.
        audit(source)
        for file in (out / 'frozen_communication').glob('*.py'):
            if sha(file) != sha(source / 'scripts' / file.name):
                raise ValueError('Frozen communication helper changed: ' + file.name)
        resume_communication(source, out)
        status('complete')
    except BaseException:
        status('failed', error=traceback.format_exc())
        raise


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, default=SOURCE)
    p.add_argument('--out', type=Path, default=DEFAULT)
    p.add_argument('--worker', action='store_true')
    p.add_argument('--check', action='store_true', help='Read-only audit without launching')
    args = p.parse_args()
    source, out = args.source.resolve(), args.out.resolve()
    if args.check:
        print(json.dumps(audit(source), indent=2))
        return
    if args.worker:
        worker(source, out)
        return
    out.mkdir(parents=True, exist_ok=False)
    (out / 'scripts').mkdir()
    for name in ('run_road_then_communication.py', 'rerun_road_original_converged.py',
                 'run_road_communication_20261003.py', 'summarize_road_communication.py'):
        target = out / 'scripts' / name
        text = (ROOT / 'scripts' / name).read_text()
        text = re.sub(r'^ROOT = .*$', 'ROOT = Path(' + repr(str(ROOT)) + ')', text, flags=re.M)
        target.write_text(text)
    shutil.copytree(source / 'scripts', out / 'frozen_communication', ignore=shutil.ignore_patterns('__pycache__'))
    save(out / 'scripts_sha256.json', {str(f.relative_to(out)): sha(f)
         for folder in ('scripts', 'frozen_communication') for f in (out / folder).rglob('*.py')})
    with (out / 'runner.log').open('w') as log:
        proc = subprocess.Popen([sys.executable, '-u', str(out / 'scripts' / Path(__file__).name),
             '--source', str(source), '--out', str(out), '--worker'],
             cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    (out / 'runner.pid').write_text(str(proc.pid) + '\n')
    print(json.dumps(dict(pid=proc.pid, output=str(out))))


if __name__ == '__main__':
    main()
