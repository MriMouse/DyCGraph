#!/usr/bin/env python3
"""One serial development run using an existing cohort command verbatim."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import time

p = argparse.ArgumentParser()
p.add_argument('--command', type=Path, required=True)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--meter', action='store_true')
p.add_argument('--correctness', action='store_true')
p.add_argument('--numa-node', type=int, help='Bind both CPU execution and host memory for a controlled pair')
args = p.parse_args()
spec = json.loads(args.command.read_text())
argv = [str(args.binary.resolve()), *spec['argv'][1:]]
if args.correctness:
    argv = [a for a in argv if not a.startswith('--check=')] + ['--check=true']
env = {**os.environ, **spec['env'], 'CG_COMM_METER': '1' if args.meter else '0'}
busy = subprocess.check_output([
    'nvidia-smi', '-i', env.get('CUDA_VISIBLE_DEVICES', '0'),
    '--query-compute-apps=pid', '--format=csv,noheader'], text=True).strip()
if busy:
    raise SystemExit(f'GPU occupied: {busy}')
memory = subprocess.check_output([
    'nvidia-smi', '-i', env.get('CUDA_VISIBLE_DEVICES', '0'),
    '--query-gpu=memory.used', '--format=csv,noheader,nounits'], text=True).strip()
if any(int(value.strip()) != 0 for value in memory.splitlines()):
    raise SystemExit(f'GPU memory occupied (MiB): {memory}')
args.output.mkdir(parents=True, exist_ok=False)
record = {'argv': argv, 'env': spec['env'], 'meter': args.meter,
          'source_command': str(args.command.resolve()), 'status': 'running',
          'numa_node': args.numa_node}
status = args.output / 'status.json'
status.write_text(json.dumps(record, indent=2) + '\n')
start = time.monotonic()
with (args.output / 'run.log').open('w') as log:
    placement = ([] if args.numa_node is None else
                 ['numactl', f'--cpunodebind={args.numa_node}', f'--membind={args.numa_node}'])
    result = subprocess.run(['/usr/bin/time', '-f', 'I17_MAX_RSS_KB=%M', *placement, *argv], env=env, cwd=spec['cwd'], stdout=log,
                            stderr=subprocess.STDOUT)
text = (args.output / 'run.log').read_text()
times = re.findall(r'\[P0-TIMER\]\[SSSP\]\[batch (\d+)\] total_batch: ([\d.]+) ms', text)
expected = next(int(a.split('=', 1)[1]) for a in argv if a.startswith('--sssp_max_batches='))
record.update(exit_code=result.returncode, wall_s=time.monotonic()-start,
              batches=times, paper_ms=sum(float(ms) for _, ms in times),
              checksums=re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', text))
rss = re.findall(r'^I17_MAX_RSS_KB=(\d+)$', text, re.MULTILINE)
record['max_rss_kb'] = int(rss[-1]) if rss else None
valid = (result.returncode == 0 and [int(b) for b, _ in times] == list(range(expected))
         and len(record['checksums']) == 1
         and not re.search(r'\[SSSP-(?:DELETE-STAGE|BATCH|BELLMAN)-CHECK\][^\n]*\bfailed\b', text))
if '--check=true' in argv:
    for label in ('DELETE-STAGE', 'BATCH'):
        passed = re.findall(r'\[SSSP-' + label + r'-CHECK\]\[batch (\d+)\] passed', text)
        valid = valid and [int(batch) for batch in passed] == list(range(expected))
    valid = valid and '[SSSP-BELLMAN-CHECK] passed' in text
record['status'] = 'complete' if valid else 'failed'
status.write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record, indent=2))
raise SystemExit(0 if valid else 1)
