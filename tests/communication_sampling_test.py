import importlib.util
from pathlib import Path
import unittest

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

    def test_clipped_ramp(self):
        self.assertAlmostEqual(sampler.integral([[0, 0], [2, 2]], .5, 1.5, 1), 1024)

    def test_incomplete_and_short_windows(self):
        samples = [[i / 100, 1, 2] for i in range(101)]
        with self.assertRaises(ValueError):
            sampler.summarize(samples, 0, 1)
        self.assertEqual(sampler.summarize(samples, .1, .2)['quality'], 'insufficient_window_or_sampling')

    def test_sampling_gap(self):
        samples = [[0, 1, 2], [.05, 1, 2], [.1, 1, 2], [2, 1, 2], [2.1, 1, 2]]
        self.assertEqual(sampler.summarize(samples, .1, 2)['quality'], 'insufficient_window_or_sampling')

if __name__ == '__main__':
    unittest.main()
