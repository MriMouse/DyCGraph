#!/usr/bin/env python3
"""Rebuild frozen origin with road-only uncapped convergence; replay 24 road runs.
Default is a read-only plan. Pass --run to build and execute in the foreground.
"""
import argparse
import difflib
import itertools
import json
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import traceback

from run_road_communication_20261003 import ROOT, REF, Runner, environment, flags, save, sha

SOURCE = ROOT / 'paper/evaluation/raw/road_communication_connected_20261003'
DEFAULT = ROOT / 'paper/evaluation/raw/road_original_converged_20261005'


def patch_framework(text):
    # Match the original experiment's normalized road paths, used unchanged below.
    road = ('(FLAGS_graphfile.find("/road_inputs/EU/") != std::string::npos || '
            'FLAGS_graphfile.find("/road_inputs/USA/") != std::string::npos)')
    for condition, count in [('round >= max_rounds', 1),
                             ('current_rount >= max_rounds', 1),
                             ('m_running_info.current_round == 100 ', 2)]:
        old = 'if (' + condition + ')'
        if text.count(old) != count:
            raise ValueError('Frozen baseline iteration guard changed: ' + old)
        text = text.replace(old, 'if (!' + road + ' && (' + condition.strip() + '))')
    return text


class OriginRunner(Runner):
    def __init__(self, out, source, timeout):
        self.out, self.source, self.timeout = out, source, timeout
        self.active = {}
        self.rows = [r for r in json.loads((source / 'results.json').read_text())
                     if r['group'] == 'road' and r['system'] != 'original']
        self.identities = {}

    def prepare_original(self):
        binaries = {}
        for algo, group in [('SSSP', 'original_src'), ('BFS', 'original_bfs_src')]:
            source = REF / group
            target = self.out / (algo + '_src')
            target.mkdir()
            for name in ('include', 'src', 'samples'):
                shutil.copytree(source / name, target / name)
            shutil.copy2(source / 'CMakeLists.txt', target / 'CMakeLists.txt')
            (target / 'deps').symlink_to(source / 'deps', target_is_directory=True)
            framework = target / 'include/framework/framework.cuh'
            before = framework.read_text()
            after = patch_framework(before)
            framework.write_text(after)
            (self.out / (algo + '_convergence.diff')).write_text(''.join(
                difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                     fromfile=str(source / 'include/framework/framework.cuh'),
                                     tofile=str(framework))))
            # reserve() does not create elements: fix undefined indexed writes before timing.
            loader = target / 'include/framework/Loader.h'
            loader_before = loader.read_text()
            anchor = 'm_batch_size[pos_batch].first = add_size;\n        m_batch_size[pos_batch].second = del_size;'
            if loader_before.count(anchor) != 1:
                raise ValueError('Unexpected frozen loader layout')
            loader_after = loader_before.replace(anchor, 'm_batch_size.emplace_back(add_size, del_size);')
            loader.write_text(loader_after)
            (self.out / (algo + '_loader.diff')).write_text(''.join(
                difflib.unified_diff(loader_before.splitlines(True), loader_after.splitlines(True),
                                     fromfile=str(source / 'include/framework/Loader.h'), tofile=str(loader))))
            save(self.out / (algo + '_source_sha256.json'), {
                str(p.relative_to(target)): sha(p) for p in sorted(target.rglob('*')) if p.is_file()})
            build = self.out / (algo + '_build')
            self.active = dict(phase='build', algorithm=algo)
            self.state('building')
            with (self.out / ('build_' + algo + '.log')).open('w') as log:
                for cmd in [
                    ['cmake', '-S', str(target), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release',
                     '-DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.1',
                     '-DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.1/bin/nvcc',
                     '-DCMAKE_CXX_COMPILER=/usr/bin/g++-12', '-DCUDA_HOST_COMPILER=/usr/bin/gcc-12'],
                    ['cmake', '--build', str(build), '--target', 'hybrid_sssp', '-j', '4'],
                ]:
                    subprocess.run(cmd, check=True, env=environment(), stdout=log, stderr=subprocess.STDOUT)
            binary = self.out / 'bin' / ('original_' + algo)
            shutil.copy2(build / 'hybrid_sssp', binary)
            binaries[algo] = dict(path=str(binary), sha256=sha(binary),
                                  source=str(source), framework_sha256=sha(framework))
        save(self.out / 'binaries.json', binaries)

    def smoke(self):
        # A directed path deeper than the old 1000-round initialization cap.
        # Keep the road path predicate active; this diagnostic is outside the measurements.
        folder = self.out / 'smoke/road_inputs/EU'
        folder.mkdir(parents=True)
        (folder / 'graph').write_text(''.join(f'{i} {i+1}\n' for i in range(2047)) + '0 2047\n')
        (folder / 'sizes').write_text('1 1\n' * 10)
        (folder / 'updates').write_text(''.join(
            'd 0 2047 1\na 1 2047 1\n' if i % 2 == 0 else 'd 1 2047 1\na 0 2047 1\n'
            for i in range(10)))
        results = []
        for algo in ('SSSP', 'BFS'):
            raw = json.loads((self.source / f'road_{algo}_EU_1k_original_r1.command.json').read_text())
            argv = raw['argv'][:]
            env = environment()
            env.update(raw['env_overrides'])
            argv = flags(argv, graphfile=folder / 'graph', updatefile=folder / 'updates',
                         update_size=folder / 'sizes', source_node=0, SEGMENT=4, cache=0)
            for mode in ('capped', 'uncapped'):
                argv[2] = str((self.source if mode == 'capped' else self.out) / 'bin' / ('original_' + algo))
                self.active = dict(phase='smoke', algorithm=algo, mode=mode)
                content, _, _ = self.child(argv, env, self.out / f'smoke_{algo}_{mode}.log', timeout=600)
                reached = 'Max iterations reached' in content
                if reached != (mode == 'capped'):
                    raise RuntimeError('Long-path smoke did not distinguish capped/uncapped origin')
                self.timing(content, algo, 10)
                results.append(dict(algorithm=algo, mode=mode, hit_iteration_cap=reached,
                                    validation='termination and complete timers only; not a distance correctness proof'))
        save(self.out / 'smoke.json', results)

    def replay(self):
        for algo, dataset, scale, repeat in itertools.product(
                ('SSSP', 'BFS'), ('EU', 'USA'), ('1k', '10k', '100k'), (1, 2)):
            name = f'road_{algo}_{dataset}_{scale}_original_r{repeat}'
            raw = json.loads((self.source / (name + '.command.json')).read_text())
            argv = raw['argv'][:]
            argv[2] = str(self.out / 'bin' / ('original_' + algo))
            env = environment()
            env.update(raw['env_overrides'])
            self.active = dict(group='road', algorithm=algo, dataset=dataset,
                               scale=scale, system='original', repeat=repeat)
            log = self.out / (name + '.log')
            content, _, wall = self.child(argv, env, log, timeout=self.timeout)
            if 'Max iterations reached' in content:
                raise RuntimeError('Iteration cap still reached: ' + str(log))
            self.record(dict(**self.active, status='ok',
                             paper_algorithm_ms=self.timing(content, algo, 10),
                             wall_s=wall, log=str(log)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--out', type=Path, default=DEFAULT)
    parser.add_argument('--run', action='store_true', help='Build and execute; omitted means plan only')
    parser.add_argument('--timeout', type=float, default=0,
                        help='Per-run wall seconds; 0 disables timeout (default)')
    args = parser.parse_args()
    source, out = args.source.resolve(), args.out.resolve()
    if args.timeout < 0:
        parser.error('--timeout must be nonnegative')
    # Validate all replay commands and source guards even in plan-only mode.
    for group in ('original_src', 'original_bfs_src'):
        patch_framework((REF / group / 'include/framework/framework.cuh').read_text())
    for algo, dataset, scale, repeat in itertools.product(
            ('SSSP', 'BFS'), ('EU', 'USA'), ('1k', '10k', '100k'), (1, 2)):
        raw = json.loads((source / f'road_{algo}_{dataset}_{scale}_original_r{repeat}.command.json').read_text())
        for flag in ('graphfile', 'updatefile', 'update_size'):
            values = [v.split('=', 1)[1] for v in raw['argv'] if v.startswith('--' + flag + '=')]
            if len(values) != 1 or not Path(values[0]).is_file():
                raise ValueError('Missing input: ' + str(values))
            if flag == 'graphfile' and f'/road_inputs/{dataset}/' not in values[0]:
                raise ValueError('Graph path does not match road-only guard')
    print(f'24 origin runs: SSSP/BFS × EU/USA × 1k/10k/100k × 2; output={out}', flush=True)
    if not args.run:
        print('Plan only: no build or experiment started. Add --run to execute.')
        return
    out.mkdir(parents=True, exist_ok=False)
    (out / 'bin').mkdir()
    (out / 'scripts').mkdir()
    for name in ('summarize_road_communication.py', 'run_road_communication_20261003.py', Path(__file__).name):
        shutil.copy2(ROOT / 'scripts' / name, out / 'scripts' / name)
    save(out / 'protocol.json', dict(source=str(source), runs=24,
         change='Skip all four iteration caps only for /road_inputs/EU/ and /road_inputs/USA/; retain active-frontier convergence',
         timeout_seconds=args.timeout, other_systems='Existing road rows copied, no rerun',
         loader_fix='Replace reserve-only vector indexed writes with emplace_back; outside timing',
         baseline=str(REF), input_policy='Replay original command files and environment overrides'))
    signal.signal(signal.SIGTERM, lambda *_: sys.exit('Terminated'))
    runner = OriginRunner(out, source, args.timeout or float('inf'))
    try:
        # Check recorded road input identity before any build or execution.
        for item in json.loads((source / 'inputs.json').read_text()):
            if '/road_inputs/' in item['path']:
                path = Path(item['path'])
                if sha(path) != item['sha256']:
                    raise ValueError('Road input hash changed: ' + str(path))
                runner.identities[str(path)] = dict(item, bytes=path.stat().st_size,
                                                     mtime_ns=path.stat().st_mtime_ns)
        runner.prepare_original()
        runner.smoke()
        runner.replay()
        runner.active = {}
        runner.state('complete')
    except BaseException:
        runner.state('failed', error=traceback.format_exc())
        raise


if __name__ == '__main__':
    main()
