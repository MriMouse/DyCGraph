"""Ordered queue regression: deferred seeds, stale membership, and convergence."""
import json
import fcntl
import argparse
import os
import random
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from i16_repair_oracle_test import encode, shortest, INF, ORACLE
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from run_i16_road_validation import gpu_idle
from run_i17a_sparse import validate

parser = argparse.ArgumentParser()
parser.add_argument('--sanitize', action='store_true')
args = parser.parse_args()
gpu_lock = (Path(__file__).resolve().parents[1]/'build/i17_replay_gpu.lock').open('a')
fcntl.flock(gpu_lock, fcntl.LOCK_EX)

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    # Every finite initial distance is a valid path but some are deliberately
    # worse than the final solution, including widely separated initial buckets.
    cases = [(512, [(i, i+1) for i in range(511)] + [(i, i+2) for i in range(510)]),
             (140, [(0, 1), (0, 129), (1, 129), (129, 130), (130, 1), (1, 2), (2, 130)]),
             (4, [])]
    rng = random.Random(1702)
    cases += [(64, [(u, v) for u in range(64) for v in range(64)
                    if u != v and rng.random() < .07]) for _ in range(4)]
    cases += [(256, [(0, v) for v in range(1, 256)] + [(v, 1) for v in range(2, 256)])]
    cases += [(2048, [(0, v) for v in range(1, 2048)] + [(v, 2047) for v in range(1, 2047)]),
              (4, []), (4, [])]
    completed = 0
    for index, (nodes, edges) in enumerate(cases):
        if args.sanitize and index not in (0, 8, 10):
            continue
        final = shortest(nodes, edges)
        initial = [INF]*nodes
        initial[0] = 0
        for u, v in edges:
            if u == 0:
                initial[v] = min(initial[v], (u+v)%128+1)
        if index == 0:
            for v in range(1, nodes):
                initial[v] = initial[v-1]+((v-1+v)%128+1)
        snapshot = root/'snapshot.bin'
        affected = list(range(nodes))
        if index >= 3:
            affected.remove(0)
        if index == len(cases)-1:
            affected = []
        snapshot.write_bytes(encode(nodes, edges, affected, initial, final))
        modes = ('compact', 'reuse') if args.sanitize else ('dense', 'sparse', 'device-control', 'compact', 'reuse')
        for mode in modes:
            while not gpu_idle():
                time.sleep(1)
            report = root/(mode+'.json')
            command = [ORACLE, str(snapshot), str(report), mode]
            if args.sanitize:
                command = ['compute-sanitizer', '--tool', 'memcheck', '--error-exitcode', '99']+command
            subprocess.run(command, check=True, timeout=120,
                           stdout=None if args.sanitize else subprocess.DEVNULL,
                           env={**os.environ, 'CUDA_VISIBLE_DEVICES': '0'})
            result = json.loads(report.read_text())
            reference = {'affected': len(affected), 'incoming_edges': sum(v in affected for _, v in edges)}
            validate(result, reference, mode)
            assert result['control_d2h_bytes'] < 1000000
            assert result['enqueued_vertices'] == result['processed_vertices']
            assert result['complete_service_ms'] >= result['service_ms']
            if mode in ('device-control', 'compact', 'reuse'):
                assert result['control_d2h_calls'] == result['iterations']
            if mode == 'reuse':
                assert result['host_cursor_bytes'] == 0
            if mode in ('compact', 'reuse'):
                assert result['deferred_copy_entries'] == result['pending_list_entries_total']-result['processed_vertices']
            bad = dict(result, bucket_mode='invalid')
            try:
                validate(bad, reference, mode)
            except ValueError:
                pass
            else:
                raise AssertionError('Wrong executor accepted')
            completed += 1
print(f'{completed} ordered replay cases passed (memcheck={args.sanitize}): deferred seeds, boundary, multi-block capacity, empty/unreachable and queue drain')
