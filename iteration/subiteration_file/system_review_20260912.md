# 系统与后续迭代复核（2026-09-12）

本次依据当前工作区实现、I13--I17 记录、I17-B5 各候选报告，以及 `logs/i17_scaling_20260911/{experiments,supplement}/results.json` 静态复核。没有启动 GPU 实验、重跑测试或修改生产代码。工作区有大量未提交修改，当前源码与实验冻结二进制不能默认等同。

结论：保留 CPU-authoritative source-local topology + GPU 增量计算主线，但后续队列需要实质调整。优先补齐实验解释与运行时契约，然后处理 FS 显存峰值和路网插入跨波重复工作。不能继续把 I18 仅定义为 ordered 接入，也不能把普通 frontier 去重当作尚未实现的机制。

## 1. 当前系统定位

实际主线是 CPU 维护动态拓扑、GPU 执行 SSSP，而非 CPU/GPU 平分 propagation。CPU source-local 更新、有效记录归一化、destination reverse overlay、稀疏 publication 构成数据侧；GPU 删除失效传播、affected repair、added-edge seed 和 exact-source insertion 构成计算侧。mixed batch 仍保留删除中间态和随后插入两个阶段。

I12 最终态事务语义成立但性能 gate 未通过，I13 恢复两阶段路径；I14 的有效更新共享保留；I15 配对纠错保留，CPU treap 候选否决；I16 CPU 路网执行器退休；I17-A/B 的 GPU ordered/compact 获得机制及成本证据。B5.4.3 的 reverse 分片保留人工开关，B6 提前完成 ordered 删除实验性运行时接入。

这里的 CPU 路网执行器退休不等于整个 framework 中所有历史 CPU owner 分支均已删除。现代码仍有 CPU ownership 配置和分支，ordered 显式拒绝 owner-local repair/component trace。后续应列清支持的参数组合；无需为本轮分析做广泛清理。

研究贡献应围绕更新局部性、拓扑发布成本和增量传播工作量展开。既有负结果足以支持停止 CPU owner、COW transaction 和 CPU treap 的当前变体；不等于数学上否决所有相关算法。

## 2. 近期实验的有效结论

以下路网时间为同二进制、同输入、两批 `check=false` 的 paper 合计秒数；比较对象为当前 pull。

| cohort | pull | ordered | 加速 | ordered 整个插入阶段占比 |
|---|---:|---:|---:|---:|
| USA 100k | 80.405 | 16.492 | 4.88x | 43.9% |
| USA 1000k | 186.018 | 76.336 | 2.44x | 77.0% |
| EU 100k | 233.636 | 36.374 | 6.42x | 47.5% |
| EU 1000k | 571.462 | 221.641 | 2.58x | 82.3% |

删除有序传播的研究方向成立。四组最终 distance checksum 相同，但本轮只有 USA 100k 另有完整阶段 check=true；EU 和百万档不能凭 checksum 宣称获得同等正确性覆盖。

77%/82% 来自 `stages_ms.add`，包含插入阶段其它工作，不是单独 propagation kernel 占比。优化优先级可以据此转向插入，但还需拆 mutation、publication、epoch/seed 和 closure 的成本。

路网插入的原始计数进一步支持算法工作量是重要候选：USA 1000k 两批 processed_edges 合计约 145 亿，约 3995/3870 waves；EU 约 254 亿，约 7334/7324 waves。波数从 100k 到 1000k 增长不大，处理边数却明显放大，需观察各波宽度和同一顶点跨波改进次数，不能只以减少波数为成功条件。

FS 新同底图 cohort：1000k 的 64/1 分片两批 2.833/3.641 秒，下降 22.2%；100k 为 0.644/0.513 秒，候选本次更慢。旧 cohort 十批 42% 收益有其同二进制证据，但不能与新 cohort 拼接成统一扩展曲线。64 分片仍应是人工候选，不能固定宣称百万更新阈值或所有 FS 100k 都受益。

FS 10000k 默认 cache=2 发生 CUDA OOM；cache=0 两批 check=true 成功，paper 22.609 秒。这只证明减小缓存后的容量可行性，不证明默认配置修复，也不能直接与其它 check=false/cache=2 数据计算公平性能比。

Twitter 新 cohort 原 source=0 只可达自身，原三档传播扩展性结论撤回正确。有效源点 28512093 补测两批为 0.589/4.535/22.722 秒，final reachable 约 23.16M；最大档 check=true 通过。

**但“TW 属于低 repair 占比边界”必须重新修订。** 补测 100k/1000k/10000k 的 repair closure 占比分别约 24.8%/47.2%/12.9%。其中百万档已值得作为单项 ordered/pull 边界短测；占比高并不自动证明 ordered 会赢，需要同时看重复扫描和完整准备开销。有效源点补测只有 64 分片，没有新的 1/64 配对，不应沿用无传播源点结果宣称真实 SSSP 的分片收益。

## 3. 需要修订的实施安排

### 3.1 I17-C 的“完成”超过已展示证据

主计划第 21 行仍称只有 replay，第 95 行称人工判据短测完成，第 106 行又称尚未实现 pilot/生产接入；代码 `framework.cuh:3945` 已读取 `CG_ORDERED_REPAIR` 并进入运行时。

本次查看到的是同状态 ordered/pull 配对及事后解释，没有独立展示“先用 pilot 预测，再在未用于决策的 batch 验证推荐”的记录。当前可标为“人工启用经验建议已有证据，预测有效性未独立验证”。若不再研究预测，应明确缩减 I17-C 目标并据此收口，而非保留原 gate 同时宣布完成。

I18 应改成“实验性运行时契约和资源完善”，因为接入已发生；B6 应写成“删除 ordered 配对与扩展性诊断完成，插入优化尚未实现”。

### 3.2 插入已有普通去重与设备端循环

`framework.cuh:439` 的 `RunExactGpuClosure` 已用 cooperative grid 在 GPU 上循环；第 495--500 行以 epoch/wave ticket 对同波 destination 去重。现有日志也明确 host_frontier_syncs=0、final_quiescence_syncs=1。

因此后续不能再以“增加普通 frontier 去重”“去掉逐轮 host 同步”作为新优化。真正候选是减少距离逐步改善造成的跨波重复扫描，并降低长窄 frontier 的同步/调度成本。跨波重新入队可能是必要工作，不能简单以整批 visited 屏蔽。

优先做插入工作量画像，然后以现有 exact-source closure 为基线验证有序调度或有语义保证的局部闭包。插入没有预先给定的 affected 子图，不能照搬删除阶段的 CSR 构造，也不能把未来会受影响的顶点集合当成免费已知输入。

### 3.3 显存问题应先处理生命周期，再判断表示替换

FS OOM 触发于 `BeginInsertionEpoch` 分配全图 uint32 epoch 数组，约 250.3 MiB。但此前已有 cache、patch staging 和 repair incoming 工作区，失败数组不代表全部根因。

`EnsureGpuAffectedRepairCapacity` 使用按最大历史需求保留的 GPU incoming 缓冲；ordered 的额外缓冲通过局部 RAII 释放，与这份外层缓冲不是同一生命周期。应建立阶段活跃内存账本，核对最后 reader/fence 后的释放或复用机会，计入再次分配的时间成本。

目标是原 cache=2 配置在同等输入上通过，而非靠 cache=0 宣布完成。需要分别报告常驻、活跃、保留容量和实测峰值；不能只求和各阶段独立峰值。禁止未经 reader 生命周期证明便让缓冲别名复用。

ordered 还有每次 `std::vector<uint32_t> local(nodes, UINT32_MAX)` 的 O(V) host 初始化。这不推翻局部边传播收益，但“所有准备成本均按 affected 缩放”的说法不成立。小 affected 是否受其影响应靠画像判断，不立即增加另一套映射结构。

### 3.4 parent 应成为独立契约项

补测 FS 10000k 各阶段 invalid_parent_witness 为 384/374/355/354。距离、Bellman 和 existential witness 通过，不代表存储的 parent 数组是合法最短路径树。

`hybrid_sssp.cu:134` 的 distance-buffer atomicMin 与后续 parent CAS 分开执行，存在 parent 与最终距离配对不一致的竞争窗口。ordered 的 `Parents` 仅重建删除 affected 集，不能修复其它顶点、initial 或后续 insertion 的所有 parent。

parent 参与后续 deletion dependency 判定；但 `driver.cuh:427`、`push_functor.h:1198` 已有非 tight parent 下的 tight-edge 失效防护。因此本次不能断言该诊断已经造成距离错误。

建议明确外部接口是否承诺路径树，以及跨批内部不变量。先用并发竞争和连续删插的小反例验证防护及 witness 更新；若修复，则在每个依赖 parent 的阶段入口前保证契约。全局最终重建可作正确性参照，但只在整个运行结束重建不足以解决跨批状态；全图每批扫描也必须计入成本。增量重建须证明其 dirty 集覆盖未变距离但 witness 失效的顶点。

### 3.5 长传播有显式容量边界

插入 wave ticket 只用低 16 位，host 在 closure 返回后检查 waves > 65535 并 abort。当前 EU/USA 数千波没有触发该边界，但后续长传播实验必须记录它，避免宣称任意直径支持。若调整 wave 组织，需验证票据复用、队列容量与终止条件；可用小型参数化契约测试替代真实超大图长跑。

ordered 当前 SSSP 使用 `(src + dst) % 128 + 1` 权重与宽度 128。相关结论应绑定此权重模型；任意权重、零权和距离溢出边界不应从现有实验外推。

## 4. 建议的新队列

| 顺序 | 任务 | 最小产出与验收 |
|---|---|---|
| I18-0 | 状态和证据口径纠正 | 单一当前状态索引；补测结果回填；修复迁移后的链接；区分 check、checksum、预测验证和容量诊断 |
| I18-A | 运行时 correctness/parent 契约 | 补齐 ordered 接入的小型连续更新反例；明确 parent 防护或修复策略；补一项 EU 代表性阶段检查，必要时后台执行 |
| I18-B | FS 显存生命周期与预算 | 保持 cache=2、同 cohort 的 10000k 容量验证；最后 reader/fence 可审计；所有回收/复用成本进 batch |
| I18-C0 | 插入成本与重复工作画像 | 同波/跨波区分；独立变化顶点、处理边、wave 宽度、closure wall 与 mutation/seed 分拆 |
| I18-C1 | 插入算法候选 | 单因素比较 exact-source 与候选；GPU 工作量及完整 batch 同时改善，必要重新入队不丢失 |
| I17-C 修订项 | 人工建议边界 | EU/USA 作已知正例；有效源点 TW 1000k 作边界短测；若保留预测主张，在另一批验证 pilot 建议 |
| 后续论文项 | 公平外部/原仓库比较 | 复用已有矩阵有效部分；最终冻结机制后补必要同语义配对，不现在恢复长矩阵 |

这是任务分解建议，不代表本轮已实施、启动实验或变更原 gate。若资源只允许一条性能线，显存契约完成后主攻路网插入；reverse/PMA 后端和 hotness 索引不应同时扩大投入。

## 5. 实验方法的最低补强

- manifest 除路径、stat 和 binary hash 外，关联数据生成参数、ID 映射、真实每批更新数、有效源点和输入内容标识；巨大输入可复用生成时哈希，避免重复全量读取。
- 将 source reachability 和实际 affected/processed_edges 纳入实验有效性分类。零工作样本可保留为 topology-only，不能自动当成传播证据，也不要求每批必须有两种非零传播。
- `paper`、外层 repair service、内部 ordered closure、mutation、correctness 开销分别定义；不同嵌套层级不得相加。check=true 的 paper 不能自动当作与 check=false 无扰动等价。
- 路网插入、FS 容量、TW 边界分别验证，不拿图名或更新数作自动启用阈值。
- 保留必要小型随机/定向正确性、队列和 epoch 边界检查；不恢复已暂停的大矩阵，也不把未重复写成稳定通过。
- 性能结论绑定 frozen binary；新改动后只补与改动相关的检查，避免用旧 replay 测试替代新运行时集成验证。

## 6. 文档与论文安排

主计划顶部动态区存在多份冲突队列；补测报告仍停留在“已启动”，但主计划已经写入完成结果；进展汇报仍把旧 I12--I15 事务方案当下一步。若继续追加顶部覆盖声明，读者难以确定哪个 gate 有效。

建议只维护一个当前状态表，把旧队列明确归档，修正迁入 `subiteration_file/` 后仍指向 iteration 根目录的报告链接。论文规划的旧 I15 外部比较编号也应与已完成的 I15 索引负结果区分。

论文正向证据可组织为：source-local CPU topology 减少更新的物理影响；reverse 分片改善大更新量准备；GPU 有序删除减少长传播重复工作。插入优化、默认配置容量解决、通用启用预测和完整 parent 树暂不能写成已完成贡献。两批扩展性短测支持当前机制选择，不足以宣称长序列空间稳态或跨配置通用加速。

## 证据入口

- [实施计划](../cggraph_cpu_gpu_dev_implementation_plan.md)
- [B6 完成复核](i17b6_completed_analysis.md)、[B6 接入记录](i17b6_scaling_ordered.md)
- [reverse 分片](i17b543_reverse_shards.md)、[B5 归因](i17b54_attribution_20260910.md)、[workspace 负结果](i17b5_workspace_screen.md)
- [原实验汇总](../../logs/i17_scaling_20260911/experiments/results.json)、[补测汇总](../../logs/i17_scaling_20260911/supplement/results.json)
- [运行时框架](../../include/framework/framework.cuh)、[ordered 实现](../../include/framework/ordered_gpu_repair.cuh)、[SSSP](../../samples/hybrid_sssp/hybrid_sssp.cu)
