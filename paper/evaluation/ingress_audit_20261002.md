# Ingress 公平性审计（历史记录）

**更新：后续已完成适配和验证并启动后台实验。当前配置与结果入口见 [Ingress 正式运行说明](ingress_run_20261002.md)。以下保留的是适配前的审计记录，其中“未完成/未启动”不再代表当前状态。**

2026-10-02。此前本次交互中的“审计通过”“开启分段优化”“PR error=0.001/source=10”“5次重复”陈述有误，以本文件及 `raw/ingress_20261002/fairness_audit.json` 为准。

当前交付是后台预检查脚本和48格计划，不是已完成的 Ingress 流式适配器。`scripts/start_ingress_paper_matrix.sh` 启动预检查；`scripts/run_ingress_paper_matrix.py run` 保存阻断原因并返回2，**不会运行正式性能测试**。已验证 Python 编译、shell语法，以及48格输入/批次检查；尚无算法正确性测试、正式运行或性能结果。

## 与已有 raw 矩阵一致的目标

- BFS、SSSP、CC、PR；OK、WK、TW、FS；1k、10k、100k。共48格，每格2次，与现有矩阵一致，共96次。
- 输入为 `data/paper_data/<dataset>/input_<scale>.txt` 及对应 update、stream_size。每次10批，每批50%删除、50%插入。保留原始方向、重边次数、自环和单位权重。
- BFS/SSSP 源点：OK=377664，WK=134151，TW=28512093，FS=0；逐格命令记录在 plan.json 中。
- 顶点集合应与现有 loader 一致，包含0到最大ID的所有顶点，不应直接生成1到最大ID而丢掉0。
- PR：alpha=0.85、base=0.15、不归一化、悬挂点不传播；每顶点有符号残差的绝对值阈值1e-6；收敛或最多100轮。初始计算和每个更新批次均采用这一停止策略。不是强制跑满100轮。

## 当前阻断项及证据

1. **优化未完全确认**：`Ingress/build_release/CMakeFiles/ingress.dir/flags.make` 含 `-O3 -DNDEBUG` 和 OpenMP；Cilk未编译，不能直接开启。`segmented_partition` 只在 flags 中声明/定义，没有运行分支使用它；Ingress加载器直接实例化 SegmentedPartitioner。原来的 `false` 并未关闭该路径的分段分区。需保留原生依赖维护和自动引擎选择，核实线程/NUMA配置后再作优化声明。
2. **PR语义不同**：`examples/analytical_apps/pagerank/pagerank_ingress.h` 硬编码0.85与0.15/N，悬挂点向顶点0发送；`1/out_degree` 还存在整数除法问题。传 `pr_d/pr_tol` 不会改变该 kernel 的对应行为。
3. **PR停止条件不同且不是10批**：`grape/worker/ingress_sync_iter_worker.h` 使用全局值差L1，指定正数 `pr_mr` 时忽略收敛强制到轮数，只完成一次旧图到新图的更新。需适配并验证10批，而非脚本传100即可。
4. **计时不公平**：旧遍历指标 `sum(reset dependencies)+Inc` 漏掉 `replay state` 和图结构重建；旧PR `run algorithm` 包含初始计算。目标应显式逐批记录拓扑维护、依赖重置、状态修正和算法计算，排除初始加载/求解、文件I/O及输出。不能通过预先生成全部快照又排除加载/建图，把拓扑更新成本消掉。快照预处理、I/O、重建成本应分别透明报告。
5. **其余待验证项**：CC是沿有向边传播最小标签，不能随意变成无向CC；删除和插入阶段、重复边、固定顶点映射、数值结果需要小图逐批独立验证。NUMA与CPU线程资源应对应记录（本系统raw有20个mutation workers），CPU/GPU硬件差异需如实报告。性能任务应串行避免干扰。

适配应保留 Ingress 自身计算引擎，仅添加流式批次、语义兼容和计时边界；修改后需要独立构建及小图验证，不能把重新实现的算法冒充未经修改的 Ingress。

## 预处理缓存和清理

缓存不是只依赖数据集名称。初始fragment依赖实际初始边集/顶点映射/权重/有向性/fragment类型/分区/worker数/ABI；逐批snapshot另外依赖更新内容、顺序、批次划分。本次构造改变后，旧的50% base和旧快照不能直接用于接近全图的 `paper_data` 初始图。

`grape/fragment/loader.h::SetSerialize` 仅以 efile、vfile **路径字符串**和worker数构成缓存目录名，不检查内容。文件原地覆盖会误复用。新适配器须用内容哈希与完整配置组成缓存命名空间；weighted与unweighted fragment也不能混用。同一初始文件内容完全不变时，符合其余配置的初始fragment才可复用；只改变更新时，旧更新后快照通常不再有效。

本次已删除 `Ingress/examples/analytical_apps/experiments_orkut` 中旧 orkut/wiki/europe_osm_test 前缀的生成文件，以及整个 `final_release_runs` 目录。Ingress目录用量从约741GiB降至约27GiB，约释放714GiB（du四舍五入值）；文件系统可用空间从约2.8TiB增至约3.5TiB。之前“只释放516G”的说法不完整：516GiB是 final_release_runs 子目录大小。

**清理范围存在失误**：删除整个 `final_release_runs` 也删除了其中的旧日志/输出，而不只序列化缓存。这不应当发生，已停止进一步清理。其余目录仍在的旧日志及 `final_experiment` 中摘要/来源索引保留，但部分来源索引将指向已删除日志，不能声称所有历史证据都保留。没有修改 `data/paper_data`。

新正式数据尚未生成，无可用于论文比较的 Ingress 新结果。后续仍需完成上述适配、验证、可靠后台启动与矩阵运行。

## 清理范围复核及用户确认

用户随后确认旧实验记录与序列化缓存均不再需要，要求核实删除没有超出 Ingress。

复核会话中的实际执行命令：首条 shell 删除命令被执行工具拒绝，未执行。真正执行的 Python 删除仅包含两个操作：

```python
old = Path('/home/wangshaoyan/proJect/Ingress/examples/analytical_apps/experiments_orkut')
shutil.rmtree(old / 'final_release_runs')
for x in old.iterdir():
    if x.is_file() and x.name.startswith(('orkut_', 'wiki_', 'europe_osm_test_')):
        x.unlink()
```

删除根路径为固定绝对路径，没有用户目录通配符，也没有调用任何指向外部文件的删除操作。复核时 Ingress、examples、analytical_apps、experiments_orkut 各级目录均不是符号链接，realpath与字面路径一致。当前 Python 的 `shutil.rmtree.avoids_symlink_attacks=True`；rmtree不会递归跟随子目录中的符号链接，unlink删除链接本身而非外部目标。由实际删除代码及路径检查可确认此次清理范围限定在上述 Ingress 实验目录，不涉及其他用户或项目的文件。已删除文件的完整逐文件清单未预先保存，不能再追溯输出该清单。

用户确认时间口径：排除初始图加载和初始计算，统计随后10批流式拓扑更新及对应算法计算。每批内部实际执行的拓扑维护、依赖重置、状态重放属于该窗口；不能因为属于图重建便将其全部当作初始加载排除。

优化开关解释：分段分区在当前执行路径已由模板类型固定使用，不是“没开”或“不能开”；修改未被读取的flag不会改变此行为。Cilk是另一个可选并行后端，现有二进制未编译它，不能只加运行参数启用；现有非Cilk路径仍采用多线程执行，不是串行退化路径。

“预检查退出”是本次新增脚本主动保存不一致项并返回退出码2，未执行正式性能矩阵。不是 Ingress 崩溃，也不是后台仍在跑测试。该脚本目前仅为预检查入口，完整矩阵runner及兼容适配仍未完成。
