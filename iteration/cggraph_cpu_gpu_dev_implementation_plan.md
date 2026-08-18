# C-GpuStreamGraph CPU-GPU 协同开发实施文档

本文档记录当前 `C-GpuStreamGraph-CG` 中 CGgraph 风格 CPU-GPU 协同机制的可维护规格、关键实验结论和后续优化方向。它同时保留完整的研发时间线：代码细节以当前实现为准，历史迭代用于解释设计选择、实验因果和论文叙事。

## 动态工作区：当前状态、下一步与维护规则

**当前状态（2026-08-17）**：E 不再继续补齐旧意义上的 CPU full runtime。E4-R1（exact-source insertion executor）与 E4-R2（affected incoming sorted merge）作为已通过 gate 的生产基座保留；E4-R3-A/B 作为成本模型和 shadow 证据保留；E4-R3-C 明确取消，而不是待修任务，因为 `--sssp_cpu_domain_map` 仍走已淘汰的 partition-round dispatcher。E 的当前生产结论是 all-GPU exact-source propagation，后续若 F 的真实同 cohort 证据证明 CPU 能删除关键路径，再由统一 runtime 条件式重新开放 CPU executor。证据见第 9.3 节和第 10 节 E4-R。

**唯一下一步**：直接进入大图优先的 F，不再执行 E4-R3-C。先在 Twitter、Friendster、Europe OSM（简称 TW/FS/EU）的 100k mixed-update cohort 完成 F0-L 关键路径审计，再执行 F1-L 的“CPU 整段接管”replay，依次筛选 host-local topology transaction、affected dependency preparation、事件驱动 hot-set/cache patch 和 deletion sparse-tail service。只有候选能够从 GPU 或串行路径删除完整服务、且净收益在至少两张大图稳定为正，才进入 F2 生产接入；insertion propagation 降为 F3 条件分支，不再作为 F 的默认主线。不修补旧 full candidate，不 sweep capacity/packet/ranking，也不以小图上 CPU/GPU 胜负决定架构。

**可用对照与数据（2026-08-17）**：原版外部 baseline 位于 `/home/wangshaoyan/proJect/CG/C-GpuStreamGraph`（仅作阶段性端到端对照；F 日常对照仍是本仓库同 runtime 的 all-GPU）。已可用合成大图 R-MAT：`data/input_rmat_fs_like_50p_100k.txt`（805M base edges，略小于 Friendster）、配套 `update_rmat_fs_like_50p_100k.txt` 与 `stream_size_rmat_fs_like_50p_100k.txt`（10×100k mixed batch）；参数/复现信息见 `data/rmat_fs_like_50p_100k.metadata.json`。

**如何维护本文档**：

1. **当前计划只更新本节和正在执行的 F**：每次开始/完成当前任务，更新状态、下一步、gate 和链接；E5 只保留历史口径，不把尚未验证的候选设计写成既成事实。
2. **完成后回填时间线**：在第 10 节对应阶段追加一段“实现—实验—结论—对下一步的影响”，保留关键数据、日志路径、失败原因和代码删除项。
3. **压缩规则**：只合并同一阶段中已经被后续结论完全覆盖的重复计划、相同实验的重复解释和已失效的预测；不删除阶段本身、创新点、工作量、关键正确性/性能证据、路线转向原因或论文可用的负结果。
4. **阅读顺序**：继续开发先读本节、E4-R 与 F；写论文/报告或理解代码演进时顺读第 10 节；查不变语义、实验口径和创新点时读第 0--9、11 节。

## 0. 最高优先级研发指令

本节优先级高于本文档中的历史结论、阶段计划、兼容性考虑和局部性能目标。后续所有设计评审、代码实现和实验决策必须首先满足以下要求：

> **总原则：本项目的最终性能胜出必须主要来自可发表的算法与系统架构贡献，例如减少全局传播轮次、形成 device-local incremental closure、降低跨域通信复杂度、按拓扑构造低边界执行域，以及让 CPU/GPU 分别替代对方不擅长的计算。工程优化只能消除新架构的实现税，不能作为论文主线，也不能靠反复追逐 memcpy、kernel launch、线程数、阈值或某个数据集的局部热点拼出性能优势。若一个迭代不能说明它改变了工作复杂度、同步复杂度、通信复杂度或关键路径并行结构，就不得作为主要迭代立项。**

1. **本任务是科研研发任务**。优先寻找能够形成明确研究问题、算法贡献、系统架构贡献和可证伪假设的优化；工作重心必须放在异构增量计算模型、任务划分、状态一致性、局部闭包、通信复杂度和调度算法上，而不是常数级工程调参。
2. **禁止临时方案和短期止损思维**。不以 admission gate、特例 fast path、额外阈值、扩大/缩小 packet、数据集 hardcode 或保守 fallback 作为迭代主线。小型工程优化统一推迟到核心算法与架构稳定以后进行，不允许为了短期曲线引入未来需要推翻的中间方案。
3. **每次实现都按最终系统标准完成**。采用业界先进且高效的数据结构、并发模型、内存管理和异步执行方式；不为历史实验长期保留多套执行路径、重复 kernel、重复状态或默认不运行的无用代码。新架构替代旧能力时必须同步删除旧实现，负结果保存在文档、实验日志、提交或独立 artifact 中，而不是留在生产代码中。
4. **主要科研证据必须来自有代表性的高压力数据集**。F 及后续优先使用 Twitter、Friendster、Europe OSM，覆盖社交图高阶数/高竞争与道路图低度数/长尾波前；三者统一使用 100k mixed-update、连续 10 batch 作为主 cohort。Wiki 只保留回归和历史对照，Orkut 只用于机制与正确性验证；小图或稀疏样本不得单独支撑架构收益或论文性能结论。
5. **所有迭代只用流式 batch 时间判断性能收益**。主要且唯一的性能 gate 是 batch 级 `[P0-TIMER]` 求和，即 `paper_algorithm_ms`；图加载、初始计算、首次 cache 建立、最终检查和其他 timer 外工作不进入论文算法时间，不能用完整进程 wall time 否定已经成立的 paper-time 收益。
6. **允许用一次性成本换流式性能**。可以增加初始化时间或适量 CPU 内存来降低 `paper_algorithm_ms`，但不得把原本属于 update batch 的工作移到 timer 外规避统计。初始化 wall、CPU RSS 和一次性物化量继续记录为部署诊断，不作为流式性能 gate。
7. **cache 容量由用户指定，系统不得代替用户决策**。`--cache` 是外部配置，同一对照必须使用相同的用户指定值；runtime、planner 和实验脚本都不得按数据集自动扩大、缩小或改选 cache。除该用户配置本身占用的显存外，系统不得通过新增常驻 GPU 副本、队列或 staging 换取 paper-time 收益；同一 `--cache` 下系统额外 GPU 峰值不得高于基线，并必须考虑后续 UK-2007 的可运行性。

由此派生的代码准入规则：

- 每个能力只能有一个 authoritative implementation；GPU-only、CPU-GPU 等模式通过同一执行框架的资源配置表达，不能复制执行流程。
- 新抽象必须同时减少语义重复或支撑至少两个算法/执行设备，不能只包装现有 SSSP 特例。
- 每个迭代的完成条件同时包含正确性、性能、代码删除和架构收敛；如果新增代码路径多于被替换路径，默认视为未完成。
- 研究消融通过统一组件的参数化接口、独立 commit/build artifact 或离线 replay 完成，不以永久保留废弃实现为代价。

最终核心目标：构建统一的 CPU-GPU 双执行域动态图增量计算系统，使 CPU 能够承担独立的局部增量传播和状态提交，GPU 承担适合其吞吐与驻留特征的任务，两者只交换必要的跨域边界消息。当前 SSSP CPU-owned packet 仅作为已完成的机制探索和对照，不再定义目标架构，也不再要求 GPU 永久拥有全部最终写入权。

## 1. 当前默认口径

当前仓库默认开启协同优化：

- `samples/hybrid_sssp/hybrid_sssp.cu` 中 `coop_mode="hybrid"`。
- `coop_split_mode="cpu_home"`。
- `coop_packet_skip_audit=true`，其当前实际语义是 CPU-owned active-frontier packet，不是旧 CPUHOME owner-skip。
- 原仓库实验默认也通常使用 hybrid/cache 路径；对比原仓库时不能把原仓库的非最佳 `--hybrid=0` 当强 baseline。

因此本文档中的 baseline 口径如下：

- 评估当前 CPU-GPU 协同收益：比较当前仓库 `--coop_mode=hybrid` 与当前仓库 `--coop_mode=off`。
- 评估相对原系统收益：使用原仓库自己的最佳配置，Friendster 当前应使用 `baseline --hybrid=1` 作为 cache 路径对照。
- 任何性能结论都必须有机制证据：CPU edge/proposal、GPU skipped source、merge success、正确性或同配置 correctness 佐证。不能把 GPU-only fallback 包装成协同收益。

## 2. 语义边界

当前生产化探索范围只覆盖 SSSP add/repair convergence：

- 删除路径保持 GPU-only。
- BFS/CC/PR 不进入 CPU-owned packet 性能主线。
- initial `ExecutePolicy_All()` 不做 source skip；CPU ownership 只允许在 convergence delta 中发生。
- CPU 只读 host PMA 的 `sync_vertices_` 和 `edges_`，不读 `cache_edges_l1`。
- CPU 只生成 SSSP proposal 和 source commit；device `value/buffer/parent/out_active/worklist` 仍由 GPU authoritative merge/commit 和 PostBW 闭合。
- CPU source 必须满足 `buffer[src] < value[src]` 才能 expand；source commit 语义是提交 `value[src]=buffer[src]`。

当前主线可以概括为：

```text
active frontier metadata
  -> bounded CPU-owned source packet
  -> CPU reads host PMA and generates proposals
  -> GPU skips fully covered CPU-owned sources in delta kernel
  -> GPU authoritative merge/commit proposals and source commits
  -> dirty/full PostBW rebuilds next-round worklist
```

这不是 CGgraph 的静态 GPU 子图前缀复制，而是动态图增量 SSSP 中的 `frontier-metadata guided CPU-owned packet + GPU authoritative merge`。

## 3. 计时与正确性

论文主指标是 batch 级 `[P0-TIMER][SSSP][batch N] total_batch` 求和，记为 `paper_algorithm_ms`。该窗口覆盖：

```text
del_edge + add_edge + compute_hot_vertices_sssp
  + confirm_candidate_batch + evication_cache + compact_cache + LoadCache
```

不包含最终 Gather、Bellman check、checksum、output。

这里必须区分两个容易混淆的“启动”概念：

- **一次性初始化加载**：`LoadGraph()`、`InitGraph()`、程序启动时的第一次 cache 构建和初始状态准备发生在 batch 循环之前，不属于 `[P0-TIMER]`，不应计入 paper algorithm time。
- **每个更新 batch 的全点增量启动**：`engine.add_edge()` 内的 `update_tree_add()` 在应用本 batch 更新后调用 `RebuildWorklist_AllVertices()`，随后执行 `ExecutePolicy_All()`，再重建 convergence worklist。这段时间位于 `sw_paper_batch` 内，因此属于 paper algorithm time。它不是初始加载，而是每个 batch 重复支付的算法开销。
- 每个 batch 末尾的 `compute_hot_vertices_sssp -> confirm_candidate_batch -> evication_cache -> compact_cache -> LoadCache` 也属于 paper timer；所以任何优化都必须报告对完整 `total_batch` 的影响，不能只报告 convergence kernel 时间。

正确性优先级：

1. `--check=true` Bellman check。
2. distance checksum。
3. parent checksum 只作参考，因为等距 relax 顺序变化会改变 parent。

Friendster stage sweep 目前多为 `--check=false` 性能跑；必须用单独 correctness 日志或补跑 `--check=true` 来支撑正确性结论。

## 4. Hot Cache 规则

GPU 计算仍按现有 hot cache 逻辑：

- `vertices_[v].cache == true`：GPU 读 `cache_edges_l1`。
- 否则 GPU 通过 zero-copy/host PMA 边数组访问。
- CPU executor 始终读 host PMA，因此 GPU cache stale 不影响 CPU 读边正确性，但会影响调度公平性和 GPU 性能。

每 batch 仍按当前顺序完整刷新 cache：

```text
confirm_candidate_batch -> evication_cache -> compact_cache -> LoadCache
```

Friendster 最新结果显示 hot cache 容量是主导收益来源：cache2 相对 cache1 在 current off 上约 29%-36% 提升，明显大于 CPU-owned packet 的 1%-4% 提升。后续优化不能绕开 hot cache 与 ownership 的协同调度。

## 5. 关键代码入口

主要入口：

- `samples/hybrid_sssp/hybrid_sssp.cu::HybridSSSP()`：batch 主循环、cache refresh、`[P0-TIMER]`。
- `include/framework/framework.cuh::Engine::update_tree_add()`：SSSP add/repair convergence 挂钩点。
- `ExecutePolicy_Converge()`：当前唯一 insertion convergence 入口；capacity 0 和正 capacity 共用。
- `BeginInsertionEpoch()`：生成 batch 内固定的 destination-partition owner plan，并路由 added-edge seed。
- `StageGpuToCpuBoundary()`、`RunCpuOwnedClosureHost()`、`CommitCpuOwnedClosure()`：同一 insertion dispatcher 内的 GPU->CPU 暂存、纯主机 owner-local closure 与 CPU->GPU 提交三阶段。
- `CompressCpuRelaxProposals()`：CPU dst-local min 压缩。
- `CommitCpuBoundaryProposals()`：GPU authoritative merge/commit。
- `PostComputationBW()`：只按 successful destination event 重建 dirty partitions 和 active count。

旧 source packet、source skip、shadow-interest 和 packet audit 代码已在 B3.1 删除。当前 GPU kernel 只检查 destination owner：GPU destination 直接 reduce/activate，CPU destination 只写 GPU->CPU boundary slab。CPU->GPU merge 成功后无条件写 changed-destination queue，作为下一轮 dirty-partition rebuild 的唯一事件源。

## 6. 参数口径

常用运行参数：

```text
--graphfile --format=market_big --weight_num=1 --weight=1
--updatefile --update_size --source_node
--SEGMENT --n_stream --hybrid --cache
--check --verbose --sssp_max_batches
```

协同相关参数：

- `--coop_mode=hybrid|off`：当前仓库默认 hybrid；off 用于当前 GPU-only ablation。
- `--coop_split_mode=cpu_home|host_select`：当前 packet 主线挂在 cpu_home 分支；host_select 仅保留历史/诊断价值。
- `--coop_packet_skip_audit=true`：当前 CPU-owned convergence delta packet 主线。
- `--coop_packet_source_policy=active_frontier|degree_desc|noncached_degree|cache_aware|hybrid_score|history_success|batch_touched`：active_frontier 仍是默认主线；当前排序类策略是 sweep/诊断入口，Friendster 上未证明优于默认；`history_success` 目前没有真实历史表，会退化为 hybrid score。
- `--coop_packet_max_sources`、`--coop_packet_edge_budget`：限制 packet 规模。
- `--coop_packet_dry_run`、`--coop_packet_diagnostic_merge`、`--coop_packet_production_merge`、`--coop_packet_overlap_merge`：历史诊断/消融入口。
- `--coop_merge_light_prefilter=false`：CPU 侧按当前 dst buffer 过滤 proposal 的实验入口；默认关闭，因为当前 full dst probe 虽能减少 proposal/H2D/PostBW，但 Friendster b10 端到端变慢。
- `--coop_home_skip_gpu_sources`：旧 CPUHOME owner-skip，曾复现 Bellman failed，不能用于性能 claim。
- `--coop_home_diagnostic_launch`：CPUHOME boundary/dst 诊断入口，不是生产主线。
- `--coop_compress_proposals`：CPU proposal compression 消融。

## 7. 已验证结论

### 7.1 正向结论

CPU-owned active-frontier packet 在 Wiki/Orkut 上形成过有效收益：

```text
Wiki100k/source134151 b10:
  CPU-owned candidate 4017.808 ms vs same-env off 4553.337 ms, Bellman passed

Orkut100k/source377664 b10:
  CPU-owned candidate 1478.845 ms vs same-env off 2406.914 ms, Bellman passed

Wiki100k high-out-degree source sweep b10:
  10.45%-14.98% advantage, Bellman passed
```

这些结果的关键不是 CPU 能扫描很多边，而是同时满足：

- source 来自真实 active frontier；
- CPU-owned source 能完整覆盖并被 GPU delta skip；
- CPU generate/compress 与 GPU launch/sync 有 overlap；
- GPU merge/commit 统一收口；
- cached active-count metadata 降低重复 D2H/sync。

### 7.2 Friendster 最新结论

最新 Friendster stage cache 结果见 `docs/friendster_stage_cache_results.md`。

主要事实：

- 正确 baseline cache 路径必须用原仓库 `baseline --hybrid=1`；早期 `baseline --hybrid=0 --cache=1/2` 只分配 cache，没有执行有效 cache maintenance。
- 当前仓库和原仓库在 Friendster 上基本同级。
- cache1 相对 cache0 有约 22%-25% 提升，cache2 相对 cache0 有约 46%-53% 提升。
- 当前 `coop_mode=hybrid` 相对当前 `coop_mode=off` 在 Friendster 上只有小收益：cache1 约 1%，cache2 约 3%-4%。
- cache3 在 V100 16GB 上 Friendster 1k 首 batch OOM，不适合作为当前主配置。

Friendster cache2 的 CPU-owned packet 机制量：

| dataset | selected sources | CPU covered edges | merge success | success/edge |
|---|---:|---:|---:|---:|
| friendster_1k | 966 | 20,693 | 62 | 0.30% |
| friendster_10k | 2,953 | 93,371 | 609 | 0.65% |
| friendster_100k | 11,908 | 409,785 | 15,648 | 3.82% |

解释：CPU work 确实发生并基本被 overlap 隐藏，但 selected frontier 覆盖和 successful proposal 比例偏低，跳过的 GPU work 不足以抵消 owner mark、state snapshot、merge/H2D、PostBW 和 cache refresh 等固定税。Friendster 当前更像 hot-cache 主导 workload，不是 CPU-owned packet 的强收益场景。

### 7.3 负结果

以下方向已被证明不适合作为当前性能主线：

- whole-segment CPU proposal executor：正确性可闭合，但粒度太粗，proposal 质量低，端到端慢。
- batch_touched high-degree CPUHOME：与真实 SSSP 更新波前错位，CPU 扫边多但有效 relax 少。
- 旧 CPUHOME owner-skip：曾复现 Bellman failed，不能用于论文性能数据。
- no-skip packet merge：GPU 和 CPU 处理同一批 source，正确但重复工作多，端到端慢。
- 只扩大 CPU source 数或降低 degree 阈值：不能解决 proposal 成功率和 ownership 质量问题。
- 未经审计的 initial `ExecutePolicy_All` skip：风险高，目前只允许诊断。

## 8. 已形成的创新工作点

当前系统值得保留和强化的创新点：

- **active-frontier ownership**：CPU source 不是静态高出度点，也不是 batch touched 点，而是当前 convergence delta 中真实 active source。
- **bounded CPU-owned packet**：每轮限制 source 数和 edge budget，避免 CPU 抢占过多不确定工作。
- **GPU authoritative merge/commit**：CPU 不直接写最终 device state，避免异构并发写一致性问题。
- **source owner epoch**：GPU delta kernel 可审计地跳过 CPU-owned source，不影响同 block 其他 source。
- **proposal compression**：CPU 侧按 dst local-min 聚合，降低 H2D 和 merge 压力。
- **round-level overlap**：CPU generate/compress 与 GPU delta launch/sync 并行。
- **cached active-count metadata**：在 rebuild 边界维护 `seg_active_num`，CPU source selection 和 GPU launch 共用 metadata，避免重复 queue counter D2H。
- **dirty/rebuild metadata**：用 changed dst 和 CPU merge dst/source commit 驱动 dirty segment rebuild。
- **机制日志摘要**：quiet log 输出 `[COOP-OWNED-SUMMARY]`，证明 CPU work、GPU skip、merge 和 hidden CPU work 真实发生。

## 9. 当前主要问题

1. **默认口径容易混淆**：当前仓库默认 `coop_mode=hybrid`，不再是 off。所有实验脚本必须显式写出 `--coop_mode`，文档和表格必须说明 current off 与 current hybrid 的差异。

2. **Friendster 上 CPU packet 质量偏低**：active source 被选中后，大量 proposal merge 不成功。说明 CPU 并没有稳定拿到 GPU 的瓶颈工作。

3. **source selection 单靠排序没有解决 Friendster**：最新 sweep 显示 CPU-owned source 已经基本是 non-cached，`degree_desc`、`noncached_degree`、`cache_aware`、`hybrid_score` 在 Friendster 1k/10k 上没有稳定超过默认 `active_frontier`。问题更像 active frontier 中可成功 relax 的工作本身稀薄，而不是简单 cache 归属错误。

4. **控制面固定税仍在 critical path**：source snapshot、owner mark、skip counter D2H、proposal H2D、merge success D2H、dirty rebuild 和 active count refresh 都可能抵消 CPU 分担收益。

5. **PostBW/dirty 放大仍可疑**：`postbw_visible_active` 不是完整的 next-round active 可见性指标。prefilter 实验证明只让成功 proposal 影响后续 dirty/rebuild 可以显著降低 proposal、H2D 和 PostBW，但 CPU full dst probe 本身太贵。

6. **hot cache refresh 是大模块成本**：Friendster 上 cache 容量收益远大于 CPU 协同收益。若 CPU ownership 不参与 cache 调度，协同空间会被 GPU cache 主路径压缩。

### 9.1 代码实现审查结论（2026-07-12）

| 能力 | 当前状态 | 代码事实 | 判断 |
|---|---|---|---|
| CPU 真实参与增量计算 | 已实现，限 SSSP add convergence | CPU 从 host PMA 扫边并生成 proposal，GPU 对 owned source 做 skip | 机制成立，但 CPU 仍是 GPU round 的辅助执行器 |
| CPU/GPU 并行 | 已实现，粒度有限 | 每轮临时创建一个 `std::thread`，CPU generate/compress 与 GPU delta 重叠 | 只有单 CPU worker，没有利用多核，也没有跨轮 persistent runtime |
| 工作划分 | 实验性 | 从 device worklist 逐 segment D2H，按 source 数和 edge budget 选择完整 source | 划分成本在 GPU launch 之前，且目标函数不是设备执行时间 |
| 状态一致性 | 已实现，限 min-plus 单调 relax | CPU snapshot source value/buffer；GPU merge `atomicMin`；source commit 回写 GPU value | 对 insertion SSSP 可闭合，不是通用动态图一致性协议 |

| proposal 降流量 | 已实现 | CPU 按 dst local-min 压缩；GPU success queue 驱动 dirty marking | 减少了放大，但所有 CPU 结果仍要 H2D 并进入 GPU commit |
| dirty rebuild | 已实现，仍为 segment scan | success dst 映射到 dirty segment，再对 dirty segment 全顶点 rebuild worklist | frontier 稀疏时仍会出现 segment 级读放大 |
| cache/ownership 联合优化 | 未实现 | cache 只作为 source policy 的静态特征，refresh 与 ownership 独立 | Friendster 的主导因素没有进入统一调度器 |
| 在线收益模型 | 未实现 | `history_success` 没有真实历史，退化为手工 score | 当前不能根据设备服务时间稳定做出 offload 决策 |
| BFS/CC/PR 协同 | 未实现 | 三个应用只定义兼容 flag，协同语义和执行器仍硬编码 SSSP | 还不能证明这是可推广的异构增量框架 |
| 删除/repair 协同 | 未实现 | 删除保持 GPU-only | 当前论文命题必须明确限定为插入诱发的 SSSP repair |

### 9.2 结构性瓶颈，而非工程小优化

1. **当前是 offload-and-return，不是 CPU/GPU 双执行域**。CPU 每轮只能处理 GPU 已经生成的 frontier，随后把每个有效目的点送回 GPU；CPU 不能在 host 上消费自己新产生的 active vertex 并形成局部闭包。因此 CPU 多承担一条边，就几乎必然增加一条 proposal、H2D、merge 和 GPU worklist 维护链路。该架构天然只适合“CPU 扫边时间完全藏在 GPU 窗口内”的小比例卸载。

2. **round barrier 仍是全局临界路径**。active source D2H、source state snapshot、owner mark、GPU sync、proposal H2D、merge sync、dirty segment D2H/rebuild 串成每轮控制链。CPU worker 与 GPU kernel 虽有重叠，但选择和提交阶段没有形成流水线；扩大 CPU 比例会迅速放大 barrier tax。

3. **调度目标与真实性能目标错位**。`edge_budget`、degree、cached/non-cached 和 `merge_success_per_edge` 都不能直接表示被替代的 GPU 时间。GPU 上 cached edge、zero-copy edge、不同度数和不同竞争度的单边成本差异很大；同时，proposal merge 失败不代表 CPU 扫边没有替代 GPU 工作。后续 admission 若只用 success ratio，可能错误关闭“relax 很少但 GPU 扫描很贵”的 CPU 任务。

4. **CPU 资源模型不成立**。当前每轮创建一个串行 worker，不能代表多核 CPU 的吞吐、NUMA locality 和持续任务队列能力。科研结论若写成 CPU-GPU 协同，至少应让 CPU executor 成为固定线程池，并报告 CPU 核数、内存带宽和占用。

5. **source packet 不是稳定的数据局部性单元**。frontier 每轮变化，逐 source ownership 需要反复 D2H/mark。最终直接复用现有稳定 vertex-range segment 作为唯一 ownership 单元，source frontier 只是 segment 内的本轮 payload，不再另建 micro-partition 层级。

6. **通用性被 SSSP 语义硬编码**。CPU executor 直接计算 `(src + dst) % 128 + 1`，merge 固定为 `atomicMin`，source active 条件固定为 `buffer < value`。在抽象出 `expand/reduce/commit/activate` 之前，扩到 BFS/CC 只会复制特例，PR 的非幂等加法语义更不能沿用当前协议。

因此，当前 packet 路径适合作为可工作的 v1 和论文消融基线，但不宜继续以增加 source policy、阈值或 packet 大小作为主研究路线。

### 9.3 最新瓶颈重判与四轮对抗性分析（2026-08-17）

本节只使用已经进入 `paper_algorithm_ms` 的实测阶段和当前代码路径，不用 GPU utilization、CPU idle、synthetic edge throughput 或单个 kernel 时间替代端到端因果。

**第一轮：反驳“CPU 参与越多越接近目标”。** E0-A 已经证明 fixed destination partition 的 CPU service 没有替代 GPU traversal；E1 的 METIS map 虽在 Wiki/Friendster 产生低边界 region，E3-B2 仍比 all-GPU 慢。R1 随后把 all-GPU insertion 改为 exact-source cooperative closure，十批累计 convergence 仅 Wiki `5.598--6.006 ms`、Twitter `2.520--2.545 ms`、Friendster `7.877--8.017 ms`。同 cohort 完整 paper time 仍约 Wiki `3.33--3.55 s`、Twitter `1.65--1.68 s`、Friendster `4.26--4.70 s`。因此 CPU 即使把 insertion propagation 降到零，理论上也只能改善约 `0.15%--0.19%`；“至少承担 15% propagation edges”不再是有意义的系统成功条件。CPU 参与是手段，不是目标；只有 CPU 替代了可观 GPU critical-path service，才算协同。

**第二轮：反驳“只差一个统一 full runtime 就能得出论文结论”。** 当前 full candidate 确实不公平：代码中 `exact_all_gpu` 只在 `!m_cpu_domain_map_enabled && capacity==0` 时进入 `RunExactSourceClosure()`，domain map 路径仍落入 `ExecutePolicy_Converge()` 的 segment worklist、CPU thread、join、commit 和 `PostComputationBW()`。但修好公平性只是获得合法实验，不会自动创造性能空间。若先投入完整 CPU exact-source runtime，而不先证明 CPU 可替代的 workload 至少占 paper critical path 的显著比例，最可能得到的是一个正确但受 Amdahl 上限约束的负结果。

**第三轮：反驳“单一 edges/ms planner 已经覆盖系统现实”。** E4-R3-B 的 synthetic GPU rate约为 CPU 的 `77.7x`，能够否定当前 METIS propagation map，却不能决定所有异构机会。当前 planner 把 cached GPU edge、host Zero-Copy edge、CPU host-local edge、deletion pull、topology mutation、cache rebuild和跨域状态事件折算为同一种 edge rate；同时把 dependency/topology 公共成本等量加到 all-GPU 与 full，无法表达 CPU work 与 GPU work 的流水重叠、CPU 在更新时已经拥有数据、以及 CPU 预处理能否删除 GPU publication/cache work。它只能回答“给定这张 propagation map 谁更快”，不能回答“CPU 应承担系统中的哪一种工作”。

**第四轮：反驳“把下一 batch 提前就能免费流水”。** 动态 SSSP 的算法状态在 batch 间有因果依赖，当前论文指标又是逐 batch `[P0-TIMER]`；直接把 batch `e+1` 的 mutation放进 batch `e` 会改变时延语义或产生重叠 timer 双重计时。可合法利用的并发边界更窄：同一 batch 内，GPU 可以基于旧 topology/state 和 update list做 dependency invalidation，CPU 同时以 touched-source COW构造应用本批更新后的新 topology/dependency版本；两者完成后原子发布新版本，再执行 replacement repair和insertion。任何更激进的跨 batch throughput pipeline都必须另立语义和指标，不能混入当前 paper claim。

**剃刀结论：当前最简单且能解释全部证据的模型是四个串行大阶段，而不是 CPU propagation 不足。**

```text
paper critical path
  = deletion invalidation + affected incoming prepare/repair
  + host topology mutation + version publication
  + exact-source incremental closure
  + hot-cache selection/compact/load
```

R1 后第三项已从主要矛盾降为小项；R2 降低了 deletion incoming preparation，但 deletion 总体仍是 Wiki/Friendster 的大项；host mutation 和 cache compact/load 在十批中分别达到数百毫秒，且当前 batch pipeline 基本串行。因而后续值得研究的 CPU-GPU 协同不应再是“CPU 与 GPU 竞争同一批 relax edges”，而应优先是 **CPU 负责其天然拥有的 topology/version/affected-set 工作，GPU 继续执行 exact closure，并在同一 batch 内对因果独立的旧状态失效与新拓扑构造形成并发**。这会改变关键路径的并行结构，也与动态图系统中 CPU 权威拓扑的现实一致。

R1 首轮十批 performance cohort 的量级如下；这里只用于机会预算，不当作最终统计报告：

| dataset | paper total | deletion | PMA mutation | cache compact + load | exact insertion closure |
|---|---:|---:|---:|---:|---:|
| Wiki | 3327.663 ms | 1441.976 ms (43.3%) | 583.092 ms (17.5%) | 1007.312 ms (30.3%) | 5.598 ms (0.17%) |
| Twitter | 1682.447 ms | 268.574 ms (16.0%) | 111.610 ms (6.6%) | 870.015 ms (51.7%) | 2.545 ms (0.15%) |
| Friendster | 4293.925 ms | 1553.147 ms (36.2%) | 669.375 ms (15.6%) | 1250.610 ms (29.1%) | 7.877 ms (0.18%) |

该表也限制了下一步的叙事：cache pipeline在 Twitter 是最大项，但若候选只减少 cache kernel 常数而不改变“每批全量重选/重建”的算法工作，就仍属于低价值工程优化；相反，若版本化更新能证明只维护受影响 hot set、消除重复 compact/load，才可升级为研究候选。F0-L 必须在 TW/FS/EU 上重新以交错重复实验确认这些比例。

据此冻结以下研究纪律：

1. 不再把 CPU edge share、CPU busy time 或 overlap 本身作为成功指标；唯一指标是被删除或被隐藏的 GPU/串行 critical-path 毫秒。
2. 不再为旧 partition-round full candidate修 correctness 或性能；它只作为历史负结果，统一 exact-source full candidate必须先通过 F1-L 的 propagation replay 才实现。
3. 不再以单一 synthetic edge loop外推真实设备服务；CPU/GPU交叉必须在同一真实 source cohort、同一 adjacency placement、相同 reduce/commit语义下测量。
4. 不做 cache compact、PMA allocator、线程数、flush阈值的局部微调；只有能够消除全量/重复工作，或把串行 batch阶段变为版本化流水的设计才可立项。
5. 若 CPU propagation 的真实可替代上界不足，论文命题应转为“CPU-managed dynamic topology 与 GPU incremental closure 的版本化协同”，而不是强行声称双执行器同时传播。

## 10. 完整研发时间线与后续方向

本节按“问题 → 实现 → 证据 → 结论/转向”记录完整科研脉络，服务于论文叙事、代码阅读和下一步设计。每项保留架构创新、代表性工作量与实验事实；已被后续结果覆盖的逐次 gate、重复命令、重复预期和临时候选不再逐条保留。10.1--10.6 是 packet v1，10.7--10.9 是从 packet 向统一 runtime 转向的过程，A--E 是当前 topology-first 事件执行架构的研究链。

### 10.1--10.6 packet v1：机制验证、负结果与冻结（2026-07-09--11）


**问题与实现。** 以 active-frontier CPU-owned source packet 让 CPU 读 host PMA、GPU skip owned source、GPU authoritative merge/commit；补齐 `[COOP-OWNED-SUMMARY]`、skip audit、attribution 与 `extract_coop_mechanism_tsv.py`，量化 frontier、cache、covered/skipped edge、proposal、merge、dirty 和 cache refresh。随后测试 degree/cache/history/batch-touched 排序、CPU full-dst prefilter 与 success-only dirty merge。

**关键证据。** Friendster cache2 b10 中 `active_frontier` 的 1k 为 `17507.863 ms`，排序策略慢约 `7%-10%`，10k 最好策略也仅约 `-0.15%`；prefilter 虽将 proposal `20238 -> 100`、H2D `251988 -> 8880 B`、PostBW `63.238 -> 12.013 ms`，却使总时间 `18846.262 -> 19240.104 ms`。success-only dirty merge 在 Wiki cache3 b1 Bellman 通过，`total_batch=380.408 ms`、`merge_success=1589`，证明 GPU 内核侧收口可正确减少 dirty 放大，但未改变 packet 的控制面模型。

**结论与论文价值。** CPU work 和 overlap 均真实发生，但 Friendster 的 `merge_success/covered_edges` 过低，热点 cache 收益远大于 packet；按 degree/cache 排序不是缺少 CPU 工作的解法，CPU full probe 的反例证明“减少通信量”不等于减少端到端关键路径。packet 被冻结为 v1 消融基线，停止 admission gate、packet budget、CPUHOME skip、特例 fast path 和 source-policy 扩张。性能口径同时冻结：`current off` 不等于原仓库 GPU-only；原仓库强基线使用 `--hybrid=1 --cache=2`，Twitter/Friendster 10k 的 current hybrid/off 分别约 `-0.54%/+2.73%`。

### 10.7 迭代七：从 packet 到双执行域的架构判定（2026-07-12）

本迭代没有向生产代码增加执行路径。工作包括：审查 insertion SSSP 的完整控制流；形式化 `expand/reduce/commit/activate`、唯一 vertex owner、boundary message、batch 边界迁移和双域 quiescence；用离线 oracle 验证三代价 ownership 模型；再用隔离 profiler 对同一 active cohort 做 20 核 CPU 与当前 GPU multi-stream 路径的对称 replay。调度模型最终只保留设备服务时间、跨 owner 传输时间和迁移时间，memory/eligibility 是硬约束，degree/cache/PMA/queue 等不进入在线打分。正确性依据是 insertion SSSP 的非负权 min-plus relax 单调下降、`min` 幂等且每个状态只有一个 authoritative owner；双侧 local queue、boundary counters 与二次 fence 同时静止时满足 Bellman 不等式并终止。

最终验证使用 Wiki100k/cache3、Twitter100k/cache2、Friendster100k/cache2，各运行 5 个真实更新 batch，CPU 读取 host PMA 并做 proposal 与线程内归约，GPU 执行原有完整 relax 路径；全部通过 Bellman。下表是 convergence cohort 的架构 headroom，不是端到端加速，CPU replay 尚未包含最终跨线程 authoritative commit，因此不能直接作为论文性能数字。

| 数据集 | batch / cohort 数 | active edges | 20 核 CPU 累计 | GPU 累计 | GPU/CPU | 最保守单 cohort GPU/CPU |
|---|---:|---:|---:|---:|---:|---:|
| Wiki100k | 5 / 53 | 1,580,174 | 21.776 ms | 283.444 ms | 13.02x | 4.81x |
| Twitter100k | 5 / 31 | 147,641 | 7.216 ms | 152.665 ms | 21.16x | 7.15x |
| Friendster100k | 5 / 46 | 2,780,240 | 25.898 ms | 281.857 ms | 10.88x | 3.53x |

最终结论与创新点：第一，当前 insertion 每 batch 的 `ExecutePolicy_All()` 是伪增量启动，5 个 batch 中全点启动占 add-compute 的 Wiki `24.83%`、Twitter `38.43%`、Friendster `88.18%`，必须由 added-edge seed frontier 替代。第二，当前 GPU 每轮遍历并 launch 全部 512 segments，后期只剩个位数 active sources 时仍有约 `4.3-4.6 ms` 固定税；最终 runtime 必须维护 active-partition queue 并只 dispatch 活跃 owner。第三，CPU 的价值主要在稀疏、细粒度波前，GPU 的价值在高并行 cohort；二者应在各自 owner 内 local closure，只交换归约后的跨域边界，而不是每跳回 GPU merge/PostBW。第四，ownership 采用现有稳定 vertex-range segment 作为唯一划分层级并在 batch 内固定，避免另建 micro-partition 体系和 round 级迁移。第五，online planner 使用一次 `O(E_boundary + P log P)` timing-only prefix sweep，对完整 plan 施加 hysteresis，不引入黑盒模型或大量相关特征。

迭代七最终 gate：三组主数据集均显示足够且稳定的结构性 headroom，正确性通过，目标架构和删除清单已冻结，允许进入迭代八。原 isolated-partition oracle 的 `1.68x/1.44x/3.32x` 只保留为方向性上界，不再作为后续性能承诺；Orkut 仅作早期机制验证，不进入主结论。

这里的 gate 只证明“seed frontier + active-partition dispatch + local closure”值得实现，不等于已经证明 paper algorithm time 会取得同样比例的端到端加速。迭代八先收敛 GPU 控制流并验证 active-partition dispatch；完整双执行域和端到端 10-batch 结论顺延到迭代九。后续实验仍必须把 cache refresh、更新应用、边界通信、migration、rebuild 和 convergence 全部纳入 `[P0-TIMER] total_batch`，convergence cohort 的 CPU/GPU headroom 不能替代 paper timer。

### 10.8--10.9：seed frontier 暴露 deletion 契约缺口（2026-07-12--14）

- 时间：2026-07-12。
- 目标：先删除 insertion convergence 的运行时分叉，并使 GPU delta launch 数由活跃 partition 数而不是固定 512 个 partition 决定，为双执行域 runtime 建立唯一 GPU 基座。
- 改动：`coop_mode=off|hybrid` 的 insertion convergence 收口到 `ExecutePolicy_Converge()`；该函数只 dispatch `seg_active_num > 0` 的稳定 vertex-range partition。此处提到的旧 packet 实现已在后续 B3.1 删除，不再存在生产 dispatcher 或兼容 flag。
- 正确性：全量构建通过；Wiki100k/source134151/cache0 b1 `--check=true` 通过，`reachable=6655918`、`relaxable_edges=0`、`[P0-TIMER] total_batch=850.690 ms`。
- 结论：统一入口和按活跃 partition dispatch 已完成；本迭代不宣称 seed frontier、CPU local closure 或完整双执行域已经交付。

迭代八完成门槛：生产 insertion convergence 只有一个入口；GPU 不再为 inactive partition 发起 delta kernel；至少一个主数据集 Bellman correctness 通过；失败 seed 原型不留在生产代码。以上门槛已满足。

**关键失败。** 统一 insertion 入口与 active-partition dispatch 已完成（Wiki b1 Bellman passed，`total_batch=850.690 ms`）；但直接 added-edge seed 在 Wiki b1 两次失败，留下 `63066/67988` 条 relaxable edge，首个反例 `61 -> 3132910`。刷新 deletion active count 后仍有 `163095` 条 relaxable edge：根因不是单跳终止，而是只有 outgoing PMA，affected region 无法从外部入边找替代父节点。由此建立 deletion-stage Bellman 硬 gate，禁止以“有删除时全点 kickoff”掩盖错误。

**修复与证据。** 引入 CPU dynamic reverse index（immutable incoming base + batch overlay）、affected-region closure 和立即 physical delete；CPU 以外部 finite source 为 boundary seed，提交 `(vertex,value,parent)`，added edge 再直接 seed。Wiki/Twitter/Friendster b1 均 deletion-stage/final passed：affected `8,672/3,746/18,341`，boundary edge `187,792/12,346/227,824`，CPU closure `35.485/32.436/107.662 ms`；Wiki 连续五 batch paper time `565.510/624.722/527.326/626.697/567.998 ms`，add compute 约 `718 -> 90 ms`。naive selective gather 虽将 Wiki transfer 降至 `1.34 MB`，却使 CPU repair `40 -> 83 ms`、paper `1194 -> 1262 ms`，证明通信压缩必须用结构化 compact queue，而非 CPU hash 容器。

**双执行域命题与转向。** 此时形成目标协议：固定 vertex-range owner、epoch/version、owner-local `expand/reduce/commit/activate`、双向 min-reduced slab 与 credit/quiescence；all-GPU 由同一 runtime 的空 CPU domain 表达。后续测量发现 `GPU invalidation -> CPU repair -> GPU insertion` 仍串行，且 deletion 占 paper `55%-59%`，不能将 CPU repair 误作协同收益。Twitter/Friendster 10k/100k 对原系统的时间分别为 `6562/7787 vs 3238/4453 ms` 与 `11545/15801 vs 20615/22309 ms`；性能 run 还存在 reachable 差异，因此仅保留为机制证据。研究转入 A/B/C：先正确性与关键路径归因，再选择 deletion executor，最后验证拓扑与 owner 架构。

#### 10.9.4 端到端对照触发的二次重排（2026-07-14）

在完全空闲的同一张 V100 GPU 2 上，current 统一 runtime 使用 `--hybrid=0 --cache=2 --coop_mode=off`，原 `C-GpuStreamGraph` 使用其已验证 cache 路径 `--hybrid=1 --cache=2`。Twitter/Friendster 10k/100k 各运行 10 个 batch；下表只汇总 `[P0-TIMER][SSSP] total_batch`，不重复计入内部 Traversal timer。

| dataset | current | C-GpuStreamGraph | baseline/current | current 相对 baseline |
|---|---:|---:|---:|---:|
| Twitter 10k | 6562.266 ms | 3237.854 ms | 0.4934x | 慢 102.67% |
| Twitter 100k | 7786.631 ms | 4453.417 ms | 0.5719x | 慢 74.85% |
| Friendster 10k | 11545.179 ms | 20615.320 ms | 1.7856x | 快 44.00% |
| Friendster 100k | 15800.763 ms | 22309.457 ms | 1.4119x | 快 29.17% |

该结果部分支持 H1：Friendster 上 added-edge seed 消除伪增量全点 kickoff 后形成显著端到端收益。但它同时否定“完成 seed frontier 后可以直接把主线全部转向 insertion concurrency”的执行顺序。current 中 deletion stage 占完整 paper time 的比例如下：

| dataset | deletion stage | insertion add | deletion / paper | add / paper |
|---|---:|---:|---:|---:|
| Twitter 10k | 3794.793 ms | 377.048 ms | 57.8% | 5.7% |
| Twitter 100k | 4308.176 ms | 635.307 ms | 55.3% | 8.2% |
| Friendster 10k | 6801.637 ms | 593.883 ms | 58.9% | 5.1% |
| Friendster 100k | 8677.197 ms | 1274.630 ms | 54.9% | 8.1% |

当前 insertion 只占 `5%-8%`，即使把它无限加速，Amdahl 上界也不足以修复 Twitter 的 `1.75-2.03x` 回退。deletion 内的全量 state D2H 和 CPU closure 是可见成本，但二者之和仍不能解释全部回退；禁止直接把 selective gather 当成既定答案。必须先拆出 GPU dependency invalidation、active-partition rebuild、host PMA physical delete/reload、state gather、boundary/local closure、commit 和 cache refresh 的独立 critical-path 时间，再依据主导项收敛架构。

本次性能运行使用 `--check=false`，不能支撑 correctness。final reachable count 中 Friendster10k 一致，但 Twitter10k current 比 baseline 少 2、Twitter100k 少 22、Friendster100k 少 6。该差异可能来自 current、baseline 或检查口径，未定位前所有四组时间只作为机制证据，不作为论文结果。

调整后的唯一执行顺序为已完成的 A、拆分后的 B1-B3，以及最终收敛 C。每个小迭代先产生证据，再决定下一步代码，不把未经实验选择的设计直接并入生产路径。

##### 迭代 A：可信正确性与关键路径归因

结论（Twitter100k/source0/cache2 mixed b10，独占 V100）：10 个 deletion-stage 和 10 个 final check 全部满足 `source=0`、`relaxable_edges=0`、`missing_tight_witnesses=0`，最终 reachable 为 23,163,906、distance checksum 为 `12687655862474487153`。stored parent mismatch 不影响 distance correctness，仅保留为诊断；不引入锁、宽原子或 parent 修复路径。

10 批 `paper_algorithm_ms` 合计 6824.811 ms：deletion 占 50.1%，insertion 占 30.5%，hotness/candidate/cache pipeline 占 19.5%。deletion 内 CPU repair 占 60.3%，GPU invalidation 占 34.4%；CPU repair 内全图 prepare scan 为 1011.685 ms、state D2H 为 453.216 ms、boundary scan 为 286.011 ms，而真正 local closure 仅 18.524 ms，commit 仅 0.745 ms。稀疏后期仍固定重建 512 个 partition。

Gate A 结论：主导问题是全图状态准备/传输、全 partition rebuild 和 deletion invalidation，不是 CPU relax 算法。后续不接入 Ligra、不并行化当前 Dijkstra，也不修 parent 竞态。由于 deletion 中真正 CPU local closure 10 批合计仅 18.524 ms，B 不把拆分这段小计算作为并发主线；唯一原型使用事件驱动、partition-owned frontier，先去掉 deletion 的全图准备税，再在占总时间 30.5% 的 insertion convergence 中验证真实 CPU-GPU 并发。

##### 迭代 B1：deletion 执行域判定与公平对照

结论：deletion 不能把原系统的“GPU invalidation 后靠全点 insertion 补偿”当作独立 GPU repair。满足 deletion-stage Bellman gate 的 GPU affected-pull closure 在 Wiki/Twitter/Friendster mixed b5 均正确，并相对 CPU repair 将完整 batch 降低 `30.83%/34.92%/32.62%`。

关键创新是以 compact affected queue 驱动 GPU closure，并由 dynamic reverse index 仅物化 affected destination 的权威 incoming slab；它避免常驻全量 CSC，也明确计入 topology H2D。结论直接决定 B2：生产代码只保留 GPU affected-pull，不保留 CPU repair 或 repair selector。

##### 迭代 B2：选定 deletion 路径的事件驱动稀疏化

实现：deletion 收敛为唯一的 `GPU dependency invalidation -> GPU affected-pull closure`。parent CAS 直接追加 compact queue；新失效点继续进入同一 queue，repair 只处理新增区间。CPU 仅负责 dynamic reverse index 的 affected incoming slab 物化，不参与 repair executor。

关键创新是删除全图 state gather、repair 专用 affected 副本和固定 512-partition rebuild，以同一事件流连接 invalidation、topology slab、GPU pull 与提交。三图 mixed b5 均 `5/5 deletion-stage + 5/5 final` 通过；相对 B1 GPU 路径，delete 降低 `68.84%/88.87%/71.67%`，完整 batch 降低 `34.37%/35.63%/21.26%`。该路径是后续唯一保留的 deletion runtime。

##### 迭代 B3：single-runtime insertion owner protocol 与并发证伪

实现：每个 epoch 按稳定 vertex-range 给 destination 指定唯一 owner；seed、reduce、commit、activate 都由 destination owner 完成，跨 owner 候选经双向 min-reduced boundary slab。capacity 0 与正 capacity 共用同一 dispatcher、frontier 和 quiescence；dirty rebuild 只消费 successful destination event。旧 packet/source-owner/shadow 路径、固定 512 rebuild 和静默 round 上限均已删除。

关键创新是把 CPU closure 拆成 `StageGpuToCpuBoundary -> RunCpuOwnedClosureHost -> CommitCpuOwnedClosure`，在首个 GPU kernel 提交后与 GPU wave 并发；slab、CPU state 和 owner flags 在 load 阶段预分配，epoch 仅更新 owner ranges。三图 capacity 0/2 checksum 一致，分别为 Wiki `17090313294947580515`、Twitter `18038659416545880558`、Friendster `1350487882132001113`；也观测到真实 overlap。

否定性结论：CPU useful service 极小，Wiki/Twitter/Friendster 的可见最大 overlap 仅约 `0.308/0.007/0.059 ms`，CPU 很快等待 GPU。Wiki 首轮 `0/1/2/4/8` correctness 均通过，但没有可靠的非零 capacity 端到端胜者；不能以 CPU partition 扩大进入 C。B3 的价值是建立无双路径、可测且正确的双 owner substrate，并排除“CPU insertion closure 是主瓶颈”这一假设。

##### 迭代 C：CPU 权威更新与 GPU 拓扑发布（C1--C4，2026-07-27--28）

**问题。** Wiki capacity 0 的 PMA insert、`ReloadAllocator()`、convergence 分别为 `42.949/45.836/46.415 ms`，而 capacity 2 的 CPU useful service 仅 `0.308 ms`。PMA 的跨 source rebalance 使 GPU 无法只发布 touched source；C 因而研究 CPU 权威拓扑和稀疏 GPU publication，不再扩大 CPU insertion ownership。

当前的两个 `45 ms` 级成本实际上同源：PMA 为了维持全局稀疏连续布局，一条边更新可能移动其他 source 的边并改写一大段 `sync_vertices_`；GPU 于是无法只信任 touched source，只能重新接收全部 descriptor。只做“PMA changed interval + 区间 memcpy”不是最终解法，因为它没有消除跨 source 移动，稀疏性仍由 rebalance 偶然决定。

**C1：语义基座。** 冻结 `ContiguousAdjacencyView`、16-byte legacy descriptor、24-byte sparse patch descriptor、`TopologyEpochContract` 与 `topology_replay`；重复边统一为 add `+1` occurrence、delete `-1` occurrence。Wiki/Twitter/Friendster 首批 replay 覆盖 `97,246/18,769/75,464` touched source，均无 missing delete/invalid add；Wiki 审计 `218,608,712` edge、zero mismatch，Bellman/checksum 通过。C1 的价值是给 PMA、reverse index、CPU/GPU/cache 提供唯一 adjacency/epoch 语义，而不是性能优化。

**C2：source-local chunk store。** 实现 mapped-pinned slab、`{offset,degree,slab_id,version}`、按 source group、source-local compact/COW 与 epoch 延迟回收；所有发布邻接保持连续，更新不改写 untouched descriptor。三图 replay 零 mismatch/isolation violation，首批 group `22.887/4.846/20.077 ms`、mutation `45.381/9.962/43.879 ms`，capacity amplification `1.455/1.430/1.453x`。Wiki 10 batch 复用约 `1.5K--1.6K` retired block/batch，high-water `465.97 -> 468.26 MB`；结论是隔离、连续格式与回收成立，非性能胜出。

**C3：稀疏发布与 cache 一致性。** 生产切换为 chunk store 唯一权威图；按 source 去重的 24-byte patch 一次 H2D、同 stream scatter、touched hot source 失效后走 cold/ZC。三图 Bellman/topology replay/hash 均通过、stale reject 为 0；Wiki 三 batch patch `97,246/97,207/97,103`，每批一次 H2D；Twitter/Friendster 分别 `18,769/75,464` record、`19.029/55.017 ms` publication。该阶段证明稀疏发布正确，不能代替 C4 性能结论。

**C4：完整验收与否决。** 独占 V100、`cache=2`、capacity 0、10 batch、5 交错重复（40/40 `ok`）对 C1：

| dataset | current paper median / p95 ms | C1 median / p95 ms | current reduction | current GPU MiB | C1 GPU MiB | GPU delta MiB |
|---|---:|---:|---:|---:|---:|---:|
| Orkut100k | 2665.539 / 2712.659 | 2043.281 / 2076.681 | -30.45% | 4959 | 4877 | +82 |
| Wiki100k | 4814.015 / 4889.088 | 4216.221 / 4310.059 | -14.18% | 6753 | 6431 | +322 |
| Twitter100k | 2265.980 / 2282.084 | 3065.573 / 3158.276 | +26.08% | 10367 | 9563 | +804 |
| Friendster100k | 6482.744 / 6647.372 | 7574.769 / 7716.144 | +14.42% | 15657 | 14141 | +1516 |

Twitter/Friendster 提升 `26.08%/14.42%`，Orkut/Wiki 回退 `30.45%/14.18%`，且 GPU 增加 `82/322/804/1516 MiB`，不能通过 C 的统一 gate。cache 相同且 refresh 反而降低，新增成本来自 mutation/publication、physical delete 和随顶点数线性增长的 24-byte extended descriptor；因此不以局部胜利宣称 C 成功，进入 D 清除可定位集成税。

### 迭代 D：去除 C3 集成税的微调迭代

!!!!!!注意：从此D迭代开始，涉及系统运行架构、数据结构、系统算法层级的大优化（类似于C或D迭代），必须关于创新点的记录量>=C\D迭代的记录量，因为这是我们科研论文的创新点，是我们写论文的重要依据！实验结果的记录还是可以压缩简略只保留关键内容

D 不改变 source-local chunk 架构、B2 deletion repair、B3 capacity-0 dispatcher、hot-cache selection 或用户 `--cache`。不引入数据集阈值、额外 GPU topology 副本、UVM、active-edge staging 或新旧双路径。D 只处理 C4 已量化的三项成本，并按 D1/D2/D3 独立提交和验收。

**D1：删除全量 extended device descriptor。** GPU traversal 已只读取现有 16-byte `vertex_sync_element`，24-byte `TopologyDescriptor[nnodes]` 仅被 scatter 的 per-source version check 使用。D1 删除该全量 device array，sparse patch 直接更新 legacy descriptor；source version 和 epoch 顺序由 CPU authoritative descriptor、唯一 source patch、全局 topology epoch 与同 stream publish-before-traverse 契约验证。`--check=true` 下的 GPU adjacency hash 继续直接读取 patch record 和 mapped slab，不依赖全量 extended mirror。patch/digest buffer 保持 `O(touched sources)`，不得改成 `O(V)` version array。

D1 gate：四图连续 mixed batch correctness 与 C3 checksum 不变；相同用户 `cache=2` 下 GPU peak 不高于 C1，至少回收理论上的 `24 * nnodes` bytes，并记录剩余 sparse patch/digest 峰值。UK-2007 估算必须只包含 legacy descriptor、用户 cache 和 `O(touched)` staging。D1 单独提交；未满足显存 gate 不进入 D2。

D1 实施结果（2026-07-29）：实现按上述最小状态契约删除了 GPU 常驻的 `TopologyDescriptor[nnodes]`。scatter 现在只更新 kernel 已经使用的 16-byte legacy descriptor，patch 中的 source version 直接等于 pending topology epoch；CPU 在发布前验证 epoch 单调性、source 严格递增且唯一，以及 descriptor 的 slab/offset/degree 合法性。GPU adjacency audit 直接读取本批 patch 和 mapped slab，不再通过全量 extended mirror。实现没有用 device stale-version array/counter 或 host history map 替代被删除的数组，因此常驻状态确实减少理论 `24 * nnodes` bytes，保留的 host/device patch 和 correctness digest staging 均严格为 `O(touched sources)`。

D1 全量 build、4/4 CTest 和 `git diff --check` 通过。Orkut/Wiki/Twitter/Friendster 各执行 3 个 mixed batch，`check=true` 下 deletion-stage 和 final Bellman 均通过，stale reject 与 GPU/CPU adjacency hash mismatch 全为 0。相对 C3，四图观测 GPU peak 分别从 `4959/6753/10367/15657 MiB` 降至 `4885/6441/9565/14151 MiB`，回收 `74/312/802/1506 MiB`，与删除 `24 * nnodes` 全量数组的方向和规模一致。D1 数值相对同 cohort 历史 C1 的 `4877/6431/9563/14141 MiB` 仍高 `8/10/2/10 MiB`；这是 MiB 级采样下的 sparse staging 与 allocator 波动，不能表述为逐项数值严格低于 C1，但已消除 C4 所定位的随 vertex 数线性增长的额外常驻副本。基于“显存只防止为性能过度牺牲，允许少量 sparse staging”的验收口径，D1 的机制和实际显存 gate 通过。原始记录位于 `logs/d1_gate_20260729/*_final.log` 和 `*_final.gpu.tsv`。

**D2：publication 去同步化，完整 hash 只属于 correctness audit。** 当前每 batch 创建/销毁 event、同步 publication event、D2H 两个 counter，并对全部 patch source 扫描邻接生成 GPU digest，再 D2H 全部 digest 由 CPU 重算 hash；这些工作全部位于 paper timer。生产 `--check=false` 路径只保留一次 patch H2D、同 stream scatter 和 epoch/version host-side precondition，依靠 stream 顺序保证 traversal 可见性，不在 publish 后立即 host synchronize。event 复用并在已有 batch 同步点读取计时/counter。完整 GPU/CPU adjacency hash 只在 `--check=true` correctness audit 中执行，不能移到 timer 外伪装性能；性能跑不执行该审计，正确性跑仍保持 hard failure。

D2 gate：每 batch 仍为一次 patch H2D，stale reject 为 0，publish-before-traverse 无违规；三图 `--check=true` 连续 batch hash/Bellman/checksum 通过。`check=false` publication median 至少降低 70%，完整 `paper_algorithm_ms` 不得回退。D2 单独提交。

D2 实施结果（2026-07-29）：pinned host patch、device patch 和 CUDA begin/end event 在 load 阶段按最大 batch 预分配，后续 epoch 复用。`PublishSparse()` 的生产路径只 enqueue event begin、cache counter memset、一次 patch H2D、同 stream scatter 和 event end；consumer streams 通过 `cudaStreamWaitEvent` 建立 publish-before-traverse 依赖，发布之后不再插入 host barrier。`CompleteSparsePublication()` 只在 batch 已有同步点读取 event timing、counter，以及 correctness 模式的 hash 结果。`check=false` 不分配 digest staging，也不执行 adjacency hash；`check=true` 仍在 paper timer 内执行完整 GPU/CPU hash，任一 mismatch 仍为硬失败，因而没有通过把 audit 移出计时来制造收益。D1 的 CPU epoch/version/source/descriptor precondition 全部保留。

D2 correctness cohort 为 Orkut/Wiki/Twitter 各 3 个 mixed batch，共 9 个 batch；deletion-stage Bellman 全部通过，hash mismatch 和 stale reject 均为 0，每 batch `h2d_count=1`。`check=true` 下 audit publication 仍完整保留，Orkut、Wiki、Twitter 分别约为 `5.9-6.3 ms`、`31.1-37.4 ms`、`20.3-21.7 ms`。production `check=false` cohort 是四图各 3 repeats、每次 10 batch，其 publication 与 paper median 如表；这里是 D2 screening/reference，不能与后续 D3 最终 5-repeat cohort 混算。

| dataset | D2 publication median ms | D2 paper median ms | C4 current paper median ms | paper change |
|---|---:|---:|---:|---:|
| Orkut100k | 0.397 | 2353.331 | 2665.539 | -11.7% |
| Wiki100k | 0.427 | 4154.785 | 4814.015 | -13.7% |
| Twitter100k | 0.089 | 1950.026 | 2265.980 | -13.9% |
| Friendster100k | 0.297 | 5351.344 | 6482.744 | -17.5% |

相对 D1 correctness/audit publication，D2 production publication 的降幅约为 Orkut `93.6%`、Wiki `98.7%`、Twitter `99.6%`、Friendster `99.5%`；四图完整 paper time 同时下降，没有出现成本从 publication 转移后造成的端到端回退。D2 gate 因而通过。原始 correctness、production 和逐次统计记录位于 `logs/d2_gate_20260729`。

**D3：source mutation 从临时全邻接复制改为两遍计划加一次 compact。** 当前每个 touched source 先通过 `Neighbors(source)` 复制完整邻接到 `std::vector` 做资源预检，随后 in-place 路径再次线性查找并对每条 delete 单独 `memmove`，扩容路径还会再次复制。这使 sparse delete 退化为重复的 `O(degree + deletes * degree)` 搬移。D3 第一遍只读统计每个 delete occurrence 是否命中、最终 degree 和是否需要扩容，完成全 batch allocation preflight；第二遍对 in-place source 用稳定 read/write cursor 一次 compact 并尾部追加，对扩容 source 直接一次写入新 block。必须保持 delete-one-occurrence、delete-before-add、邻接顺序、失败原子性和 epoch retirement。

D3 gate：定向测试覆盖重复边、多 delete 同 destination、missing delete、in-place、COW、高度点和 arena exhaustion；逐 source ordered hash 与 C1 oracle 一致。四图 `mutation_written_bytes` 只统计实际 compact/append，physical delete 与 CPU mutation median 显著下降；最终 paper gate 要求 Wiki 不再回退、Twitter/Friendster 保持正收益，Orkut只作机制诊断。任何收益不得来自改变用户 cache 或增加 GPU 峰值。D3 后重新执行四图 5-repeat C4；通过后才完成旧 PMA runtime 清理并冻结 C/D 结论，否则按 C4 规则回退到 C1 runtime。

D3 实施结果与最终判定（2026-07-29）：mutation 被改造成“全 batch 只读计划/preflight，成功后一次实际提交”的两阶段协议。第一遍按 source grouping mutations，统计每个 delete occurrence 的命中、missing delete、final degree 和 expansion requirement，并对全 batch 执行 `EnsureAllocationsFit`；只有 preflight 全部成功后才推进 pending epoch、edge count 和实际 adjacency。这样 arena exhaustion 在任何 source 被修改前失败，不会留下部分 batch 已提交的 descriptor 或邻接。

单 delete 常见路径使用 inline `DeletionRun` 和 `std::find` 记录 first-match offset，不为每个 source 构造 heap vector，随后只做一次 stable `memmove` compact。多 delete 路径对 destination 排序计数，用 read/write cursor 一次稳定 compact，严格保持每个 delete 只删除一个 occurrence。addition-only 且容量足够时不扫描旧邻接，直接 append；COW 路径直接从旧 block 写入新 block，addition-only COW 只 memcpy 一次 old range 后 append，不再先形成完整临时 adjacency vector。所有路径继续保持 delete-before-add、邻接顺序和 epoch retirement；`mutation_written_bytes` 只统计实际 compact/relocation/append，`relocation_copied_bytes` 只统计被复制的存活旧边。

定向测试覆盖 duplicate edge、多 delete 同 destination、missing delete、in-place、direct COW、4096-degree source、对 `TopologyReplayModel` 的 ordered hash，以及多 source arena exhaustion 的 failure atomicity；全量 build、4/4 CTest 和 `git diff --check` 通过。Orkut/Wiki/Twitter 各 3 个 mixed batch 同时启用 `--check=true` 和 `--topology_replay_audit=true`，共 9 个 batch 的 touched-source ordered/multiset mismatch 均为 0，deletion-stage Bellman、batch check 和 final Bellman 全部通过。正确性原始记录为 `logs/d3_gate_20260729/orkut_check_final.log`、`wiki_check_final.log` 和 `twitter_check_final.log`。

D3 最终性能 cohort 使用当前最终二进制，四图各 5 repeats、每次 10 batch，共 20 runs/200 batches；所有实验严格串行，每次启动前确认完整 GPU compute-process 列表为空，没有中断、抢占或影响其他用户进程。四图 final reachable 在各自 5 次中稳定为 `268658/6655852/23163906/54222900`，无 protocol、CUDA 或 runtime error。原始日志位于 `logs/d3_gate_20260729/*_perf_r1..r5.log`。下表中的 D2 是前述独立 3-repeat reference，D3 才是最终 5-repeat median，二者用于方向性前后对照而非伪装成同一交错 cohort。

| dataset | D2 paper (3r) ms | D3 paper (5r) ms | paper change | D2 total mutation ms | D3 total mutation ms | mutation change |
|---|---:|---:|---:|---:|---:|---:|
| Orkut100k | 2353.331 | 2277.559 | -3.2% | 463.460 | 357.117 | -23.0% |
| Wiki100k | 4154.785 | 3977.542 | -4.3% | 653.944 | 521.377 | -20.3% |
| Twitter100k | 1950.026 | 1919.521 | -1.6% | 166.957 | 143.592 | -14.0% |
| Friendster100k | 5351.344 | 5184.984 | -3.1% | 815.232 | 606.411 | -25.6% |

addition mutation 四图均明显下降，依次为 `216.997 -> 149.198 ms`、`287.909 -> 194.631 ms`、`68.347 -> 36.897 ms`、`376.423 -> 241.800 ms`。delete mutation median 在 Orkut/Wiki/Friendster 从 `246.560/368.161/436.006 ms` 降至 `207.919/326.746/364.611 ms`，但 Twitter 从 `97.909 ms` 增至 `106.945 ms`，回退 `9.2%`；对应 physical delete 在前三者从 `377.580/510.714/573.581 ms` 降至 `338.917/462.570/509.176 ms`，Twitter 则从 `118.865 ms` 增至 `128.319 ms`，回退 `8.0%`。delete `mutation_written_bytes` 的 D2 -> D3 变化分别为 Orkut `53,062,400 -> 51,095,352`、Wiki `129,906,824 -> 127,020,316`、Twitter `76,303,340 -> 62,795,568`、Friendster `151,316,600 -> 150,111,916`；Twitter 写入字节减少但 delete wall time 增加，说明该子项不能只凭字节指标宣称通过。

相对冻结的 C1 paper median，D3 的 Orkut 为 `2277.559 vs 2043.281 ms`，仍慢约 `11.5%`，按既定 gate 只作机制诊断；Wiki 为 `3977.542 vs 4216.221 ms`，快约 `5.7%`；Twitter 为 `1919.521 vs 3065.573 ms`，快约 `37.4%`；Friendster 为 `5184.984 vs 7574.769 ms`，快约 `31.5%`。因此最终 paper gate 通过：Wiki 不再回退，Twitter/Friendster 保持明确正收益，总 CPU mutation 四图均下降，C/D 主线端到端假设得到支持。

但 D3 的严格子 gate“每张图 physical delete 与 delete mutation median 都显著下降”没有无条件通过，Twitter 是唯一例外。当前不为 Twitter 引入 dataset special case，也不以总体收益抹去该负项；因此尚未执行旧 PMA runtime cleanup，亦不宣称所有 D3 子 gate 已全部通过。冻结 C/D 和清理旧 runtime 前，需要明确接受 Twitter delete-only 子项由其 `-14.0%` 总 mutation、`-1.6%` D2-to-D3 paper 以及相对 C1 的 `+37.4%` 端到端收益覆盖，或继续做不依赖数据集特例的机制优化。

C 期间不引入 UVM 或 insertion active-edge staging。GPU-resident hot CSR 继续服务热边，cold source 继续 Zero-Copy，B2 deletion incoming slab 继续显式 H2D。C4 后若 ZC cold-edge time 成为新主导项，再用同一 compact frontier 对 `ZC` 与 `pack + H2D` 做独立同 cohort 对照。dirty-worklist/rebuild、CUDA Graph、persistent kernel 和 CPU ownership 扩展也延后到 C4 后重新 profile，不在本轮预设下一个优化对象。

### 迭代 E：边界感知的 CPU-GPU 双执行域增量闭包

迭代 E 是 C/D 完成 topology substrate 之后的下一项架构迭代，目标是让 CPU **替代** GPU 执行一部分完整的增量传播，而不是继续辅助 GPU 做 source packet、proposal prefilter、状态搬运或工程级微调。B3 已证明“给 CPU 少量连续 destination partition”能够保持正确并产生真实 overlap，但 CPU useful service 只有微秒到亚毫秒级；这否定的是当前固定 vertex-range 划分和逐轮回传模型，不是否定 CPU-GPU 协同本身。

E 的核心研究问题是：能否把动态图增量波前划成两个具有局部闭包能力的执行域，使 CPU 消化 host-resident、cold、分支不规则且边界较小的区域，GPU 消化 cache-resident、高吞吐区域，并把通信复杂度从“CPU 每次 relax 都返回 GPU”降低为“只有跨域成功 relax 才交换消息”。性能收益必须来自 GPU 被替代的计算和 Zero-Copy 访存减少，而不是 timer 外搬移、数据集 hardcode、阈值 gate 或新增 GPU 常驻副本。

#### E0：冻结研究基线与机会空间

先冻结 D3 的 `capacity=0` 为唯一内部性能基线，并完成 C/D 旧 PMA runtime cleanup；未完成 cleanup 时不允许在旧路径上叠加 E。E0 分成两道证据：E0-A 用现有 unified runtime 对 fixed destination-partition owner 做真实执行 screening，判断扩大现有 CPU ownership 是否能删除 GPU service；E0-B 再对 all-GPU 事件流做 source-owner 离线 replay，评估尚未实现的 region-local closure。两者不能混淆：E0-A 的 CPU service 只代表旧 destination-owner 架构，不能直接当作 E 新架构的 CPU cost。

E0-B 对 Wiki/Twitter/Friendster 连续 mixed batch 采集 source/partition 级 replay trace，至少包含 active 次数、实际扫描边数、GPU cache/cold 边数、GPU service time、成功 relax、source/destination region、局部闭包深度和跨 region 成功边。trace 只记录已有计算事件，不在性能 run 中启用全边软件插桩；性能基线关闭 trace，离线 oracle 消费独立 correctness trace。

E0 不以 GPU utilization 或 CPU idle 估算机会，而是离线计算三个可证伪上界：

1. `replaceable_gpu_ms`：若某区域转交 CPU，理论上可从 GPU critical path 删除的实测 service time。
2. `cpu_domain_ms`：CPU 完成本地闭包的计算时间，包括本地队列、状态提交和必要拓扑访问。
3. `boundary_ms`：双向成功 relax 的聚合、传输、消费与终止检测成本。

只有 E0-B 在代表性数据上找到满足 `max(cpu_domain_ms, remaining_gpu_ms) + boundary_ms < baseline_gpu_ms` 的非平凡 source-owned region，才进入生产 executor 实现。若现有 segment membership 下所有候选的 boundary volume 都接近内部 relax volume，E1 只允许研究 region construction 并重新运行离线 oracle，而不是先写 runtime、调度阈值或异步通信。

**E0-A 结论（2026-07-31）。** 单卡、`cache=2`、三 batch screening 中，Wiki capacity `0 -> 32` 的 paper/convergence 为 `1048.766 -> 1453.444` / `107.722 -> 446.448 ms`；Twitter 为 `539.327 -> 559.235` / `54.469 -> 70.211 ms`，Friendster 为 `1536.586 -> 3175.790` / `283.431 -> 1761.819 ms`。GPU service 在三图仅变化 `+3.381/+0.469/-1.683 ms`，CPU service 虽增长至 `2.646/0.152/5.611 ms`，却未替代 GPU source traversal。故 fixed destination-partition expansion 的 `replaceable_gpu_ms≈0`，正式停止 capacity、seed ranking、连续 range 与 CPU thread sweep；日志为 `logs/e0_screen_20260731/`。

E0-A 正式否定 fixed destination-partition expansion，后续不再对 capacity、seed-count ranking、连续 range 或 CPU thread 数做 sweep。它同时把 E 的第一性不变式提前：**source/outgoing traversal、vertex authoritative state 和 local active queue 必须同 owner**。E0-B/E1 的 oracle 必须按这个新语义重放；E2 不是可选优化，而是任何 CPU 计算收益成立的前提。

**E0-B 结论。** `--e0b_trace_file` 记录 exact `parent -> dst` 成功事件；Wiki correctness trace 的 11 轮 `4,232` summary/event 完全守恒，三图三 batch all-GPU trace 共 `12,297/5,627/73,300` event。现有 512 vertex-range segment 中仍存在 local chain（最大深度 Wiki/Twitter/Friendster `4/4/6`），所以局部闭包有算法空间；但在达到非平凡 scan share 时 boundary/internal 为 Wiki `2.10`、Twitter `1.14`、Friendster `1.91`，不适合直接实现双域。trace 从此只评价冻结的分区，不参与训练、owner 选择或逐图调参；原始结果在 `logs/e0b_20260731/`。

因此 E0-B 不批准直接进入 E2/E3 production executor，也不否定 E。E0-B 的 exact successful propagation event 从此只承担**评价**职责：验证一个通用分区在不同图、source 和 update batch 上实际产生多少内部闭包与边界通信，不再作为 region construction、owner selection 或在线模型的输入。禁止用前若干 batch 的成功传播图训练、拟合或搜索后续 owner plan，也不引入按数据集保存的 community、阈值或参数。

E 的下一步改为 topology-first 的通用异构划分：region 只由当前权威拓扑的静态结构和设备可解释成本构造，设备选择只使用与数据集名称无关的稀疏度、degree irregularity、边界体积、邻接驻留位置和硬件一次性标定结果。E1 必须在同一套规则、同一组硬件参数下跨 Wiki/Twitter/Friendster 工作；换图时只重新读取图结构，不重新训练或 sweep 目标函数。

#### E1：通用 topology-first 异构区域划分

E1 不沿用 B3 的 fixed vertex-range destination partition，也不根据历史 active frontier 或 successful relax 构造分区。region 是纯拓扑对象：每个 vertex 及其 outgoing adjacency 只属于一个 source-owned region；初始化时按结构连接性形成低边界区域，同时约束 region edge volume，防止生成一个巨型稠密区和大量碎片。可以采用成熟的通用图分区器或确定性的 multilevel coarsening，但输入只能是当前图的邻接关系和边权，不能输入 dataset id、SSSP source、update trace、distance 或历史设备收益。

E1 分为三个彼此独立、可解释的步骤：

1. **结构分区**：以静态 edge cut/volume 和 region edge-balance 为唯一分区语义。分区器对所有数据集使用相同算法和固定 region-count/imbalance 规则；region count 由 CPU core 数、GPU stream 并行度和最小任务粒度等硬件约束推导，不对每张图 sweep。
2. **结构分类**：为每个 region 计算 `edges/vertices`、degree mean/CV、零度与低度比例、内部边比例、boundary volume，以及 adjacency 中当前位于 GPU hot cache 与 host chunk store 的比例。这些是可解释的拓扑/放置量，不使用传播历史。
3. **设备映射**：GPU优先承担 cache-resident、边密集、并行度高且 degree distribution较规则的 region；CPU优先承担 host-resident、稀疏或分支不规则且内部边比例足够高的 region。CPU/GPU crossover 只由部署时一次性 synthetic microbenchmark 标定为吞吐曲线，不在真实数据集上搜索阈值。

设备映射使用解析式成本而非学习模型：

```text
T_cpu(r) = edges(r) / calibrated_cpu_edges_per_ms(class(r))
T_gpu(r) = hot_edges(r) / calibrated_gpu_hot_edges_per_ms
         + cold_edges(r) / calibrated_gpu_zc_edges_per_ms
T_boundary(r) = cut_edges(r) * calibrated_message_cost
```

这里的 `class(r)` 只表示预先固定的 sparse/dense 与 regular/irregular 结构类别。标定在合成结构上一次完成，产生硬件配置，不随 Wiki/Twitter/Friendster 或 update batch 改变。owner assignment 只求解上述解析成本的容量约束 balance；E0-B trace 在 assignment 完成后才用于检查真实 successful boundary，不能反向调参。

动态图更新默认保持 region membership 和 owner 稳定。source-local chunk mutation只更新 region 的 edge/degree/boundary 计数；只有通用结构不变式被破坏，例如 region edge volume 超出初始化上限或 edge-balance 超出固定容差，才在 batch 边界拆分/合并受影响 region。不得因某几批传播收益下降而迁移 owner，也不得维护每数据集历史模型。

E1 必须同时输出两类证据：结构证据包括 edge cut、edge balance、region size distribution、类别分布和 CPU/GPU 解析成本；E0-B replay 证据包括 internal successful relax、双向 successful boundary、local chain depth 和可替代扫描边。结构证据决定方案，传播证据只验证方案。

E1 gate：同一个分区算法、region-count规则、结构分类规则和硬件标定文件直接用于 Wiki/Twitter/Friendster，不做逐图 sweep。至少两张主图的 CPU regions 同时满足：(a) 承担不低于约 10% 的实际扫描边；(b) `boundary/internal < 1`；(c) 存在深度至少 2 的 local chain；(d) 解析式 `max(T_cpu, T_gpu) + T_boundary` 低于 all-GPU propagation time。第三张图允许解析模型自然选择 all-GPU，但不得用数据集特例关闭 CPU。若通用 topology-first 分区不能通过该 gate，E 停止为负结论，不进入 executor 实现。

CGgraph-V1.5 参考结论（2026-07-31）：其 `ProcessorSpeed` 并非决策树或学习模型，而是在真实图上分别完整运行 CPU/GPU BFS/SSSP 五次、去掉最快和最慢样本，并以 `CPU total time / GPU total time` 得到 `CG_ratio`。协同轮中令 GPU 边份额为 `CG_ratio / (1 + CG_ratio)`（SSSP 再除以 1.05），对已排序 frontier 构造 degree exclusive-prefix-sum，通过 `upper_bound` 找切点；GPU 扫描前缀、CPU 扫描后缀，两者 source work 严格互斥并发，最后 OR/merge visited/frontier 或 SSSP state。这个设计证明“给 CPU 的量应按 source 扫描边数而非顶点数”以及“吞吐比例可直接换算边容量”是有效的通用机制。不能照搬的部分包括依赖真实数据集完整运行的比例文件、`1M/200M` active-work 硬阈值、累计扫描 90% 后锁定 GPU，以及每轮全量 SSSP state H2D/merge；这些会引入数据集依赖或抵消动态图的小批量收益。

因此 E1 的 CPU 获取规则冻结为两层约束。第一层由一次性 synthetic hardware calibration 给出目标边份额 `q_cpu = P_cpu / (P_cpu + P_gpu)`，其中吞吐按固定 sparse/dense、regular/irregular 类分别标定，不在真实图上训练。第二层只选择完整 topology region，使累计 source-edge volume 接近 `q_cpu * active_edge_volume`，且新增 region 后的静态 boundary/internal 仍满足 gate；不能把一个 region 拆给两个设备。这里仅借用 CGgraph 的“source-edge volume 是容量单位”，不借用它的每轮 frontier 切断语义：`q_cpu` 只控制 epoch/batch 边界的新 region admission，CPU 已领取的 region 一旦被激活就必须完成 region-local incremental closure，不能因达到配额中断。闭包导致的实际边量超额记为 quota debt，并在后续 admission 中扣减；owner 候选集合、边界约束和 debt 规则均与数据集名称及传播历史无关，E0-B trace 不参与选择。

**E1-A/B 分区筛选结论。** 现有 shard quotient 的 CPU 集合虽覆盖 Wiki/Twitter/Friendster `11.47%/11.54%/25.26%` actual scan，却有 successful boundary/internal `3.38/1.41/1.51`，否决；RCM、固定轮 label propagation、80-region 与 15/85 双域也未在 `>=10%` work 时跨图达到低边界，故不继续调 quota/启发式。转用固定 seed、edge-cut objective、1.05 imbalance 的 METIS 5.1；输入仅为对称静态邻接和 `max(out_degree,1)` weight。

METIS 输入只含对称化静态邻接和 `max(out_degree, 1)` vertex weight，固定 seed、edge-cut objective 和 1.05 imbalance；E0-B trace 仅在 map 冻结后 replay。20/80 是 E1-A 预先声明的统一容量观察点，并非按图搜索。结果为：Wiki static CPU edge 19.51%、actual scan 17.88%、static boundary/internal 0.345、successful boundary/internal 0.448、local depth 6；Friendster 分别为 19.22%、16.06%、0.635、0.569、depth 10；Twitter 分别为 19.87%、23.21%、3.273、1.129、depth 5。原始结果位于 `logs/e1b_metis_wiki_20260731_143014/wiki.tsv` 和 `logs/e1b_metis_cross_graph_20260731_143415/`。Wiki 与 Friendster通过 E1 的 work/boundary/chain gate；Twitter不通过低边界 gate，后续解析 planner 必须能因 boundary cost 输出 all-GPU，不能给 Twitter设置例外参数。

E1 至此冻结为两级结构，而不是把 CGgraph 的 frontier slice 原样移植：第一级在装载/离线阶段按硬件 `q_cpu` 直接生成 CPU/GPU 两个不对称 device domain，跨域 cut 才产生通信；第二级在每个 device domain 内按 CPU worker/GPU stream 切 scheduling region，只用于队列并行，不改变 vertex-state owner。Friendster METIS 单次离线生成耗时 2425 秒，主分区阶段 RSS 约 74GB，因此 production 必须支持持久化 `vertex -> domain` map、拓扑 fingerprint 和配置版本校验；不得在每次启动或 batch 内现场重分区。动态图增量默认保持 domain 稳定，结构失衡后的局部重分区属于 E4，不进入 E2 correctness substrate。

#### E2：建立 vertex-state ownership 与本地域完整闭包

E2 实现 E0-A 已证明不可缺少的 source-state co-ownership，将 B3 的 destination owner substrate 替换为 vertex-state owner：顶点的 `value/buffer/parent/active queue` 和 outgoing traversal 在一个 epoch 内由同一设备负责。CPU-owned vertex 的权威状态驻留 host pinned state，CPU 直接读取 C/D 的 source-local chunk adjacency，并用多核 work-efficient priority/bucket frontier 执行到本地域暂时静止；GPU-owned vertex继续使用现有 GPU frontier、hot cache 和 cold adjacency view。CPU 不为本地域每一轮生成 GPU proposal，GPU 也不为 CPU region 扫描内部边，CPU state 不在每轮整段回写 GPU。

边 `u -> v` 的执行规则固定为：owner(`u`) 扫描该边；若 owner(`u`) 等于 owner(`v`)，在本地域直接 reduce、activate 并继续传播；否则只把候选 `<v, distance, parent, epoch>` 写入目标域 boundary slab。每个 slab 在发送前按 destination 做 min-reduce，目标 owner 是该顶点状态的唯一提交者。distance 是算法权威状态；parent 只需提供合法 tight witness，不以竞争相关的 parent checksum 作为双域等价条件。

这一步的关键算法变化是 **region-local closure before communication**：一个域连续消费内部新 active vertex，只在本地队列暂时为空或 boundary slab 达到既定批量时发布跨域消息；不再维持“一次 GPU round 对应一次 CPU round”的全局 barrier。batch 结束条件由双域 credit-based quiescence 判定：CPU queue、GPU queue、双向在途 slab 和未消费 event 同时为零，且 epoch counter 在两次观测间稳定。不得通过固定 round cap 或最后一次全图 GPU sweep补正确性。

E2 gate：定向图覆盖 CPU-only chain、GPU-only chain、双向跨域环、多次 boundary 改进、相等距离竞争和更新后 owner epoch；Wiki/Twitter/Friendster 连续 mixed batch 的 deletion-stage/final Bellman、distance checksum 和 tight witness 与 capacity 0 一致。机制日志必须证明 CPU 执行了多层 local closure，GPU 确实没有扫描 CPU internal edges，且所有 boundary credit 最终守恒。

E2 当前进展（2026-08-03）：已增加持久化 `uint16_t vertex -> device domain` map（`0=CPU, 1=GPU`）及严格大小/owner 校验，并实现 CPU-owned compact state、CPU source-local chunk closure、CPU->GPU 压缩 proposal、GPU->CPU boundary queue 和 owner-aware added-edge seed。定向 smoke 已覆盖 CPU-only 两层闭包及 CPU->GPU 后继续 GPU 传播，distance/parent checksum 均与 all-GPU 一致。Wiki METIS map 的 mixed b1 在 `check=true` 下与 all-GPU distance checksum 同为 `17090313294947580515`，Bellman `relaxable_edges=0`、`missing_tight_witnesses=0`；CPU 首轮执行 869 个 vertex、21,838 条边、7 层闭包，证明 CPU 计算替代了 GPU 域内传播而非重复执行。parent checksum 不作为等价 gate：现有 SSSP 的分离 distance/parent 原子更新本来就会留下少量竞争相关的 stored-parent mismatch，distance 与 tight-witness gate 才是冻结口径；本迭代不为此引入全边 parent 重建或 64-bit packed state。

同日对 GPU worklist 做了 owner 原地压缩并增加 `removed_gpu_sources/removed_gpu_source_edges` 实测指标。Wiki 的 11 个 insertion round 均为 0：CPU work 只由 CPU-owned seed、CPU 内部 relax 和 GPU->CPU boundary 三条路径进入本地 frontier，本来就没有回流 GPU source worklist。因此 kernel 内 owner skip 不是当前性能主因，不再沿此方向做工程优化。真正的结构性冗余是每个 CPU closure round 全量 scatter 4,103,205 个 CPU 顶点；改为 dirty-state scatter 后，首轮仅回写 864 个顶点、10,368 B、0.100 ms，其余有效轮为 1--102 个顶点。相同单次 correctness cohort 中 Wiki domain 从 `669.472 ms` 降到 `446.649 ms`，all-GPU 为 `381.511 ms`，仍慢 `17.1%`；这只是一次 correctness cohort，只能定位结构瓶颈，不能作为性能胜出结论。剩余差距与 epoch 开头 49,238,460 B、`72.881 ms` 的全量 CPU-state gather 同量级。

**E2-C 下一研究迭代：跨 mixed update 生命周期的持久双执行域。** 不把“减少一次 gather”作为独立优化目标，而是改变动态图算法的状态所有权：METIS/topology region 的 owner 跨 batch 稳定，CPU/GPU 各自长期保存其顶点的 authoritative distance、parent、active state 和 deletion/insertion repair queue；删除失效、替代父边搜索、插入 relax 与后续局部闭包都由 vertex owner 在本域完成。边界只交换两类归约消息：删除导致的 dependency invalidation/repair request，以及插入或修复产生的跨域 distance proposal。这样全量 state gather/scatter 会作为架构结果自然消失，通信由 `O(|V_cpu|)` 降为 `O(|successful boundary| + |cross-domain invalidation|)`，全局 mixed-batch pipeline 从串行 `GPU deletion -> state snapshot -> CPU/GPU insertion` 改为两个域上的增量修复与局部闭包。研究消融必须比较：(a) 仅 insertion domain ownership；(b) deletion/insertion 统一 ownership；(c) all-GPU，并报告减少的全局轮次、被 CPU 替代的 GPU edge service、boundary complexity 和 critical path，而不能只报告少拷贝了多少字节。

E2-C 持久状态首轮实现（2026-08-05）：CPU domain state 现在在初始 SSSP 收敛后一次性 gather，并带独立 state epoch 跨 mixed batch 保留；`BeginInsertionEpoch()` 不再按 batch gather 全部 CPU-owned vertex。deletion affected queue 只筛出 CPU-owned destination，通过稀疏 `{vertex,value,parent}` 状态事件更新 host authoritative mirror，随后 insertion closure 继续消费同一状态。协议禁止在 initial state handoff 前执行 deletion reconciliation，违反时直接终止。Wiki METIS map 连续两个 mixed batch、`check=true` 均通过 deletion-stage、batch 和 final Bellman，最终 `relaxable_edges=0`、`missing_tight_witnesses=0`。一次性初始化为 `4,103,205` vertices、`49,238,460 B`、`30.160 ms`，明确位于初始计算后且不属于 batch timer；batch 0/1 不再发生全域 state D2H，只分别 reconciliation `1,521/1,806` 个 CPU vertex，双向字节为 `36,504/43,344 B`，耗时 `0.158/0.148 ms`。原始日志为 `logs/e2c_persistent_20260805/wiki_b2_fixed.log`。

该结果只通过 E2-C 的 state-lifetime 与通信复杂度子 gate，**E2-C 尚未完成**。当前 deletion invalidation 和 affected pull-relax 仍由 GPU 产生，CPU owner 只在 repair 静止后接收自己的最终状态；因此不能声称 deletion/insertion 已统一为 owner-local repair，也不能把约 73 ms 旧 gather 的消失单独作为论文贡献。下一实现必须让 deletion pull/replacement-parent search 按 destination owner 执行：CPU-owned affected vertex 在 host reverse index 与持久 CPU state 上闭包，GPU-owned affected vertex在 device 闭包，跨域只发送 invalidation/repair request 和归约 distance proposal，并用双向 credit 守恒终止。该 gate 通过前不启动 E3，也不做性能 sweep。

E2-C owner-local deletion repair（2026-08-05）：上述 destination-owner gate 已实现。GPU affected pull kernel 接收冻结的 vertex owner map，并拒绝处理 CPU-owned destination；CPU 从同一 dynamic reverse index 对 CPU-owned affected vertex执行 replacement-parent pull closure。每个 repair credit cycle 中，GPU-owned destination先在 device 到本域静止，随后只 gather 可能进入 CPU affected destination 的 GPU source state；CPU 域在 host 到本域静止后，仅将 changed CPU state稀疏发布给 GPU。CPU 没有新提交时，说明两域均已消费最新跨域状态并终止。旧的“GPU 完整 repair 后 reconciliation CPU mirror”路径已删除，不再存在第二套 deletion state producer。

Wiki METIS map 连续两个 mixed batch 均通过 deletion-stage、batch 和 final Bellman，distance checksum 与前述持久状态版本完全一致。CPU deletion relax 为 `1,420/1,814`，domain cycles 为 `4/3`，CPU dirty scatter 为 `1,404/1,789` vertices；repair boundary bytes 为 `9,315,552/10,980,720`。Twitter/Friendster 分别与同次 all-GPU b1 对照，distance checksum 完全一致，deletion-stage/final Bellman 均通过；CPU deletion relax 为 `639/2,734`，domain cycles 均为 `3`，boundary bytes 为 `738,000/12,690,720`。全量 build、4/4 CTest 和 `git diff --check` 通过。原始记录为 `logs/e2c_persistent_20260805/wiki_b2_owner_delete.log` 与 `logs/e2c_fs_tw_20260805/`。

E2-C 至此通过 mixed deletion/insertion 的 owner-local correctness substrate gate，但还没有通过端到端性能 gate。单次 correctness cohort 中，Twitter domain/all-GPU 为 `215.584/203.333 ms`，Friendster为 `783.028/613.570 ms`；这些不是正式性能统计，但已显示当前同步 credit cycle有明显实现税。主要原因不是重新出现 `O(|V_cpu|)` state copy，而是每个 cycle 重发完整的跨域 repair-source集合，并串行执行 GPU closure、D2H、CPU closure、H2D。下一步进入 E3 时必须将其替换为 changed-source boundary queue：每个 owner只发布本轮真正 changed 且具有跨域依赖的 source，CPU worker、GPU stream和双向 slab异步推进，以 credit/event 守恒判定 quiescence。禁止通过调整 cycle 数、batch 阈值或按图关闭 CPU 来掩盖该结构成本。

对 Twitter 的含义保持不变：其 METIS successful boundary/internal 为 `1.129`，在消除全量 state copy 后仍必须由 E4 解析成本比较 `removed GPU service`、CPU local service 和双向 boundary；若收益不覆盖边界成本，通用规则输出 all-GPU 或更小 CPU quota。不能为了“让 CPU 必须参与”而强行接管固定比例，也不设置 Twitter 数据集特例。

#### E3：异步双执行器与边界消息通道

E2-C 的结果要求 E3 先改变消息复杂度，再实现执行重叠。当前正确版本每个 deletion domain cycle 重发完整跨域 repair-source 集合：Wiki 为约 `9.3-11.0 MB`，Friendster为 `12.7 MB`，且 GPU closure、D2H、CPU closure、H2D 串行。这不是 memcpy 常数问题，而是同步 cohort snapshot协议导致同一未变化 source被重复发送。E3 的核心研究问题调整为：**能否用因果状态变化事件驱动两个 owner-local fixed point，使每个跨域状态版本至多发送一次，并让全局同步次数从 domain cycle数降为一次 quiescence detection。**

E3 按两个不可颠倒的子阶段实施。

**E3-A：因果 changed-source boundary propagation。** 初始化时由冻结 domain map和权威拓扑构造跨域 dependency index：只记录具有跨域 outgoing dependency的source及其目标owner，不复制完整adjacency。一个owner提交vertex新状态后，仅当该vertex的authoritative version增加且具有跨域依赖时产生 `<source,state,parent,epoch,version,event_kind>` 事件；sender先按 `(target owner,source)` 保留最新版本，receiver再按destination执行min-reduce或invalidation coalescing。插入事件保持单调 `min`；删除分成 invalidation和replacement两类有序事件，同一vertex的replacement必须依赖对应invalidation credit，不能把非单调repair伪装成普通proposal。receiver消费source event后在本地dependency index展开跨域入边并激活owner-local queue，因此线上通信量取决于changed cross-domain sources/invalidations，而不是affected cohort、全体cut edges或domain cycle数。

E3-A 保留同步执行顺序作为 correctness oracle，但删除 E2-C 的“每 cycle gather全部GPU repair source”生产路径；不能永久保留snapshot和event两套dispatcher。E3-A gate：三图mixed correctness与E2-C checksum/Bellman一致；每个 `(epoch,source,version,target)` 事件最多被接受一次，stale/duplicate可检测且credit最终守恒；Wiki/Friendster deletion boundary bytes和重复source records相对E2-C显著下降，并证明下降来自事件复杂度而不是更小packet、阈值或丢消息。若changed-source事件数仍接近完整跨域dependency cohort，说明当前domain cut对mixed repair不成立，应交给E4结构成本判定，而不是压缩record格式。

E3-A 首轮实现（2026-08-06）：deletion repair kernel 现在输出本轮真正 changed 的 GPU vertex queue；同步 oracle 在 epoch 开始只为受影响 CPU destination 发布一次 dependency invalidation source 集合，后续 cycle 只发布同时满足“authoritative state changed”和“具有 CPU affected dependency”的 replacement source。事件携带 `epoch/version/kind`，sender 按 source 去重保留最终状态，receiver 拒绝非递增版本，并显式核对 sent/accepted/rejected credit。E2-C 的每 cycle 全量 `m_gpu_repair_incoming_sources` gather 已被删除，不再存在 snapshot/event 双生产路径。

Wiki METIS map mixed b1 `check=true` 已通过 deletion-stage、batch 和 final Bellman，最终 distance checksum 仍为 `17090313294947580515`。该 batch 的 deletion boundary 从 E2-C 的 `9,315,552 B` 降为 `93,672 B`，共发送并接受 `3,903` 个 source-version event，`stale_or_duplicate=0`、`outstanding_credit=0`；CPU affected relax 为 `1,432`，同步 domain cycle 仍为 4。全量 build、4/4 CTest、定向 owner smoke 和 `git diff --check` 通过。

E3-A 跨图 gate（2026-08-06）：`scripts/temp_scripts/run_e3a_fs_tw_correctness.sh` 在同一 V100 上顺序执行 all-GPU/domain mixed b1 对照，原始记录位于 `logs/e3a_fs_tw_correctness_20260806_131625/`。Twitter 和 Friendster 的 deletion-stage、batch、final Bellman 全部通过，domain distance checksum 分别与 all-GPU 一致为 `18038659416545880558` 和 `1350487882132001113`。Twitter boundary 从 E2-C 的 `738,000 B` 降到 `27,168 B`（`-96.319%`），发送/接受 `1,132/1,132` 个事件；Friendster从 `12,690,720 B` 降到 `249,528 B`（`-98.034%`），发送/接受 `10,397/10,397` 个事件。两图均为 `stale_or_duplicate=0`、`outstanding_credit=0`，证明下降来自 changed-source/version 事件复杂度，而非缩小 packet、阈值或丢消息。

E3-A gate 至此通过，允许进入 E3-B。同步 oracle 的单次 paper time 仍慢于 all-GPU：Twitter `231.453 vs 202.656 ms`（`+14.21%`），Friendster `735.535 vs 672.315 ms`（`+9.40%`）；当前 3 个 domain cycle 仍串行执行 GPU closure、event D2H、CPU closure和state H2D。因此 E3-B 的性能命题保持为删除 cycle 级全局 barrier并形成 useful-service overlap，不能把 E3-A 的通信降幅直接表述为端到端加速。

**E3-B：无全局轮次的异步双执行器。** 只有E3-A gate通过后，CPU才使用load阶段创建的persistent worker pool和owner-local region queues，GPU使用独立compute/communication stream；两个执行器通过有界epoch channel消费changed-source event，并各自在本域连续执行local closure。双缓冲pinned arena和复用event只承载已冻结消息语义，不能作为主要收益来源，也不预设persistent GPU kernel；只有profiler证明kernel launch仍占异步critical path，才另立工程收尾。

异步终止采用带epoch的分布式credit：产生local work或boundary event必须转移credit，消费后只有在未产生后继工作时归还；coordinator在CPU queue、GPU queue、双向channel、device event和outstanding credit全部为零，并连续两次观察epoch稳定后宣布quiescence。不得使用固定轮数、定时空闲窗口或最终全图sweep。旧epoch必须在owner迁移前drain，不能静默丢弃或应用到新owner。

E3-B gate：时间线上必须出现CPU/GPU重叠useful-service，而不只是线程存活；相对E3-A同消息协议的同步版本，global domain barriers从每cycle一个降为batch末quiescence，critical-path idle显著下降。报告processed internal edges、被替代GPU edges、local closure depth、changed-source/invalidation、发送与接受版本数、coalescing ratio、在途峰值、credit、queue idle、barrier和overlap。不得通过增加常驻GPU state、扩大staging或按数据集设置flush threshold换取收益。

E3-B1 负结果（2026-08-10）：尝试了“常驻单 CPU worker + 每 event epoch 与 GPU local closure 并行 + epoch 末 join/exchange”的最小重叠版本。三图 mixed b1 correctness、distance checksum和credit均通过，且时间线证明 useful-service overlap真实存在：Wiki CPU/GPU/overlap为 `4.511/32.724/4.080 ms`，Twitter为 `1.390/4.715/1.181 ms`，Friendster为 `12.351/9.062/6.726 ms`。但 join仍是全局barrier，并把因果传播切成更多epoch：Wiki由E3-A的4 cycle增至6，Twitter/Friendster由3增至5；事件分别增至 `4,219/1,369/10,788`。paper time为Wiki `473.151 ms`、Twitter `234.604 ms`、Friendster `819.380 ms`，相对E3-A同步oracle的 `445.472/231.453/735.535 ms` 全部退化，Friendster退化约11.4%。

因此否决“先并行、每轮join”的过渡架构，相关worker、日志和dispatcher改动已从生产代码删除，不保留开关。该结果进一步收紧E3-B实现条件：CPU executor、GPU executor和双向channel必须独立推进；事件接收只能激活目标owner的本地queue，不能要求另一个owner在同一epoch结束；coordinator只允许在batch末执行两次稳定观测的quiescence判定。下一实现直接建立有界MPSC channel、独立credit和非阻塞executor状态机，不再以domain cycle为调度单位。

E3-B2 协议基座（2026-08-10）：新增算法无关的 `dual_domain_event_runtime`，按双owner单生产者/单消费者语义提供两条独立的有界lock-free SPSC ring，而不是共享锁队列；CPU->GPU和GPU->CPU分别持有event credit，事件在进入可见ring前先保留credit，满队列时原子回滚。source-version gate显式绑定单调epoch，按source惰性记录版本，拒绝旧epoch、重复版本和倒退版本，不需要每batch清零全顶点数组。quiescence coordinator同时检查两域local-work credit、双向event credit、两条channel和全局sequence，只有连续两次无状态变化的空观测才允许结束epoch；新epoch启动前强制旧epoch完全drain。

该组件通过容量背压/FIFO、epoch drain、version reject、credit underflow和双向并发测试；两个真实host线程各发送并接收50,000个事件，100次压力复跑均无事件丢失、乱序或credit泄漏。全量build和5/5 CTest通过。E3-B2只冻结了最终channel/credit/quiescence语义，尚未把现有deletion dispatcher切换到该runtime，因此E3-B性能与无barrier gate仍未完成；下一步必须将GPU changed queue和CPU owner queue直接接到这两条channel，并删除`domain_cycles`控制循环。

E3-B2 deletion接入与E3收尾（2026-08-10）：owner-local deletion dispatcher已直接接入双向SPSC runtime，旧`domain_cycles`控制循环被删除。CPU与GPU执行器只由local-work/event credit激活，coordinator只在batch末以两次稳定观测判定quiescence；epoch开始先执行一次GPU replacement dependency fence，避免CPU owner消费删除前或中间GPU状态，该fence是单owner局部正确性依赖，不是domain-wide cycle barrier。最初接入在Twitter出现约`316.7 ms` repair wall，定位为每batch构造两套全图version gate和两套全图dependency flag导致的数百MB清零；version gate和affected dependency集合改为稀疏结构后，repair wall降至`7.608 ms`，该失败的稠密路径已删除，没有保留开关。

三图mixed b1均通过deletion-stage、batch和final Bellman，最终distance checksum分别为Wiki `17090313294947580515`、Twitter `18038659416545880558`、Friendster `1350487882132001113`，全部event/local credit和channel均drain，`stale_or_duplicate=0`。原始记录为`logs/e3_close_wiki_20260810_150244/wiki.log`和`logs/e3b_async_20260810_103038/`。时间线均有真实useful-service overlap：Wiki/Twitter/Friendster分别为`1.367/0.242/2.711 ms`；每batch仅保留`global_barriers=1`的最终quiescence。收尾计数在Wiki上报告CPU closure `5`次、`11`个local round、扫描`212,454`条incoming edge，GPU扫描`3,399,291`条，`5,941`个候选source record合并为`5,338`个事件，coalescing ratio `10.15%`，peak inflight `3,882`。`scripts/temp_scripts/run_e3b_async_cross_graph.sh`现在强制检查这些work/barrier/credit字段。

E3的机制gate至此完成：changed-source消息复杂度、无cycle级全局barrier、双执行器真实重叠和分布式终止均已成立；但这不是端到端性能胜出结论。单次同机cohort中，E3-B2相对E3-A的Twitter由`231.453`降至`214.370 ms`，Friendster由`735.535`升至`780.234 ms`；相对all-GPU仍分别慢`5.8%/16.0%`。Friendster主要差距已不在event runtime（`14.907 ms`），而在insertion convergence（domain `193.511 ms`、all-GPU `121.103 ms`）、PMA mutation和incoming materialization。coordinator/CPU idle poll数量保留为诊断，但不继续用packet、线程数或flush阈值微调来证明E3；下一步转入E4，以统一结构成本模型决定all-GPU或CPU domain，接受不合算region被拒绝。

#### E4：消除执行粒度放大后再做结构 owner planner

E3收尾时识别出的两个主要回退是Friendster insertion `converge_ms=193.511`（同批all-GPU为`121.103 ms`）和deletion `MaterializeIncoming=54.713 ms`。更关键的是insertion仍保留13个`DUAL-RUNTIME-ROUND` barrier：每轮实际GPU active vertex只有`8--7,069`，却因partition bitmap调度产生最高约`3.5B`的`active_edge_span_upper_bound`，CPU service通常不足`1.3 ms`却等待GPU `2--9 ms`。以下E4-A/B/C描述保留最初“先依赖结构、再source事件、最后planner”的历史计划及实验记录；两次E4-A2否决后，当前有效执行顺序以本节后面的E4-R为准。

**E4-A：持久owner-local增量依赖图。** load阶段从冻结domain map同时构造：(1) owner-local incoming dependency slices，用于deletion replacement pull；(2)跨域`source -> dependent destination/owner`索引，用于invalidation、replacement和insertion proposal展开；(3)与source-local chunk topology共用epoch的稀疏delta patch。mixed update只为touched source/destination追加或撤销dependency record，并在batch quiescence后回收旧版本，不再对每批affected集合从全局reverse index重新`MaterializeIncoming`，也不复制完整CSR/CSC。

E4-A是数据结构/算法复杂度调整，不是缓存已有结果：同一versioned dependency record必须同时服务deletion和insertion，拓扑mutation、dependency publication和状态事件共享epoch可见性；任何一侧失败都不能退回全量materialization。gate要求三图连续mixed correctness不变，dependency maintenance与读取量按`touched dependency records + affected owner-local incoming edges`缩放，并在Friendster明确消除当前约`54.7 ms`的batch级重建关键路径。若增量维护成本等于或超过materialization，否决该结构，不用arena大小或线程数掩盖。

E4-A1 协议基座（2026-08-11）：新增算法无关的 `PersistentDependencyGraph`，一个 versioned dependency record 同时进入 destination-local incoming slice 与跨域 `source -> destination/owner` 索引。初始图只构造一次；mixed batch 保持 delete-before-add，重复边按 occurrence 处理，删除/追加在同一 pending topology epoch 可见，publish 后只有 completed epoch 才能回收 retired record。batch 在推进 epoch 前完成全部 vertex/owner precondition，非法 mutation 不会留下 pending epoch 或部分 record。定向测试覆盖重复边、missing delete、同 epoch delete/add、owner 校验、跨域展开、publish/reclaim 和失败原子性；全量 6/6 CTest 通过。

E4-A2 首次实现与否决（2026-08-11）：尝试用 load 阶段预分配的 mapped pinned record arena 替换 `DynamicReverseIndex`。每个 destination 持有 versioned incoming linked slice，CPU 与 GPU 读取同一 16-byte `{source,next,born_epoch,retired_epoch}` record；GPU 直接 zero-copy 遍历，batch 只为 touched dependency 退休或追加 record，旧临时 offsets/sources、edge H2D 和对应 device edge buffer在该实验实现中全部删除。同一 pending epoch 承载 delete/add，publish 与 source-local topology 对齐，completed epoch 后同 destination slot 才允许复用；没有新增 GPU edge 副本。

机制与 correctness 成立。Wiki all-GPU/domain、Twitter domain、Friendster domain 的 mixed b1 deletion-stage、batch 和 final Bellman 全部通过，最终 checksum 分别保持 `17090313294947580515`、`18038659416545880558`、`1350487882132001113`。Wiki/Twitter/Friendster affected incoming 分别为约 `182K/15.6K/233.5K`，dependency host read 为 `3.2/0.53/7.27 ms`，三图 repair edge H2D 均为 0、额外 device edge bytes 为 0。双执行域 event credit、channel 和 quiescence 继续守恒。

但该物理结构被 gate 明确否决。Friendster 旧 E3 路径的 `MaterializeIncoming=54.713 ms`、H2D `0.270 ms`、closure `26.280 ms`；linked mapped 路径虽把 materialization/H2D 降为 `7.268/0 ms`，却把 closure增至 `90.818 ms`，repair wall 从 `81.926` 增至 `98.716 ms`。更严重的是 903,040,059 条边需要约 1,015,920,066-record arena，load build 为 `230.0 s`，进程 RSS 峰值约 `78 GB`；大工作集还破坏 deletion-stage audit 和后续阶段局部性，单次 `check=true` paper time 达到 `2321.329 ms`，相同 E3 cohort 为 `780.234 ms`。Twitter/Wiki 初始化 build 也分别约 `38.6/19.6 s`。收益没有覆盖增量维护、随机 zero-copy traversal 与部署内存，因此不能以 arena、prefetch、线程数或关闭 audit 掩盖。

否决后 linked mapped store、kernel 和 production dispatcher 已删除，生产恢复 E3 唯一 `DynamicReverseIndex` 路径；负结果保留于 `logs/e4a2_smoke_20260811/`、`logs/e4a2_cross_graph_20260811_152451/` 和实验脚本。E4-A 仍未完成，也不得进入 E4-B。下一版 E4-A2 必须改变物理布局而非调 linked store：owner-local incoming 应为 destination-local 连续 chunk/slab，GPU 对 logical incoming 做合并访问；version/tombstone 只进入 touched destination 的稀疏 delta，batch quiescence 时在本 destination compact/COW，不能为每条静态边常驻 16-byte version metadata。目标常驻 host bytes 应接近 `4 * |E| + O(|V| + delta)`，跨域 source index只保存 cut record；同一 record identity仍服务 deletion/insertion epoch语义。只有同时消除 Friendster约54.7 ms materialization、保持 closure接近旧连续slice、RSS显著低于此次78 GB并通过三图连续mixed gate，E4-A才可完成。

E4-A2 连续 chunk 原型（2026-08-11）：冻结静态 load `capacity=degree`；只有 touched destination 扩容时使用 `max(required, ceil(old_capacity * 5/4))` 并向上对齐8条边，空 destination 首次分配保持 exact-sized。GPU 映射冻结为一个warp处理一个 affected destination，lane按32步长读取同一连续 incoming chunk并做warp reduction，128 threads/block即每block四个destination。定向测试覆盖1000度扩容、8-edge alignment、整批arena预检失败原子性、epoch退休/精确尺寸复用和mapped descriptor/slab的CPU/GPU结果及处理边数一致性。

生产接入前容量投影位于 `logs/e4a2_capacity_projection_20260811/`，投影器为 `scripts/analyze_e4a2_capacity.cpp`。它按真实10个100k mixed batch重放destination degree，并模拟exact-size free-list与batch末回收。Wiki/Twitter/Friendster最终live amplification分别为 `1.079287/1.055020/1.013749`，arena high-water分别为 `294,347,239/247,490,611/952,867,601` edges；计入每vertex 24-byte descriptor后的依赖结构投影分别约 `1.504/1.829/5.386 GB`。因此连续布局通过了相对78 GB linked方案的接入前RSS筛选，但这不是完整进程RSS admission，也没有证明Friendster closure `<54.7 ms`。当前原型尚未接入生产 dispatcher；接入前还必须提供对整个mixed batch统一预检的 deletion-visible/addition-later 两阶段API，避免addition分配失败留下已提交deletion。随后先切CPU owner pull，再切GPU warp kernel，只有三图correctness、实测RSS与Friendster closure gate同时通过才删除 `MaterializeIncoming`。

E4-A2 两阶段事务协议（2026-08-12）：`DestinationLocalDependencyStore` 已拆为 `PrepareBatch -> ApplyPreparedDeletions -> deletion repair -> ApplyPreparedAdditions -> Publish`。prepare从同一mixed batch计算删除后状态和最终状态，并在任何可见 mutation 前预检全部最终COW allocation；删除阶段只在已有chunk内compact，不分配，addition阶段只消费已预检容量。pending期间拒绝第二次prepare、reclaim、越序addition和提前publish；insertion-only、deletion-only、空batch也必须显式走完整状态机并推进同一个epoch。便捷 `ApplyBatch` 仍保留，但内部严格调用上述阶段。定向测试已证明repair窗口只看见删除、不看见新增，以及最终allocation不足时删除仍保持未提交。

CPU owner pull 的生产接入点已审阅：当前 `DynamicReverseIndex` 在load保留完整base CSC，并在每批维护overlay；若第一阶段同时新建连续store而保留GPU旧materialization，Friendster会临时常驻两份incoming（连续store投影约5.386 GB之外还保留旧base CSC），不能把该形态用于RSS admission。下一实现应以显式实验路径完成五点接线：load构造store、batch开始统一prepare、physical delete后提交dependency deletion、CPU pull从chunk读取、addition后提交/publish；GPU仍走旧materialization仅用于隔离CPU正确性。CPU通过后立即切GPU mapped warp并删除旧base CSC，最终RSS只测单结构形态。

E4-A2 连续 chunk 生产实验与否决（2026-08-12）：实验没有保留双CSC，而是load时用临时reverse builder直接填充最终mapped chunk store，builder随后释放；CPU owner pull、跨域dependency扫描和GPU repair均读取同一store，每批旧`MaterializeIncoming`、repair edge H2D及device edge buffer删除。GPU严格使用已冻结的warp-per-destination、lane stride-32连续读；mixed batch严格使用两阶段事务并与source topology发布同一epoch。Wiki/Friendster单batch `check=true` 均通过deletion-stage、batch和final Bellman，最终distance checksum保持 `17090313294947580515/1350487882132001113`。原始日志位于 `logs/e4a2_contiguous_smoke_20260812/` 与 `logs/e4a2_contiguous_gate_20260812/`。

读路径目标成立：Friendster affected incoming约227K，materialization/H2D均降为0，warp closure为 `44.959 ms`，低于旧materialization单项 `54.713 ms`，且显著好于linked mapped实验的 `90.818 ms` closure。依赖store自报resident约 `6.632 GB`；包含临时load builder的保守进程峰值RSS约 `62,711,120 KiB`（约59.8 GiB），显著低于linked实验约78 GB，但仍不是理想常驻RSS采样。

然而完整E4-A gate失败。为保持每边仅4 bytes且不增加常驻position index，delete prepare必须在touched destination连续chunk内定位occurrence；统一20-worker单次slice扫描后，Wiki扫描29.65M edges仍需 `162.088 ms`，Friendster扫描5.04M为 `38.112 ms`。Friendster deletion commit `25.033 ms`、addition/COW commit `64.551 ms`（relocation 4.86M edges），dependency maintenance合计 `127.696 ms`，超过被替换的约54.7 ms materialization；paper time为 `859.891 ms`，相对E3 `780.234 ms`退化约10.2%。因此不能用closure或RSS单项收益宣称通过，也不能继续E4-B/C。生产接入、warp kernel和dispatcher改动已移除，恢复E3唯一`DynamicReverseIndex`路径；连续store、事务/映射测试、容量投影器与负结果日志保留为证据。若继续E4-A，必须先解决record identity定位和COW relocation成本，同时仍满足 `4*|E|+O(|V|+delta)`，不能增加每静态边position/version metadata。

#### E4-R：基于A2负结果重排关键路径（2026-08-12）

两次E4-A2否决表明，原先“先彻底消除reverse materialization，再做exact-source insertion”的顺序不再成立。当前incoming结构同时受三个约束：(1) GPU replacement pull需要destination-local连续布局；(2) 50k mixed update需要按`(source,destination,occurrence)`近似直接定位；(3) 常驻内存接近4 bytes/edge，不允许每条静态边携带position/version。连续packed chunk删除后会移动record，position index随即失效；同步维护index会引入每边元数据、随机写和COW联动；不维护index则必须扫描touched incoming，扩容时还要relocation。linked record满足identity但破坏GPU合并读取和RSS，连续COW满足读取但维护成本超过旧materialization。这个冲突不能靠worker数、增长因子、slab大小或mapped prefetch消除。

因此E4不再把“每批materialization必须为0”作为先验架构要求。真正gate改为完整关键路径：`dependency update + affected incoming preparation + repair closure`必须低于E3对应总成本；只要只处理affected集合、没有完整CSC复制、H2D与device临时空间按affected incoming缩放，紧凑materialization可以保留。结构目标改为immutable sorted base CSC加batch-local sparse counted delta，而不是全动态图packed CSC：base slice在load后不移动；delta只为真实update保存`(src,dst,count)`，删除和重复边由count语义表达；affected destination materialization使用sorted merge/count subtraction，禁止为每个destination构造`unordered_map`。只有delta相对base达到统一结构阈值且amortized compaction通过完整paper gate时，才允许在quiescence执行base rebuild；阈值由delta/base比例和内存硬约束统一决定，不按数据集设置。

新E4采用以下顺序，取代下方旧E4-B/C的不可颠倒关系：

**E4-R1：先消除insertion执行粒度放大。** 该问题不依赖incoming物理结构，且Friendster domain/all-GPU差距为`193.511/121.103 ms`。authoritative source value/version变化后只进入compact source queue；GPU按source-local chunk descriptor展开这些source的逻辑outgoing edge，不再把一个active source提升为整个partition bitmap扫描。CPU继续在同一source-local chunk store展开owner-local source，跨域只发送合并后的`<source,value,epoch,version>` proposal。终止仍使用E3-B2的local/event credit和两次稳定空观测，batch内禁止`DUAL-RUNTIME-ROUND` barrier。

E4-R1 协议与executor基座（2026-08-12）：新增算法无关的`ExactSourceFrontier`，epoch严格递增，按source接受单调version，拒绝stale/duplicate并把同source多次新version合并为一个compact frontier；seal时从authoritative source-local descriptor计算精确logical edge总量。CUDA定向executor使用一个block处理一个source，直接读取`SourceLocalChunkStore`的mapped slab和published descriptor，不构造邻接副本。测试覆盖乱序source、duplicate/stale version、同epoch更高version重新激活、零度source、越界/epoch错误，以及source COW并publish新descriptor后的第二epoch；GPU processed edges与authoritative degree总和及edge checksum严格一致。额外device version gate证明同一source的version 1处理后到达version 2会再次service，旧version和重复event被拒绝，不丢更新。全量10/10 CTest与GPU测试100次复跑通过。该基座尚未替换生产`ExecutePolicy_Converge/PostComputationBW`，下一步先接空CPU-domain all-GPU exact-source runtime。

E4-R1 production基座接入（2026-08-12）：`capacity=0` insertion convergence已在唯一`ExecutePolicy_Converge`入口改为按每个segment的compact active-source worklist发射一个block/source，直接读取已发布的source-local descriptor和mapped slab；不再由partition kernel扫描active source之外的邻接，也没有新增常驻拓扑副本。kernel在提交source state后只累计真实展开source及其authoritative logical degree，成功destination继续进入唯一changed queue。Orkut 0.1k mixed b1 `check=true`通过deletion-stage、batch和最终Bellman，topology stale/hash mismatch均为0；该batch insertion首轮从约457,757条partition span收敛为1个source、2条logical/processed edge，`processed_edges == logical_edges`。全量build、10/10 CTest和`git diff --check`通过。当前仍保留changed-destination驱动的`PostComputationBW`作为下一轮frontier构造，因此本结果只完成R1 production executor基座，不宣称`global_barriers=0`、不宣称R1性能gate完成；下一步必须让changed source/version直接形成下一frontier并删除insertion segment rebuild，再做Wiki/Twitter/Friendster同cohort gate。

E4-R1 direct frontier接入（2026-08-12）：`capacity=0`路径新增两条可交换的device exact-source queue，本轮成功destination直接成为下一轮source payload；轮末只读取compact queue count并交换队列，不再D2H source、不扫描active bitmap、不按dirty destination重建vertex-range segment worklist。Orkut 0.1k连续mixed b10 `check=true`逐batch通过，最终Bellman通过；batch 3和5均覆盖4轮local chain，所有轮次`processed_edges`严格等于实际提交source的authoritative degree总和，`rebuilt_partitions=0`。接入时发现计数器清零曾晚于非默认stream kernel发射，导致仅审计计数出现`processed_sources=0, processed_edges>0`；已将清零移到任何发射之前并增加硬invariant，复跑6 batch未再出现。当前每轮仍通过host读取compact count完成frontier推进，因此准确口径是`partition_rebuilds=0, frontier_syncs=1`，尚不能宣称无轮次同步；initial added-edge seed仍经过一次seed partition rebuild。下一步先把seed直接写入exact queue，再将frontier count/quiescence交给device credit/event runtime，之后才进入Wiki/Twitter/Friendster性能gate。

E4-R1机制收尾（2026-08-12）：added-edge seed在`atomicMin`成功后直接append到复用的combined exact-source queue，initial seed bitmap/partition rebuild已从`capacity=0`路径删除；未新增第三条大容量queue或常驻拓扑副本。后续closure由单次cooperative kernel在device内交换两条queue并以grid-wide因果wave推进，host不再逐轮读取frontier count，kernel只在两条queue都空时结束，batch末保留一次final quiescence sync和双queue drain审计。运行时若设备不支持cooperative launch或occupancy无法形成resident grid则硬失败，不保留旧partition dispatcher fallback。Orkut 0.1k mixed b10 `check=true`逐batch和最终Bellman通过，batch 3/5均为4个local wave，分别处理`5 sources/61 edges`和`8 sources/123 edges`；每个epoch均为`seed_partition_rebuilds=0, host_frontier_syncs=0, final_quiescence_syncs=1`，两条queue和owner/boundary credit最终为0。initial rebuild观测由此前约4.6 ms降至约0.06--0.08 ms。至此R1机制实现完成；该Orkut结果只支撑正确性和执行复杂度，不替代Wiki/Twitter/Friendster同cohort性能gate。

E4-R1代表图gate（2026-08-12）：新增`scripts/temp_scripts/run_e4r1_exact_source_gate.sh`，把`check=true`正确性与`check=false`性能cohort分离，并硬审计每batch恰有一次`seed_partition_rebuilds=0`、`host_frontier_syncs=0`和最终quiescence。Wiki/Twitter/Friendster单batch正确性均通过deletion-stage、batch和final Bellman，checksum保持`17090313294947580515/18038659416545880558/1350487882132001113`；对应closure只展开`129,691/12,440/940,628`条真实logical edge，Friendster为14个device-local wave。10 batch首轮累计convergence为Wiki `5.598 ms`、Twitter `2.545 ms`、Friendster `7.877 ms`，Friendster相对E3 domain `193.511 ms`和同批旧all-GPU `121.103 ms`均大幅下降；initial rebuild累计仅约`0.37--0.41 ms`，R1性能方向通过。

重复性能筛查曾发现Wiki最终distance checksum低概率波动。根因是同一wave中同一destination可被多个成功relax重复append，随后多个block并发执行非原子的`CombineValueBuffer`，旧buffer对应block可能晚写value。生产closure现复用已有per-node epoch ticket做wave-local schedule-once：relax仍全部参与`atomicMin`，但同一source每wave只提交一次，下一wave仍可重新激活；seed使用wave 0 ticket，ticket低16位epoch回卷时稀疏运行之外执行一次数组重置，超过65,535 wave硬失败。修复后三次独立Wiki 10 batch最终distance checksum均为`12884871059933969976`，convergence为`6.006/5.901/5.931 ms`，未牺牲R1收益。原始结果位于`logs/e4r1_exact_source_correctness_20260812_160526/`、`logs/e4r1_exact_source_correctness_20260812_165113/`和`logs/e4r1_exact_source_performance_20260812_165748/`。R1至此通过，可以进入R2；完整paper收益仍待R2/R3和E5同cohort判断。

R1先做算法无关的exact-source executor定向测试，再做all-GPU空CPU-domain接入，最后接CPU owner；不能一步同时修改planner。gate要求每轮/事件的processed edges可由active source degree精确闭合，`active_edge_span_upper_bound`不再参与调度，除最终quiescence外`global_barriers=0`。Friendster insertion convergence必须显著低于当前`193.511 ms`且不显著慢于同runtime all-GPU；Wiki/Twitter checksum与连续mixed correctness不变。若source-local mapped chunk随机读取使实际processed edge减少但wall退化，则R1否决，并把placement作为必要前提，而不是恢复partition扫描。

**E4-R2：优化affected incoming preparation，而非维护全动态packed CSC。** load时构造每destination排序的immutable base source slice；batch delta按edge key聚合signed occurrence count，并为touched destination保存排序后的稀疏条目。materialize只对affected destination执行base/delta线性merge，直接输出最终紧凑sources和offsets；重复边、missing delete和delete-before-add语义与现有`DynamicReverseIndex`一致。第一实现保留repair H2D以隔离CPU merge收益；只有merge达到gate后，才比较(a)紧凑H2D加旧连续kernel、(b)mapped host compact buffer加warp kernel，按完整`prepare + transfer + closure`选择，不预设zero-copy胜出。

E4-R2 sorted base/count delta接入（2026-08-13）：现有`DynamicReverseIndex`已收敛为每destination排序的immutable base slice和batch-local signed occurrence delta。旧materialize为每个affected destination临时构造`unordered_map`；新路径先排序该destination真实delta source，再用双指针按相同source的base occurrence count与signed delta做线性merge，只输出仍存在的唯一dependency source。生产GPU repair继续使用紧凑offset/source H2D和旧连续kernel，以隔离CPU merge收益；新增定向测试覆盖base重复边逐次删除、净删除、新增source、missing delete、delete-before-add抵消和重复insert。日志新增`base_edges_scanned/delta_records_scanned/merge_output_sources`，机制工作量可直接闭合，没有per-destination hash、全图清零或每静态边新增metadata。

三图单batch`check=true`均通过deletion-stage、batch和final Bellman，checksum保持Wiki `17090313294947580515`、Twitter `18038659416545880558`、Friendster `1350487882132001113`。Wiki扫描`185,160 base + 1,555 delta -> 183,605 output`，materialize由历史约`24.312 ms`降至`5.977 ms`。Friendster扫描`234,310 + 3,025 -> 231,285`，`prepare/H2D/closure=7.097/0.258/4.299 ms`，合计`11.654 ms`，显著低于E3 gate基线`81.263 ms`；旧同类路径单batchmaterialize约`47.097 ms`。Friendster 10 batch累计扫描`2,695,263 base + 31,591 delta -> 2,665,052 output`，delta每批约`3.0--3.4K`未随累计update失控；累计`prepare/H2D/closure=193.534/2.921/51.039 ms`，平均完整关键路径约`24.75 ms/batch`。load-time base排序使Friendster reverse build约`40.8 s`，作为初始化代价保留报告，不移入paper timer。原始结果位于`logs/e4r2_sorted_merge_wiki_20260813_095642/`、`logs/e4r2_sorted_merge_twitter_20260813_101610/`、`logs/e4r2_sorted_merge_friendster_20260813_095928/`和`logs/e4r2_sorted_merge_friendster_b10_20260813_100837/`。因此R2的紧凑H2D方案通过机制与性能gate；mapped host compact buffer不再是完成R2的前置条件，后续进入R3 owner planner。

R2 gate分两层。机制gate要求工作量为`sum(base degree of affected destinations) + affected delta records + output incoming edges`，无per-destination hash、无全图清零、无每静态边新增metadata。性能gate要求Friendster `prepare + H2D + closure`显著低于E3的约`54.713 + 0.270 + 26.280 = 81.263 ms`，且batch delta maintenance加进来后仍低于该基线；Wiki/Twitter不得因排序merge显著回退。若R2失败，保留E3 reverse路径并接受deletion不是当前可优化项，不能再次尝试linked或destination COW变体。

**E4-R3：最后做owner planner。** 只有R1通过且R2通过或被证明不是端到端瓶颈后，才标定planner。planner先比较同一exact-source runtime下的all-GPU、edge-cut、placement-only和完整模型；输入仅含exact source-edge volume、跨域event volume、degree irregularity、host/GPU residency、dependency prepare成本和内存硬约束。允许三图全部选择all-GPU；若CPU owner不能降低关键路径，则删除CPU propagation路径，而不是调低boundary权重保留研究假设。

E4-R3-A成本判定基座（2026-08-13）：新增算法无关的`OwnerCostPlanner`，候选显式携带exact CPU/GPU source-edge volume、boundary event、affected dependency prepare、topology delta、host-resident placement、migration和memory eligibility；唯一总成本严格为`max(cpu,gpu)+event+dependency+topology+placement+migration`，内存只作硬拒绝条件。定向测试证明：(1)CPU work只有真正缩短GPU关键路径且收益覆盖boundary/placement时才会胜出；(2)高boundary候选自然退回all-GPU；(3)memory-ineligible候选不能通过调权重获选；(4)无合法候选和非法synthetic rate硬失败。审阅同时确认旧`capacity>0`生产路径按本批added-edge seed数重新排名segment，属于近期frontier驱动，不能作为R3 planner；外部`sssp_cpu_domain_map`也只是实验输入而非统一决策。下一步必须用静态候选map结构量和synthetic CPU/GPU/event calibration填充四类候选，先shadow比较预测与同runtime cohort，再允许选择结果接管owner map；在此之前不把任意吞吐常数写入生产，也不宣称R3完成。

E4-R3-B synthetic calibration与shadow候选（2026-08-13）：新增独立CUDA calibration，统一测量CPU exact-edge loop、GPU atomic relax edge和boundary event写入吞吐，不从真实图paper time反推参数；GPU1本次标定为`CPU 383,993 edges/ms`、`GPU 29,843,352 edges/ms`、`event 1,105,728 records/ms`、host placement `2.604 ns/edge`。shadow evaluator读取同一标定文件、冻结METIS topology TSV和E1 exact work TSV；exact execution使用`cpu_scan_edges/share`还原，不用全图静态edge冒充active work，静态domain大小只保留给memory eligibility。四类结果中edge-cut和placement-only是消融解释，正式winner只在可部署的all-GPU与full之间选择；dependency/delta使用R2工作量并作为两种可部署方案共有成本。

同一模型输出Wiki `all-GPU 0.503/full 0.857 ms`、Twitter `0.056/0.097 ms`、Friendster `0.674/1.834 ms`，三图均自然选择all-GPU。原因是CPU synthetic throughput不足以缩短GPU exact-source关键路径，host placement再增加成本；不是降低boundary权重或逐图阈值。工具和fixture测试覆盖TSV解析、四候选生成、消融项不能成为部署winner、memory eligibility和all-GPU决策，结果位于`logs/e4r3b_shadow_20260813/`。该结论仍是shadow prediction；下一步R3-C必须用R1/R2后的同runtime all-GPU/domain cohort验证预测，若full实测不能胜出则正式让planner输出all-GPU并删除旧fixed-capacity/近期seed ranking入口。

E4-R3-C 首次实际候选审计（2026-08-16）：按同一二进制、相同 `cache=2`、单个真实 mixed batch 复跑时，Twitter all-GPU exact-source 路径正常完成，`paper_algorithm_ms=150.327 ms`、distance checksum 为 `18038659416545880558`。但现存 `--sssp_cpu_domain_map` 路径仍是 E2/E3 的 partition-round dispatcher，不是 R1 的 exact-source runtime；Twitter METIS full 候选在 insertion 第 6 round 后以 `SIGABRT` 中止，未产生 `[P0-TIMER]` 或最终 checksum。Wiki/Friendster 的对应候选因这一前置失败未继续计入性能数据。日志位于 `logs/e4r3c_runtime_20260816/`。

因此 R3-C 已取消而非“尚待完成”，且当前结果不能被表述为“full 慢于 all-GPU”。失败首先证明旧同步 CPU-domain dispatcher 不能充当 R3 的同-runtime full candidate；禁止为该路径修补 round barrier、capacity 或 source ranking。R3 在 E 阶段以 all-GPU exact-source 作为唯一生产 propagation 路径收口；F1-L 先判断 CPU 能否整段替代 topology/dependency/cache/deletion 服务，F3 才条件式重开 propagation。若 F3 不获批准，删除 fixed-capacity、近期 frontier ranking 和旧 CPU dispatcher，而不是为了补齐 R3-C 扩展一条没有机会预算的路径。

R3完整成本改为：

```text
T_plan = max(T_cpu_exact_source_edges, T_gpu_exact_source_edges)
       + T_changed_source_events
       + T_affected_incoming_prepare_and_repair
       + T_topology_delta_maintenance
       + T_placement_penalty
       + amortized T_owner_migration
```

E4 完成条件同步调整：R1/R2 必须通过；R3-A/B 提供 planner substrate 与否定旧 propagation map 的证据，R3-C 由 F 的任务级真实 crossover 取代，不再要求先实现 CPU full candidate。原“至少两图由 CPU owner 取得统计显著 paper 收益”的条件取消，改由 F1-L/F2 的 critical-path gate 决定保留哪一种 CPU 服务；CPU propagation 只有 F3 通过才重新进入生产。任何失败候选都不作为默认或 fallback 留在代码中。

**旧 E4-B/C 的作用与替代关系（压缩归档）**：旧 B 提出了 source/version 驱动的统一事件执行：owner 在本地队列完成 source-local closure，跨域只发送归约后的事件，以 `logical active sources / logical outgoing edges / processed edges / coalescing / critical path` 取代 partition 数和 edge-span；旧 C 提出了只在初始化或 quiescence 边界选择稳定 owner map、并允许 all-GPU 自然胜出的结构化 planner。它们保留为 E4-R 的设计来源和论文脉络，但具体实施顺序已由 A2 负结果重排：R1 先消除 source-to-partition 放大，R2 再按完整 incoming prepare/repair 关键路径确定 reverse 结构，R3 最后以精确工作量、事件、dependency、placement、迁移与内存硬约束选择 owner。R1/R2/R3 的实现与证据在本节前文，且不允许用 packet 大小、阈值、线程数、CUDA Graph 或 timer 外移替代该结构变更。

#### E5：端到端验收与架构收敛

> **状态覆写（2026-08-17）**：本节原先要求“至少两张图由 CPU owner 取得完整 paper-time 收益并承担不低于 15% propagation edges”。在 R1 之后该门槛与实际 Amdahl 上限不再相称，改由下方新迭代 F 的 critical-path gate 替代。本节保留为 E4-R 历史验收口径，不得作为当前实现顺序或强制 CPU 参与的理由。

正式性能只使用Wiki/Twitter/Friendster 100k，Orkut保留机制诊断；同一用户 `cache=2`、10 batch、current/all-GPU交错运行，先3次screening，候选再5次报告median/p95。all-GPU必须由同一owner/event runtime以空CPU domain表达，不能保留旧dispatcher。主指标仍是完整 `paper_algorithm_ms`，并单独报告dependency delta maintenance、deletion invalidation/replacement、insertion convergence、CPU/GPU logical active sources与outgoing edges、实际processed edges、changed-source boundary、quiescence、planner/migration、cache refresh、CPU RSS和GPU peak。正确性cohort启用 `--check=true`，与性能cohort分开但使用相同算法路径。

迭代 E 的历史 gate（已由 F 覆写）曾要求：

- 三张主图均通过连续 batch 正确性和 epoch/credit 守恒；
- 若R3 planner为某张图选择CPU owner，则CPU必须承担不低于15%的实际propagation/repair edges或replaceable GPU service，且GPU不重复扫描其internal edges；planner选择all-GPU时该条件不适用，但必须由统一成本模型解释，不能人为保留空转CPU域；
- 至少两张主图证明region-local closure折叠了跨域/全局推进步骤：changed-source accepted events显著少于旧snapshot records，batch中除最终quiescence外不存在domain-wide barrier；
- 三张主图的GPU/CPU实际processed edges都能由logical active source邻接量与显式dependency expansion闭合解释，不再以partition edge-span upper bound作为工作量替代；
- 至少两张主图相对 D3 all-GPU 在完整 `paper_algorithm_ms` 上取得统计显著收益，第三张不得显著回退；
- 收益能由 `removed GPU service + removed global synchronization - CPU local service - event boundary - migration critical-path cost` 闭合解释；
- 相同 `--cache` 下 GPU peak 不高于 D3，新增 CPU 内存与初始化 partition 成本如实报告；
- 删除B3 fixed-capacity入口、E2同步snapshot/cycle closure和任何被E替代的dispatcher，只保留一个可由owner map表达all-GPU/CPU-GPU的event runtime。

以下内容明确不属于 E 的主迭代：调整 packet/source 数、增加 degree threshold、单独扩大 CPU 线程数、CUDA Graph/persistent kernel launch 优化、proposal 格式微调、按数据集选择 capacity、把 batch 工作移出 paper timer。这些只能在 E 的架构和算法 gate 已成立后作为独立工程收尾，不能用于证明 E 的科研贡献。

#### 迭代 F：大图任务接管优先的异构关键路径收敛（2026-08-17 起）

F 直接接在 E4-R1/R2 之后，不要求先完成 E4-R3-C。主问题改为：**在 TW/FS/EU 这类大图的真实 mixed batch 中，CPU 能否凭借 host-local topology、update stream 和多核内存带宽，整段接管一种系统任务，使 GPU 不再执行对应全量扫描、publication、状态搬运或稀疏尾部服务，并最终降低完整 batch 关键路径。** CPU 是否维护状态、承担多少边、利用率多高都不是目标；只有删除的 GPU/串行毫秒减去 CPU、边界和版本成本后仍为正，才算协同。

第三方实现只作为机制参考，不作为移植目标：

- `CGgraph-V1.5` 证明真实 frontier 应按 degree prefix-sum 和设备实测服务能力做互斥切分；但其全量 state H2D/merge、固定 active-work 阈值和数据集预跑比例不能进入本项目。
- `GraphBolt/KickStarter` 证明 deletion 可以分成 deleted-parent seed、affected trimming、一次 incoming pull 和后续增量传播；但其 `O(V)` bitset 清零/扫描不能用于大图生产路径。
- `RadixGraph` 证明旧快照可读、新版本日志构造、时间戳可见性和读者退出后回收能够支持读写并发；本项目只借鉴 batch-epoch publication，不接受逐边时间戳、链式全版本或独占全图 snapshot compaction。
- `POEGA` 的高低度划分可作 irregularity 消融，但固定 `degree_limit` 不是 planner，也不能作为 TW/FS/EU 的 dataset-specific gate。

当前不需要继续泛读其他仓库。只有 F1-L 暴露出具体结构缺口（例如 touched-only cache patch、旧版本回收或 affected dependency 表示）时，才围绕该缺口定向检索；禁止先移植完整动态图库再判断是否有关键路径收益。

##### F0-L：TW/FS/EU 关键路径与可接管任务审计

F0-L 不新增执行路径。基于 R1 exact-source all-GPU 和 R2 sorted-merge，在 Twitter、Friendster、Europe OSM 的 100k mixed-update、连续 10 batch 上完成至少 3 组交错重复。主配置使用相同用户指定 `cache`；`cache=0` 只作为同一大图上的 cold/out-of-core 诊断，不进入主 gate，也不使用小图证明 CPU 价值。EU 现有输入位于 `/home/wangshaoyan/proJect/gunrock/examples/data/input_eu_100k.mtx`，对应 update/stream 文件同目录；正式脚本必须通过显式 `DATA_ROOT` 使用，不复制 505 MB 数据到仓库。

每 batch 至少拆分并闭合以下关键路径：deleted-parent seed、dependency invalidation、affected collection、incoming sorted merge、repair H2D、repair closure、PMA delete/add、reverse delta、source descriptor publication、exact insertion closure、hotness/candidate、eviction、cache compact、cache load、final quiescence。子计时与 `[P0-TIMER] total_batch` 的残差不超过 2%，并同时记录 touched sources/destinations、affected vertices/incoming edges、published bytes、cache changed records、GPU kernels/sync 和 CPU worker wall。

F0-L 对每种任务输出：

```text
baseline_window_ms = 当前串行/设备路径从任务 ready 到依赖消费者可运行的 wall
removable_work_ms  = 候选明确删除的 GPU kernel、扫描、H2D 或同步 wall
overlapable_work_ms = 同 batch 内具备版本独立性、可被另一设备覆盖的 wall
headroom_upper_ms  = baseline_window_ms - unavoidable_dependency_fence_ms
```

`removable_work_ms` 与 `overlapable_work_ms` 只解释上界来源，不允许相加充当收益；同一 wall 区间只能归因一次。

F0-L gate：至少一个任务在至少两张大图中占 `paper_algorithm_ms >= 10%`，或单独可形成 `>= 5%` 的保守 net headroom；并且能明确指出 CPU 接管后 GPU 将删除哪些 kernel、全图扫描、H2D 或同步。仅观察到 CPU 空闲、GPU 利用率低、CPU 边量大或某个小 kernel 较慢均不通过。若 insertion closure 仍低于完整 batch 的 5%，propagation 不进入下一主步骤。

##### F1-L：CPU 整段接管 replay 与候选生死门

F1-L 只做独立 replay/benchmark，不接旧 dispatcher。它按 F0-L 的 trace 对以下任务逐项比较当前路径与 CPU host-local 完整服务，优先级固定为：

1. **Topology transaction**：update normalize/deduplicate、PMA source-local COW、reverse counted delta、descriptor patch、cache invalidation record 由一个 batch epoch 事务产出；比较当前串行 mutation/publication 与 CPU 构造加 touched-only publish。
2. **Affected dependency preparation**：CPU 从旧 dependency seed 和新 reverse delta 构造紧凑 affected incoming/witness 输入；只有连同 GPU 端被删除的 materialize/H2D/scan 一起计入，不能只测 sorted merge。
3. **Hot-set/cache patch**：CPU 消费真实 access/change event，维护固定容量 residency 元数据并产出 admitted/evicted/changed adjacency patch；比较对象是被替代的 candidate + eviction + compact + load 完整服务，不能只测 patch memcpy。
4. **Deletion sparse-tail service**：只在同一 TW/FS/EU batch 内按可解释结构类别（affected incoming、degree irregularity、host residency、state transfer）replay CPU/GPU 完整 reduce/commit；禁止按 dataset id、固定 degree threshold 或成功结果反向挑 cohort。
5. **Insertion propagation reference**：仅保留 R1 exact source/version 的 CPU/GPU 同语义 crossover，用于判断是否开放 F3，不阻塞前四项。

每个 replay 必须处理相同逻辑记录和相同最终语义，CPU 使用启动前固定的 persistent worker pool；计入 state gather/scatter、boundary、publication、quiescence、NUMA/RSS 和 GPU 被删除服务。不得用 synthetic edge loop、CPU 只扫不提交、GPU hot 数据对 CPU cold 数据、timer 外预处理或小图阈值作为证据。

统一决策量为：

```text
baseline_window_ms = 当前生产路径在同一 ready/visible 边界间的 wall
candidate_window_ms = CPU 接管后从相同 ready 到相同 visible 边界的 wall
net_cpu_takeover_gain = baseline_window_ms - candidate_window_ms
```

`candidate_window_ms` 已包含 CPU complete service、剩余 GPU service 的 `max()` 关系、boundary/publication、version/reclamation 和最终 fence；不得再把 overlap 作为额外正收益重复相加。

F1-L gate：候选规则不含 dataset id，在至少两张大图上 `net_cpu_takeover_gain > 0` 且重复方向稳定，并保守预测完整 `paper_algorithm_ms` 至少下降 5%，才允许进入 F2。若只有 cache=0 胜出，结论限定为 cold/out-of-core；若只在单图胜出，保留为 workload boundary，不进入默认生产。失败候选立即停止，不调 packet、线程数、degree limit 或 capacity。insertion propagation 只有同样通过该 gate 才批准 F3。

##### F2：胜出任务的 batch-epoch 版本化生产接入

F2 只实现 F1-L 胜出的任务，不预先同时实现所有候选。共同协议是在同一个 mixed batch 的 `[P0-TIMER]` 内保留 `epoch e` 旧 published view，CPU 构造 `epoch e+1` 的 topology/dependency/cache patch，GPU 继续完成被证明可与之并发的旧状态服务；二者完成后一次性发布 `e+1`，repair/insertion 只读新版本。这里不提前执行下一 batch，也不改变结果可见顺序。

版本协议的硬约束：

1. topology mutation、reverse delta、descriptor patch 和 cache invalidation 共享同一 batch epoch，GPU 不得观察半提交邻接。
2. 旧版本至少保留到所有 GPU reader quiescent；按 touched source/group 延迟回收，禁止逐边 MVCC、`O(V)` mirror 或第二份常驻 GPU topology。
3. publication 和 cache patch 按 `touched sources + delta records + changed cached records` 缩放；未变化的 cached adjacency 不 compact、不 reload。
4. 若接管 affected preparation或 deletion tail，authoritative state、witness 和 changed-source event 的 owner/epoch 必须闭合，GPU 不得重复执行 CPU 已接管的服务。
5. 比较必须包含同一代码基座的串行单版本、版本化 CPU 接管和 all-GPU exact-source 对照，所有异步工作在 batch timer 内结清。

F2 gate：TW/FS/EU 连续 10 batch 的 Bellman、distance checksum、tight witness、topology hash 和 epoch audit 全部通过；至少两张大图的完整 `paper_algorithm_ms` 稳定下降，且收益能由 deleted GPU kernels/scans/H2D、overlap wall、patch bytes、changed records 和峰值内存闭合。若只降低子项而 total batch 不降，候选否决，不继续调 allocator、slab、prefetch 或线程数。

##### F3：条件式 CPU propagation/deletion closure（仅当对应 F1-L replay 通过）

F3 才允许 CPU 成为算法状态 executor。它复用 `ExactSourceFrontier`、source-version gate、local/event credit 和 batch-epoch topology view；CPU source 的 traversal、authoritative state 和 local queue必须同 owner，跨域只发送 min-reduced changed-source/witness event。禁止复用 E2/E3 的 segment-round dispatcher、每轮 join、全量 state snapshot、固定 degree split 或 `PostComputationBW()`。

correctness gate 覆盖 CPU-only chain、GPU-only chain、双向跨域 chain、重复/乱序 version、删除 replacement 和连续 mixed batch；性能 gate 使用 F1-L 已冻结的结构类别，并把 F2 版本、boundary 和回收成本计入完整 timer。若真实 planner 选择 all-GPU，则不保留生产 CPU executor，机制测试和负结果留在独立 artifact。

##### F4：收敛与论文决策

F4 只允许三种结论：

1. **CPU 系统任务接管胜出**：F2 证明 topology/dependency/cache 中至少一种 host-local 完整服务降低大图 batch 关键路径；论文主线是 CPU-managed versioned graph service + GPU exact incremental closure。
2. **CPU 算法 closure 也胜出**：在第一项成立或不被其成本抵消的前提下，F3 进一步证明某个可解释 cold/irregular cohort 能删除 GPU critical-path service，保留统一双域 runtime。
3. **all-GPU 算法路径胜出**：F1-L/F2 均不能改善完整 timer；删除生产 CPU propagation/planner 和旧 dispatcher，保留 R1/R2、任务 crossover 与大图负结果作为系统边界。CPU 仍可作为 host topology 的实现细节，但不能宣称异构性能贡献。

共同验收只以 TW/FS/EU 100k mixed-update、相同用户 `cache`、交错重复、完整 `paper_algorithm_ms`、正确性和内存峰值为主；Wiki/Orkut 和小图只作回归，不要求每张图强行存在 CPU owner，也不以 CPU edge share 作为完成条件。

## 11. 实验与验收要求

### 11.1 研究假设

后续实验应围绕以下可证伪假设组织，而不是只报告某组参数更快：

- **A0：结果可信**。连续 mixed batch 的 deletion-stage 和 final state 都满足 Bellman 与 existential tight witness，checksum 可重复；stored parent mismatch 仅作诊断。否则只修 correctness。
- **A1：当前回退可由少数关键阶段解释**。deletion、insertion、cache refresh 的 wall-time 分项可加和，且 deletion 内的 rebuild/invalidation、state D2H、CPU boundary/local closure、commit 和 PMA update 能解释主要成本；否则继续补观测。
- **A2：CPU 机会必须由工作而非设备空闲推导**。只有在主图上同时看到可观 CPU-ready work、CPU 路径的含通信净服务成本，以及 GPU 关键路径可被覆盖，才进入 B。单看 CPU idle、GPU utilization 或某个 kernel 慢都不足以选方案。
- **B/C 条件假设**。B1 先决定 deletion 的合法执行域，B2 只稀疏化胜出路径，B3 再检验 fixed-owner insertion 并发。C 检验一个联合假设：source-local chunked adjacency 能否把 CPU 更新的物理影响限定为 touched sources，并使 GPU topology publication 从 `O(V)` 全量 mirror 变为 `O(touched sources)` 紧凑 patch，且在计入 relocation、cache invalidation 和后续 ZC 扫边后仍降低完整 batch 时间。若只降低 update/s 或 H2D 子项，但端到端成本被 compaction、allocator 或 cache refresh 抵消，则该假设被否定，不转而扩大 CPU ownership 掩盖结果。
- **E：通用 topology-first 事件 substrate（历史，已由 F 收紧）**。E4-R 的 exact source/version 与 affected-only reverse merge 保留；E4-R3-C 已取消，production propagation 暂为 all-GPU，不再以“完成 CPU full runtime”作为 F 的前置条件。
- **F0-L/F1-L：大图任务接管可行性假设**。TW/FS/EU 的完整 paper timer 中必须存在可由 CPU 整段替代或与 GPU 合法并发的 topology/dependency/cache/deletion 服务；收益按被删除的完整 GPU/串行服务计算，不按 CPU edge share、利用率或 synthetic throughput计算。
- **F2：batch-epoch 版本化假设**。若 CPU 构造 `epoch e+1` 的 touched-only topology/dependency/cache patch 与 GPU 读取 `epoch e` 的旧状态服务具有版本独立性，则两者可在同 batch timer 内形成 `max()` 而不是串行和；旧版本只保留到 reader quiescent，禁止逐边 MVCC 和全量副本。
- **F3：条件式算法双执行域假设**。只有对应 F1-L 完整 replay 通过时，CPU/GPU 才共享 exact-source/event runtime；owner-local closure、跨域 changed-source/witness event 和 credit quiescence必须减少 GPU critical path，不能以固定 CPU quota、degree threshold、partition round 或最后全图 sweep制造参与。

## 12. 构建与运行模板

！！！！！！！！！！！！！！！注意，计算资源十分珍贵，不允许中断、影响任何其他用户的GPU进程资源，如果GPU被占用任何空间就不要使用，也不允许多卡并行工作

scripts/temp_scripts可用于放临时的脚本，如果可以用实验脚本取代轮询查看实验状态来省AI调度的token，请你写实验脚本

构建：

```bash
cd /home/wangshaoyan/proJect/C-GpuStreamGraph-CG
cmake --build build -j 8
```

B3.1 同路径 GPU owner plan：

```bash
CUDA_VISIBLE_DEVICES=0 ./build/hybrid_sssp \
  --graphfile=/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/data/input_wiki_50p_100k.txt \
  --format=market_big --weight_num=1 --weight=1 \
  --updatefile=/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/data/update_wiki_50p_100k.txt \
  --update_size=/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/data/stream_size_wiki_50p_100k.txt \
  --source_node=134151 --SEGMENT=512 --n_stream=3 --hybrid=0 --cache=0 \
  --check=true --verbose=false --sssp_max_batches=1 \
  --sssp_cpu_partition_capacity=0
```

B3.1 fixed-owner plan：

```bash
CUDA_VISIBLE_DEVICES=0 ./build/hybrid_sssp \
  --graphfile=/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/data/input_wiki_50p_100k.txt \
  --format=market_big --weight_num=1 --weight=1 \
  --updatefile=/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/data/update_wiki_50p_100k.txt \
  --update_size=/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/data/stream_size_wiki_50p_100k.txt \
  --source_node=134151 --SEGMENT=512 --n_stream=3 --hybrid=0 --cache=0 \
  --check=true --verbose=false --sssp_max_batches=1 \
  --sssp_cpu_partition_capacity=2
```

Friendster 当前建议主配置：

```text
--cache=2
--sssp_cpu_partition_capacity=0  # unified runtime GPU owner plan
--sssp_cpu_partition_capacity=2  # B3.1 fixed-owner screening plan
```

cache3 在 V100 16GB 上 Friendster 目前会 OOM，不作为主配置。
