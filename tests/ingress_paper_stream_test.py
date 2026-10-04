#!/usr/bin/env python3
"""Independent per-batch oracle for the native Ingress paper adapter."""
import argparse
from collections import Counter
import hashlib
import heapq
import json
import os
from pathlib import Path
import random
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT.parent/'Ingress/build_paper/ingress'
OUT = ROOT/'paper/evaluation/raw/ingress_20261002/validation'


def reference(app, edges, n):
    adj = [[] for _ in range(n)]
    for (u, v), count in edges.items():
        adj[u].extend([v]*count)
    if app in ('bfs', 'sssp'):
        dist = [2**32-1]*n
        dist[0] = 0
        queue = [(0, 0)]
        while queue:
            cost, u = heapq.heappop(queue)
            if cost != dist[u]: continue
            for v in adj[u]:
                value = cost + (1 if app == 'bfs' else (u+v)%128+1)
                if value < dist[v]:
                    dist[v] = value
                    heapq.heappush(queue, (value, v))
        return dist, adj
    if app == 'cc':
        labels = list(range(n))
        for _ in range(n):
            prev = labels[:]
            for u in range(n):
                for v in adj[u]: labels[v] = min(labels[v], labels[u])
            if prev == labels: break
        return labels, adj
    rank = [0.15]*n
    for _ in range(1000):
        nxt = [0.15]*n
        for u in range(n):
            for v in adj[u]: nxt[v] += 0.85*rank[u]/len(adj[u])
        if max(abs(a-b) for a,b in zip(rank, nxt)) < 1e-13: break
        rank = nxt
    return nxt, adj


def fixture(seed):
    rng = random.Random(seed)
    n = 48
    edges = Counter((u, (u+1)%20) for u in range(20))
    edges.update([(0,1), (0,1), (3,3), (30,31), (31,30), (35,36)])
    if seed:
        edges.update((rng.randrange(40),rng.randrange(40)) for _ in range(100))
    initial = edges.copy()
    batches = []
    states = [initial]
    for b in range(10):
        dels = rng.sample(list(edges.elements()), min(7,len(list(edges.elements()))))
        for e in dels: edges[e] -= 1
        adds = [(rng.randrange(44),rng.randrange(44)) for _ in dels]
        edges.update(adds)
        ops = [('d',*e) for e in dels] + [('a',*e) for e in adds]
        rng.shuffle(ops)
        batches.append(ops)
        states.append(edges.copy())
    return n, initial, batches, states


def main():
    p=argparse.ArgumentParser(); p.add_argument('--binary',type=Path,default=BIN)
    args=p.parse_args(); OUT.mkdir(parents=True,exist_ok=True)
    completed=[]
    for seed in (0,7,91):
        n, initial, batches, states = fixture(seed)
        folder=OUT/f'fixture_{seed}'; folder.mkdir(exist_ok=True)
        (folder/'graph.v').write_text(''.join(f'{u} 0\n' for u in range(n)))
        (folder/'graph.base').write_text(''.join(f'{u} {v} {(u+v)%128+1}\n' for u,v in initial.elements()))
        (folder/'graph.update').write_text(''.join(f'{op} {u} {v} 1\n' for ops in batches for op,u,v in ops))
        (folder/'sizes.txt').write_text('7 7\n'*10)
        for app in ('bfs','sssp','cc','pagerank'):
            for threads in (1,20):
                output=folder/f'{app}_{threads}'; output.mkdir(exist_ok=True)
                cmd=['numactl','--cpunodebind=0',str(args.binary),'--logtostderr=1',
                     '--application='+app,'--efile='+str(folder/'graph.base'),
                     '--vfile='+str(folder/'graph.v'),'--efile_update='+str(folder/'graph.update'),
                     '--paper_stream_sizes='+str(folder/'sizes.txt'),'--out_prefix='+str(output),
                     '--paper_dump_batches=true','--app_concurrency='+str(threads),
                     '--sssp_source=0','--pr_d=0.85','--pr_tol=0.000001','--pr_mr=100','--cilk=false']
                log=output/'run.log'
                with log.open('w') as f:
                    proc=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=180)
                if proc.returncode: raise RuntimeError(f'{log}: rc={proc.returncode}')
                txt=log.read_text(); timers=re.findall(r'\[PAPER-BATCH\] batch=(\d+) paper_algorithm_ms=([\d.e+-]+)',txt)
                assert [int(b) for b,_ in timers]==list(range(10)),log
                for b,state in enumerate(states,-1):
                    ranks={int(v):(float(x),float(d)) for v,x,d in (line.split() for line in (output/f'batch_{b}.txt').read_text().splitlines())}
                    assert set(ranks)==set(range(n)),(app,b,'vertex set')
                    oracle,adj=reference(app,state,n)
                    if app!='pagerank':
                        assert [ranks[u][0] for u in range(n)]==oracle,(seed,app,threads,b,[(u,ranks[u][0],oracle[u]) for u in range(n) if ranks[u][0]!=oracle[u]])
                    else:
                        defect=[0.15-ranks[u][0]-ranks[u][1] for u in range(n)]
                        for u in range(n):
                            for v in adj[u]: defect[v]+=0.85*ranks[u][0]/len(adj[u])
                        assert max(abs(x) for x in defect)<1e-5,(seed,app,b,'residual invariant',max(abs(x) for x in defect))
                        assert max(abs(ranks[u][0]-oracle[u]) for u in range(n))<1e-4,(seed,app,b,'rank error')
                        assert max(abs(d) for x,d in ranks.values())<=1.01e-6,(seed,app,b,'convergence')
                completed.append(dict(seed=seed,algorithm=app,threads=threads,checked_states=11,log=str(log)))
                print('PASS',seed,app,threads,flush=True)
    report=dict(status='passed',binary=str(args.binary),binary_sha256=hashlib.sha256(args.binary.read_bytes()).hexdigest(),runs=completed,checked_states=sum(r['checked_states'] for r in completed))
    (OUT/'result.json').write_text(json.dumps(report,indent=2)+'\n')


if __name__=='__main__': main()
