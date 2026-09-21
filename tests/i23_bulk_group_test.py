"""Bulk source grouping: 8192-record batches and independent per-stage Dijkstra."""
import argparse
import heapq
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from run_i20_screen import gpu_free


def checksum(edges, n):
    adj = [[] for _ in range(n)]
    for u, v in edges:
        adj[u].append(v)
    distances = [2**32-1] * n
    distances[0] = 0
    queue = [(0, 0)]
    while queue:
        d, u = heapq.heappop(queue)
        if d != distances[u]:
            continue
        for v in adj[u]:
            value = d + (u+v) % 128 + 1
            if value < distances[v]:
                distances[v] = value
                heapq.heappush(queue, (value, v))
    result = 1469598103934665603
    for u, d in enumerate(distances):
        if d != 2**32-1:
            result ^= u + 0x9e3779b97f4a7c15 + (d << 6) + (d >> 2)
            result = result * 1099511628211 & (2**64-1)
    return result


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--binary', type=Path, default=ROOT / 'build/hybrid_sssp')
args = parser.parse_args()
gpu_free()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=False)
n = 8192
edges = {(u, (u+1) % n) for u in range(n)}
edges |= {(u, 4096) for u in range(4096)}
(out / 'graph').write_text(''.join(f'{u} {v}\n' for u,v in sorted(edges)))
# Each source has one deletion and one addition; sorting and bulk paths execute.
adds = [(u, 8191) for u in range(4096)]
dels = [(u, 4096) for u in range(4096)]
batches = [(dels, adds), (adds, dels), (dels, adds)]
updates = []
expected = []
for deleted, inserted in batches:
    for u,v in deleted:
        edges.remove((u,v))
        updates.append(f'd {u} {v} 1\n')
    expected.append(('SSSP-DELETE-STAGE-CHECK', checksum(edges,n)))
    for u,v in inserted:
        edges.add((u,v))
        updates.append(f'a {u} {v} 1\n')
    expected.append(('SSSP-BATCH-CHECK', checksum(edges,n)))
(out / 'updates').write_text(''.join(updates))
(out / 'sizes').write_text('4096 4096\n' * 3)
command = [str(args.binary.resolve()), f'--graphfile={out / "graph"}',
           f'--updatefile={out / "updates"}', f'--update_size={out / "sizes"}',
           '--format=market_big', '--weight_num=1', '--weight=1', '--source_node=0',
           '--SEGMENT=32', '--n_stream=3', '--hybrid=0', '--cache=2',
           '--sssp_cpu_partition_capacity=0', '--check=true', '--verbose=false',
           '--sssp_max_batches=3', '--sssp_print_checksum=true']
with (out / 'run.log').open('w') as log:
    env = {k:v for k,v in os.environ.items() if not k.startswith('CG_')}
    env.update(CUDA_VISIBLE_DEVICES='0', CG_INSERTION_SCHEDULE='block', CG_BULK_SOURCE_GROUPS='1',
               CG_MERGE_PUBLICATION_SOURCES='1', CG_PARALLEL_SOURCE_RADIX='0',
               CG_BATCH_MAINTENANCE='large', CG_MUTATION_WORKERS='20',
               CG_REVERSE_SHARDS='64', CG_ORDERED_REPAIR='0', CG_COMM_METER='0')
    subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                   check=True, timeout=180)
text = (out / 'run.log').read_text()
actual = [(tag, int(value)) for tag,value in re.findall(
    r'\[(SSSP-DELETE-STAGE-CHECK|SSSP-BATCH-CHECK)\][^\n]*distance_checksum=(\d+)',text)]
assert actual == expected, (actual, expected)
assert re.findall(r'\[I23-GROUP\]\[batch (\d+)\] bulk=(\d+)',text) == [('0','1'),('1','1'),('2','1')]
assert re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', text) == [str(expected[-1][1])]
assert len(re.findall(r'\[SSSP-(?:DELETE-STAGE|BATCH)-CHECK\][^\n]* passed ', text)) == 6
(out / 'result.json').write_text(json.dumps(dict(state='passed', expected=expected, actual=actual), indent=2)+'\n')
print('I23 bulk: six stage Dijkstra checks and final checksum passed')
