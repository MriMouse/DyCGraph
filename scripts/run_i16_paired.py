#!/usr/bin/env python3
"""I16 fixed-binary three-batch A-B-B-A, GPU 0 only; A=pull, B=CPU PQ."""
import argparse
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
from run_i16_road_validation import ROOT, fields, gpu_idle, write_json


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(8*1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def parse_performance(text, cpu, expected_checksum, expected_reachable, batches=3, updates=100000, capture=False):
    if not capture and '[I16-SNAPSHOT]' in text:
        raise ValueError('Capture in performance log')
    if any(token in text for token in ('protocol_error=', 'Overall: Test failed',
                                       '[SSSP-DELETE-STAGE-CHECK]', '[SSSP-BATCH-CHECK]')):
        raise ValueError('Wrong path or runtime failure in performance log')
    rows = {}
    repair_tag = 'I16-CPU-REPAIR' if cpu else 'B2-GPU-REPAIR'
    if '[' + ('B2-GPU-REPAIR' if cpu else 'I16-CPU-REPAIR') + ']' in text:
        raise ValueError('Mixed repair executors')
    for tag in ('P0-TIMER', 'P0-ATTR', 'I14-BATCH', 'C3-PUBLISH', repair_tag):
        found = []
        for line in text.splitlines():
            if '['+tag+']' not in line:
                continue
            batch = re.search(r'\[batch (\d+)\]', line)
            if not batch:
                raise ValueError('Missing batch ID')
            row = fields(line)
            row['batch'] = int(batch[1])
            if tag == 'P0-TIMER':
                match = re.search(r'total_batch: ([0-9.]+) ms', line)
                if not match:
                    raise ValueError('Missing total timer')
                row['total_ms'] = float(match[1])
            if tag == 'C3-PUBLISH' and any(row.get(k) != 0 for k in ('stale_version_rejects', 'gpu_cpu_hash_mismatches')):
                raise ValueError('Publication failed')
            expected_updates = updates[row['batch']] if isinstance(updates, (list, tuple)) and row['batch'] < len(updates) else updates
            if tag == 'I14-BATCH' and row.get('updates') != expected_updates:
                raise ValueError('Wrong update count')
            if tag == repair_tag and 'affected' not in row:
                raise ValueError('Missing repair work')
            if tag == repair_tag and row['affected'] and not cpu and any(k not in row for k in ('incoming_edges','iterations','closure_ms')):
                raise ValueError('Incomplete GPU repair metrics')
            if tag == repair_tag and row['affected'] and cpu:
                if (any(k not in row for k in ('service_ms','gather_ms','setup_ms','closure_ms','parent_ms','scatter_ms',
                                               'temporary_device_bytes','avoided_incoming_device_bytes')) or
                    row['temporary_device_bytes'] > row['avoided_incoming_device_bytes']):
                    raise ValueError('Incomplete CPU service/budget record')
            found.append(row)
        if [r['batch'] for r in found] != list(range(batches)):
            raise ValueError('Incomplete or duplicate batches: '+tag)
        rows[tag] = found
    for timer, attr in zip(rows['P0-TIMER'], rows['P0-ATTR']):
        keys = ('deletion','add','hotness','candidate','eviction','compact','cache_load','residual')
        if any(k not in attr for k in keys) or abs(sum(attr[k] for k in keys)-timer['total_ms']) > max(.03,timer['total_ms']*.02):
            raise ValueError('Timer attribution mismatch')
    sums = re.findall(r'\[SSSP-FINAL-CHECK\] distance_checksum=(\d+)', text)
    reachable = re.findall(r'\[SSSP-FINAL-CHECK\] final_reachable=(\d+)', text)
    if sums != [str(expected_checksum)] or reachable != [str(expected_reachable)]:
        raise ValueError('Final state differs from verified three-batch reference')
    return {'checks': rows, 'sum_batch_ms': sum(r['total_ms'] for r in rows['P0-TIMER']),
            'distance_checksum': expected_checksum, 'reachable': expected_reachable}


def process_has_token(pid, token):
    if not token:
        return False
    try:
        return ('CG_I16_RUN_TOKEN='+token).encode() in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0')
    except (FileNotFoundError, PermissionError, ProcessLookupError):
        return False


def memory_sample(group, token=None):
    text = subprocess.check_output(['nvidia-smi','-i','0','--query-compute-apps=pid,used_gpu_memory',
                                    '--format=csv,noheader,nounits'], text=True, timeout=10)
    own, foreign = 0, []
    for line in text.strip().splitlines():
        pid, memory = [part.strip() for part in line.split(',')]
        try:
            if os.getpgid(int(pid)) == group or process_has_token(int(pid), token):
                own += int(memory)
            else:
                foreign.append(int(pid))
        except ProcessLookupError:
            continue
    return own, foreign


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--resume', action='store_true')
    args = parser.parse_args()
    directory = args.directory.resolve()
    directory.mkdir(parents=True, exist_ok=True)
    lock = (directory/'runner.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    status_path = directory/'status.json'
    results = {}
    if args.resume:
        old = json.loads(status_path.read_text())
        if old['state'] != 'blocked_resource':
            raise SystemExit('Resume only supported after resource blocking')
        results = old['results']
    elif status_path.exists():
        raise SystemExit('Use a new directory')
    def state(value, **extra):
        write_json(status_path, {'state': value,'pid': os.getpid(),'results': results,**extra})
    try:
        state('freezing')
        source = ROOT/'logs/i16_cpu_pq_validation_20260907'
        binary = directory/'hybrid_sssp'
        if not args.resume:
            if json.loads((source/'status.json').read_text())['state'] != 'completed':
                raise ValueError('CPU correctness prerequisite incomplete')
            shutil.copy2(source/'hybrid_sssp', binary)
            shutil.copy2(source/'manifest.json', directory/'reference_manifest.json')
            shutil.copy2(source/'correctness.json', directory/'reference_correctness.json')
            shutil.copytree(source/'sources', directory/'sources')
            shutil.copy2(__file__, directory/'runner.py')
            shutil.copy2(ROOT/'scripts/run_i16_road_validation.py', directory/'parser.py')
        reference = json.loads((directory/'reference_manifest.json').read_text())
        correctness = json.loads((directory/'reference_correctness.json').read_text())
        if sha(binary) != reference['binary_sha256']:
            raise ValueError('Binary differs from CPU correctness-tested binary')
        manifest = {'binary_sha256': reference['binary_sha256'],'gpu':0,'order':['A_gpu','B_cpu','B_cpu','A_gpu'],
                    'batches':3,'check':False,'timeout_seconds':7200,'memory_sample_interval_seconds':.5,
                    'memory_scope':'per-process nvidia-smi sampled peak, not exact allocator high-water; GNU time max RSS',
                    'commands':{},'files':reference['files']}
        if args.resume:
            manifest=json.loads((directory/'manifest.json').read_text())
        for entry in reference['commands']:
            cohort = entry['cohort']
            state('auditing',cohort=cohort)
            base = [arg for arg in entry['argv'][1:] if not arg.startswith(('--check=','--i16_cpu_pq='))]
            paths = [Path(arg.split('=',1)[1]) for arg in base if arg.startswith(('--graphfile=','--updatefile=','--update_size='))]
            stats = {}
            for path in paths:
                before = path.stat()
                cached = reference['files'][str(path)]
                if sha(path) != cached['sha256'] or before.st_size != cached['bytes']:
                    raise ValueError('Frozen input hash mismatch')
                stats[path] = (before.st_size,before.st_mtime_ns)
            for index, cpu in enumerate((False,True,True,False)):
                run = cohort+'_'+str(index)+('_B_cpu' if cpu else '_A_gpu')
                if run in results:
                    continue
                command = [str(binary)] + base + ['--check=false', '--i16_cpu_pq='+str(cpu).lower()]
                usage = directory/(run+'.usage.txt')
                actual = ['/usr/bin/time','-v','-o',str(usage)] + command
                manifest['commands'][run] = actual
                write_json(directory/'manifest.json',manifest)
                if not gpu_idle():
                    state('blocked_resource',run=run)
                    return 2
                for path, frozen in stats.items():
                    now=path.stat()
                    if (now.st_size,now.st_mtime_ns) != frozen:
                        raise ValueError('Input changed before launch')
                started=time.monotonic()
                samples=[]
                child=None
                try:
                    with (directory/(run+'.log')).open('w') as output:
                        child=subprocess.Popen(actual,stdout=output,stderr=subprocess.STDOUT,start_new_session=True,
                            env={**os.environ,'CUDA_VISIBLE_DEVICES':'0','CG_MUTATION_WORKERS':'20','LC_ALL':'C'})
                        state('running',run=run,child_pid=child.pid)
                        while child.poll() is None:
                            if time.monotonic()-started>7200:
                                raise TimeoutError('Run exceeded 7200 seconds')
                            memory,foreign=memory_sample(child.pid)
                            samples.append({'elapsed_seconds':time.monotonic()-started,'used_mib':memory})
                            if foreign:
                                raise RuntimeError('Foreign GPU process appeared; measurement contaminated')
                            time.sleep(.5)
                        if child.returncode:
                            raise RuntimeError('Runtime exit '+str(child.returncode))
                finally:
                    if child is not None and child.poll() is None:
                        os.killpg(child.pid,signal.SIGTERM)
                        try: child.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid,signal.SIGKILL)
                            child.wait()
                    write_json(directory/(run+'.memory.json'),samples)
                expected=correctness[cohort]
                result=parse_performance((directory/(run+'.log')).read_text(),cpu,expected['distance_checksum'],expected['final']['reachable'])
                rss=re.search(r'Maximum resident set size \(kbytes\):\s*(\d+)',usage.read_text())
                if not rss or not samples or max(row['used_mib'] for row in samples)==0:
                    raise ValueError('Missing memory/RSS measurement')
                result.update(cpu_pq=cpu,wall_seconds=time.monotonic()-started,max_rss_kib=int(rss[1]),
                              sampled_gpu_peak_mib=max(row['used_mib'] for row in samples))
                results[run]=result
                write_json(directory/'results.json',results)
                print('Completed '+run,flush=True)
                time.sleep(3)
            runs=[results[cohort+'_'+str(i)+('_B_cpu' if cpu else '_A_gpu')] for i,cpu in enumerate((False,True,True,False))]
            ratios=[runs[1]['sum_batch_ms']/runs[0]['sum_batch_ms'],runs[2]['sum_batch_ms']/runs[3]['sum_batch_ms']]
            summary={'cpu_over_gpu_pair_ratios':ratios,'both_pairs_improve':all(r<1 for r in ratios),
                     'aggregate_reduction':1-(runs[1]['sum_batch_ms']+runs[2]['sum_batch_ms'])/(runs[0]['sum_batch_ms']+runs[3]['sum_batch_ms']),
                     'gpu_sampled_peak_mib':[r['sampled_gpu_peak_mib'] for r in runs],
                     'cpu_max_rss_kib':[r['max_rss_kib'] for r in runs],
                     'exact_gpu_peak_gate':'pending; sampled memory is supporting evidence only'}
            summary['timing_gate_passed']=summary['both_pairs_improve'] and summary['aggregate_reduction']>=.05
            write_json(directory/(cohort+'.summary.json'),summary)
        state('completed',runs=len(results),next_gate='Review paired timing, memory ledger and sampled peaks before ten-batch/regression gate')
        return 0
    except Exception as error:
        state('timeout' if isinstance(error,TimeoutError) else 'failed',error=str(error))
        raise


if __name__=='__main__':
    raise SystemExit(main())
