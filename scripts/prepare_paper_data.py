#!/usr/bin/env python3
"""Build Grapin paper-style streaming graphs, 10 mixed batches at 1k/10k/100k.

Each original edge occurrence has equal probability of being chosen. We sample
1,000,000 distinct occurrence indices uniformly without replacement, assign
half to insertion and half to deletion, and nest the three workload sizes.
For each size the initial graph is the entire original graph minus its selected
insertion occurrences. Deletion occurrences remain in the initial graph.
Duplicates and loops are preserved as occurrences. Matrix Market rows are used
as stored, matching this repository's older generators; symmetric headers do
not cause implicit reverse-edge expansion. Files end in .part until complete.
"""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import random
import re
import struct
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[1]
DATA=ROOT/'data'
RAW=Path('/home/wangshaoyan/proJect/DataSet')
SOURCES={
 'OK':(RAW/'com-Orkut.mtx','mtx'),
 'WK':(RAW/'out.wikipedia_link_en','text'),
 'TW':(RAW/'twitter-2009_bin/edges_u64.bin','bin'),
 'FS':(RAW/'com-friendster.ungraph.txt','friendster'),
 'EU':(RAW/'europe_osm/europe_osm.mtx','mtx'),
 'USA':(DATA/'road_usa/road_usa.mtx','mtx'),
 'UK':(DATA/'uk-2007-05.graph','uk'),
 'RMAT':(None,'rmat'),
}
EACH={'1k':5000,'10k':50000,'100k':500000}

def source_edges(path:Path|None,mode:str,backend:Path)->int:
 if mode=='rmat':return 1_610_000_000
 if mode=='bin':
  size=path.stat().st_size
  if size%8:raise ValueError('binary edge source is not divisible by 8')
  return size//8
 if mode=='uk':
  m=re.search(r'^arcs=(\d+)$',path.with_suffix('.properties').read_text(),re.M)
  if not m:raise ValueError('UK properties lacks arcs')
  return int(m.group(1))
 if mode=='mtx':
  with path.open('rb') as f:
   for line in f:
    if line.startswith(b'%'):continue
    return int(line.split()[2])
 if mode=='friendster':
  with path.open('rb') as f:
   for line in f:
    m=re.search(rb'Nodes:\s*\d+\s+Edges:\s*(\d+)',line)
    if m:return int(m.group(1))
    if not line.startswith(b'#'):break
 return int(subprocess.check_output([backend,'count',str(path),'text'],text=True))

def write_picks(path:Path,edges:int,seed:int)->None:
 if edges<1_000_000:raise ValueError('source has fewer than one million edge occurrences')
 rng=random.Random(seed)
 chosen=rng.sample(range(edges),1_000_000)
 rng.shuffle(chosen)
 insert=chosen[:500_000];delete=chosen[500_000:]
 records=sorted(((index,0,rank) for rank,index in enumerate(insert)),key=lambda x:x[0])
 records.extend((index,1,rank) for rank,index in enumerate(delete))
 records.sort(key=lambda x:x[0])
 with path.open('wb',buffering=8<<20) as f:
  pack=struct.Struct('<QII').pack
  for row in records:f.write(pack(*row))

def compile_backend(output:Path)->Path:
 exe=output/'.paper_data_stream'
 source=ROOT/'scripts/paper_data_stream.cpp'
 if not exe.exists() or source.stat().st_mtime_ns>exe.stat().st_mtime_ns:
  subprocess.run(['g++','-O3','-std=c++17','-Wall','-Wextra',str(source),'-o',str(exe)],check=True)
 return exe

def write_status(folder:Path,**items)->None:
 tmp=folder/'status.json.tmp';tmp.write_text(json.dumps({'time':time.time(),'pid':os.getpid(),**items},indent=2)+'\n');tmp.replace(folder/'status.json')

def run_one(name:str,output:Path,backend:Path,seed:int)->None:
 source,mode=SOURCES[name]
 if source is not None and not source.is_file():raise FileNotFoundError(source)
 folder=output/name;folder.mkdir(parents=True,exist_ok=True)
 ready=folder/'ready.json'
 if ready.exists():print(f'{name}: already ready; skipping',flush=True);return
 if any(folder.glob('*.part')):
  for stem in ('input','update'):
   for suffix in EACH:
    for ending in ('.txt.part','.txt'):
     (folder/f'{stem}_{suffix}{ending}').unlink(missing_ok=True)
  for suffix in EACH:(folder/f'stream_size_{suffix}.txt').unlink(missing_ok=True)
  print(f'{name}: cleared incomplete previous attempt',flush=True)
 edges=source_edges(source,mode,backend)
 source_identity={'path':str(source.resolve()),'bytes':source.stat().st_size,'mtime_ns':source.stat().st_mtime_ns} if source else {'model':'classic R-MAT','scale':26,'probabilities':[.57,.19,.19,.05],'edges':edges}
 print(f'{name}: source edges={edges:,}, mode={mode}',flush=True)
 write_status(folder,state='sampling',source_edges=edges)
 picks=folder/'picks.bin'
 if not picks.exists():write_picks(picks,edges,seed)
 write_status(folder,state='generating',source_edges=edges)
 # WebGraph emits packed edges to the backend's stdin. Passing the .graph
 # pathname here would make the backend interpret compressed bytes as edges.
 generate_source='-' if mode=='uk' else str(source if source else '-')
 cmd=[str(backend),'generate',generate_source,'pipe' if mode=='uk' else mode,str(picks),str(folder),str(edges),str(seed),'26']
 if mode=='uk':
  jars=Path('/home/wangshaoyan/CGGraph/ligra/data')
  cp=':'.join(map(str,[jars/'WebGraph/webgraph-3.6.8.jar',*sorted((jars/'lib').glob('*.jar'))]))
  producer=subprocess.Popen(['java','-Xmx2g','-XX:ActiveProcessorCount=2','-cp',cp,str(ROOT/'scripts/PaperUkEdges.java'),str(source.with_suffix(''))],stdout=subprocess.PIPE)
  try: result=subprocess.run(cmd,stdin=producer.stdout,check=False)
  finally:producer.stdout.close()
  code=producer.wait()
  if result.returncode or code:raise RuntimeError(f'UK decoder={code}, generator={result.returncode}')
 else:subprocess.run(cmd,check=True)
 if source and (source.stat().st_size!=source_identity['bytes'] or source.stat().st_mtime_ns!=source_identity['mtime_ns']):raise RuntimeError('source changed during generation')
 for suffix,each in EACH.items():
  for stem in ('input','update'):
   part=folder/f'{stem}_{suffix}.txt.part';final=folder/f'{stem}_{suffix}.txt'
   if not part.is_file() or part.stat().st_size==0:raise RuntimeError(f'missing {part}')
   part.replace(final)
  (folder/f'stream_size_{suffix}.txt').write_text(f'{each//10} {each//10}\n'*10)
 metadata={'dataset':name,'source':source_identity,'source_edges':edges,'batches':10,'scales':list(EACH),'seed':seed,'initial_edges':{s:edges-n for s,n in EACH.items()},'insertions':EACH,'deletions':EACH,'semantics':'initial=all original edge occurrences except selected insertion occurrences; sampled deletions are initially present; 50/50 mixed operations in ten batches; smaller scales use nested selections','symmetric_mtx_expansion':False,'sparse_id_remap':'dense sorted full-source vertex IDs' if mode in ('friendster','bin') else None,'rmat_note':'independent stream with original model parameters, not byte-identical to old NumPy stream' if mode=='rmat' else None}
 temp=folder/'ready.json.tmp';temp.write_text(json.dumps(metadata,indent=2)+'\n');temp.replace(ready)
 write_status(folder,state='completed',source_edges=edges)
 print(f'{name}: completed',flush=True)

def main()->None:
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--datasets',nargs='+',choices=list(SOURCES),default=list(SOURCES))
 p.add_argument('--output',type=Path,default=DATA/'paper_data')
 p.add_argument('--seed',type=int,default=20260924)
 a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
 backend=compile_backend(a.output)
 for name in a.datasets:
  try:run_one(name,a.output,backend,a.seed+list(SOURCES).index(name))
  except Exception as exc:
   folder=a.output/name;folder.mkdir(parents=True,exist_ok=True)
   write_status(folder,state='failed',error=repr(exc))
   raise
if __name__=='__main__':main()
