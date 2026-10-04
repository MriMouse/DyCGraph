#!/usr/bin/env python3
"""Independent small-graph PR check using historical executables, on idle GPU 1."""
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = Path(__file__).resolve().parent / 'pr_probe'
OUT.mkdir(exist_ok=True)
BASE = ROOT / 'paper/evaluation/raw/cc_pr_20260928'
n = 64
edges = {(u, (u + 1) % n) for u in range(n)} | {(u, (u + 7) % n) for u in range(0, n, 3)}
(OUT / 'graph').write_text(''.join(f'{u} {v}\n' for u, v in sorted(edges)))
updates = []
for b in range(10):
    old = (b, (b + 1) % n)
    new = (b, (b + 17) % n)
    edges.remove(old)
    edges.add(new)
    updates += [f'd {old[0]} {old[1]} 1\n', f'a {new[0]} {new[1]} 1\n']
(OUT / 'updates').write_text(''.join(updates))
(OUT / 'sizes').write_text('1 1\n' * 10)
adj = [[] for _ in range(n)]
for u, v in edges:
    adj[u].append(v)
reference = [0.] * n
for _ in range(10000):
    nxt = [.15] * n
    for u, targets in enumerate(adj):
        for v in targets:
            nxt[v] += .85 * reference[u] / len(targets)
    delta = sum(abs(a - b) for a, b in zip(reference, nxt))
    reference = nxt
    if delta < 1e-12:
        break
results = []
for side in ('current', 'original'):
    active = subprocess.check_output(['nvidia-smi', '-i', '1', '--query-compute-apps=pid',
                                      '--format=csv,noheader,nounits'], text=True).strip()
    if active:
        raise RuntimeError('GPU 1 occupied; no probe launched')
    env = {k: v for k, v in os.environ.items() if not k.startswith(('CG_', 'CUDA_'))}
    env.update(CUDA_VISIBLE_DEVICES='1', CG_MUTATION_WORKERS='20', CG_REVERSE_SHARDS='64',
               CG_MERGE_PUBLICATION_SOURCES='1', CG_BATCH_MAINTENANCE='regular', CG_COMM_METER='0')
    cmd = [str(BASE / f'{side}_build/hybrid_pr'), f'--graphfile={OUT / "graph"}',
           f'--updatefile={OUT / "updates"}', f'--update_size={OUT / "sizes"}',
           '--format=market_big', '--weight_num=1', '--weight=true', '--SEGMENT=1',
           '--n_stream=3', '--cache=2', f'--hybrid={0 if side == "current" else 2}',
           '--check=false', '--verbose=false', '--error=0.000001', '--pr_max_rounds=100']
    if side == 'current':
        cmd += ['--pr_max_batches=10', f'--output={OUT / "current.ranks"}']
    with (OUT / f'{side}.log').open('w') as f:
        done = subprocess.run(cmd, env=env, stdout=f, stderr=subprocess.STDOUT, timeout=90)
    text = (OUT / f'{side}.log').read_text()
    if side == 'current' and (OUT / 'current.ranks').exists():
        values = {int(row[0]): float(row[1]) for row in
                  (x.split() for x in (OUT / 'current.ranks').read_text().splitlines())}
    else:
        values = {int(u): float(x) for u, x in re.findall(r'v (\d+) data ([\d.eE+-]+) delta', text)}
    result = dict(side=side, exit_code=done.returncode, reported_vertices=len(values),
                  max_error=max((abs(x - reference[u]) for u, x in values.items()), default=None),
                  first20_l1_error=sum(abs(values[u] - reference[u]) for u in range(20))
                  if all(u in values for u in range(20)) else None,
                  termination=re.findall(r'\[PR-(?:CONVERGE|BATCH)\].*?stop=(\w+)', text), argv=cmd)
    results.append(result)
(OUT / 'result.json').write_text(json.dumps(dict(results=results, reference=reference), indent=2) + '\n')
print(json.dumps(results, indent=2))
