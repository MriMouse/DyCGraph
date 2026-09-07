# C-GpuStreamGraph CPU-GPU 协同开发进展汇报

## 1. 总体结论

本项目的路线已经从“CPU 和 GPU 共同承担最短路传播”收敛为：**CPU 负责动态图拓扑构造，GPU 负责 SSSP 状态和增量传播**。

目前已经取得的核心优势不是让 CPU 多执行一部分最短路，而是把动态图更新从“GPU 端全局结构修改、全图状态准备和重复传播”改造成“CPU 端局部拓扑更新、GPU 端受影响区域修复和精确 source 传播”。这条路线已经在正确性、显存占用、拓扑发布开销和 Twitter/Friendster 的关键路径上取得稳定证据。

## 2. 为什么 CPU propagation owner 路线不能成立

CPU propagation owner 路线希望让 CPU 接管 deletion repair 或 insertion propagation 的一部分计算。该路线经过 fixed owner、图区域划分、持久 CPU 状态、异步双执行器和 SCC 子图回放等多种机制验证，结论始终一致：

- 动态更新后的受影响区域本身已经较小，CPU 能够替代的 GPU 传播工作不足以覆盖跨设备状态交接、版本管理和同步成本。
- fixed destination owner 不能保证 source traversal 和 vertex state 处于同一执行方，容易增加跨域通信，也不能稳定减少 GPU 扫描。
- 即使采用对 CPU 有利的离线成本下界，Twitter 仍慢约 `22.4%`，Friendster 仍慢约 `95.6%`。
- 静态 CGgraph 式协同依赖每轮数亿条活跃边和长期稳定的图结构；本项目每个动态图 batch 的修复工作通常只有数万到数十万条受影响入边，无法摊薄切分、同步和状态迁移成本。

因此，CPU 作为 SSSP propagation owner 已被否决。R-MAT 上出现的 CPU 优势只保留为 workload crossover 边界，不外推到真实图，也不进入生产路径。

## 3. 已取得优势的主要迭代

下面按研究问题和系统演进顺序列出已经形成实际价值的迭代。每项同时说明它做了什么、解决了什么问题，以及它为什么构成优势。

### 3.1 A：建立可解释的正确性和关键路径基线

早期首先把 deletion stage、insertion stage、GPU/CPU 传输、状态准备、partition rebuild 和 cache refresh 分开计时，并加入 Bellman、tight witness 和 checksum 检查。这个迭代解决了“总时间变慢但不知道慢在哪里”的问题，也证明 CPU 真正执行的最短路计算只占很小部分，主要成本来自全图准备、传输和重复扫描。

这一步没有直接带来性能优势，但它建立了后续所有判断的实验基础：后续优化必须降低 batch 级 `paper_algorithm_ms`，不能只优化一个 kernel 或一个 CPU 子项。

### 3.2 B1：将 deletion repair 从 CPU 转移到 GPU

删除一条 tight predecessor edge 后，受影响顶点需要重新寻找替代路径。B1 不再让 CPU 执行完整 repair，而是由 GPU 根据 affected vertices 的 incoming edges 做 affected pull-relax。

它解决了 CPU 修复吞吐不足和数据往返的问题。Wiki、Twitter、Friendster correctness 全部通过；相对原 CPU repair，完整 batch 时间分别下降约 `30.83%`、`34.92%` 和 `32.62%`。从此删除后的最短路修复确定由 GPU 承担。

### 3.3 B2/R2：affected-only deletion repair 和 sorted incoming merge

B1 仍存在全图状态复制、固定 512 个 partition 重建和过量 incoming 数据准备。B2 进一步维护 compact affected queue，只为真正受影响的 destination 物化 incoming edges；R2 将静态 incoming base 与本批 reverse delta 做排序合并，而不是每次重建完整反向图。

这个迭代的本质是把 deletion repair 的工作规模从全图规模压缩到 affected region 和其必要入边，减少了无关的 state gather、H2D 和 partition rebuild。三类真实图 correctness 通过；相对 B1，deletion stage 进一步下降约 `68.84% / 88.87% / 71.67%`，Friendster 的“入边准备 + 传输 + GPU 修复”约降至 `24.75 ms/batch`。

这形成了当前 GPU deletion repair 的基本算法优势：GPU 不再因为少量删除而重新处理整张图。

### 3.4 10.8--10.9：added-edge seed frontier 和 exact-source propagation

原 insertion 路径在每个 batch 中使用近似全点启动，导致大量顶点并没有真正受到新增边影响，却仍然被加入传播过程。该阶段把 insertion convergence 改为由新增边和实际变化顶点产生 seed frontier，并让 GPU 只扩展确实发生变化的 source。

最初的 direct added-edge seed 暴露出 deletion affected region 缺少外部 incoming replacement parent 的语义缺口。随后引入 dynamic reverse index、affected-region closure 和 deletion-stage Bellman gate，最终形成“affected boundary recovery + added-edge seed”的完整 seed 规则。

该迭代解决了两个问题：一是避免伪增量的全点 kickoff，二是保证删除和插入组合时不会因为缺少替代入边而得到错误距离。Wiki、Twitter、Friendster 的 deletion-stage 和 final Bellman 均通过；insertion closure 十批累计仅约 Wiki `5.6 ms`、Twitter `2.5 ms`、Friendster `7.9 ms`，说明 exact-source executor 已经把 insertion propagation 压缩到很小的规模。

### 3.5 C：CPU authoritative topology 和稀疏 GPU publication

原有 PMA 风格的全局连续布局使一个 source 的边更新可能引起其他 source 的 relocation，GPU 很难判断哪些结构仍然有效，因此更新容易扩大为全图或大范围重新发布。C 路线改为 source-local chunk：CPU 只修改发生变化的 source 邻接表，并向 GPU 发布 touched source 的 descriptor、版本和地址变化。

这个迭代的本质是把拓扑更新的影响范围从全局结构压缩为 `O(touched sources)`。未变化的 source 不需要重新发布，GPU 也不需要持有一份用于追踪全图 topology version 的大型辅助表。

### 3.6 D1：删除全量 GPU topology descriptor

D1 移除了按全部顶点维护的大型 device-side topology 辅助表，只保留 GPU 实际 traversal 所需的数据，并通过变化 source 的 descriptor 记录完成更新。

它解决了动态图场景中“为了少量更新而常驻全量元数据”的显存浪费，同时保持了拓扑访问语义。Orkut、Wiki、Twitter、Friendster 分别减少约 `74 / 312 / 802 / 1506 MiB` GPU 内存，正确性保持通过。

### 3.7 D2：降低 topology publication 等待

D2 预先分配 publication buffer，正常性能路径只发送一次紧凑更新，并将完整 topology audit 限制在 correctness 模式。这样避免了每次发布后立即执行不影响算法结果的同步和核对。

该迭代解决的是 CPU 更新和 GPU 可见性之间的固定等待税。拓扑发布阶段下降约 `93.6%--99.6%`，完整 batch 没有回退；它为后续 epoch/version publication 契约提供了基础。

### 3.8 D3：source-local topology mutation 优化

D3 对 CPU 端邻接表修改过程做了整批 preflight 和 source-local compact/rewrite：先确认整批更新能够执行，再一次性提交；同一 source 的删除、复制和插入集中处理，减少临时容器和重复扫描。

它解决了 topology mutation 本身的重复工作和异常状态风险，使 CPU 端拓扑构造成为可控的生产路径。相对 C1 的正式五次重复中位数，完整十批时间：Wiki 快 `5.7%`，Twitter 快 `37.4%`，Friendster 快 `31.5%`。Orkut 慢 `11.5%`，因此没有用数据集特例掩盖负结果。

### 3.9 F1-C0：touched-only cache patch

在 topology 已经按 source 局部更新后，旧 cache 路径仍会因为少量 touched source 失效而执行整批 eviction、compact 和 reload。F1-C0 将 cache refresh 改为 producer-native touched-only publication：未变化的 resident source 保持原位置，degree 增长的 source 只追加搬迁自身 adjacency；只有尾部容量不足时才回退到原有全量 compact/load。

它解决了“局部拓扑变化被缓存管理放大成整批 cache 重建”的实现税。Twitter 单次十批 screening 中，cache pipeline 从约 `1096 ms` 降至 `42.7 ms`，降低约 `96.1%`；完整 batch 从 `1618.5 ms` 降至 `594.7 ms`，降低约 `63.3%`。该端到端数字尚未完成正式交错重复，因此应作为强 screening 证据，不作为最终论文 speedup。

后续 cache delta allocator 原型因 Friendster 碎片和 allocator planning 回退而删除，当前只保留经过 correctness 验证的 touched-only patch、refresh gate 和安全 fallback。

### 3.10 I5：source-local mutation 多核化

I5 利用 source 之间天然隔离的特点，建立固定生命周期线程池，让不同 source 的 deletion planning、final-degree 计算和 source-local compact/rewrite 并行执行；allocation preflight、epoch commit、publication、retire/reclaim 仍保持串行，以保证资源和可见性契约简单明确。

它解决了 CPU topology mutation 中不同 source 之间本来可以并行、却被单线程顺序处理的问题，同时没有改变同一 source 的操作顺序。Twitter 两批实验中，mutation 时间从 `26.291 ms` 降至 `14.690 ms`，完整两批 timer 从 `103.215 ms` 降至 `90.106 ms`；Friendster correctness、Bellman 和 GPU/CPU hash 检查通过。

### 3.11 I8--I9：证明 mutation 收益来自关键路径，而非偶然调度

I8 使用交错重复实验确认 20-worker 相对 1-worker 的收益方向稳定：Twitter paper time 中位数下降 `29.9%`，Friendster 下降 `16.1%`；mutation 中位数分别下降 `73.9%` 和 `79.3%`。I9 又把 grouping、prepare、allocation、parallel apply、epoch commit、retire 和 publication 分开审计。

这两个迭代解决了科研汇报中的因果归因问题：收益不是把工作移出 timer，也不是 cache 状态偶然变化，而是来自 source-local prepare/apply 的并行缩短。Twitter topology boundary 约从 `440.357 ms` 降至 `170.748 ms`，Friendster 约从 `1560.680 ms` 降至 `798.121 ms`，残差分别为 `0.049%` 和 `0.067%`。

### 3.12 I10：CPU/GPU topology visibility 和资源契约封板

I10 将 source descriptor、arena、epoch、publication、retire/reclaim 和 GPU reader 可见性整理成一套不变量，并在测试中覆盖同源冲突、跨 source 更新、重复边、容量扩展、非法 epoch transition 和 arena 容量守恒。

它解决了 CPU authoritative topology 可能引入隐式全图副本、旧版本过早回收或 batch 间竞态的问题。Twitter/Friendster 的十批 correctness 和 final Bellman 全部通过，publication 次数、edge count、topology hash 一致，没有 stale version reject 或 GPU/CPU hash mismatch；同时冻结了后续实验必须使用的 CPU RSS、pinned memory 和 GPU peak 资源基线。

### 3.13 I11：最终态 repair 语义和统一 closure 模型

I11 证明 mixed batch 不需要对 deletion-only 中间图完整收敛。正确执行关系是：根据最终边多重性判断旧依赖是否真正断裂，CPU 构造最终 touched-source topology，GPU 在旧 epoch 上完成 invalidation，发布最终 topology 后再统一执行 boundary recovery 和 added-edge relaxation。

它解决了当前两阶段路径中“删除后先得到一个中间 fixed point，再重新处理插入”的重复结构。模型覆盖删除后重加、重复边、等长 predecessor、affected source 和不可达分量，并通过 full Dijkstra oracle 与固定种子的 `20,000` 次随机测试。I11 目前是已完成的语义和可证伪性验证，下一步才是将该模型接入生产代码。

## 4. 当前数据集规模排行

以下数据采用项目实际加载的输入文件规模，部分数据经过 `50p` 抽取、顶点重映射或对称扩展，不等同于原始公开数据集口径。

### 4.1 按点数排序

| 排名 | 数据集 | 实际点数 | 实际边数 | 说明 |
|---:|---|---:|---:|---|
| 1 | R-MAT FS-like | 67,108,864 | 805,000,000 | 合成图，scale 26 |
| 2 | Friendster | 65,608,366 | 903,040,059 | `50p` base，顶点已重映射 |
| 3 | Europe OSM | 50,912,018 | 107,028,226 | 当前 correctness 使用 symmetric-expanded 99% 输入 |
| 4 | Twitter | 34,956,270 | 196,289,923 | 顶点已重映射 |
| 5 | Wiki-Talk | 7,575,606 | 218,608,712 | `50p` base |
| 6 | Orkut | 3,072,406 | 58,592,541 | `50p` base |

### 4.2 按边数排序

| 排名 | 数据集 | 实际边数 | 实际点数 |
|---:|---|---:|---:|
| 1 | Friendster | 903,040,059 | 65,608,366 |
| 2 | R-MAT FS-like | 805,000,000 | 67,108,864 |
| 3 | Wiki-Talk | 218,608,712 | 7,575,606 |
| 4 | Twitter | 196,289,923 | 34,956,270 |
| 5 | Europe OSM | 107,028,226 | 50,912,018 |
| 6 | Orkut | 58,592,541 | 3,072,406 |

### 4.3 数据来源

- Friendster：`data/friendster_reid_stats.json`。
- Twitter：`data/twitter_reid_stats.json`。
- R-MAT：`data/rmat_fs_like_50p_100k.metadata.json`。
- Orkut、Wiki-Talk、Europe：`logs/large_six_dataset_20260824T170000Z/` 中实际加载日志的 `nedges` 和最大顶点 ID。
- 当前主实验通常使用每批 `100k` mixed updates，共 `10` 个 batch；上表统计的是 base graph，不是更新边数量。

## 5. 后续需要取得的进展

### I12：实现事务化 mixed-batch topology

将当前删除和插入的两次 topology materialization 合并为一次 source-level transaction：删除和插入统一分组，touched source 使用 copy-on-write next chunk，CPU 构造最终 topology，GPU 同时在旧 epoch 上执行 invalidation。

该阶段要解决的本质问题是当前系统仍然分别执行 deletion topology phase 和 addition topology phase，存在两次 source grouping、两次 materialization 和两种 reverse delta 处理。目标是一次 publication、一次 epoch commit 和一次最终 closure，同时保持额外空间只与 touched source 有关。

### I13：统一事务的 correctness 和资源封板

需要验证 current/next chunk 可见性、epoch fence、publication、reclaim、forward/reverse edge count、topology hash、final Bellman 和 tight witness。还要确认临时 COW 空间、CPU RSS、pinned memory 和 GPU peak 不超过 I10 基线和 touched-source 上界。

### I14：架构消融和关键路径验收

在同一生产实现上比较 fused transaction 的串行版本、加入 CPU/GPU overlap 的版本和完整 unified final-state closure。目标是把性能收益归因到一次 final-topology materialization、旧 epoch invalidation 与 CPU prepare 重叠，以及删除中间 fixed point 的消除。

验收目标是 Twitter 和 Friendster 的完整 `paper_algorithm_ms` 中位数均下降至少 `5%`，且至少一张图下降 `10%`；如果只降低 CPU 子项而完整 batch 不下降，则不能将该机制包装成论文贡献。

### I15：完成外部 GPU-only 对照

在相同 graph、batch、cache 和 source 配置下，对比最终事务化 CPU-GPU 版本与原版 GPU-only 系统。两边必须先通过 correctness，再进行交错性能重复。

只有外部对照也取得稳定优势，才能宣称相对原系统的整体性能提升；否则应准确表述为当前系统内部的拓扑构造和 GPU 增量修复优势。

## 6. 最终汇报口径

项目已经取得的最稳定优势可以概括为三层：

1. **算法层**：只修复 affected region，使用 exact-source frontier，避免 deletion 和 insertion 的全图传播。
2. **系统层**：CPU 权威构造 source-local topology，GPU 只接收 touched-source 的稀疏 publication，并通过 cache patch 避免整批缓存重建。
3. **并发与一致性层**：source-local mutation 已多核化，epoch、descriptor version、publication 和 reclaim 契约已经封板；I11 进一步证明可以在最终 topology 上执行一次统一 repair。

因此，下一阶段的研究重点不是继续扩大 CPU propagation owner，而是验证源粒度事务化 topology construction 能否与 GPU old-epoch invalidation 合法重叠，并通过一次 final-state closure 进一步降低完整 mixed-batch 的关键路径。
