from pathlib import Path
import re,json,hashlib,subprocess,tarfile,csv
root=Path.cwd(); out=root/'paper/work_audit_20260917'
old=(out/'系统优化工作量与创新证据总账.md').read_text()
ms=['A01','A02','A03','A04','A07','A08','A07','A10','A09','A05','A05','A06','A11','C01','C02','B02','B05','B04','B06','B07','B08','B09','B10','B11','B12','B12','B12','B13','B13/B14','B14','B13','B15','B16','C03','C09','C10','B03','C08','C05']
hs=['N01','N01','N01','N01/N05','N04','N04','N01/N04','N02','N03','N04','N05','N06','N08','N07/N09','N09/N10','N11','N12','N15','A06/N16','N16','N16/N17','N13/N14','N18','N20','N19','N19','N21','N23','N24','N25','N22','N26']
es=['C06/C07','T04','T05','T06','T01','T02','T02/T09','T03','T03/T07','C08/T08']
m={f'{prefix}{i:02}':v for prefix,arr in [('M',ms),('H',hs),('E',es)] for i,v in enumerate(arr,1)}
lines=['# 两版总账交叉核对\n','以《系统优化工作量与论文证据总账.md》及 work_items.json 为当前引用入口；较早总账保持原样。旧版81个条目与新版72项粒度不同，下表覆盖旧版全部条目，不能直接按数量判断遗漏。\n','复核补入 C09 初始化自然收敛、C10 Loader 容器长度修复；I12 已解包源码与 tar 内容复核后增补可点击函数位置。I16 以新版恢复的道路 CPU PQ 正收益与十批检查为准。旧版同样未找回 extent/linked 等全部生产源码，仍如实保留缺口。\n','| 旧编号与名称 | 新工作项 |','|---|---|']
heads=re.findall(r'^### ([MHE]\d+) (.+)$',old,re.M)
for k,title in heads:lines.append(f'| {k} {title} | {m[k]} |')
(out/'两版交叉核对.md').write_text('\n'.join(lines)+'\n')
checks=[]
for p in (out/'historical').rglob('*'):
 if not p.is_file():continue
 rel=p.relative_to(out/'historical');rev=rel.parts[0];name='/'.join(rel.parts[1:])
 if rev=='i12_pre_cleanup':
  with tarfile.open(root/'logs/i13_cleanup_20260906/pre_cleanup.tar.gz') as t: data=t.extractfile(name).read()
 else:data=subprocess.check_output(['git','show',rev+':'+name])
 checks.append({'path':str(p.relative_to(root)),'source':rev+':'+name,'bytes_match':data==p.read_bytes()})
assert all(x['bytes_match'] for x in checks)
inv=json.loads((out/'code_inventory.json').read_text())
changed=[x['path'] for x in inv if hashlib.sha256((root/x['path']).read_bytes()).hexdigest()!=x['sha256']]
items=json.loads((out/'work_items.json').read_text()); assert len(items)==72
with (out/'work_items.csv').open(encoding='utf-8-sig') as f: assert len(list(csv.reader(f)))==73
report=(out/'系统优化工作量与论文证据总账.md').read_text()
bad=[];count=0
for target in re.findall(r'\]\(([^)]+)\)',report):
 if target.startswith(('https:','http:','#')):continue
 target=target.strip('<>');match=re.match(r'^(.*):(\d+)$',target)
 path=Path(match[1] if match else target);path=path if path.is_absolute() else out/path
 if not path.exists():bad.append(target);continue
 if match and path.is_file() and int(match[2])>len(path.read_text(errors='replace').splitlines()):bad.append(target)
 count+=1
assert not changed,(changed)
assert not bad,bad
result={'items':len(items),'previous_report_items_mapped':len(heads),'inventory_files_hash_unchanged':len(inv),'main_report_links_checked':count,'bad_links':bad,'changed_implementation_files':changed,'historical_extractions_verified':checks,'scope':'静态审计完整性检查；未新跑GPU、构建或算法测试'}
(out/'final_integrity_checks.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k!='historical_extractions_verified'},ensure_ascii=False))
