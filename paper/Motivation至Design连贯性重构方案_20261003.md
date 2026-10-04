# Motivation → Design 连贯性重构方案（写作蓝图）

日期：2026-10-03
对象：`paper/Out_of_Memory_GPU_Streaming_Graph_Processing/chapters/` 中的 `background.tex`（§Motivation）、`design.tex`，以及需要同步对齐的 `introduction.tex` / `abstract.tex`
依据：现稿；`iteration/当前系统创新主线凝练与真实性核对_20260917.md`；当前代码（`framework.cuh`、`csr_graph.cuh`、`cache_refresh_gate.h`、`hybrid_sssp.cu`）；原版 Grapin 仓库 `7ffcb29`；范文 Grapin (PVLDB'25) 与 GASgraph。

> 本文件只规划“怎么改、为什么这样改”，不直接改论文。后续由作者或 AI 按第 4–6 节逐段改写，并用第 9 节的清单自查。

---

## 0. 一句话主线（全文所有段落都应能回溯到这句话）

**流式图更新在拓扑上和计算上都是局部的，但现有 CPU–GPU 协同的 out-of-memory 系统在两处把这种局部性丢掉了：图组织把局部修改放大成跨 source 的搬移和全量 GPU 视图维护；增量计算因 GPU 拿不到受影响顶点的前驱，只能把局部失效放大成全图重新激活。CoIncGraph 让持有权威拓扑的 CPU 提供 GPU 难以低成本获得的两样东西：按 source 粒度的有效变更，以及受影响顶点的入边，从而在维护和计算两侧都把工作限制在变化区域内。**

英文版（可直接作为 Motivation 小结或 Design 开头的 thesis）：

> Streaming updates are local both in topology and in computation, yet an out-of-memory CPU–GPU pipeline loses both forms of locality: the graph layout amplifies a local change into cross-source relocation and graph-wide GPU view maintenance, and the incremental engine, lacking access to predecessors on the GPU, amplifies a local invalidation into graph-wide reactivation. CoIncGraph restores both forms of locality by letting the CPU, which owns the topology, supply what the GPU cannot cheaply obtain: source-granular effective changes and the incoming adjacency of affected vertices.

这句话同时解决了你说的“②协同 CPU–GPU 不太知道怎么说”：**CPU 协同的意义不是分摊算力，而是补上 GPU 恢复局部性所缺的数据**。CPU 本来就维护拓扑、处理每一条更新，在主存里维护反向索引不占显存；给定受影响集合 A 后，抽取 A 的入边是一个小规模、易并行的主机端任务。这样，“CPU–GPU 协同”和“紧凑工作列表”就成了同一个故事，不再是两个并列卖点。

---

## 1. 审稿视角：现稿的主要问题

按严重程度排序。

### 1.1 Motivation 和 Design 讲的不是同一个系统（最严重）

- `background.tex:35`（§CPU–GPU cooperative incremental execution）写的是“小活动集 GPU 摊不平 launch 开销、大活动集 CPU 吞吐不够，所以要按计算需求、数据位置、通信开销做 work distribution”。这描述的是**已经退休的 CPU owner / 动态分工路线**（核对文档 N01–N12）。当前 Design 里没有任何按活动集大小在 CPU/GPU 之间分派传播任务的机制。审稿人读完会期待一个调度器，到 Design 却找不到，会直接判定“motivation 与 design 不匹配”。
- `background.tex:33`（§Graph representation and data access）的论点是“粗粒度传输会搬无用数据”。这是 Subway/Grapin 已经解决的问题（zero-copy、热子图），不是我们的切入点。我们的切入点是**更新导致的搬移放大和 GPU 视图维护放大**。
- 结论：Motivation 的两个小节需要整体重写，不是润色。

### 1.2 “局部性”这一核心概念没有被定义，术语漂移

现稿中出现了 topological locality、update locality、dynamic-update locality、locality of dynamic graph updates 四种说法，含义不统一。审稿人无法判断这是一个观察还是几个观察。
→ 需要在 Motivation 开头**一次性定义** update locality，并拆成两个面（见 §2）：topology locality 和 computation locality，分别对应 Design 的两部分。

### 1.3 Background 承担了 Motivation 的论证

`background.tex:14` 的 PMA 段已经在论证“局部修改被放大成大量索引变化，并波及 GPU descriptor、reverse index、cache”。这其实是 O1 的核心论据，却放在 Background；Motivation 里反而只有泛泛的“tension”。
→ Background 只中性地介绍 CSR/PMA 的结构，“放大”的论证和数据移到 Motivation O1。

### 1.4 缺少量化证据（与范文差距最大的一点）

Grapin 用 Table 1（冗余访问量）、Table 2（页迁移放大）支撑每个 challenge；GASgraph 用 Fig. 2（expansion/rebalance 是平均更新时间的 65–139×）支撑 PMA 的问题。现稿 Motivation 没有任何数字。
→ 需要补 1 个图 + 1 个表的 motivation 实验（见 §7）。

### 1.5 Design 过于流程化，创新点被淹没

- §5.1/5.2 按 1→6 步骤叙述，读者要读到 `design.tex:129` 才知道“为什么先完成删除修复”，这恰恰是整个增量计算部分的核心洞察。核心洞察应放在小节开头，步骤只负责展开。
- “GPU 缓存精细更新”只在 `design.tex:86` 用半句话带过，`design.tex:88` 的 refresh gate 也只有一句。这是你提到漏掉的点，应升格为一个独立的段落/小节，并在 O1 中有对应的动机。
- `design.tex:135`（step 4 publishing）与 §4.3 内容重复。

### 1.6 三条贡献与“两部分 Design”的结构冲突

Intro 写三个 design（第三个是 workload-specific optimizations），Design overview 写“两部分 + 另外的优化”，你的构想是两部分。Challenge 3（`introduction.tex:20`）写的是“局部性本身不能消除 workload 相关开销”，和主线是并列关系，削弱了主线。
→ 建议：ordered propagation 并入增量计算部分（作为 compact worklist 之后的“剩余低效”），shared batch preparation 并入 unified change view（作为大批量下的实现）。Motivation 只保留两个观察，Intro 保留两个 challenge。

### 1.7 与代码不符或证据不足的表述（必须改）

| 位置 | 现稿表述 | 问题 |
|---|---|---|
| `abstract.tex:6` | “improves concurrency by overlapping CPU preparation of affected incoming adjacency with GPU deletion repair” | 当前 `update_tree_del` 中 `del_edge_pr`、`MaterializeIncoming` 与 GPU 失效、修复是**串行**执行的，没有 overlap 线程。删去 overlap/concurrency，改为“division of labor”。 |
| `introduction.tex:17` | “large CPU--GPU data-transfer overhead … greatly reducing … CPU--GPU transfer time” | 核对文档 §三：通信审计的 zero-copy 物理流量尚未闭合，只有显式 memcpy payload 证据。在补齐测量前，用 “adjacency reads / host-memory requests / edges examined” 表述，不要直接说 PCIe 传输时间。 |
| `introduction.tex:17` | “the insertion phase must conservatively add all vertices … to search widely” | 原因没讲清楚。真正的原因是：恢复一个失效顶点需要它未受影响的前驱重新推送，而定位这些前驱需要入边视图，GPU 端没有。见 §4.3。 |
| `design.tex:102,129,141` | `[Efficient Graph Data Access ...]` | 占位符，改为 `\cite{2025-Grapin}`。另外要写成 “Grapin's released implementation”，因为 Grapin **论文**说 iterative calculation 从 result correction 产生的 active vertices 开始，全点激活是**原仓库实现**的行为（`update_tree_add` → `RebuildWorklist_AllVertices`）。不加区分的话，审稿人或原作者可以直接反驳。 |
| `design.tex:86-88` | cache 段 | 不能写成 Grapin 每批丢弃整个缓存：原论文明确保留未变化的 chunk。准确说法是：原实现中 touched source 的缓存被失效（`reset_pr_del_edges`），且 evict→compact→load 维护链**每批无条件执行**（原 `hybrid_sssp.cu:266-270`）。 |

---

## 2. 统一的故事骨架：一个主题、两个观察、两部分设计

```
                 Update locality（定义：一个批次只改少量 source 的出边，只让少量结果失效）
                         │
        ┌────────────────┴────────────────┐
  O1 拓扑局部性在图维护中丢失          O2 计算局部性在增量计算中丢失
  (CSR/PMA 共享数组 → 搬移放大          (删除修复需要前驱 → GPU 无入边
   → GPU descriptor 全量重载              → 推迟到插入阶段全点激活
   → GPU cache 失效 + 每批维护链          → 每轮扫描分区重建 worklist)
   → 多视图各自重复解析请求)
        │                                   │
  需求 R1：按 source 隔离搬移，            需求 R2：删除修复与插入传播解耦，
  一份有效变更驱动所有视图                  CPU 提供 A 的入边，全程紧凑 worklist
        │                                   │
  D1 Source-isolated graph organization    D2 Decoupled CPU–GPU incremental computation
   ├ source-isolated blocks (不变量)         ├ 关键洞察 + 正确性论证（放最前）
   ├ unified change view (+大批量共享准备)   ├ compact invalidation → A
   ├ reverse index (base+delta) ──────────→ ├ CPU 物化 I(A) + GPU pull 修复
   └ selective GPU publication               ├ 插入：只从改善的终点启动，单 cooperative kernel
      ├ descriptor patch 24|S|               └ ordered propagation（大直径图的剩余低效）
      └ cache 精细更新 + refresh gate
```

关键的“桥”：**D1 中的 reverse index 是 D2 删除修复的前提**。写 D1 时要预告（“this view later supplies predecessors for deletion repair, §3.2”），写 D2 时要回指。这样两部分就不是并列的两个模块，而是有依赖关系的整体。

对仗关系（可以在 Design overview 用一句话点明，读者会很受益）：
- 删除侧：GPU 缺少入边 → CPU 提供 → **pull**-based repair over I(A)
- 插入侧：GPU 已有出边（descriptor + zero-copy/cache）→ **push**-based propagation from improved vertices

> “在 GPU 缺少数据的地方由 CPU 补充并 pull，在 GPU 已有数据的地方直接 push。”

---

## 3. 术语统一表（全文强制统一）

| 统一使用 | 不再使用 | 说明 |
|---|---|---|
| streaming graph | dynamic graph（指本系统处理对象时） | 引用他人工作时可保留其原称；snapshot-based evolving graph 是另一类，不要混用 |
| update locality；分为 topology locality / computation locality | topological locality、dynamic-update locality 等 | 在 Motivation 首段一次性定义 |
| source（边的起点）、changed source、$S=S^-\cup S^+$ | touched source、updated source、modified source 混用 | “changed” 只指 effective change 实际修改了邻接的 source |
| effective change / effective edge-change record | actual change、real change | 与 update request 严格区分 |
| outgoing adjacency / adjacency block | neighbor list、adjacency list、chunk 混用 | “chunk”只留给 Grapin 的 GPU cache chunk，避免和我们的 block 混淆 |
| reverse index（结构名）；incoming adjacency / predecessors（内容） | predecessor view、incoming view、incoming lists、precursor 混用 | `design.tex:104` 的 precursor 删掉；I(A) 叫 “the incoming adjacency of A” |
| adjacency descriptor（GPU 端，记录位置+degree） | GPU index、GPU adjacency index、descriptor record 混用 | 首次出现定义一次 |
| cached adjacency / hot-subgraph cache | resident adjacency、cache payload | 沿用 Grapin 的 hot subgraph 叫法，并注明是 Grapin 的机制 |
| affected vertices $A$ | marked vertices、invalidated vertices 混用 | “invalidate” 作动词，A 作名词 |
| worklist | work list | 全文统一（现稿 design.tex 两种都有） |
| result $r(v)$（通用）；SSSP 示例中再写 $d(v)$ | distance、shortest edge 等作为通用名 | 与 `论文小点记录.md` 的要求一致 |
| deletion repair / insertion propagation | deletion recovery、insertion repair、insertion processing 混用 | `design.tex:129,137` 中的 “insertion repair” 改为 insertion propagation |
| publication（拓扑变更对 GPU 可见的过程） | publishing、reload | reload 只用来描述 Grapin 的全量 `ReloadAllocator` |

章节交叉引用一律用 `\ref`，删除硬编码的 “Section 4.2 / 4.3 / 5.3”（`design.tex:113,135,151`）。

---

## 4. Motivation 逐段规划（替换 `background.tex:29-35`）

篇幅建议：约 1 页（IEEE 双栏），由 4 段正文、1 个 motivation 图和 1 个小表组成。写法参照 Grapin §2：先给事实和数据，再说明“为什么现有方法解决不了”，最后落到一句需求。

### 4.1 P0：CPU–GPU 分工与 update locality（1 段）

目的：交代系统前提，并定义贯穿全文的“局部性”。

要点顺序：
1. CPU：主存容量大，能容纳完整的图和辅助结构，但内存带宽和并行度有限；GPU：带宽高、并行度高，但显存有限。
2. OOM 的标准做法（Grapin、EMOGI、Subway）：拓扑放在主存，结果和计算放在 GPU，GPU 通过 zero-copy 或 hot-subgraph cache 访问邻接。每一次跨 PCIe 的邻接访问都比显存访问昂贵得多。**因此一个批次的开销取决于：必须被修改的数据有多少，以及必须被读取的邻接有多少。**
3. 定义 update locality：一个批次只修改少量 source 的出边（topology locality），且只有依赖于被修改边的结果可能改变（computation locality）。可以给一个数字，比如 100K 边批次相对 |V| 和 |E| 的占比，或 |A|/|V|。
4. 过渡句：“Ideally, both maintenance and computation costs should scale with this locality. We observe that existing designs lose it at two points.”

英文关键句：
> Since the GPU accesses host-resident adjacency over PCIe, the cost of a batch is governed by how much data must be modified and how much adjacency must be read. Streaming updates exhibit *update locality*: a batch modifies the outgoing adjacency of only a small set of sources (*topology locality*), and only results that depend on modified edges may change (*computation locality*).

注意：不要在这里批评 CPU-only 和 GPU-only 系统的细节。Intro 已经做过，这里只需一句交代分工。

### 4.2 O1：拓扑局部性在图维护中丢失（1 段 + 图的左半部分）

标题建议：`\subsubsection{Observation 1: Graph maintenance breaks topology locality}`

逻辑链（每一步一句，形成因果链，不要并列堆砌）：
1. **为什么用紧凑布局**：CSR/PMA 把每个 source 的邻接连续存放，GPU 可以用合并的 zero-copy 请求读取，这也是 Grapin 采用 PMA 的原因。
2. **代价**：共享数组的插入需要 shift；空间不足会触发 rebalance 或 expansion，搬动**未被更新**的 source 的邻接（引 GASgraph 的数字，或用我们自己测的 relocated sources / requested sources）。
3. **异构系统中放大会继续扩散**（这是我们独有的视角，要重点写）。搬移让被搬 source 的 GPU descriptor 失效；由于事先无法知道哪些 source 被搬动，只能**全量重载 V+1 个 descriptor**（Grapin 实现中的 `ReloadAllocator`）。仅把 touched source 的 descriptor 稀疏传输是**不安全**的，因为被搬动的 source 并不在请求里。这句话是 sparse publication 必须以 source isolation 为前提的论据，一定要写。
4. **GPU cache 也被波及**：被修改 source 的 cached adjacency 被失效，hot-subgraph 的 evict→compact→load 维护链每批执行一次，即使热集合基本没变。可以给 E4 的热集合跨批相似度数据。注意措辞：Grapin 保留未变 chunk，我们指出的是“维护链每批无条件执行”和“修改即失效”。
5. **多视图重复解析**：出边、反向索引、descriptor、cache 四个视图各自根据原始请求推导变化；不存在的删除请求在每个视图都被重复检查。（这一点较弱，一句话即可，作为 unified change view 的引子。）
6. **需求 R1**（段末一句，斜体）：
> *This calls for a graph organization that keeps each source's adjacency contiguous for coalesced GPU access, yet bounds relocation to changed sources, so that every graph view — host adjacency, reverse index, GPU descriptors, and cached adjacency — can be maintained at source granularity.*

### 4.3 O2：计算局部性在增量计算中丢失（1 段 + 图的右半部分）

标题建议：`\subsubsection{Observation 2: Incremental computation breaks computation locality}`

这是全文最需要讲清楚的一段，因为它解释了为什么需要 CPU 协同。逻辑链：
1. **DM 增量计算（Grapin）**：删除使依赖它的顶点集合 A 失效，需要重新计算；插入只可能让少数终点变好。
2. **关键困难**：失效顶点只能通过它**剩余的入边**恢复，而提供替代路径的前驱往往**未受影响、本身不活跃**。在 toy 例子中，删除 (u,v) 后，v 可以由 x→v 恢复，但 x 不在任何 worklist 中。GPU 引擎按出边 push（descriptor 只描述出边），它**无法定位 A 的前驱**。
3. **后果**：Grapin 的实现把恢复推迟到插入阶段，先同时应用删除和插入，**激活全部顶点**重新 push，之后每轮扫描所有分区的顶点标记重建 worklist。删除修复和插入传播被耦合在一起，工作量正比于 |V| 和全图邻接，而不是 |A| 和变化边数。（要写明 “Grapin's released implementation”，见 §1.7。）给 E3 数据：初始活动集 |V| 与 |A|、插入种子数的对比，第一轮读取的边数，worklist 重建时间占比。
4. **洞察：缺的数据恰好是 CPU 拥有的**。CPU 维护权威拓扑，并处理每一条更新；在主存中维护反向索引不占显存；给定 A 后，抽取 I(A) 是规模正比于 |A| 及其入边、易于并行的主机端任务。而在 Grapin 的执行模型中，CPU 主要负责应用更新。
5. **解耦的收益**：一旦在 G^{-E} 上完成删除修复，所有结果对 G^{-E} 都正确，插入传播只需从被新增边改善的终点启动。这是“精确启动”成立的前提（核对文档主线二已说明：直接用新增边启动而不先完成恢复，会漏掉来自外部顶点的替代路径，这是开发中真实遇到过的失败，可以作为 insight 的佐证）。
6. **需求 R2**（斜体）：
> *This calls for decoupling deletion repair from insertion propagation, with the CPU supplying the incoming adjacency of affected vertices, and for keeping worklists compact throughout so that work scales with the affected region rather than with the graph.*
7. （可选，一句）为 ordered propagation 埋伏笔：“Even with compact worklists, a vertex may be activated repeatedly by successively better results in large-diameter graphs (§3.2.4).”

### 4.4 P-summary：设计原则（2–3 句，可并入 O2 段末或单独成段）

> These observations lead to two design principles. **(P1)** Graph changes should be represented and propagated at source granularity across all graph views. **(P2)** Incremental work should be bounded by the affected region, with the CPU supplying the dependency data that the GPU cannot cheaply obtain. CoIncGraph realizes P1 through a source-isolated graph organization (§3.1) and P2 through decoupled CPU–GPU incremental computation (§3.2).

这段是 Motivation 和 Design 之间的“接口”，Design overview 第一句就回指 P1/P2。

### 4.5 Motivation 图设计（替换或拆分现有 `fig:increment-compute`）

建议一个 `figure*` 或单栏图，分左右两部分：
- (a) O1：一个批次中 requested sources、PMA relocated sources、reloaded descriptors 三者的数量对比（柱状图，对数轴），旁边配一个小的 PMA 搬移示意（可从现 `fig:increment-compute(c)` 挪过来）。
- (b) O2：toy 图示意：删除 (u,v)，v 失效，不活跃前驱 x，所以只能全点激活；配上 E3 的 |A|、|V| 与插入种子数对比。

现在 Background 中的 `fig:increment-compute` 的 (a)(b)(d) 是增量计算的通用示意，可以保留在 Background；(c) PMA 部分移到 Motivation。

---

## 5. Background 的配套调整（`background.tex`）

- `background.tex:14` PMA 段：保留结构描述（gaps、density、rebalance、expansion），删除“amplify … heterogeneous system … GPU descriptors … cached adjacency”这类论证句，移到 O1。改后约减少 40%。
- `background.tex:16-17` 增量计算段：补一句 push/pull 背景，为 O2 铺垫：“Restoring an invalidated result requires examining its remaining incoming edges, whereas propagating an improvement examines outgoing edges.”
- `background.tex:19` CPU–GPU 段：删除 “coordinating work distribution” 这一暗示动态分工的说法。改为介绍 Grapin 模型（主存拓扑、GPU 计算、zero-copy、hot-subgraph cache），并**明确这些是 Grapin 的机制、本文沿用**。这样在 Design 中使用 cache 和 zero-copy 时，归属已经交代清楚。
- 背景里“已有工作的缺点”不要写，统一放到 Motivation，避免两处重复。

---

## 6. Design 逐节规划（`design.tex`）

### 6.0 通用写法：每个小节开头用“四句式”，取代流程式开头

1. **Problem**（回指 O1/O2 的具体现象，一句）
2. **Key idea**（一句，可斜体，是本小节的创新点）
3. **Mechanism**（展开，可以按步骤写，这里允许流程化）
4. **Guarantee / Cost**（得到什么不变量或复杂度，以及诚实交代的代价）

现稿多数小节缺第 2 句，并把第 4 句的 guarantee 埋在中间。改写时优先补这两句。

### 6.1 §3 Overview（替换 `design.tex:6`）

结构：
1. 回指 P1/P2（一句）。
2. **CPU/GPU 分工**（一句话讲清楚，审稿人最关心）：CPU 维护权威拓扑、反向索引、unified change view，并物化 I(A)；GPU 保存结果，执行失效、修复、传播，维护 descriptor 和 hot-subgraph cache。
3. 一个批次的 6 步流水线（对应 Fig.1 / Fig.3 的编号），每步一句并标注由哪个小节负责。
4. 一句话点出 D1→D2 的依赖关系（reverse index 支撑删除修复）和 pull/push 的对仗。
5. 删除“In addition, workload-specific optimizations …”这句，或改为“§3.2.4 further addresses …”。

### 6.2 §3.1 Source-Isolated Graph Organization（对应 O1、P1）

小节开头四句式示例：
> Problem: shared-array layouts relocate unchanged sources, forcing graph-wide descriptor reloads and per-batch cache maintenance (O1). Key idea: *we make source the unit of storage, change description, and GPU publication, so that maintenance cost follows the set of changed sources rather than the graph size.*

#### 3.1.1 Source-isolated adjacency blocks
- 突出**不变量**，而不是分配过程：“An unchanged source never changes address; hence its descriptor and cached adjacency remain valid.” 后面所有稀疏机制都依赖这个不变量，应以加粗或单独一句强调。
- 和 O1 第 3 点呼应：正因为这个不变量，只发布 changed source 才是安全的。
- 代价（保留现稿 `design.tex:29` 的诚实说明）：扩容时复制整个列表，预留空间和延迟回收带来内存开销。
- 不要宣称“首次让邻接连续”，原 PMA 已经按 source 连续存放；新意在于**跨 source 的更新隔离和发布契约**。

#### 3.1.2 Unified change view
- Problem：四个视图各自解析请求（O1 第 5 点）。Key idea：outgoing-adjacency preparation 一次性产生 effective edge-change records 和 changed-source lists，作为其他视图的唯一输入。
- 现稿 `design.tex:52` 的 [a,a,b] 例子很好，保留。
- **把 Shared Batch Preparation（`design.tex:233-234`）并入这里**，作为一段 “Scaling to large batches”：同一份 per-source 元数据在 allocation、mutation、reverse-index 维护和 publication 之间复用，source 顺序复用，省去再次排序。它在逻辑上就是 unified change view 在大批量下的实现，而不是一个独立的 workload 优化。

#### 3.1.3 Reverse index（建议从 “Coordinated View Maintenance” 中拆出独立成段）
- base sorted list + signed delta，查询时合并（现稿 `design.tex:84` 内容）。
- **必须加一句桥接**：“This index is what allows the CPU to supply the incoming adjacency of affected vertices during deletion repair (§3.2.2) without scanning outgoing adjacency.” 这是 D1 和 D2 之间最重要的连接句，现稿缺失。

#### 3.1.4 Selective GPU publication（descriptor + cache 精细更新，补上你漏掉的点）

分两段写：

**(a) Sparse descriptor publication**：$S=S^-\cup S^+$，每个 source 一条 24-byte record，流量为 $24|S|$ 而不是 $O(|V|)$。与 Grapin 的 `ReloadAllocator` 全量重载对比。不安全反例已在 O1 交代，这里只需回指。

**(b) Fine-grained cache maintenance（新增，独立成段）**。按四句式写：
- Problem：Grapin 实现中，被修改 source 的 cached adjacency 被失效，且 evict→compact→load 维护链每批执行，即使下一批需要的热集合与当前一致（O1 第 4 点）。
- Key idea：*把 cache 修复并入拓扑发布：changed source 若仍在 cache 中，就随 descriptor 一起就地修补其 cached adjacency；只有当热集合真正变化时才执行常规替换。*
- Mechanism（与代码 `PatchOrInvalidateCachedAdjacency` / `ReserveCachePatchOrInvalidate` / `RefreshGate` 对应）：
  1. 与 descriptor patch 在同一 CUDA stream 中，按 changed source 一个 block 执行；
  2. 新 degree ≤ 原有槽长：**原地覆盖**；
  3. 变长：在 cache 尾部用 `atomicAdd` 申请空间并更新 cache 索引；
  4. 空间不足：**失效**该 cached copy，后续计算回退到 zero-copy 读主存（正确性不受影响）；
  5. 计算后沿用 Grapin 的 hotness 策略选择下一批的 desired set；当 desired 顶点全部有有效 cached adjacency，且数量与已发布集合一致时，跳过 eviction/compaction/loading，否则执行常规替换。
- Guarantee / Cost：cache 维护量跟随 $|S\cap\text{cached}|$；每次修补复制该 source 的**完整当前邻接**，不是边级 delta；hotness 计算和候选排序仍然是全量的；尾部空间会产生碎片，最终依靠常规 compaction 回收。
- 归属措辞：“We retain Grapin's hotness-based hot-subgraph cache and add source-granular patching and a refresh gate”。不要写成我们提出了 GPU cache。

**(c) Consistency**（保留现稿 `design.tex:88` 的前半句）：同一 stream 的顺序保证，计算等待发布完成，旧 block 在先前的 GPU 读者完成后才回收。

### 6.3 §3.2 Decoupled CPU–GPU Incremental Computation（对应 O2、P2）

建议把标题从 “CPU-GPU Collaborative Compact Incremental Computation” 改为更能体现核心机制的名字，例如 **“Decoupled CPU–GPU Incremental Computation”**，“compact” 放在正文中作为结果。（标题由你定，关键是 intro、overview、小节标题三处一致。）

**小节开头先讲关键洞察和正确性，再讲步骤**。这是对现稿最重要的结构调整：把 `design.tex:129` 的论证提前，扩写成开篇段落：

> Problem (O2): restoring invalidated results requires predecessors that the GPU cannot locate, which forces Grapin's implementation to merge repair into insertion processing and to activate all vertices. Key idea: *we complete deletion repair on $G^{-E}_{t+1}$ before applying insertions, using incoming adjacency of the affected vertices supplied by the CPU. Once repair converges, every result is correct for $G^{-E}_{t+1}$; therefore insertion propagation needs to start only from destinations improved by inserted edges.*

再用 2–3 句说明为什么不能跳过解耦：直接从新增边启动会漏掉来自未激活前驱的替代路径（就是 O2 中的 x→v）。这句话同时回答了审稿人可能提出的问题：“为什么不直接只从插入边启动？”

然后按四个子节展开（保留现 Fig.3 / Alg.1 / Alg.2 和 1–6 编号）：

#### 3.2.1 Compact dependency invalidation（step 1）
- 与 Grapin 的差异只写一句：Grapin 按顶点 ID 数组标记、每轮扫描所有分区重建 worklist；我们在第一次标记时 append（atomic slot reservation），每轮只处理上一轮追加的区间。
- 产出 A：连续存放、无重复、不含未受影响顶点。**A 同时是 CPU 准备入边的输入**，这是 CPU/GPU 的接口，要点明。
- 删减 `design.tex:104` 的实现细节（例如 “Only the thread that first marks…” 可以压缩）。

#### 3.2.2 CPU-prepared incoming adjacency and GPU repair（steps 2–3）
- 回指 §3.1.3 的反向索引；I(A) 的定义式保留。
- CPU 并行物化（分组、私有 buffer、前缀和、无共享 append）保留，但压缩到一段。
- 复杂度：空间 $O(|A|+M_A)$，构造工作正比于 |A| 与所检查的 base/delta 记录数。**这一句是“工作随受影响区域伸缩”的形式化证据**，要保留并加粗。
- GPU pull 修复公式保留；warp 协作扫描一行入边。
- 写明删除修复仍由 CPU 逐轮控制（诚实；与插入侧的单 kernel 形成对比）。
- 删除 abstract 中的 overlap 说法（§1.7）。

#### 3.2.3 Insertion propagation from improved destinations（steps 4–6）
- step 4 只写一句并回指 §3.1.4，不要重复发布机制（现 `design.tex:135`）。
- step 5：松弛新增边，**只有改善的终点进入初始 worklist**，种子数 ≤ |I_t|，而 Grapin 实现是 |V|。
- step 6：成功松弛即入队，(batch, round) tag 保证每轮至多一次；单个 cooperative kernel 加 grid barrier，消除 CPU 的 worklist 编排和收敛检查。
- 工作量式 $W_{expand}$ 保留，并与 Grapin 的全点激活对比一句。
- 现稿 `design.tex:154` 与 `design.tex:139` 重复介绍 Algorithm，删一处。

#### 3.2.4 Ordered propagation（从原 §Workload-Specific Optimizations 移入）
- 回指 O2 末尾的伏笔：compact worklist 排除了未激活顶点，但无法阻止同一顶点在大直径图上被更好的结果反复激活。
- bucket $\lfloor r/\Delta\rfloor$，每次只服务最小的非空 bucket，暂缓其他顶点。
- 边界（必须写）：适用于单调、越小越好的算法和正权；当前需要显式开启（`CG_ORDERED_REPAIR`），没有自动选择器；在社交图上可能回退，所以定位为 road-network 场景的选项。

原 §Workload-Specific Optimizations（`design.tex:222-234`）整节删除，内容分别并入 3.1.2 和 3.2.4。

---

## 7. 建议补充的 motivation 实验（参照 Grapin Table 1/2、GASgraph Fig. 2）

只需要选 1 个图和 1 个表；都在 Grapin 原版上测，作为“现有系统的问题”的证据。

| 编号 | 测什么 | 支撑 | 实现提示 |
|---|---|---|---|
| E1 | 每批 requested sources、PMA 实际搬移的 sources、全量 reload 的 descriptor 数和字节数（TW/FS，batch 1K–1M） | O1 第 2–3 点 | 原版 `PMAGraph::insert/rebalance_weighted` 处插计数；descriptor = (V+1) × 记录大小 |
| E2 | Grapin 每批时间分解：拓扑更新、descriptor reload、cache 维护（evict/compact/load）、删除、插入 | O1 第 4 点 + 整体占比 | 原版 `hybrid_sssp.cu:266-270` 周围计时 |
| E3 | size(A)/size(V)；插入阶段初始活动集（=size(V)）对比“被新增边改善的终点数”；第一轮读取边数；worklist 重建时间占比 | O2 第 3 点 | `RebuildWorklist_AllVertices` 与 `RebuildArrayWorklist` 计时；size(A) 可以从我们系统的日志取 |
| E4 | 相邻批次 desired hot set 的重叠率（Jaccard），以及 refresh gate 的跳过比例 | O1 第 4 点 / cache 精细更新 | 我们系统 `[F1-CACHE-PUBLISH] refresh=` 日志可以直接统计跳过率 |

实验口径：与 Evaluation 用同一批 update 序列，避免读者质疑。若篇幅不够，优先做 E1 和 E3。

---

## 8. Introduction / Abstract 的同步对齐

Motivation 改完后，Intro 必须与之镜像，否则前后不一致的问题会转移到 Intro。

- **Challenges**：保留两条，分别是 O1 和 O2 的压缩版，各 3–4 句，每条以“需求”结尾。删除 Challenge 3（`introduction.tex:19-20`），其两项内容在 contribution 中以从属形式出现。
- Challenge 2 改写方向（替换 `introduction.tex:17`）：先讲“恢复需要前驱 → GPU 无入边 → Grapin 实现全点激活”，再讲“CPU 持有拓扑，可以提供 A 的入边 → 解耦 → 插入精确启动”。去掉 transfer time 的断言（§1.7）。
- **CoIncGraph overview 段**（`introduction.tex:23`）：两个 design，分别用一句话写 key idea；ordered propagation 作为第二个 design 的从属。
- **Contributions** 建议改为：
  1. source-isolated graph organization：source 粒度的存储、变更与 GPU 发布，**含 descriptor 稀疏发布与 hot-subgraph cache 的精细更新**；
  2. decoupled CPU–GPU incremental computation：CPU 提供 A 的入边完成删除修复，插入只从改善的终点启动，全程紧凑 worklist，以及面向大直径图的 ordered propagation；
  3. 实验评估。
  如果你仍希望有三条技术贡献，第三条可以是 “ordered propagation + large-batch shared preparation”，但 Motivation 中只需为它们各留一句伏笔，不要另立 challenge。
- **Abstract**：三点结构改为两点，并删除 overlap/concurrency 的说法。

---

## 9. 真实性边界（写作时不能越过）

摘自核对文档并经本次代码复核：

1. **不认领**：DM 增量引擎、result/parent 解耦 CAS、warp/block 顶点中心调度、hot-subgraph cache 本身、zero-copy 与 128B 对齐、CPU 维护拓扑、邻接按 source 连续存放、“两阶段”这一思想本身（Grapin 已有 result correction + iterative calculation）。
2. **可认领**：跨 source 更新隔离及其发布契约；有效变更驱动的多视图维护；稀疏 descriptor 发布；cache 发布时修补与 refresh gate；CPU 物化 I(A) 支撑的独立删除修复；插入只从改善终点启动的精确 worklist；设备内插入闭包；ordered propagation 的接线。
3. **Grapin 论文与 Grapin 实现要区分**：全点激活、全量 reload、每批维护链都是**实现**行为，写 “Grapin's released implementation [artifact]” 或用 E2/E3 的实测说话。
4. **通信**：在 zero-copy 物理流量测量闭合之前，不写 “reduces PCIe transfer by X%”，改用 adjacency reads 或 edges examined。
5. **overlap**：当前删除路径上 CPU 准备与 GPU 修复是串行的，不写 overlap。
6. **通用性**：四条机制主要在 SSSP/BFS 上验证；CC/PR 只说共享框架支持，不说获得同等收益。
7. **ordered propagation**：需要显式开启，正权 1..128，没有自动选择器。

---

## 10. 改写自查清单（写完每一节后逐项打勾）

- [ ] Motivation 首段定义了 update locality 的两个面，后文只用这两个术语。
- [ ] O1、O2 各自以一句斜体需求（R1/R2）结尾；Design §3.1、§3.2 首句分别回指 O1、O2。
- [ ] Motivation 中没有任何当前系统不具备的机制（例如动态 CPU/GPU 分工）。
- [ ] 每个 Design 小节有 Key idea 句，并且出现在机制细节之前。
- [ ] §3.2 开篇先给解耦的正确性论证（为什么修复后只需从插入边启动），再讲步骤。
- [ ] reverse index 在 §3.1 中预告服务于 §3.2，在 §3.2 中回指。
- [ ] cache 精细更新有独立段落：原地覆盖 / 尾部重定位 / 失效回退 / refresh gate，并写明沿用 Grapin 的 hotness 策略。
- [ ] Workload-specific 章节已拆散并入；Intro 只有两条 challenge。
- [ ] 所有对 Grapin 缺点的描述都区分论文与实现，并有 `\cite` 或实验支撑；不存在 `[Efficient Graph ...]` 占位符。
- [ ] 术语表中“不再使用”的词全文搜索为 0（precursor、work list、insertion repair、topological locality …）。
- [ ] 不存在硬编码的 “Section 4.x / 5.x”。
- [ ] Abstract、Intro、Overview 三处对两个 design 的命名逐字一致。
- [ ] 没有越过 §9 的真实性边界。

---

## 附：代码事实速查（供写作时核对）

| 论文论点 | 代码证据 |
|---|---|
| Grapin 插入阶段全点激活 | 原仓库 `framework.cuh:1528-1568` `update_tree_add` → `RebuildWorklist_AllVertices` → `ExecutePolicy_All`，日志 “sssp active all node” |
| Grapin 全量 descriptor 重载 | 原仓库 `framework.cuh:1549` `ReloadAllocator()` |
| Grapin 删除阶段只失效、每轮扫分区重建 worklist | 原仓库 `framework.cuh:1613-` `update_tree_del` → `reset_del_edges` + `RebuildArrayWorklistDel` |
| Grapin 每批无条件执行 cache 维护链 | 原仓库 `samples/hybrid_sssp/hybrid_sssp.cu:266-270` |
| 我们的 cache 原地修补 / 尾部重定位 / 失效 | `include/groute/graphs/csr_graph.cuh:1813-1865` `ReserveCachePatchOrInvalidate`、`PatchOrInvalidateCachedAdjacency`，在 `PublishSparse` 中调用（约 `:2124`） |
| 我们的 refresh gate | `include/framework/cache_refresh_gate.h`；`framework.cuh:1381-1411`；`samples/hybrid_sssp/hybrid_sssp.cu:509-521` |
| 删除修复与 I(A) 物化 | `framework.cuh` `update_tree_del`（约 `:4811`）→ `RunGpuAffectedRepair`（`:4148`）→ `DynamicReverseIndex::MaterializeIncoming`；串行，无 overlap |
