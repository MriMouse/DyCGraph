#!/usr/bin/env python3
"""Run one bounded reverse-preparation probe, preserving command and evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--binary', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--manifest', type=Path, default=ROOT / 'logs/i17b5_20260910/b542_radix_single/manifest.json')
p.add_argument('--batches', type=int, default=2, choices=range(1, 11))
p.add_argument('--check', action='store_true')
p.add_argument('--shards', type=int, choices=(1, 64), default=1)
p.add_argument('--timeout', type=int, default=1200)
a = p.parse_args()
if a.timeout <= 0:
    p.error("--timeout must be positive")
command = json.loads(a.manifest.read_text())['command']
command[0] = str(a.binary.resolve())
command = [f'--sssp_max_batches={a.batches}' if x.startswith('--sssp_max_batches=') else
           f'--check={str(a.check).lower()}' if x.startswith('--check=') else x for x in command]
inputs = []
for arg in command:
    if arg.startswith(('--graphfile=', '--updatefile=', '--update_size=')):
        path = Path(arg.split('=', 1)[1])
        stat = path.stat()
        inputs.append(dict(path=str(path.resolve()), bytes=stat.st_size, mtime_ns=stat.st_mtime_ns))
busy = subprocess.check_output([
    'nvidia-smi', '-i', '0', '--query-compute-apps=pid', '--format=csv,noheader,nounits'
], text=True).strip()
if busy:
    raise SystemExit(f'GPU 0 occupied; probe not started (PIDs: {busy})')
a.output.mkdir(parents=True, exist_ok=False)
env = dict(os.environ, CUDA_VISIBLE_DEVICES='0', CG_MUTATION_WORKERS='20', CG_REVERSE_SHARDS=str(a.shards))
manifest = dict(command=command, binary_sha256=hashlib.sha256(a.binary.read_bytes()).hexdigest(),
                inputs=inputs, cpu_affinity=sorted(os.sched_getaffinity(0)), environment={k: env[k] for k in ('CUDA_VISIBLE_DEVICES', 'CG_MUTATION_WORKERS', 'CG_REVERSE_SHARDS')})
(a.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
start = time.monotonic()
with (a.output / 'run.log').open('w') as stream:
    try:
        process = subprocess.Popen(['/usr/bin/time', '-v', '-o', str(a.output.resolve() / 'time.log'), *command],
                                   cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        code = process.wait(timeout=a.timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        code = 'timeout'
    except KeyboardInterrupt:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise
content = (a.output / 'run.log').read_text()
summary = dict(returncode=code, elapsed_seconds=time.monotonic() - start)
for key, pattern in {
    'paper_ms': r'\[P0-TIMER\].*?total_batch: ([\d.]+)',
    'reverse_ms': r'\[C3-EFFECTIVE\].*?reverse_prepare_ms=([\d.]+)',
    'updates': r'\[I14-BATCH\].*?updates=(\d+)',
    'effective_records': r'\[C3-EFFECTIVE\].*?records=(\d+)',
}.items():
    summary[key] = [float(x) for x in re.findall(pattern, content)]
summary['reverse_detail'] = re.findall(r'\[I17-REVERSE\].*', content)
summary['checks'] = re.findall(r'\[SSSP-(?:FINAL-CHECK|DELETE-STAGE-CHECK|BATCH-CHECK|BELLMAN-CHECK)\].*', content)
summary['shards_verified'] = re.findall(r'\[I17-REVERSE-CONFIG\] shards=(\d+)', content) == [str(a.shards)]
summary['passed'] = (code == 0 and len(summary['paper_ms']) == a.batches
                     and 'Overall: Test passed' in content and summary['shards_verified'])
if a.check:
    stages = re.findall(r'\[SSSP-(?:DELETE-STAGE-CHECK|BATCH-CHECK)\].*', content)
    required = {'source_ok': 1, 'relaxable_edges': 0, 'missing_tight_witnesses': 0}
    valid = len(stages) == 2 * a.batches
    for line in stages:
        fields = dict(re.findall(r'(\w+)=(\d+)', line))
        valid = valid and all(fields.get(key) == str(value) for key, value in required.items())
    summary['distance_and_tight_witness_checks_passed'] = valid
    # Stored-parent races remain diagnostic under the frozen production contract.
    summary['stored_parent_invalid_vertices'] = [int(x) for x in re.findall(
        r'invalid_parent_witness=(\d+)', '\n'.join(stages))]
    summary['passed'] = summary['passed'] and valid
(a.output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary, indent=2), flush=True)
raise SystemExit(0 if summary['passed'] else 1)
