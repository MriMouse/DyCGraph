"""Opt-in GPU audit distinguishing hop distance from both SSSP weight rules.

Includes initial-only output, no-op, deletion-only, insertion-only, unreachable,
and reconnection phases. Reads every output distance and validates parent edges.
"""
import argparse
import fcntl
import heapq
import json
import os
from pathlib import Path
import re
import subprocess
import time

from bfs_dynamic_smoke import oracle


def weighted_distance(edges, cost, target):
    adj = [[] for _ in range(256)]
    for u, v in edges:
        adj[u].append(v)
    distances = [2**32-1] * 256
    distances[0] = 0
    work = [(0, 0)]
    while work:
        value, u = heapq.heappop(work)
        if value != distances[u]:
            continue
        for v in adj[u]:
            candidate = value + cost(u, v)
            if candidate < distances[v]:
                distances[v] = candidate
                heapq.heappush(work, (candidate, v))
    return distances[target]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--gpu', type=int, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    lock = open(f'/tmp/cggraph_bfs_gpu{args.gpu}.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    n, target = 256, 127
    # BFS chooses 0->100->127 (2 hops); synthetic SSSP chooses 0->1->2->127 (8).
    # Explicit input weights on the latter path are 1,1,1, hence weighted distance 3.
    original = {(0,100), (100,127), (0,1), (1,2), (2,127)}
    original |= {(u,u) for u in range(n)}
    cost = lambda u,v: 1000 if (u,v) in {(0,100),(100,127)} else 1
    initial, _ = oracle(original,n)
    assert initial[target] == 2
    assert weighted_distance(original, lambda u,v: (u+v)%128+1,target) == 8
    assert weighted_distance(original, cost,target) == 3
    # weight_num=0 actually parses the third graph column (no unit-weight loader shortcut).
    (out/'graph').write_text(''.join(f'{u} {v} {cost(u,v)}\n' for u,v in sorted(original)))
    batches = [([], []), ([(100,127)], []), ([], [(0,127)]),
               ([(0,127),(2,127)], []), ([], [(100,127)])]
    expected, stages, updates = [], [], []
    edges = set(original)
    for deleted, added in batches:
        for u,v in deleted:
            edges.remove((u,v)); updates.append(f'd {u} {v} 777\n')
        dist, value = oracle(edges,n)
        expected.append(('BFS-DELETE-STAGE-CHECK',value)); stages.append(dist[target])
        for u,v in added:
            edges.add((u,v)); updates.append(f'a {u} {v} 999\n')
        dist, value = oracle(edges,n)
        expected.append(('BFS-BATCH-CHECK',value)); stages.append(dist[target])
    assert stages == [2,2,3,3,3,1,2**32-1,2**32-1,2**32-1,2], stages
    (out/'updates').write_text(''.join(updates))
    (out/'sizes').write_text(''.join(f'{len(a)} {len(d)}\n' for d,a in batches))
    rows = []
    for name, count, maintenance, road in [('initial',0,'regular',0),
            ('regular',5,'regular',0), ('large',5,'large',0), ('road_large',5,'large',1)]:
        time.sleep(2)
        state = subprocess.check_output(['nvidia-smi','-i',str(args.gpu),
            '--query-gpu=memory.used,utilization.gpu','--format=csv,noheader,nounits'],text=True)
        if any(int(x.strip()) for x in state.strip().split(',')):
            raise RuntimeError(f'GPU {args.gpu} occupied: {state}')
        env = {k:v for k,v in os.environ.items() if not k.startswith('CG_')}
        env.update(CUDA_VISIBLE_DEVICES=str(args.gpu), CG_MUTATION_WORKERS='2',
                   CG_REVERSE_SHARDS='64', CG_BATCH_MAINTENANCE=maintenance,
                   CG_ORDERED_REPAIR=str(road), CG_COMM_METER='0')
        output = out/f'{name}.out'
        command = [str(args.binary.resolve()), f'--graphfile={out/"graph"}',
                   f'--updatefile={out/"updates"}', f'--update_size={out/"sizes"}',
                   '--format=market_big', '--weight_num=0', '--weight=true', '--source_node=0',
                   '--SEGMENT=32', '--n_stream=3', '--hybrid=0', '--cache=2',
                   '--check=true', '--verbose=false', '--bfs_print_checksum=true',
                   f'--bfs_max_batches={count}', f'--output={output}']
        with (out/f'{name}.log').open('w') as log:
            subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=90)
        text = (out/f'{name}.log').read_text()
        actual = [(tag,int(value)) for tag,value in re.findall(
            r'\[(BFS-DELETE-STAGE-CHECK|BFS-BATCH-CHECK)\][^\n]*distance_checksum=(\d+)',text)]
        assert actual == (expected if count else []), (name,actual,expected)
        assert '[BFS-PARENT-CHECK] passed invalid_parent_witness=0' in text
        assert len(re.findall(r'\[BFS-(?:DELETE-STAGE|BATCH)-CHECK\][^\n]* passed ',text)) == 2*count
        distances, final_checksum = oracle(edges if count else original,n)
        states = [list(map(int,line.split())) for line in output.read_text().splitlines()]
        assert len(states)==n and all(len(row)==4 for row in states)
        assert [row[0] for row in states]==list(range(n))
        assert [row[1] for row in states]==distances
        final_edges = edges if count else original
        for u,d,parent,buffer in states:
            if u and d != 2**32-1:
                assert (parent,u) in final_edges and distances[parent]+1==d
        assert re.findall(r'\[BFS-FINAL-CHECK\] distance_checksum=(\d+)',text)==[str(final_checksum)]
        rows.append(dict(name=name,state='passed',phase_checks=2*count,
                         target=target,output_target=states[target],
                         expected_phase_target_distances=stages if count else [],
                         initial_bfs_hops=2,initial_synthetic_sssp_distance=8,
                         initial_input_weighted_distance=3))
        (out/'result.json').write_text(json.dumps(rows,indent=2)+'\n')
    print('PASS: initial-only and 30 incremental phases use BFS hops; all output rows/parents match FIFO BFS')


if __name__=='__main__':
    main()
