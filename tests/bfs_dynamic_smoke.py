"""Opt-in GPU BFS regression: independent FIFO oracle after each update phase.

Run under numactl on spare CPUs; --gpu must name an idle physical GPU.
"""
import argparse
from collections import deque
import json
import os
from pathlib import Path
import re
import subprocess
import time


def oracle(edges, n):
    adj = [[] for _ in range(n)]
    for u, v in edges:
        adj[u].append(v)
    dist = [2**32 - 1] * n
    dist[0] = 0
    work = deque([0])
    while work:
        u = work.popleft()
        for v in adj[u]:
            if dist[v] == 2**32 - 1:
                dist[v] = dist[u] + 1
                work.append(v)
    value = 1469598103934665603
    for u, d in enumerate(dist):
        if d != 2**32 - 1:
            value ^= u + 0x9e3779b97f4a7c15 + (d << 6) + (d >> 2)
            value = value * 1099511628211 & (2**64 - 1)
    return dist, value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--gpu', type=int, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    n = 2048
    # Directed cycle, self-loop, equal-length witnesses, and long propagation.
    edges = {(u, (u + 1) % n) for u in range(n)}
    edges |= {(u, 1024) for u in range(1024)} | {(0, 0), (0, 2), (1, 3)}
    (out / 'graph').write_text(''.join(f'{u} {v}\n' for u, v in sorted(edges)))
    deleted = [(0, 1024), (20, 21), (700, 701), (1200, 1201)]
    added = [(1, 1900), (500, 1700), (900, 2000), (3, 1500)]
    expected, updates = [], []
    for dels, adds in [(deleted, added), (added, deleted), (deleted, added)]:
        for u, v in dels:
            edges.remove((u, v))
            updates.append(f'd {u} {v} 77\n')
        expected.append(('BFS-DELETE-STAGE-CHECK', oracle(edges, n)[1]))
        for u, v in adds:
            edges.add((u, v))
            updates.append(f'a {u} {v} 91\n')
        expected.append(('BFS-BATCH-CHECK', oracle(edges, n)[1]))
    (out / 'updates').write_text(''.join(updates))
    (out / 'sizes').write_text('4 4\n' * 3)
    results = []
    for schedule, maintenance, ordered in [('block', 'regular', '0'),
                                            ('ordered', 'large', '1'),
                                            ('thread', 'large', '0')]:
        # Let the previous CUDA process leave the utilization sampling window.
        time.sleep(2)
        # Check again before each invocation, never fall back to another GPU.
        state = subprocess.check_output([
            'nvidia-smi', '-i', str(args.gpu),
            '--query-gpu=memory.used,utilization.gpu', '--format=csv,noheader,nounits'],
            text=True).strip().split(',')
        if any(int(v.strip()) for v in state):
            raise RuntimeError(f'GPU {args.gpu} is occupied: {state}')
        env = {k: v for k, v in os.environ.items() if not k.startswith('CG_')}
        env.update(CUDA_VISIBLE_DEVICES=str(args.gpu), CG_INSERTION_SCHEDULE=schedule,
                   CG_BATCH_MAINTENANCE=maintenance, CG_ORDERED_REPAIR=ordered,
                   CG_MUTATION_WORKERS='2', CG_REVERSE_SHARDS='64', CG_COMM_METER='0')
        output = out / f'{schedule}.distances'
        command = [str(args.binary.resolve()), f'--graphfile={out / "graph"}',
                   f'--updatefile={out / "updates"}', f'--update_size={out / "sizes"}',
                   '--format=market_big', '--weight_num=1', '--weight=1',
                   '--source_node=0', '--SEGMENT=32', '--n_stream=3', '--hybrid=0',
                   '--cache=2', '--check=true', '--verbose=false', '--bfs_max_batches=3',
                   '--bfs_print_checksum=true', f'--output={output}']
        with (out / f'{schedule}.log').open('w') as log:
            subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                           check=True, timeout=180)
        text = (out / f'{schedule}.log').read_text()
        actual = [(tag, int(value)) for tag, value in re.findall(
            r'\[(BFS-DELETE-STAGE-CHECK|BFS-BATCH-CHECK)\][^\n]*distance_checksum=(\d+)', text)]
        assert actual == expected, (schedule, actual, expected)
        assert len(re.findall(r'\[BFS-(?:DELETE-STAGE|BATCH)-CHECK\][^\n]* passed ', text)) == 6
        rows = [list(map(int, line.split())) for line in output.read_text().splitlines()]
        distances, _ = oracle(edges, n)
        assert [row[1] for row in rows] == distances
        for node, distance, parent, _ in rows:
            if node and distance != 2**32 - 1:
                assert (parent, node) in edges and distances[parent] + 1 == distance
        results.append(dict(schedule=schedule, maintenance=maintenance, state='passed',
                            batch_ms=re.findall(r'\[P0-TIMER\]\[BFS\][^\n]*total_batch: ([\d.]+)', text)))
        (out / 'result.json').write_text(json.dumps(results, indent=2) + '\n')
    print('BFS: 18 phase checks, all final distances and parent witnesses passed')


if __name__ == '__main__':
    main()
