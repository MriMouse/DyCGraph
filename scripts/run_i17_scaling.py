#!/usr/bin/env python3
"""Focused in-process scalability queue; road experiments default to ordered repair."""
import argparse, fcntl, hashlib, json, os, re, shutil, signal, subprocess, time
from pathlib import Path
from run_i17_eu_background import save, now, summarize
ROOT=Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser(description=__doc__); p.add_argument('--output',type=Path,required=True)
 a=p.parse_args(); out=a.output.resolve(); out.mkdir(parents=True,exist_ok=False)
 lock=(ROOT/'build/i17_replay_gpu.lock').open('a'); fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
 binary=out/'hybrid_sssp'; shutil.copy2(ROOT/'build/hybrid_sssp',binary)
 for rel in ['include/framework/ordered_gpu_repair.cuh','include/framework/framework.cuh','include/framework/dynamic_reverse_index.h','scripts/run_i17_scaling.py','scripts/prepare_i17_scaling.py','scripts/run_i17b_reverse_probe.py','scripts/run_i17_eu_background.py']:
  target=out/'sources'/rel; target.parent.mkdir(parents=True,exist_ok=True); shutil.copy2(ROOT/rel,target)
 results={}; status=dict(state='running',pid=os.getpid(),started_utc=now(),completed=[])
 manifest=dict(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),runs=[],scope='Full production batch with experimental ordered deletion repair; insertion unchanged; two batches per run, no stability repeats')
 save(out/'manifest.json',manifest)
 child=None
 def state(**kw):
  status.update(updated_utc=now(),**kw); save(out/'status.json',status)
 def stop(*args): raise KeyboardInterrupt()
 signal.signal(signal.SIGTERM,stop)
 def run(name,command,shards,ordered,check=False):
  nonlocal child
  command=[str(binary)]+[x for x in command[1:] if not x.startswith('--i16_repair_snapshot=')]
  path=out/name; config=out/(name+'.manifest.json'); save(config,dict(command=command))
  manifest['runs'].append(dict(name=name,shards=shards,ordered=ordered,check=check,command=command)); save(out/'manifest.json',manifest)
  busy=subprocess.check_output(['nvidia-smi','-i','0','--query-compute-apps=pid','--format=csv,noheader,nounits'],text=True).strip()
  if busy: raise RuntimeError('GPU occupied: '+busy)
  cmd=['python3',str(out/'sources/scripts/run_i17b_reverse_probe.py'),'--binary',str(binary),'--output',str(path),'--manifest',str(config),'--batches','2','--shards',str(shards),'--timeout','7200']
  if check: cmd+=['--check']
  start=time.monotonic()
  with (out/(name+'.driver.log')).open('w') as log:
   child=subprocess.Popen(cmd,cwd=ROOT,env={**os.environ,'CG_ORDERED_REPAIR':str(int(ordered))},stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   while child.poll() is None:
    text=(path/'run.log').read_text(errors='replace') if (path/'run.log').exists() else ''
    state(active=name,child_pid=child.pid,active_log=str(path/'run.log'),elapsed_seconds=round(time.monotonic()-start,1),completed_batches=len(re.findall(r'\[P0-TIMER\]',text)))
    time.sleep(5)
  if child.returncode: raise RuntimeError(name+' failed; see driver/run log')
  result=summarize(path); text=(path/'run.log').read_text()
  result['ordered_details']=re.findall(r'\[I17-ORDERED\].*',text)
  if ordered and not result['ordered_details']: raise RuntimeError('Ordered repair did not execute')
  result.update(ordered=ordered,check=check); results[name]=result; status['completed'].append(name)
  save(out/'results.json',results)
  lines=['# I17 扩展性短测','', '所有时间均为两批合计；ordered 只优化删除修复。check=false 的 checksum 仅用于配对诊断。','', '| run | paper s | reverse s | repair service* s | insertion s | check |','|---|---:|---:|---:|---:|---|']
  for n,r in results.items(): lines.append(f"| {n} | {r['paper_total_ms']/1000:.3f} | {r['reverse_total_ms']/1000:.3f} | {r['repair_closure_ms']/1000:.3f} | {r['stages_ms']['add']/1000:.3f} | {r['check']} |")
  lines+=['','* B2 closure 计时包含 ordered 的额外准备、发布与 workspace 释放，外层 incoming materialize/allocation/H2D 单列于 results.json。']
  (out/'report.md').write_text('\n'.join(lines)+'\n')
 try:
  # Short road integration check before performance queue.
  base=json.loads((ROOT/'logs/i17_eu_probe_20260911/100k_manifest.json').read_text())['command']
  for dataset in ['road_usa','europe_osm']:
   command=[x.replace('europe_osm',dataset) for x in base]
   # USA 100k check, then both scales paired with same-binary pull.
   if dataset=='road_usa': run('usa_100k_ordered_check',command,1,True,True)
   for scale in [100,1000]:
    cmd=[x.replace('100k',f'{scale}k') for x in command]
    for ordered in [True,False]: run(f'{dataset}_{scale}k_'+('ordered' if ordered else 'pull'),cmd,1,ordered)
  for dataset in ['twitter','friendster']:
   data=ROOT/'data/i17_scaling_20260911'/dataset
   start=time.monotonic()
   while not (data/'ready.json').exists():
    if (data/'status.json').exists() and json.loads((data/'status.json').read_text())['state']=='failed': raise RuntimeError(dataset+' generation failed')
    if time.monotonic()-start>86400: raise TimeoutError('data generation wait')
    state(state='waiting_data',active=dataset,child_pid=None,data_status=str(data/'status.json')); time.sleep(15)
   for scale in [100,1000,10000]:
    prefix=f'{dataset}_{scale}k'
    command=json.loads((ROOT/'logs/i17b5_20260910/b542_radix_single/manifest.json').read_text())['command']
    replacements={'--graphfile=':str(data/f'input_{prefix}.txt'),'--updatefile=':str(data/f'update_{prefix}.txt'),'--update_size=':str(data/f'stream_size_{prefix}.txt')}
    command=[next((k+v for k,v in replacements.items() if x.startswith(k)),x) for x in command]
    if dataset=='twitter':
     command=['--source_node=28512093' if x.startswith('--source_node=') else x for x in command]
    for shards in [64,1]:
     state(state='running'); run(f'{prefix}_s{shards}',command,shards,False)
   # Full-stage distance/witness checks only at the largest new scale.
   run(f'{dataset}_10000k_check',command,64,False,True)
  state(state='completed',active=None,child_pid=None,finished_utc=now())
 except BaseException as e:
  if child and child.poll() is None:
   child.send_signal(signal.SIGINT)
   try: child.wait(timeout=20)
   except subprocess.TimeoutExpired: child.kill(); child.wait()
  state(state='failed',error=repr(e),finished_utc=now()); raise
if __name__=='__main__': main()
