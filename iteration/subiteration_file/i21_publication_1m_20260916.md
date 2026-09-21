# I21 候选A：1M publication source有序合并

## 范围与实现

按主计划末尾2026-09-16修订执行，聚焦FS/TW扩展性，先1M，不启动10M/100M，也不续跑EU insertion。

`CG_MERGE_PUBLICATION_SOURCES=1`启用候选，未设置保持原sort+unique。两个publication入口共用FinalizePublicationSources。delete后记录列表分界，add后对两段有序changed-source执行set_union+unique，使用跨批复用scratch。changed列表来自source-ordered prepared结果，仅包含实际生效变更；无效删除不进入publication。未修改拓扑布局、reverse、epoch或delete-repair-add顺序。代价是额外host scratch，容量上界为两phase source总数；不增加GPU拓扑。

新增`I21-PUBLICATION`记录输入/输出source数与source_order_ms；完整P0包含此成本。默认路径保留，候选收益未裁决。

## 验证

- hybrid_sssp构建通过。
- publication_sources_test、source_local_chunk_store_test、grouped_update_batch_test、dynamic_reverse_index_test共4项CTest通过。
- 合并测试对不同分界（含空phase）、重复source、跨phase重复及scratch跨次复用，与独立sort+unique参考逐元素比较。
- 实际chunk-store测试覆盖重复/缺失删除、删后重加、changed过滤与source顺序。首版测试误在两个phase间Publish，触发`no pending chunk-store batch`；修正测试以符合现有epoch契约后通过，生产epoch协议未改。
- 候选开启、large模式，既有三批非对称GPU smoke通过Bellman及首批CPU PQ oracle。日志在`logs/i21_publication_1m_20260916/smoke/`，不是大图全阶段正确性结论。

## 后台1M配对

入口`scripts/run_i21_publication.py`，目录`logs/i21_publication_1m_20260916/`，启动PID 2142409。先验证既有1M输入哈希，再TW、FS各off/on/on/off，共8次，每次两批；同冻结二进制、GPU0/NUMA0、20 workers、64 reverse shards、cache2、SEGMENT512、large维护，ordered关闭。每次检查GPU空闲，运行中检测外部GPU进程，有冲突停止自身任务。

保存command、输入/二进制指纹、完整阶段日志、最终距离checksum、RSS峰值与2秒采样GPU峰值（非精确分配峰值）。原始阶段指标保留嵌套关系，不直接相加。每批必须为0/1，候选与large接线必须正确，最终checksum必须匹配已有输入参考，否则停止。最终summary给出两对完整P0收益及均值，不自动promote，不启动B/C或10M。

**当前状态：已启动，性能待结果。** `status.json`为实时权威；本报告不宣称FS扩展性问题已解决。健康确认后不持续轮询，后续审阅完整P0约5%门槛再决定撤回/保留及候选B。10M需先提醒迁移至更大GPU并确认显存预算，100M继续延期。

## A结果与后续裁决

8/8完成，最终checksum均匹配。TW两批均值1728.949→1641.006ms，下降5.0865%，两对6.3818%/3.7570%；FS1893.4295→1798.7675ms，下降4.9995%，两对6.4694%/3.4997%。未满足两对都>=5%的严格门槛，不默认启用。TW每批source排序约54→4.5ms，支持机制有效但单项收益边界明显。

用户随后授权继续FS或TW的1M/10M，任一优于原系统即可，并允许据实测调整预想方法。本轮据此保留A作为显式组合候选，推进B，不把A写为严格Gate已通过。新队列优先TW，见[i21_radix_tw_20260916.md](i21_radix_tw_20260916.md)。
