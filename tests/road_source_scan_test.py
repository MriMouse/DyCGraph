import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys

BINARY = sys.argv.pop(1) if len(sys.argv) > 1 else str(Path(__file__).resolve().parents[1] / 'build/road_source_scan')


class SourceScanTest(unittest.TestCase):
    def test_directed_cycle_ties_and_batch_coverage(self):
        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as directory:
            paths = [Path(directory) / name for name in ('graph', 'updates', 'sizes')]
            paths[0].write_text('1 2\n2 3\n3 2\n4 2\n5 6\n')
            paths[1].write_text('d 2 3 1\nd 3 2 1\n')
            paths[2].write_text('0 1\n0 1\n')
            result = json.loads(subprocess.check_output(
                [BINARY, *map(str, paths)], text=True))
            self.assertEqual(result['max_reachable'], 3)
            self.assertEqual(result['candidates'][0], {
                'source': 1, 'reachable': 3, 'deletion_records': 2, 'deletion_batches': 2})


if __name__ == '__main__':
    unittest.main()
