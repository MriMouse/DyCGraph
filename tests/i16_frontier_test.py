"""GPU snapshot fixtures with an idle check before each process."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from i16_repair_oracle_test import encode, shortest, INF, ORACLE
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from run_i16_road_validation import gpu_idle

fixtures = [(4096, [(v, v+1) for v in range(4095)]),
            (8, [(0, 1), (0, 2), (1, 3), (2, 3), (3, 4), (4, 3), (5, 6)]),
            (5, [(0, 1), (0, 1), (1, 2), (2, 3), (0, 4), (4, 3)]), (5, [])]
with tempfile.TemporaryDirectory() as directory:
    path, report = Path(directory)/'state.bin', Path(directory)/'report.json'
    for nodes, edges in fixtures:
        final = shortest(nodes, edges)
        affected = list(range(2 if nodes == 8 else 0, nodes))
        initial = final.copy()
        for vertex in affected:
            if vertex:
                initial[vertex] = INF
        path.write_bytes(encode(nodes, edges, affected, initial, final))
        if not gpu_idle():
            raise SystemExit('GPU 0 occupied; fixture queue stopped')
        subprocess.run([ORACLE, str(path), str(report)], env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0'},
                       check=True, timeout=300, stdout=subprocess.DEVNULL)
        result = json.loads(report.read_text())
        assert result['distance_mismatches'] == result['invalid_parents'] == 0
        time.sleep(3)
print('Four GPU frontier fixtures passed: distances and tight parents')
