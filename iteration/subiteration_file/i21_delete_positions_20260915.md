# I21 删除位置复用与连续存活区间搬移（2026-09-15）

状态：4次短筛查已完成并审阅；位置复用工作量机制成立，但完整时间单次仅改善0.76%/0.51%，无稳定显著收益证据，候选保持默认关闭、归档，不追加反向配对。用户本次要求直接推进瓶颈优化，取消独立大图正确性检查作为前置任务。保留必要的小规模语义/机制测试和性能运行内的批数/策略/最终checksum校验，不把这些证据写成目标大图全阶段检查通过。

## 为什么调整原先预想

I20两轮配对后，FS大模式两批prepare约2.006 s、preflight约4.144 s，而apply约0.956 s；距历史目标仍需减少约2.183 s。因此邻接搬移优化本身没有足够实测预算保证FS追平，不能先假定多段/块结构会解决全部差距。

代码中更直接的重复工作是多删除路径：`BuildDeletionPlan`已经逐边寻找并确认删除occurrence，但`CompactSourceInPlace`及扩容rewrite随后又通过`ShouldDelete`逐边重新匹配删除run。首个I21候选复用匹配位置，并将存活邻接按连续区间搬移。它不引入新块布局、空洞、tombstone、GPU查找或跨批整理债务；相比预想块级重建，实现更小、可单独证伪。它属于访问/匹配工作放大控制，不声称已经降低存活边写入量或完成块级结构创新。

## 实现与成本契约

- `GroupedUpdateBatch`在批次开始时冻结`CG_REUSE_DELETE_POSITIONS=0|1`，默认0；仅在`CG_BATCH_MAINTENANCE=large`或auto选中large时生效。无图名/比例/耗时判别。
- 多删除source在权威匹配过程中记录递增邻接offset，保持原来的first-occurrence和重复删除计数规则。每source借用单个批次数组内互不重叠的request范围，无逐source vector分配。
- 删除或mixed phase临时分配`RequestCount()*sizeof(index_t)`未初始化空间，10M混合批次容量40 MB，只有已匹配位置可读；单条删除仍用原快速路径，不写位置列表。Add phase不分配位置空间。
- 原地compact跳过未改变前缀和已删除边，以memmove搬移存活区间；扩容rewrite复用相同位置复制存活区间。GPU仍读取原连续source-local邻接，stable顺序、descriptor/version、reverse有效变更、发布和回收契约共用。
- 位置数组在当前mutation函数返回前销毁，无跨批持久结构状态。分配、位置写入和复制代价计入当前P0；prepare/preflight等嵌套timer不作重复相加。数组容量单独记录为`position_capacity_bytes`，不是实际写入或完整内存流量。

代码：`include/framework/effective_update_batch.h`、`include/groute/graphs/source_local_chunk_store.h`、`include/framework/framework.cuh`。CPU replay的计量接口也增加位置容量字段，但本轮不启动长CPU replay。

## 已完成的验证

候选开启：grouped-update、source-local chunk store、dynamic reverse、I19 work metrics四项CTest通过。候选关闭：source-local、dynamic reverse、work metrics三项通过。沿用现有随机跨批regular/large切换与双向oracle、重复/缺失删除、删后重加、epoch、空phase、分配/observer失败检查。

新增定向fixture同时覆盖长前缀、分散/连续匹配位置、重复destination、无效删除以及mixed扩容。对独立TopologyReplayModel结果和邻接顺序检查通过；原地mutation读取4096→1092条，扩容4096→4092条，写入量不变。该数据仅为机制fixture，不是实际大图收益。没有单独追加GPU smoke或大图correctness队列。

## 短筛查与裁决

双方使用同一冻结二进制`53e293d09d2389f915c40e7871535269f8c3c2bc4f18f225b06f63a0bfca3e86`，都启用I20 large，只切换位置复用0/1，因此测量I21相对I20的增量收益。沿用TW/FS10M各两批、NUMA0、20workers、64reverse shards、cache2、ordered0、通信计量关闭。核对原输入哈希和历史已验最终距离checksum。

顺序为TW positions_off→positions_on，再FS positions_off→positions_on，共4次完整性能运行。关闭check以免把检查开销混入性能，不重跑192批CPU或18次GPU矩阵。已有I20大图加载/运行约19分钟/4次，据此预估20～30分钟，有调度波动。

结果同时记录完整P0、prepare/preflight/apply/mutation、匹配读取与mutation读取、forward写入、位置容量、RSS及checksum。必须看到实际重复访问减少且完整收益未被新增准备/空间成本抵消；完整时间无收益则审阅后调整或撤回，不以单个memmove/malloc timer保留候选。runner中的5%布尔字段仅沿用I20预算作参考，I21的判断仍需结合剩余差距、整体重复方向与空间成本，不能把一次筛查当作稳定结果。

启动命令：

```bash
python3 -u scripts/run_i20_screen.py --output logs/i21_positions_20260915 --positions
```

本次PID `227675`，状态文件`logs/i21_positions_20260915/status.json`。查看：

```bash
watch -n 10 'cat logs/i21_positions_20260915/status.json'
```

`completed_gpu_runs=4`且`state=screen_complete_needs_review`表示正常完成；`failed_or_blocked`表示异常停止。结果位于同目录`gpu_results.json`和`screen_summary.json`。后台只运行固定4次，不自动追加实验或启用默认候选。I22仍未启动。

## 完成结果与裁决

4次运行全部完成，墙钟1146.0秒（19.1分钟），两图off/on最终距离checksum均与各自历史参考一致。每项时间为两批完整P0合计。

| 图 | I20大模式（位置关） | 位置开 | 完整下降 | mutation读取减少 | apply减少 | prepare变化 |
|---|---:|---:|---:|---:|---:|---:|
| TW10M | 11295.117 ms | 11209.066 ms | 0.76% | 38810767条 | 192.237 ms | 增68.383 ms |
| FS10M | 13646.342 ms | 13576.573 ms | 0.51% | 96908378条 | 50.942 ms | 降15.277 ms |

匹配阶段读取与forward写入量均不变；位置缓冲区单phase容量40 MB，两批累计分配容量80 MB（不是峰值80 MB）。完整收益仅86.051/69.769 ms，远低于剩余追平缺口；单次试跑不能区分这种小幅变化与环境/SPT工作波动。不能把读取大幅减少等同于完整系统有效加速。

裁决：位置复用候选保留为默认关闭的研究artifact，不并入启用路径、不追加反向配对。I21首个候选筛查结束；没有证明块级重建必败，但当前apply预算不足以支撑FS追平，不再延长这一局部路线。I20共享规划仍为large开发基线。

准备成本复核发现per-source统计精简已在2026-09-14 B5中因性能回退撤回，见 `i17b7_b5_progress_20260914.md`，不重复立项。下一执行方向转I22 EU insertion，先从已有日志定位frontier重复工作和完整服务入口，选择短开发配对；不恢复CPU propagation、不启动十批长矩阵或独立大图正确性检查作为前置。TW/FS尚未追平的缺口继续保留，不能将进入I22写成四项目标达标。

本次仅完成审阅与计划更新，无新增后台实验。I22待开始实现，不声称已启动。
