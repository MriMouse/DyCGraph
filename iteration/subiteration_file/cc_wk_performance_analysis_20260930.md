# WK CC 性能分析（2026-09-30，修复 OOM 后的 directed 版本）

## 状态与范围

按用户要求暂停本轮实验：controller 449129、active TW/1k/current/r1 子进程 529945 均 SIGSTOP。暂停时 WK 六次 current 实验均已完成。未恢复实验，未改算法或计时数据。暂停记录位于 paper/evaluation/raw/cc_pr_20260928/pause_wk_analysis_20260930.json。恢复前应归档并重启未完成的 TW 尝试，避免暂停时间污染进程 wall time/timeout。

数据只取本轮修复后 current 与保留的 original。阶段统计写入同目录 wk_cc_analysis_20260930.json。下文 1k 数据来自两个 repeat 共 20 个 batch；SSSP/BFS 对照来自 sssp_bfs_20260927。已核验当前工作区引用的五个关键源文件与本轮冻结源码的 SHA256 相同。

## 结论

失速的主因是删除依赖范围和修复执行方式不匹配：CC 的等标签依赖使删除失效传播覆盖巨大的旧标签区域，随后 generic incoming pull 每轮扫描全部 affected 入边。不是通用性能组件全部漏接，也不是本轮 OOM 修复让 WK 退回零拷贝。已有分组 mutation、合并 publication、严格成功事件驱动的插入 frontier、cache refresh gate 都有实际执行证据；但它们无法消除删除修复中的近全图工作量。

## 量化证据

WK/1k 每 batch 平均（ms）：

| 阶段 | 耗时 | 占 batch 总耗时 |
|---|---:|---:|
| 整个 batch | 5314.514 | 100% |
| 删除阶段（包含以下 repair 子项） | 5305.278 | 99.826% |
| GPU pull closure | 3117.518 | 58.660% |
| host incoming 拓扑物化 | 1243.992 | 23.407% |
| incoming H2D | 441.216 | 8.302% |
| 插入阶段 | 1.725 | 0.032% |
| hotness + candidate | 7.505 | 0.141% |

子项不能再次与删除总项相加；closure/topology/H2D 三项以外的删除开销包括失效传播、affected D2H/分区统计、finalize 等，不能全部归为某一个未单独计时的函数。

每 batch 删除 500 条记录就产生约 8,063,618 个 affected 顶点、436,775,328 条 incoming 边，相当于初始 437,212,424 条边的 99.90%。26–38 轮 pull，平均 33.35 轮。按 logged incoming_edges × iterations 计算，每 batch 约 145.66 亿次入边循环访问（算法循环次数推算，不是硬件流量计数）。每 batch 重传约 1.812 GB 拓扑。全部 60 个 WK batch 的 mapped_bytes 都为 0，4 GiB budget 下拓扑驻留 device。

WK 的 1k / 10k / 100k 更新规模下 affected 都约 806 万，incoming 都约 4.36 亿；这是近固定的大范围重算，不是随少量更新而增长的局部修复。OK/1k 本轮 20 个 batch 均 affected=0，跳过了该昂贵路径，因此 OK 的优势不能外推到 WK。

## 与 SSSP/BFS 对照

相同 WK/1k，按两个 repeat 的每 batch 均值：

| 算法 | affected 顶点 | incoming 边 | pull 轮次 | closure ms |
|---|---:|---:|---:|---:|
| SSSP | 36.65 | 2131.40 | 3.55 | 0.124 |
| BFS | 19.05 | 646.05 | 3.20 | 0.100 |
| CC | 8063618.10 | 436775327.50 | 33.35 | 3117.518 |

三者 benchmark 使用相同 CG_MUTATION_WORKERS=20、CG_REVERSE_SHARDS=64、CG_ORDERED_REPAIR=0、CG_BATCH_MAINTENANCE=regular、CG_MERGE_PUBLICATION_SOURCES=1。关闭 ordered repair 不是 CC 独有遗漏。共享执行器在小 affected 上很便宜，在 CC 巨大 affected 上成本完全不同。PR 属于另一种更新传播语义，PR 领先不能证明 CC 的删除依赖也会保持稀疏。

## 源码定位

1. samples/hybrid_cc/hybrid_cc.cu:69 的 IsDeletionDependency 采用 src != dst && source == destination && destination < dst，不采用 parent/parent_tight 来限制失效传播。reset_del_edges（include/framework/variants/driver.cuh:400 附近）和 PushFunctor 的删除传播都调用该规则。它保证零成本环不靠彼此维持旧标签，但会保守地失效大量标签实际上可能仍有效的顶点。当前日志没有逐阶段真实 changed-label 数，不能把 affected 数误称为实际标签变化数。
2. include/framework/framework.cuh:4128 RunGpuAffectedRepair 每批调用 reverse-index MaterializeIncoming，随后 Upload。复用分配容量不等于复用拓扑内容，因此仍然每批物化/复制约全图的 incoming。
3. framework.cuh:4292 附近的 do/while 每轮传入同一个完整 affected 列表，直到 changed==0。GpuAffectedPullRelax（:170）逐 affected 顶点遍历其 incoming row，warp 协同已启用；但没有下一轮活跃 frontier 来跳过稳定顶点/边。其参数是单独 incoming CSR，不经过 forward hot-cache 的 chunk push 路径。不能说 GPU 没有 cache；准确说现有 forward hot-cache 优化不服务这个主要 closure。
4. framework.cuh:3820 CollectDeletionAffectedVertices 在 D2H 后串行对每个 affected 做 upper_bound 分区统计，806 万顶点时也有额外 O(A log SEGMENT) CPU 工作。这是次级优化项，当前没有专门计时，不能声称独占 residual。
5. grouped mutation、I21 merge=1 publication、E4-R1 closure（例如首 batch 仅 4 个源/18 条边）、F1 cache refresh gate 均在日志中出现，说明通用插入组件已经接入。WK/1k 的 cache refresh=0 是无需刷新，不是缓存关闭。
6. UseCcUnionRepair（framework.cuh:4068）被 kComponentLabels=false 挡住。CC 当前只设置 kVertexSeeds=true；旧 union/sampled repair 确实没有走到。但这些路径针对对称无向邻接，当前任务是原始有向图的 minimum reachable label；不能通过开启旧开关直接恢复。反例 0->1 与 2->1：有向标签为 [0,0,2]，无向 union 会变为 [0,0,0]。

## origin 的比较边界

original_src/samples/hybrid_cc/hybrid_cc.cu 的删除算子只在 parent==src 时失效。双方当前执行的失效工作量不同；original 不会像 current 那样沿所有等标签依赖泛洪。原版没有同粒度 affected 计数，不能量化其实际失效顶点数量。

现有 P0 timer 两边均包围删除、插入和缓存维护，不能把差距解释为原版完全不计删除。原版 HybridCC 最后直接 return true，本轮 check=false；日志 Overall: Test passed 不是独立动态标签 oracle。current 的 timing 也未运行逐阶段 oracle。因此目前能确认时延差距，不能只凭这些日志断言原版在 WK 上错误，或断言双方逐阶段结果已验证一致。旧的对称图审核结论不能替代当前 directed WK 的正确性检查。

## 后续实现优先级（尚未实施）

1. 先在独立诊断中量化 affected 中真正发生标签变化的比例，并比较删除前后及插入后的 label oracle；为有向零成本环、桥删除、批量割集、平行边建立保留旧标签的有效证据。不能简单改回 parent-only，也不能仅统计等标签入度（环可相互支撑旧标签）。
2. 建立有根、无循环依赖的 directed label 支持证据，或批删除后的边界可达性验证；仅重置确实失去根支持的区域。这样才有机会恢复与更新范围相符的增量成本。
3. 改造大 affected 的执行路径：在保证最新删除 descriptor 与 cache 可见性协议下，使用方向正确的边界 seed + 活跃 push/worklist，复用 grouped publication、cache/chunk 和成功事件调度；避免稳定边反复参与 pull。若暂时保留 incoming，优先增量维护/复用，避免每批 near-full materialization/H2D。性能收益需测量，不能仅凭设计承诺超越 origin。
4. 清理 affected 分区统计等次级线性开销。仅调 workers/cache/ordered 开关不足以消除上亿边乘几十轮的工作量；ordered repair 可作为隔离对照，但也不会自动缩小 affected 或消除拓扑物化。

当前仅暂停与分析，未修改算法；纸面实验保持暂停。
