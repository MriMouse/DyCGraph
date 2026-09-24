# BFS 迁移：2026-09-21

## 实现范围

用户要求将当前 SSSP 迭代迁移到 `samples/hybrid_bfs`，保留性能机制，并且不能干扰后台 SSSP 实验。迁移前该目录四个文件与 `samples/hybrid_sssp` 完全一致，但 CMake 仍引用不存在的旧 BFS 文件名。

本次修复构建入口，生成 `hybrid_bfs.cu`、`hybrid_bfs_common.h`、`hybrid_bfs_host.cu`、`main.cu`，链接与 SSSP 相同的通信计量实现。BFS 的距离为有向无权跳数，所有输入边及更新边均按 1 处理，不读取输入权重作为距离成本。

共享 `AppBase::TraversalEdgeWeight` 默认保留原 `(src+dst)%128+1`，BFS 编译期特化为 1。六处 GPU push 路径、三种插入调度、更新边准备和实验 CPU owner 松弛都使用该策略。BFS 的 `DeletionEdgeWeight` 同样为 1，因此删除失效、普通修复和有序修复统一为 BFS 语义。BFS 应用中的阶段 Bellman 检查、父边见证和 host FIFO 参考也改为单位权重。不会通过全局宏改变 SSSP 的权重。

保留 chunk/reverse、regular/large/auto、publication merge、cache/hotness、block/thread/ordered 和阶段计时机制；不重新引入已否决的全局优化默认值，不在边遍历热路径添加运行时算法分支。普通 BFS 默认仍为 block；大直径 ordered 仅显式启用。BFS 初始 priority delta 为一跳，修复原复制代码用恒零 weight_sum 算 priority 的问题。负 batch 数、空图和 SSSP 专用 weighted I16 snapshot 明确拒绝，负 source 按帮助信息夹到 0。

应用参数改为 `bfs_max_batches`、`bfs_print_checksum`、`bfs_hotness_audit`。共享实验 CPU ownership 参数仍保留 `sssp_cpu_partition_capacity`、`sssp_cpu_domain_map` 旧名，默认关闭。用法见 [README](../../samples/hybrid_bfs/README.md)。

## 资源隔离与验证

后台 SSSP PID 807281 使用 GPU 0、CPU 0–19/40–59（NUMA 0）；本次独立构建到 `build-bfs`，CUDA 12.1，`-j2`、nice 15，CPU 24/25，NUMA 1 内存。测试使用 GPU 2、CPU 26/27 或 24/25、NUMA 1 内存、2 mutation workers、64 reverse shards。未更新 `build/`、后台冻结二进制或其启动环境，未发送任何停止信号。这里只说明采取的隔离措施，不声称已经测量证明共享主机的干扰严格为零。

- `hybrid_bfs` 与 `hybrid_sssp` 独立构建成功。
- `tests/bfs_dynamic_smoke.py`：2048 点有向图，含环、自环、竞争路径、断连与重连，三批删除/插入。更新文件故意使用 77/91 权重，CPU oracle 完全忽略它们。
- block+regular、ordered repair+ordered insertion+large、thread+large：共 18 阶段 checksum 与独立 FIFO BFS 相等；每个最终顶点距离逐项一致，每个可达非源顶点父边存在且恰好相差一跳；内置六阶段检查每次均 passed。
- SSSP 回归：使用现有 `i22_ordered_insertion_test.py` 的隔离副本，仅切换 GPU 2、2 workers 和独立 binary；三批六阶段独立 Dijkstra 与最终 checksum 全通过。共享策略未改变本次覆盖的 weighted SSSP 结果。
- `git diff --check` 通过。

验证记录：`logs/bfs_dev_20260921/smoke_v3/result.json`、三个模式日志、`sssp_regression/result.json`、`rebuild.log`。超过三次的后续验证采用后台独立进程启动，未建立持续轮询实验队列。当前这些测试均已结束。

首次配置的 FindCUDA 自动选择 CUDA 13，因其不支持 sm_70 编译失败；显式指定 CUDA 12.1 toolkit/nvcc 后修复。首次测试将 reverse shards 设为 4，被既有的 1/64 限制拒绝，已改为 64。第二次运行 block 校验成功，但下一项被前一进程残留利用率采样拒绝；脚本增加两秒冷却并重新检查空闲，第三次完整通过。未绕过占用检查。

## 性能结论及边界

本次保留已有优化机制、单位边权常量折叠和增量传播路径，没有为了 BFS 改成每批全图重算。三个模式的测试计时带 `--check=true`，图小且 regular/large 配置不同，不能拿它们作为模式排名或论文性能结果。

**尚未进行真实数据的大图 BFS 同语义基线配对，因此不宣称性能无回退或优于旧版 BFS，也不把 SSSP 已有的大直径收益转写为 BFS 收益。** 迁移前该目录本来不能按 CMake 构建，也不能把其 weighted SSSP 副本当成 BFS 性能基线。后续正式性能测量应在空闲资源上冻结同图、source、更新序列、缓存和 NUMA，关闭 correctness/diagnostics，比较完整 batch 时间与距离 checksum；普通/有序调度分别测量。CPU owner、sparse fused 等非默认路径本次没有单独 GPU 验收。
