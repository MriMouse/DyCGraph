#!/usr/bin/env python3
"""Audit raw PR/CC timers and export comparison without changing measurements."""
import csv, json, math, re, statistics
from collections import Counter
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'paper/evaluation/raw/cc_pr_20260928'
DEST = ROOT / 'paper/evaluation/data'
rows = [r for r in csv.DictReader((OUT/'runs.csv').open()) if r['algorithm'] in ('PR','CC')]
keys = [(r['algorithm'],r['dataset'],r['scale'],r['system'],int(r['repeat'])) for r in rows]
expected = {(a,d,s,side,n) for a in ('PR','CC') for d in ('OK','WK','TW','FS') for s in ('1k','10k','100k') for side in ('current','original') for n in (1,2)}
assert len(keys)==len(set(keys)) and set(keys)==expected
terms=Counter(); witnesses={}
for r in rows:
    assert r['status']=='ok', r
    text=Path(r['log']).read_text(errors='replace')
    timers=re.findall(r'\[P0-TIMER\]\['+r['algorithm']+r'\]\[batch (\d+)\] (?:total_batch:|paper_algorithm_ms=)\s*([\d.]+)',text)
    assert [int(i) for i,_ in timers]==list(range(10)),r
    assert abs(sum(float(v) for _,v in timers)-float(r['paper_algorithm_ms']))<0.002,r
    assert not re.search(r'CUDA error|cudaError|out of memory|protocol_error|Overall: Test FAILED',text,re.I),r
    if r['algorithm']=='CC':
        assert 'Overall: Test passed' in text and 'Max iterations reached' not in text,r
        if r['dataset']=='TW' and r['system']=='current':
            lines=[line for line in text.splitlines() if '[CC-ROOTED-WITNESS]' in line]
            assert len(lines)==10
            witnesses[r['scale']+'_'+r['repeat']]={key:sum(float(re.search(r'\b'+key+r'=([\d.]+)',line)[1]) for line in lines) for key in ('total_ms','candidates','certified','fallback')}
    else:
        initial=re.findall(r'\[PR-CONVERGE\].*?stop=(\w+)',text)
        batch=re.findall(r'\[PR-BATCH\].*?stop=(\w+)',text)
        assert len(initial)==1 and len(batch)==10 and set(initial+batch)<= {'converged','iteration_limit'},r
        terms.update(initial+batch)
summary=[]
existing={(r['algorithm'],r['dataset'],r['scale']):r for r in csv.DictReader((DEST/'performmance.csv').open())}
lines=['# PR / CC 结果汇总（2026-10-01）','',
'来源：raw/cc_pr_20260928；96/96 次状态为 ok，逐条核对 10 个有序 batch timer 与 runs.csv。',
'每个配置每系统重复 2 次；计时为 10 个增量 batch 的算法总时间，再对两次取均值，不是进程端到端时间。加速比 = original/current，大于 1 表示 current 更快。',
'GPU 0 / NUMA 0；current hybrid=0，original hybrid=2；cache=2。CC 为 directed_min_label。',
'PR 保留原有结果；current CC 为最新冻结源码重跑；original CC 保留原有结果。',
'运行完成不代表完整正确性验证：check=false，validation_status=timing_complete_unvalidated。PR 采用提前收敛或最多 100 轮的统一停止策略。','']
for a in ('PR','CC'):
    ratios=[]
    lines += ['## '+a,'','| 数据集 | 规模 | current（ms） | original（ms） | 加速比 |','|---|---|---:|---:|---:|']
    for d in ('OK','WK','TW','FS'):
        for s in ('1k','10k','100k'):
            values={side:[float(r['paper_algorithm_ms']) for r in rows if (r['algorithm'],r['dataset'],r['scale'],r['system'])==(a,d,s,side)] for side in ('current','original')}
            means={side:statistics.mean(v) for side,v in values.items()}
            c,o=means['current'],means['original']; ratio=o/c; ratios.append(ratio)
            stored=existing[(a,d,s)]
            assert abs(c-float(stored['current_mean_total_10batch_ms']))<0.00011
            assert abs(o-float(stored['original_mean_total_10batch_ms']))<0.00011
            record=dict(algorithm=a,dataset=d,scale=s,current_mean_total_10batch_ms=c,original_mean_total_10batch_ms=o,original_over_current=ratio)
            for side,v in values.items():
                record[side+'_r1_ms']=v[0];record[side+'_r2_ms']=v[1]
                record[side+'_repeat_range_pct']=(max(v)-min(v))/statistics.mean(v)*100
            summary.append(record)
            lines.append(f'| {d} | {s} | {c:,.3f} | {o:,.3f} | {ratio:.4f}× |')
    gm=math.exp(statistics.mean(math.log(x) for x in ratios))
    lines += ['',f'current 更快：{sum(x>1 for x in ratios)}/12；12 项等权几何平均加速比：{gm:.4f}×。','']
    print(a,'wins',sum(x>1 for x in ratios),'geomean',gm)
lines += ['## 观察与限制','',f'- PR 共 528 个停止记录（48 次 × 初始计算及 10 个 batch）：{dict(terms)}；达到轮数上限不能表述为数值收敛。']
for s in ('1k','10k','100k'):
    item=next(r for r in summary if (r['algorithm'],r['dataset'],r['scale'])==('CC','TW',s))
    w=[witnesses[s+'_'+str(n)] for n in (1,2)]
    ms=statistics.mean(x['total_ms'] for x in w)
    certified=sum(x['certified'] for x in w); candidates=sum(x['candidates'] for x in w)
    line=f'- CC TW/{s}：current 耗时为 original 的 {1/item["original_over_current"]:.2f} 倍；witness 平均 {ms/1000:.3f} 秒，占算法时间 {ms/item["current_mean_total_10batch_ms"]*100:.2f}%；两次累计 certified/candidates={int(certified)}/{int(candidates)}。'
    lines.append(line); print(line)
lines += ['- witness 数据为当前运行实测；结构性修复及独立正确性验证见 iteration/subiteration_file/cc_tw_structural_fix_20261001.md。']
for a in ('PR','CC'):
    worst=max(((r[side+'_repeat_range_pct'],r,side) for r in summary if r['algorithm']==a for side in ('current','original')),key=lambda x:x[0])
    pct,r,side=worst
    lines.append(f'- {a} 最大重复差异（极差/均值）：{r["dataset"]}/{r["scale"]}/{side}，{r[side+"_r1_ms"]:.3f} 与 {r[side+"_r2_ms"]:.3f} ms，相差 {pct:.2f}%。仅两次重复，不提供显著性结论。')
with (DEST/'pr_cc_summary_20261001.csv').open('w',newline='') as f:
    writer=csv.DictWriter(f,fieldnames=list(summary[0]));writer.writeheader();writer.writerows(summary)
report=DEST/'pr_cc_summary_20261001.md'
report.write_text('\n'.join(lines)+'\n')
print('WROTE',report)
print('PR stopping reasons',dict(terms))
