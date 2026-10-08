import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import rerun_road_original_converged as road
import run_road_then_communication as queue


class QueueTest(unittest.TestCase):
    def test_guards_only_disable_caps_for_road_paths(self):
        for group in ('original_src', 'original_bfs_src'):
            before = (road.REF / group / 'include/framework/framework.cuh').read_text()
            after = road.patch_framework(before)
            changed = [(x, y) for x, y in zip(before.splitlines(), after.splitlines()) if x != y]
            self.assertEqual(len(changed), 4)
            for old, new in changed:
                self.assertIn('/road_inputs/EU/', new)
                self.assertIn('/road_inputs/USA/', new)
                self.assertIn('if (!(', new)
            with self.assertRaises(ValueError):
                road.patch_framework(after)

    def test_resume_preserves_completed_and_restarts_whole_partial_cell(self):
        with tempfile.TemporaryDirectory() as td:
            base = Path(td)
            source, out = base / 'source', base / 'out'
            source.mkdir(); out.mkdir()
            completed = dict(algorithm='SSSP', dataset='TW', scale='1k')
            pending = dict(algorithm='BFS', dataset='TW', scale='10k')
            rows = [dict(group='road', system='current'),
                    dict(group='communication', **completed),
                    dict(group='communication', **pending)]
            data = {'results.json': rows, 'inputs.json': [],
                    'communication_comparisons.json': [completed],
                    'direct_measurement_plans.json': {}, 'status.json': {}}
            for name, value in data.items():
                (source / name).write_text(json.dumps(value))
            (source / 'runs.csv').write_text('old rows')
            (source / 'comm_BFS_TW_10k_current_physical_c5_r1.log').write_text('interrupted')
            class FakeRunner:
                def __init__(self, out): pass
                def communications(self):
                    self.asserted_rows = self.rows
                    if self.rows != rows[:2]:
                        raise AssertionError(self.rows)
                def state(self, *args, **kwargs): pass
            class FakeModule:
                Runner = FakeRunner
            with patch.object(queue, 'module', return_value=FakeModule):
                queue.resume_communication(source, out)
            self.assertEqual(json.loads((source / 'results.json').read_text()), rows[:2])
            self.assertEqual(json.loads((out / 'communication_before_resume/results.json').read_text()), rows)
            self.assertEqual((out / 'communication_before_resume/comm_BFS_TW_10k_current_physical_c5_r1.log').read_text(), 'interrupted')
            plan = json.loads((out / 'communication_resume_plan.json').read_text())
            self.assertEqual(len(plan['restart_cells']), 11)


if __name__ == '__main__':
    unittest.main()
