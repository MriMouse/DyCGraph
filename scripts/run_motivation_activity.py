#!/usr/bin/env python3
"""External CPU/GPU activity sampling; no engine changes or profiling hooks."""
import ctypes as C
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import threading
import time
import traceback

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('motivation',ROOT/'scripts/run_motivation_sssp.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
OUT=ROOT/'paper/evaluation/raw/motivation_activity_20261003'
BASE=m.DEFAULT_OUT

class Util(C.Structure):
    _fields_=[('gpu',C.c_uint),('memory',C.c_uint)]

class NVML:
    def __init__(self):
        self.lib=C.CDLL('libnvidia-ml.so.1')
        self.check(self.lib.nvmlInit_v2())
        self.handle=C.c_void_p()
        self.check(self.lib.nvmlDeviceGetHandleByIndex_v2(C.c_uint(0),C.byref(self.handle)))
    def check(self,code):
        if code: raise RuntimeError(f'NVML error {code}')
    def sample(self):
        value=Util()
        self.check(self.lib.nvmlDeviceGetUtilizationRates(self.handle,C.byref(value)))
        return dict(t=time.monotonic(),gpu_pct=value.gpu,memory_busy_pct=value.memory)
    def pids(self):
        return subprocess.check_output(['nvidia-smi','-i','0','--query-compute-apps=pid','--format=csv,noheader,nounits'],text=True).strip().splitlines()

def cpu(pid):
    # Process utime+stime includes all threads; exclude the external sampler.
    fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
    return (int(fields[11])+int(fields[12]))/os.sysconf('SC_CLK_TCK')

def aggregate(samples,start,end):
    # Time-weighted hold of the latest native driver reading, clipped to window.
    elapsed=end-start
    sums={'gpu_pct':0.,'memory_busy_pct':0.}
    coverage=0.
    for i,s in enumerate(samples):
        right=samples[i+1]['t'] if i+1<len(samples) else end
        weight=max(0.,min(end,right)-max(start,s['t']))
        coverage+=weight
        for key in sums: sums[key]+=weight*s[key]
    if coverage < elapsed*.99: raise ValueError('Insufficient GPU sampling coverage')
    return {key:value/coverage for key,value in sums.items()}

def summarize():
    runs=[json.loads(p.read_text()) for p in sorted(OUT.glob('*.result.json'))]
    rows=[]
    for dataset in m.SOURCES:
        for side in ('current','original'):
            valid=[r for r in runs if r['dataset']==dataset and r['system']==side and r['status']=='ok']
            row=dict(dataset=dataset,system=side,successful_repeats=len(valid),status='complete' if len(valid)==2 else 'pending_or_failed')
            for key in ('window_seconds','cpu_seconds','cpu_average_cores','cpu_one_core_pct','gpu_pct','memory_busy_pct','gpu_busy_seconds_estimate'):
                row['mean_'+key]=statistics.mean(r[key] for r in valid) if len(valid)==2 else None
            rows.append(row)
    m.write_csv(OUT/'averages.csv',rows); m.save(OUT/'averages.json',rows)
    return runs

def execute(nvml,dataset,side,rep):
    name=f'SSSP_{dataset}_{side}_r{rep}'
    reference=json.loads((m.REFERENCE/f'SSSP_{dataset}_100k_{side}_r1.command.json').read_text())
    argv=reference['argv']; argv[2]=str(BASE/(side+'_build/hybrid_sssp'))
    # C stdio line buffering makes existing batch-end LOG visible immediately.
    argv=['stdbuf','-oL','-eL',*argv]
    env=m.clean_env(); env.update(reference['env_overrides']); env['CG_MOTIVATION_MODE']='off'
    m.save(OUT/(name+'.command.json'),dict(argv=argv,env_overrides={k:v for k,v in env.items() if k.startswith(('CG_','CUDA_'))}))
    samples=[]; boundaries={}; errors=[]; batches=[]; finished=threading.Event()
    child=subprocess.Popen(argv,cwd=OUT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,bufsize=1,start_new_session=True)
    m.save(OUT/'status.json',dict(state='running',task=name,child_pid=child.pid,pid=os.getpid()))
    def reader():
        try:
            with (OUT/(name+'.log')).open('w') as log:
                for line in child.stdout:
                    if line.strip()=='batch number 0':
                        boundaries['start']=dict(t=time.monotonic(),cpu=cpu(child.pid))
                    match=re.search(r'\[P0-TIMER\]\[SSSP\]\[batch (\d+)\] total_batch: ([\d.]+)',line)
                    if match:
                        batch=int(match[1]); batches.append(dict(batch=batch,ms=float(match[2])))
                        if batch==9:
                            boundaries['end']=dict(t=time.monotonic(),cpu=cpu(child.pid))
                    if re.search(r'CUDA error|cudaError|out of memory|Test failed|protocol_error|Max iterations reached',line,re.I): errors.append(line.strip())
                    log.write(line)
        except Exception: errors.append(traceback.format_exc())
        finally: finished.set()
    thread=threading.Thread(target=reader,daemon=True); thread.start()
    started=time.monotonic(); foreign=set(); last_check=0
    try:
        while not finished.is_set():
            now=time.monotonic()
            if now-started>10800: raise TimeoutError(name)
            # Samples from initialization are discarded except the last second,
            # retained only to cover the left boundary of the incremental window.
            if 'end' not in boundaries:
                samples.append(nvml.sample())
                if 'start' not in boundaries:
                    samples[:]=[s for s in samples if s['t']>=now-1]
            if now-last_check>=2:
                foreign.update(p for p in nvml.pids() if p.strip() and p.strip()!=str(child.pid))
                last_check=now
            finished.wait(.1)
        code=child.wait(timeout=30); thread.join()
    except BaseException:
        os.killpg(child.pid,signal.SIGTERM)
        try: child.wait(timeout=10)
        except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL); child.wait()
        raise
    result=dict(dataset=dataset,system=side,repeat=rep,status='failed',exit_code=code,errors=errors,foreign_gpu_pids=sorted(foreign),boundaries=boundaries,batches=batches)
    m.save(OUT/(name+'.samples.json'),samples)
    try:
        if code or errors or foreign: raise ValueError('Process error or GPU contention')
        if [b['batch'] for b in batches]!=list(range(10)): raise ValueError('Incomplete batches')
        a,b=boundaries['start'],boundaries['end']; duration=b['t']-a['t']; cpu_seconds=b['cpu']-a['cpu']
        if duration<=0 or cpu_seconds<0: raise ValueError('Invalid interval')
        result.update(aggregate(samples,a['t'],b['t']))
        result.update(window_seconds=duration,cpu_seconds=cpu_seconds,cpu_average_cores=cpu_seconds/duration,cpu_one_core_pct=100*cpu_seconds/duration,
                      gpu_busy_seconds_estimate=duration*result['gpu_pct']/100,status='ok',samples_in_window=sum(a['t']<=s['t']<=b['t'] for s in samples))
    except (ValueError,KeyError) as exc: result['errors'].append(str(exc))
    m.save(OUT/(name+'.result.json'),result); summarize()
    print('DONE',name,result['status'],flush=True)

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    lock=(OUT/'runner.lock').open('w'); fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    (OUT/'runner.pid').write_text(str(os.getpid())+'\n')
    try:
        nvml=NVML(); nvml.sample()
        expected=json.loads((BASE/'binaries.json').read_text())
        assert expected=={s:m.sha(BASE/(s+'_build/hybrid_sssp')) for s in ('current','original')},'Frozen binary changed'
        for entry in json.loads((BASE/'inputs.json').read_text()):
            stat=Path(entry['path']).stat()
            assert (stat.st_size,stat.st_mtime_ns)==(entry['size'],entry['mtime_ns']),'Input changed'
        m.save(OUT/'manifest.json',dict(binary_sha256=expected,interval_seconds=.1,window='batch number 0 through P0 batch 9, host log receipt boundaries',repeats=2,cpu_clock_ticks=os.sysconf('SC_CLK_TCK'),gpu=0,meter='off',gpu_metric='NVML native rolling utilization; approximate window average'))
        for dataset in m.SOURCES:
            for rep in (1,2):
                for side in (('current','original') if rep==1 else ('original','current')):
                    if (OUT/f'SSSP_{dataset}_{side}_r{rep}.result.json').exists(): continue
                    while nvml.pids():
                        m.save(OUT/'status.json',dict(state='waiting_for_gpu',pid=os.getpid())); time.sleep(15)
                    print('START',dataset,side,rep,flush=True)
                    execute(nvml,dataset,side,rep)
        runs=summarize()
        m.save(OUT/'status.json',dict(state='completed' if len(runs)==8 and all(r['status']=='ok' for r in runs) else 'completed_with_failures',runs=len(runs)))
    except Exception:
        m.save(OUT/'status.json',dict(state='failed',error=traceback.format_exc())); raise

if __name__=='__main__': main()
