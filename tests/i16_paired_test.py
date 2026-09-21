import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from run_i16_paired import parse_performance


def fixture(cpu):
    lines=[]
    for batch in range(3):
        lines += [f'[P0-TIMER][batch {batch}] total_batch: 7.000 ms',
                  f'[P0-ATTR][batch {batch}] deletion=1 add=1 hotness=1 candidate=1 eviction=1 compact=1 cache_load=1 residual=0',
                  f'[I14-BATCH][batch {batch}] updates=100000',
                  f'[C3-PUBLISH][batch {batch}] stale_version_rejects=0 gpu_cpu_hash_mismatches=0']
        if cpu:
            lines += [f'[I16-CPU-REPAIR][batch {batch}] affected=10 incoming_edges=20 service_ms=1 gather_ms=0 setup_ms=0 '
                      'closure_ms=1 parent_ms=0 scatter_ms=0 temporary_device_bytes=100 avoided_incoming_device_bytes=200']
        else:
            lines += [f'[B2-GPU-REPAIR][batch {batch}] affected=10 incoming_edges=20 iterations=3 closure_ms=1']
    lines += ['[SSSP-FINAL-CHECK] final_reachable=100 checksum=enabled',
              '[SSSP-FINAL-CHECK] distance_checksum=42 parent_checksum=7']
    return '\n'.join(lines)


class TestPerformance(unittest.TestCase):
    def test_modes(self):
        for cpu in (False,True):
            self.assertEqual(parse_performance(fixture(cpu),cpu,42,100)['sum_batch_ms'],21)

    def test_reject_corruption(self):
        good=fixture(True)
        for bad in (good.replace('[batch 1]','[batch 2]'),good.replace('checksum=42','checksum=43'),
                    good.replace('total_batch: 7.000','total_batch: 70.000'),
                    good.replace('temporary_device_bytes=100','temporary_device_bytes=300'),
                    good.replace('updates=100000','updates=99999'),
                    good+'\n[I16-SNAPSHOT]',good+'\n[B2-GPU-REPAIR]',
                    good.replace('gpu_cpu_hash_mismatches=0','gpu_cpu_hash_mismatches=1')):
            with self.assertRaises(ValueError):
                parse_performance(bad,True,42,100)


if __name__=='__main__':
    unittest.main()
