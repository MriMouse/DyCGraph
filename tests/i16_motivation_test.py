import sys
import unittest
import tempfile
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from run_i16_motivation import batch_updates, compare_stages, details, profile_stats, summarize
from run_i16_paired import memory_sample, parse_performance
from i16_paired_test import fixture


class MotivationTest(unittest.TestCase):
    def test_actual_batch_sizes_override_filename(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'stream_size_twitter_100k.txt'
            path.write_text('10000 10000\n5000 7000\n1 2\n')
            self.assertEqual(batch_updates(path), [20000, 12000, 3])
        text = fixture(False)
        for i, count in enumerate((20000, 12000, 3)):
            text = text.replace(f'[I14-BATCH][batch {i}] updates=100000', f'[I14-BATCH][batch {i}] updates={count}')
        self.assertEqual(parse_performance(text, False, 42, 100, updates=[20000, 12000, 3])['sum_batch_ms'], 21)
        with self.assertRaises(ValueError):
            parse_performance(text, False, 42, 100)

    def test_capture_only_allowed_explicitly(self):
        text = fixture(False)+'\n[I16-SNAPSHOT]'
        self.assertEqual(parse_performance(text, False, 42, 100, capture=True)['sum_batch_ms'], 21)
        with self.assertRaises(ValueError):
            parse_performance(text, False, 42, 100)

    def test_profile_requires_all_event_tables(self):
        text = '\n'.join(f'Processing [x] with [/reports/{name}.py]...\n'
                         'Time (%),Total Time (ns),Name\n100,1000000,"kernel<T1, T2>"\n'
                         for name in ('cuda_api_sum', 'cuda_gpu_kern_sum', 'cuda_gpu_mem_time_sum'))
        self.assertEqual(profile_stats(text)['total_ms']['cuda_gpu_kern_sum'], 1)
        with self.assertRaises(ValueError):
            profile_stats(text.replace('cuda_gpu_kern_sum.py', 'unknown.py'))

    def test_profiler_target_and_foreign_process(self):
        with patch('run_i16_paired.subprocess.check_output', return_value='100, 50\n200, 70\n'), \
             patch('run_i16_paired.os.getpgid', return_value=999), \
             patch('run_i16_paired.process_has_token', side_effect=lambda pid, token: pid == 100 and token == 'owned'):
            self.assertEqual(memory_sample(1, 'owned'), (50, [200]))

    def test_detail_rejects_missing_duplicate_and_bad_total(self):
        service = {'batch': 0, 'affected': 2, 'gather_ms': 6, 'setup_ms': 9}
        result = {'checks': {'I16-CPU-REPAIR': [service]}}
        text = ('[I16-CPU-DETAIL][batch 0] nodes=10 union_vertices=4 ids_ms=1 allocation_ms=2 '
                'gather_transfer_ms=3 index_ms=2 boundary_ms=3 transpose_ms=4 repair_workers=1')
        self.assertEqual(len(details(text, result)['cpu_detail']), 1)
        for bad in ('', text+'\n'+text, text.replace('ids_ms=1', 'ids_ms=10'),
                    text.replace('repair_workers=1', 'repair_workers=20')):
            with self.assertRaises(ValueError):
                details(bad, result)

    def test_empty_repair_is_valid(self):
        text = fixture(True)
        lines = ['[I16-CPU-REPAIR][batch '+str(i)+'] affected=0' for i in range(3)]
        text = '\n'.join(line for line in text.splitlines() if '[I16-CPU-REPAIR]' not in line)
        result = parse_performance(text+'\n'+'\n'.join(lines), True, 42, 100)
        self.assertEqual(details(text, result)['cpu_detail'], [])

    def test_stage_mismatch_rejected(self):
        a = {'checks': {tag: [{'distance_checksum': 1}] for tag in
                      ('SSSP-DELETE-STAGE-CHECK', 'SSSP-BATCH-CHECK')}}
        b = {'checks': {tag: [{'distance_checksum': 2}] for tag in a['checks']}}
        with self.assertRaises(ValueError):
            compare_stages(a, b)

    def test_worker_bound_uses_full_batch(self):
        cpu = {'sum_batch_ms': 100, 'cpu_detail': [], 'checks': {'I16-CPU-REPAIR': [
            {'affected': 1, 'closure_ms': 20, 'service_ms': 80, 'gather_ms': 30, 'setup_ms': 30}]}}
        gpu = {'sum_batch_ms': 200, 'checks': {'B2-GPU-REPAIR': [
            {'affected': 1, 'iterations': 10, 'incoming_edges': 2}]}}
        result = summarize({'x.p0.0': gpu, 'x.p0.1': cpu, 'x.p0.2': cpu, 'x.p0.3': gpu}, 'x', 1)
        self.assertAlmostEqual(result['ideal_20way_pq_batch_speedup_bound'], 1/.81)
        self.assertEqual(result['cpu_over_gpu_pairs'], [.5, .5])


if __name__ == '__main__':
    unittest.main()
