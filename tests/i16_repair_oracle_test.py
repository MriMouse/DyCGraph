import heapq
import json
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import unittest

ORACLE = sys.argv.pop(1)
INF = 2**32 - 1


def encode(nodes, edges, affected, initial, final):
    incoming, offsets = [], [0]
    for v in affected:
        incoming.extend(u for u, dst in edges if dst == v)
        offsets.append(len(incoming))
    ids = sorted(set(affected + incoming + [0]))
    data = struct.pack('<Q6I', 0x4931365354415445, 1, INF, 1, 0, 0, nodes)
    for values, fmt in ((affected, 'I'), (offsets, 'Q'), (incoming, 'I')):
        data += struct.pack('<Q', len(values)) + struct.pack('<' + fmt * len(values), *values)
    for distances in (initial, final):
        data += struct.pack('<Q', len(ids))
        for v in ids:
            data += struct.pack('<4I', v, distances[v], distances[v], INF)
    return data


def shortest(nodes, edges):
    outgoing = [[] for _ in range(nodes)]
    for u, v in edges:
        outgoing[u].append(v)
    distance = [INF] * nodes
    distance[0] = 0
    queue = [(0, 0)]
    while queue:
        d, u = heapq.heappop(queue)
        if d != distance[u]:
            continue
        for v in outgoing[u]:
            candidate = d + (u + v) % 128 + 1
            if candidate < distance[v]:
                distance[v] = candidate
                heapq.heappush(queue, (candidate, v))
    return distance


class OracleTest(unittest.TestCase):
    def test_graph_contracts_and_corruption(self):
        rng = random.Random(42)
        fixtures = [(120, [(v, v+1) for v in range(119)]),
                    (8, [(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (4, 3), (5, 6)]),
                    (5, [(0, 1), (0, 1), (1, 2), (2, 3), (0, 4), (4, 3)]),
                    (5, [])]
        fixtures += [(40, [(u, v) for u in range(40) for v in range(40)
                           if u != v and rng.random() < .06]) for _ in range(6)]
        with tempfile.TemporaryDirectory() as directory:
            path, report = Path(directory)/'state.bin', Path(directory)/'report.json'
            for nodes, edges in fixtures:
                final = shortest(nodes, edges)
                for affected in (list(range(nodes)), list(range(1, nodes)), list(range(2, nodes, 2))):
                    initial = final.copy()
                    for v in affected:
                        if v:
                            initial[v] = INF
                    raw = encode(nodes, edges, affected, initial, final)
                    path.write_bytes(raw)
                    result = subprocess.run([ORACLE, str(path), str(report)], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(report.read_text())['distance_mismatches'], 0)
            # INF and overflow must never wrap into finite distances.
            path.write_bytes(encode(4, [(1, 2)], [2], [0, INF-1, INF, INF], [0, INF-1, INF, INF]))
            self.assertEqual(subprocess.run([ORACLE, str(path), str(report)], stdout=subprocess.DEVNULL).returncode, 0)
            for bad in (raw[:-1], raw + b'x', b'wrong',
                        encode(3, [(0, 1)], [1, 1], [0, INF, INF], [0, 2, INF]),
                        encode(3, [(0, 1)], [1], [0, INF, INF], [0, 99, INF])):
                path.write_bytes(bad)
                self.assertNotEqual(subprocess.run([ORACLE, str(path), str(report)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, 0)


if __name__ == '__main__':
    unittest.main()
