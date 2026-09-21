# I23：TW批量source分组构建，1M瓶颈驱动的三配置消融

## 来由与现有结果

用户授权：进一步针对瓶颈，可按实验发现采用更好的科研/工业方法，目标仍为FS或TW在1M/10M优于原系统之一。此轮不宣称某方法是最先进；采用数据库/并行图处理中通用的count-prefix-scatter批量构建思想，实际收益由完整运行决定。

I21 A+B TW1M四次全部完成、checksum匹配；完整两批均值1762.8825→1686.1625ms，下降4.35196%，两对1.84234%/6.78739%，未过每对5% Gate，10M未启动。阶段均值如下，均为两批总和：

| 阶段 | 原路径ms | A+B ms |
|---|---:|---:|
| grouping | 141.225 | 133.977 |
| publication source排序 | 109.140 | 8.992 |
| mutation prepare | 293.164 | 319.017 |
| mutation preflight（含reverse） | 463.003 | 453.971 |
| reverse prepare（preflight子项） | 208.847 | 206.126 |
| mutation apply | 150.192 | 163.368 |
| retire | 52.267 | 49.394 |

A排序收益明确；B未体现为显著grouping收益，而且第一批delete prepare/apply出现相关回退，不能凭此确定因果。preflight仍最大，其中非reverse约248ms/两批；不重复此前B5统计结构精简负结果，也不把reverse与preflight相加。先补grouping内部计时，确定剩余串行物化是否有真实可消除成本。

## 新机制

`CG_BULK_SOURCE_GROUPS=1`显式启用：

1. 对排序后记录的连续区间并行统计source起点，以小型分区前缀和确定每个source的输出位置。
2. 一次确定sources/groups/destinations大小，并行写destination与group起点，避免逐条push_back与多轮扩容搬移。
3. 起点全部可见后，按group分区确定delete/add边界。稳定source排序保证同source删除在插入之前；partition_point对跨record分区的大source也正确。
4. 每分区计算delete/add group数，再前缀分配两phase索引并写入，保持phase source索引严格有序。

使用原mutation固定worker池；没有额外thread pool或GPU内存。输入排序与group构建独立开关，当前生产消融关闭并行radix，仅隔离bulk构建。<4096、无pool、worker<=1回退原路径；默认关闭。临时新增O(workers)计数数组，三项输出仍是既有表示；不改forward/reverse含义、有效变更、epoch或两次闭包。group物化计时不含返回时少量分区计数数组析构；sort计时包含radix scratch释放。整体I14 grouping另含输入转换、record释放和旧batch释放等，不能直接等于三个细分timer之和。

`I23-GROUP`新增record_ms/sort_ms/materialize_ms；原I14完整group与P0仍作上级口径。

## CPU实测与验证

`src/i23_group_replay.cpp`读取现有TW1M manifest首批合法记录，NUMA0/20 workers，对三种构造逐元素比较sources、destination序列、phase索引。结果见`logs/i23_bulk_tw_20260916/group_probe.jsonl`：

| CPU首批模式 | record ms | sort ms | materialize ms | 构造总ms |
|---|---:|---:|---:|---:|
| 串行radix＋串行物化 | 10.577 | 32.431 | 37.977 | 80.991 |
| 串行radix＋bulk | 5.905 | 25.198 | 11.319 | 42.427 |
| 并行radix＋bulk | 4.834 | 19.535 | 13.069 | 37.443 |

这仅为一次固定顺序机制探针，缓存/allocator状态不同；不能把总时间差全归因于bulk，也不是完整SSSP加速。可用预算为物化约26.7ms/批，而非保证兑现。由于bulk本身已显示明确成本差，完整消融先不叠加并行radix，避免再次混淆归因。

- hybrid_sssp与CPU probe构建通过；4项CTest通过。
- grouped_update_batch_test覆盖bulk/radix四组合、0/1/4095/4096/4097/100000记录、32位source、重复destination、phase索引；独立map/输入顺序参考保持一致。
- 新增8193条同一source跨所有record分区、纯删除/纯插入/混合、空group分区、非法开关用例。
- `tests/i23_bulk_group_test.py`在8192节点、每批4096删除＋4096插入、三批反向更新下实际执行bulk=1。GPU六个stage checksum与独立Python Dijkstra逐阶段一致，final checksum一致。SEGMENT32、large、block插入、ordered关闭；不把小图正确性说成大图全阶段oracle。
- `git diff --check`和Python编译检查通过。

## 后台完整消融与10M准入

入口`scripts/run_i21_radix_queue.py --bulk`，复用已有安全GPU串行执行器，PID2455334，目录`logs/i23_bulk_tw_20260916/`。当前健康进入TW1M首个运行。顺序固定为A/B/C/C/B/A，每次两批：

- A：原publication排序、串行radix、串行group。
- B：仅publication有序合并，其他与A相同。
- C：publication合并＋bulk group，radix仍串行。

TW1M共6次。同冻结二进制、同cohort哈希、GPU0/NUMA0、20 workers、64 shards、large/cache2/SEGMENT512。逐批检查实际bulk/merge策略、完整批数与最终checksum，保存完整P0、细分阶段、records/source-work、RSS与2秒GPU采样峰值。GPU外部占用则停止自身任务。status.json和queue_status.json为实时权威。

准入TW10M：C相对A两对完整P0均>=5%，且C相对B两对都严格改善；通过才在同输入预算下执行10M同样6次，否则停止待审阅。最多12次后台GPU运行；健康确认后不持续轮询。10M预算沿用上一轮已说明的TW16GB/cache2成功配置，新机制仅CPU空间变化，不偷偷减cache；100M及FS矩阵不启动。

**本轮截至交付：性能待结果，默认关闭，未宣称战胜原版。** 任一低于历史原版目标仍需共同语义/输入/资源/结果指纹核实，不能把旧跨系统checksum差异忽略。若bulk只有局部收益或影响后续mutation导致完整回退，关闭候选；下一方向转preflight effective生成和reverse分阶段工作，先计量而不重新做已否决的统计结构精简。


## 2026-09-17最终裁决（覆盖上文运行中状态）

6/6完成，checksum匹配。原路径1758.9835ms，仅合并1624.7085ms（-7.6337%），合并+bulk1687.347ms（-4.0726%）；bulk相对仅合并回退3.8554%，两对均回退，因此否决bulk。队列停止于1M，10M未运行。前次将仅合并收益误写4.07%的会话结论已纠正。后续独立验证单独合并的TW10M规模效果，见[I24](i24_tw10m_publication_20260917.md)，不恢复bulk组合Gate队列。
