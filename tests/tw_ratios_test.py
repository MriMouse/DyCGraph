#!/usr/bin/env python3
"""CPU-only synthetic regression: occurrence validity, ratios and nested scales."""
from collections import Counter
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from prepare_tw_ratios import SIZES, write_ratio_picks


class TwRatiosTest(unittest.TestCase):
    def test_ratio_streams(self):
        with tempfile.TemporaryDirectory(prefix='tw-ratios-test-') as temp:
            root = Path(temp)
            backend = root / 'backend'
            subprocess.run(['g++', '-O2', '-std=c++17', '-Wall', '-Wextra',
                            str(ROOT / 'scripts/paper_data_stream.cpp'),
                            '-o', str(backend)], check=True)
            # Repeated edges and self-loops exercise occurrence multiplicity.
            total = 1_000_017
            source = root / 'source.txt'
            original = Counter()
            with source.open('w') as handle:
                for index in range(total):
                    edge = (index % 11, index % 13)
                    original[edge] += 1
                    handle.write(f'{edge[0]} {edge[1]}\n')
            rng = random.Random(20260926)
            chosen = rng.sample(range(total), 1_000_000)
            rng.shuffle(chosen)
            for percent in (100, 75, 25, 0, 50):
                folder = root / str(percent)
                folder.mkdir()
                picks = folder / 'picks.bin'
                write_ratio_picks(picks, chosen, percent)
                command = [str(backend), 'generate', str(source), 'text',
                           str(picks), str(folder), str(total), '20260926', '26']
                subprocess.run(command + [str(percent)], check=True,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                split = len(chosen) * percent // 100
                for suffix, batch_size in SIZES.items():
                    adds = batch_size * percent // 100
                    dels = batch_size - adds
                    insert_pool = Counter((i % 11, i % 13) for i in chosen[:adds*10])
                    delete_pool = Counter((i % 11, i % 13)
                                          for i in chosen[split:split+dels*10])
                    initial = Counter()
                    with (folder / f'input_{suffix}.txt.part').open() as handle:
                        for line in handle:
                            initial[tuple(map(int, line.split()))] += 1
                    self.assertEqual(initial, original - insert_pool)
                    state = initial.copy()
                    observed = {'a': Counter(), 'd': Counter()}
                    with (folder / f'update_{suffix}.txt.part').open() as handle:
                        for _ in range(10):
                            operations = Counter()
                            for _ in range(batch_size):
                                op, src, dst, weight = next(handle).split()
                                self.assertEqual(weight, '1')
                                edge = int(src), int(dst)
                                if op == 'd':
                                    self.assertGreater(state[edge], 0)
                                    state[edge] -= 1
                                else:
                                    self.assertEqual(op, 'a')
                                    state[edge] += 1
                                operations[op] += 1
                                observed[op][edge] += 1
                            self.assertEqual(operations['a'], adds)
                            self.assertEqual(operations['d'], dels)
                        self.assertEqual(handle.read(), '')
                    self.assertEqual(observed['a'], insert_pool)
                    self.assertEqual(observed['d'], delete_pool)
                    self.assertEqual(+state, original - delete_pool)
                if percent == 50:
                    default = root / 'default'
                    default.mkdir()
                    command[5] = str(default)
                    subprocess.run(command, check=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    for path in folder.glob('*.txt.part'):
                        self.assertEqual(path.read_bytes(), (default / path.name).read_bytes())


if __name__ == '__main__':
    unittest.main()
