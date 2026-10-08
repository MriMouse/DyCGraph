#!/usr/bin/env python3
"""Detached 12-run Current road benchmark with CG_ORDERED_REPAIR=0; integrate on success."""
import argparse
import csv
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
from run_road_communication_20261003 import ROOT, Runner, environment, save, sha

SOURCE = ROOT / 'paper/evaluation/raw/road_communication_connected_20261003'
DEFAULT = ROOT / 'paper/evaluation/raw/current_road_mode_off_20261006'


def read_csv(path):
    with path.open(newline='') as f:
        reader = csv.DictReader(f)
        return reader.fieldnames, list(reader)


def write_csv(path, fields, rows):
    tmp = path.with_suffix(path.suffix + '.tmp')
    with tmp.open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader(); writer.writerows(rows)
    tmp.replace(path)


def key(row):
    return tuple(row[k] for k in ('algorithm', 'dataset', 'scale'))


class CurrentRunner(Runner):
    def __init__(self, out):
        self.out = out
        self.rows = []
        self.identities = {}
        self.active = {}

    def record(self, row):
        self.rows.append(row)
        save(self.out / 'results.json', self.rows)
        write_csv(self.out / 'runs.csv', list(row), self.rows)

    def integrate(self):
        perf = ROOT / 'paper/evaluation/data/performmance.csv'
        report = ROOT / 'paper/evaluation/data/road_performance_summary_20261006.md'
        fields, rows = read_csv(perf)
        lookup = {key(r): r for r in self.rows}
        assert len(lookup) == 12 and len(self.rows) == 12
        extra = ['current_repeats', 'original_repeats', 'current_road_mode', 'current_result_status',
                 'current_road_mode_enabled_mean_total_10batch_ms', 'current_road_mode_enabled_repeats']
        fields += [f for f in extra if f not in fields]
        updated = []
        replacements = []
        for row in rows:
            row.setdefault('current_repeats', row['repeats_per_system'])
            row.setdefault('original_repeats', row['repeats_per_system'])
            row.setdefault('current_road_mode', 'enabled' if row['dataset'] in ('EU', 'USA') else 'disabled')
            row.setdefault('current_result_status', 'two_run_mean')
            row.setdefault('current_road_mode_enabled_mean_total_10batch_ms', '')
            row.setdefault('current_road_mode_enabled_repeats', '')
            if key(row) in lookup:
                result = lookup[key(row)]
                assert result['status'] == 'ok'
                row['current_road_mode_enabled_mean_total_10batch_ms'] = row['current_mean_total_10batch_ms']
                row['current_road_mode_enabled_repeats'] = row['current_repeats']
                row['current_mean_total_10batch_ms'] = f"{result['paper_algorithm_ms']:.4f}"
                row['current_repeats'] = '1'
                row['current_road_mode'] = 'disabled'
                row['current_result_status'] = 'single_run_provisional'
                row['repeats_per_system'] = 'mixed'
                row['original_over_current'] = f"{float(row['original_mean_total_10batch_ms']) / result['paper_algorithm_ms']:.4f}"
                row['validation_status'] = 'timing_complete_unvalidated'
                replacements.append(row)
            updated.append(row)
        assert len(replacements) == 12
        shutil.copy2(perf, self.out / 'performmance.before.csv')
        shutil.copy2(report, self.out / 'road_performance_summary.before.md')
        text = ['# 路网结果合并（2026-10-06）', '',
                '单位 ms，均为每遍 10 批总时间。Current 使用 CG_ORDERED_REPAIR=0 的单次结果；Origin 和 Ingress 为两遍算术平均。旧 Current 路网模式开启的两遍均值另列保留。', '',
                '总表 repeats_per_system=mixed，current_repeats=1、original_repeats=2；Current 标记 single_run_provisional。Ingress 沿用 reset + compute、不含 topology。收敛和计时完整不代表独立正确性验证已完成。', '',
                'Gunrock OOM 是用户指定的推定标记，本次未实测。通信实验保持暂停，未自动恢复。', '',
                '|算法|数据集|Batch size|Current（关闭，1遍）|Current（开启，2遍均值）|Origin（2遍均值）|Ingress（reset+compute，2遍均值）|Origin/Current（关闭）|',
                '|---|---|---|---:|---:|---:|---:|---:|']
        for r in replacements:
            text.append('|' + '|'.join(r[f] for f in ('algorithm', 'dataset', 'scale',
                'current_mean_total_10batch_ms', 'current_road_mode_enabled_mean_total_10batch_ms',
                'original_mean_total_10batch_ms', 'ingress_mean_total_10batch_ms', 'original_over_current')) + '|')
        write_csv(perf, fields, updated)
        report.write_text('\n'.join(text) + '\n')
        save(self.out / 'integration.json', dict(performance=str(perf), report=str(report),
             updated_rows=12, current_repeats=1, source=str(self.out / 'results.json'),
             old_current_preserved_in='current_road_mode_enabled_mean_total_10batch_ms',
             gunrock_status='assumed_oom_not_run'))

    def run(self):
        expected = json.loads((SOURCE / 'binaries.json').read_text())
        for algo in ('SSSP', 'BFS'):
            source = SOURCE / 'bin' / ('current_' + algo)
            if sha(source) != expected['current_' + algo]:
                raise ValueError('Frozen Current binary changed')
            shutil.copy2(source, self.out / 'bin' / source.name)
        save(self.out / 'binaries.json', {p.name: sha(p) for p in (self.out / 'bin').iterdir()})
        for item in json.loads((SOURCE / 'inputs.json').read_text()):
            if '/road_inputs/' in item['path']:
                path = Path(item['path'])
                if sha(path) != item['sha256']:
                    raise ValueError('Road input changed: ' + str(path))
                self.identities[str(path)] = dict(item, bytes=path.stat().st_size, mtime_ns=path.stat().st_mtime_ns)
        for algo, dataset, scale in itertools.product(('SSSP', 'BFS'), ('EU', 'USA'), ('1k', '10k', '100k')):
            raw = json.loads((SOURCE / f'road_{algo}_{dataset}_{scale}_current_r1.command.json').read_text())
            argv = raw['argv'][:]
            argv[2] = str(self.out / 'bin' / ('current_' + algo))
            env = environment(); env.update(raw['env_overrides']); env['CG_ORDERED_REPAIR'] = '0'
            assert raw['env_overrides']['CG_ORDERED_REPAIR'] == '1'
            assert env['CG_COMM_METER'] == env['CG_COMM_WINDOW'] == '0'
            self.active = dict(group='road_mode_off', algorithm=algo, dataset=dataset, scale=scale,
                               system='current', repeat=1, ordered_repair=0)
            log = self.out / f'{algo}_{dataset}_{scale}_current_r1.log'
            content, _, wall = self.child(argv, env, log, timeout=float('inf'))
            if re.search(r'Max iterations? reached|iteration_limit|stop=limit', content, re.I):
                raise RuntimeError('Nonconverged result: ' + str(log))
            self.record(dict(**self.active, status='ok', paper_algorithm_ms=self.timing(content, algo, 10),
                             wall_s=wall, log=str(log)))
        self.active = {}; self.state('integrating')
        self.integrate(); self.state('complete')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=DEFAULT)
    parser.add_argument('--worker', action='store_true')
    args = parser.parse_args(); out = args.out.resolve()
    if not args.worker:
        out.mkdir(parents=True, exist_ok=False); (out / 'bin').mkdir(); (out / 'scripts').mkdir()
        for name in (Path(__file__).name, 'run_road_communication_20261003.py'):
            text = (ROOT / 'scripts' / name).read_text()
            text = re.sub(r'^ROOT = .*$', 'ROOT = Path(' + repr(str(ROOT)) + ')', text, flags=re.M)
            (out / 'scripts' / name).write_text(text)
        save(out / 'protocol.json', dict(matrix='SSSP/BFS x EU/USA x 1k/10k/100k', repeats=1, batches=10,
             only_mode_change='CG_ORDERED_REPAIR: 1 -> 0', baseline=str(SOURCE),
             integrate_after_all_success=True, communication='paused; no automatic resume'))
        with (out / 'runner.log').open('w') as log:
            child = subprocess.Popen([sys.executable, '-u', str(out / 'scripts' / Path(__file__).name),
                '--out', str(out), '--worker'], cwd=ROOT, stdin=subprocess.DEVNULL,
                stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        (out / 'runner.pid').write_text(str(child.pid) + '\n')
        print(json.dumps(dict(pid=child.pid, output=str(out)))); return
    lock = (SOURCE / 'runner.lock').open('a'); fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit('Terminated'))
    runner = CurrentRunner(out)
    try:
        runner.state('validating_inputs'); runner.run()
    except BaseException:
        runner.state('failed', error=traceback.format_exc()); raise


if __name__ == '__main__':
    main()
