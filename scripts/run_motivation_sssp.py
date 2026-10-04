#!/usr/bin/env python3
"""Frozen TW/FS 100K SSSP motivation experiment: isolated probes, two repeats per mode."""
import argparse
import csv
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import statistics
import subprocess
import sys
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent/'motivation'))
from prepare import instrument

ROOT=Path(__file__).resolve().parents[1]
REFERENCE=ROOT/'paper/evaluation/raw/sssp_bfs_20260927'
DEFAULT_OUT=ROOT/'paper/evaluation/raw/motivation_sssp_20261003'
SOURCES={'TW':28512093,'FS':0}
COUNT_FIELDS=['vertices','updated_sources','relocated_sources','relocated_untouched_sources','descriptor_bytes','invalidated_vertices','initial_insertion_worklist','seeds_prebatch','seeds_preinsert']

def save(path, value):
    tmp=path.with_suffix(path.suffix+'.tmp')
    tmp.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n'); tmp.replace(path)

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda:f.read(8<<20),b''): h.update(chunk)
    return h.hexdigest()

def write_csv(path, rows):
    if not rows: return
    tmp=path.with_suffix('.tmp')
    with tmp.open('w',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    tmp.replace(path)

def clean_env():
    env={k:v for k,v in os.environ.items() if not k.startswith(('CG_','CUDA_')) and k not in ('OPT','LD_PRELOAD')}
    env['CUDA_VISIBLE_DEVICES']='0'
    return env

def prepare(out):
    manifest=out/'sources.json'
    if manifest.exists(): return
    info={}
    for side,source in [('current',ROOT),('original',REFERENCE/'original_src')]:
        dst=out/(side+'_src')
        if dst.exists(): raise RuntimeError(f'Incomplete source freeze: {dst}; use a fresh --out')
        dst.mkdir()
        for name in ['CMakeLists.txt','include','src','samples','deps','tests']:
            p=source/name
            if not p.exists(): continue
            if p.is_dir(): shutil.copytree(p,dst/name,ignore=shutil.ignore_patterns('.git','__pycache__'))
            else: shutil.copy2(p,dst/name)
        patch=instrument(dst,side); (out/(side+'_motivation.patch')).write_text(patch)
        info[side]={'source':str(source),'sha256':{str(p.relative_to(dst)):sha(p) for p in sorted(dst.rglob('*')) if p.is_file()}}
    (out/'current_worktree.patch').write_bytes(subprocess.check_output(['git','diff','HEAD'],cwd=ROOT))
    (out/'current_git_head.txt').write_bytes(subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT))
    save(manifest,info)

def build(out):
    for side in ('current','original'):
        save(out/'status.json',dict(state='building',system=side,pid=os.getpid()))
        with (out/(side+'_build.log')).open('w') as log:
            subprocess.run(['cmake','-S',str(out/(side+'_src')),'-B',str(out/(side+'_build')),
                '-DCMAKE_BUILD_TYPE=Release','-DCG_MOTIVATION_METER=ON',
                '-DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.1','-DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.1/bin/nvcc',
                '-DCMAKE_CXX_COMPILER=/usr/bin/g++-12','-DCUDA_HOST_COMPILER=/usr/bin/gcc-12'],check=True,stdout=log,stderr=subprocess.STDOUT,env=clean_env())
            subprocess.run(['cmake','--build',str(out/(side+'_build')),'--target','hybrid_sssp','-j','4'],check=True,stdout=log,stderr=subprocess.STDOUT,env=clean_env())
    identity={s:sha(out/(s+'_build/hybrid_sssp')) for s in ('current','original')}
    old=out/'binaries.json'
    if old.exists() and json.loads(old.read_text())!=identity: raise RuntimeError('Frozen binaries changed; use a fresh --out')
    save(old,identity)

def parse_log(content, mode, batches=10):
    if re.search(r'CUDA error|cudaError|out of memory|Test failed|protocol_error|Max iterations reached',content,re.I):
        raise ValueError('Runtime failure or non-convergence in log')
    records=[json.loads(line.split('[MOTIVATION] ',1)[1]) for line in content.splitlines() if '[MOTIVATION] ' in line]
    if [r['batch'] for r in records]!=list(range(batches)) or any(r['mode']!=mode for r in records):
        raise ValueError('Missing, duplicate, out-of-order, or wrong-mode motivation batches')
    timers=re.findall(r'\[P0-TIMER\]\[SSSP\]\[batch (\d+)\] total_batch: ([\d.]+)',content)
    if [int(i) for i,t in timers]!=list(range(batches)): raise ValueError('Incomplete P0 timers')
    for r,(_,t) in zip(records,timers):
        r['paper_batch_ms']=float(t)
        if mode=='timing' and not 0<=r['rebuild_ms']<=r['compute_ms']: raise ValueError('Invalid rebuild/compute timing')
        if mode=='counts' and any(r[f]<0 for f in COUNT_FIELDS): raise ValueError('Invalid count')
        # Never present an unmeasured metric as a measured zero.
        if mode=='timing':
            for field in COUNT_FIELDS:
                if field!='vertices': r[field]=None
        else:
            for field in ('compute_ms','rebuild_ms','rebuild_groups'): r[field]=None
    return records

def summarize(out):
    runs=[json.loads(p.read_text()) for p in sorted(out.glob('SSSP_*.result.json'))]
    flat=[]
    for run in runs:
        if run['status']=='ok':
            for batch in run['batches']:
                flat.append(dict(dataset=run['dataset'],system=run['system'],repeat=run['repeat'],**batch))
    write_csv(out/'batches.csv',flat)
    rows=[]
    for dataset in SOURCES:
        for side in ('current','original'):
            row=dict(dataset=dataset,system=side,status='pending_or_failed',count_repeats=0,timing_repeats=0)
            for mode in ('counts','timing'):
                group=[r for r in runs if r['dataset']==dataset and r['system']==side and r['mode']==mode and r['status']=='ok']
                row['count_repeats' if mode=='counts' else 'timing_repeats']=len(group)
                fields=COUNT_FIELDS if mode=='counts' else ['compute_ms','rebuild_ms','rebuild_groups','paper_batch_ms']
                for field in fields:
                    row['mean_'+field]=statistics.mean(statistics.mean(b[field] for b in r['batches']) for r in group) if len(group)==2 else None
            if row['count_repeats']==2 and row['timing_repeats']==2: row['status']='complete'
            n=row['mean_vertices']; upd=row['mean_updated_sources']; aff=row['mean_invalidated_vertices']; comp=row['mean_compute_ms']; reb=row['mean_rebuild_ms']
            row['updated_pct']=100*upd/n if n else None
            row['invalidated_pct']=100*aff/n if n else None
            row['relocated_over_updated']=row['mean_relocated_sources']/upd if upd else None
            row['descriptor_MB']=row['mean_descriptor_bytes']/1e6 if n else None
            row['rebuild_share_pct']=100*reb/comp if comp else None
            rows.append(row)
    write_csv(out/'averages.csv',rows)
    save(out/'averages.json',rows)
    if all(r['status']=='complete' for r in rows):
        lines=['% Auto-generated measured means: two runs, ten batches each. See README methodology.',
               '% Seeds column is seeds_prebatch (common pre-batch baseline), not seeds_preinsert.',
               'Graph & System & Upd. & Reloc. & Desc. (MB) & $|A|$ & Init. WL & Seeds & Rebuild \\\\']
        for r in rows:
            lines.append(f"{r['dataset']} & {'CoIncGraph' if r['system']=='current' else 'Grapin'} & {r['mean_updated_sources']:.1f} & {r['mean_relocated_sources']:.1f} & {r['descriptor_MB']:.3f} & {r['mean_invalidated_vertices']:.1f} & {r['mean_initial_insertion_worklist']:.1f} & {r['mean_seeds_prebatch']:.1f} & {r['rebuild_share_pct']:.2f}\\% \\\\")
        (out/'table_rows.tex').write_text('\n'.join(lines)+'\n')
    elif (out/'table_rows.tex').exists():
        (out/'table_rows.tex').unlink()
    return runs

def run_child(argv, env, log, timeout=10800):
    with log.open('w') as output:
        child=subprocess.Popen(argv,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True,cwd=log.parent)
        save(log.with_suffix('.process.json'),dict(pid=child.pid,started_unix=time.time()))
        try: return child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGTERM)
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL); child.wait()
            return 124

def smoke(out):
    # Small independent Dijkstra fixture, ten mixed batches, exactly the same
    # SSSP synthetic weights as the paper runs. Also checks off-mode result equality.
    test=out/'smoke'; test.mkdir(exist_ok=True)
    n=2048
    edges={(u,u+1) for u in range(n-1)} | {(0,u) for u in range(2,n,7)}
    (test/'graph').write_text(''.join(f'{u} {v}\n' for u,v in sorted(edges)))
    updates=[]
    for i in range(10):
        dels=[(0,2+7*i)]; adds=[(1,103+7*i)]
        for u,v in dels: updates.append(f'd {u} {v} 1\n'); edges.remove((u,v))
        for u,v in adds: updates.append(f'a {u} {v} 1\n'); edges.add((u,v))
    (test/'updates').write_text(''.join(updates)); (test/'sizes').write_text('1 1\n'*10)
    import heapq
    adj=[[] for _ in range(n)]
    for u,v in edges: adj[u].append(v)
    expected=[2**32-1]*n; expected[0]=0; queue=[(0,0)]
    while queue:
        distance,u=heapq.heappop(queue)
        if distance!=expected[u]: continue
        for v in adj[u]:
            candidate=distance+(u+v)%128+1
            if candidate<expected[v]: expected[v]=candidate; heapq.heappush(queue,(candidate,v))
    results=[]
    for side in ('current','original'):
        baseline=None
        for mode in ('off','counts','timing'):
            env=clean_env(); env.update(CG_MOTIVATION_MODE=mode,CG_MUTATION_WORKERS='2',CG_REVERSE_SHARDS='64',CG_ORDERED_REPAIR='0',CG_BATCH_MAINTENANCE='regular',CG_COMM_METER='0')
            output=test/f'{side}_{mode}.distances'
            env['CG_MOTIVATION_RESULT_PATH']=str(output)
            command=['numactl','--cpunodebind=0',str(out/(side+'_build/hybrid_sssp')),
                f'--graphfile={test}/graph',f'--updatefile={test}/updates',f'--update_size={test}/sizes',
                '--format=market_big','--weight=true','--weight_num=1','--source_node=0','--SEGMENT=1','--n_stream=3','--cache=2',
                f'--hybrid={0 if side=="current" else 2}','--check=false','--verbose=false',f'--output={output}']
            if side=='current': command+=['--sssp_cpu_partition_capacity=0','--sssp_max_batches=10']
            log=test/f'{side}_{mode}.log'
            code=run_child(command,env,log,300)
            if code: raise RuntimeError(f'Smoke failed ({code}): {log}')
            content=log.read_text()
            if mode=='off':
                if '[MOTIVATION]' in content: raise RuntimeError('Off switch failed')
            else:
                records=parse_log(content,mode)
                if mode=='counts':
                    for record in records:
                        assert record['updated_sources']==2
                        if side=='current':
                            assert record['relocated_untouched_sources']==0
                            assert record['descriptor_bytes']==48
                            assert record['initial_insertion_worklist']<=1
                        else:
                            assert record['descriptor_bytes']==(n+1)*16
                            assert record['initial_insertion_worklist']==n
            # Both applications export "vertex distance parent buffer".
            got={int(parts[0]):int(parts[1]) for line in output.read_text().splitlines() if len(parts:=line.split())>=2 and parts[0].isdigit()}
            mismatches=sum(got.get(v)!=d for v,d in enumerate(expected))
            if side=='current' and mismatches: raise RuntimeError(f'Smoke Dijkstra mismatch: {log}')
            if mode=='off': baseline=got
            elif got!=baseline: raise RuntimeError(f'Instrumentation changed distances: {log}')
            results.append(dict(system=side,mode=mode,status='ok',vertices=n,segments=1,oracle_mismatches=mismatches,matches_off_mode=True))
    save(out/'smoke.json',results)

def wait_gpu(out):
    while subprocess.check_output(['nvidia-smi','-i','0','--query-compute-apps=pid','--format=csv,noheader,nounits'],text=True).strip():
        save(out/'status.json',dict(state='waiting_for_gpu',pid=os.getpid())); time.sleep(15)

def run(out):
    inputs=[]
    for dataset in SOURCES:
        base=ROOT/'data/paper_data'/dataset
        lines=(base/'stream_size_100k.txt').read_text().splitlines()
        assert len(lines)==10 and all(list(map(int,line.split()))==[50000,50000] for line in lines)
        for stem in ('input','update','stream_size'):
            path=base/f'{stem}_100k.txt'; st=path.stat()
            inputs.append(dict(path=str(path),size=st.st_size,mtime_ns=st.st_mtime_ns))
    if (out/'inputs.json').exists() and json.loads((out/'inputs.json').read_text())!=inputs:
        raise RuntimeError('Input identity changed; use a fresh --out')
    save(out/'inputs.json',inputs)
    tasks=[(dataset,mode,rep,side) for dataset in SOURCES for mode in ('counts','timing') for rep in (1,2) for side in (('current','original') if rep==1 else ('original','current'))]
    for index,(dataset,mode,rep,side) in enumerate(tasks):
        name=f'SSSP_{dataset}_{side}_{mode}_r{rep}'
        if (out/(name+'.result.json')).exists(): continue
        wait_gpu(out)
        reference=json.loads((REFERENCE/f'SSSP_{dataset}_100k_{side}_r1.command.json').read_text())
        argv=reference['argv']; argv[2]=str(out/(side+'_build/hybrid_sssp'))
        env=clean_env(); env.update(reference['env_overrides']); env['CG_MOTIVATION_MODE']=mode
        save(out/(name+'.command.json'),dict(argv=argv,env_overrides={k:v for k,v in env.items() if k.startswith(('CG_','CUDA_'))}))
        save(out/'status.json',dict(state='running',task=name,completed=index,total=len(tasks),pid=os.getpid()))
        print('START',name,flush=True); start=time.monotonic()
        log=out/(name+'.log'); code=run_child(argv,env,log)
        result=dict(dataset=dataset,system=side,mode=mode,repeat=rep,exit_code=code,wall_seconds=time.monotonic()-start,status='failed',batches=[])
        try:
            if code: raise ValueError(f'Process exit {code}')
            result['batches']=parse_log(log.read_text(errors='replace'),mode); result['status']='ok'
        except ValueError as exc: result['error']=str(exc)
        save(out/(name+'.result.json'),result); summarize(out)
        print('DONE',name,result['status'],flush=True)
    runs=summarize(out)
    save(out/'status.json',dict(state='completed' if len(runs)==16 and all(r['status']=='ok' for r in runs) else 'completed_with_failures',completed=len(runs),total=16,pid=os.getpid()))

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out',type=Path,default=DEFAULT_OUT)
    parser.add_argument('--prepare-only',action='store_true')
    parser.add_argument('--build-only',action='store_true')
    parser.add_argument('--smoke-only',action='store_true')
    parser.add_argument('--summarize-only',action='store_true')
    args=parser.parse_args(); out=args.out.resolve(); out.mkdir(parents=True,exist_ok=True)
    lock=(out/'runner.lock').open('w'); fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    (out/'runner.pid').write_text(str(os.getpid())+'\n')
    try:
        if args.summarize_only: summarize(out); return
        prepare(out)
        if args.prepare_only: return
        if not (out/'binaries.json').exists(): build(out)
        elif json.loads((out/'binaries.json').read_text()) != {s:sha(out/(s+'_build/hybrid_sssp')) for s in ('current','original')}:
            raise RuntimeError('Frozen binaries changed; use a fresh --out')
        if args.build_only: return
        wait_gpu(out)
        if not (out/'smoke.json').exists(): smoke(out)
        if args.smoke_only: return
        run(out)
    except Exception:
        save(out/'status.json',dict(state='runner_failed',pid=os.getpid(),error=traceback.format_exc())); raise

if __name__=='__main__': main()
