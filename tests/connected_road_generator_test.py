import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GENERATOR = sys.argv.pop(1) if len(sys.argv) > 1 else str(ROOT / 'build/connected_road_generator')
VERIFIER = sys.argv.pop(1) if len(sys.argv) > 1 else str(ROOT / 'build/verify_connected_road_dataset')


class ConnectedRoadTest(unittest.TestCase):
    def test_all_ratios_and_valid_stateful_exchange(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'graph.mtx'
            # Dense core plus a disconnected component; include duplicate and
            # self-loop records to exercise normalization without fake roads.
            edges = [(u, v) for u in range(1, 251) for v in range(u + 1, 251)]
            edges += [(251, 252), (252, 253), (1, 2), (1, 1)]
            source.write_text('%%MatrixMarket matrix coordinate pattern symmetric\n'
                              f'253 253 {len(edges)}\n' + ''.join(f'{u} {v}\n' for u, v in edges))
            output = root / 'generated'
            command = [GENERATOR, str(source), str(output), 'test_road', '50,75,99', '1000', '10', '42', 'test']
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            subprocess.run([VERIFIER, str(output)], check=True, stdout=subprocess.DEVNULL)
            metadata = json.loads((output / 'metadata.json').read_text())
            self.assertEqual(metadata['self_loops_removed'], 1)
            self.assertEqual(metadata['duplicate_pairs_removed'], 1)
            original = {tuple(sorted(pair)) for pair in edges if pair[0] != pair[1]}
            for percent in (50, 75, 99):
                directory = output / f'{percent}p'
                graph = set(tuple(map(int, line.split())) for line in
                            (directory / f'input_test_road_{percent}p_1k.txt').read_text().splitlines())
                self.assertEqual(len(graph), 2 * (len(original) * percent // 100))
                self.assertTrue(all((v, u) in graph and tuple(sorted((u, v))) in original for u, v in graph))
                active = {v for edge in graph for v in edge}
                lines = (directory / f'update_test_road_{percent}p_1k.txt').read_text().splitlines()
                changed_distance_batches = 0
                def distances(edges):
                    outgoing = {}
                    for u, v in edges:
                        outgoing.setdefault(u, []).append(v)
                    result = {metadata['source_node']: 0}
                    queue = list(result)
                    for u in queue:
                        for v in outgoing.get(u, []):
                            if v not in result:
                                result[v] = result[u] + 1
                                queue.append(v)
                    return result
                for batch in range(10):
                    records = [line.split() for line in lines[batch * 1000:(batch + 1) * 1000]]
                    deletes = {(int(u), int(v)) for op, u, v, _ in records if op == 'd'}
                    adds = {(int(u), int(v)) for op, u, v, _ in records if op == 'a'}
                    self.assertEqual(len(deletes), 500)
                    self.assertEqual(len(adds), 500)
                    self.assertTrue(deletes <= graph)
                    self.assertFalse(adds & graph)
                    self.assertTrue(all(tuple(sorted(edge)) in original for edge in adds))
                    before = distances(graph)
                    graph -= deletes
                    changed_distance_batches += distances(graph) != before
                    # Independently traverse the deletion-only intermediate graph.
                    outgoing = {}
                    for u, v in graph:
                        outgoing.setdefault(u, []).append(v)
                    visited, queue = {metadata['source_node']}, [metadata['source_node']]
                    for u in queue:
                        for v in outgoing.get(u, []):
                            if v not in visited:
                                visited.add(v)
                                queue.append(v)
                    self.assertGreaterEqual(len(visited), 240)
                    self.assertEqual({v for edge in graph for v in edge}, active)
                    graph |= adds
                # Protecting the source BFS tree would make this identically zero.
                self.assertGreater(changed_distance_batches, 0)
            again = root / 'again'
            command[2] = str(again)
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
            for path in output.rglob('*.txt'):
                self.assertEqual(path.read_bytes(), (again / path.relative_to(output)).read_bytes())
            # Corrupt one operation without changing line counts or file syntax.
            update = output / '99p/update_test_road_99p_1k.txt'
            lines = update.read_text().splitlines()
            lines[0] = ('a' if lines[0][0] == 'd' else 'd') + lines[0][1:]
            update.write_text('\n'.join(lines) + '\n')
            self.assertNotEqual(subprocess.run([VERIFIER, str(output)], stdout=subprocess.DEVNULL,
                                               stderr=subprocess.DEVNULL).returncode, 0)

    def test_impossible_tree_budget_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / 'tree.mtx'
            source.write_text('%%MatrixMarket matrix coordinate pattern symmetric\n'
                              '1001 1001 1000\n' + ''.join(f'{v} {v+1}\n' for v in range(1, 1001)))
            result = subprocess.run([GENERATOR, str(source), str(root / 'out'), 'tree',
                                     '50', '1000', '10', '42', 'test'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('supports at most', result.stderr)


if __name__ == '__main__':
    unittest.main()
