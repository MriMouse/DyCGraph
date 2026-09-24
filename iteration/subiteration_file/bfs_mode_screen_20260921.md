# BFS 大 batch / 路网模式短测（2026-09-21）

用户授权检查两种模式适配，并做少量 paper algorithm 性能实验，强调不能干扰其他实验。六次后台串行运行已全部结束，没有继续扩大实验矩阵。

## 适配检查

- 大 batch：`CG_BATCH_MAINTENANCE=large`；`auto` 在 additions+deletions >= 1,000,000 时选 large。与 BFS/SSSP 的边权语义独立，使用同一 source-group/effective-update/reverse/publication 实现。
- 路网：`CG_ORDERED_REPAIR=1` 同时启用有序删除修复及有序插入，BFS 的修复权重为 1；插入为距离加 1。可与 regular/large 任意组合。
- **不要用 `--large_batch` 选择大 batch 模式**：它是未接通的旧 PMA 实验标志，应用仍打印 fallback 提示。
- 运行日志确认真实选择：`I20-MODE maintenance=large requests=1000000`；auto 两批实际均 large。路网两批均有 `I17-ORDERED` 和 `I22-SCHEDULE mode=ordered selection=large_diameter_mode`，不是只设置了环境变量。

## 隔离与实验规模

SSSP PID 875349 当时运行于 GPU 0、NUMA 0（CPU 0–19/40–59）。本次使用 GPU 2（NUMA 1 的 PCIe root）、CPU 24/25、严格 NUMA 1 内存绑定，nice 15、ionice idle、2 mutation workers。未重建/替换 SSSP binary，未修改其环境、affinity 或进程。输入在 NUMA 1 的 `/dev/shm` 生成，避免读取真实大图/共享数据盘造成额外 I/O。每次均检查 GPU 2 空闲；脚本设置独立锁、超时和仅终止自己子进程的资源检查。后台 PID 883766，当前状态 completed / 6。

统一配置：冻结 `build-bfs/hybrid_bfs` 副本、cache=2、SEGMENT=32、n_stream=3、hybrid=0、reverse shards=64、publication merge=1、关闭 bulk/radix/positions/通信诊断、check=false。仅改变 maintenance 和路网开关。每次两批，第二批恢复第一批修改，因此每组最终拓扑相同。

- 百万更新图：65,536 顶点、1,048,576 有向边；每批 500,000 有效删除 + 500,000 有效插入，共 1,000,000 更新。保留环边确保可达，日志确认每 phase effective records=500000、changed_sources=62500、missing_deletes=0。
- 长直径图：4,096 顶点、8,444 有向边的双向双车道路段，稀疏连接两侧；每批 62 删除 + 62 插入，共 124 更新。属于受控合成图，不是真实 EU/USA 路网。

## paper_algorithm_ms 结果

指标为两条 `[P0-TIMER][BFS] total_batch` 之和，包含增删维护、传播和 cache/hotness；不计一次性加载和初始 BFS，不外推成十批。

| 输入 | maintenance | 路网开关 | batch 0 ms | batch 1 ms | 两批 paper_algorithm_ms | 相对该图普通模式 |
|---|---|---:|---:|---:|---:|---:|
| 百万更新 | regular | 0 | 225.778 | 188.405 | 414.183 | 基线 |
| 百万更新 | large | 0 | 218.340 | 179.013 | 397.353 | 下降 4.06% |
| 百万更新 | auto（实际 large） | 0 | 223.086 | 170.903 | 393.989 | 下降 4.88% |
| 长直径 | regular | 0 | 84.688 | 114.448 | 199.136 | 基线 |
| 长直径 | regular | 1 | 68.740 | 95.959 | 164.699 | 下降 17.29% |
| 长直径 | large | 1 | 68.600 | 96.324 | 164.924 | 下降 17.18% |

auto 与 large 实际同一维护路径，两者间的几毫秒差异不解释为 auto 加速。路网+large 在 124 更新下与路网+regular 基本相同，不声称小 batch 需要 large。

六次最终 distance checksum 均通过独立 FIFO BFS：百万更新组 15169262176585702227，长直径组 5449529026844528003。此前独立 correctness smoke 已覆盖三种调度的 18 个阶段。本次关闭逐阶段 check，仅最终 checksum，不将其写成百万更新的逐阶段完整 correctness 验收。

## 结论与边界

两种模式及组合已适配，并在实际运行中生效；本次单次合成图筛查观察到 large 约 4% 和路网模式约 17% 的完整 batch 收益。没有交错重复或真实大图，不能声称稳定收益、论文正式结果或优于旧 BFS 系统。

每个子进程在首个两秒资源采样前已经退出，旧 runner 的 sampled_peak_rss_kb / sampled_peak_gpu_mib 为 0 实际表示**未采到样本**，绝非零资源占用；wall_s 也包含轮询等待，只作监控耗时，不能用来评估算法。当前脚本已将未采样值改为 null 并将该耗时字段改名 monitored_elapsed_s；没有为修正元数据重复跑实验。冻结 runner 中反向 radix 的显式关闭变量拼写未被框架识别，但 CG 环境在启动时已清空且该优化默认关闭，因此本次实际仍为关闭；当前脚本已修正变量名。原始 artifact 不改写。

结束后 GPU 2 显存回到 0、利用率为 0，SSSP PID 875349 仍在 GPU 0 运行。采取了上述硬件/CPU/内存/I/O 隔离措施；没有测量足以证明共享主机干扰严格为零。

可复现脚本：[run_bfs_mode_screen.py](../../scripts/run_bfs_mode_screen.py)。完整日志、冻结脚本、binary/input SHA256、命令、模式选择、结果和状态均位于 `logs/bfs_modes_20260921/`，入口 `report.md` / `results.json` / `manifest.json`。输入保留在 manifest 指定的 `/dev/shm` 目录，内容也可由脚本确定性重建。
