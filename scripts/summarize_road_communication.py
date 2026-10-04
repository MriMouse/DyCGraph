#!/usr/bin/env python3
"""Summarize complete repeat pairs; no best-run selection or incomplete averages."""
import argparse,csv,json,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('output',type=Path);a=p.parse_args()
rows=json.loads((a.output/'results.json').read_text()) if (a.output/'results.json').exists() else []
groups={}
for r in rows:
 if r['group']=='road':groups.setdefault((r['algorithm'],r['dataset'],r['scale'],r['system']),[]).append(r)
summary=[]
for key,group in groups.items():
 complete=len(group)==2 and {r['repeat'] for r in group}=={1,2} and all(r['status']=='ok' for r in group)
 row=dict(zip(('algorithm','dataset','scale','system'),key));row.update(repeats=len(group),complete=complete)
 for metric in ('paper_algorithm_ms','selected_compute_ms','full_update_compute_ms','topology_ms','reset_ms'):
  row['mean_'+metric]=statistics.mean(r[metric] for r in group) if complete and all(metric in r for r in group) else None
 summary.append(row)
if summary:
 with (a.output/'road_averages.csv').open('w',newline='') as f:
  w=csv.DictWriter(f,fieldnames=list(summary[0]));w.writeheader();w.writerows(summary)
print(json.dumps(dict(completed_runs=len(rows),road_complete_cells=sum(r['complete'] for r in summary),road_total_cells=36,output=str(a.output/'road_averages.csv')),indent=2))
