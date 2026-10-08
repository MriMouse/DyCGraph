#!/usr/bin/env python3
"""Plan, validate, or run the isolated SSSP/BFS ablation matrix. Default: plan only."""
import argparse, csv, fcntl, hashlib, heapq, itertools, json, os, re, signal
import statistics, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
REFERENCE=ROOT/'paper/evaluation/raw/sssp_bfs_20260927'
BAD=re.compile(r'CUDA error|cudaError|out of memory|Test failed|protocol_error|\] failed\b',re.I)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def save(path,obj):
    tmp=path.with_suffix(path.suffix+'.tmp');tmp.write_text(json.dumps(obj,indent=2,ensure_ascii=False)+'\n');tmp.replace(path)
def binary(root,v,a):return root/v/'build'/('hybrid_'+a.lower())
def binary_hashes(root,variants):
    result={}
    for v in variants:
        frozen=json.loads((root/v/'binary_manifest.json').read_text())
        for a in ('SSSP','BFS'):
            value=sha(binary(root,v,a))
            if value!=frozen['hybrid_'+a.lower()]:raise RuntimeError('Binary changed since build')
            result[v+'/'+a]=value
    return result

def ensure_idle():
    # Checking the parent runners matters: a free GPU between their jobs is
    # not permission to occupy it. Do not wait and automatically start later.
    blockers=[]
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit() or int(proc.name)==os.getpid():continue
        try:
            if proc.stat().st_uid!=os.getuid():continue
            raw=(proc/'cmdline').read_bytes().split(b'\0')
            argv=[x.decode(errors='replace') for x in raw if x]
        except (OSError,PermissionError):continue
        if not argv:continue
        name=Path(argv[0]).name
        # Match executables or Python scripts, not shell command text.
        scripts=[Path(x).name for x in argv[1:3]] if 'python' in name else []
        if (name.startswith(('current_BFS','current_SSSP','hybrid_')) or
            any(s.startswith(('run_road_communication','run_ingress','run_paper_sssp_bfs')) for s in scripts) or
            ('python' in name and any('/paper/evaluation/' in x and x.endswith('.py') for x in argv[1:3]))):
            blockers.append({'pid':int(proc.name),'argv':argv})
    gpu=subprocess.check_output(['nvidia-smi','-i','0','--query-compute-apps=pid','--format=csv,noheader,nounits'],text=True).strip()
    if blockers or gpu:raise RuntimeError(f'Active experiments/GPU processes; refusing to launch: {blockers}; GPU={gpu}')

def checksum(row):
    h=1469598103934665603;mask=(1<<64)-1
    for i,d in enumerate(row):
        if d==(1<<32)-1:continue
        h=((h ^ ((i+0x9e3779b97f4a7c15+(d<<6)+(d>>2))&mask))*1099511628211)&mask
    return h

def fixture(out):
    n=64;adj=[[] for _ in range(n)]
    for s in range(47):adj[s].append(s+1)
    for s in range(48,64):adj[s].append(48+(s-47)%16)
    adj[0]+=[1,8];adj[8]+=[24];adj[24]+=[47]
    graph=out/'graph.txt';graph.write_text(''.join(f'{s} {d}\n' for s,row in enumerate(adj) for d in row))
    batches=[([(0,48),(3,20)],[(0,1),(0,1),(0,1),(8,24)]),
             ([(0,d) for d in range(10,22)],[]),
             ([],[(0,48),(24,47),(10,11)]),([],[]),
             ([(0,48),(10,11),(0,1)],[(0,8),(3,20)])]
    updates=out/'updates.txt';sizes=out/'sizes.txt'
    updates.write_text(''.join(f'{op} {s} {d} 1\n' for adds,dels in batches for op,edges in [('d',dels),('a',adds)] for s,d in edges))
    sizes.write_text(''.join(f'{len(a)} {len(d)}\n' for a,d in batches))
    expected={'SSSP':[],'BFS':[]}
    for adds,dels in batches:
        for s,d in dels:
            if d in adj[s]:adj[s].remove(d)
        for s,d in adds:adj[s].append(d)
        for algo in expected:
            dist=[(1<<32)-1]*n;dist[0]=0;queue=[(0,0)]
            while queue:
                value,s=heapq.heappop(queue)
                if value!=dist[s]:continue
                for d in adj[s]:
                    new=value+(1 if algo=='BFS' else (s+d)%128+1)
                    if new<dist[d]:dist[d]=new;heapq.heappush(queue,(new,d))
            expected[algo].append(checksum(dist))
    save(out/'oracle.json',expected)
    return graph,updates,sizes,expected

def launch(argv,env,log,timeout):
    try:
        ensure_idle()
    except Exception as exc:
        save(log.parent/'status.json',dict(state='blocked',reason=str(exc)))
        raise
    with log.open('x') as output:
        child=subprocess.Popen(argv,env=env,cwd=log.parent,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        try:code=child.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGTERM)
            try:child.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
            code=124
        except KeyboardInterrupt:
            os.killpg(child.pid,signal.SIGTERM)
            try:child.wait(timeout=10)
            except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
            save(log.parent/'status.json',dict(state='interrupted'))
            raise
    return code,log.read_text(errors='replace')

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('prepared',type=Path)
    p.add_argument('--mode',choices=['plan','validate','run'],default='plan')
    p.add_argument('--variants',nargs='+',default=['011','101','110'])
    p.add_argument('--out',type=Path)
    p.add_argument('--validation',type=Path,help='passed validate output directory required for timing')
    p.add_argument('--datasets',nargs='+',choices=['OK','WK','TW','FS'],default=['TW','FS'])
    p.add_argument('--scales',nargs='+',choices=['1k','10k','100k'],default=['1k','10k','100k'])
    p.add_argument('--repeats',type=int,default=1)
    p.add_argument('--resume',action='store_true',help='resume an existing run directory and skip completed variant cells')
    p.add_argument('--timeout',type=int,default=10800)
    args=p.parse_args();root=args.prepared.resolve()
    prepared=json.loads((root/'manifest.json').read_text())
    if not set(args.variants)<=set(prepared['variants']):p.error('unprepared variant')
    if len(set(args.variants))!=len(args.variants):p.error('duplicate variants')
    if args.repeats<1:p.error('repeats must be positive')
    env={k:v for k,v in os.environ.items() if not k.startswith(('CG_','CUDA_')) and k not in ('OPT','LD_PRELOAD')}
    common=json.loads((REFERENCE/'SSSP_OK_1k_current_r1.command.json').read_text())['env_overrides']
    env.update(common)
    tasks=[]
    for a,d,k in itertools.product(('SSSP','BFS'),args.datasets,args.scales):
        reference=json.loads((REFERENCE/f'{a}_{d}_{k}_current_r1.command.json').read_text())
        for rep in range(1,args.repeats+1):
            for v in args.variants if rep%2 else reversed(args.variants):
                argv=reference['argv'].copy();argv[2]=str(binary(root,v,a))
                tasks.append(dict(algorithm=a,dataset=d,scale=k,variant=v,repeat=rep,argv=argv,env_overrides=common))
    if args.mode=='plan':
        result=dict(prepared=str(root),tasks=tasks,total=len(tasks),launches_gpu=False)
        if args.out:
            args.out.mkdir(parents=True,exist_ok=True);save(args.out/'plan.json',result)
            print(f'Prepared {len(tasks)} runs in {args.out}/plan.json; nothing launched')
        else:print(json.dumps(result,indent=2))
        return
    if args.out is None:p.error('--out is required for validate/run')
    out=args.out.resolve()
    if args.resume and (args.mode!='run' or args.repeats!=1):p.error('resume supports single-repeat timing only')
    if out.exists() and not args.resume:p.error('output exists; use a new directory (never overwrite results)')
    hashes=binary_hashes(root,args.variants)
    if args.mode=='run':
        if args.validation is None:p.error('--validation is required before timing')
        gate=json.loads((args.validation/'validation.json').read_text())
        if gate['status']!='passed' or any(gate['binary_sha256'].get(k)!=v for k,v in hashes.items()):
            p.error('validation missing/failed or binaries changed; validate these binaries first')
    ensure_idle()
    lock=open('/tmp/cg_ablation_gpu0.lock','a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    out.mkdir(parents=True,exist_ok=True)
    save(out/'manifest.json',dict(binary_sha256=hashes,prepared=str(root),mode=args.mode,variants=args.variants))
    if args.mode=='validate':
        graph,updates,sizes,expected=fixture(out)
        results=[]
        save(out/'validation.json',dict(status='running',binary_sha256=hashes))
        for a,v in itertools.product(('SSSP','BFS'),args.variants):
            argv=['numactl','--cpunodebind=0',str(binary(root,v,a)),f'--graphfile={graph}',f'--updatefile={updates}',f'--update_size={sizes}',
                  '--format=market_big','--weight_num=1','--weight=true','--source_node=0','--SEGMENT=8','--n_stream=3','--cache=2','--hybrid=0',
                  '--check=true','--verbose=false','--sssp_cpu_partition_capacity=0',f'--{a.lower()}_max_batches=5',f'--{a.lower()}_print_checksum=true']
            name=f'{a}_{v}';save(out/(name+'.command.json'),dict(argv=argv,env_overrides=common))
            code,text=launch(argv,env,out/(name+'.log'),min(600,args.timeout))
            matches=re.findall(r'\['+a+r'-BATCH-CHECK\]\[batch (\d+)\] passed[^\n]*distance_checksum=(\d+)',text)
            actual=[int(value) for _,value in matches]
            ok=code==0 and not BAD.search(text) and [int(i) for i,_ in matches]==list(range(5)) and actual==expected[a]
            results.append(dict(algorithm=a,variant=v,passed=ok,exit_code=code,checksums=actual,expected=expected[a]))
            save(out/'validation.json',dict(status='running',results=results,binary_sha256=hashes))
            print(name,'passed' if ok else 'FAILED',flush=True)
        passed=all(r['passed'] for r in results)
        save(out/'validation.json',dict(status='passed' if passed else 'failed',results=results,binary_sha256=hashes))
        if not passed:raise SystemExit('Validation failed; performance run is blocked')
        return
    existing=[]
    if args.resume and (out/'runs.json').exists(): existing=json.loads((out/'runs.json').read_text())
    done={(r['algorithm'],r['dataset'],r['scale'],r['variant']) for r in existing if r.get('status')=='timing_complete'}
    tasks=[t for t in tasks if (t['algorithm'],t['dataset'],t['scale'],t['variant']) not in done]
    inputs={}
    for t in tasks:
        for arg in t['argv']:
            if arg.startswith(('--graphfile=','--updatefile=','--update_size=')):
                path=Path(arg.split('=',1)[1]);st=path.stat()
                inputs[str(path)]=dict(size=st.st_size,mtime_ns=st.st_mtime_ns)
    save(out/'inputs.json',inputs)
    rows=list(existing)
    total_runs=len(existing)+len(tasks)
    for t in tasks:
        name='{algorithm}_{dataset}_{scale}_{variant}_r{repeat}'.format(**t)
        for arg in t['argv']:
            if arg.startswith(('--graphfile=','--updatefile=','--update_size=')):
                path=Path(arg.split('=',1)[1]);st=path.stat()
                if inputs[str(path)]!=dict(size=st.st_size,mtime_ns=st.st_mtime_ns):raise RuntimeError('Input changed during experiment')
        save(out/'status.json',dict(state='running',completed=len(rows),total=total_runs,active=name))
        save(out/(name+'.command.json'),t)
        begin=time.monotonic();code,text=launch(t['argv'],env,out/(name+'.log'),args.timeout)
        timers=re.findall(r'\[P0-TIMER\]\['+t['algorithm']+r'\]\[batch (\d+)\] total_batch: ([\d.]+)',text)
        ok=code==0 and [int(i) for i,_ in timers]==list(range(10)) and not BAD.search(text)
        row={k:t[k] for k in ('algorithm','dataset','scale','variant','repeat')}
        row.update(status='timing_complete' if ok else 'failed',exit_code=code,total_batch_ms=sum(float(v) for _,v in timers) if ok else None,wall_seconds=time.monotonic()-begin)
        rows.append(row);save(out/'runs.json',rows);save(out/(name+'.batches.json'),timers)
        with (out/'runs.csv').open('w',newline='') as f:
            w=csv.DictWriter(f,fieldnames=list(row));w.writeheader();w.writerows(rows)
        print(name,row['status'],flush=True)
        if not ok:
            save(out/'status.json',dict(state='failed',completed=len(rows),total=total_runs,active=name))
            raise SystemExit('Failed run; inspect logs before continuing with a new output directory')
    summary=[]
    for a,d,k in itertools.product(('SSSP','BFS'),args.datasets,args.scales):
        means={v:statistics.mean(r['total_batch_ms'] for r in rows if (r['algorithm'],r['dataset'],r['scale'],r['variant'])==(a,d,k,v) and r['repeat']<=args.repeats) for v in args.variants}
        for v,mean in means.items():
            row=dict(algorithm=a,dataset=d,scale=k,variant=v,mean_total_batch_ms=mean,mean_batch_ms=mean/10)
            if '111' in means: row['over_full']=mean/means['111']
            summary.append(row)
    with (out/'summary.csv').open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(summary[0]));w.writeheader();w.writerows(summary)
    save(out/'status.json',dict(state='completed',completed=len(rows),total=total_runs))
if __name__=='__main__':main()
