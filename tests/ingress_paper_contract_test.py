#!/usr/bin/env python3
"""Validate PR capped-state persistence, initial-cache reuse and CPU placement."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
from ingress_paper_stream_test import BIN, OUT, fixture, reference


def main():
    folder=OUT/'contracts_v2';folder.mkdir(parents=True,exist_ok=True)
    converter=BIN.parent/'prepare_ingress_paper'
    n,initial,batches,states=fixture(19)
    # Reserve isolated highest vertex exactly as baseline's dense universe.
    for s in states: s[(n-1,n-1)]+=1
    raw=folder/'raw.txt'
    raw.write_text(''.join(f'{u} {v}\n' for u,v in initial.elements()))
    prefix=folder/'graph'
    counts=json.loads(subprocess.check_output([str(converter),str(raw),str(prefix)],text=True))
    assert counts==dict(vertices=n,edges=sum(initial.values()))
    converted=[tuple(map(int,x.split())) for x in prefix.with_suffix('.base').read_text().splitlines()]
    assert converted==[(u,v,(u+v)%128+1) for u,v in initial.elements()]
    assert [int(x.split()[0]) for x in prefix.with_suffix('.v').read_text().splitlines()]==list(range(n))
    updates=folder/'updates.txt';sizes=folder/'sizes.txt'
    updates.write_text(''.join(f'{op} {u} {v} 1\n' for batch in batches for op,u,v in batch))
    sizes.write_text('7 7\n'*10)
    cache=folder/'serialization';cache.mkdir(exist_ok=True)
    summaries=[]
    for numa,cap in ((0,1),(1,1),(0,100)):
        output=folder/f'pr_numa{numa}_cap{cap}';output.mkdir(exist_ok=True)
        cmd=['numactl',f'--cpunodebind={numa}',str(BIN),'--logtostderr=1','--application=pagerank',
             '--efile='+str(prefix.with_suffix('.base')),'--vfile='+str(prefix.with_suffix('.v')),
             '--efile_update='+str(updates),'--paper_stream_sizes='+str(sizes),'--serialization_prefix='+str(cache),
             '--out_prefix='+str(output),'--paper_dump_batches=true','--app_concurrency=20',
             '--pr_d=0.85','--pr_tol=0.000001',f'--pr_mr={cap}']
        with (output/'run.log').open('w') as f:
            proc=subprocess.run(cmd,stdout=f,stderr=subprocess.STDOUT,timeout=180)
        assert proc.returncode==0,output
        text=(output/'run.log').read_text()
        if numa==1 or cap==100: assert 'Deserializing from' in text
        markers=re.findall(r'rounds=(\d+) stop=(\w+)',text)
        assert len(markers)==10
        if cap==1: assert all(int(r)==1 and s=='iteration_limit' for r,s in markers)
        for b,state in enumerate(states,-1):
            ranks={int(v):(float(x),float(d)) for v,x,d in (line.split() for line in (output/f'batch_{b}.txt').read_text().splitlines())}
            oracle,adj=reference('pagerank',state,n)
            defect=[0.15-ranks[u][0]-ranks[u][1] for u in range(n)]
            for u in range(n):
                for v in adj[u]: defect[v]+=0.85*ranks[u][0]/len(adj[u])
            assert max(abs(x) for x in defect)<1e-5,(numa,cap,b,'invariant')
            if cap==100: assert max(abs(ranks[u][0]-oracle[u]) for u in range(n))<1e-4
        summaries.append(dict(numa_node=numa,cap=cap,states=11,cache_reused=numa==1 or cap==100))
    report=dict(status='passed',binary_sha256=hashlib.sha256(BIN.read_bytes()).hexdigest(),converter_sha256=hashlib.sha256(converter.read_bytes()).hexdigest(),cases=summaries)
    (OUT/'contracts.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__': main()
