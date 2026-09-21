# I17-B5：复用 source 顺序与并行 incoming 物化（2026-09-14）

## 范围和依据

延续四个落后项的当前计划，本轮先处理 TW scaling 1000K/10000K、FS scaling 10000K 的共用 B5 路径。保留此前 mixed-source radix；不恢复统计结构精简、CPU propagation、事务化 mixed batch、正式矩阵或参数扫描。

上轮 `tw10000_radix/run.log` 两批 incoming topology 合计 2519.877 ms、四个 phase reverse sort 合计 1362.906 ms。这两项是真实的完整 batch 内成本。reverse prepare 已包含在 mutation preflight 中，incoming topology 已包含在 deletion 中，不能重复相加。

## 本轮候选

1. `SortEffectiveDeltas` 在大列表上检查 source 是否单调；若已排序，只做四个 destination radix pass。forward 通过 `GroupedUpdateBatch` 和 source-ordered `prepared` 输出有效记录，已有 source 次序可以复用。任意调用者的乱序输入仍执行完整八个 pass，不引入依赖调用者承诺的跳过开关。destination 稳定排序保留 source 次序与有效计数，不改变删除/插入阶段。
2. `DynamicReverseIndex::MaterializeIncoming` 使用已有 persistent worker pool 按 4096 个 destination 的 tile 并行 merge。每 tile 暂存输出，再计算 prefix、并行复制到连续 CSR。每条 base/delta 记录只扫描一次；输出仍按输入 destination 顺序排列，每个 destination 内 source 去重/有序，与原实现相同。小列表或单 worker 保留直接物化。4096 是任务粒度，不是按图训练的 selector。

新的空间/计量口径：此方案以临时 host vectors 和一次 CPU copy 换取并行构建，并非零拷贝。输出为 E 个 source 时，额外逻辑 CPU copy 为 `E * sizeof(index_t)`；vector capacity 还受增长策略影响，不能用逻辑长度冒充精确峰值。没有新增 GPU allocation 或 CUDA payload，也没有把 CPU copy 接入 B7 的自动账本。通过 `/usr/bin/time` 记录进程峰值 RSS，该值包含初始化且不等于这一数组的峰值。

## 验证与实验状态

`hybrid_sssp` 及三个相关测试目标构建成功。5 项 CTest 通过：reverse、chunk store、grouped update、communication meter 开/关。新增回归覆盖 source 已排序/乱序的完整 32-bit IDs 与重复计数，以及 4095/4096/4097/17001 个 destination 的 serial/parallel 精确 CSR 和扫描计数一致性；含重复 destination、非法 destination、base 重边、删除抵消和 overlay 新边。

实验目录：`logs/i17b5_continue_20260914/`；串行 runner：`scripts/temp_scripts/run_i17b5_continue.py`。沿用性能矩阵的原 command.json、source、cache=2、20 workers、64 reverse shards、两个 batch；计量关闭。启动前同时确认 GPU 0 无 compute process 且 memory.used=0；不使用其他 GPU。正确性运行单列，不计入性能对照。

冻结基线 SHA256：`6cb09ce543cc779b00ed4165e5f2111707e4641a3ff6e985ffce033dcd788d8c`。

冻结候选 SHA256：`c8552fc859bddec1c39e042127f3097c386c534500cd18394cb5c06bc922e34e`。

最终候选的三组性能配对及 TW/FS 完整正确性均已完成，保留 source-order 复用、并行 incoming 物化与 warp 归约；TW1000K 的最小重复确认见文末。四个原版追平目标不能整体写为完成。

## 追加候选：warp incoming min-plus 归约

首轮 TW1000K 完整时间从 4450.489 ms 降到 4012.252 ms，但候选 GPU pull closure 仍为 2010.616 ms；单线程负责一个 destination 的整个 incoming row，使长行仍串行。第二候选让一个 warp 协作扫描一行，按 `(distance, parent ID)` 归约，lane 0 完成原有 value/buffer/parent 提交和 changed queue 发布。保留自然收敛；没有改变 affected 集构造、incoming CSR、SSSP 权重或删除/插入边界。非 32 整数倍的 block 使用同一代码的 width=1 分组，不增加用户模式开关。

该机会属于 B5 原计划的“删除修复准备与传播”，但具体 warp 归约由本轮代码检查提出；不能预先声称已减少传播轮数或实际 edge scans。新增 `tests/i17b5_pull_smoke.py` 用 1024 入边的长行与三次 mixed batch 验证 Bellman 和独立 CPU PQ snapshot oracle。

最终候选 SHA256：`816169b0ad56929acfe2b96ded0a059cb7ae3826b57fb4d740319da9c0808c3c`。原 host-only 候选作为中间 artifact 保留。为避免重复的大图 correctness 初始化，旧 scheduler 在 FS 基线执行中停止后续调度；正在运行的 FS 实验未中断。最终候选统一验证三项短配对及 TW/FS 正确性。

### NUMA 混杂与对照修订

未绑定 TW10000K A-B-B-A 为 17650.018 / 18520.311 / 18689.461 / 22704.563 ms；四次 checksum 相同。A 的 mixed grouping 从 1750.681 ms 变为 2336.106 ms，incoming 从 2534.400 变为 3750.608 ms，证明单次差异不能全部归因于代码。

设备拓扑显示 GPU 0 属于 NUMA 0；B2 主线程实际在 NUMA 1（CPU 29/69），一次 `numastat -p` 显示约 6580 MiB 在 NUMA 1。该观察提供放置混杂线索，不足以独立证明全部慢因。最终开发配对双方均使用 `numactl --cpunodebind=0 --membind=0`，仍为 20 workers，记录 `numa_node=0`；分析脚本拒绝混合绑定与未绑定的结果。这是可复现开发环境控制，不是 dataset-specific 参数扫描，也不改写旧原版中位数或追平标准。

## 最终候选同 NUMA 单次开发配对

所有结果为两个 batch 合计，单位 ms；性能运行 `check=false`、meter 关闭。这里的 A 是本轮冻结的上次 radix 基线，W 包含 source-order 复用、并行物化与 warp 归约三个变化，不作三项独立因果消融。

| 配置 | A 完整时间 | W 完整时间 | 下降 | 原版历史目标 | 当前判断 |
|---|---:|---:|---:|---:|---|
| TW1000K | 3891.473 | 1808.632 | 53.52% | 2242 ms | 三次候选中位数越线，停止专项优化 |
| TW10000K | 16977.157 | 11918.180 | 29.80% | 10716 ms | 改善，尚差约 1202 ms |
| FS10000K | 16947.927 | 14334.668 | 15.42% | 11468 ms | 改善，尚差约 2867 ms |

| 配置 | A incoming | W incoming | A closure | W closure | A / W RSS KiB |
|---|---:|---:|---:|---:|---:|
| TW1000K | 206.994 | 42.870 | 2008.007 | 110.780 | 19722512 / 19720740 |
| TW10000K | 2489.954 | 246.753 | 2888.629 | 438.964 | 22723048 / 22702140 |
| FS10000K | 1902.253 | 283.643 | 373.232 | 341.251 | 60649228 / 60648668 |

三组最终 checksum 分别为 `15984646590043123926`、`791729548754523982`、`7340189607729832727`，各自 A/W 相同。RSS 是进程峰值，不能据微小下降声称内存优化；本轮证明的是未观察到总峰值增长，不是否认临时物化副本存在。

TW10000K 最终候选 mixed grouping 为 1711.435 ms、mutation 四阶段合计 6622.597 ms，后者已包含 reverse prepare。剩余 B5 主工作回到 forward preparation、effective 构造与发布的重复遍历/分配；不继续为亚秒级 incoming/closure 追加参数微调。EU1000K 的 B6 insertion 尚未实施，本次不能宣称四项目标完成。

## 最终正确性与保留裁决

`tw10000_w_check/` 与 `fs10000_w_check/` 均完整成功：每图两次 deletion-stage、两次 batch、一次 final Bellman 均 `source_ok=1`（阶段检查）、`relaxable_edges=0`、`missing_tight_witnesses=0`。最终 checksum 分别为 `791729548754523982`、`7340189607729832727`，与性能版本一致。stored-parent invalid witness 按四个阶段顺序为 TW `7/7/6/6`、FS `350/343/322/314`，仍仅作既有诊断，不宣称 parent correctness 封板。

性能和 correctness 使用同一 `warp_candidate` 二进制。新增长行三批 GPU 检查与 CPU oracle、6 项相关 CTest 全过；脚本语法与 `git diff --check` 通过。保留三项结构优化，不新增运行时 old/new 开关。未绑定 host-only 候选的首对回退和后续反向结果作为环境混杂证据保留，不删除失败方向，也不单独宣称 host-only 已稳定胜出。

## 重复确认、收尾和下一步

TW1000K 同 NUMA 候选三次为 `1808.632 / 1749.237 / 1811.779 ms`，中位数 `1808.632 ms`，三次最终 checksum 均为 `15984646590043123926`。中位数低于原版历史 `2242 ms` 约 19.33%，最慢一次也低于该目标。本轮按既定历史目标线停止 TW1000K 专项优化。注意：当前侧明确绑定 NUMA 0，原版历史侧未重新运行，这不是双方新采集的等条件三次中位数对照，也不替换原性能大表；同 NUMA A/W 的 53.52% 仍只有一次基线配对，不能改称三次配对中位加速。

本次 B5 子迭代结束，全部 runner 已退出，无遗留 GPU 工作。`build/hybrid_sssp` 与最终冻结 `warp_candidate` SHA256 一致。原工作区已有改动均保留，没有 git reset/checkout 或外部仓库写入。

本报告原有未执行 B5/B6/B7 后续清单已删除，统一由主文档文末 I19—I22 接管；本轮已完成结果与不足保留，不再维护独立队列。

开发复现与汇总入口：`scripts/run_i17_target_check.py`、`scripts/temp_scripts/run_i17b5_continue.py`、`scripts/temp_scripts/analyze_i17b5_continue.py`。日志目录不覆盖旧实验。中间 scheduler 提前停止只取消未开始的任务，所有实际启动的 GPU 实验均正常完成。

## 口径补充

相同输入和最终 distance checksum 不保证中间 affected 集逐项相同。当前 SPT parent 的并行平局选择会改变后续 deletion invalidation 范围；首个新基线日志与历史 radix 日志已出现 affected 数差异。因此按完整 batch 判断性能，机制数据报告实际值，不能把不同运行当成固定 affected workload 的严格微基准。完整距离/Bellman/tight witness 仍是 correctness gate，stored-parent 问题未在本轮解决。
