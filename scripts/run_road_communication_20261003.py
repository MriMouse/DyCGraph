#!/usr/bin/env python3
"""Detached serial road benchmark and symmetric, calibrated PCIe comparison."""
import argparse
import csv
import fcntl
import hashlib
import importlib.util
import itertools
import json
import math
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

ROOT = Path(__file__).resolve().parents[1]
REF = ROOT/'paper/evaluation/raw/sssp_bfs_20260927'
DEFAULT = ROOT/'paper/evaluation/raw/road_communication_20261003'
SOURCES = dict(OK=377664, WK=134151, TW=28512093, FS=0, EU=1, USA=1)


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    obj = importlib.util.module_from_spec(spec); spec.loader.exec_module(obj)
    return obj


def save(path, obj):
    tmp = path.with_suffix(path.suffix+'.tmp')
    tmp.write_text(json.dumps(obj, indent=2, ensure_ascii=False)+'\n'); tmp.replace(path)


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for b in iter(lambda: f.read(8<<20), b''): h.update(b)
    return h.hexdigest()


def flags(argv, **changes):
    return [v for v in argv if not any(v.startswith('--'+k+'=') for k in changes)] + ['--'+k+'='+str(v) for k,v in changes.items()]


def environment():
    e = {k:v for k,v in os.environ.items() if not k.startswith(('CG_', 'CUDA_')) and k not in ('OPT','LD_PRELOAD')}
    e.update(CUDA_VISIBLE_DEVICES='0', OMP_NUM_THREADS='20', OPENBLAS_NUM_THREADS='1', MKL_NUM_THREADS='1')
    return e


class Runner:
    def __init__(self, out):
        self.out = out; self.rows = []; self.active = {}; self.sampler = None
        self.pcie = module('pcie', out/'scripts/sample_pcie.py')
        self.ing = module('ingress', out/'scripts/run_ingress_paper_matrix.py')
        self.ing.ROOT=ROOT; self.ing.OUTPUT=out/'ingress'; self.ing.OUTPUT.mkdir(exist_ok=True)
        self.ing.WORK=self.ing.INGRESS/'paper_data_matrix/v2'
        self.ing.WORK.mkdir(parents=True, exist_ok=True)
        self.full = module('full', out/'scripts/run_evaluation_full.py')
        self.full.ROOT=ROOT

    def state(self, state, **kw):
        save(self.out/'status.json', dict(state=state,pid=os.getpid(),updated_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),completed_runs=len(self.rows),active=self.active,**kw))

    def idle(self):
        while subprocess.check_output(['nvidia-smi','-i','0','--query-compute-apps=pid','--format=csv,noheader,nounits'],text=True).strip():
            self.state('waiting_for_gpu'); time.sleep(15)

    def child(self, argv, env, log, sample=False, timeout=10800):
        self.idle()
        for arg in argv:
            if '=' in arg and arg.split('=',1)[1] in self.identities:
                path=Path(arg.split('=',1)[1]);st=path.stat();ident=self.identities[str(path)]
                if st.st_size!=ident['bytes'] or st.st_mtime_ns!=ident['mtime_ns']:raise ValueError('Input changed: '+str(path))
        save(log.with_suffix('.command.json'),dict(argv=argv,env_overrides={k:v for k,v in env.items() if k.startswith(('CG_','CUDA_')) or k.endswith('NUM_THREADS')}))
        sampler = self.pcie.ContinuousSampler(0).start() if sample else None
        if sample: time.sleep(.15)
        start=time.monotonic()
        with log.open('w') as f:
            p=subprocess.Popen(argv,env=env,stdout=f,stderr=subprocess.STDOUT,cwd=ROOT,start_new_session=True)
            print('START',log.name,'pid='+str(p.pid),flush=True)
            self.state('running',child_pid=p.pid,log=str(log))
            try:
                while p.poll() is None:
                    try: p.wait(timeout=5)
                    except subprocess.TimeoutExpired: pass
                    if time.monotonic()-start>timeout: raise TimeoutError(str(log))
                    other=subprocess.check_output(['nvidia-smi','-i','0','--query-compute-apps=pid','--format=csv,noheader,nounits'],text=True).strip().splitlines()
                    if any(int(x.strip())!=p.pid for x in other if x.strip()): raise RuntimeError('Concurrent GPU process; measurement rejected')
                    self.state('running',child_pid=p.pid,elapsed_s=time.monotonic()-start,log=str(log))
            except BaseException:
                os.killpg(p.pid,signal.SIGTERM)
                try: p.wait(timeout=10)
                except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL);p.wait()
                raise
            finally:
                if sampler:
                    time.sleep(.15);sampler.stop()
                    save(log.with_suffix('.samples.json'),dict(samples_time_txKBps_rxKBps=sampler.samples,error=sampler.error))
        content=log.read_text(errors='replace')
        if p.returncode or re.search(r'CUDA error|cudaError|out of memory|Test failed|protocol_error',content,re.I):
            raise RuntimeError(f'Run failed: {log}; rc={p.returncode}')
        physical=None
        if sampler:
            if sampler.error: raise RuntimeError(sampler.error)
            markers=re.findall(r'\[CG-COMM-WINDOW\] event=(begin|end) monotonic_ns=(\d+)',content)
            if [m[0] for m in markers]!=['begin','end']: raise ValueError('Missing/duplicate windows: '+str(log))
            physical=self.pcie.summarize(sampler.samples,*(int(m[1])/1e9 for m in markers))
            save(log.with_suffix('.physical.json'),physical)
        print('DONE',log.name,flush=True)
        return content,physical,time.monotonic()-start

    def command(self, a, d, k, side, road=False, comm=False, batches=10):
        raw=json.loads((REF/f'{a}_OK_{k}_{side}_r1.command.json').read_text())
        argv=raw['argv']; binary=self.out/'bin'/f'{side}_{a}'
        if comm and side=='original': binary=self.out/'bin'/f'comm_original_{a}'
        argv[2]=str(binary)
        folder=self.out/'road_inputs'/d if road else ROOT/'data/paper_data'/d
        argv=flags(argv,graphfile=folder/f'input_{k}.txt',updatefile=folder/f'update_{k}.txt',update_size=folder/f'stream_size_{k}.txt',source_node=SOURCES[d])
        env=environment();env.update(raw['env_overrides'])
        env.update(CG_COMM_WINDOW=str(int(comm)),CG_COMM_METER='0',CG_COMM_BATCHES=str(batches))
        if side=='current':
            env['CG_ORDERED_REPAIR']=str(int(road))
            argv=flags(argv,**{a.lower()+'_max_batches':batches})
        return argv,env

    def record(self, row):
        self.rows.append(row);save(self.out/'results.json',self.rows)
        if row['group']=='road':subprocess.run([sys.executable,str(self.out/'scripts/summarize_road_communication.py'),str(self.out)],check=True,stdout=subprocess.DEVNULL)
        fields=sorted({k for r in self.rows for k in r if not isinstance(r[k],(dict,list))})
        with (self.out/'runs.csv').open('w',newline='') as f:
            w=csv.DictWriter(f,fieldnames=fields,extrasaction='ignore');w.writeheader();w.writerows(self.rows)

    def timing(self, content, a, n):
        ts=re.findall(r'\[P0-TIMER\]\['+a+r'\]\[batch (\d+)\] total_batch: ([\d.]+)',content)
        if [int(i) for i,t in ts]!=list(range(n)): raise ValueError(f'Expected {n} {a} batch timers; got {len(ts)}')
        return sum(float(t) for i,t in ts)

    def prepare(self):
        self.state('preparing_binaries')
        identities=[]
        for d,k in itertools.product(SOURCES,('1k','10k','100k')):
            for stem in ('input','update','stream_size'):
                path=ROOT/'data/paper_data'/d/f'{stem}_{k}.txt';st=path.stat()
                ident=dict(path=str(path),bytes=st.st_size,mtime_ns=st.st_mtime_ns)
                if stem!='input':ident['sha256']=sha(path)
                identities.append(ident)
        save(self.out/'inputs.json',identities)
        self.identities={r['path']:r for r in identities}

        (self.out/'bin').mkdir(exist_ok=True)
        expected=json.loads((REF/'manifest.json').read_text())['binary_sha256']
        for a,s in itertools.product(('SSSP','BFS'),('current','original')):
            group=s if s=='current' or a=='SSSP' else 'original_bfs'
            target='hybrid_'+a.lower() if s=='current' else 'hybrid_sssp'
            source=REF/(group+'_build')/target
            if sha(source)!=expected[group+'/'+target]: raise ValueError('Reference binary changed')
            shutil.copy2(source,self.out/'bin'/f'{s}_{a}')
        for a in ('SSSP','BFS'):
            src=self.out/f'original_{a}_src'
            if not src.exists(): subprocess.run([sys.executable,str(self.out/'scripts/prepare_baseline.py'),'--source',str(REF/('original_src' if a=='SSSP' else 'original_bfs_src')),'--output',str(src)],check=True)
            loader=src/'include/framework/Loader.h';before=loader.read_text()
            old='m_batch_size[pos_batch].first = add_size;\n        m_batch_size[pos_batch].second = del_size;'
            if old in before:
                loader.write_text(before.replace(old,'m_batch_size.emplace_back(add_size, del_size);'))
                (self.out/f'original_{a}_loader_fix.txt').write_text('Communication-only input loader: replace indexing a reserve(10), size-zero vector with emplace_back. Prevents heap overwrite for >10 batches; entirely before measurement window. No algorithm/kernel change.\n')
            path=src/'samples/hybrid_sssp/hybrid_sssp.cu';txt=path.read_text()
            anchor='if(NumOfSnapShots==10) break;'
            assert txt.count(anchor)<=1
            txt=txt.replace(anchor,'if(NumOfSnapShots == (std::getenv("CG_COMM_BATCHES") ? std::atoi(std::getenv("CG_COMM_BATCHES")) : 10)) break;')
            if path.read_text()!=txt:path.write_text(txt)
            build=self.out/f'original_{a}_build'
            self.active=dict(phase='build',algorithm=a);self.state('building')
            with (self.out/f'build_{a}.log').open('w') as f:
                for cmd in ([ 'cmake','-S',str(src),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release','-DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.1','-DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.1/bin/nvcc','-DCMAKE_CXX_COMPILER=/usr/bin/g++-12','-DCUDA_HOST_COMPILER=/usr/bin/gcc-12'],['cmake','--build',str(build),'--target','hybrid_sssp','-j','4']):
                    subprocess.run(cmd,check=True,env=environment(),stdout=f,stderr=subprocess.STDOUT)
            shutil.copy2(build/'hybrid_sssp',self.out/'bin'/f'comm_original_{a}')
        with (self.out/'communication_source_changes.diff').open('w') as patch:
            for a,group in [('SSSP','original_src'),('BFS','original_bfs_src')]:
                subprocess.run(['diff','-ru',str(REF/group),str(self.out/f'original_{a}_src')],stdout=patch,stderr=subprocess.STDOUT)
        binary=self.ing.BUILD/'ingress'; converter=self.ing.BUILD/'prepare_ingress_paper'
        for file in ('result.json','contracts.json'):
            v=json.loads((self.ing.VALIDATION/file).read_text())
            if v['status']!='passed' or v['binary_sha256']!=sha(binary): raise ValueError('Ingress validation mismatch')
            if 'converter_sha256' in v and v['converter_sha256']!=sha(converter): raise ValueError('Converter validation mismatch')
        for name in ('ingress','prepare_ingress_paper'):shutil.copy2(self.ing.BUILD/name,self.out/'bin'/name)
        save(self.out/'binaries.json',{p.name:sha(p) for p in (self.out/'bin').iterdir()})

    def calibration(self):
        probe=self.out/'bin/communication_probe'
        source=self.out/'scripts/communication_probe.cu'
        source.write_text((ROOT/'tests/communication_probe.cu').read_text().replace('count() < 2.0','count() < 6.0'))
        subprocess.run(['/usr/local/cuda-12.1/bin/nvcc','-std=c++14','-I'+str(ROOT/'include'),str(source),'-o',str(probe)],check=True)
        rows=[]
        for mode in ('h2d','d2h','zc'):
            self.active=dict(phase='calibration',mode=mode)
            env=environment();env['CG_COMM_WINDOW']='1'
            text,p,_=self.child([str(probe),mode],env,self.out/f'calibration_{mode}.log',True)
            requested=int(re.search(r'requested_bytes=(\d+)',text)[1]);direction='gpu_tx' if mode=='d2h' else 'gpu_rx'
            ratio=p[direction+'_estimated_bytes']/requested
            ok=p['quality']=='coarse_estimate' and .7<=ratio<=1.3
            rows.append(dict(mode=mode,physical=p,requested_bytes=requested,ratio=ratio,passed=ok))
        save(self.out/'calibration.json',rows)
        if not all(r['passed'] for r in rows):raise RuntimeError('PCIe calibration failed; do not publish traffic estimates')

    def ingress(self,a,d,k,rep):
        paths=[self.out/'road_inputs'/d/f'{stem}_{k}.txt' for stem in ('input','update','stream_size')]
        row=dict(algorithm=a,dataset=d,scale=k,inputs=[dict(path=str(p),bytes=p.stat().st_size,mtime_ns=p.stat().st_mtime_ns) for p in paths])
        self.ing.WORK=self.ing.INGRESS/'paper_data_matrix/road99_20261003';self.ing.WORK.mkdir(exist_ok=True)
        env=environment();prefix,prepared=self.ing.prepare(row,self.out/'bin/prepare_ingress_paper',env)
        cache=self.out/'ingress'/f'cache_{d}_{k}';cache.mkdir(exist_ok=True)
        argv=['numactl','--cpunodebind=0',str(self.out/'bin/ingress'),'--logtostderr=1','--application='+a.lower(),'--efile='+str(prefix.with_suffix('.base')),'--vfile='+str(prefix.with_suffix('.v')),'--efile_update='+str(paths[1]),'--paper_stream_sizes='+str(paths[2]),'--serialization_prefix='+str(cache),'--out_prefix=','--directed=true','--cilk=false','--app_concurrency=20','--sssp_source=1']
        name=f'road_{a}_{d}_{k}_ingress_r{rep}';log=self.out/(name+'.log')
        _,_,wall=self.child(argv,env,log)
        result=self.ing.parse_log(log)
        self.record(dict(group='road',algorithm=a,dataset=d,scale=k,system='ingress',repeat=rep,status='ok',wall_s=wall,log=str(log),**result))

    def smoke(self):
        # Exercise every GPU binary on a small legal ten-batch fixture before the matrix.
        folder=self.out/'smoke';folder.mkdir(exist_ok=True)
        (folder/'graph').write_text(''.join(f'{u} {(u+1)%64}\n' for u in range(64)))
        (folder/'sizes').write_text('1 1\n'*20)
        (folder/'updates').write_text(''.join(('d 20 21 1\na 20 22 1\n' if i%2==0 else 'd 20 22 1\na 20 21 1\n') for i in range(20)))
        (folder/'sizes10').write_text('1 1\n'*10)
        (folder/'updates10').write_text(''.join((folder/'updates').read_text().splitlines(True)[:20]))
        results=[]
        for a,s in itertools.product(('SSSP','BFS'),('original','current')):
            for mode in ('physical','ledger','road'):
                self.active=dict(phase='smoke',algorithm=a,system=s,mode=mode)
                argv,env=self.command(a,'OK','1k',s,road=mode=='road',comm=mode!='road',batches=10 if mode=='road' else 20)
                argv=flags(argv,graphfile=folder/'graph',updatefile=folder/('updates10' if mode=='road' else 'updates'),update_size=folder/('sizes10' if mode=='road' else 'sizes'),source_node=0,SEGMENT=4,cache=0)
                env['CG_COMM_METER']=str(int(mode=='ledger'))
                log=folder/f'{a}_{s}_{mode}.log'
                text,physical,_=self.child(argv,env,log,sample=mode=='physical')
                self.timing(text,a,10 if mode=='road' else 20)
                if mode=='ledger' and '[I17-B7-COMM]' not in text:raise ValueError('Smoke ledger missing')
                results.append(dict(algorithm=a,system=s,mode=mode,status='passed',physical=physical))
        save(self.out/'smoke.json',results)

    def prepare_roads(self):
        # Regenerate the SAME connected-road-v2 rule with the requested 1k/10k/100k scales.
        tools=ROOT/'data/road_connected_v2/_tools'
        source_manifest=json.loads((ROOT/'data/road_connected_v2/manifest.json').read_text())
        for name in ('connected_road_generator','verify_connected_road_dataset'):
            if sha(tools/name)!=source_manifest['tools'][name]['binary_sha256']:raise ValueError('Road tool identity mismatch')
            shutil.copy2(tools/name,self.out/'bin'/name)
        for d,name,source in [('EU','europe_osm',ROOT.parent/'DataSet/europe_osm/europe_osm.mtx'),('USA','road_usa',ROOT/'data/road_usa/road_usa.mtx')]:
            self.active=dict(phase='prepare_connected_road',dataset=d);self.state('preparing_road')
            folder=self.out/'connected_inputs'/name
            if not folder.exists():
                if sha(source)!=source_manifest['sources'][name]['sha256']:raise ValueError('Original road source changed')
                self.child([str(self.out/'bin/connected_road_generator'),str(source),str(folder),name,'99','1000,10000,100000','10','42','connected-road-v2'],environment(),self.out/f'generate_{d}.log')
            self.child([str(self.out/'bin/verify_connected_road_dataset'),str(folder)],environment(),self.out/f'verify_{d}.log')
            metadata=json.loads((folder/'99p/metadata.json').read_text())
            assert metadata['source_node']==1 and metadata['source_reachable_vertices']>1000000
            normalized=self.out/'road_inputs'/d;normalized.mkdir(parents=True,exist_ok=True)
            for k,stem in itertools.product(('1k','10k','100k'),('input','update','stream_size')):
                original=folder/'99p'/f'{stem}_{name}_99p_{k}.txt';path=normalized/f'{stem}_{k}.txt'
                if not path.exists():path.symlink_to(original)
                st=path.stat();self.identities[str(path)]=dict(path=str(path),bytes=st.st_size,mtime_ns=st.st_mtime_ns,sha256=sha(path))
            save(normalized/'ready.json',dict(initial_edges={k:metadata['base_directed_edges'] for k in ('1k','10k','100k')}))
        save(self.out/'inputs.json',list(self.identities.values()))
        save(self.out/'road_protocol.json',dict(dataset='connected-road-v2 99p',scales=['1k','10k','100k'],source=1,seed=42,semantics='Original undirected roads expanded both directions, random-order Kruskal forest protected; only non-forest present edges eligible for deletion; no synthetic edges',comparison='Separate cohort from paper_data; all three systems share identical initial graph and updates; only current road-mode switch differs from its baseline configuration',warning='Connectivity-preserving deletion sampling is biased; not uniform deletion over all present edges'))

    def roads(self):
        for a,d,k in itertools.product(('SSSP','BFS'),('EU','USA'),('1k','10k','100k')):
            for rep in (1,2):
                for side in (('current','original','ingress') if rep==1 else ('ingress','original','current')):
                    self.active=dict(group='road',algorithm=a,dataset=d,scale=k,system=side,repeat=rep)
                    if side=='ingress':self.ingress(a,d,k,rep);continue
                    argv,env=self.command(a,d,k,side,road=True)
                    log=self.out/f'road_{a}_{d}_{k}_{side}_r{rep}.log'
                    text,_,wall=self.child(argv,env,log)
                    self.record(dict(**self.active,status='nonconverged' if 'Max iterations reached' in text else 'ok',paper_algorithm_ms=self.timing(text,a,10),wall_s=wall,log=str(log)))

    def communication_run(self,a,d,k,side,cycles,phase,rep,meter=False):
        n=20*cycles;argv,env=self.command(a,d,k,side,comm=True,batches=n)
        folder=self.out/'inputs'/f'{d}_{k}'
        argv=flags(argv,updatefile=folder/f'updates_{cycles}.txt',update_size=folder/f'sizes_{cycles}.txt')
        env['CG_COMM_METER']=str(int(meter))
        self.active=dict(group='communication',algorithm=a,dataset=d,scale=k,system=side,phase=phase,repeat=rep,cycles=cycles)
        log=self.out/f'comm_{a}_{d}_{k}_{side}_{phase}_c{cycles}_r{rep}.log'
        text,p,wall=self.child(argv,env,log,sample=not meter)
        timer=self.timing(text,a,n)
        checksum=re.findall(r'\[CG-COMM-RESULT\] distance_checksum=(\d+)',text)
        if len(checksum)!=1:raise ValueError('Missing final checksum')
        ledger={}
        if meter:
            for batch,direction,nb in re.findall(r'\[I17-B7-COMM\] batch=(-?\d+) stage=\S+ category=\S+ direction=(\S+) bytes=(\d+)',text):
                if int(batch)>=0:ledger[direction]=ledger.get(direction,0)+int(nb)
            if not ledger:raise ValueError('Missing explicit copy ledger')
        row=dict(**self.active,status='nonconverged' if 'Max iterations reached' in text else 'ok',batches=n,paper_algorithm_ms=timer,checksum=checksum[0],wall_s=wall,physical=p,explicit_api_bytes=ledger,log=str(log))
        self.record(row);return row

    def stream(self,d,k,cycles):
        folder=self.out/'inputs'/f'{d}_{k}';folder.mkdir(parents=True,exist_ok=True)
        src=ROOT/'data/paper_data'/d
        batches=self.full.parent_batches(src/f'update_{k}.txt',src/f'stream_size_{k}.txt',int(k[:-1]))
        audit=folder/'audit.json'
        if not audit.exists():
            self.active=dict(phase='audit_input',dataset=d,scale=k);self.state('auditing_input')
            cycle,info=self.full.audit_cycle(src/f'input_{k}.txt',batches,lambda n:self.state('auditing_input',edges_scanned=n))
            save(audit,dict(**info,updates_sha256=sha(src/f'update_{k}.txt'),base_stat=dict(bytes=(src/f'input_{k}.txt').stat().st_size,mtime_ns=(src/f'input_{k}.txt').stat().st_mtime_ns)))
        else:cycle=batches+[dict(d=b['a'],a=b['d']) for b in reversed(batches)]
        with (folder/f'updates_{cycles}.txt').open('w') as u,(folder/f'sizes_{cycles}.txt').open('w') as s:
            for _ in range(cycles):
                for batch in cycle:
                    s.write(f"{len(batch['a'])} {len(batch['d'])}\n")
                    for op in ('d','a'):
                        for x,y,w in batch[op]:u.write(f'{op} {x} {y} {w}\n')
        save(folder/f'identities_{cycles}.json',{p.name:sha(p) for p in (folder/f'updates_{cycles}.txt',folder/f'sizes_{cycles}.txt')})

    def communication_cycles(self, a, d, k):
        # Duration only; never select workload length by measured traffic or ratio.
        history=[r for r in self.rows if r.get('group')=='communication'
                 and r.get('dataset') in ('TW','FS') and r.get('physical')
                 and r['physical']['duration_s']>0]
        exact=[r for r in history if (r['algorithm'],r['dataset'],r['scale'])==(a,d,k)]
        dataset=[r for r in history if r['dataset']==d]
        pool=exact or dataset or history
        seconds_per_cycle=min((r['physical']['duration_s']/r['cycles'] for r in pool),default=1.0)
        return min(128,max(4,math.ceil(10/seconds_per_cycle)))

    def communications(self):
        path=self.out/'communication_comparisons.json'
        comparisons=json.loads(path.read_text()) if path.exists() else []
        completed={(r['algorithm'],r['dataset'],r['scale']) for r in comparisons}
        plans_path=self.out/'direct_measurement_plans.json'
        plans=json.loads(plans_path.read_text()) if plans_path.exists() else {}
        for a,d,k in itertools.product(('SSSP','BFS'),('TW','FS'),('1k','10k','100k')):
            if (a,d,k) in completed:continue
            key=f'{a}_{d}_{k}'
            if key not in plans:
                plans[key]=dict(cycles=self.communication_cycles(a,d,k),target_window_s=10,
                    method='No dedicated pilots; conservative minimum observed seconds/cycle; floor4 cap128; both systems identical batches',attempts=[])
                save(plans_path,plans)
            cycles=plans[key]['cycles']
            def measured(side,phase,rep,meter=False):
                prior=[r for r in self.rows if r.get('group')=='communication' and
                       (r['algorithm'],r['dataset'],r['scale'],r['system'],r['cycles'],r['phase'],r['repeat'])==
                       (a,d,k,side,cycles,phase,rep)]
                if len(prior)>1:raise ValueError('Duplicate measurement identity')
                return prior[0] if prior else self.communication_run(a,d,k,side,cycles,phase,rep,meter)
            while True:
                self.stream(d,k,cycles)
                formal=[measured(side,'physical',rep) for rep in (1,2)
                        for side in (('original','current') if rep==1 else ('current','original'))]
                shortest=min(r['physical']['duration_s'] for r in formal)
                # All four runs retained. Only a short window triggers a new shared length.
                # Sampling gaps / checksum mismatches never trigger best-of-N retries.
                if shortest>=5 or cycles>=128:break
                next_cycles=min(128,max(cycles*2,math.ceil(cycles*10/shortest)))
                plans[key]['attempts'].append(dict(cycles=cycles,status='superseded_short_window',shortest_s=shortest))
                cycles=next_cycles;plans[key]['cycles']=cycles;save(plans_path,plans)
            ledger=[measured(side,'ledger',1,True) for side in ('original','current')]
            sufficient=all(r['status']=='ok' and r['physical']['quality']=='coarse_estimate' and r['physical']['duration_s']>=5 for r in formal)
            same=len({r['checksum'] for r in formal+ledger})==1
            means={s:{direction:statistics.mean(r['physical'][field]/r['batches'] for r in formal if r['system']==s) for direction,field in [('h2d_bytes_per_batch','gpu_rx_estimated_bytes'),('d2h_bytes_per_batch','gpu_tx_estimated_bytes')]} for s in ('original','current')}
            comparisons.append(dict(algorithm=a,dataset=d,scale=k,cycles=cycles,sampling_sufficient=sufficient,final_checksum_equal=same,eligible=sufficient and same and all(r['status']=='ok' for r in ledger),means=means,original_over_current=(sum(means['original'].values())/sum(means['current'].values()) if sufficient and same and all(r['status']=='ok' for r in ledger) and sum(means['current'].values()) else None),explicit_api_bytes_per_batch={r['system']:{key:value/r['batches'] for key,value in r['explicit_api_bytes'].items()} for r in ledger}))
            save(self.out/'communication_comparisons.json',comparisons)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--out',type=Path,default=DEFAULT);p.add_argument('--worker',action='store_true');args=p.parse_args()
    out=args.out.resolve()
    if not args.worker:
        out.mkdir(parents=True,exist_ok=False);(out/'scripts').mkdir()
        files=['summarize_road_communication.py','run_road_communication_20261003.py','run_ingress_paper_matrix.py','run_evaluation_full.py','run_paper_supplement_20260922.py','communication/sample_pcie.py','communication/prepare_baseline.py']
        for name in files:shutil.copy2(ROOT/'scripts'/name,out/'scripts'/Path(name).name)
        # Frozen legacy helpers discover ROOT from their own location; pin it to this workspace.
        for name in ('run_evaluation_full.py','run_ingress_paper_matrix.py','prepare_baseline.py','run_road_communication_20261003.py'):
            f=out/'scripts'/name;txt=f.read_text();txt=re.sub(r'^ROOT\s*=.*$', 'ROOT = Path('+repr(str(ROOT))+')',txt,count=1,flags=re.M);f.write_text(txt)
        shutil.copy2(ROOT/'scripts/run_paper_supplement_20260922.py',out/'scripts/supplement_helper_frozen.py')
        save(out/'protocol.json',dict(road='SSSP/BFS x EU/USA x 1k/10k/100k x current/original/ingress x 2; frozen baseline binaries; only current CG_ORDERED_REPAIR=1',communication='SSSP/BFS x TW/FS x 1k/10k/100k; no dedicated pilots; SAME cycles selected from prior durations targeting10s, floor4 cap128; AB/BA two formal repeats; separate ledger pass; only short windows trigger a shared longer repeat; all attempts retained',physical='NVML GPU RX=H2D TX=D2H; device-wide PCIe including mapped-host Zero-Copy, explicit propagation/state/cache/control transfers; coarse estimate, never sum with API ledger, cannot isolate exact ZC bytes',ledger='same successful cudaMemcpy/Async requested bytes wrapper; aggregate directions only; initialization/final gather excluded; no kernel instrumentation; unclassified/default retained',correctness='final checksum mismatch blocks ratio; equality is not an independent per-batch correctness proof',ingress='report selected compute and full reset+topology+compute; compute-only excludes topology rebuild and is asymmetric to P0',quality='calibrate H2D D2H ZC on same GPU; >=5s EACH formal window, >=50 samples, max gap<=100ms, complete boundaries; no repeated-short-window claim of precision',scripts={f.name:sha(f) for f in (out/'scripts').iterdir()}))
        with (out/'runner.log').open('w') as log:
            child=subprocess.Popen([sys.executable,'-u',str(out/'scripts'/Path(__file__).name),'--out',str(out),'--worker'],stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,cwd=ROOT)
        (out/'runner.pid').write_text(str(child.pid)+'\n');print(json.dumps(dict(pid=child.pid,output=str(out))));return
    lock=(out/'runner.lock').open('w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    runner=Runner(out)
    try:
        runner.prepare();runner.calibration();runner.smoke();runner.prepare_roads();runner.roads();runner.communications();runner.active={};runner.state('complete')
    except BaseException:
        runner.state('failed',error=traceback.format_exc());raise

if __name__=='__main__': main()
