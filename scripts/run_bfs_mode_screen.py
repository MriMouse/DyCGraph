#!/usr/bin/env python3
"""Small synthetic BFS mode screen, isolated from the NUMA0/GPU0 experiment.

Six serial runs, two batches each. Never changes or signals another process.
Input generation and the runner must execute on NUMA1 (see README/report).
"""
import argparse
from collections import deque
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def save(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n')
    tmp.replace(path)


def checksum(distances):
    value = 1469598103934665603
    for node, d in enumerate(distances):
        if d != 2**32 - 1:
            value ^= node + 0x9e3779b97f4a7c15 + (d << 6) + (d >> 2)
            value = value * 1099511628211 & (2**64 - 1)
    return value


def bfs(n, neighbors):
    d = [2**32 - 1] * n
    d[0] = 0
    queue = deque([0])
    while queue:
        u = queue.popleft()
        for v in neighbors(u):
            if d[v] == 2**32 - 1:
                d[v] = d[u] + 1
                queue.append(v)
    return checksum(d)


def generate(folder):
    specs = {}
    # Unique directed edges; retain k=0 ring edges through both batches.
    n, changed = 65536, 62500
    dst = lambda u, k: (u + 4093 * k + 1) % n
    folder.mkdir(parents=True, exist_ok=False)
    with (folder / 'large.graph').open('w') as f:
        for u in range(n):
            for k in range(16):
                f.write(f'{u} {dst(u,k)}\n')
    with (folder / 'large.updates').open('w') as f:
        for delete_slots, add_slots in [(range(8,16), range(16,24)),
                                         (range(16,24), range(8,16))]:
            for action, slots in [('d', delete_slots), ('a', add_slots)]:
                for u in range(changed):
                    for k in slots:
                        f.write(f'{action} {u} {dst(u,k)} 1\n')
    (folder / 'large.sizes').write_text('500000 500000\n' * 2)
    specs['large'] = dict(nodes=n, edges=n*16, updates_per_batch=1000000,
                         final_checksum=bfs(n, lambda u: (dst(u,k) for k in range(16))))
    # Bidirectional two-lane road with sparse connecting rungs, diameter ~2048.
    length, n = 2048, 4096
    edges = set()
    def pair(u, v):
        edges.add((u, v)); edges.add((v, u))
    for lane in (0, length):
        for u in range(lane, lane + length - 1):
            pair(u, u+1)
    for u in range(0, length, 16):
        pair(u, u+length)
    dels, adds = [], []
    for u in range(32, 2048-64, 64):
        dels += [(u, u+1), (u+1, u)]
        adds += [(u, u+48), (u+48, u)]
    (folder / 'road.graph').write_text(''.join(f'{u} {v}\n' for u,v in sorted(edges)))
    with (folder / 'road.updates').open('w') as f:
        for deleted, added in [(dels, adds), (adds, dels)]:
            for action, records in [('d', deleted), ('a', added)]:
                for u,v in records:
                    f.write(f'{action} {u} {v} 1\n')
    (folder / 'road.sizes').write_text(f'{len(adds)} {len(dels)}\n' * 2)
    adj = [[] for _ in range(n)]
    for u,v in edges:
        adj[u].append(v)
    specs['road'] = dict(nodes=n, edges=len(edges), updates_per_batch=len(adds)+len(dels),
                        final_checksum=bfs(n, lambda u: adj[u]))
    return specs


def gpu_state(gpu):
    fields = subprocess.check_output(['nvidia-smi', '-i', str(gpu),
        '--query-gpu=memory.used,utilization.gpu', '--format=csv,noheader,nounits'], text=True)
    return [int(x.strip()) for x in fields.strip().split(',')]


def gpu_pids(gpu):
    text = subprocess.check_output(['nvidia-smi', '-i', str(gpu),
        '--query-compute-apps=pid', '--format=csv,noheader,nounits'], text=True)
    return {int(x) for x in text.splitlines() if x.strip().isdigit()}


def local_free_kb():
    return int(re.search(r'MemFree:\s+(\d+)',
        Path('/sys/devices/system/node/node1/meminfo').read_text()).group(1))


def report(out, rows):
    lines = ['# BFS synthetic mode screening', '',
             'Two batches per run; paper_algorithm_ms = sum of complete P0 batch timers. '
             'No extrapolation to ten batches or real road/social graphs. Single runs, no confidence interval.', '',
             '| graph | maintenance | road mode | batch 0 ms | batch 1 ms | paper_algorithm_ms | checksum |',
             '|---|---|---|---:|---:|---:|---|']
    for r in rows:
        a,b = r['batch_ms']
        lines.append(f"| {r['graph']} | {r['maintenance']} | {r['road']} | {a:.3f} | {b:.3f} | {r['paper_algorithm_ms']:.3f} | passed |")
    (out / 'report.md').write_text('\n'.join(lines)+'\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--binary', type=Path, required=True)
    ap.add_argument('--cache', type=int, required=True)
    args = ap.parse_args()
    gpu = 2
    if not os.sched_getaffinity(0) <= {24,25}:
        raise RuntimeError('Run with numactl --physcpubind=24,25 --membind=1')
    lock = open('/tmp/cggraph_bfs_gpu2.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if (out/'status.json').exists():
        raise RuntimeError('Output already contains a run; choose a new directory')
    rows, child = [], None
    try:
        if any(gpu_state(gpu)) or gpu_pids(gpu):
            raise RuntimeError('GPU2 occupied; refusing to run')
        if local_free_kb() < 3 * 1024**2:
            raise RuntimeError('NUMA1 free memory below 3 GiB')
        save(out/'status.json', dict(state='preparing', pid=os.getpid()))
        data = Path('/dev/shm') / f'bfs_modes_{os.getuid()}_{os.getpid()}'
        specs = generate(data)
        binary = out/'hybrid_bfs'
        shutil.copy2(args.binary, binary)
        shutil.copy2(__file__, out/'runner_frozen.py')
        tasks = [('large','regular',0), ('large','large',0), ('large','auto',0),
                 ('road','regular',0), ('road','regular',1), ('road','large',1)]
        save(out/'manifest.json', dict(specs=specs, tasks=tasks, data=str(data),
             cache=args.cache, gpu=gpu, cpus=[24,25], numa=1, workers=2,
             binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
             inputs={p.name:dict(bytes=p.stat().st_size, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                     for p in data.iterdir()},
             note='Synthetic, 6 serial runs, 2 batches; check=false, final independent BFS checksum.'))
        for idx,(graph,maintenance,road) in enumerate(tasks):
            time.sleep(2)
            if any(gpu_state(gpu)) or gpu_pids(gpu):
                raise RuntimeError('GPU2 became occupied; stopping queue')
            if local_free_kb() < 3 * 1024**2:
                raise RuntimeError('NUMA1 free memory below 3 GiB; stopping queue')
            env = {k:v for k,v in os.environ.items() if not k.startswith('CG_')}
            env.update(CUDA_VISIBLE_DEVICES='2', CG_MUTATION_WORKERS='2', CG_REVERSE_SHARDS='64',
                CG_BATCH_MAINTENANCE=maintenance, CG_ORDERED_REPAIR=str(road),
                CG_INSERTION_SCHEDULE='block', CG_MERGE_PUBLICATION_SOURCES='1',
                CG_BULK_SOURCE_GROUPS='0', CG_PARALLEL_SOURCE_RADIX='0',
                CG_PARALLEL_REVERSE_RADIX='0', CG_REUSE_DELETE_POSITIONS='0', CG_COMM_METER='0')
            cmd = [str(binary), f'--graphfile={data}/{graph}.graph',
                   f'--updatefile={data}/{graph}.updates', f'--update_size={data}/{graph}.sizes',
                   '--format=market_big', '--weight_num=1', '--weight=1', '--source_node=0',
                   '--SEGMENT=32', '--n_stream=3', '--hybrid=0', f'--cache={args.cache}',
                   '--check=false', '--verbose=false', '--bfs_max_batches=2', '--bfs_print_checksum=true']
            save(out/f'{idx}.command.json', dict(argv=cmd, env={k:v for k,v in env.items()
                 if k.startswith('CG_') or k=='CUDA_VISIBLE_DEVICES'}))
            save(out/'status.json', dict(state='running', pid=os.getpid(), task=idx,
                 graph=graph, maintenance=maintenance, road=road, completed=len(rows)))
            start = time.monotonic()
            max_rss = peak_gpu = 0
            with (out/f'{idx}.log').open('w') as log:
                child = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT,
                                         stdin=subprocess.DEVNULL, start_new_session=True)
                while child.poll() is None:
                    time.sleep(2)
                    if child.poll() is not None: break
                    if time.monotonic()-start > 180:
                        raise RuntimeError('Run exceeded 180s limit')
                    foreign = gpu_pids(gpu)-{child.pid}
                    if foreign:
                        raise RuntimeError(f'Another GPU2 client appeared: {foreign}; stop own run')
                    used,_ = gpu_state(gpu)
                    peak_gpu = max(peak_gpu, used)
                    status = Path(f'/proc/{child.pid}/status')
                    if status.exists():
                        m = re.search(r'VmRSS:\s+(\d+)',status.read_text())
                        if m: max_rss = max(max_rss,int(m.group(1)))
                    if used > 4096 or max_rss > 2*1024**2 or local_free_kb() < 2*1024**2:
                        raise RuntimeError('Own-run resource limit reached; stopping')
                if child.wait() != 0:
                    raise RuntimeError(f'Task {idx} failed, see {idx}.log')
            text = (out/f'{idx}.log').read_text()
            values = [float(x) for x in re.findall(r'\[P0-TIMER\]\[BFS\]\[batch \d+\] total_batch: ([\d.]+)',text)]
            sums = re.findall(r'\[BFS-FINAL-CHECK\] distance_checksum=(\d+)',text)
            modes = re.findall(r'\[I20-MODE\]\[batch \d+\] maintenance=(\w+)',text)
            schedules = re.findall(r'\[I22-SCHEDULE\] mode=(\w+)',text)
            assert len(values)==2 and sums==[str(specs[graph]['final_checksum'])], (values,sums)
            assert modes==[('large' if maintenance=='auto' else maintenance)]*2, modes
            assert schedules==[('ordered' if road else 'block')]*2, schedules
            if road: assert len(re.findall(r'\[I17-ORDERED\]\[batch',text))==2
            rows.append(dict(graph=graph, maintenance=maintenance, road=road, batch_ms=values,
                 paper_algorithm_ms=sum(values), distance_checksum=int(sums[0]), modes=modes,
                 schedules=schedules, sampled_peak_rss_kb=max_rss or None, sampled_peak_gpu_mib=peak_gpu or None,
                 monitored_elapsed_s=time.monotonic()-start))
            save(out/'results.json', rows); report(out,rows)
        save(out/'status.json',dict(state='completed', completed=len(rows), pid=os.getpid()))
    except BaseException as exc:
        if child and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL); child.wait()
        save(out/'status.json',dict(state='stopped', completed=len(rows), error=str(exc),pid=os.getpid()))
        raise


if __name__=='__main__':
    main()
