#!/usr/bin/env python3
"""Generate I19 tables without mixing nested timers or incomplete runs."""
import argparse
from collections import defaultdict
import json
from pathlib import Path
import re


def fields(line):
    return {k:float(v) for k,v in re.findall(r'\b([A-Za-z_][A-Za-z_0-9]*)=(-?\d+(?:\.\d+)?)',line)}


def gpu(folder):
    status=folder/'status.json'
    if not status.exists():return None
    s=json.loads(status.read_text())
    if s.get('status')!='complete':return None
    log=(folder/'run.log').read_text()
    sums=defaultdict(float);batches=[];affected=[];overlay=[]
    for line in log.splitlines():
        f=fields(line)
        if '[P0-ATTR]' in line:
            batches.append(f)
            for k,v in f.items():sums[k]+=v
        if '[I14-BATCH]' in line:sums['mixed_group_ms']+=f['group_ms']
        if '[C3-CPU-MUTATION]' in line:
            for k in ['mutation_ms','group_ms','written_bytes','relocation_bytes','prepare_ms','preflight_ms','apply_ms']:
                sums['mutation_'+k]+=f.get(k,0)
        if '[C3-EFFECTIVE]' in line:sums['reverse_prepare_ms']+=f['reverse_prepare_ms']
        if '[I19-WORK]' in line:
            for k,v in f.items():sums[k]+=v
        if '[I19-REVERSE-WORK]' in line:
            for k in ['input_records','old_records_read','output_records']:sums['reverse_'+k]+=f[k]
            overlay.append(f['overlay_records'])
        if '[B2-GPU-REPAIR]' in line:
            affected.append(f['affected'])
            for k in ['closure_ms','topology_ms','base_edges_scanned','delta_records_scanned']:sums['repair_'+k]+=f.get(k,0)
        if '[INSERTION-STAGE]' in line:sums['insertion_converge_ms']+=f['converge_ms']
        if '[C3-PUBLISH]' in line:
            sums['publication_ms']+=f['publication_ms'];sums['publication_bytes']+=f['patch_bytes']
        if '[I17-B7-COMM]' in line:
            batch=re.search(r' batch=(-?\d+)',line)
            if batch and int(batch[1])>=0:
                direction=re.search(r'direction=(\w+)',line)[1]
                stage=re.search(r'stage=(\w+)',line)[1]
                sums[f'cuda_{stage}_{direction}_bytes']+=f['bytes']
    return dict(status=s,sums=dict(sums),batches=batches,affected=affected,overlay=overlay)


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();out=a.output
    ratios=[];cpu_profiles=[]
    for file in sorted(out.glob('*_cpu.jsonl')):
        groups=defaultdict(list)
        for line in file.read_text().splitlines():
            if not line.startswith('{'):continue
            r=json.loads(line)
            if r['type']=='batch':groups[r['manifest']].append(r)
        for manifest,rows in groups.items():
            phases=[p for r in rows for p in r['phases']];u=sum(r['U'] for r in rows)
            row=dict(dataset=file.stem,manifest=manifest,batches=len(rows),B=rows[0]['B'],U=u,
                cpu_service_ms=sum(r['cpu_service_ms'] for r in rows),
                group_ms=sum(r['group_ms'] for r in rows),
                forward_prepare_ms=sum(p['prepare_ms'] for p in phases),
                reverse_prepare_ms=sum(p['reverse_prepare_ms'] for p in phases),
                reverse_merge_ms=sum(p['reverse_merge_ms'] for p in phases),
                mutation_write_bytes=sum(p['mutation_written_bytes'] for p in phases),
                relocation_bytes=sum(p['relocation_bytes'] for p in phases),
                adjacency_reads=sum(p['deletion_match_reads']+p['mutation_edge_reads'] for p in phases),
                deletion_match_reads=sum(p['deletion_match_reads'] for p in phases),
                effective_bytes=sum(p['effective_bytes'] for p in phases),
                reverse_copy_bytes=sum(p['reverse_copy_bytes'] for p in phases),
                reverse_old_records=sum(p['reverse_old_records_read'] for p in phases),
                overlay_first=rows[0]['phases'][-1]['reverse_overlay_records'],
                overlay_last=rows[-1]['phases'][-1]['reverse_overlay_records'],
                service_first_ms=rows[0]['cpu_service_ms'],service_last_ms=rows[-1]['cpu_service_ms'],
                S_min=min(r['S'] for r in rows),S_max=max(r['S'] for r in rows),
                rss_peak_kb=max(r['rss_peak_kb'] for r in rows),
                retired_edges_last=rows[-1]['retired_capacity_edges'],
                arena_high_water_edges=rows[-1]['arena_high_water_edges'],
                forward_oracle=all(r['forward_oracle']=='passed' for r in rows),
                reverse_oracle=all(r['reverse_oracle']=='passed' for r in rows))
            row['write_bytes_per_U']=row['mutation_write_bytes']/u if u else None
            row['reads_per_U']=row['adjacency_reads']/u if u else None
            cpu_profiles.append(row)
    for ds in ['wiki','friendster']:
        for percent in range(10,100,10):
            perf=gpu(out/f'{ds}_p{percent:02}_performance');check=gpu(out/f'{ds}_p{percent:02}_correctness')
            ratios.append(dict(dataset=ds,percent=percent,performance=perf,correctness=check))
    scales=[]
    for dataset in ['twitter','friendster']:
        for k in [100,1000,10000]:
            scales.append(dict(dataset=dataset,B=k*1000,performance=gpu(out/f'{dataset}_scaling_{k}k_performance')))
    result=dict(cpu=cpu_profiles,ratios=ratios,scales=scales)
    (out/'analysis.json').write_text(json.dumps(result,indent=2)+'\n')
    lines=['# I19 画像表（自动生成）','',
        'CPU service 为 production mutation/reverse 接口的结构 replay，不含独立 oracle、装载与初始化；RSS 包含 oracle。CPU publication 只含 epoch/reclaim，descriptor 字节是逻辑范围，实际发布以 GPU 日志为准。',
        '写入已包含 relocation，不能再次相加。reverse prepare 已包含在 mutation/preflight，不能再次相加。未测物理互连、完整 CPU memcpy、GPU cache/ZC 分类访问，均为 unavailable。','',
        '| CPU 输入 | B | 已完成批次 | service ms | forward prepare ms | reverse prepare ms | 写入 bytes/U | 邻接读/U | 历史 reverse 读 | overlay 首/末 |','|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    for r in cpu_profiles:
        label=r['dataset']+'/'+Path(r['manifest']).parent.name if 'p' in Path(r['manifest']).parent.name else Path(r['manifest']).stem
        lines.append(f"| {label} | {r['B']} | {r['batches']} | {r['cpu_service_ms']:.3f} | {r['forward_prepare_ms']:.3f} | {r['reverse_prepare_ms']:.3f} | {r['write_bytes_per_U']:.2f} | {r['reads_per_U']:.2f} | {r['reverse_old_records']} | {r['overlay_first']}/{r['overlay_last']} |")
    lines+=['','## 比例 × 完整阶段（十批合计）','','| 图 | 插入比例 | P0 ms | deletion ms | addition ms | cache等 ms | mutation ms（嵌套） | reverse ms（嵌套） | RSS MiB | GPU sampled MiB | correctness |','|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|']
    for r in ratios:
        perf=r['performance'];check=r['correctness']
        if not perf:
            lines.append(f"| {r['dataset']} | {r['percent']}% | pending | | | | | | | | {'passed' if check else 'pending'} |")
            continue
        s=perf['sums'];status=perf['status'];other=sum(s.get(k,0) for k in ['hotness','candidate','eviction','compact','cache_load','residual'])
        lines.append(f"| {r['dataset']} | {r['percent']}% | {status['paper_ms']:.3f} | {s['deletion']:.3f} | {s['add']:.3f} | {other:.3f} | {s['mutation_mutation_ms']:.3f} | {s['reverse_prepare_ms']:.3f} | {status['rss_peak_kb']/1024:.1f} | {status['gpu_sampled_peak_mib']} | {'passed' if check else 'pending'} |")
    lines+=['','## 规模 × 阶段（现有 cohort，同一 I19 二进制，各两批）','','| 图 | B | P0 ms | grouping ms（嵌套） | mutation ms（嵌套） | reverse ms（嵌套） | repair closure ms | insertion converge ms |','|---|---:|---:|---:|---:|---:|---:|---:|']
    for r in scales:
        perf=r['performance']
        if not perf:
            lines.append(f"| {r['dataset']} | {r['B']} | pending | | | | | |")
            continue
        s=perf['sums']
        lines.append(f"| {r['dataset']} | {r['B']} | {perf['status']['paper_ms']:.3f} | {s['mixed_group_ms']:.3f} | {s['mutation_mutation_ms']:.3f} | {s['reverse_prepare_ms']:.3f} | {s['repair_closure_ms']:.3f} | {s['insertion_converge_ms']:.3f} |")
    (out/'tables.md').write_text('\n'.join(lines)+'\n')
    active_cpu=[]
    for file in out.glob('*_cpu_status.json'):
        state=json.loads(file.read_text())
        if state['state']=='running':active_cpu.append(file.name)
    gpu_state=json.loads((out/'gpu_status.json').read_text()) if (out/'gpu_status.json').exists() else None
    print(json.dumps(dict(cpu_batches=sum(r['batches'] for r in cpu_profiles),active_cpu=active_cpu,
        gpu_performance=sum(bool(r['performance']) for r in ratios),
        gpu_correctness=sum(bool(r['correctness']) for r in ratios),
        gpu_scaling=sum(bool(r['performance']) for r in scales),gpu_state=gpu_state)))


if __name__=='__main__':main()
