# CC TW 结构性失速：方向审计、有根证书与修复（2026-10-01）

## 实验边界

分析来源为 `paper/evaluation/raw/cc_pr_20260928` 的最新冻结 CC。原结果、冻结源码和汇总不覆盖。
本次改动前的工作区已经有未提交修改；本次只在现有有根删除修复上继续修改。
`logs/cc_tw_structural_20261001` 保存改动前关键文件、二进制、编译日志、测试和新实验。
改动前的 `framework.cuh`、`directed_label_witness.h` 与原实验 latest 冻结版本 SHA256 一致；
CC application、reverse index、AppBase 和 repair storage 也逐项一致。新性能运行使用冻结二进制
`aab2247332e7627b5c9e82ea26fb6635a0601f8c2327780552be9a811f9e81a1`。

当前 CC 的语义为 `label[v] = min {u | u 能沿有向边到达 v}`，包含顶点自身。
它不是 SCC，也不是将输入无向化后的 WCC。本次不改变图、更新记录、算法语义或 P0 计时边界。

## 1. 为什么 TW 慢、FS 不慢

先比较实际输入结构，而不是只比较名字、顶点数或边数。对两张 **input_1k.txt 全量扫描**：

| 指标 | TW | FS |
|---|---:|---:|
| 源 ID < 目标 ID | 978,786,622 | 1,806,062,135 |
| 源 ID > 目标 ID | 984,471,886 | 0 |
| 自环 | 313 | 0 |
| 顶点 0 出度 | 1 | 203 |
| 顶点 0 入度 | 11 | 0 |
| 顶点 0 的最小出邻居 | 44,749,888 | 1 |

审计程序：`scripts/cc_orientation_audit.cpp`；原始输出：`FS_orientation.json`、`TW_orientation.json`。
FS 当前输入全是升序单向边，所以在当前执行语义下是 DAG。反向每走一步 ID 都严格降低，
三档更新流也全量核验，FS 的 10,000 / 100,000 / 1,000,000 条更新全部满足源 ID < 目标 ID，整个动态过程保持该性质。
旧 witness 的“优先低 ID 入邻居”策略与这种拓扑相符。不能将该结果解释为一般无向 Friendster 的性质。
TW 约一半边逆序，顶点 0 唯一根出口偏偏是 44,749,888；ID 顺序无法代表到根的距离。
反向 DFS 在巨大等标签区域中先搜索低 ID 分支，没有一个已认证的根侧锚点，容易迟迟接不到根。

旧实现的预算是整批共享的，第一个失败查询会消耗几乎全部预算，后面的查询直接失败。
TW/1k 每批平均 490.7 个候选，certified=0；首批 scratch 的 reset_entries=0、
avoided_bucket_slots=1，表明实际上只有第一个查询进入了搜索。
这不是 490 个顶点真的都失去根支持的证据，只是证明器未能证明。

未证明种子触发沿全部等标签边的保守失效传播，然后逐 affected 顶点物化入边，
每轮 GPU pull 再扫描整个 affected 入边集合。旧 TW/1k 两次、共 20 批均值：

| 项目 | 每批均值 |
|---|---:|
| 整批 | 17,918.270 ms |
| 删除阶段 | 17,816.169 ms |
| affected 顶点 | 49,230,318.3 |
| incoming 边 | 1,963,046,672.6 |
| 有根证明 | 634.858 ms |
| GPU 失效传播 | 2,102.380 ms |
| host 拓扑物化 | 3,891.011 ms |
| GPU pull closure | 7,969.688 ms / 7.55 轮 |

子项属于删除阶段，不应再次与删除总数累加；未单独计时部分不能随意归因。
TW 首批 repair storage 的约 7.852 GB 入边来源数组位于 mapped host memory，
只有约 394 MB offsets/affected 驻留 device；巨大的重复 pull 因而还放大 PCIe 访问。
不能将只打印约 394 MB H2D 误读为整个修复拓扑都在 GPU。

规模增大后，证明预算随候选数放大，却仍没有认证成功：TW/10k 平均证明 7.644 秒，
TW/100k 平均证明 50.996 秒；其后仍然执行近全图修复。增大预算不是解决方法。
FS/1k 则每批约 494.8/497.3 个候选获证，最终 affected 均值 3.8；
FS/100k 最终 affected 也仅约 480.1。大量冗余删除不再进入 GPU 修复，故可超过 original。

## 2. 与本系统 BFS、PR 的区别

- BFS 的有效最短路依赖严格增加距离（+1），可以使用 tight parent 等证据维持局部修复。
  CC 的传播代价为 0，等标签环可以相互支持错误的旧标签；不能照搬 parent/tight 入边检查。
  当前 CC 因此在失去根证明时沿所有等标签依赖传播，范围可以瞬间膨胀到几千万顶点。
- PR 使用带符号 residual：删除/增加造成贡献差分，活跃条件是残差阈值，
  通过 `atomicAdd` 传播，不走 CC 的等标签失效、incoming 物化、反复全 affected pull 链路。
- 分组 mutation、合并 publication、chunk store、严格成功事件插入调度、热度/cache 都已经接入 CC。
  旧 TW/1k 插入平均仅 3.462 ms；慢的是删除证明和删除修复。补几个插入/cache 小优化不能消除该失速。

## 3. 与 original 的区别

original 删除种子及传播仅在 `parent[dst] == src` 时失效，不会沿所有等标签边保守泛洪；
也没有本次 current 中昂贵的 host witness 与全 affected incoming pull 修复路径。
original 的 TW/1k、10k、100k 十批均值分别为 12,278.171、12,569.368、14,535.432 ms；
旧 current 分别为 179,182.702、279,560.743、739,973.759 ms。
两边 P0 都覆盖删除、插入和 cache 维护，不能说 original 通过不计删除时间而领先。

original 的 HybridCC 最后直接 return true，历史实验 check=false；日志 Test passed 不是动态标签 oracle。
本次不能靠直接改回 parent-only 宣称正确修复，也不能仅凭这些日志断言 original 在 TW 错误。

## 结构性修改：批次共享、两端相接的有根证明

1. 整批删除提交完成后，从候选的真实旧标签根出发，沿当前 forward chunk 建立共享有根证书。
2. 只有真实根及从已认证顶点沿同标签存活边到达的顶点才能获证。
3. 反向查询无需一路找到单个根，只需接入任一同标签已认证锚点；成功路径继续加入共享证书。
4. 仍然沿当前 forward chunk 闭合未证明区域；只将最终 affected 交给现有精确修复器。
5. 所有证书在这一删除阶段结束后销毁。预算耗尽仍使用保守 fallback，绝不猜测标签。

这改变的是证明的搜索方向和批内共享方式，使 TW 的高 ID 根入口先成为有效锚点；
不是提高预算、换算法语义或修改原始数据。默认正向最多 262,144 边、32,768 个出队顶点；
不构建全图副本、不维护跨批 stale 证书，原有反向证明预算不增加。
`CG_CC_FORWARD_WITNESS=0` 可在同一二进制中关闭该路径做消融。
新增 `[CC-FORWARD-WITNESS]` 记录正向顶点、边与证书数。

正确性：删除不可能降低最小可达标签。若从旧根 r 到 v 有一条删除后的真实路径，
则新 label[v] <= r；与单调性合并得到新 label[v] = 旧 label[v]。
所有正向证书和反向接入路径都满足这个条件，等标签环不能自行获证。
未获证顶点的处理仍是现有保守失效及精确修复。

## 验证结果

- 独立 fixed-point oracle：64,057 个随机查询，含截断正向预算；同时验证 affected 集合等于真正改变标签的集合。
- 新增“低 ID 稠密环 + 高 ID 根入口”结构回归：相同有限反向预算下旧搜索失败，共享根侧证书成功；切断根入口后不能沿用证书。
- CC GPU smoke：18 个配置全部通过，406 个删除/插入阶段独立检查；覆盖 block/thread/ordered、CPU 分区、cache off、稀疏初算、单独关闭 forward anchors、关闭 witness、平行边、批量断桥、跨批插入后删除。
- BFS、SSSP 重编译后分别通过 18 个独立阶段 oracle 和最终距离/parent witness；PR 重编译后通过动态、静态 oracle 及错误输入契约。
- TW 与 FS 的 100k 实图各 20 次逐阶段全图 oracle 及最终全图 oracle 均已通过（共 42 次实图全图检查）。性能运行见下文，诊断运行不作为 benchmark。

### 已完成：TW/100k 实图正确性

`TW_100k_fixed_r1_checked.result.json`：GPU 2 / NUMA 1，20 次删除/插入全图独立 oracle
及最终全图 oracle 全部 errors=0，进程成功退出。十批全部 closed=1。
affected 范围 120–151、均值 140；incoming repair 范围 3–17、均值 9。
这与旧 current 平均约 4,923 万 affected、19.625 亿 incoming 的工作量根本不同。

该 **诊断运行不用于性能对比**：除显式全图 CC oracle 外，check=true 还会在 P0 内
启用额外的 topology publication audit / hash 检查，且此轮使用 GPU 2 / NUMA 1。
其 18,892.565 ms 不能与 GPU 0 / NUMA 0 的 check=false original 直接比较；
用于论文口径的 100k 性能已单独按原命令在 GPU 0 / NUMA 0 完成，结果见文末。

FS/100k 同样完成 20 次逐阶段及最终全图独立检查，均 errors=0，进程正常退出。
证据：`fs_validation/FS_100k_fixed_r1_checked.result.json`。

### 已完成：TW/1k 性能

GPU 0 / NUMA 0，原始输入与全部原有参数，check=false；一次运行十批。

| 十批算法总时间 | ms |
|---|---:|
| 旧 current（原记录两次均值） | 179,182.702 |
| original（原记录两次均值） | 12,278.171 |
| 修复后（本次一轮） | 3,235.654 |

相对旧 current 加速 55.38 倍，相对 original 加速 3.79 倍。不同重复数，不能据此报告统计显著性。
十批 affected 为 `[1,1,0,0,1,2,2,3,0,3]`，均值 1.3，全部闭合无 fallback。
每批正向只需出队 8 个顶点、访问 262,144 边，就获得 261,946 个真实有根锚点；
随后反向查询每批只访问约 2.2–3.2 万边。GPU repair 每批只有 0–3 顶点、0–1 条入边。
这验证改善来自消除近全图失效/修复，而不只是降低某个 kernel 的常数。
该轮是性能检查；实图 correctness 单独使用 TW/100k 的逐阶段全图 oracle，不用 Test passed 冒充正确性证据。

### 已完成：TW/10k 性能

同样 GPU 0 / NUMA 0 / check=false，十批 4,264.223 ms；原 original 两次均值
12,569.368 ms，旧 current 两次均值 279,560.743 ms。分别加速 2.95 倍、65.56 倍。
十批 affected 为 `[13,19,10,12,16,15,18,10,12,5]`，均值 13，全部 closed=1。

FS/100k 新版在 GPU 1 / NUMA 0 / check=false 的十批时间为 11,080.608 ms；
与旧 current 11,330.930 ms 同一量级，不把单次约 2% 的差异表述为显著提升。
同 GPU 新测 original 为 14,216.200 ms，新版快 1.283 倍；两者均为 GPU 1 / NUMA 0，单次十批，check=false。


### 最终 TW 性能结果（全部完成）

GPU 0 / NUMA 0 / check=false；保留原始输入、更新及原实验参数。
单位为十批增量算法总时间 ms，包含删除、插入、热度和 cache 维护；不含读图和初算。
旧 current / original 为原记录两次均值；新版每档一次，不报告统计显著性。

| 更新规模 | 旧 current | original | 新版 | original / 新版 | 旧 current / 新版 |
|---|---:|---:|---:|---:|---:|
| 1k | 179,182.702 | 12,278.171 | 3,235.654 | 3.795× | 55.38× |
| 10k | 279,560.743 | 12,569.368 | 4,264.223 | 2.948× | 65.56× |
| 100k | 739,973.759 | 14,535.432 | 8,662.055 | 1.678× | 85.43× |

三个 TW 档位全部超过 original 的同 GPU 历史参考。新版十批均成功且全部 closed=1。
100k 新性能运行的 affected 均值 140，incoming 修复均值 9，与独立检查运行一致。
1k / 10k / 100k 的 affected 均值为 1.3 / 13 / 140；旧实现三档都约 4,923 万。
这是删除修复工作量从近全图回到稀疏更新区域的结构性改变。

证据索引：

- 机器可读指标、原始日志路径、正确性结果：logs/cc_tw_structural_20261001/verification_summary.json
- 精简结果表：paper/evaluation/data/cc_structural_fix_20261001.md
- CSV：paper/evaluation/data/cc_structural_fix_20261001.csv
- 冻结二进制与源码哈希：logs/cc_tw_structural_20261001/source_manifest.json
- 原实验 raw/cc_pr_20260928 和既有 PR/CC 汇总保持原样。

复现：先构建 hybrid_cc，再用 scripts/run_cc_structural_perf.py 的独立 --output 目录、
--datasets TW --scales 1k 10k 100k --repeats 2 --gpu 0 --numa 0；
--check 单独跑正确性，--variants reverse 可关闭新增正向证书作消融。
脚本只读原实验命令和输入，不覆盖原论文结果。

边界：这是有界共享有根证明，不承诺任意图、任意大割集的最坏情况性能。
证书失败仍走原有保守精确修复；没有通过 parent-only、无向 union、近似标签或跳过删除换取速度。
