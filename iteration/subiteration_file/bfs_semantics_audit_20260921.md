# BFS 计算、增量算子与输出语义复核（2026-09-21）

用户要求再次检查 `samples/hybrid_bfs` 是否初始计算、增量计算和输出均为 BFS。本次重新阅读该目录全部源码，并沿共享 framework/driver/push/ordered repair 的实际调用链核对，不仅依据文件名或历史 checksum 作结论。

## 调用链结论

| 环节 | 实际语义 |
|---|---|
| main / CMake | `Skeleton<hybrid_bfs::App>` → `HybridBFS()` → `Engine<..., hybrid_bfs::BFS, ...>`；构建引用当前 BFS 三个 `.cu` 文件 |
| 初始状态 | 源点 buffer=0，其他点 UINT32_MAX；node value 从 INF 开始，由 combine 发布距离 |
| 初始传播 / 普通 push | BFS `AccumulateBuffer` 跳过 INF，用 `buffer+1` 做 atomicMin，不使用传入权重累加 |
| 插入边种子 | framework 将 `added_edges_h[i].w` 设置为 BFS 的 `TraversalEdgeWeight=1`；消费 `edge.w` 的种子 kernel 因此同样加 1 |
| 增量传播 | BFS `AccumulateBuffer_add` 为 `incoming_value_curr+1`；block/thread/ordered closure 调用 BFS 权重策略及松弛方法 |
| 删除失效传播 | `reset_del_edges` 及两个删除 push functor 用 BFS `DeletionEdgeWeight=1` 判断 tight dependency |
| 普通删除修复 | `GpuAffectedPullRelax` 按 `dist[src]+DeletionEdgeWeight(src,dst)` 求最小，BFS 即 +1 |
| 路网删除修复 | `i17_ordered::Run<AppImplDeviceObject>` 的初始化、松弛和父边恢复均使用同一 BFS 单位权重 |
| 实验 CPU owner | 插入 closure 用 TraversalEdgeWeight，删除 repair 用 DeletionEdgeWeight，静态追踪均为 1；本次未启用非默认 owner 做运行验收 |
| 校验 | 单位权 Bellman 不等式和 `dist[parent]+1==dist[node]`；host FIFO 参考同样每边 +1 |
| 实际 `--output` | `GatherValue/Parent/Buffer` 从 GPU 状态拷回，逐行输出 `vertex hop_distance parent buffer`；第二列为最终 BFS 跳数，INF 为十进制 4294967295 |

共享的 `compute_hot_vertices_sssp` → `comp_hotness_sssp` 只根据可达标记和四窗访问计数生成缓存热度分数，不计算 weighted distance，也不修改距离。`sum_value` 是调度统计回调。带 `sssp_` 名的 ownership flags 为共享旧接口。API 默认仍保留 SSSP 权重，但 BFS 明确覆盖 traversal/deletion 两个静态策略；I16 weighted snapshot 被 BFS 入口拒绝。

算法使用共享引擎的异步单位权松弛与增量修复，计算结果是有向无权 BFS 最少跳数；不是要求每一轮必须严格层同步的串行 FIFO 实现。普通/large 改变拓扑维护方式，路网模式改变调度方式，不改变 BFS 距离定义。

## 本次发现并修正

1. 继承自 SSSP 副本的阶段校验计算了父边见证错误数，但此前 `success/passed` 只看距离。现将父边错误计入删除阶段和 batch 整体失败，并为 final（含 0-batch 初始结果）增加父边检查。只影响 `check=true` 校验路径。
2. 第四输出列取自 `host_buffer`，此前变量/README 称 `delta` 不准确；现改名为 `buffers`，文档明确为内部候选距离 buffer。保留四列兼容性，BFS 答案始终是第二列。
3. 输出文件创建/写入/关闭失败此前没有影响返回状态；现报错并返回失败。
4. 删除 BFS 文件中已过时的 weighted priority 公式注释和废弃输出示例。未修改生产松弛热路径或 SSSP 源码。

## 明确区分 BFS / SSSP 的测试

新增 `tests/bfs_semantics_test.py`，核心图包含两条到顶点 127 的路径：

- `0→100→127`：2 条边，输入权重为 1000、1000。
- `0→1→2→127`：3 条边，输入权重为 1、1、1。

独立 FIFO BFS 答案为 **2**；独立 Dijkstra 按文件权重计算为 **3**，按原 SSSP `(u+v)%128+1` 计算为 **8**。测试使用 `--weight_num=0`，使 loader 真正解析文件第三列，避免单位权加载选项掩盖错误；更新文件使用 777/999 权重。

初始-only（`bfs_max_batches=0`）实际输出行为 `127 2 100 2`。随后在普通、large、路网+large 三模式各执行五批：空 batch 验初始、仅删除短路边、仅插入直达边、删除所有到达路径、恢复短路边。目标点依次为 2→3→1→INF→2。三模式共 **30 个删除/插入阶段** checksum 与独立 BFS 一致；四次运行的全部 256 个输出距离逐点相等，可达非源顶点父边全部存在且相差一跳，新增严格父边校验全部 passed。

日志：`logs/bfs_semantics_audit_20260921/semantics/`，`result.json` 保存预期与目标输出，四份 `.out` 是实际输出文件。独立构建日志在同目录上层 `build.log`。此外再次运行原 2048 点三模式动态 smoke，用于覆盖此次父边失败判定修正后的回归，结果见 `regression/result.json`。

所有 GPU 验证后台串行运行于空闲 GPU 2，CPU 24/25、NUMA 1、nice 15、ionice idle、2 workers，未修改后台 SSSP 的 binary/环境/CPU 配置。没有重跑性能矩阵。非默认 sparse/fused 和 CPU owner 组合未做本次运行验证，不把上述结果写成所有实验开关的穷尽证明。
