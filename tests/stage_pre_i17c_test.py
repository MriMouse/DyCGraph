"""Matrix accounting, selection and failure regressions; optional real GPU smoke."""
import argparse
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from run_stage_pre_i17c import Matrix, parse_run, select, sha


def log(batches=2):
    return '\n'.join(f'[P0-TIMER][SSSP][batch {b}] total_batch: 10.000 ms\n'
        f'[P0-ATTR][SSSP][batch {b}] deletion=2 add=2 hotness=1 candidate=1 eviction=1 compact=1 cache_load=1 residual=1 total=10'
        for b in range(batches))+'\nOverall: Test passed\n'


class Contracts(unittest.TestCase):
    def test_complete_timer(self):
        self.assertEqual(parse_run(log(), 'current', False, 2)['paper_algorithm_ms'], 20)

    def test_truncated(self):
        for text in (log(1), log()+log(), log()+'\nMax iterations reached',
                     log()+'\nCUDA out of memory', log()+'\n[SSSP-BATCH-CHECK]',
                     log().replace('deletion=2', 'deletion=30')):
            with self.assertRaises(ValueError):
                parse_run(text, 'current', False, 2)

    def test_correctness_not_exit_success(self):
        with self.assertRaises(ValueError):
            parse_run(log(), 'current', True, 2)

    def test_equal_cache_choice(self):
        rows = [dict(side=s, cache=c, hybrid=h, paper_algorithm_ms=t, status='passed') for s, c, h, t in (
            ('current', 2, 0, 10), ('current', 2, 2, 12), ('original', 2, 1, 20),
            ('original', 2, 2, 18), ('current', 3, 0, 8), ('original', 3, 2, 14))]
        chosen = select(rows)
        self.assertEqual(chosen['cache'], 3)
        self.assertEqual(chosen['current']['hybrid'], 0)
        self.assertEqual(chosen['original']['hybrid'], 2)
        rows[-1]['status'] = 'failed'
        self.assertEqual(select(rows)['cache'], 2)

    def test_no_feasible_baseline(self):
        self.assertEqual(select([])['status'], 'no_common_configuration')

    def test_publication_rejected(self):
        with self.assertRaises(ValueError):
            parse_run(log()+'\n[C3-PUBLISH] stale_version_rejects=1 gpu_cpu_hash_mismatches=0', 'current', False, 2)

    def test_failures_never_get_speedup(self):
        with tempfile.TemporaryDirectory() as folder:
            m = Matrix(argparse.Namespace(directory=Path(folder), repeats=3, timeout=20))
            ds = {'name': 'fixture', 'group': 'primary', 'configs': {'100': {'actual_updates_per_batch': [100000]*10}}}
            m.manifest = {'datasets': [ds], 'selections': {'fixture': {'cache': 2}}}
            m.results = {'bad': {'phase': 'performance', 'dataset': 'fixture', 'size_k': 100, 'side': 'original',
                                  'cache': 2, 'status': 'failed', 'error': 'oom'}}
            m.report()
            rows = json.loads((Path(folder)/'comparison.json').read_text())
            row = next(r for r in rows if r['size_k'] == 100)
            self.assertEqual(row['status'], 'failed_or_partial')
            self.assertNotIn('original_over_current', row)
            m.lock.close()


def smoke(directory):
    directory.mkdir(parents=True, exist_ok=True)
    fixture = directory/'fixture'
    fixture.mkdir(exist_ok=True)
    edges = sorted({(u, (u+1) % 2048) for u in range(2048)} |
                   {((u+1) % 2048, u) for u in range(2048)})
    graph, updates, sizes = [fixture/(name+'.txt') for name in ('graph', 'updates', 'sizes')]
    graph.write_text(''.join(f'{u} {v}\n' for u, v in edges))
    updates.write_text('d 0 1 1\nd 1 0 1\na 0 2 1\na 2 0 1\n'
                       'd 0 2 1\nd 2 0 1\na 0 1 1\na 1 0 1\n')
    sizes.write_text('2 2\n2 2\n')
    ds = {'name': 'smoke', 'source': 0, 'group': 'fixture', 'configs': {'100': {
        'graph': str(graph.resolve()), 'updates': str(updates.resolve()), 'sizes': str(sizes.resolve()),
        'actual_updates_per_batch': [4, 4], 'batch_sizes': [[2, 2], [2, 2]]}}}
    matrix = Matrix(argparse.Namespace(directory=directory, repeats=1, timeout=180))
    matrix.manifest = {'datasets': [ds], 'files': {}, 'selections': {},
                      'binaries': {s: sha(directory/'bin'/s) for s in ('current', 'original')}}
    for side, modes in (('current', (0, 2)), ('original', (1, 2))):
        for h in modes:
            result = matrix.run(ds, 100, 'pilot', side, 2, h, batches=2)
            assert result['status'] == 'passed', result
    result = matrix.run(ds, 100, 'correctness', 'current', 2, 0, batches=2)
    assert result['status'] == 'passed', result
    print('4 performance smoke paths and current correctness passed')


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--smoke':
        smoke(Path(sys.argv[2]).resolve())
    else:
        unittest.main()
