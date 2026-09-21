#!/usr/bin/env python3
"""Run I19 CPU structure replay for ratio cohorts or existing size cohorts."""
import argparse
import json
from pathlib import Path
import subprocess
import time
from prepare_i19_ratios import digest, identity

ROOT=Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--dataset',choices=['wiki','friendster','twitter'],required=True)
    p.add_argument('--scaling',action='store_true')
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--data',type=Path,default=ROOT/'data/i19_ratios_20260914_v2')
    p.add_argument('--binary',type=Path,default=ROOT/'build/i19_topology_replay')
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    name=a.dataset+('_scaling' if a.scaling else '')
    if any((out/f'{name}_cpu{suffix}').exists() for suffix in ['.jsonl','.stderr','_status.json']):
        raise RuntimeError(f'CPU output already exists; preserving previous result: {name}')
    if a.scaling:
        root=ROOT/'data/i17_scaling_20260911'/a.dataset
        cohort=json.loads((root/'ready.json').read_text());manifests=[]
        base_spec=identity(root/'input_shared.txt');base_spec['sha256']=digest(root/'input_shared.txt')
        for size in [100,1000,10000]:
            stem=f'{a.dataset}_{size}k'
            adapter=dict(status='ready',nodes=cohort['nodes'],base_edges=cohort['base_edges'],
                batches=cohort['batches'],base=base_spec,
                updates=dict(path=str((root/f'update_{stem}.txt').resolve())),
                sizes=dict(path=str((root/f'stream_size_{stem}.txt').resolve())),
                provenance=str((root/'ready.json').resolve()),scope='adapter of existing I17 ready cohort; CPU oracle verifies actual updates')
            for key in ['updates','sizes']:
                file_path=Path(adapter[key]['path']);adapter[key]=dict(identity(file_path),sha256=digest(file_path))
            file=out/f'{stem}_cpu_input.json';file.write_text(json.dumps(adapter,indent=2)+'\n');manifests.append(file)
    else:
        root=a.data.resolve()/a.dataset
        if json.loads((root/'ready.json').read_text())['status']!='ready':raise RuntimeError('generation not ready')
        manifests=[root/f'p{ratio:02}/ready.json' for ratio in range(10,100,10)]
    command=['/usr/bin/time','-v','numactl','--cpunodebind=0','--membind=0',str(a.binary.resolve()),*map(str,manifests)]
    start=time.time();status=out/f'{name}_cpu_status.json'
    record=dict(command=command,state='running',started=start)
    status.write_text(json.dumps(record,indent=2)+'\n')
    with (out/f'{name}_cpu.jsonl').open('x') as log,(out/f'{name}_cpu.stderr').open('x') as err:
        result=subprocess.run(command,stdout=log,stderr=err)
    rows=[json.loads(line) for line in (out/f'{name}_cpu.jsonl').read_text().splitlines() if line.startswith('{')]
    rows=[r for r in rows if r['type']=='batch'];expected=6 if a.scaling else 90
    valid=result.returncode==0 and len(rows)==expected and all(r['forward_oracle']==r['reverse_oracle']=='passed' for r in rows)
    record.update(state='complete' if valid else 'failed',exit_code=result.returncode,batches=len(rows),wall_s=time.time()-start)
    status.write_text(json.dumps(record,indent=2)+'\n')
    if not valid:raise RuntimeError(f'CPU replay failed: {name}')

if __name__=='__main__':main()
