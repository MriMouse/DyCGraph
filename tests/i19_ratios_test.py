#!/usr/bin/env python3
"""Nested asymmetric cohorts, occurrence semantics, deterministic and fail-closed."""
from collections import Counter
import json
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
pool, replay = map(Path, sys.argv[1:])
with tempfile.TemporaryDirectory() as tmp:
    tmp=Path(tmp)
    source=tmp/'source.txt'; base=tmp/'base.txt'
    # Repeated source pairs overlap the base, plus enough distinct legal held-out pairs.
    full=[(i%19, i+20) for i in range(200)]
    full += full[:20]
    initial=full[::2]
    source.write_text('% fixture\n'+''.join(f'{s} {d}\n' for s,d in full))
    base.write_text(''.join(f'{s} {d}\n' for s,d in initial))
    def generate(out):
        return subprocess.run([sys.executable,str(ROOT/'scripts/prepare_i19_ratios.py'),
            '--dataset','wiki','--source',str(source),'--base',str(base),
            '--source-node','0','--batch-size','10','--batches','2',
            '--pool-binary',str(pool),'--output',str(out)],capture_output=True,text=True)
    one=tmp/'one'; two=tmp/'two'
    for out in [one,two]:
        result=generate(out)
        assert result.returncode==0,result.stderr
    # One occurrence permutation for both pools: operation salts must not
    # correlate neighboring source rows through XOR-related occurrence IDs.
    def rank(x):
        mask=(1<<64)-1
        x=(x+0x9e3779b97f4a7c15)&mask
        x=((x^(x>>30))*0xbf58476d1ce4e5b9)&mask
        x=((x^(x>>27))*0x94d049bb133111eb)&mask
        return x^(x>>31)
    for op in ['insert','delete']:
        rows=[list(map(int,line.split())) for line in (one/f'pool.{op}.tsv').read_text().splitlines()]
        ranks=[rank(row[2]^20260914) for row in rows]
        assert ranks==sorted(ranks)
    for p in range(10,100,10):
        m=json.loads((one/f'p{p:02}/ready.json').read_text())
        update=one/f'p{p:02}/updates.txt'
        assert update.read_bytes()==(two/f'p{p:02}/updates.txt').read_bytes()
        assert (one/f'p{p:02}/stream_size.txt').read_text()==f'{p//10} {10-p//10}\n'*2
        state=Counter(initial)
        lines=update.read_text().splitlines()
        for b in range(2):
            c=Counter()
            for line in lines[b*10:(b+1)*10]:
                op,s,d,w=line.split();pair=int(s),int(d);c[op]+=1
                if op=='d':assert state[pair]>0;state[pair]-=1
                else:assert state[pair]==0;state[pair]+=1
            assert c=={'a':p//10,'d':10-p//10}
            assert sum(state.values())==m['validation'][b]['graph_edges']
        if p<90:
            larger=(one/f'p{p+10:02}/updates.txt').read_text().splitlines()
            for b in range(2):
                lo=lines[b*10:(b+1)*10];hi=larger[b*10:(b+1)*10]
                assert set(x for x in lo if x[0]=='a') <= set(x for x in hi if x[0]=='a')
                assert set(x for x in hi if x[0]=='d') <= set(x for x in lo if x[0]=='d')
    run=subprocess.run([str(replay),*[str(one/f'p{p:02}/ready.json') for p in range(10,100,10)]],capture_output=True,text=True)
    assert run.returncode==0,run.stderr
    batches=[json.loads(x) for x in run.stdout.splitlines() if x.startswith('{') and json.loads(x)['type']=='batch']
    assert len(batches)==18
    assert all(b['forward_oracle']==b['reverse_oracle']=='passed' for b in batches)
    assert all(b['retired_capacity_edges']==0 for b in batches)
    # No silent random insertion fallback when the legal source pool is exhausted.
    source.write_text(base.read_text())
    failed=tmp/'failed';result=generate(failed)
    assert result.returncode!=0 and not list(failed.rglob('ready.json'))
    assert json.loads((failed/'status.json').read_text())['state']=='failed'
print('I19 ratio fixtures passed')
