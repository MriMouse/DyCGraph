# I17-B5.4.3：reverse 分项归因与 destination 分片（定向验证完成）

2026-09-11。阶段矩阵保持暂停。

本轮保留人工 64 分片研究候选，默认仍为 1 分片。单 map 的目标查询/反复重哈希是 FS 1000k 的主要额外准备成本；分片将同二进制十批 paper 从 26.174 s 降到 15.173 s。FS 100k 同时改善，1000k/100k 比例从 6.650 降到 5.191。几何扩容替代项有收益但仍有尾部尖峰，已撤下运行时分支。真实 FS 1000k 两批的距离/existential tight witness、publication 审计及定向契约验证通过。

| cohort | 1 分片 paper ms | 64 分片 paper ms | 变化 |
|---|---:|---:|---:|
| FS 1000k / 10 batch | 26173.694 | 15173.065 | -42.0% |
| FS 100k / 10 batch | 3935.969 | 2922.737 | -25.7% |
| TW 100k / 2 batch | 251.771 | 249.415 | -0.9% |
| small / 3 batch, check=true | 161.242 | 164.552 | +2.1% |

这是定向验证，尚未完成重复交错十批的稳定性 gate，不自动启用，不宣称相对原仓库已通过同语义比较。EU 1000k 的主要瓶颈仍是长传播，本轮未修改其传播算法。


## 输入与编译口径更正

原 FS 输入实际位于 `/home/wangshaoyan/proJect/CG/Grapin-CG/data/{input,update,stream_size}_friendster_50p_1000k.txt`，不存在需要恢复输入的阻塞。SSSP 使用 FindCUDA 生成的自定义规则，该规则实际含 `-O3`；native CUDA 的 `flags.make` 不能代表该翻译单元的编译选项。本轮保持当前配置，不把构建类型变化当算法收益。

FS 与 EU 的问题不同：FS 主要损失在 topology 准备，EU 1000k 主要损失在删除/插入传播。此次 reverse 候选只处理前者，不声明已经解决 EU 的长传播。

## 候选

`DynamicReverseIndex` 支持 1/64 个 destination 范围分片。全局 radix sort 后 pending destination 仍有序，以 `floor(dst * shards / nnodes)` 将其划分为连续范围。每个 worker 独占一个 map 和一段 pending，完成新增目标统计、reserve 与槽位创建；所有槽位准备完成后才启动原有并行 merge。没有并发修改同一个 unordered_map。默认 `CG_REVERSE_SHARDS=1`；仅人工 `CG_REVERSE_SHARDS=64` 启用实验，不按 batch 大小自动切换。

prepare 不修改已有可见 overlay，只预建空槽并生成替代向量；取消/失败后下一次 prepare 清理空槽。commit 仍是无分配 swap、空目标删除与旧向量释放，保留 deletion 中间态。只读 materialization 按相同分片定位 overlay。

worker pool 的 Run 新增可选 grain（默认仍为 16），分片准备使用 grain=1，避免只有四个线程领取完 64 个分片。原调用保持默认调度粒度。分片边界和新增计数的临时数组随 prepare 释放；不复用 B5.1 被否决的 workspace。

## 观测契约

`[I17-REVERSE]` 记录 reset/copy、sort、group、slots、merge、记录释放和 commit；另记 destination/new destination 与总 bucket count。commit 不属于 reverse_prepare，禁止重复累加进完整 batch。分片实现将新增目标 find 从 group 移到 slots，因此这两个分项应合计后与早期 instrumentation 对照。临时向量与旧 overlay 的释放仍在原 prepare/commit 成本内。计时和日志不是脱离 paper time 的离线工作。

## 验证与结果

单/64 分片均覆盖随机连续更新、重复边计数、取消准备、空分片、删除中间态和注入 preflight 失败。worker grain 覆盖 0/1/16/256、非整除任务数、异常传播及下一次 Run 可用。三项 topology CTest 通过，独立 ASan/UBSan 通过。

真实性能结果见下文。证据目录：`logs/i17b5_20260911/b543_reverse_profile/`。复现工具：`scripts/run_i17b_reverse_probe.py`，每次仅运行明确指定的 1--10 批，保存命令、二进制 SHA256、输入路径/大小/mtime、环境、完整日志和 `/usr/bin/time -v`；超时终止整个进程组。

## 本轮单 map 分项实测

FS 1000k 两批，source=0、hybrid=2、cache=2、20 workers、check=false。paper 合计 3881.946 ms，reverse prepare 合计 1013.743 ms，距离 checksum 4613270879134330002，与此前 cohort 一致。

| phase | sort ms | group ms | slots ms | merge ms | commit ms | buckets before → after |
|---|---:|---:|---:|---:|---:|---|
| 0 delete | 18.106 | 21.452 | 56.802 | 7.531 | 10.363 | 1 → 520241 |
| 0 add | 25.319 | 53.467 | 128.985 | 9.811 | 12.138 | 520241 → 976369 |
| 1 delete | 17.642 | 72.546 | 200.231 | 12.626 | 13.646 | 976369 → 1447153 |
| 1 add | 17.376 | 78.298 | 268.980 | 14.247 | 15.182 | 1447153 → 1832561 |

group+slots 合计 880.761 ms，占 reverse prepare 86.9%；sort 78.443 ms，merge 44.215 ms。四个 phase 均触发 bucket 扩容，因此下一步针对共享 map 的目标查询和槽位准备，不继续以排序为主候选。此表只定位当前两批，不能外推十批中每个峰值的原因。

## 64 分片两批筛查

候选 paper 为 1799.877/1482.298 ms，合计 3282.175 ms；较上述单 map 诊断版降低 15.5%。reverse prepare 为 67.958/61.914/69.343/83.316 ms，合计 282.531 ms（-72.1%）。group+slots 为 142.592 ms；候选将部分 group 工作移到 slots，故按合计比较。commit 合计从 51.329 增至 60.352 ms，已包含在完整 paper time，不能只报准备降时而忽略该增加。

两批各 100 万更新、每 phase 50 万 effective records，最终 distance checksum 同为 4613270879134330002。parent checksum 不要求相同；check=false 尚不能证明 tight parent witness。RSS 从 57974124 KiB 到 57999756 KiB（+25.03 MiB）。当前只是一次短测，基线为分片接线前的诊断二进制；同一 `shards_binary` 的 1/64 分片十批对照见下文，不能将短测当稳定收益 gate。

## 同二进制十批对照：1/64 分片、精确扩容

两侧命令、输入 stat 元数据和 binary SHA256 完全相同，只改 `CG_REVERSE_SHARDS`。单次十批 paper 合计 26173.694 → 15173.065 ms（-42.0%），reverse prepare 合计 13608.976 → 1891.843 ms（-86.1%）。RSS 58497372 → 58545460 KiB（+46.96 MiB）。20 个 phase 各 500000 effective records，十批最终 distance checksum 均为 6734520550430324932。check=false，不替代距离/tight-witness 检查。

| batch | 1 分片 paper ms | 64 分片 paper ms | 1 分片 reverse ms | 64 分片 reverse ms |
|---|---:|---:|---:|---:|
| 0 | 1814.941 | 1899.501 | 321.935 | 152.995 |
| 1 | 1953.682 | 1617.903 | 679.754 | 192.624 |
| 2 | 2175.318 | 1496.662 | 1021.646 | 161.798 |
| 3 | 2548.694 | 1629.987 | 1320.031 | 191.935 |
| 4 | 2832.020 | 1473.853 | 1569.434 | 186.881 |
| 5 | 3214.243 | 1403.143 | 1819.572 | 198.449 |
| 6 | 2554.008 | 1390.965 | 1339.589 | 200.307 |
| 7 | 3539.317 | 1439.952 | 2329.496 | 199.480 |
| 8 | 2711.318 | 1413.041 | 1532.778 | 198.939 |
| 9 | 2830.153 | 1408.058 | 1674.741 | 208.435 |

reverse 减少 11717.133 ms，完整 paper 减少 11000.629 ms，其余工作净增约 716.504 ms；不能把 reverse 与 preflight 重复相加。commit 合计 508.170 → 779.778 ms，已计入上述完整成本。

本轮单分片基线较历史矩阵慢，因此 42.0% 仅描述本轮同二进制一次对照，不宣称相对原仓库或所有运行环境都有该收益。首批候选慢于基线，后九批均改善；尚未完成重复交错十批 gate。保留人工候选，默认仍为单分片。

## 几何扩容补充候选（实测完成，不保留运行时分支）

单 map 十批有 17/20 phase 的 bucket count 增长，后期 slots 达 1373.379 ms，而未扩容的相邻 delete phase 约 201.592 ms。新增独立 `CG_REVERSE_GROWTH=geometric`，只在容量不足时 `reserve(max(required, 2 * old_size))`，默认 `exact`。不按 touched destination 数过度预留，不改变 effective delta 或提交语义。实际内存与完整 batch 成本见下文。

四种组合的契约回归和 ASan/UBSan 已通过；新增 4099 目标分 17 轮连续增长、准备不可见、取消全量抵消及最终全量抵消检查。单 map 几何扩容的实测已完成。

## 后续瓶颈边界

64 分片十批中 forward mutation 的 allocation 平均仅 0.821 ms/batch，prepare 为 216.223 ms/batch、group 为 157.375 ms/batch、apply 为 110.556 ms/batch，完整 mutation 为 663.638 ms/batch（已包含 reverse，不可重复加和）。这份证据不支持继续把 chunk allocator 作为第一主因；若后续优化 forward，优先检查重复扫描/分组和数据搬运的完整成本，而非立即替换 PMA 后端。

`CG_MUTATION_WORKERS` 只控制 chunk store 的 forward workers，reverse Build/merge 自己使用 `min(20, hardware_concurrency)`。因此历史 1/20 worker ratio 不能证明 reverse 线程扩展好或差。本轮所有性能运行均明确使用 20 mutation workers，未改变这项既有行为。

单 map 几何扩容十批 paper 为 18364.902 ms、reverse prepare 为 5844.345 ms，6/20 phase 扩容；RSS 58556244 KiB，最终 distance checksum 同为 6734520550430324932。它比精确扩容单 map 明显改善，但慢于 64 分片的 15173.065 ms，最后一次 add 的 reverse prepare 仍为 1018.021 ms。此候选有机理价值，但不是本轮主方案，已从当前源码移除几何扩容参数和实现，避免增加未经完整 gate 的运行时策略组合。实验二进制为 `growth_binary`，源码、当时的 runner 和四组合测试归档在 `source_geometric/`，日志为 `shards1_geometric_ten/`。最终保留单/64 分片切换。

## FS 1000k 真实正确性检查

`shards64_correctness/` 使用相同候选，连续两批 `--check=true`：两个 delete-stage、两个 batch check 及最终 Bellman 全部通过，所有阶段 source_ok=1、relaxable_edges=0、missing_tight_witnesses=0。阶段距离 checksum 依次为 5047606141650279150、9905524282624512177、3514131911189012668、4613270879134330002，最终值与两批性能运行相同。检查运行总耗时 584.014 s，其 paper time 不混入 check=false 性能对照。

按计划冻结的 distance/existential tight-witness 契约验收；stored-parent invalid vertices 依次为 272/275/273/276（missing_parent_edges 均为 0），仍保留为历史诊断，不宣称 parent 数组已构成合法最短路径树。runner 除检查程序退出码，还核验四个阶段的 source/Bellman/existential witness 字段；不以 `Overall passed` 单独代替这些检查。

## FS 100k 固定开销与规模比例

同一 `shards_binary`、各十批、check=false，1/64 分片 paper 合计 3935.969 → 2922.737 ms（-25.7%），reverse prepare 1120.300 → 167.508 ms（-85.0%），最终距离 checksum 均为 12734023534853680802。常规 100k 没有出现回退。

| 模式 | FS 100k 十批 ms | FS 1000k 十批 ms | 1000k / 100k |
|---|---:|---:|---:|
| 1 分片 | 3935.969 | 26173.694 | 6.650 |
| 64 分片 | 2922.737 | 15173.065 | 5.191 |

比例下降约 21.9%。这里沿用原计划两个 batch size 各自的输入 cohort（两个 base 文件不是逐字节相同），不将比例外推成渐近复杂度、通用 batch 阈值或 EU 的结论；也不能仅因比例仍高于原仓库就忽略当前 100k 固定成本更低。

FS 1000k check=true 的两个 publication epoch 均为 `stale_version_rejects=0`、`gpu_cpu_hash_mismatches=0`、`audit=1`。分片只增加普通 host 容器和临时索引，不新增 pinned/device 分配或线程；峰值 host RSS 仍以实际日志比较，不用对象尺寸估算代替实测。

## Twitter 与小 batch 边界

Twitter 使用原矩阵的 source=0、hybrid=0、cache=2、100k cohort；两批 251.771 → 249.415 ms（-0.9%），reverse 48.486 → 48.601 ms，视为基本持平，不声称加速。最终 distance checksum 均为 135395585444927021。该结果说明分片不是所有图/批次的通用加速器。

小图复用 I16 smoke 的 2048 节点双向环模式，三个 batch 每批 2 delete + 2 add，交替删除/恢复 0↔1 与 0↔2；两侧均 check=true。三批 161.242 → 164.552 ms（+2.1%），reverse 1.090 → 3.519 ms，显式暴露额外调度的固定开销；不将该一次小图运行当显著退化或大图性能证据。六个阶段的距离/existential witness、stored parent 和最终 Bellman 均通过，各阶段 distance checksum 逐项一致。输入与 manifest 保存于 `small_input/`、`small_manifest.json`。

## 本轮裁决与剩余工作

- 保留 `CG_REVERSE_SHARDS=64` 人工研究候选，默认单分片；没有按更新量/图名自动切换，没有 PMA 后端接入。
- 本轮完成两批筛查、FS 1000k/100k 各一次同二进制十批对照、TW 100k 两批对照、FS 1000k 两批 correctness、微型三批对照，以及 topology 契约和 ASan/UBSan。普通 host RSS 在 FS 1000k 十批增加 46.96 MiB，FS 100k 增加 11.30 MiB；不新增 pinned/device 分配或 worker 数。
- 尚缺重复交错十批的稳定性确认和更长序列空间边界，因此不能把 B5 整体或生产默认启用 gate 标为完成。按用户 2026-09-11 最新要求，不再补收口级稳定性重复，也不将它作为下一步前置条件；现有证据用于确认当前性能取舍，继续 EU 定向瓶颈确认/B6。不继续以 allocator 或 PMA 作为预设主因。
- EU 的删除/插入长传播仍由 B6/I18 处理，当前优化不替代有序 GPU 的完整成本验证。

复现主候选（单次调用只执行指定批数）：

```bash
python3 scripts/run_i17b_reverse_probe.py \
  --binary logs/i17b5_20260911/b543_reverse_profile/shards_binary \
  --output logs/i17b5_20260911/your_new_probe \
  --batches 10 --shards 64
```

添加 `--check` 运行距离与 existential tight-witness/publication 检查；使用 `--shards 1` 做同二进制基线。其它 cohort 传 `--manifest` 指向本目录对应 manifest。脚本要求日志确认实际分片配置，拒绝覆盖结果和占用中的 GPU 0，记录完整命令、输入 stat、二进制 SHA256、环境、CPU affinity（后期 runner）、RSS 及日志，超时终止整个进程组。几何扩容只可通过归档源码/二进制复现，当前 runner 和生产代码已无该策略开关。

汇总：`final_comparison.json`；冻结主候选 SHA256：`cfda8b9e32024c31a8e2707690dc06ea31534bc1690b65c2effbb0628f60a7cc`。最终源码中的 reverse/framework/pool 与冻结主候选归档源码一致；重新构建的二进制 SHA256 不同，故性能表明确引用冻结二进制，不能用哈希不同的新构建冒充已测对象。
