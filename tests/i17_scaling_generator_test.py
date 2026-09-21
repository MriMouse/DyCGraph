"""Verify true per-batch counts, shared base and legal nested updates."""
import json, subprocess, sys, tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temporary:
 d=Path(temporary); source=d/'source.txt'
 source.write_text(''.join(f'{u} {v}\n' for u in range(40) for v in range(40) if u!=v))
 out=d/'cohort'
 # Scales below 1k would collide in filenames, so use sufficient distinct scales.
 source.write_text(''.join(f'{u} {v}\n' for u in range(160) for v in range(160) if u!=v))
 subprocess.run([sys.executable,str(ROOT/'scripts/prepare_i17_scaling.py'),'--dataset','friendster','--source',str(source),'--output',str(out),'--scales','1000,2000','--batches','2'],check=True,stdout=subprocess.DEVNULL)
 ready=json.loads((out/'ready.json').read_text()); assert ready['scales']==[1000,2000]
 base={tuple(map(int,l.split())) for l in (out/'input_shared.txt').read_text().splitlines()}
 operations={}
 for k in [1000,2000]:
  prefix=f'friendster_{k//1000}k'
  assert (out/f'input_{prefix}.txt').stat().st_ino==(out/'input_shared.txt').stat().st_ino
  assert (out/f'stream_size_{prefix}.txt').read_text()==f'{k//2} {k//2}\n'*2
  lines=(out/f'update_{prefix}.txt').read_text().splitlines(); assert len(lines)==2*k
  ops=[(p[0],(int(p[1]),int(p[2]))) for p in map(str.split,lines)]
  assert len(set(ops))==len(ops)
  graph=set(base)
  for op,e in ops:
   if op=='d': assert e in graph; graph.remove(e)
   else: assert e not in graph; graph.add(e)
  operations[k]=[set(ops[b*k:(b+1)*k]) for b in range(2)]
 for b in range(2): assert operations[1000][b] <= operations[2000][b]
 print('Generator counts, shared base, nested batches and update legality passed')
