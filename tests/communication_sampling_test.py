import importlib.util
from pathlib import Path
import unittest
import time
import subprocess
import sys

path = Path(__file__).resolve().parents[1] / 'scripts/communication/sample_pcie.py'
spec = importlib.util.spec_from_file_location('sampler', path)
sampler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sampler)

class SamplingTest(unittest.TestCase):
    def test_constant_rate_directions_and_units(self):
        samples = [[i / 100, 100, 200] for i in range(301)]
        result = sampler.summarize(samples, .5, 2.5)
        self.assertAlmostEqual(result['gpu_tx_estimated_bytes'], 204800)
        self.assertAlmostEqual(result['gpu_rx_estimated_bytes'], 409600)
        self.assertEqual(result['quality'], 'coarse_estimate')
        self.assertAlmostEqual(result['pcie_total_estimated_bytes'], 614400)

    def test_clipped_ramp(self):
        self.assertAlmostEqual(sampler.integral([[0, 0], [2, 2]], .5, 1.5, 1), 1024)

    def test_incomplete_and_short_windows(self):
        samples = [[i / 100, 1, 2] for i in range(101)]
        with self.assertRaises(ValueError):
            sampler.summarize(samples, 0, 1)
        self.assertEqual(sampler.summarize(samples, .1, .2)['quality'], 'insufficient_window_or_sampling')
        self.assertIsNone(sampler.summarize(samples, .1, .2)['pcie_total_estimated_bytes'])

    def test_empty_and_sparse_samples(self):
        with self.assertRaises(ValueError):
            sampler.summarize([], 1, 2)
        result = sampler.summarize([[0, 1, 2], [3, 1, 2]], 1, 2)
        self.assertEqual(result['quality'], 'insufficient_window_or_sampling')
        self.assertIsNone(result['pcie_total_estimated_bytes'])

    def test_sampling_gap(self):
        samples = [[0, 1, 2], [.05, 1, 2], [.1, 1, 2], [2, 1, 2], [2.1, 1, 2]]
        self.assertEqual(sampler.summarize(samples, .1, 2)['quality'], 'insufficient_window_or_sampling')

class ContinuousSamplingTest(unittest.TestCase):
    def test_sampling_continues_during_blocking_supervisor_work(self):
        class FakeNVML:
            def __init__(self, index):
                self.closed = False
            def sample(self):
                return [time.monotonic(), 100, 200]
            def call(self, name):
                self.closed = True
        collector = sampler.ContinuousSampler(0, factory=FakeNVML, interval=.005).start()
        try:
            before = len(collector.samples)
            subprocess.run([sys.executable, '-c', 'import time; time.sleep(.2)'], check=True)
            self.assertGreater(len(collector.samples)-before, 5)
        finally:
            collector.stop()
        self.assertIsNone(collector.error)
        self.assertFalse(collector._thread.is_alive())

    def test_sampling_errors_are_not_silently_accepted(self):
        class BrokenNVML:
            def __init__(self, index):
                raise RuntimeError('mock NVML failure')
        collector = sampler.ContinuousSampler(0, factory=BrokenNVML)
        with self.assertRaisesRegex(RuntimeError, 'mock NVML failure'):
            collector.start()
        collector.stop()
        self.assertIsNotNone(collector.error)

if __name__ == '__main__':
    unittest.main()
