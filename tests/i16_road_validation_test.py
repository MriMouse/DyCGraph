import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('road', ROOT / 'scripts/run_i16_road_validation.py')
road = importlib.util.module_from_spec(spec)
spec.loader.exec_module(road)

GOOD = '''[SSSP-DELETE-STAGE-CHECK][batch 0] passed source_ok=1 relaxable_edges=0 missing_tight_witnesses=0 distance_checksum=12
[SSSP-BATCH-CHECK][batch 0] passed source_ok=1 relaxable_edges=0 missing_tight_witnesses=0 invalid_parent_witness=5 distance_checksum=13
[C3-PUBLISH][batch 0] stale_version_rejects=0 gpu_cpu_hash_mismatches=0
[I14-BATCH][batch 0] updates=100000
[B2-GPU-REPAIR][batch 0] affected=0
[P0-TIMER][SSSP][batch 0] total_batch: 7.000 ms
[P0-ATTR][SSSP][batch 0] deletion=1 add=1 hotness=1 candidate=1 eviction=1 compact=1 cache_load=1 residual=0
[SSSP-BELLMAN-CHECK] passed reachable=1 relaxable_edges=0 missing_tight_witnesses=0
[SSSP-FINAL-CHECK] distance_checksum=13
Overall: Test passed
'''


class ParserTest(unittest.TestCase):
    def test_cpu_service_and_budget(self):
        cpu = GOOD.replace('[B2-GPU-REPAIR][batch 0] affected=0',
            '[I16-CPU-REPAIR][batch 0] affected=10 incoming_edges=20 internal_scans=15 service_ms=6 '
            'gather_ms=1 setup_ms=1 closure_ms=2 parent_ms=1 scatter_ms=1 '
            'temporary_device_bytes=100 avoided_incoming_device_bytes=200')
        self.assertTrue(road.parse_log(cpu, cpu_pq=True)['has_repair_work'])
        for bad in (cpu.replace('temporary_device_bytes=100', 'temporary_device_bytes=300'),
                    cpu.replace('scatter_ms=1', ''), cpu.replace('I16-CPU-REPAIR', 'B2-GPU-REPAIR')):
            with self.assertRaises(ValueError):
                road.parse_log(bad, cpu_pq=True)

    def test_three_batch_sequence(self):
        stage, final = GOOD.split('[SSSP-BELLMAN-CHECK]', 1)
        content = ''.join(stage.replace('[batch 0]', f'[batch {batch}]') for batch in range(3))
        content += '[SSSP-BELLMAN-CHECK]' + final
        self.assertEqual(len(road.parse_log(content, 3)['checks']['P0-TIMER']), 3)
        with self.assertRaises(ValueError):
            road.parse_log(content.replace('[batch 1]', '[batch 2]'), 3)

    def test_ten_batch_cpu_sequence(self):
        stage, final = GOOD.replace('[B2-GPU-REPAIR][batch 0] affected=0',
            '[I16-CPU-REPAIR][batch 0] affected=10 incoming_edges=20 internal_scans=15 service_ms=6 '
            'gather_ms=1 setup_ms=1 closure_ms=2 parent_ms=1 scatter_ms=1 '
            'temporary_device_bytes=100 avoided_incoming_device_bytes=200').split('[SSSP-BELLMAN-CHECK]', 1)
        content=''.join(stage.replace('[batch 0]',f'[batch {batch}]') for batch in range(10))
        content+='[SSSP-BELLMAN-CHECK]'+final.replace('distance_checksum=13','distance_checksum=13')
        self.assertEqual(len(road.parse_log(content,10,True)['checks']['I16-CPU-REPAIR']),10)

    def test_connected_suite_and_certificate(self):
        datasets = road.datasets_for('connected50')
        self.assertEqual(len(datasets), 2)
        self.assertTrue(all(sources == (1,) and stem.endswith('50p_100k')
                            for _, _, stem, sources in datasets))
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            data = root / '50p'
            data.mkdir()
            path = data / 'input.txt'
            report = {'state': 'passed', 'ratios': [{'percent': 50, 'active_vertices': 100,
                'source_reachable_vertices': 100, 'configs': [{'scale': 100000,
                'batches': [{'connectivity_preserved': True, 'effective_delete_pairs': 25000,
                    'effective_add_pairs': 25000, 'source_reachable_delete_pairs': 25000,
                    'source_reachable_add_pairs': 25000} for _ in range(10)]}]}]}
            raw = json.dumps(report).encode()
            (root / 'verification.json').write_bytes(raw)
            (root / 'checksums.json').write_text(json.dumps({
                'verification.json': {'sha256': hashlib.sha256(raw).hexdigest()},
                '50p/input.txt': {'sha256': 'expected', 'bytes': 10}}))
            self.assertEqual(road.validate_connected(data, [path], [{'sha256': 'expected', 'bytes': 10}])
                             ['source_reachable_vertices'], 100)
            with self.assertRaises(ValueError):
                road.validate_connected(data, [path], [{'sha256': 'changed', 'bytes': 10}])
            (root / 'verification.json').write_bytes(raw + b' ')
            with self.assertRaises(ValueError):
                road.validate_connected(data, [path], [{'sha256': 'expected', 'bytes': 10}])

    def test_no_work_and_parent_diagnostic(self):
        self.assertFalse(road.parse_log(GOOD)['has_repair_work'])

    def test_reject_incomplete_duplicate_failure(self):
        for bad in (GOOD.replace('[B2-GPU-REPAIR][batch 0] affected=0\n', ''),
                    GOOD + '[B2-GPU-REPAIR][batch 0] affected=0\n',
                    GOOD.replace('missing_tight_witnesses=0', 'missing_tight_witnesses=1'),
                    GOOD.replace('distance_checksum=13\nOverall', 'distance_checksum=14\nOverall'),
                    GOOD.replace('total_batch: 7.000', 'total_batch: 70.000'),
                    GOOD.replace('Overall: Test passed', ''),
                    GOOD + 'protocol_error=bad',
                    GOOD.replace('affected=0', 'affected=10')):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                road.parse_log(bad)


if __name__ == '__main__':
    unittest.main()
