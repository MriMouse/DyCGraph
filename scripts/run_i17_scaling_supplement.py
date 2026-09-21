#!/usr/bin/env python3
"""Only missing evidence: reachable TW source and FS cache coexistence diagnostic."""
import json, os, subprocess, time, signal
from pathlib import Path
from run_i17_eu_background import save, summarize
ROOT=Path(__file__).resolve().parents[1]
old=ROOT/'logs/i17_scaling_20260911/experiments'
out=ROOT/'logs/i17_scaling_20260911/supplement'
out.mkdir(exist_ok=False)
status={'state':'running','pid':os.getpid(),'completed':[]}; results={}; child=None
runs=[('fs10000k_cache0_check','friendster_10000k_s64',{'--cache=':'0'},True)]
for scale in [100,1000,10000]:
 runs.append((f'tw{scale}k_source28512093',f'twitter_{scale}k_s64',{'--source_node=':'28512093'},scale==10000))
try:
 for name,base,replace,check in runs:
  cfg=json.loads((old/(base+'.manifest.json')).read_text())
  cfg['command']=[next((k+v for k,v in replace.items() if x.startswith(k)),x) for x in cfg['command']]
  save(out/(name+'.manifest.json'),cfg)
  cmd=['python3',str(ROOT/'scripts/run_i17b_reverse_probe.py'),'--binary',str(old/'hybrid_sssp'),'--output',str(out/name),'--manifest',str(out/(name+'.manifest.json')),'--batches','2','--shards','64','--timeout','1800']
  if check: cmd+=['--check']
  with (out/(name+'.driver.log')).open('w') as log:
   child=subprocess.Popen(cmd,env={**os.environ,'CG_ORDERED_REPAIR':'0'},stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   while child.poll() is None:
    status.update(active=name,child_pid=child.pid,updated=time.time()); save(out/'status.json',status); time.sleep(10)
  # A failed capacity diagnostic must not prevent independent TW evidence.
  if child.returncode: results[name]={'failed':True,'returncode':child.returncode}
  else: results[name]=summarize(out/name)
  status['completed'].append(name); save(out/'results.json',results)
 status.update(state='completed_with_failures' if any(r.get('failed') for r in results.values()) else 'completed',active=None,child_pid=None)
except BaseException as e:
 if child and child.poll() is None:
  child.send_signal(signal.SIGINT)
  child.wait(timeout=20)
 status.update(state='failed',error=repr(e))
finally: save(out/'status.json',status)
