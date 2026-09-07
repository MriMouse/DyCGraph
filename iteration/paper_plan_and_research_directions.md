# 论文规划与后续研究方向

**日期**：2026-09-04  
**基于**：I0–I11 全部实验日志、代码审计、CGgraph-V1.5 源码分析

---

## 第一部分：后续优化方向（均为论文级贡献）

### 方向 A：事务化 Mixed-Batch Topology Construction（I12，已验证语义但性能否决）

**问题**：当前系统对一个 mixed batch 执行两次 topology materialization——先删除、收敛到中间 fixed point，再插入、再次收敛。I11 的语义证明表明，外部可见状态只是最终 SSSP fixed point，删除后的中间图从不对外可见，因此这两次 materialization 和两次收敛是多余的。

**贡献内容**：
- 将 deletion 和 insertion 对 touched source 的修改合并为单次 source-level transaction（统一分组、一次 COW next chunk 构造最终拓扑）
- GPU 在旧 epoch 执行 deletion invalidation 的同时，CPU 并发构造最终 topology——这是系统内第一次合法的 CPU/GPU 重叠
- 唯一 epoch commit + 一次 device-local closure，消除中间 fixed point

**可证伪性**：I11 的 20,000 次随机 mixed-batch oracle 测试已经证明语义正确；I12 production 原型在 Wiki/Orkut/Twitter/FS correctness 上通过，但 Friendster 2-batch 仍比 I10 回退约 5%，因此性能 gate 失败。

**验收 gate（来自文档）**：Twitter 和 Friendster 的 paper_algorithm_ms 中位数均下降 ≥5%，至少一图 ≥10%；否则删除 I12 机制，回到 I10 基线。

**上界估算（I11，非预测）**：
- Twitter：结构覆盖区域 262 ms / 569 ms = 46%
- Friendster：1344 ms / 3989 ms = 34%

**路线决策（2026-09-05）**：不再把方向 A 拆成 I13/I14 继续优化，也不实现高 churn 阈值或 sequential fallback。事务、reverse compact 和 unified closure 保留为结构 artifact 与负结果；生产性能基线回到 I10。后续正向工作必须改变 repair 的算法复杂度或全量工作量，不能继续优化当前 COW relocation。

---

### 方向 B：高直径图的 GPU-Efficient Deletion Repair（新发现）

**问题**：当前 GPU deletion repair 是 Bellman-Ford 式——每轮扫描全部 affected incoming edges（dirty_partitions 始终等于 512，edge span 近似恒定）。对于社交图，受影响集很小（Twitter 每 batch 约 4k–6k 顶点），轮数极少（8–11 轮），问题不明显。但对于高直径路网（Europe OSM 99p），受影响集覆盖全图的 52%（约 2660 万顶点），需要约 7700 轮，总 edge-visits 达 4.4×10¹¹——算法上是 O(iters × E_affected)。

**实测数据**（I8 logs）：
- Europe 99p：10 batch paper time = 2,235,501 ms（37 分钟）；deletion repair 占 88%
- 每轮 throughput 约 2.21–2.56 M edges/ms（近似常数），说明是全量重扫而非 frontier-based
- 工作量比：GPU edge-visits / CPU Dijkstra ops = 4.35×10¹¹ / 1.38×10⁹ = **313x**
- 盈亏平衡条件：GPU/CPU 吞吐比约 77x（E4-R3-B 标定），313x >> 77x → **CPU Dijkstra 理论快 4.1x**

**贡献内容**：
- 识别两种 repair regime：低直径图（受影响集小、轮数少）适合 GPU BFS-style；高直径图（受影响集大、轮数多）可能适合 CPU Dijkstra
- 以 batch telemetry 和硬件标定驱动解析式 admission，在 GPU affected repair 与 CPU priority-queue/Dijkstra repair 之间选择
- 对高直径图实现 CPU priority-queue repair，替代当前 Bellman-Ford 全量重扫

**运行时判定约束**：selector 绝不读取数据集名称，也不使用“TW/FS 路径”或“EU/USA 路径”这样的硬编码。EU/USA 只是高直径路网的验证样本；TW/FS 只是低直径社交/web 图的验证样本。选择依据是当前 batch 的 `affected_vertices`、`affected_incoming_edges`、预测 repair rounds、frontier/heap work 以及 CPU/GPU transfer/setup 成本。建议成本模型为：

```text
gpu_cost = predicted_E_affected * predicted_rounds / gpu_scan_throughput
cpu_cost = predicted_E_affected * log2(max(affected_vertices, 2))
            / cpu_relax_throughput + transfer_cost + setup_cost
```

仅当 `cpu_cost * safety_margin < gpu_cost` 时选择 CPU Dijkstra，否则继续使用现有 GPU repair。首个 batch 用 bounded probe 或当前 affected seed 估计 rounds，后续 batch 继承并校正上一批 telemetry。这样才能证明是 workload-regime crossover，而不是数据集特例或固定阈值调参。

**注意**：这与前六代 CPU owner 实验的失败路线有本质区别——不是用 CPU 分担 GPU frontier-based 传播，而是用算法上更高效的 Dijkstra 替换一个已被证明算法上低效的 Bellman-Ford 实现。改变的是**工作复杂度**，不是 CPU/GPU 分工比例。

**前置条件**：首先修复 Europe 50p 的 correctness 问题（batch 0 出现 missing_tight_witnesses=1），建立可信的 baseline；再用至少一个独立 road graph（如 USA 类路网）检验 selector 是否跨数据集泛化。

---

### 方向 C：Hotness/Candidate 增量维护

**问题**：`compute_hot_vertices_sssp()` 每 batch 对全部 0..nnodes 顶点全量刷新 hotness 和 candidate，即使只有少量 touched source。I9 实测：Twitter 10 batch 这一阶段耗时 170 ms（占 w20 paper time 的 **30%**），Friendster 370 ms（9%）。

**贡献内容**：
- 维护 touched-source 的度数变化 delta，以增量方式更新 hotness 排序，而非全量 `comp_hotness + sort`
- 与 cache patch（F1-C0）同构：两者都是把"全量重建"改为"局部修补"

**约束**：I4 已经否决了一个语义不完备的 touched-only hotness 方案——新方案需要证明语义正确（特别是 eviction 判断和 GPU expand 计数的一致性）。这是方向 C 的主要技术挑战。

**上界**：Twitter 若该项降到接近零，paper time 可减少约 30%；Friendster 约 9%。

---

### 方向 D：更大 Batch Size 下的 Scalability

**问题**：当前主实验固定使用 100k mixed updates / batch。Friendster 1000k 和 Twitter 1000k 的数据集已于 Sep 3 生成（base 文件已就绪），但尚无任何实验。

**贡献内容**：
- 验证 source-local chunk store 和 epoch 机制在更大 batch 下的正确性和扩展性
- 如果 touched source 数量随 batch size 线性增长，mutation 并行化的收益应该更显著（每 source 的平均 work 相似，并行度可以更充分利用）
- 如果 batch size 增大导致受影响集扩大到超过 30% 顶点，可能触发方向 B 的 regime 切换

**前置条件**：I10 资源基线（GPU peak 9699/14409 MiB）需要确认在 1000k batch 下不溢出；Friendster 1000k 的 pinned memory 可能从当前 8.9 GB 增长到 ~89 GB。

---

### 方向 E：外部系统对照（I15，论文必须项）

**问题**：目前的性能数字都是内部对比（20 worker vs 1 worker，或 current vs C1 baseline）。要宣称"相对原系统的性能提升"，必须有外部对照。

**设计**：
- Baseline：原版 `C-GpuStreamGraph`（路径 `/home/wangshaoyan/proJect/CG/C-GpuStreamGraph`，已确认存在），使用 `--hybrid=1 --cache=2`
- 测试条件：相同 graph、相同 batch、相同 cache 配置，交错重复 ≥5 次，报 median

**注意**：10.9.4 节的早期对照（Twitter 10k/100k 慢 75–103%，Friendster 10k/100k 快 29–44%）是在 correctness 未完全闭合时的结果，不能用于论文。I15 必须先 correctness gate 全过，再做性能对照。

---

## 第二部分：论文组织结构

### 论文定位

**核心命题**：CPU 权威版本化拓扑与 GPU 增量闭包的协同——针对流式图 SSSP，通过将拓扑构造权威性赋予 CPU（source-local chunk store + epoch protocol）、将算法状态和传播权威性赋予 GPU，实现比纯 GPU 系统更低的 batch latency 和更好的 scalability。

**创新层次**（由稳到新排列）：
1. 算法：只修复 affected region + exact-source frontier（已有 TW -30% / FS -16% 论文数字）
2. 存储：CPU-authoritative source-local versioned topology，O(touched) 稀疏发布（已正式化）
3. 并行：source-local mutation 多核化，因果归因完整（I9 residual < 0.1%）
4. 流水线：事务化 final-state topology（I12，语义完成、性能否决，作为负结果/边界）
5. 适应：基于 regime 的 repair executor 选择（方向 B，下一条正向主线）

---

### 论文章节结构（建议）

#### 一、Introduction（约 1.5 页）

**核心论点序列**：

1. **动态图 SSSP 的挑战**：大规模图不断变化，每个 batch 包含混合的删除和插入；维护 SSSP 状态的核心困难是删除破坏了原有最短路树的单调性，需要找替代路径。

2. **GPU 方案的局限**：GPU 的高并行度适合图传播，但拓扑变化处理（邻接表更新、版本管理）是随机内存访问密集型操作，在 GPU 上效率低、显存占用高（D1 回收 74–1506 MiB 是一个有力数据点）。纯 GPU 系统（CGgraph、POEGA）在静态图或简单更新上有优势，但面临拓扑维护开销的瓶颈。

3. **CPU-GPU 协同的机会**：CPU 天然持有 host-side 拓扑权威性，其多核计算能力适合构造拓扑变化（source-local parallel mutation）；GPU 的 SIMD 并行适合在固定拓扑上跑传播闭包。将"拓扑构造"和"算法计算"分别交给最适合的硬件，是一个自然的分工。

4. **本文贡献概要**：CPU-authoritative source-local chunk store + epoch protocol，使 CPU 能以 O(touched sources) 构造拓扑更新并发布到 GPU，同时不阻塞 GPU 的传播工作；配合 affected-only GPU deletion repair 和 exact-source insertion frontier，形成完整的流式 SSSP 系统。

5. **负结果的学术价值**：系统性地否定了"CPU 分担 GPU 传播工作"的方向（五代机制，F1-C 给出可复现的定量下界），说明了 workload 规模是决定性因素，并给出了 workload crossover 边界分析。

**关键数字**（Introduction 末尾或贡献列表）：
- Affected-only GPU repair：Twitter/Friendster/Wiki batch time −30–35%
- CPU parallel mutation（20 worker）：Twitter −30%，Friendster −16%
- Cache touched-only patch：pipeline −96%，end-to-end −63%（注明 screening）
- CPU propagation owner 下界：TW 慢 22%，FS 慢 96%（负结果）

---

#### 二、Background and Motivation（约 2 页）

**§2.1 Streaming Graph Processing and Incremental SSSP**

- 流式图模型：multigraph，delete-before-add，multigraph occurrence 语义（文档已冻结）
- 增量 SSSP 的难点：删除破坏单调性，需要 affected region 识别和修复；插入只需单向松弛
- KickStarter/GraphBolt 作为 CPU-only incremental 基线（算法层的对立点）

**§2.2 GPU-Accelerated Streaming Graph**

- GPU 的优势：高带宽、大规模并行松弛
- GPU 的局限：拓扑变化需要频繁重组内存布局（PMA rebalance → 触发大范围 reallocation）；删除后 GPU 端全量 topology descriptor 导致显存浪费（对照 D1 数据）
- POEGA（OSDI'26）：最近的竞品，GPU-centric，无 CPU 版本化拓扑的并发构造；写作时正面对比

**§2.3 CPU-GPU Cooperative Graph Processing**

- CGgraph-V1.5 的机制（详细，供后文对比）：
  - 静态 degree-based 顶点重排，GPU resident = 高 degree prefix（一次性离线）
  - per-iteration frontier 按 degree prefix-sum 切分，CPU/GPU 并行松弛同一 frontier
  - 成立的三个前提：①工作量前提（协同轮有 2×10⁸ 活跃边）；②结构静止前提（图不变，预处理可复用）；③状态交换前提（每轮全量 SSSP state H2D/merge 可接受）
- 为什么 CGgraph 式协同在流式场景失效（§1.5 的论点，更正式地展开）：
  - 三个前提全部不成立：受影响集每 batch 仅 2.2×10⁴–2.24×10⁵ 入边，比静态协同小四个数量级；图结构每 batch 变化，比例文件失效；小 batch 的状态交换税不可摊薄

这一节为 §4（CPU 作为 propagation owner 的系统性否定）做铺垫，同时为 §5（CPU 作为拓扑构造者）建立对比框架。

---

#### 三、System Design：Data Organization（约 3 页）

> 你规划的"数据组织一章"，对应存储层架构

**§3.1 Overview and Design Goals**

整体架构图：update stream → CPU mutation layer（source-local chunk store）→ epoch publication → GPU topology descriptors → GPU SSSP state / propagation。突出三条原则：
1. CPU 对拓扑具有写权威性，GPU 对算法状态具有写权威性，两者不交叉
2. 更新发布的传输量与 touched source 数成正比，与全图规模无关
3. 每个 source 的 chunk 在物理存储上相互隔离，使 mutation 可以安全并行

**§3.2 Source-Local Chunk Store**

- 数据结构：per-source `{index, degree, slab_id, version}` descriptor + power-of-two chunk（pinned mapped memory）
- 与 PMA 的对比：PMA 修改一个 source 可能导致其他 source 的邻接表搬移；chunk store 修改互不影响
- 容量策略：power-of-two rounding，size-class free list，epoch-delayed reclaim
- 关键不变量（topology contract）：prepare 不修改 current descriptors；commit 是唯一可见性转换点；retire 后旧 block 直到 GPU reader quiescent 才回收

**§3.3 Parallel Source-Local Mutation**

- 两阶段协议：并行 prepare（deletion planning + final degree + expansion flag），串行 allocation preflight + epoch commit，并行 apply（compact in-place or COW rewrite），串行 retire
- 为什么 preflight 必须串行：需要原子性——整批要么全部成功，要么全部失败，不允许部分 mutation 后回滚
- Work-stealing 调度（kWorkGrain=16 source/task）：对幂律图的高 degree source 和低 degree source 有自然的负载均衡
- 性能归因（I9）：parallel prepare+apply 缩短 TW 264 ms / FS 759 ms，control overhead 仅 5.4/4.2 ms，残差 <0.1%

**§3.4 Sparse Topology Publication**

- 24-byte TopologyPatchRecord：只发布 touched sources 的 descriptor 变化，而非全图
- GPU 端 scatter：ScatterTopologyPatch + PatchOrInvalidateCachedAdjacency，通过 stream event 保证 publish-before-traverse
- 发布阶段耗时：10 batch 约 21.9 ms（Twitter）/ 18.4 ms（Friendster），与 worker 数无关（publication 串行）
- D1 回收结果：删除全量 device topology descriptor 后，Orkut/Wiki/Twitter/Friendster 分别回收 74/312/802/1506 MiB

**§3.5 Dynamic Reverse Index**

- Immutable sorted base CSC + batch-local signed count delta，CPU 端线性 merge 构造 incoming edges
- 用于 deletion repair 的 affected incoming edge 准备（B2/R2）
- 效果：Friendster affected incoming prepare+H2D+closure 从 81.3 ms 降到 11.7 ms

---

#### 四、System Design：Incremental Computation（约 3 页）

> 你规划的"数据计算一章"，对应算法层架构

**§4.1 Deletion Stage：Affected-Region Repair**

- Affected region identification：deletion 破坏 tight parent edge 的条件（multigraph occurrence 归零），BFS 传播影响闭包
- GPU affected-pull closure：只为 affected vertices 准备 incoming edges，sorted base + count delta merge；GPU pull-relax 到收敛
- 对比 CPU repair：CPU repair 需要全图状态 prepare + D2H，真正的 local closure 只占 18.5 ms，其余 >1000 ms 是税。GPU repair 后 TW/FS/Wiki batch time 降 30–35%
- B2/R2 的效果：affected incoming prepare 从全图规模压缩到 O(affected vertices)；Friendster 关键路径从 81.3 ms 降到 24.75 ms/batch

**§4.2 Insertion Stage：Exact-Source Frontier**

- 近似全点启动的代价：ExecutePolicy_All 每 batch 触发全图扫描，Twitter/Friendster/Wiki 中这部分占 add-compute 的 38%/88%/25%
- exact-source 语义：seed = 当前 source 有 finite value 的 added edges ∪ affected region 的 boundary recovery edges；GPU 只从确实发生变化的 source 扩展
- 修复 deletion 契约缺口：如果旧 parent edge 在最终多重图中 occurrence 不为零（例如删除了其中一条重复边），则旧依赖没有断裂，不需要重新找替代路径
- 效果：insertion closure 累计 TW 2.5 ms / FS 7.9 ms（占 paper time <0.5%）；partition_rebuilds=0，host_frontier_syncs=0

**§4.3 CPU-as-Propagation-Owner：Systematic Negation**（负结果节）

- 动机：CGgraph 成功地让 CPU 分担 GPU 传播工作，为什么在流式系统中失败？
- 五代机制摘要（B3 / E2-E3 / E4-R3 / F1-C）及每一代的核心量化结果
- F1-C 作为最严格的实验：offline replay，对 CPU 最有利的下界，TW 慢 22.4%，FS 慢 95.6%
- 根本原因：`可替代 GPU 关键路径毫秒数 < 跨设备状态交接与协议固定税`；workload 规模比 CGgraph 的协同阈值（2×10⁸ 活跃边）小四个数量级
- Crossover 边界：R-MAT（高 closure、无 cache，67M 顶点）CPU 快 41%，作为 workload boundary discussion
- 学术贡献：crossover replay 方法论——可复现的、对 CPU 有利的定量下界，可用于其他系统的类似分析

**§4.4 Cache-Aware Execution**

- touched-only cache patch（F1-C0）：未 grow 的 source 保持原位，grow 的 source 只追加到 cache tail，容量不足才回退到全量 compact
- 效果（Twitter screening）：cache pipeline 1096 ms → 43 ms（−96%），end-to-end 1618 ms → 595 ms（−63%）
- 注明：正式交错重复尚未完成，screening 结果作为 strong evidence

**§4.5 Unified Final-State Repair（I12，负结果与边界）**

I11 oracle 证明了 mixed batch 可以在最终图上统一恢复，不必让 deletion-only 中间图对外收敛；I12 实现了 GPU old-epoch invalidation、CPU final-topology COW prepare、单次 epoch commit/publication 和 unified exact-source closure。可是 Friendster 2-batch 仍比 I10 回退约 5%，新增成本主要来自高 churn source 的 COW/materialization 与 cache pipeline，而不是 publication。因此本文不把 I12 写成性能贡献，也不继续扩大其 production 状态空间；该节保留语义证明、实现边界和负结果，说明“语义上可行”不等于“在高 churn 图上值得部署”。

后续正向方向转向高直径 regime：当 GPU repeated affected scan 的预测工作量超过 CPU priority-queue/Dijkstra 的 `E_affected log V` 成本时，才改变 repair executor；这不是在低直径社交/web 图上恢复 CPU propagation owner。

---

#### 五、Evaluation（约 3 页）

**§5.1 Experimental Setup**
- 硬件：V100 16GB × 1（独占），Intel Xeon Gold 5218R 2×20 核，754GB RAM
- 数据集（表格）：6 个真实图，按边数排列，注明 50p base 和重映射
- 算法：动态 SSSP，mixed 100k updates × 10 batches，`paper_algorithm_ms` 指标定义
- Baselines：原版 GPU-only（`--hybrid=1 --cache=2`，I15 完成后），内部 1-worker baseline

**§5.2 Overall Performance**（主结果表）
- 各机制组合的 Twitter/Friendster 10 batch paper time
- 对比原版系统（I15 数据）

**§5.3 Component Analysis（消融实验）**

| 消融项 | TW delta | FS delta | 数据来源 |
|---|---|---|---|
| B2/R2 affected-only GPU repair | −30.8% | −32.6% | 正式实验 |
| E4-R2 sorted base/delta merge | — | −85.6%（prepare） | 正式实验 |
| E4-R1 exact-source closure | −97%（add compute） | −96%（add compute） | 正式实验 |
| D3 CPU source-local topology | +37.4% | +31.5% | 正式，5-repeat |
| I5–I10 parallel mutation（20w vs 1w） | −29.9% | −16.1% | 正式，3-repeat |
| F1-C0 cache touched-only patch | −63.3% | TBD | screening（需正式化） |
| I12 unified transaction（条件性） | TBD | TBD | 待实施 |

**§5.4 Critical Path Attribution**（I9 结果）
- topology_boundary vs paper time 的占比变化
- parallel prepare+apply 的因果归因（残差 <0.1%，structural_mismatches=0）

**§5.5 Resource Analysis**
- GPU memory：D1 回收 74–1506 MiB；I10 基线（9699/14409 MiB）
- CPU RSS / pinned memory（I10 数据）
- publication 开销：10 batch 约 21.9/18.4 ms，与 worker 数无关

**§5.6 Scalability（方向 D，条件性）**
- 1000k batch size 结果（若数据准备好）

**§5.7 Discussion：Workload Regime and Crossover**
- 六图 regime 对比表（paper time、affected、rounds、exact_sources、GPU propagation 占比）
- R-MAT crossover（41% CPU win 的条件：高 closure、无 cache、合成图）
- Europe OSM（高直径，52% 顶点受影响，repair 占 88%，current GPU 算法效率极低）
- 方向 B 的 motivation（若已实施，写成贡献；若未实施，写成 limitation and future work）

---

#### 六、Related Work（约 1 页）

| 类别 | 代表系统 | 与本文关系 |
|---|---|---|
| CPU-only 增量图 | KickStarter, GraphBolt, DZiG | 算法基线；本文 B2/R2 是其 affected-only 的 GPU 化 |
| GPU-only streaming | POEGA (OSDI'26) | 最近竞品；无 CPU 版本化拓扑并发；写作时正面对比 |
| Static CPU-GPU cooperative | CGgraph-V1.5 | 移植失败的前提分析（§4.3）；方法论对比 |
| GPU dynamic graph storage | GPMA, Hornet, faimGraph | 对立设计点：GPU 端 mutation 烧显存与 kernel 时间；D1 回收 1.5 GB 为反证 |
| CPU dynamic graph storage | RadixGraph (SIGMOD'26), RapidStore | 版本链 + 引用计数回收的参考实现；本文 epoch 协议与其概念相近但面向 GPU reader |
| Out-of-core GPU graph | Liberator | 正交（超显存分区，静态图） |

---

#### 七、Conclusion（约 0.5 页）

三段：
1. 系统性地否定了 CPU-GPU co-propagation 在流式增量图上的可行性，并给出了定量的 workload crossover 分析
2. 建立了 CPU-authoritative source-local versioned topology 的正确架构，取得了 TW −30% / FS −16% 的端到端收益
3. I11 的语义证明与 I12 事务性能负结果；后续工作聚焦高直径 regime 适应和语义完备的 hotness/candidate 增量维护

---

## 第三部分：近期写作优先级

### Introduction 写作要点

Introduction 的核心论述链需要在读者接受之前就回答：**为什么不是 CGgraph 直接移植**？这是审稿人会问的第一个问题。建议在第 3 段（motivation）中明确写出三个前提条件的破坏，而不是等到 §4.3 才解释。这样读者从一开始就知道本文的贡献空间在哪里。

数字密度：Introduction 不需要放太多数字，但以下三个数字建立可信度：①删除全量 device descriptor 回收 74–1506 MiB（说明 GPU 端拓扑维护的代价）；②parallel mutation 使 Twitter end-to-end −30%（说明 CPU 做拓扑的价值）；③CPU propagation owner 即使在最有利的下界也比 all-GPU 慢 22%/96%（说明否定结论的严格性）。

### Background 写作要点

CGgraph 机制的描述要足够精确，以便 §4.3 的对比有力。特别需要描述清楚：①`CG_ratio` 的标定方式（10 次完整跑，disk cache）；②协同阈值（2×10⁸ 活跃边）；③frontier sorted by ID → CPU/GPU split 是 degree prefix-sum 上的 upper_bound，而非任意切分。这三点都在 CGgraph-V1.5 源码中有直接对应。

### Method 章节写作要点

**数据组织章**（§3）的写作顺序建议：先写 §3.1 的整体架构图（建立读者的空间感），再写 §3.2 chunk store 的数据结构（最核心），然后 §3.3 mutation protocol（与 §3.2 紧密相连），最后 §3.4 publication 和 §3.5 reverse index（相对独立）。不要从最低层的数据结构开始写，容易让读者在细节中迷失。

**算法章**（§4）的关键挑战是 §4.3 的负结果节：如何将五代实验的失败写成一个有说服力的论点，而不是一堆零散的失败案例。建议用**剃刀原则**组织：五个独立机制、失败方向完全一致→最简单的解释→workload 规模的结构性质→crossover 条件→结论。F1-C 作为最后的、最严格的一次，放在最后，给出可复现下界。

---

## 附：已冻结的硬约束（写论文时不要违反）

1. **唯一性能指标**：`paper_algorithm_ms`（batch 级 `[P0-TIMER]` 求和），不用 kernel time、wall time、CPU busy time 或子项收益替代
2. **正式数字来源**：必须来自交错重复 ≥3 次的中位数；单次 screening 结果必须注明
3. **Europe 数据集说明**：I6/I7（50p，1639 ms）和 I8（99p，2235501 ms）是两个不同数据集，不可跨迭代比较；Europe 被移出性能 cohort（CPU mutation 贡献 <0.06%）
4. **负结果口径**：D3 Orkut 回退 +11.5%，Twitter delete 子项 +9.2%，均需如实报告
5. **R-MAT 结论限制**：只能作为 workload boundary discussion，不得写成 CPU owner 正面贡献
6. **F1-C0 cache patch**：只有 screening 结果，写论文时需补正式交错重复实验
