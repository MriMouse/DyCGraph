"""CPU-only tests; no GPU, dataset scans, compilation, or experiment launch."""
import csv
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('full', ROOT / 'scripts/run_evaluation_full.py')
full = importlib.util.module_from_spec(spec)
spec.loader.exec_module(full)


class FullEvaluationTest(unittest.TestCase):
    def test_inverse_restores_graph_and_checks_cross_batch_dependencies(self):
        with tempfile.TemporaryDirectory() as d:
            graph = Path(d) / 'graph'
            graph.write_text('0 1\n1 2\n2 3\n')
            batches = [dict(d=[(0, 1, 1)], a=[(0, 2, 1)]),
                       dict(d=[(0, 2, 1)], a=[(0, 3, 1)])]
            cycle, audit = full.audit_cycle(graph, batches)
            self.assertEqual(len(cycle), 4)
            self.assertTrue(audit['restores_base_topology'])
            self.assertEqual(cycle[2]['d'], [(0, 3, 1)])

    def test_illegal_updates_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            graph = Path(d) / 'graph'
            graph.write_text('0 1\n1 2\n2 3\n')
            for batch in [dict(d=[(0, 2, 1)], a=[(0, 3, 1)]),
                          dict(d=[(0, 1, 1)], a=[(1, 2, 1)]),
                          dict(d=[(0, 1, 1)], a=[(0, 4, 1)]),
                          dict(d=[(0, 1, 1), (0, 1, 1)], a=[(0, 2, 1)])]:
                with self.subTest(batch=batch), self.assertRaises(ValueError):
                    full.audit_cycle(graph, [batch])
            graph.write_text('0 1\n0 1\n2 3\n')
            with self.assertRaises(ValueError):
                full.audit_cycle(graph, [dict(d=[(0, 1, 1)], a=[(0, 2, 1)])])

    def test_full_manifest_covers_each_matrix_cell_once(self):
        matrix = full.read_csv(full.MATRIX)
        tasks = full.plan(matrix, full.read_json(ROOT / 'logs/timing_modes_20260921/manifest.json'),
                          full.read_json(full.PARENT / 'manifest.json'),
                          full.read_json(full.ROADS / 'manifest.json'), 200)
        performance = [t for t in tasks if t['group'] == 'timing']
        communication = [t for t in tasks if t['group'] == 'communication']
        self.assertEqual(len(performance), len(matrix)*2)
        self.assertEqual(len({(t['dataset'],t['k'],t['cache'],t['side']) for t in performance}), len(performance))
        self.assertEqual(len(communication), 16)
        self.assertTrue(all(t['batches'] == 200 and t['env']['CG_COMM_METER'] == '0' for t in communication))
        for i in range(0, 16, 4):
            self.assertEqual([t['side'] for t in communication[i:i+4]], ['original','current','current','original'])
        self.assertTrue(all(t['env']['CG_COMM_WINDOW'] == '0' for t in performance))

    def test_means_require_both_repeats_and_sufficient_windows(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d)
            tasks = [dict(group='timing', dataset='tw', k=10, cache=2, side=s) for s in ('original','current')]
            rows = []
            for ds in ('tw','fs'):
                for k in (10,100):
                    for side in ('original','current'):
                        for repeat in range(2):
                            i = len(tasks)
                            tasks.append(dict(group='communication', dataset=ds, k=k, side=side))
                            folder = out / f'run_{i:03d}'
                            folder.mkdir()
                            (folder / 'physical_summary.json').write_text(json.dumps(dict(
                                quality='coarse_estimate', duration_s=10,
                                gpu_rx_estimated_bytes=100+100*repeat, gpu_tx_estimated_bytes=10)))
                            rows.append(dict(run_id=i, group='communication', dataset=ds, k=k, side=side,
                                status='ok', p0_total_s=1+repeat, common_checksum=['123'], log=str(folder/'run.log')))
            manifest = dict(tasks=tasks, communication_cycles=10, communication_min_window_s=5)
            full.export(out, rows, manifest)
            means = full.read_csv(out/'communication_means.csv')
            self.assertEqual(float(means[0]['pcie_total_mean_bytes']), 160)
            self.assertEqual(float(means[0]['p0_mean_s']), 1.5)
            self.assertTrue(full.read_json(out/'communication_comparisons.json')[0]['comparable'])
            # One missing repeat must not silently become a single-run mean.
            full.export(out, rows[1:], manifest)
            means = full.read_csv(out/'communication_means.csv')
            self.assertEqual(means[0]['pcie_total_mean_bytes'], 'NULL')
            self.assertFalse(full.read_json(out/'communication_comparisons.json')[0]['comparable'])
            # Too-short windows null the aggregate, even if NVML's own coarse gate passes.
            path = Path(rows[0]['log']).parent / 'physical_summary.json'
            data = full.read_json(path); data['duration_s'] = 2; path.write_text(json.dumps(data))
            full.export(out, rows, manifest)
            self.assertEqual(full.read_csv(out/'communication_means.csv')[0]['pcie_total_mean_bytes'], 'NULL')
            # Stable sampling alone does not establish cross-system agreement.
            data['duration_s'] = 10; path.write_text(json.dumps(data))
            rows[0]['common_checksum'] = ['456']
            full.export(out, rows, manifest)
            self.assertFalse(full.read_json(out/'communication_comparisons.json')[0]['comparable'])


if __name__ == '__main__':
    unittest.main()
