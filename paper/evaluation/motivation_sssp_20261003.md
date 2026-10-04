# SSSP 动机实验（2026-10-03）

启动脚本：`scripts/run_motivation_sssp.py`。补丁生成器与计量头文件：`scripts/motivation/prepare.py`、`scripts/motivation/meter.h`。

## 开关与隔离

不修改当前系统或 `../C-GpuStreamGraph` 的运行时算法实现。脚本冻结当前工作区源码（包括未提交修改）；Grapin 使用 `raw/sssp_bfs_20260927/original_src`，即上次实验保存的原系统及完整批计时补丁。所有计量补丁仅应用于新的 `raw/motivation_sssp_20261003/*_src`，保存为 `*_motivation.patch`。

实验副本增加 CMake `CG_MOTIVATION_METER`，默认 `OFF`：关闭时 `#ifdef` 和空宏完全删除计量代码，没有计数、扫描、同步、内存分配或运行时判断。脚本单独编译 `ON` 版本。该版本还需环境变量 `CG_MOTIVATION_MODE=counts|timing`，默认 off。平时原有构建、二进制和历史结果不变。

## 实验矩阵与计时

SSSP × TW/FS × 100K（50K 插入 + 50K 删除）× current/Grapin × counts/timing × 2 次，共 16 个独立进程。每个进程消费十个混合批。每种模式采用 current / original / original / current 顺序，GPU0、NUMA0，串行执行；启动参数沿用用户指定的上次实验 `.command.json`。保留 hybrid=current:0、original:2 等各自优化配置，不强行改成相同访问策略。

**计数与计时分开运行，各两次。** counts 模式允许批边界全图 CPU 扫描和距离拷回，不使用该模式的耗时做论文时间结论。timing 模式完全不进行这些扫描和拷回，仅在粗粒度计算区间和整组工作集重建区间使用同步后的主机单调时钟。计的是完整多 stream 区间的墙钟时间，不把重叠 stream 的时间相加。不做逐边原子计数、不使用 profiler。

`compute_ms`：删除失效传播及恢复 + 插入传播/工作集构建，排除初始遍历、输入读取、CPU 物理拓扑更新、描述符发布入口、批后缓存维护。当前系统删除阶段物理更新前暂停计算计时，恢复前重启；Grapin 的删除恢复自然包含在其插入计算中。当前系统计算路径内已有的 publication 完成检查仍计入计算区间。同步计时会扰动调度，故此为诊断实验，不替代 20260927 的无计量性能结果。

`rebuild_ms`：计算区间内已有的整组工作集重建（包括过滤、压缩）以及 Grapin 初始全点工作集、首次传播后的重建和删除初始工作集。组边界同步等待所有相关 GPU 工作完成。当前系统本次配置直接维护精确队列，若未调用扫描重建则该项为 0；这不表示队列插入/去重没有成本。批后缓存工作集不计入此项。

`rebuild_share_pct = 100 × 两次运行重建总时间之和 / 两次运行计算总时间之和`，不是先求每批百分比再平均。每个原始计数先在十批上平均，再对两次运行取算术平均；同时保留全部 20 条逐批记录。

## 指标定义及边界

- `updated_sources`：本批插入和删除记录的源点并集，CPU 去重；是更新记录触及的源，不声称每条更新都实际改变图。
- `relocated_sources`：批前和批后都非空、且邻接起始位置改变的源数。Grapin 比较 `(edges_ 基址, index)`，可检测整块重新分配；current 比较 `(slab_id, index)`。这是批边界的**净地址变化**，不统计搬动次数，也不计移走后又回原址的瞬时移动。
- `relocated_untouched_sources`：上述源中不在更新源并集的部分，直接体现对未更新源的波及。
- `descriptor_bytes`：在真实增量 H2D 调用处按实际元素数 × `sizeof` 累加；Grapin 包含 sentinel，current 包含稀疏 patch 的 source/version 等字段。不计初始全图装载、缓存边数据和计量自身拷贝。这是显式传输 payload，不是 PCIe 总线线上字节。MB=10^6 字节。
- `invalidated_vertices`：current 使用已有去重 affected 队列长度；Grapin 在删除传播结束、恢复开始前比较距离，统计从有限值变为 UINT32_MAX 的顶点。两者均为依赖失效集合大小，不是最终距离变化点数；不同父节点选择可能导致集合不同。
- `initial_insertion_worklist`：Grapin 初始全点工作集大小；current 在直接插入边播种后已有精确队列的长度。后者可能为 0。
- `seeds_prebatch`：对本批每条插入边，用**本批开始前固定距离**判断 `d[u]+w(u,v)<d[v]`，按目的点去重。两系统使用相同时间基准及各自的批前距离，用于比较局部改善机会；只有算法结果正确时这些距离才代表同一最短路状态。合成权重为 `(u+v)%128+1`，与 SSSP 一致。
- `seeds_preinsert`：同一判定，但使用各自插入处理入口的距离。Grapin 此时尚未修复删除，current 已完成删除恢复，**不能视为同一图状态下的横向比较**。二者都不是插入传播最终影响的所有顶点数。

论文现有 Seeds 描述需要明确选择哪种基准。自动生成的 `table_rows.tex` 使用 `seeds_prebatch`，应写为 “destinations directly improvable by inserted edges against pre-batch distances”。Reloc. 应写为 “sources whose adjacency start addresses differ across the batch”。不能用净地址变化数宣称实际搬移事件总数。两个系统对比需在表中增加 System 列。

## 验证、输出与后台运行

正式大图运行前，脚本在 2048 点小图上运行两系统的 off/counts/timing 六种组合，用独立 Dijkstra 检查最终距离，同时检查十批计量完整性、计量前后距离完全一致及关闭时无计量输出。小图使用 SEGMENT=1（Grapin 的小图分段路径不能安全处理本例的 512 段），大图保持历史配置 SEGMENT=512。

实测：current 三种模式均通过 Dijkstra；Grapin 三种模式均有相同的 59 个距离不一致，且 counts/timing 的全部距离与 off 完全一致。这是未启用计量时已存在的基线差异，未为本实验修改原算法。`smoke.json` 中 status=ok 仅表示计量不改变结果及计量协议检查通过，oracle_mismatches 单独记录算法正确性诊断。大图沿用 `--check=false`；不得将本实验称为两系统大图正确性已验证。

输出目录：`paper/evaluation/raw/motivation_sssp_20261003/`。

- `status.json` / `runner.pid` / `runner.log`：后台状态与进度。
- `*.command.json` / `*.process.json` / `*.log` / `*.result.json`：每次完整命令、环境、进程信息、原始日志、成功/失败记录。
- `batches.csv`：所有成功运行的逐批指标。
- `averages.csv` / `averages.json`：两次完整成功后才填写对应模式的均值；失败不补零。
- `table_rows.tex`：所有组合成功后生成可审阅的表格行，不自动替换论文中的 x。
- `sources.json` / `binaries.json` / `inputs.json`：源码与二进制哈希、数据路径/大小/mtime。
- `smoke.json`：小图验证结果。

```bash
nohup setsid python3 -u scripts/run_motivation_sssp.py > paper/evaluation/raw/motivation_sssp_20261003/runner.log 2>&1 < /dev/null &
cat paper/evaluation/raw/motivation_sssp_20261003/status.json
tail -n 20 paper/evaluation/raw/motivation_sssp_20261003/runner.log
```

脚本单实例加锁；检测到 GPU 上有计算进程时等待。每次最多三小时，超时终止该进程组并保留失败记录。重启跳过已有运行记录（包括失败），不悄悄覆盖结果。可用 `--summarize-only` 重建汇总；源码或配置变化请另选 `--out`。
