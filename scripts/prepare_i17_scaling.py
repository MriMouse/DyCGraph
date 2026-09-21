#!/usr/bin/env python3
"""Streaming FS/TW cohort: shared base/ID map, true updates per batch, nested scales."""
import argparse, importlib.util, json, os, time
from pathlib import Path
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('fs_generator',ROOT/'data/prepare_experiment_Friendster.py')
f=importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name]=f
spec.loader.exec_module(f)

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--dataset',choices=['friendster','twitter'],required=True)
 p.add_argument('--output',type=Path,required=True)
 p.add_argument('--source',type=Path)
 p.add_argument('--binary-source',action='store_true')
 p.add_argument('--scales',default='100000,1000000,10000000')
 p.add_argument('--batches',type=int,default=2)
 a=p.parse_args(); scales=sorted(set(map(int,a.scales.split(','))))
 if a.batches<1 or any(k<=0 or k%2 for k in scales): p.error('positive even scales required')
 out=a.output.resolve(); out.mkdir(parents=True,exist_ok=False)
 source=a.source or Path('/home/wangshaoyan/proJect/DataSet/'+('com-friendster.ungraph.txt' if a.dataset=='friendster' else 'twitter-2009_bin/edges_u64.bin'))
 binary=a.binary_source or a.dataset=='twitter'; chunk_size=2_000_000
 identity=lambda:dict(bytes=source.stat().st_size,mtime_ns=source.stat().st_mtime_ns)
 manifest=dict(dataset=a.dataset,source=str(source),source_identity=identity(),batches=a.batches,scales=scales,seed=45 if a.dataset=='friendster' else 20260327,base_ratio=.5 if a.dataset=='friendster' else .1,
  semantics='Same base and full-source dense sorted ID map for every scale; each batch takes a nested prefix of independent hash-ranked insertion/deletion pools. Unique source occurrence indices; duplicates in source retain multigraph occurrence semantics. Sentinel self-loop reserves full ID universe. New cohort, not directly paired to historical data.')
 def status(stage,**extra):
  temp=out/'status.tmp'; temp.write_text(json.dumps(dict(state=stage,pid=os.getpid(),updated=time.time(),**extra),indent=2)); temp.replace(out/'status.json')
 def chunks():
  if binary:
   mm=np.memmap(source,dtype=np.uint64,mode='r')
   for start in range(0,len(mm),chunk_size):
    x=np.asarray(mm[start:start+chunk_size]); yield np.column_stack(((x>>np.uint64(32)).astype(np.uint32),(x&np.uint64(0xffffffff)).astype(np.uint32)))
  else: yield from f.iter_edge_chunks(source,chunk_size)
 try:
  status('mapping'); present=np.zeros(1<<27,dtype=np.bool_); total=0
  for c in chunks():
   present=f.ensure_id_capacity(present,int(c.max())); present[c[:,0]]=True; present[c[:,1]]=True; total+=len(c)
   status('mapping',scanned_edges=total)
  mapping=np.cumsum(present,dtype=np.uint32); nodes=int(mapping[-1]); mapping-=np.uint32(1); mapping[~present]=f.UINT32_MAX; del present
  # Discard candidates worse than the retained maximum before concatenation.
  original=f.keep_smallest_k
  def filtered(ch,ci,nh,ni,k):
   if len(ch)==k:
    mask=nh<=ch.max(); nh=nh[mask]; ni=ni[mask]
   return original(ch,ci,nh,ni,k)
  f.keep_smallest_k=filtered
  status('selecting',total_edges=total,nodes=nodes)
  sel=f.make_config_selection(max(scales),0,total,out,manifest['base_ratio'],a.batches,manifest['seed'],5_000_000)
  status('writing_base',total_edges=total)
  base=out/'input_shared.txt'; threshold=np.uint64(int(manifest['base_ratio']*(2**64-1))); seen=written=0
  with (out/'input_shared.tmp').open('w',buffering=16<<20) as stream:
   for c in chunks():
    src=mapping[c[:,0]]; dst=mapping[c[:,1]]; idx=np.arange(seen,seen+len(c),dtype=np.uint64)
    mask=f.splitmix64_np(idx ^ np.uint64(manifest['seed']))<=threshold
    f.write_edges(stream,src[mask],dst[mask]); written+=int(mask.sum())
    f.fill_selected_edges(sel,seen,src,dst); seen+=len(c); status('writing_base',scanned_edges=seen,total_edges=total)
   stream.write(f'{nodes-1} {nodes-1}\n')
  (out/'input_shared.tmp').replace(base)
  max_each=max(scales)//2
  for scale in scales:
   status('writing_updates',scale=scale)
   prefix=f'{a.dataset}_{scale//1000}k'; update=out/f'update_{prefix}.txt'
   with update.open('w',buffering=16<<20) as stream:
    for b in range(a.batches):
     for op,edges in [('d',sel.delete_edges_hash_order),('a',sel.insert_edges_hash_order)]:
      take=edges[b*max_each:b*max_each+scale//2]
      np.savetxt(stream,take,fmt=op+' %u %u 1')
   (out/f'stream_size_{prefix}.txt').write_text(f'{scale//2} {scale//2}\n'*a.batches)
   os.link(base,out/f'input_{prefix}.txt')
  if seen!=total or identity()!=manifest['source_identity']: raise RuntimeError('Source changed or count mismatch')
  manifest.update(nodes=nodes,source_edges=total,base_edges=written+1,base_sentinel=nodes-1)
  (out/'ready.json').write_text(json.dumps(manifest,indent=2)+'\n'); status('completed')
 except BaseException as e:
  status('failed',error=repr(e)); raise
if __name__=='__main__': main()
