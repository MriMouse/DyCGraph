#!/usr/bin/env python3
"""Serial I19 screening. Requires all 180 CPU replay batches to pass first."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT=Path(__file__).resolve().parents[1]


def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda:f.read(16<<20),b''):h.update(block)
    return h.hexdigest()


def free_gpu(gpu):
    processes=subprocess.check_output(['nvidia-smi','-i',str(gpu),'--query-compute-apps=pid','--format=csv,noheader'],text=True).strip()
    memory=subprocess.check_output(['nvidia-smi','-i',str(gpu),'--query-gpu=memory.used','--format=csv,noheader,nounits'],text=True).strip()
    if processes or int(memory)!=0:raise RuntimeError(f'GPU {gpu} occupied: pids={processes}, memory={memory} MiB')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--data',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--binary',type=Path,required=True)
    p.add_argument('--gpu',type=int,default=0)
    p.add_argument('--skip-scaling',dest='include_scaling',action='store_false')
    a=p.parse_args(); out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    lock=(ROOT/"build/i17_replay_gpu.lock").open("a")
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    data=a.data.resolve();binary=a.binary.resolve();binary_hash=sha(binary)
    manifests=[]
    for dataset in ['wiki','friendster']:
        # CPU log is complete only with 90 uniquely identified, successful batches.
        log=out/f'{dataset}_cpu.jsonl';records=[json.loads(line) for line in log.read_text().splitlines() if line.startswith('{')]
        rows=[r for r in records if r['type']=='batch']
        expected={(str(data/dataset/f'p{p:02}'/'ready.json'),b) for p in range(10,100,10) for b in range(10)}
        actual={(str(Path(r['manifest']).resolve()),r['batch']) for r in rows}
        if len(rows)!=90 or actual!=expected or any(r['forward_oracle']!='passed' or r['reverse_oracle']!='passed' for r in rows):raise RuntimeError(f'incomplete CPU gate: {dataset}')
        checked_base=None
        for percent in range(10,100,10):
            path=data/dataset/f'p{percent:02}'/'ready.json';m=json.loads(path.read_text())
            if m['status']!='ready':raise RuntimeError('dataset not ready')
            for key in ['base','updates','sizes']:
                spec=m[key];f=Path(spec['path'])
                if key=='base' and checked_base==(str(f),spec['sha256']):continue
                if sha(f)!=spec['sha256']:raise RuntimeError(f'input hash mismatch: {f}')
                if key=='base':checked_base=(str(f),spec['sha256'])
            manifests.append((dataset,percent,path,m))
    if a.include_scaling:
        scaling=[]
        for dataset in ['twitter','friendster']:
            cpu=json.loads((out/f'{dataset}_scaling_cpu_status.json').read_text())
            if cpu['state']!='complete' or cpu['batches']!=6:raise RuntimeError('scaling CPU gate incomplete')
            checked_base=None
            for size in [100,1000,10000]:
                path=out/f'{dataset}_{size}k_cpu_input.json';m=json.loads(path.read_text())
                for key in ['base','updates','sizes']:
                    spec=m[key];f=Path(spec['path'])
                    if key=='base' and checked_base==(str(f),spec['sha256']):continue
                    if sha(f)!=spec['sha256']:raise RuntimeError(f'scale input hash mismatch: {f}')
                    if key=='base':checked_base=(str(f),spec['sha256'])
                m['source_node']=28512093 if dataset=='twitter' else 0
                # Exact existing cohort, same source/cache/workers/NUMA as ratio screening.
                scaling.append((dataset+'_scaling',size*1000,path,m))
        manifests=scaling+manifests
    state=out/'gpu_status.json'
    def status(**kw):
        temp=state.with_suffix('.tmp');temp.write_text(json.dumps(dict(pid=os.getpid(),updated=time.time(),**kw),indent=2)+'\n');temp.replace(state)
    try:
        for dataset,percent,path,m in manifests:
            checksums=[]
            kinds=['performance'] if dataset.endswith('_scaling') else ['performance','correctness']
            n_batches=m['batches']
            for kind in kinds:
                stem=f'{dataset}_{percent//1000}k' if dataset.endswith('_scaling') else f'{dataset}_p{percent:02}'
                folder=out/f'{stem}_{kind}'
                if (folder/'status.json').exists():
                    old=json.loads((folder/'status.json').read_text())
                    if old.get('status')=='complete' and old.get('binary_sha256')==binary_hash and old.get('manifest_sha256')==sha(path):
                        checksums.append(old['checksums']);continue
                    raise RuntimeError(f'previous incomplete run needs inspection: {folder}')
                free_gpu(a.gpu)
                folder.mkdir(exist_ok=False)
                command=[str(binary),f'--graphfile={m["base"]["path"]}','--format=market_big','--weight_num=1','--weight=1',
                    f'--updatefile={m["updates"]["path"]}',f'--update_size={m["sizes"]["path"]}',f'--source_node={m["source_node"]}',
                    '--SEGMENT=512','--n_stream=3','--hybrid=0','--cache=2','--verbose=false',f'--sssp_max_batches={n_batches}',
                    '--sssp_cpu_partition_capacity=0','--sssp_print_checksum=true',f'--check={str(kind=="correctness").lower()}']
                env={k:v for k,v in os.environ.items() if not k.startswith('CG_')}
                settings=dict(CUDA_VISIBLE_DEVICES=str(a.gpu),CG_MUTATION_WORKERS='20',CG_REVERSE_SHARDS='64',CG_ORDERED_REPAIR='0',CG_COMM_METER='1' if kind=='correctness' else '0')
                env.update(settings)
                spec=dict(argv=command,cwd=str(ROOT),env=settings,binary_sha256=binary_hash,manifest_sha256=sha(path),manifest=str(path),numa_node=0,kind=kind,status='running')
                expected_checksum=None
                if dataset.endswith('_scaling'):
                    short='tw' if dataset.startswith('twitter') else 'fs'
                    ref=ROOT/'logs/performance_matrix_20260912/runs'/f'correctness.{short}_scaling.{percent//1000}k.current.c2.h0.w20.r0.attempt0.log'
                    reference=ref.read_text()
                    expected_checksum=re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)',reference)
                    if len(expected_checksum)!=1 or '[SSSP-BELLMAN-CHECK] passed' not in reference:
                        raise RuntimeError(f'invalid historical distance reference: {ref}')
                    spec['distance_reference_log']=str(ref)
                    spec['distance_reference_checksum']=expected_checksum
                (folder/'command.json').write_text(json.dumps(spec,indent=2)+'\n')
                status(state='running',dataset=dataset,percent=percent,kind=kind)
                start=time.monotonic();peak=0;resource_conflict=None
                with (folder/'run.log').open('w') as log:
                    proc=subprocess.Popen(['/usr/bin/time','-f','I19_MAX_RSS_KB=%M','numactl','--cpunodebind=0','--membind=0',*command],env=env,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
                    status(state='running',dataset=dataset,percent=percent,kind=kind,child_pid=proc.pid)
                    while proc.poll() is None:
                        sample=subprocess.run(['nvidia-smi','-i',str(a.gpu),'--query-gpu=memory.used','--format=csv,noheader,nounits'],capture_output=True,text=True)
                        if sample.returncode==0:peak=max(peak,int(sample.stdout.strip()))
                        # The loader can spend minutes on CPU before its first CUDA
                        # allocation. Yield our own process group if another user
                        # starts using the device during that interval or later.
                        apps=subprocess.run(['nvidia-smi','-i',str(a.gpu),'--query-compute-apps=pid','--format=csv,noheader'],capture_output=True,text=True)
                        foreign=[]
                        if apps.returncode!=0:
                            foreign=['process query failed']
                        else:
                            for value in apps.stdout.splitlines():
                                try:
                                    pid=int(value.strip())
                                    if os.getpgid(pid)!=proc.pid:foreign.append(pid)
                                except ProcessLookupError:
                                    pass
                                except (ValueError,PermissionError):
                                    foreign.append(value.strip())
                        if foreign and proc.poll() is None:
                            resource_conflict=foreign
                            os.killpg(proc.pid,signal.SIGTERM)
                            try:proc.wait(timeout=10)
                            except subprocess.TimeoutExpired:
                                os.killpg(proc.pid,signal.SIGKILL);proc.wait()
                            break
                        time.sleep(2)
                text=(folder/'run.log').read_text();times=re.findall(r'\[P0-TIMER\]\[SSSP\]\[batch (\d+)\] total_batch: ([\d.]+) ms',text)
                sums=re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)',text)
                valid=proc.returncode==0 and [int(b) for b,_ in times]==list(range(n_batches)) and len(sums)==1
                if kind=='correctness':
                    for label in ['DELETE-STAGE','BATCH']:
                        passed=re.findall(r'\[SSSP-'+label+r'-CHECK\]\[batch (\d+)\] passed',text)
                        valid=valid and [int(b) for b in passed]==list(range(n_batches))
                    valid=valid and '[SSSP-BELLMAN-CHECK] passed' in text
                valid=valid and not re.search(r'\[SSSP-(?:DELETE-STAGE|BATCH|BELLMAN)-CHECK\][^\n]*\bfailed\b',text)
                if expected_checksum is not None:
                    spec['distance_reference_match']=sums==expected_checksum
                    valid=valid and spec['distance_reference_match']
                rss=re.findall(r'I19_MAX_RSS_KB=(\d+)',text)
                spec.update(status='complete' if valid else 'failed',resource_conflict=resource_conflict,exit_code=proc.returncode,wall_s=time.monotonic()-start,paper_ms=sum(float(t) for _,t in times),batches=times,checksums=sums,rss_peak_kb=int(rss[-1]) if rss else None,gpu_sampled_peak_mib=peak,gpu_sample_interval_s=2)
                (folder/'status.json').write_text(json.dumps(spec,indent=2)+'\n')
                if not valid:raise RuntimeError(f'GPU gate failed: {folder}')
                checksums.append(sums)
            if len(checksums)==2 and checksums[0]!=checksums[1]:raise RuntimeError(f'performance/correctness checksum mismatch: {dataset} p{percent}')
        status(state='complete',runs=36+(6 if a.include_scaling else 0))
    except BaseException as e:
        status(state='blocked_or_failed',error=repr(e));raise

if __name__=='__main__':main()
