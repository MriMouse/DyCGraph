# 2026-09-13 完整性能矩阵复核与后续实验建议

本次只分析已有实验与代码，不启动 GPU 实验、不修改生产实现。数据截至 `logs/performance_matrix_20260912/status.json` 的 `2026-09-13T07:20:54Z`。完整数值见 [性能、阶段与模式大表](performance_matrix_20260912_analysis/tables.md)，可筛选的 [主表 CSV](performance_matrix_20260912_analysis/matrix.csv)、[阶段 CSV](performance_matrix_20260912_analysis/stages.csv)、[逐批 CSV](performance_matrix_20260912_analysis/batches.csv)、[探测 CSV](performance_matrix_20260912_analysis/probes.csv)。生成入口为 `scripts/analyze_performance_matrix_20260912.py`。

## 1. 实验完成了，但跨系统加速结论没有通过

190 项任务中 188 项通过运行器判据，2 项失败。细分为 28 pilot、132 主性能运行（22 配置 × 两侧 × 三次）、22 当前侧两批 correctness、8 单因素模式探测（6 成功、2 失败）。22 组主对比全部 `checksum_mismatch`，所以 **本轮有效的跨系统加速比是 0 组，而非 188 组有效性能结果**。

主表仍列出 `original/current` 的诊断耗时比，供观察成本趋势；`validated_speedup` 列保持空白。不得计算论文总体几何平均加速、胜率，或以这些比值证明方法优于原版。原始 comparison/report 不改写、不解除正确性拦截。

口径：三次独立进程中，各次所有 batch 的 `total_batch` 求和，再取中位数；它含更新、修复、插入、缓存维护及完成同步，不含初始化、初次 cache、文件读取和检查。主 cohort 十批，`*_scaling` 两批；两条线不能直接混用合计耗时，即便除以批数也不能消除底图、源点和历史状态差异。全部主配置 cache=2；OK 1000k、EU/USA 1k 缺文件而跳过。

主配置由每 cohort 的两批有限 pilot 冻结：current/original hybrid 分别为 OK 0/1、FS 0/2、TW 0/2、EU 0/1、USA 2/1、FS_scaling 0/1、TW_scaling 0/1。EU/USA current 开 ordered；1000k/10000k current 为 reverse64，其余 reverse1；current mutation workers=20。原版不是未经修改的 upstream，而是留档的本地公平性副本。

## 2. 指纹问题：已证实的事实与尚待定位的原因

- 当前侧全部 22 配置的三次主性能运行，最终共同指纹各自一致；原版有 10 配置出现重复间不一致：EU 10k/1000k，USA 100k/1000k，FS 10k/100k/1000k，FS_scaling 1000k/10000k，TW_scaling 10000k。稳定是必要观测，不是正确性证明；原版的不稳定也不能靠选最快一次或取中位数消除。
- 两侧共同指纹确实都用有限距离的 `sum(distance[i]*(i+1)) mod 2^64` 和 reachable。current 的补丁新增 `[COMPARE-FINAL]`，比较的是该值，不能把其另一个 FNV 风格 `distance_checksum` 混进来解释差异。
- reachable 也存在实质差异。例如 FS_scaling 10000k repeat0 原版/current 为 54,226,172/54,224,561；TW_scaling 10000k 为 23,184,661/23,164,304。不是只差 parent 平局选择。其他一些配置 reachable 相同而距离指纹不同。
- 当前侧 22 项两批 Bellman/existential tight witness 检查通过，仅覆盖当前侧最初两批。它既不认证原版，也不覆盖十批主线的后八批；相对各自内部 topology 检查通过，也不能单独证明两侧的 topology 与规范一致。stored-parent 仍是独立诊断。

代码提供了值得优先排查的具体语义差异，但目前不能宣判为全部 mismatch 的根因：

1. current `TopologyReplayModel` 明确先删除、再添加，每次删除一个 occurrence；current source-local mutation 分阶段执行。原版 `update_tree_add` 中却先 `add_edge_pr` 再 `del_edge_pr`。同边增删、重复边和不存在的删除会使顺序语义重要，需先检查实际流是否触发，不能仅凭代码差异认定本轮最终拓扑一定不同。
2. 原版 `csr_graph.cuh::del_edge` 删除并左移后没有 `break`，循环右界仍取删除前 degree。对重复邻接，其行为不等同于 current 的单 occurrence 契约；用极小 CPU 邻接例子即可先验证，无需重跑大图。
3. 原版十组结果非确定，提示仍需定位 initial SSSP、删除失效传播、插入松弛或 cache 可见性中的并发/状态问题。现有终态指纹无法判断首次分歧阶段；“自然收敛”只说明停止条件满足，不能替代最短路正确性。

建议首先对 OK 小档做 initial → delete-only → batch-final 的双侧 topology multiset digest 与 distance 对照：initial 已不同先查初始化；topology 不同先查更新契约；同拓扑距离不同再查 SSSP。每次记录最早不同顶点、邻接和 tight witness。小图用独立 CPU Dijkstra/重算作裁决，真实大图只追踪触发源和最早分歧。若需修原版，保留原版原始结果与新修正版身份、补丁及二进制指纹，不能悄悄覆盖基线。

## 3. 性能反映的三个机制问题

### 3.1 路网：删除优化把矛盾转移到了插入

以总时间中位数对应的完整运行计算阶段占比：EU 10k/100k/1000k 插入占 17.3%/39.0%/85.2%，USA 对应 23.6%/40.3%/77.6%。EU 1000k 当前十批 1189.302 s，插入 converge 本身约 1005.964 s；USA 十批 411.025 s，converge 约 313.422 s。相应插入扫描计数合计约 1370.69 亿/758.94 亿条边，local waves 合计 71,827/39,166。计数是重复处理量，不是独立边数。

这直接支持 B6 的研究方向：exact-source 已消除全图 seed/rebuild 和 host frontier 同步，**但精确的初始工作集不保证传播过程中不会反复改进同一顶点**。源码 `[E4-R1-CLOSURE]` 明确 host_frontier_syncs=0，因此不能把问题笼统归为 CPU 每轮等待，更不能仅继续缩小 seed 或增加 mutation workers。

后续先量化成功 relax、独立变化顶点、重复 processed sources/edges、frontier 宽度，测试 GPU 有序插入候选能否以较少重复工作抵消排序/桶管理成本。删除 ordered 的 affected 局部图闭包不能直接当插入闭包：插入改善会越出原 affected 集，必须在最终图传播到自然 quiescence。保留全成本与正确性，delta=128 的权重假设仍需明确。

路网小档仍以删除为主，故不能宣布删除优化结束。EU 1000k 的 repair incoming topology 准备约 69.864 s，ordered 二次准备约 70.782 s，而 ordered 算法 closure 约 12.622 s；USA 对应 36.562/37.199/4.959 s。`ordered_gpu_repair.cuh::Run` 每次构造 `local(nodes)` 全图映射，按 incoming 再计数/前缀和/转置为 outgoing，并分配复制临时数组。这是准备成本的新候选，而不是继续单独压 kernel 的依据。

注意层级：外层 `[B2-GPU-REPAIR] closure_ms` 已含 ordered prepare/closure/publish 及返回时释放，不能再将这些内层数值与它相加。EU/USA 即使把整个删除阶段免费化，1000k 的理论整批加速上界也只有约 1.17x/1.29x（其他阶段不变），说明 B6 应升为首要性能实验。

### 3.2 社交图大批：不能用路网插入方案统一解释

FS_scaling 10000k 的两批当前 18.920 s，删除/插入/缓存为 61.1%/37.0%/1.9%；TW_scaling 为 23.991 s，69.8%/30.0%/0.2%。但两图插入 converge 分别只有 86.605/81.435 ms，约占整批 0.46%/0.34%，插入 CPU mutation 字段约 4.832/5.321 s。这是 topology 更新与准备问题，不是长传播插入问题。

现有 reverse64 仅把哈希容器准备按 destination shard 分配给 workers；并未消除 effective delta copy/sort/group、source mutation preflight、提交和 repair incoming 构建。当前 `DynamicReverseIndex::Prepare` 仍有复制、排序和多段准备，`Commit` 仍顺序遍历 pending。源码和日志不能支持“开64分片就完成大批路径优化”。

建议 B5 下一步先拆清 source grouping、mutation preflight、reverse slots/sort/commit 和 repair incoming，消除被计入父级 timer 的重复计数，再按最大可删除成本选一种原型。连续 PMA/topology rebuild 仍可保留为条件候选，但 `--large_batch` 当前只打印 backend 未接入，不能把本轮当作该候选已验收，也不宜在没有成本上界前实现整套新后端。

### 3.3 小批：固定缓存维护成本成为下限

FS 1k/10k 当前缓存相关阶段占 97.2%/85.6%，TW 1k/10k 为 63.4%/44.4%。这解释了为什么继续加快很小的 propagation 未必显著改善整批。FS 1k 即使删除和插入都免费，按该运行也只能再快约 1.03x。

可以新增小规模 cache 成本画像：候选不变/变化、是否触发 refresh、churn 大小、hotness 到期批。先分别测 hotness/candidate 与 eviction/compact/load 的可避免部分。已有 I4-R 与 I15 CPU 索引负结果继续有效，不能因为出现缓存瓶颈就恢复被否决的 CPU treap 或 resident-delta 实现；任何新算法必须保持当前候选/刷新语义并计入事件维护开销。

## 4. 模式边界、失败与容量结论

同二进制单因素探测中，成功项最终共同指纹均与 repeat0 默认路径一致：

| 图与档位 | ordered 配对加速 | reverse64 配对加速 | 解释 |
|---|---:|---:|---|
| FS 10k | 失败 | 1.047x | 分片小收益仅是单次线索 |
| FS 100k | 失败 | 1.399x | 分片正向证据较强，仍不称重复验证完成 |
| TW 10k | 0.387x | 0.951x | ordered 约慢 2.58 倍；分片也未受益 |
| TW 100k | 1.091x | 1.094x | 单次约9%差异，小于默认主重复约23.9%的极差/中位数，证据不足以冻结推荐 |

FS 100k 默认配对运行是 3871.212 ms，而主表中位数为 3805.951 ms；不能混用分母。FS 100k reverse slots 在默认 repeat0 十批约 1005.73 ms，说明分片有可解释的成本目标；历史同底图两批曾负收益，与本轮十批正收益不矛盾，cohort 和累积 reverse 状态不同。I17-C 应加入“批历史、累计 delta destinations/records、容器增长”的维度，不能只按名义 k/batch 设阈值。

两项 FS ordered 原始日志分别完成 batch0、batch0–3 后，在下一批抛 `std::runtime_error: invalid configuration argument` 并以134退出。现有分类 `incomplete_or_duplicate_batch_timers` 只是解析层后果，**不是 OOM 证据，也不是已证实的算法错误位置**。需为该路径增加 kernel/调用点和 CUDA 错误定位，核查空工作量、launch 参数、此前异步错误等；最短失败前缀分别是2批和5批。特别是 FS 100k 只检查前两批会漏掉第5批的故障。

因此 I17-C 需要先有“能完成/空间可承受”的前置判据，再讨论速度预测。不能从两次失败推出 FS 永远不适用 ordered，更不能把失败项从边界表省去。

FS_scaling 10000k 本轮 cache=2 的三次性能与两批 correctness 都成功，旧记录的 OOM 不能再写成当前配置必现的容量边界。中位数配置 CSV 同时记录三次的最大采样峰值与 RSS；repeat0 GPU 采样约14710 MiB、RSS约57.8 GiB，仍需考虑瞬时峰值。此次成功不等于已定位/修复旧 OOM：应对照两个冻结二进制和执行期显存分配生命周期，不能臆断其原因。当前侧 `framework.cuh`、`ordered_gpu_repair.cuh`、`dynamic_reverse_index.h`、`source_local_chunk_store.h` 与本轮冻结副本逐字节一致，因此上述代码分析直接对应本轮。

## 5. 建议调整后的短实验队列（尚未启动）

| 优先级 | 子任务 | 最小范围与裁决 |
|---|---|---|
| P0 | 双侧语义与 correctness 分歧定位 | 先 CPU 重复边/同边增删案例；再 OK 小档 initial/删除/最终状态的双侧分阶段检查，定位首次分歧。修复后只补受影响的代表配置，不直接重跑22组。 |
| P0 | FS ordered 失败定位 | 加精确调用点错误证据；10k两批、100k五批为已知最短失败前缀上限。修复后覆盖触发条件并校验距离/队列。与基线分歧定位独立，不用全矩阵验证。 |
| P1 / B6 | 路网有序插入 | 优先 EU/USA 1000k同状态两批；100k作规模对照，必要时仅挑一组。先测重复工作上界，再一个 GPU 插入候选。完整 batch 不改善即否决。 |
| P1 / B5 | 社交图 topology/reverse 准备 | FS/TW scaling 1000k、10000k已有日志先做成本拆分；仅对胜出子项实施单因素候选。需要1/64配对时补同图同档，不能跨100k→1000k归因于分片。 |
| P2 / B1 补项 | ordered 准备规模 | 在 EU/USA 删除仍占主要部分的档位，比较复用映射/索引或准备合并的完整 service；计入跨批维护和空间，不默认恢复曾失败的 cursor 复用。 |
| P2 新增 | 小批缓存下限 | FS 1k/10k、TW一个代表档，先画像已有十批；观察到可避免成本后再提不同于已否决方案的候选。 |
| P2 / I17-C | 手动选择的预测验证 | 保留人工开关；记录 repair占比、affected incoming、实际扫描放大、frontier宽度、完整准备及空间，再加批历史/delta增长。ordered iterations 是桶循环，不能与 pull rounds 当成同一量直接阈值比较。 |
| I18 重定义 | 已接入原型的健壮性与成本验收 | ordered已由 `CG_ORDERED_REPAIR=1` 进入生产调用链；剩余是失败路径、共存空间、完整交接和人工适用边界，不再列作“尚未实现接入”。默认pull保留。 |

本轮本身不是 EU/USA ordered 对当前 pull 的新消融：两侧整个系统不同，且最终结果不匹配；已有 I17-B6 同二进制 pull/ordered 匹配结果仍作为独立证据保存。新矩阵增强的是瓶颈画像与边界问题，不能偷换基线来扩大 ordered 的收益主张。

研究主线建议调整为：**CPU 承担局部拓扑更新和发布，GPU 根据传播工作特征处理修复/插入；收益由受影响工作量、重复传播、准备成本及批历史共同决定。** 这轮没有支持恢复 CPU propagation owner 或自动 dispatcher 的新证据。保持短定向、单因素、必要 correctness；长任务按现有单卡资源保护规则后台执行并提供状态文件，不恢复旧全量稳定性队列。
