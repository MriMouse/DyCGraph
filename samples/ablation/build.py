#!/usr/bin/env python3
"""Compile prepared variants serially, without accessing a GPU."""
import argparse, hashlib, json, os, subprocess
from pathlib import Path

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('prepared',type=Path)
    p.add_argument('--variants',nargs='+')
    p.add_argument('--cpu',default='39',help='single CPU for low-priority compilation')
    args=p.parse_args();root=args.prepared.resolve()
    manifest=json.loads((root/'manifest.json').read_text())
    variants=args.variants or manifest['variants']
    if not set(variants)<=set(manifest['variants']):p.error('unprepared variant')
    env=os.environ.copy();env['CUDA_VISIBLE_DEVICES']=''
    prefix=['nice','-n','19','taskset','-c',args.cpu]
    for v in variants:
        src=root/v/'src';build=root/v/'build'
        expected=json.loads((root/v/'source_manifest.json').read_text())
        for name,value in expected.items():
            if sha(src/name)!=value:raise RuntimeError(f'Source changed: {src/name}')
        print('BUILD',v,flush=True)
        with (root/v/'configure.log').open('w') as log:
            subprocess.run(prefix+['cmake','-S',str(src),'-B',str(build),'-DCMAKE_BUILD_TYPE=Release',
                '-DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.1','-DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.1/bin/nvcc',
                '-DCMAKE_CUDA_ARCHITECTURES=70','-DCMAKE_CXX_COMPILER=/usr/bin/g++-12','-DCUDA_HOST_COMPILER=/usr/bin/gcc-12'],
                env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        targets=['hybrid_sssp','hybrid_bfs']+(['ablation_pma_bridge_test'] if v[0]=='0' else [])
        with (root/v/'build.log').open('w') as log:
            subprocess.run(prefix+['cmake','--build',str(build),'--target',*targets,'-j1'],env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        if v[0]=='0':
            with (root/v/'pma_bridge_test.log').open('w') as log:
                subprocess.run(prefix+[str(build/'ablation_pma_bridge_test')],env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=60)
        (root/v/'binary_manifest.json').write_text(json.dumps({t:sha(build/t) for t in targets},indent=2)+'\n')
        print('BUILT',v,flush=True)
if __name__=='__main__':main()
