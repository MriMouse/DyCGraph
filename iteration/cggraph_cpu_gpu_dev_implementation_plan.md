# C-GpuStreamGraph CPU-GPU 协同开发实施文档

本文档记录当前 `C-GpuStreamGraph-CG` 中 CGgraph 风格 CPU-GPU 协同机制的可维护规格、关键实验结论和后续优化方向。它同时保留完整的研发时间线：代码细节以当前实现为准，历史迭代用于解释设计选择、实验因果和论文叙事。

迭代计划中说明的方法是我们的预想方法，如果在迭代执行中的实验结果或者某些结论让你发现了更好的方法，可以使用更好的方法进行优化，在完成后报告给我并如实写入迭代计划即可！

如果需要跑>3的实验或者该实验运行时间较长，请让实验在后台运行，确保健康运行后不用一直轮询查看实验状态

> **文档阅读顺序（2026-09-14 整理）：** 本节“当前权威状态”和“迭代论文索引”是接手与写作入口；后文动态工作区、执行计划和时间线保留各阶段的详细问题、方法、实验与负结果，但其中的旧“下一步”不再构成当前任务。逐次试跑和完整 profiler 数据仍以子报告、脚本和 `logs/` 为准。

## 当前权威状态（2026-09-17）

**I25完成，最后尝试未达到明显领先目标：** TW10M reverse并行排序off/on两批完整均值10762.8765→10847.8605ms，回退0.7896%；两对-1.7593%/+0.1723%，checksum和已核对工作计数一致。排序虽减少360.048ms，但后续group/slots/merge成本上升，完整收益被抵消；两次候选均慢于历史原版，未达到10.180058s（历史线快5%）目标。否决该候选作为推荐优化，保持默认关闭；当前没有足够净收益证据启动reverse结构重写或CPU owner。保留I24 publication显式合并，承认目前只有接近历史原版的证据，未证明明显胜出。本轮收口，后台已结束，无新实验。详见[I25完整结果](subiteration_file/i25_reverse_radix_20260917.md)。本条覆盖下方“已启动/性能待结果”状态。

**I25最后瓶颈驱动尝试已启动（用户新授权）：** 用户要求明显领先原版而非仅追平，允许CPU计算/数据组织调整。复核I24：TW10M两批reverse串行destination排序约787ms、Commit约489ms；新增默认关闭的reverse稳定并行radix，复用现有worker池，区别于此前mixed source radix负结果。4项CTest（含66K有效记录reverse集成及500K排序比对）与小图GPU smoke通过；TW10M固定publication merge=1，仅reverse radix off/on/on/off四次后台启动，PID3962971，目录`logs/i25_reverse_radix_20260917/`。采用历史原版快5%即两批10.180058s作为明确开发筛查目标；性能待结果，尚不宣称达标。CPU SSSP owner因没有新净收益预算暂不恢复；后续仅按实测剩余成本决定数据组织候选或承认未胜出。详见[I25实现与计划](subiteration_file/i25_reverse_radix_20260917.md)。本条为当前执行入口，覆盖旧的全面收口和I24唯一下一项状态。

**I24四次已完成并复核：** TW10M publication合并两批完整P0均值11258.968→10685.928ms（下降5.0896%），两对5.2830%/4.8942%，满足本I24两对均改善且均值约>=5%的开发收益条件。排序两批均值575.795→55.381ms；checksum及已核对forward/reverse工作计数一致。候选10719.232/10652.624ms相对历史10715.850ms一高一低，仅均值低29.922ms，记为跨线边界，不宣称正式原版胜出。后台已结束，默认未改，未启动原版新配对或FS/100M。详见[I24结果复核](subiteration_file/i24_tw10m_publication_20260917.md)。本条覆盖下方运行中/尚未运行历史状态。

**I24已执行并进入后台测量（2026-09-17）：** 当前源码构建、4项CTest及同冻结binary三批小图Bellman/首批CPU PQ通过，TW10M固定large/20 workers/NUMA0/reverse64/cache2、关闭bulk/radix/positions/ordered，publication off/on/on/off四次后台配对已启动。PID `3769144`，目录 `logs/i24_tw10m_publication_20260917/`，实时以 `status.json` 为准。runner已显式固定block插入，保留输入/binary指纹、GPU锁、失败停止与checksum Gate；生产默认未改。遵守后台健康确认后不持续轮询约定，完整结果待审阅，不宣称性能达标或正式原版胜出，未扩展FS/100M。详见[I24执行记录](subiteration_file/i24_tw10m_publication_20260917.md)。本条覆盖下方“尚未运行”历史状态。

**当前唯一下一迭代：I24 TW10M publication合并定向确认（2026-09-17，计划已修订、尚未运行）。** 最新尝试、I23百分比纠错、瓶颈证据与机会预算已收拢至[I24计划](subiteration_file/i24_tw10m_publication_20260917.md)。固定20 workers/NUMA0/large/reverse64/cache2，关闭bulk、并行radix、位置复用和ordered，TW10M两批off/on/on/off，仅切换publication合并。直接确认单独合并的10M收益，不再受已失败组合候选的1M Gate阻挡；16GB沿用既有TW同配置成功预算，异常停止而不降cache。区分当前系统收益、低于10.715850s历史目标和正式同语义原版胜出；后三者不能混用。历史全面收口、1M组合Gate强制阻止10M、无条件换更大GPU的条目均不再是当前待办。此次只更新文档，未启动I24实验。

**2026-09-17结果复核与纠错：** 最后四次1M worker筛查全部完成，两批和参考checksum逐项匹配。TW20→32 workers完整P0 1622.023→1558.158ms（-3.94%），FS1749.395→1748.111ms（-0.073%），仅单对。纠正此前I23误报：仅publication合并为-7.63%，合并+bulk为-4.07%，bulk相对仅合并回退3.86%。从1M未过组合Gate推断10M无机会或必需架构重写，证据不足；TW10M历史缺口约0.573s，合并仍有定向验证价值，FS10M约2.183s缺口暂无足够收益证据。当前10M尚未新跑、不宣称胜出，原版共同指纹差异仍须处理。详见[复核修正](subiteration_file/expansion_bottleneck_assessment_20260916.md)。本条覆盖历史过强收口判断；本次未启动新实验。

**最后一轮系统并行度筛查（2026-09-16）：** 用户授权最后尝试，现固定large/publication merge/reverse64/NUMA0/cache2、关闭bulk/radix，在TW/FS1M各比较mutation workers=20/32，共四次两批后台运行。日志`logs/final_system_sweep_20260916/`，PID2793485；结果待收齐，不宣称新算法或正式胜出。见[最后筛查](subiteration_file/final_system_sweep_20260916.md)。

**扩展性瓶颈最终评估（2026-09-16）：** 根据I21/I23完整1M消融、既有TW10M阶段日志和当前代码复核，本轮建议收口，不再声称存在已证实的局部优化可稳定追平原版。当前劣势主要来自source-local CPU mutation的邻接扫描/重写、chunk分配与retire同步，以及effective/reverse preflight和overlay历史增长；publication排序只是可见的次级成本，merge虽有效但不稳定，bulk group完整P0回退。TW1M原路径约1.759s，仅merge约1.625s，merge+bulk约1.687s；10M当前每phase mutation约1.5–1.8s、preflight约0.8–0.95s，不能通过局部计时推断胜出。理论上的reverse分代、分块publication、GPU/NUMA协同拓扑维护属于新架构，需新的容量与语义设计，现有16GB和合法大图证据不足，不继续盲目实现。完整归因见[扩展性瓶颈评估](subiteration_file/expansion_bottleneck_assessment_20260916.md)。

**I23瓶颈驱动的bulk source构建已启动（2026-09-16）：** I21 A+B TW1M四次完成，完整均值下降4.35%、两对1.84%/6.79%，未过Gate，10M未启动。阶段复核发现group仍约67ms/批，publication收益大部分被其他阶段波动抵消，不能宣称B有效。新机制采用count-prefix-scatter并行构建source/groups/phase索引，避免串行逐条追加和扩容；真实TW1M首批CPU物化37.98→11.32ms、逐元素相等，仅为机制探针。4项CTest与实际bulk=1的三批8192更新、六stage独立Dijkstra检查通过。后台TW1M原路径/仅合并/合并+bulk的A/B/C/C/B/A六次两批消融已启动（`logs/i23_bulk_tw_20260916/`，PID2455334）；radix固定串行以隔离新收益。C对A两对均>=5%且C对B两对均改善才进入TW10M同六次配对，最多12次，不自动恢复FS/100M。默认关闭、性能待结果。方法、异常/空间边界与后续裁决见[I23开发记录](subiteration_file/i23_bulk_groups_20260916.md)。本条为当前执行入口，旧队列历史状态保留。

**I21新授权与A+B继续推进（2026-09-16）：** 用户要求继续FS或TW的1M/10M、任一优于原系统即可，并允许实测驱动方法调整。A八次已完成：TW/FS完整两批均值下降5.0865%/4.9995%，各图第二对仅3.5%～3.8%，不写成严格Gate通过；source排序确有约54→4.5ms/批收益，因此保留为显式组合候选继续B。已实现复用mutation worker池的并行稳定source radix，group物化暂不改，默认关闭；4项CTest和小batch GPU smoke通过，后者走串行回退，验证边界如实保留。新后台队列优先TW1M A+B off/on/on/off，两对完整P0均>=5%才继续TW10M同样4次；目录`logs/i21_radix_tw_20260916/`。已提醒10M显存：TW同输入/cache2在16GB既有成功记录且新候选无GPU增量，按本次10M授权沿用该预算，不启动FS10M/100M。性能待结果，不自动宣称优于原版。详见[A+B开发记录](subiteration_file/i21_radix_tw_20260916.md)。此条覆盖文末“A严格过Gate才做B”与无条件迁移更大GPU的旧执行顺序，其余语义与公平比较边界保留。

**I21 FS/TW 1M候选A已实施并启动后台验证（2026-09-16）：** 按文末新规模顺序，新增显式`CG_MERGE_PUBLICATION_SOURCES=1`，将两phase有序changed-source列表线性合并，默认仍为原sort+unique；保留有效变更过滤、epoch及两阶段传播。4项CTest与候选large模式三批GPU Bellman/CPU PQ smoke通过。TW/FS 1M各off/on/on/off、每次两批，共8次后台运行已启动，目录`logs/i21_publication_1m_20260916/`，PID2142409，以`status.json`为准。完整P0收益待结果，不宣称达标，不提前进入B/C或10M/100M。实现、成本及测试边界见[I21候选A记录](subiteration_file/i21_publication_1m_20260916.md)。本条及文末I21/I22新定义优先于历史EU与位置复用队列。

**10M/100M扩展性可行性复核（本轮分析，非新生产迭代）：** 已复核近期阶段日志与当前/原版维护代码，并完成NUMA0真实10M输入的CPU机制实验：稳定并行source radix约408→91ms/批；publication两个有序changed-source列表用线性合并替代重排，TW约335→39ms、FS约554→41ms，输出完全一致。按首批机制结果折算两批预算约1.227/1.660秒，支持TW10M继续追平，FS仍需额外准备成本收益；不是整系统加速。100M仅完成重复记录排序压力实验，尚无合法100M双系统结果；发现24B×B的publication显存预留、固定chunk arena及reverse历史增长的容量边界。生产代码未改，后台微实验均已结束，未启动大图队列。详见[10M/100M深度复核与实测预算](subiteration_file/scaling_feasibility_10m_100m_20260916.md)。

**I22模式优先级最终修订：** 按用户要求消除手动unset负担，`CG_ORDERED_REPAIR=1`现在直接选择ordered插入，不受遗留`CG_INSERTION_SCHEDULE=block/thread`影响；大直径模式始终包括有序删除和有序插入。普通模式才读取显式插入策略，未设置则block。此条覆盖下方历史“显式插入设置优先”的接线说明。运行流程文档同步修订。

**I22大直径模式默认绑定（用户授权实施）：** `CG_ORDERED_REPAIR=1`且未显式设置`CG_INSERTION_SCHEDULE`时，现在默认启用ordered插入，因此大直径模式默认工作包括**有序删除修复＋距离区间有序插入闭包**。普通模式默认block，显式插入策略优先用于消融/回退，batch拓扑维护独立。依据为EU/USA小batch明确收益及FS/TW插入全回退，不按图名或batch规模强制选择。构建及普通默认/大直径默认/显式回退三项两批接线检查通过（小图SEGMENT=32）；小图512分段有序删除的既有配置错误在旧冻结二进制复现并另记，未冒充通过。此条覆盖下方历史“未修改默认入口”状态；实现与验证见 [I22模式绑定](subiteration_file/i22_ordered_insertion_20260916.md)。

**I22适用范围最新裁决：** 24次运行、12对全部正常完成。EU/USA10K/100K完整P0下降24.17%～45.68%，插入下降55.99%～81.83%；FS/TW八组插入全部回退，边工作基本不变，其少数完整P0小幅下降不能归因于ordered。否决全局默认启用，建议并入显式大直径/长传播组合策略，与batch维护模式独立，保留显式覆盖；未实际改动默认入口。按用户要求本轮无正确性检验/交错重复，不据此宣称正式验收。后台已结束，无新任务。详见 [范围结果与整合裁决](subiteration_file/i22_ordered_insertion_20260916.md)。

**I22适用范围筛查已启动（用户最新授权）：** FS/TW/EU/USA各10K/100K，FS/TW各1M/10M，共12组block/ordered各一次、各两批，24次串行GPU运行。明确不做交错重复或正确性检验；小/大batch使用auto维护，组内仅切换插入策略。入口`scripts/run_i22_scope.py`，目录`logs/i22_scope_20260916/`，PID1609502；`status.json`看进度、`report.md`看已完成配对。结果用于判断通用入口还是大直径传播入口，尚未改变默认策略。详情见 [I22适用范围筛查](subiteration_file/i22_ordered_insertion_20260916.md)。

**I22距离区间短配对最新裁决：** EU1M两批block/ordered均正常完成；完整P0 `195.076→42.246 s`（下降78.34%，4.62×），insertion `172.926→20.326 s`（下降88.25%），processed edges `253.66亿→1.081亿`（下降99.57%）。最终距离checksum一致；waves增至22293/22455，pending扫描仍大，收益来自减少重复边松弛。保留显式ordered候选，默认block不改；仅单轮两批，反向重复和EU十批未完成，不宣称历史目标已追平。本次结果审阅未启动新实验，原后台任务已结束。详见 [I22结果与裁决](subiteration_file/i22_ordered_insertion_20260916.md)。

**2026-09-16 I22继续推进（本轮聚焦EU1M）：** I19完成、I20共享规划保留、I21位置复用与I22 thread调度默认关闭；不要求四个缺口同时追平。新候选`CG_INSERTION_SCHEDULE=ordered`在GPU pending frontier上选择固定128距离窗口，延后任务与改善事件统一去重，消除远距离过早反复松弛；不按图名选策略，默认block。首版kernel引用/按值ABI错误已修复，修复后三批六stage独立Dijkstra及final checksum、非对称三批Bellman/删除CPU PQ、默认block回归均通过。EU同cohort两批block/ordered共2次后台配对已启动（`logs/i22_ordered_20260916/`，PID 1447857），收益待结果；未完成EU十批验收，不宣称任何新目标达标。实现、首版失败、验证和实验边界见 [I22距离区间闭包](subiteration_file/i22_ordered_insertion_20260916.md)。

**I22首次短测最新裁决：** EU1M两批block/thread均完成且最终距离checksum一致；thread完整P0 `196.540→359.155 s`（回退82.74%），insertion `173.949→336.081 s`（回退93.21%），边处理仅减2.38%、waves不变。否决此调度候选，保留默认block，不补反向配对；下一候选转GPU距离有序/分桶以削减重复松弛，不做线程粒度扫参。IWB与完整CTA并未被此实验否定。无新增后台任务，I22未完成。详见 [I22结果与机制裁决](subiteration_file/i22_cggraph_scheduling_20260915.md)。

**I22已开始与CGgraph机制复核：** 已核对论文§5.1–5.4和本地V1.5源码，区分论文CTA/IWB与V1.5等边量block/块内scan路径。EU插入每source固定128线程block而历史处理度约2.1，首个候选改为显式thread/source调度；已构建并通过三批小图Bellman，EU1000K同cohort两批block/thread共2次后台短配对已启动。四个目标映射、算法级有序闭包、CPU边级窃取/工作量分块、GPU IWB条件准入和跨域平衡边界见 [I22与CGgraph实施记录](subiteration_file/i22_cggraph_scheduling_20260915.md)。不恢复CPU propagation，不扩大正式矩阵，收益待结果。

**I21短筛查最新裁决：** 4次运行完成，TW/FS10M相对I20 large完整时间仅下降0.76%/0.51%，减少3881万/9691万次mutation读取但forward写入不变；单次微小收益不足以确认保留价值。位置复用保持默认关闭并归档，不追加反向实验；I20共享规划继续保留。下一执行方向转I22 EU insertion，TW/FS缺口仍开放。per-source统计精简已有B5负结果，不重复立项；本次未启动新后台实验。详见 [I21结果与裁决](subiteration_file/i21_delete_positions_20260915.md)。

**2026-09-15 后续用户指令与 I21 开发：** 用户要求直接继续瓶颈优化，不再单独执行大图正确性检查；此要求覆盖旧“先定向正确性验收再继续”待办，不将未运行检查写成通过。I20共享规划候选保留为本轮large基线。I21首个候选改为复用多删除匹配位置、按连续存活区间搬移，避免再次逐边匹配，不引入新GPU邻接布局或整理债务；四项候选及三项关闭对照CTest通过，TW/FS10M各off/on一对、共4次后台性能短测已启动，收益待裁决。依据、成本与状态见 [I21开发记录](subiteration_file/i21_delete_positions_20260915.md)。I22未启动。

**2026-09-15 I20 已开始开发：** 首个候选复用单份 source 规划，并将 forward 有效变更缓冲区交给 reverse 消费，删除重型规划副本和 reverse 输入复制；显式 regular/large 与按 B>=1M 分类的 auto 已实现，开发默认 regular。四项相关 CTest及两项强制 large 验证通过；large 三批 GPU Bellman 和首批 repair CPU PQ oracle 通过，原192批CPU replay→18次GPU队列按用户要求停止，仅TW100K两批CPU oracle完成；首轮4次短筛查完成，TW/FS10M完整两批分别下降5.76%/9.80%，checksum一致；反向4次也已完成，TW/FS两轮均值下降7.36%/9.59%，每轮各自均超过5%开发预算，已审阅并保留候选待定向正确性验收；仍未追平历史目标（按候选均值尚需下降5.07%/15.99%），默认regular不改，无新增后台任务，尚未正式封板；I21/I22 未启动。实施、固定实验顺序与状态见 [I20开发记录](subiteration_file/i20_shared_plan_20260915.md)。

**通信口径修订（2026-09-15）：** 已实现双方共用显式 CUDA payload 包装及原版隔离构建适配，补充进程外整组 PCIe 采样以覆盖 zero-copy，避免 kernel 细粒度插桩。同机 probe 确认可见 ZC，但整体流量仅为粗粒度估计，采样不足时双方统一降级；尚无正式大图通信胜负结论。实现、验证与准入见 §13.2。

**2026-09-15 I19 完成：** FS/WK 固定100K、10%～90%插入的18组十批全部合法，192批CPU双向oracle、18组完整GPU正确性和性能checksum一致性通过；6组GPU规模画像完成，合计42次GPU运行。WK p10→p90 完整十批 `1081.723→796.665 ms`，FS `2591.080→2479.966 ms`；FS hotness/cache等占55%～65%，不能将CPU搬移减少等同完整加速。TW/FS10M两批 `12.078/14.846 s`，grouping+mutation占70.69%/69.46%，仍未达到历史目标。I20选择共享有效变更/紧凑source规划，I21条件性选择限制存活邻接搬移的块级局部重建；暂不立项reverse历史整理。单次筛查、WK60%准备阶段异常及通信未测边界均保留。详见[完整结果与机制裁决](subiteration_file/i19_complete_results_20260915.md)、[全部画像表](subiteration_file/i19_profile_tables_20260915.md)。传输量原系统对比尚未实施。

当前架构为 **CPU source-local topology mutation + GPU SSSP state/propagation/cache**。CPU propagation owner 已退休，但早期 CPU-own 路线形成的 source/state/topology co-ownership、region-local closure、changed-source/version、双向 channel 和 credit quiescence 等研究成果继续保留，详见 E/F 时间线；最终否决的是它在当前真实大图完整 batch 成本下的生产路线，而不是其算法正确性或研究价值。

历史四个整组落后项及最初缺口如下（最新状态见下方 B5 结果，新执行范围见文末）：

| 项目 | 当前/原版 | 追平需下降 | 当前归属 |
|---|---:|---:|---|
| TW scaling 1000K | 5.080/2.242 s（2.27x） | 55.9% | I17-B5 |
| TW scaling 10000K | 23.991/10.716 s（2.24x） | 55.3% | I17-B5 |
| FS scaling 10000K | 18.920/11.468 s（1.65x） | 39.4% | I17-B5 |
| EU 1000K | 1189.302/783.060 s（1.52x） | 34.2% | I17-B6 |

**历史队列（2026-09-14）：I19 → I20 → I21 → I22，当前已由I24接管。** I17 已完成结果保留；其未执行的 B5/B6 后续清单、B7 扩展、I17-C pilot 和 I18 独立收口不再作为未来计划。用户本次明确允许按 batch 规模分类的大 batch 模式，以及 FS/WK 100K 插入比例 10%～90% 的数据生成和适应性验证，覆盖旧的模式/比例实验限制。其他旧正式矩阵不自动恢复。

详细范围与逐批例外见 [最新优化计划](subiteration_file/formal_experiment_optimization_plan_20260913.md)，190 项矩阵结果见[性能大表](subiteration_file/performance_matrix_20260912_analysis/tables.md)。

**2026-09-14 实施进展：** 根据用户本次指令开始开发。B7 已接入可关闭的显式 CUDA payload 计量和阶段/category 归属，计量开关与三批 GPU/CPU oracle 通过；zero-copy 逻辑访问、CPU memcpy 和物理流量仍未测，不将 B7 整体写为完成。B5 的 per-source 统计精简候选在 TW10000K A-B-B-A 中回退，已撤回；保留稳定 radix mixed-source grouping，TW10000K 两批开发配对从 19.030 s 降到 17.603 s（单次下降 7.50%），五项测试及同 cohort 两批完整距离/Bellman 检查通过。四个追平目标均尚未改写为达标，B6 新增插入优化尚未实施。实现、验证和剩余边界见[本轮开发记录](subiteration_file/i17b7_b5_progress_20260914.md)。

**2026-09-14 后续 B5（本次子迭代完成，整体仍进行中）：** 保留 source 已有顺序复用、persistent-worker incoming 物化和 warp 协作 pull 归约。发现未绑定 A-B-B-A 存在明显放置/调度混杂，故双方固定 NUMA 0 作开发配对：TW1000K `3.891 -> 1.809 s`（-53.52%），TW10000K `16.977 -> 11.918 s`（-29.80%），FS10000K `16.948 -> 14.335 s`（-15.42%），均为两批单次配对且 checksum 一致。TW1000K 候选三次 `1.809/1.749/1.812 s`、中位数 `1.809 s`，已低于历史原版 `2.242 s` 目标线，停止该档专项优化；原版未重新绑定/采集，不将此改写成双方同条件三次中位数对照。TW/FS10000K 仍未追平，下一步继续 B5 CPU 公共准备成本，再进入 B6 EU insertion。长行三批 Bellman/CPU oracle、六项相关 CTest、TW/FS10000K 两批全阶段及 final correctness 均通过；stored-parent 仍为既有诊断，未封板。全部实验已结束，无后台 GPU 任务。具体实现、NUMA/affected 口径、混杂结果和剩余差距见[后续 B5 报告](subiteration_file/i17b5_incoming_source_order_20260914.md)。

## 迭代论文索引

本索引保证每个 I 迭代至少保留“解决问题、使用方法、代码位置、关键数据/结论”四类信息。具体实现细节和实验因果仍保留在后文对应小节，不用本表替代正文。

| 迭代 | 解决问题 | 使用方法 | 主要代码/证据位置 | 关键数据与结论 |
|---|---|---|---|---|
| I0 | 旧 deletion repair 错误是否仍存在 | 冻结二进制、最小失败前缀、逐阶段 Bellman/tight witness | `samples/hybrid_sssp/hybrid_sssp.cu`；`logs/large_six_dataset_*` | 旧错误未按原条件复现；建立后续 correctness 基座。 |
| I1 | deletion repair 契约修复 | 仅在 I0 产生稳定新失败时恢复，区分 distance 与 stored-parent race | deletion repair kernels、checker | 条件未成立而跳过；stored parent 只作诊断，distance/tight witness 为硬 gate。 |
| I2 | 六图连续 mixed-batch correctness | deletion-stage、batch、final Bellman 与 checksum 封板 | `hybrid_sssp` checker；I0/I2 日志 | correctness 封板通过，为性能迭代提供可信状态。 |
| I3 | 旧画像受错误和计时口径污染 | 统一 timer、参数与当前/原版基线，重采 TW/FS | `[P0-TIMER]`、性能脚本 | 形成可信生产基线，后续 cache/transaction 候选均以此裁决。 |
| I4 | hotness/candidate 全量刷新成本 | touched-only 事件原型；I4-R 进一步尝试 resident-set delta cache | cache candidate/eviction/compact/load；`logs/i4r_*` | delta 路径 correctness 通过，但 TW/FS `1021.654/6416.829 ms` 明显慢于 I3 `646.987/4210.008 ms`；生产原型删除。 |
| I4-R1--R3 | resident delta 回退归因与清理 | 两段 extent、churn/crossover 审计，失败后恢复单一 cache 链 | cache allocator/publish artifact；`logs/i4r_sanity_20260826/` | FS host plan 达 `750--851 ms`，碎片 gate 失败；清除 allocator/delta runtime，保留负结果。 |
| I5 | source-local topology mutation 串行瓶颈 | source grouping、多 worker touched-source mutation | source-local chunk store、mutation workers | 多核 mutation 工程完成，成为 CPU topology 基础；不扩展为 CPU propagation。 |
| I6 | CPU/GPU topology overlap 是否合法 | 审计版本可见性、reader lifetime、preflight/commit 和 publication | topology epoch/descriptor/reverse index | full dual-version pipeline 没有足够收益证据，未立项生产实现。 |
| I7 | CPU mutation 的资源与真实性 | 记录 touched source、写入字节、relocation、publication 和完整 batch | mutation instrumentation；I7/I8 日志 | 工程工作完成；重复性和因果 gate 转 I8。 |
| I8 | I7 收益是否稳定且由机制导致 | 同 cohort 重复、阶段闭合和机制计数核对 | I8 实验脚本与日志 | 完成 I7 的重复性/因果闭合，批准继续 source-local 主线。 |
| I9 | source-local mutation 剩余关键路径 | 审计 grouping、allocation、copy/compact、publication | chunk store、descriptor patch | 明确只优化能减少完整工作量的部分，停止局部 timer 猜因。 |
| I10 | topology 可见性与资源契约 | 封板 epoch、旧版本 reader、cache invalidation、内存上界 | engine topology publication/cache path | 形成 I12 前的生产基线与唯一资源契约。 |
| I11 | mixed batch 是否可只求最终态 fixed point | 建立 deletion affected、final topology recovery seed 和统一 closure 的可证伪模型 | 事务设计与独立 oracle | 语义模型通过，允许 I12 原型；不等于性能成立。 |
| I12 | deletion/addition 两阶段是否能事务化重叠 | source-local COW next chunks、reverse compact、old-epoch invalidation/CPU prepare overlap、单次 commit/publication、unified closure | transaction/topology artifact；`logs/i12_dev/`、`logs/i13_cleanup_20260906/pre_cleanup.tar.gz` | Wiki/Orkut correctness、22/22 CTest 通过；TW 两批约快 11.6%，FS 仍回退约 5%，双图性能 gate 失败，路线暂停归档。 |
| I13 | I12 失败后恢复干净生产基线 | 删除事务冗余，恢复两阶段 repair，保留 source-local mutation/epoch/reverse/exact-source | engine/SSSP cleanup；`logs/i13_cleanup_20260906/` | 净删 698 行；四应用构建、22/22 CTest、TW/FS 十批 correctness 通过。 |
| I14 | deletion/addition 重复分组和无效更新准备 | `GroupedUpdateBatch` 统一 mixed-source grouping、forward/reverse effective records | grouped update、chunk store、dynamic reverse index；`logs/i14_effective_batch_20260906/` | TW/FS `53.335/414.674 ms/batch`，较相邻诊断基线下降 7.05%/11.15%；保留。 |
| I15 | hotness score/ID 错配及候选全量维护 | 修正配对；以有限分数域 ID treap 离线维护事件索引 | hotness/candidate、`iteration/subiteration_file/i15_event_contract.md`、`logs/i15_candidate_index_20260907/` | 22 个顺序/前缀 hash 与 checksum 通过；十批 treap `11200.956/27544.501 ms`，为预算 62.1/58.9 倍，CPU 索引否决。 |
| I16 | EU/USA 长传播 pull 重复扫描 | CPU PQ oracle、普通 GPU frontier replay、完整 CPU production screening | repair oracle/runtime artifact；`logs/i16_*`、`logs/i17_cpu_retirement/` | CPU PQ 将工作降至有效边量级，但生产状态交接不合算；CPU 路网执行器退休，问题转向 GPU ordered。 |
| I17-A | 无序 pull 的重复 incoming 扫描 | Delta=128 ordered replay、affected local CSR、sparse active-list/bucket | ordered replay；`logs/i17a_sparse_20260909/` | EU/USA sparse closure `1.749/0.726 s`，internal scans 约 `4299/2777 万`，与 CPU oracle 同量级；机制成立。 |
| I17-B | ordered replay 控制同步与空间成本 | device control 合并、selected/deferred 双缓冲复用、host cursor 消融 | ordered compact；`iteration/subiteration_file/i17b_gpu_cost_results.md`、`logs/i17b_final_compact_20260908/` | EU/USA 完整 service 降 11.6%/8.1%，显存减 79.1/47.5 MiB；55 回归、6 memcheck 通过，cursor reuse 否决。 |
| I17-B5 | 大 batch topology/reverse 成本 | phase-active source、radix 候选、reverse destination slots/shards，条件性 PMA | `GroupedUpdateBatch`、`SourceLocalChunkStore`、`DynamicReverseIndex`；`iteration/subiteration_file/i17b543_reverse_shards.md` | FS1000K 64 shards 十批单次对照 paper/reverse 降 42.0%/86.1%，RSS +46.96 MiB；只完成子项，当前继续三个大档落后项。 |
| I17-B6 | 长传播 deletion 后 insertion 成为瓶颈 | ordered deletion 生产实验入口；下一步控制 insertion wave/frontier/edge 重复 | `CG_ORDERED_REPAIR` 路径；`iteration/subiteration_file/i17b6_completed_analysis.md` | EU/USA1000K 两批相对 pull 加速 2.58x/2.44x；EU ordered 后 insertion 占约 82%，当前只继续 EU1000K insertion。 |
| I17-B7 | 缺少完整通信量账本 | 分阶段统计实际 H2D/D2H payload，逻辑 ZC、D2D、CPU copy 和物理互连分列 | `communication_meter.h/.cpp`、batch/stage instrumentation；2026-09-14 开发记录 | 显式 CUDA 拷贝入口已接入并通过基础验证；ZC/CPU memcpy/物理流量未测。观测能力不预设通信落后，不阻塞已有时间瓶颈优化。 |
| I17-C | ordered 是否可人工选择 | 用 repair 占比、`A/E_A/R/Q`、frontier 宽度和完整短配对作建议 | ordered diagnostics/pilot 报告 | EU/USA 为长传播正例，TW/FS 为低 repair 边界；无通用阈值，剩余 pilot 暂停。 |
| I18 | ordered 候选生产交接和边界 | authoritative state、gather/scatter、parent、workspace 生命周期与显式模式 | ordered runtime integration | deletion 已实验性接入；独立收口暂停，未来 insertion 接入并入 B6。 |

### 当前 I17 子任务的代码位置补充

- batch 主循环、paper timer、cache refresh：`samples/hybrid_sssp/hybrid_sssp.cu::HybridSSSP()`；
- insertion convergence：`include/framework/framework.cuh::Engine::update_tree_add()` 与 `ExecutePolicy_Converge()`；
- source-local forward mutation：`SourceLocalChunkStore::ApplyMutationPhase()`；
- reverse preparation/merge：`DynamicReverseIndex`；
- ordered deletion 的 local CSR、bucket、compact queue 和 device control：I17 ordered repair/replay 实现及 `CG_ORDERED_REPAIR` 接入点；
- 具体文件名发生移动时，以相应实验报告记录的冻结源码、二进制 hash 和日志目录为准，不根据本索引猜测实现。

## 动态工作区：当前状态、下一步与维护规则

> **历史区说明：** 本节从 2026-09-07 起连续追加，保留当时的接手状态和实验因果。其旧队列、后台 PID、“下一步”和预计工期均已失效；当前任务只以上方“当前权威状态”为准。

已删除过期接手和恢复后台任务指令；完成结果保留在历史记录和子报告。

### 迭代时间线与状态总表（截至 2026-09-05）

> 状态修订：最新队列为 I14 有效更新批次 -> I15 事件驱动维护 -> I16 高直径 repair。1000k 扩展和论文/外部对照后置；旧编号释义不再作为执行计划。

本表是执行状态的唯一索引；第 10 节保留完整技术历史。状态只依据本文档已经明确写出的完成、跳过、否决或 gate 结论，不以代码工作区或推测补写状态。

| 时间 | 阶段 | 明确状态 | 对后续的影响 |
|---|---|---|---|
| 2026-07-09--11 | 10.1--10.6 packet v1 | 已冻结为消融/负结果 | 停止扩展 CPU-owned packet、source policy 和 packet budget。 |
| 2026-07-12--14 | 10.7--10.9、A--B3 | 已完成，CPU propagation owner 随后被否决 | 保留 GPU affected repair 与 exact-source insertion 的研究基础，不再让 CPU 接管 SSSP propagation。 |
| 2026-07-27--08-20 | C--F 系列 | CPU-authoritative topology 路线收敛；CPU owner/CGgraph frontier 切分终止 | source-local topology mutation、稀疏发布成为生产方向；历史 P0--P5 计划随后被 I0--I15 队列取代。 |
| 2026-08-24 | P0（旧路线收口） | 已完成 | 旧 cache patch 工程收口；不构成当前并行任务。 |
| 2026-08-25 | I0、I2、I3 | 已完成 | correctness 基座与 TW/FS 基线完成。 |
| 2026-08-25 | I1 | 跳过，条件性可恢复但当前不活跃 | I0 未复现旧 deletion repair 错误；只有 I2 出现新的可重复错误才恢复，而 I2 已通过。 |
| 2026-08-25--26 | I4、I4-R1--R3 | I4/I4-R2 否决；I4-R1/R3 已完成 | cache delta 原型已删除，恢复 I3 cache 链；该支线已关闭。 |
| 2026-08-26 | I5、I6、I7 | I5/I6/I7 工程工作已完成 | I5 冻结多线程 mutation；I6 的 full dual-version pipeline 未立项；I7 的研究 gate 由 I8 收口。 |
| 2026-08-27 | I8、I9、I10、I11 | 已完成 | I8 完成 I7 的重复性/因果 gate；I10 封板资源契约；I11 批准进入 I12。 |
| 2026-08-27 以后 | I12 | 已暂停，性能 gate 未通过 | 事务路线转为负结果/边界 artifact；生产性能基线回到 I10。 |
| 2026-09-06 | I13 | 已完成 | 恢复默认两阶段路径并删除冗余事务代码；四应用构建、22/22 CTest、TW/FS 十批正确性通过，各批 distance checksum 与 I10 一致。 |
| 当前及后续队列 | I14--I16 | I14 完成，I15 前置审计，严格串行 | 有效更新批次、事件驱动维护、高直径 repair；由当前子项证据决定准入。 |

### 文档维护

已完成和负结果保留；未执行旧任务不再列为待办，新队列只维护文末 I19—I22。

### I0—I15 已执行研发记录（历史）

以下保留已执行迭代的原问题、实现规格与结果；其中当时使用的步骤是历史实验设计，不构成新任务。未执行路线已从待办移除。

#### I0：冻结证据并建立最小失败前缀（预计半天）

**状态（2026-08-25）：已完成。** 新增 `scripts/diagnose_i0_failures.py` 和 `scripts/temp_scripts/run_i0_failure_prefixes.sh`。解析器准确复原旧日志的 Orkut batch 3/vertex 19948、Twitter batch 9/vertex 8174392、Europe batch 0/vertex 37840449；当前代码新跑 Orkut 4 batch、Twitter 10 batch、Europe 1 batch 均无 `relaxable_edges` 或 `missing_tight_witnesses`，最终 Bellman 通过。旧失败属于修复前证据，不再推导当前代码仍有错误。日志目录：`logs/i0_failure_prefixes_20260825/`。

**目的**：把“十批最终失败”缩成可重复、可逐状态比较的首个失败 batch，避免在 Europe 的长运行上盲调。

**输入证据**：`logs/large_six_dataset_20260824T170000Z/`。首个已知失败点是 Orkut batch 3、Twitter batch 9、Europe deletion-stage batch 0；Wiki、Friendster、R-MAT 是正对照。

**实施**：

1. 新增只读诊断脚本，解析每个 batch 的 delete-stage/batch Bellman、checksum、首个 missing witness、affected 数和 repair 轮数，失败时返回非零；修正现有六图 runner 只统计通过次数、却继续跑完后才判错的问题。
2. 为 `--sssp_max_batches=4` 的 Orkut 和 `=10` 的 Twitter 固化复现命令；Europe 只跑 `=1`。保留同数据、source、`--cache=2`、capacity 0，不更换 cohort。
3. 在首个失败 batch 记录目标点的 batch 前距离、父点、被删入边、所有当前入边及其候选距离，并区分：affected 集漏标、incoming merge 漏边、repair 提前静止、publication/host topology 不一致。诊断仅在 `--check=true` 下启用，不进入性能路径。
4. 用当前 `ChunkStore` 对失败 batch 计算 CPU 参考 SSSP，输出 GPU/CPU 首个距离差异及差异点数。参考结果只作 oracle，不作为生产 fallback。

**交付物**：一个可自动判定首个失败 batch 的脚本；一个受 `check` 控制的 witness 诊断入口；三图各一份最小失败日志和一页根因归类表。

**Gate**：相同命令连续两次得到相同首错 batch/vertex；CPU oracle 与 Bellman 诊断一致；正对照 Wiki 1 batch 不产生误报。若失败点漂移，先按竞态处理并使用 Compute Sanitizer/事件顺序审计，不进入 I1。

#### I1：跳过（历史）

I0 未复现旧错误，I1 未实施；原条件性实施步骤已删除。后续任何新增正确性失败随所属新迭代处理，不能放宽检查。

#### I2：六图 correctness 封板（预计半天 GPU 调度 + 长任务时间）

**状态（2026-08-25）：已完成。** `scripts/temp_scripts/run_i2_six_graph_correctness.sh` 串行执行六图，六图均为 `10/10` delete-stage pass、`10/10` batch pass、final Bellman pass、overall pass，runner 最终状态为 `PASS`。日志与汇总：`logs/i2_six_graph_correctness_20260825/`。当前代码 correctness 基座成立，旧的 2026-08-24 failure 日志只作修复前历史证据。

**目的**：把局部修复提升为当前生产基座的完整正确性结论。

**实验矩阵**：Orkut/Wiki/Twitter/Europe/Friendster/R-MAT，统一 100k mixed、10 batch、`--check=true --cache=2 --sssp_cpu_partition_capacity=0`，串行独占一张 GPU。Europe 使用 symmetric-expanded 99% base 和确定性 `source=1`，不得恢复 1000 轮 cap。

**Gate**：六图每个 batch 的 delete-stage 与 batch Bellman 全过，final Bellman 全过，进程退出码非零传播正确；日志解析器不能再把部分 batch 通过写成整体 correct。Europe 若仅因运行时间超预算而未完成，I3 可先在其余五图进行，但 Europe 状态必须明确写为 pending，不能写作通过。

#### I3：可信基线与决策数据重采（预计 1 天）

**状态（2026-08-25）：已完成。** `scripts/temp_scripts/run_i3_current_baseline.sh` 完成 TW/FS 各一次 correctness 和各三次 `check=false` 性能运行，日志目录为 `logs/i3_current_baseline_20260825/`。TW 性能值为 `597.778/677.466/646.987 ms`，中位数 `646.987 ms`；FS 为 `4209.324/4329.033/4210.008 ms`，中位数 `4210.008 ms`。correctness 与 timer 记录全部通过。TW 离散度较大，I4 必须继续使用交错重复，不能用单次下降宣称收益。

**目的**：I1 可能改变 affected 工作量和时间，旧 P2 数字不能直接作为实现后的基线。本迭代只测量，不优化。

**实验**：

1. TW/FS 先做一次 `check=true` checksum run，再做 `check=false` screening；两种模式的最终 checksum 必须一致。
2. 性能日志继续以 10 个 `[P0-TIMER]` 之和为唯一 `paper_algorithm_ms`，保留 deletion/add/hotness/candidate/eviction/compact/load 以及 mutation/publication/repair 子项。
3. 对 TW/FS 做 `A-B-B-A` 交错，其中 A 为 I1 前提交、B 为修复提交；每项至少 3 个有效 run，报告中位数和离散度。I1 前版本仅在其 correctness 已通过的 batch/图上作性能参照，否则只比较 B 的重复稳定性。
4. Europe 只做一次正确版本画像；其约 `120s/batch` 及更长实测决定是否进入日常性能 cohort，不用它拖慢每次开发循环。

**Gate**：所有日志阶段加和残差可解释且不超过 `2%`；TW/FS `check=true/false` checksum 相同；没有数量级性能回退。输出更新后的阶段占比表，作为 I4/I5 的唯一输入。

#### I4：touched-only hotness/candidate（预计 2--4 天）

**状态（2026-08-25）：语义审计完成，原方案否决，未修改生产路径。** `scripts/audit_i4_hotness_semantics.py` 确认：SSSP hotness 在 GPU successful expand 中递增；每批通过 `hotness[3] <- hotness[2] <- hotness[1] <- hotness[0]` 对全顶点滚动窗口，且 `compute_hot_vertices_sssp()` 对 `0..nnodes` 全量刷新。因此 topology mutation 的 touched source 不是 hotness 的完备更新集，直接做 touched-only hotness 会改变 candidate 顺序和 cache desired 集，不能进入生产代码。该 I4 作为负结果归档。

**路线修正**：不继续设计 traversal-event hotness 索引。当前先保留全量 hotness/candidate，以避免同时改变候选语义和 cache allocator。已有 `cache_patch_replay` 已证明 Friendster batch 3 后每批 resident-set delta 约 `3.4万--9.2万` vertices、`1.8--3.7 MB`，而生产路径仍每批执行全量 compact/load；因此下一迭代只完成 resident-set delta 生产化。

#### I4-R：cache resident-set delta 原型（正确性通过，性能未通过）

**现有证据**：TW 的 deletion/add/hotness 与 I3 基本持平，新增回退主要来自 candidate `195.116 ms`（I3 `42.485 ms`）和 delta publish `294.617 ms`。FS 的非 cache 阶段基本持平；I3 旧 eviction/compact/load 合计约 `1280 ms`，新 fallback rebuild 为 `3439.229 ms`。因此当前问题集中在 cache 实现，不需要改 propagation 算法，也不能用整体噪声解释。

#### I4-R1：回退归因与真实 delta 审计（已完成）

**状态（2026-08-26）：已完成。** 审计日志位于 `logs/i4r1_audit_20260826/`。Twitter resident membership 基本稳定，主要 delta 来自 topology growth 后的 cache invalidation；Friendster 前三批存在真实大 churn，batch 3 后 membership delta 已小但单段 allocator 碎片严重。审计 kernel 本身每批约 `56--86 ms`，仅用于归因，不能进入生产性能路径。

**目标**：只增加可移除计时与 checksum，不改变执行结果；回答“delta 集是否算对”和“时间花在哪”两个问题。

1. 在 `RefreshCache()` 内分别记录 classify、scan/select、record gather、host extent planning、command H2D、command apply、metadata clear 和 rebuild load；GPU 阶段用 CUDA event，host 阶段用 wall timer，全部计入原 batch timer。
2. 每批记录 desired/published/admitted/evicted/invalidated/degree-changed 数、对应 edge bytes、候选 ID checksum 和 resident membership checksum。用现有 trace replay 对同一运行输入逐批核对，解释 FS 线上千万级 delta 与旧离线 `3.4万--9.2万` 的差异；不得默认旧 replay 正确。
3. 复核 TW candidate 从 `42.485` 增至 `195.116 ms` 的因果：区分 CUB 临时存储/同步污染、`d_v/d_sum/d_id.Alternate()` 复用依赖和 cache metadata 对 `search_batch` 的影响。
4. 只跑 TW/FS 各一次 `check=false` 10-batch；若问题在前 2 批已确定，可用 2-batch 开发复现。已有 correctness 证据不重复支付。

**Gate**：新增分项能解释 cache publish 的 `>=95%`；candidate 回退定位到具体同步或数据依赖；线上 delta 与 replay 差异有确定结论。若扣除全部可消除实现税后，TW 仍高于 I3 `+2%` 或 FS 仍无 `>=5%` 理论收益，则跳过 I4-R2，直接进入 I4-R3 删除原型。

#### I4-R2：按证据收敛唯一 cache 实现（已否决）

**状态（2026-08-26）：已否决。** 两段式原型允许 resident 使用 primary/secondary 两段、新 admission 最多分配两段，并回收 topology shrink slack。Twitter 2-batch 与 Friendster 5-batch correctness 通过，日志为 `logs/i4r2_two_extent_20260826/twitter_2batch_correctness.log` 和 `logs/i4r2_two_extent_20260826/friendster_5batch_correctness.log`。但结构复测显示 Friendster batch 3 为 `free_edges=90042, largest_extent=18, plan_ms=750.697`，batch 4 为 `free_edges=8572, largest_extent=2, plan_ms=850.514`，均以 `reason=fragmentation` 回退；证据见 `friendster_5batch_structure.log` 与 `friendster_5batch_shrink_reclaim.log`。继续扩展第三段/page chain 会扩大 metadata 与调度复杂度，且没有通过开发 gate，因此停止该路线。

只允许实现 I4-R1 证明的主要成本，不做阈值 sweep：

1. **小 delta 成立时**：把 delta select、resident metadata 更新和 adjacency copy 保持在 GPU；复用已有 `d_v/d_sum/d_id` 临时区，删除逐批 `cudaHostAlloc/cudaFreeHost`、全量 host extent planning 和一-command-one-block 的低效调度。空间管理采用批量 page/extent 操作，不新增与 `V` 或 `E` 同阶的常驻 GPU 副本。
2. **FS churn 确实很大时**：不强迫走 delta。将 rebuild 实现为一次确定性的 candidate prefix packing，直接从 authoritative chunk slabs 写入 cache，并在同一 kernel/scan 流程生成 `virtual_start/degree/capacity`；删除当前 `ResetCacheForRebuild + legacy LoadCache` 的重复全点遍历。delta/rebuild 选择只比较本批实际 bytes/work，不使用 dataset id 或调参阈值。
3. **replay/线上语义不一致时**：先修 membership epoch/mark 生命周期并补逐批 checksum 测试，再谈性能；不得通过保留 stale cache 或改变 hotness/candidate 排序制造小 delta。
4. 被新实现替代的 `evication_cache/compact_cache/LoadCache` 常态链、重复 kernel 和临时字段语义必须同步删除；内部 rebuild 与 delta 共用同一 metadata 和 publication contract。

**开发 gate**：TW 2-batch cache publish 合计不超过 I3 同批 cache 成本加 `5 ms`；FS 2-batch rebuild 不慢于旧链；candidate 阶段恢复到 I3 同数量级。未达到即停止继续优化数据结构。

#### I4-R3：轻量验收与代码裁决（已完成）

**状态（2026-08-26）：已完成。** 按未过 gate 分支删除 I4-R production prototype，恢复 I3 的 `confirm_candidate_batch -> evication_cache -> compact_cache -> LoadCache` 为唯一 cache 路径；删除 extent allocator、delta audit/publish kernel、两段传播读取和 topology capacity 复用。`hybrid_sssp` 编译通过，`cache_patch_trace_test`、`cache_refresh_gate_test`、`cache_tail_fallback_test` 全部通过。独立审计脚本与日志保留为负结果 artifact，不参与生产构建。

1. 先跑 cache CTest、Wiki 2-batch correctness；再跑 TW/FS 各一次 10-batch correctness 和一次 `check=false` performance，不做收官级交错重复。
2. 保留 gate：TW 不高于 I3 中位数 `+2%`，FS 至少低于 I3 中位数 `5%`，阶段加和闭合，无额外 GPU 峰值，candidate/checksum/cache adjacency 一致。
3. gate 通过：保留 `RefreshCache()` 唯一实现并删除旧 cache 链。gate 未通过：删除 I4-R kernels、allocator 和生产接线，恢复 I3 cache 路径作为唯一实现；只保留独立测试、trace/replay、日志和负结果文档。不得把当前回退原型带入 I5。

#### I5：source-local CPU topology mutation 多核化（已完成）

**I5.1 状态（2026-08-26）：已完成，批准 I5.2。** 在 `ChunkStoreBatchMetrics` 中加入 grouping、prepare、apply 分项，以及 update/source-work 总量和最大 source 工作量；执行顺序与拓扑语义不变。Twitter 2-batch 日志位于 `logs/i5_1_mutation_profile_20260826/twitter_2batch.log`：每个 delete/add phase 均约 `9.9k` touched sources，单 source 最多 `4--7` 条 update；delete 的 `prepare+apply` 为 `11.382/9.698 ms`，add 为 `2.583/2.628 ms`。最重 source work 为 `77.8k`，只占各 phase 总估算 work 的约 `2.5%--2.8%`，没有少数 source 串行主导；publication 约 `2.2 ms`，不属于线程池目标。主程序编译及 `source_local_chunk_store_test` 通过，2-batch 正常退出。下一子迭代 I5.2：固定生命周期线程池并行 prepare/source-local materialize，allocator reservation、epoch commit、retire/reclaim 和 publication 保持 batch 级串行。

**I5.2 状态（2026-08-26）：已完成，保留实现并进入 I5.3。** `SourceLocalChunkStore` 现在持有 20-worker 固定生命周期线程池；deletion planning/final-degree 计算和 source-local compact/rewrite 按 source 并行，allocation preflight、block allocation、epoch/edge-count commit、retire/reclaim 与 publication 仍串行。worker 以 16-source 小块动态领取任务，避免逐 source 原子争用；grouping 改为排序去重 source 后用连续数组索引，去掉共享 `unordered_map` 查找和节点分配，生产代码不保留 selectable serial/parallel 分支。1-worker 与 4-worker 定向测试逐 source 比较 adjacency、ordered hash、degree、version、epoch 和 edge count；三个相关 CTest 全部通过。

Twitter 同参数 2-batch 最终日志为 `logs/i5_2_parallel_mutation_20260826/twitter_2batch_indexed.log`。相对 I5.1，四个 delete/add mutation 合计由 `26.291 ms` 降至 `14.690 ms`（`-44.1%`），grouping 合计由 `9.337 ms` 降至 `7.388 ms`（`-20.9%`），两批 `[P0-TIMER]` 合计由 `103.215 ms` 降至 `90.106 ms`（`-12.7%`）；written bytes、touched/changed sources、missing delete 和 publication records 与基线一致。Friendster `check=true` 2-batch 日志为 `logs/i5_2_parallel_mutation_20260826/friendster_2batch_check.log`：delete-stage、batch oracle 与最终 Bellman check 全部 passed，`gpu_cpu_hash_mismatches=0`。早期逐 source 原子领取日志仅作调优诊断，不作为最终实现结果。

**I5.3 状态（2026-08-26）：已完成，gate 通过并冻结实现。** 使用 `logs/i3_current_baseline_20260825/` 中相同 `cache=2`、capacity 0、10-batch cohort 的三次性能日志中位数作为 I3 基线；I5.3 只执行 Twitter/Friendster 各一次 `check=false` 10-batch，不做重复、线程数 sweep 或 dataset-specific threshold。

| dataset | I3 paper median ms | I5.3 paper ms | paper change | I3 mutation median ms | I5.3 mutation ms | mutation change |
|---|---:|---:|---:|---:|---:|---:|
| Twitter | 646.987 | 565.137 | -12.7% | 218.596 | 106.388 | -51.3% |
| Friendster | 4210.008 | 3923.398 | -6.8% | 853.606 | 208.951 | -75.5% |

原始日志为 `logs/i5_3_gate_20260826/twitter_b10.log` 与 `logs/i5_3_gate_20260826/friendster_b10.log`。两图均产生完整 `10 delete + 10 add + 10 publish + 10 P0-TIMER`，正常输出 `Overall: Test passed`，且所有 publication 的 `gpu_cpu_hash_mismatches=0`。mutation 两图均超过 `30%` 降幅，完整 paper 两图均超过 `5%` 降幅，因此既定 gate 无条件通过。固定线程池、小块动态分发和连续索引 grouping 作为唯一生产实现冻结；不恢复串行接线，不追加参数特例。下一步进入 I6 只观测 overlap 审计。

**目标**：优化已经胜出的 CPU-authoritative topology 路线，而不是恢复 CPU propagation owner。按 source 对 100k mixed updates 做确定性分组，不同 source 并行、同一 source 保持输入顺序；每个 worker 只修改所属 source-local chunk，最后合并排序后的 publication records。

1. 先记录 mutation 中分组、chunk allocate/copy、descriptor commit 和 patch merge 的耗时与 touched-source 分布，确认可并行部分上界。
2. 使用固定生命周期线程池和 worker-local staging；batch 级 epoch commit、reclaim 与 GPU publication 仍保持一次。禁止并发修改同一 source，禁止复制全图 topology。
3. 单测覆盖同源冲突、跨源并行、删除后插入、重复边、epoch/reclaim；输出与串行 reference 的 descriptor、degree、adjacency hash 和 patch 顺序完全一致。
4. 轻量 gate：TW/FS 各一次 10-batch，CPU mutation 合计至少下降 `30%`，完整 `paper_algorithm_ms` 至少一图下降 `5%`、另一图不回退 `>2%`。未过 gate 则恢复串行实现并删除线程池生产接线。

#### I6：已完成的合法 CPU/GPU overlap 审计（不进入实现）

只有 I5 收口后才记录 mutation、publication、repair 与 cache staging 的统一时间线和 topology epoch，计算真正无依赖窗口。至少两张真实图的合法重叠上界达到完整 batch 的 `5%`，才另立 dual-version/topology pipeline 实现迭代；否则明确否决，不先建设第二份常驻 GPU topology。

**I6 六图观测结果（2026-08-26）：** `scripts/run_i6_overlap_observation.sh` 已完成 Orkut、Wiki、R-MAT、Twitter、Friendster、Europe 各 10 batch；日志目录为 `logs/i6_overlap_observation_20260826_060919/`，汇总为 `summary.tsv`。六图均为 `10/10` mutation phase、`10/10` publication、`Overall: Test passed`，所有 publication 的 `gpu_cpu_hash_mismatches=0`。paper timer / mutation 合计分别为：Orkut `1401.769/179.465 ms`，Wiki `1621.871/182.860 ms`，R-MAT `7370.717/1602.342 ms`，Twitter `667.465/119.833 ms`，Friendster `3974.561/211.968 ms`，Europe `1639.574/214.367 ms`。

当前运行的 `[DUAL-RUNTIME-ROUND]` 时间线在六图均记录 `cpu_vertices=0`、`cpu_service_ms=0`、`overlap_ms=0`、`concurrent=0`；因此本轮只能证明生产路径稳定且观测字段闭合，不能证明存在已实现的 CPU/GPU 重叠。I6 的 `5%` overlap 上界 gate 未达到，暂不立项 dual-version topology pipeline；后续若继续，只能先提出并验证不改变拓扑可见性语义的 overlap 架构假设。

**I6 执行入口（2026-08-26）**：新增 `scripts/run_i6_overlap_observation.sh`，默认顺序运行 Orkut、Wiki、R-MAT、Twitter、Friendster、Europe 六个 100k mixed-update 图各 10 batch，`cache=2`、`hybrid=0`、`sssp_cpu_partition_capacity=0`、`check=false`。脚本逐图等待 GPU 三次空闲采样后启动，保存可复现 `.cmd`、逐图日志、manifest 和 `summary.tsv`，提取 batch `[P0-TIMER]`、CPU mutation/grouping/apply、publication 数量、hash mismatch 与 phase 完整性；任一进程异常退出或缺少 `Overall: Test passed` 即停止。它不修改生产代码、不做线程数 sweep、不并行占用 GPU，可用以下命令后台运行：

```bash
nohup env GPU_INDEX=0 RUN_DIR=logs/i6_overlap_observation_$(date +%Y%m%d_%H%M%S) \
  scripts/run_i6_overlap_observation.sh \
  > logs/i6_overlap_observation.launch.log 2>&1 &
```

需要缩短开发筛查时可显式设置 `DATASETS=twitter friendster europe`；正式 I6 观测仍以默认六图 cohort 为准。脚本完成后，先依据 `summary.tsv` 和各日志中的 epoch/phase 时间线计算合法 overlap 上界，再决定是否立项 dual-version topology；不得把脚本的观测结果直接当作 overlap 已实现。

#### I7：CPU topology mutation 首轮资源消融（已完成，研究 gate 待补）

**状态（2026-08-26）：已完成构建、定向 CTest 和 10 项后台实验，进程与 correctness 均通过。** I5 已证明 CPU source-local mutation 是当前唯一跨真实图稳定的 CPU 优势；I7 在统一 executor 上完成 `CG_MUTATION_WORKERS=1/20` 资源消融。该结果只证明单进程多线程 mutation 的潜力，不等价于相对 GPU-only 的系统收益；Twitter 首轮 correctness 的检查开销也不能混入性能中位数。日志目录：`logs/i7_mutation_ablation_20260826T082725Z/`。

1. 使用同一 runtime、同一 `cache=2`、同一 10-batch cohort，交错重复固定线程池 `CG_MUTATION_WORKERS=1` 与 `=20`；这是统一 source-local mutation executor 的资源消融，不伪称 GPU/all-GPU mutation。相对原版 GPU-only 系统只作外部端到端基线。
2. 仅报告 batch `[P0-TIMER]` 及 mutation、grouping、publication、GPU propagation/cache 分项；给出中位数、离散度、峰值内存和 checksum/correctness。不得用 CPU 利用率、单个 kernel 或 wall time 代替主指标。
3. 在 Twitter、Friendster、Europe 上验证收益方向；Wiki/Orkut 只作回归。若 Europe correctness 或资源预算未闭合，明确标记 pending，不用其他图替代。
4. 做一次结构性消融：关闭 source-local mutation 的 CPU 执行但保留相同 topology semantics，确认收益来自删除/缩短 GPU topology mutation critical path，而不是日志、线程数或 cache 偶然变化。

**首轮结果**：Twitter 两次交错对照的 paper time 为 `837.042/558.324 ms`，Friendster 为 `4727.682/4094.064 ms`，Europe 为 `2043.587/1596.237 ms`（1/20 workers）；mutation 分别下降 `68.4%/77.4%/64.4%`。三图 correctness 进程通过，所有日志有 `Overall: Test passed`，无新增 GPU 常驻副本。由于样本数量、运行顺序、publication/hash 字段和外部 GPU-only 对照尚未按论文口径闭合，I7 仅通过工程 gate，未通过最终研究 gate。

**资源决策**：保留固定生命周期线程池和单一路径；不增加 worker 数 sweep、数据集阈值或第二套 mutation 实现。I8 之前不得把 I7 数字写成最终论文 speedup。

#### I8：mutation 因果与重复性闭合（已完成）

**目的**：把 I7 的“1/20 worker 资源差异”变成可重复、可归因的流式 batch 结论；不改生产算法。

**状态（2026-08-27）：已完成。** `scripts/run_i8_mutation_repeats.sh` 串行完成 20-worker 三图 correctness、TW/FS 各 3 次 A/B 性能和 Europe 各 1 次 A/B 性能；`scripts/analyze_i8_mutation_ablation.py` 输出最终聚合。正式结果位于 `logs/i8_mutation_repeats_20260827T031043Z/`。Europe 使用 I2 冻结的 symmetric-expanded 99% cohort 与 `source=1`；I7 中旧 Europe `50p/source=0` 数字只作筛查。前两次启动因实验脚本漏输出 publication count 而误停，系统 correctness 实际通过；修复后完整续跑成功，该脚本缺陷不计作系统失败。

1. TW/FS 做 `A-B-B-A` 交错，A=`CG_MUTATION_WORKERS=1`，B=`=20`，每个配置至少 3 个 `check=false` 有效 10-batch run；Europe 做至少 2 个有效 run，资源不足则明确 pending。
2. correctness 单独执行，不把 `check=true`、Bellman、checksum 和最终 Gather 时间混入性能样本；每个性能 run 必须记录 publication 数、`gpu_cpu_hash_mismatches`、topology/edge-count invariant。
3. 计算 batch 级中位数、MAD/p95、mutation/grouping/apply/allocation/publication 分项和 timer 残差；同一批次只允许一次归因。

**Gate**：TW/FS 各自 B 相对 A 的 `paper_algorithm_ms` 中位数下降 `>=5%`，mutation 中位数下降 `>=30%`；方向在交错重复中一致；正确性与 publication hash 全过；残差 `<=2%`。未通过则只保留 I5 工程结果，不再优化线程池。

| dataset | 1-worker paper median ms | 20-worker paper median ms | paper change | 1-worker mutation median ms | 20-worker mutation median ms | mutation change |
|---|---:|---:|---:|---:|---:|---:|
| Twitter | 827.039 | 579.388 | -29.9% | 367.292 | 95.856 | -73.9% |
| Friendster | 4734.041 | 3971.274 | -16.1% | 986.260 | 204.516 | -79.3% |
| Europe | 2235501.245 | 2247136.749 | +0.52% | 645.659 | 258.002 | -60.0% |

**结论**：I8 gate 通过。TW/FS 的完整 batch 与 mutation 收益在 3 次重复中方向稳定；所有有效 run 均为 10 batch、20 mutation phase、10 publication、`gpu_cpu_hash_mismatches=0`，timer residual 最大 `0.007%`。Europe correctness 通过，但 mutation 加 grouping 也只占完整 batch约 `0.06%`，20-worker 实际节省约 `0.39/2235 s`；没有论文级收益空间。Europe 从性能 cohort 移除，只保留 correctness/压力边界，不为它增加特例。下一步进入 I9，只对 TW/FS 做关键路径归因。

#### I9：source-local mutation 关键路径边界审计（已完成）

**目的**：验证 CPU mutation 的收益确实来自替代/缩短原有 topology update critical path，而不是把工作移出 timer 或偶然的 cache 状态。

**状态（2026-08-27）：已完成。** mutation 指标拆分为 grouping、prepare、allocation preflight、allocation、epoch commit、parallel apply 和 retire；reclaim 独立计时，publication 保持现有边界。新增逐 phase allocations/reuse/retire/logical-edge 计数，不改变执行顺序。构建和两个定向 CTest 通过；A/B 日志与汇总位于 `logs/i9_critical_path_20260827T082919Z/`。

1. 只增加可移除计时和计数：grouping、prepare、allocation preflight、source-local apply、epoch commit、retire/reclaim、GPU publication、cache invalidation；不新增执行分支。
2. 对 A/B 使用同一 batch 输入逐项比较 changed sources、written/relocation bytes、patch records、cache invalidations、edge count、epoch 和 topology hash。
3. 计算 `deleted_or_shortened_work`、`added_control_work` 和 `net_critical_path_delta`；不得把 CPU worker busy time 直接当作收益。

**Gate**：分项闭合 `<=2%`；B 的收益可由删除/缩短的原 topology work 与新增控制成本解释；publication/hash/edge count 完全一致。若无法闭合，暂停性能扩展，修复观测契约而非继续调参。

**结果**：Twitter 的 topology boundary 从 `440.357` 降至 `170.748 ms`，完整 paper 从 `841.515` 降至 `568.991 ms`；其中 parallel prepare/apply 缩短 `264.365 ms`，control 差额 `5.376 ms`，闭合残差 `0.049%`。Friendster boundary 从 `1560.680` 降至 `798.121 ms`，paper 从 `4890.399` 降至 `3989.362 ms`；parallel work 缩短 `758.884 ms`，control 差额 `4.183 ms`，残差 `0.067%`。逐 batch epoch、changed/touched/update/source-work、written/relocation bytes、alloc/reuse/retire、logical edges、patch records/bytes、ZC cold edges 和 topology hash 全等，`structural_mismatches=0`。

Friendster 两次独立运行的 cache invalidation 总量为 `154442/154502`，差 60（`0.039%`）；同时 desired resident 数和 cache tail 轻微波动。这是 traversal hotness/candidate 的派生 cache 状态，不是 CPU topology 输出，故只作诊断，不列入 topology 等价 gate。I9 通过，收益由 source-local prepare/apply 的并行缩短解释，不来自 publication、reclaim 或 cache 偶然变化。下一步进入 I10 契约封板。

#### I10：CPU/GPU topology 可见性与资源契约封板（已完成）

**目的**：形成可发表的单一异构状态模型，确认 CPU-authoritative topology 不引入隐式全图副本或 batch 间竞态。

**状态（2026-08-27）：已完成。** `source_local_chunk_store_test` 新增 arena 守恒、1/4-worker descriptor slab/index/version 等价和非法 epoch publication transition 拒绝；`C3-CHUNK-LOAD` 明确记录 pinned edge、metadata 和 pinned total bytes。构建及 topology/chunk-store CTest 通过。`scripts/run_i10_topology_contract.sh` 串行完成 TW/FS 20-worker correctness，并采集 `/usr/bin/time` RSS 与 2 秒 GPU memory peak；Europe 复用 I8 symmetric-99% 的完整 correctness/publication hash 日志。结果位于 `logs/i10_topology_contract_20260827T094010Z/`。

Twitter/Friendster 均为 `10/10` delete-stage、`10/10` batch、final Bellman 与 overall pass；每图 10 次 publication，`gpu_cpu_hash_mismatches=0`、`stale_version_rejects=0`。Twitter 的 CPU peak RSS/GPU peak/pinned topology 为 `15.54 GiB/9699 MiB/3.095 GiB`；Friendster 为 `54.19 GiB/14409 MiB/8.890 GiB`。I3 未采 GPU peak，不能伪造历史数值比较；I10 实测冻结为后续同配置资源基线。本迭代没有新增 device allocation，因此可见性、正确性和资源计量契约通过。

1. 为 source descriptor、adjacency chunk、epoch、retire/reclaim、GPU publication 定义不变式，并在定向测试覆盖同源冲突、跨源更新、删除后插入、重复边、空 source 和容量扩展。
2. 在 TW/FS 校验每批 publication 前后 topology hash、logical edge count、descriptor version 和 GPU/host hash；Europe 只做一次相同 correctness/资源压力审计，不进入性能 gate。记录 CPU RSS、pinned bytes 和 GPU peak。
3. all-GPU 仅作为同一 runtime 的 capacity-0/空 CPU domain 语义对照；不复制 mutation 流程，也不引入第二份 topology。

**Gate**：TW/FS correctness 全过且 Europe 压力审计无语义错误；无 stale version、missing publication、hash mismatch 或 epoch leak；确认本迭代没有新增 device allocation，并将实测 GPU peak 冻结为下一架构的同配置资源基线；资源契约写入代码测试和文档。I3 未采 GPU peak，不能要求一个不存在的数值对照；Europe 时间不参与 gate。

### I11--I15 统一研究主线：源粒度事务化 mixed-batch 流水线

这五个迭代不是五个零碎贡献，而是同一论文级机制的“语义证明 -> 核心实现 -> 正确性封板 -> 性能归因 -> 外部验证”。论文叙事只保留一个中心问题：**当系统只要求每个 mixed batch 的最终 SSSP 状态时，能否消除 deletion-only 中间图的完整收敛，并以源粒度多版本拓扑把 CPU final-state construction 与 GPU old-state invalidation 放到同一关键路径中并行执行？**

当前代码与 I9 数据支持立项，而不是无依据猜测：当前 `SourceLocalChunkStore` 已把删除和插入放在同一未发布 epoch，却仍分别调用 `ApplyBatch()` 与 `ApplyPendingAdditions()`，按 source 分组和物化两次；`DynamicReverseIndex` 又按 edge 串行写入全局 `unordered_map`。GPU 先在 deletion-only topology 上迭代 repair，再对 additions 启动 exact-source closure。I9 的 20-worker 运行中，Twitter 的 physical deletion / deletion repair / addition CPU window 合计约 `115.084/46.455/100.617 ms`，占 `568.991 ms` paper time 的 `46.1%`；Friendster 对应 `500.178/148.705/695.150 ms`，占 `3989.362 ms` 的 `33.7%`。这些时间不能全部当作可获得收益，但足以证明应攻击的是跨两个状态的串行结构，而不是 worker 数、memcpy 或数据集阈值。

目标执行关系：

```text
epoch e: immutable current topology + current SPT
        |-- GPU: deleted-parent seed -> old-SPT dependency invalidation --|
        |-- CPU: group mixed updates once -> build final touched chunks --|  overlap
                                      fence / commit epoch e+1 once
final topology e+1: boundary recovery seeds U added-edge seeds
                    -> one device-local exact-source closure
                    -> one quiescence / publication completion / reclaim
```

这里的“多版本”只存在于本 batch 的 touched-source chunk：CPU 为改变的 source 构造 next block，GPU 在 fence 前继续读 current descriptor；没有第二份全图 topology、没有第二套 executor、没有运行时 fallback。CPU 仍只负责它已经证明擅长的 topology construction，GPU 仍是唯一 SSSP state owner。

#### I11：最终态 repair 语义与可证伪模型（已完成）

**目的**：在改 production code 前证明“先失效旧 SPT dependency，再在最终图统一恢复”与当前“删除后收敛，再插入后收敛”的最终距离语义等价；本迭代不跑长性能实验。

**状态（2026-08-27）：已完成，批准 I12。** 新增 `tests/final_state_repair_model_test.cpp` 与 CTest 入口，以最终 multigraph 的 full Dijkstra 为 oracle，覆盖删后重加、重复边只删除一个副本、等长 predecessor、跨 affected/unaffected 的新增捷径、added edge source 初始 affected、空 phase 与不可达分量，并完成固定种子的 `20,000` 次随机 mixed-batch 反例搜索；distance 与 existential tight witness 全部一致。语义证明与 epoch fence 见 `iteration/i11_final_state_repair_semantics.md`。

I11 明确修正了失效判定：不能因 old parent edge 出现在 deletion list 就失效；只有该 parent arc 在 delete-then-add 后的最终多重图中计数为零，旧 tree dependency 才真正断裂。统一种子为 final topology 中 finite/unaffected 到 affected 的 boundary incoming，以及当前 source finite 的 added-edge improvements；added edge source 若初始 affected，会在其恢复后由同一 closure 扫描，不需要第三类种子或 fallback。

`scripts/analyze_i11_final_state_upper_bound.py` 只读复用 I9 日志：Twitter 被机制覆盖的串行结构区域为 `262.156/568.991 ms = 46.074%`；Friendster 为 `1344.033/3989.362 ms = 33.690%`，均超过 `10%` admission gate。该区域是立项上界而非预测收益，I12 必须实测 fused materialization、reverse delta、overlap、publication 和 unified closure 的净成本。

1. 写出状态不变式：batch 开始时 `d_e` 是 `G_e` 的 Bellman fixed point；只根据成功删除的 parent/tight dependency 构造 affected descendant closure；affected 状态失效后，未 affected 状态是最终图松弛的合法上界种子；在 `G_{e+1}` 上从“affected boundary incoming + added edges”统一传播至静止，得到最终 SSSP fixed point。
2. 用确定性小图 oracle 覆盖：同一 edge 先删后加、重复边计数、删除 parent 但仍有等长 predecessor、added edge 连接 affected/unaffected 两域、source 被波及、空 delete/add phase和不可达分量。oracle 比较的是最终 distance 与 witness，不要求 parent tie 完全一致。
3. 只复用 I9 日志计算结构上界：旧路径的两次 source work、reverse-delta 随机更新、deletion repair iterations、insertion closure waves以及可重叠 invalidation window；不重采 TW/FS。

**Gate**：所有 oracle 与 full recompute 一致；能够明确列出 unified closure 的种子完备性和 epoch fence；TW/FS 现有日志中被该机制覆盖的串行区域均超过 paper time 的 `10%`。任一语义反例不能通过扩大 affected 到全图或增加 fallback 掩盖，必须先修正算法定义；无法修正则终止本主线。

#### I12：事务化 mixed-batch 核心实现（预计 3--5 天）

**目的**：一次性完成该章节的核心代码变化，不把 forward topology、reverse index、GPU repair 各包装成独立“小贡献”。

**进入条件（2026-09-05 微调）**：当前 22/22 CTest 已通过，因此 `fable5结论.md` 中记录的 `cache_tail_fallback_test` crash 不再是现时 blocker。正式改动 production code 前仍须保存 I10 基线的源码状态/未提交 diff manifest、构建命令、二进制校验值和 TW/FS 2-batch 命令；若现有 I10 artifact 不能由该 manifest 复现，则先重建一次短基线。此步骤只冻结对照，不整理或覆盖用户已有工作区修改。

**进展（2026-09-05）**：已新增 `SourceLocalChunkStore::PrepareTransaction`、`CommitPreparedTransaction`、`PreparedReverseDelta` 与 `HasPreparedTransaction`。prepare 阶段只按 touched source 构造 next chunk 并写入，current descriptor/epoch/edge count 保持不变；commit 阶段一次切换 descriptor、更新 edge count、退休旧 block。transaction 只向 reverse index 输出实际成功删除和合法插入，缺失删除不会留下错误负计数。`DynamicReverseIndex` 已改为 destination-local sorted compact delta，整批排序/归约后与持久 delta 线性合并，不再维护逐 edge 全局 count map。两个定向测试新增 current/next 可见性、mixed duplicate/delete-add oracle、batch compact 和重叠 prepare 拒绝覆盖，均通过。

SSSP runtime 已切换到 I12：`del_edge()` 一次构造完整 mixed batch，在 CPU 异步 prepare final touched chunks 的同时，GPU 只读取旧 epoch 做 dependency invalidation；删除种子按最终 multigraph multiplicity 过滤，delete-then-add 或仍有重复 occurrence 的 arc 不会被错误失效。fence 后只执行一次 descriptor commit、一次 reverse `ApplyBatch` 和一次 sparse publication；final reverse topology 的 affected boundary seed 与有效 added-edge seed进入同一 exact-source queue，并只调用一次 cooperative closure。删除阶段不再物理发布 deletion-only topology，也不再做 Bellman fixed-point 检查。

当前证据：22/22 CTest 通过；Wiki 100k 1-batch 与 Orkut 0.1k 1-batch 的最终 Bellman/tight witness、topology publication audit 和 overall check 通过，两个用例均观测到每 batch 恰好一次 `I12-TRANSACTION-COMMIT`、一次 `C3-PUBLISH`、一次 `E4-R1-CLOSURE`，且 stale reject/hash mismatch 为零。TW/FS 2-batch `check=false` 开发 screening 也已完成：Twitter 为 `71.759/68.417 ms`，相对 I10 `75.293/83.219 ms` 下降约 11.6%；Friendster 为 `506.269/539.232 ms`，相对 I10 `483.123/512.589 ms` 上升约 5.0%。因此 Twitter 通过结构回退门槛，但 Friendster 已达到/略超过 `>5%` 回退边界，I12 性能 gate 暂不通过，不能进入 I13。

Friendster 阶段归因已经补齐：I10 batch 0/1 的 publication 为 `57.424/56.728 ms`，I12 降至 `1.925/1.848 ms`；但 I12 transaction CPU mutation 为 `176.195/194.179 ms`，并叠加 cache compact/load `58.400/59.094 ms` 与 `102.070/103.408 ms`，因此总 batch 仍为 `506.269/539.232 ms`。这说明回退不是 publication 或 GPU invalidation（后者仅约 1 ms），而是 Friendster 的 COW materialization 与 cache pipeline 叠加成本。

本轮已将 transaction 分组改为 flat sorted mutation log：按 source 的连续 range 描述删除/添加，预留 groups/effective-delta/prepared capacity，避免每个 touched source 的小 vector 扩容。该实现保持 22/22 CTest 和已有真实图 correctness 通过；FS 新测 `group_ms=105.245/83.172 ms`、总 batch `532.192/539.331 ms`，相较前版总时间没有形成稳定改善。因此 flat grouping 不是 FS 的完整解法，不能宣称 I12 gate 通过。

I12 gate 决策：暂停当前 COW production 路线，不实现“高 churn 原地 compact + 低 churn COW”的新阈值分支。该分支会重新引入 commit 前后可见性、GPU reader fence、异常回滚和跨应用路径复杂度；在没有新的算法级证据前，不应继续扩大 production 状态空间。事务、reverse compact、unified closure 代码和日志保留为 artifact，用于论文中的结构失败/边界证据；生产性能比较回到 I10。`RunGpuAffectedRepair()` 已无 SSSP production caller，`ApplyPendingAdditions()` 仍由 BFS/CC 共用的兼容 `add_edge_pr()` 保留调用。

### I12 之后的路线调整（2026-09-05）

这次调整不是放弃科研问题，而是把研究问题从“如何把 final-state COW 事务做快”改为“什么 workload regime 值得改变 repair 算法复杂度”。调整依据如下：

1. 已经成立、应保留为论文主线的是 affected-only GPU deletion repair、exact-source insertion closure、CPU-authoritative source-local topology、epoch/sparse publication 和并行 source mutation。它们在 TW/FS/Wiki 上已有 correctness 和正式收益证据。
2. I12 证明了 final-state transaction 的语义可行性，但 FS 证明其 COW/materialization 成本会抵消 publication 收益；因此 I12 作为失败的结构假设和负结果，不再继续扩展 production 状态空间。
3. Fable5 指出的 Europe 高直径 regime 改变的是 repair 的算法复杂度：当前 GPU 是 `O(E_affected * rounds)` 的重复扫描，而 CPU Dijkstra 目标是 `O(E_affected log V)`。这与已否决的“CPU 分担低直径 GPU frontier”不是同一问题，值得单独立项。
4. 近期实验只做能改变决策的最小实验：Europe 50p 1-batch correctness/work counter、I14 GPU-vs-Dijkstra 单 batch 对照、I15 hotness event oracle；不再为已经判定失败的 I12 COW 路线支付交错重复成本。

生产代码在完成 I13 隔离前不得把当前 I12 修改宣称为默认性能实现；I10 构建和 manifest 是唯一外部性能基线。论文 §4.5 的 unified final-state repair 改写为“语义证明与失败性能边界”，Europe regime 适应改写为后续正向研究方向。

1. 将两阶段 `ApplyBatch()/ApplyPendingAdditions()` 收敛为一个 mixed-batch transaction：删除和插入按 `(source, input-order)` 一次分组，对 touched-source union 只扫描旧 adjacency 一次，并严格保留当前 delete-then-add 的 multigraph 语义。
2. touched source 采用 copy-on-write next chunk；prepare 阶段不修改 current descriptor，commit 只在 GPU old-epoch reader 完成后发布排序、去重的 descriptor patch。临时额外空间必须为 `O(sum degree(touched sources) + updates)`，禁止全图副本。
3. 将 reverse delta 改为同一 transaction 产生的 destination-local compact records，批量排序/归约后提交；删除逐 edge 全局 `unordered_map` 写入，不保留 selectable old/new reverse path。
4. batch 开始后并发启动 GPU old-epoch invalidation 与 CPU final-topology prepare；二者完成后执行唯一 epoch commit。GPU 对 affected boundary 做一次 incoming min-reduce，与 added-edge relax 共同生成 exact-source seed，随后只调用一次 device-local closure 到 quiescence。
5. 新路径正确接管后，删除 deletion-only physical topology state、迭代 affected pull repair、pending-addition API 以及重复 phase grouping。实验开关只允许存在于独立构建 artifact，不进入 production flags。
6. 从第一个可运行版本起分别记录：一次 final-topology source scan/materialization、reverse compact records、old-epoch invalidation、CPU prepare、两者实际 overlap、fence/publication、boundary min-reduce、unified closure waves 和临时 COW high-water。I11 的 `46.1%/33.7%` 只是结构覆盖上界，不写作预期 speedup。

**结构 Gate**：每 batch 只有一个 topology transaction、一次 descriptor publication 和一次最终 closure；GPU old reader 在 commit 前只能观察 epoch `e`，commit 后只能观察 `e+1`；forward/reverse edge count、descriptor hash 与 final graph oracle 一致；无全图新副本；被替代的旧生产路径和 API 同步删除。分项必须能区分“少一次 materialization”“合法 overlap”和“消除中间 fixed point”各自效果。开发期 TW/FS 2-batch `paper_algorithm_ms` 不回退 `>5%`，否则只定位结构税，不做阈值或数据集特例。

#### I13：默认路径恢复与冗余事务代码清理（已完成）

**结果（2026-09-06）**：清理前源码、测试、脚本与 SSSP 二进制保存在 `logs/i13_cleanup_20260906/pre_cleanup.tar.gz`，不在运行时保留 I12 开关或备用事务路径。已移除 async prepare、COW transaction API/状态、final-boundary seed 及专属测试，恢复 deletion-only GPU repair、addition exact-source closure 和删除阶段 Bellman 检查；保留 I5--I10 多线程 mutation、epoch/arena 契约。reverse index 恢复逐边 delta 更新，同时增加“缺失删除不能抵消未来插入”的语义检查及定向回归。chunk-store、cache-tail、topology-contract 测试显式启用 Release 断言，避免断言中的操作被优化掉。

核心实现净减少 `698` 行，其中 `framework.cuh` 从 `5809` 行减至 `5494` 行，chunk store 从 `1136` 行减至 `797` 行；现有测试净减少 `92` 行，另增加小型开发 runner `scripts/run_i13_smoke.sh`。清理针对 I12 及其依赖；仍有调用者的历史 CPU-domain 路径、独立 replay 工具和跨应用共用代码未作全仓批量删除。

SSSP/BFS/CC/PR 均重新编译；间接依赖 chunk store 的测试也重编译，`22/22` CTest 通过。TW/FS 各 `10/10` deletion-stage、`10/10` batch、final Bellman 和 overall check 通过；各批 distance checksum 全部与历史 I10 一致。每图 `10` 次 publication，stale-version reject 与 topology hash mismatch 均为 `0`。最终 distance checksum：TW `12687655862474487153`，FS `12734023534853680802`。

同 GPU、source、cache、20 workers 的两批 `check=false` 单次短测，相对清理前保存的 I12 二进制：TW `124.139 -> 102.254 ms`（下降 `17.63%`）；FS `1369.420 -> 874.267 ms`（下降 `36.16%`）。两批最终 distance checksum 一致，也与十批 correctness 的 batch 1 一致。这是开发 screening，不能写成重复性能结论。沿用 I10/I12 原文件，TW 实际每批 `10k delete + 10k add`，FS 为 `50k + 50k`，不能仅凭文件名把两者均称作 100k mixed。

验证边界：按既有 distance/existential tight-witness 契约验收；历史 stored-parent witness 非零诊断仍存在，本轮未修复，也不声称 parent 数组已构成合法最短路径树。BFS/CC/PR 仅做编译兼容验证，Europe 未重跑。命令、二进制校验值和完整日志见 `logs/i13_cleanup_20260906/README.md`。I13 完成，不自动启动后续算法迭代。

1. 从当前工作区隔离 I12 transaction artifact，恢复默认 I10-compatible 路径；不在默认运行时保留 COW transaction、sequential fallback 或数据集特例。
2. 保留 source-local mutation、epoch publication、reverse merge 和 exact-source closure 作为所有 executor 共用的公共接口。
3. Europe 的 `50p/source=0` 与 `99p/source=1` 作为不同 cohort 记录；只做短 correctness/work-counter 检查，不把论文级重复或外部对照作为本迭代条件。

**Gate**：默认路径在 TW/FS 通过 correctness 与资源契约；I12 状态不会被默认路径误用；I13 不引入新的算法分支。

### I13 后工作量归因与队列修订（2026-09-06）

**当前唯一近期执行队列：I14 有效更新批次 -> I15 事件驱动维护 -> I16 work-efficient repair。** I13/I14 已完成；I15 前置审计进行中。1000k 扩展、外部对照和论文整理退出近期编号队列。下文覆盖此前同名迭代以及历史章节中的执行顺序。

**证据**：`logs/current_profile_20260906T094718Z/` 四次完整运行，每次十批 `check=false`。可复算脚本 `scripts/analyze_current_substages.py`；明细 `substages.json`。均值按两轮共二十批计算，子项包含关系不能重复加和。TW 实际每批 10k 删除+10k 插入，FS 为 50k+50k，保持现有输入不变。

| 每批平均，ms | Twitter | Friendster | 解释 |
|---|---:|---:|---|
| 总 batch | 63.141 | 480.452 | 两轮均值，非稳定性能保证 |
| 删除阶段总量 | 25.582 | 173.816 | 包含 topology、准备和 repair |
| 删除外层未细分差额 | 8.950 | 81.723 | 外层 deletion 减内部 total；不能直接标为 reverse 成本 |
| physical delete | 10.871 | 69.453 | 包含下面 grouping 和 prepare/apply |
| delete grouping | 1.967 | 48.191 | 按 source 分组、分配容器和统计等 |
| delete prepare+apply | 8.097 | 13.684 | 必要邻接修改的主要计算 |
| GPU invalidation | 0.651 | 2.132 | 必要失效传播 |
| repair 总量 | 4.849 | 19.611 | 包含 incoming prepare、H2D 和 closure |
| incoming prepare | 1.557 | 13.810 | 上一行子项 |
| GPU deletion closure | 3.207 | 5.457 | 总 batch 的 5.08% / 1.14% |
| add grouping | 1.903 | 27.009 | 与删除重复建立 source 分组 |
| add wrapper 未细分差额 | 7.464 | 40.489 | cpu_mutation 减 group+mutation；含逐边 reverse 更新/封装/析构等 |
| publication | 2.191 | 1.835 | 当前不是主要机会 |
| insertion closure | 0.267 | 0.842 | 不重开低直径 CPU propagation owner |
| hotness+candidate | 21.318 | 80.096 | 总 batch 的 33.76% / 16.67% |

Friendster 两轮总均值从 441.627 到 519.276 ms，删除阶段从 135.612 到 212.021 ms；其中外层差额从 58.296 到 105.151 ms，delete grouping 从 39.925 到 56.456 ms，repair 总量从 14.389 到 24.833 ms，而 GPU closure 为 5.495/5.420 ms。因此波动集中于 host 更新准备和 incoming preparation，不能归因于 GPU closure，也不能由两次运行断言某个 CPU 函数是唯一根因。

代码核对：`del_edge()` 在 `update_tree_del()` 的内部 timer 之前逐边执行 `ApplyDelete()`，后者查 base multiplicity 和全局 delta；外层还包含同步、reclaim、audit 入口及内部 timer 前的 reset/setup。`add_edge_pr()` 同样逐边更新 reverse 后才执行 chunk mutation。`ApplyMutationPhase()` 为两阶段分别建立 source 容器，reverse 又独立维护 endpoint 计数。这里存在共同更新语义被多次解释的结构，值得验证统一表示，而不是移除删除工作。

FS cache 前三批平均约 176.751 ms，后七批仍约 109.981 ms；不是只有预热期才有开销。但现有日志没有完整 desired/resident 集差分，不能断言后七批全部可用 delta 更新消除。TW hotness/candidate 的全顶点 kernel、radix sort、degree extraction 和窗口 shift 已由代码确认，不依赖此推断。

#### I14：统一有效更新批次与双向拓扑维护（已完成，保留）

启动记录：`logs/i14_host_attribution_20260906/` 保留计时前源码和二进制归档。新增 `I14-HOST-DELETE`、`I14-DELETE-SETUP`、`I14-HOST-ADD` 整批计时；不逐边读时钟、不新增执行模式。为隔离 reverse 时间，将原来交织的 preparation/reverse 拆为两个顺序循环，phase 顺序不变，但内存访问局部性可能改变，因此此轮是诊断画像，不是优化收益证明。`scripts/profile_current_runtime.py` 在每次运行完成后自动生成 `substages.json`，失败状态写入 `status.json`。TW/FS 各两轮十批、20 workers、cache=2、check=false，保留全部删除；完整 batch 仍是比较口径。日志、析构、内部未归因量均保留为 residual，不归到 reverse。现有 22 项 CTest 和新增 4 项计时解析测试通过；后台结果决定是否准入有效批次核心实现，不能将本步骤记为 I14 完成。

**研究问题**：在保留删除数量、delete-before-add 语义和两阶段 repair 的前提下，能否让 forward topology、reverse dependency 和 publication 消费同一份有效变更，避免分别解释、分组和查询原始更新？核心是更新数据流与权威性的统一，不是把现有函数包进新类。

1. **前置归因是本迭代的一部分**：只补足 delete 外层的 sync/reclaim、edge preparation、reverse update、reset/setup，以及 add wrapper 的 reverse/update preparation 计时；复用十批开发 screening，解释 FS 两轮差额。所有计时留在 batch 内；若新增观测扰动明显，移除后再确认方向。完成这一步才决定是否实现下一步，不将 81.7 ms 差额当作已证明可消除工作。
2. **统一表示**：按 source 构建一次 mixed update 的分组索引，保留各 phase 输入顺序及重复 occurrence 语义。forward mutation 是实际成功删除/合法插入的权威来源，产生紧凑 effective deletion/addition records；reverse 不再通过独立逐边 multiplicity 查询重新判定成功性。该表示同时供 forward、reverse 和 touched-source publication 使用。
3. **保持 phase 可见性**：old topology 上完成 invalidation 后执行 forward delete；删除有效 delta 必须在 deletion incoming materialization 前提交 reverse。删除 fixed point 完成后再执行 additions、reverse add 和已有 publication。不把 additions 提前暴露给 deletion repair；不引入 COW next graph、async transaction 或全图副本。有效记录的 prepare/preflight/commit 顺序要防止失败造成 forward/reverse 分歧。
4. **目的端批量消费**：同一 effective record 集建立 destination 视图，批量归约和合并 reverse delta；只维护一套权威 reverse 状态。I12 sorted compact 的经验可参考，但不能原样恢复其 transaction API，也不能每条边调用一次批量排序。新路径必须替换逐边重复解析及不再需要的临时容器。
5. **开发 gate**：先用 duplicate、missing delete、删后重加、空 phase 和跨 batch 小图 oracle 对比 forward/reverse，再做 TW/FS 短性能与正确性检查。只有实际减少重复查找/构造工作、完整 batch 收益明确且另一图无明显回退才保留；计时证明机会不在这层，或批量重排成本抵消收益，则明确否决并进入 I15。不要求论文级重复、外部对照或 preset speedup 数字。

**边界**：这里保留实际删除邻接表、失效传播和替代路径恢复；优化的是多消费者重复解释更新的过程。单独更换 hash map、线程数或小 vector 不构成本迭代完成。单独“把 I12 flat grouping 拿回来”也不算新结构证据。

**前置归因结论**：`logs/i14_host_attribution_20260906/status.json` 已为 complete，四次十批运行全部完成并通过 final distance checksum 和 publication count 检查。本轮 TW/FS 总 batch 均值 57.380/466.728 ms；reverse delete 为 7.135/79.315 ms，reverse add 为 5.024/46.214 ms。FS delete outer gap 79.575 ms 中 reverse 占 79.315 ms，sync/reclaim/edge preparation/setup 合计约 0.246 ms；add wrapper gap 50.945 ms 中 reverse 为 46.214 ms，forward call 内未归因约 4.445 ms。此前怀疑的 reverse 重复处理已得到直接测量支持，允许进入核心实现。此处诊断版总时间变化不作为 I14 加速成果。

**核心实现记录**：`effective_update_batch.h` 将 mixed 输入稳定按 source 排序一次，使用平坦 destination 数组及两阶段范围。chunk store 的原有 replay API 与线上 API 均复用这一实现，不保留原 per-source 小 vector 分组算法。forward 的 matched deletion runs 产生有效负 delta，合法 source 的插入产生正 delta；缺失删除及无效 source 不交给 reverse 消费。仅实际 changed source 进入 publication 列表。reverse 用 destination 分组、source 归约和已排序 delta 合并，删除旧 `ApplyDelete/ApplyInsert` 逐边接口、全局 edge-count hash 及 incoming 时重新排序的分支。删除有效 delta 在 forward delete 后、incoming materialization 前可见；add phase 仍在 deletion fixed point 后。

reverse 的 Prepare 在 forward 邻接提交前完成排序、合并及目标槽位分配；Commit 为 noexcept 已准备 vector 交换，并删除净零 delta。arena 容量预检、effective records、apply metrics 和 retire 容器预留在邻接提交前。容量失败和 reverse prepare 注入失败回归要求 forward/reverse 可见拓扑不变；这不是任意硬件错误或内部 invariant 破坏下的全事务回滚承诺。批量 merge 仍需扫描 touched destination 的累计 delta，后续必须观察完整 batch 和 incoming 成本，不能只看移除 base multiplicity 查询。

**当前验证**：全项目构建成功，SSSP/BFS/CC/PR 均重新编译；22 项 CTest 通过。reverse 测试已改为直接对接 chunk store 的两阶段 oracle，覆盖重复/缺失/删加、空 phase、无效和未 materialized source、300 批固定种子随机更新及预检失败；同一测试通过 ASan/UBSan。5 项归因脚本测试通过。`scripts/run_i14_validation.py` 已在 `logs/i14_effective_batch_20260906/` 后台运行：先 TW/FS 各两批 check=true + topology replay audit，并比较 I13 每阶段 distance checksum，再自动串行运行两轮十批 check=false。启动 PID 3496575；最终以 status.json 为准。真实图结果待返回；BFS/CC/PR 此处仅编译，历史 stored parent witness 诊断未修复。

**计时口径更新**：一次性 shared grouping 位于 delete 外层、仍在 batch 内，记录为 `I14-BATCH.group_ms`；`C3-EFFECTIVE.reverse_prepare_ms` 是 mutation preflight 的子项，reverse commit 含在 apply 中。旧 I14 host 诊断打点已由归档保留并从线上移除，不能将新 preflight/apply 与旧 forward-only 子项直接比较为同一工作。以完整 batch 收益决定保留，I14 尚未完成。

**最终验收覆盖以上待返回状态**：`logs/i14_effective_batch_20260906/status.json` 已 complete，`correctness_status.json` 已 passed。TW/FS 各两批 check=true + topology replay audit，删除/插入阶段 checksum 与 I13 一致；四次十批 check=false 的最终 checksum 与 publication count 通过。TW 两轮均值 54.716/51.954，合计 53.335 ms；FS 417.484/411.864，合计 414.674 ms。相对紧邻诊断基线 57.380/466.728，耗时降低 7.05%/11.15%，两图均改善，达到开发 gate，保留 I14。不将两轮估计表述为统计稳定保证，也不将旧未打点 63.141/480.452 当作唯一加速基线。reverse prepare（删+加）现为 6.955/86.256 ms，commit 已含在 apply，不能与旧 reverse 总时间做严格同口径加速比。hotness+candidate 仍为 21.287/79.998 ms，约占总 batch 39.91%/19.29%，进入 I15 有依据。

#### I15：事件驱动的 hotness/candidate 维护（进行中：分数配对修正验收）

**2026-09-07 提交检查点与顺序调整**：I14 保留；I15 拆成“配对纠错基线验收 -> 完整事件契约与正确排序 oracle -> 增量候选原型”三个顺序步骤，不新增独立工程迭代编号。此检查点 TW 两批正确性已通过，FS 正确性仍在后台运行，纠错后四次十批性能与零错配 audit 尚未完成，因此不可报告 I15 性能收益或完整验收。旧 I14 性能比较仍是同一旧 cache 语义下的拓扑改造开发证据，但不能代替纠错后最终系统基线。

后续研究重心不是继续优化单个 hash/vector，也不是简单把全量 GPU 排序搬到 CPU。优先验证四窗口有限分数域（0--1020）下的分数分组维护与按 ID 排序的零分大集合，按累计 degree 做容量选择；维护事件必须包含 expand、expiry、reachability mask 和 degree change，并保持现有容量边界语义。大量零分顶点仍可能进入 cache，非零活跃集小不等于候选输出小。初始化及其首次到期均是大事件，必须计入；不能只用 batch 3--9 的稀疏集合宣称全程低复杂度。若正确候选集合很大、事件维护开销抵消收益，则停止该原型并细化 I16，不能靠逐图阈值补救。I16 暂不提前，EU 独立证据仍缺失。

**2026-09-07 更新，覆盖此前待核实状态**：十批 TW/FS 只读审计完成，final checksum 和 publication count 均通过。初始化 score/ID mismatch=0；首个更新批次 TW=19,485,389、FS=46,931,414，确认旧排序输入错配，而非 tie 现象。初始化窗口到期后的 batch 3--9，window_nonzero 为 TW 18,102--20,669、FS 58,509--91,774；零分集合仍占绝大多数。mask 非零约三千，不能漏掉可达性状态事件；uint8_t 非零数仍不等同全部 expand 事件。

验收启动补记：修复版 SSSP 编译和 23/23 CTest 通过。首次后台启动因 CTest 刚结束的 GPU busy 检查退出，未运行图实验；已在 `logs/i15_pairing_fix_20260907/validation/` 重启，最终读取该子目录及其 audit/status.json。根目录失败记录保留用于解释启动过程。

本次只修正 SSSP 分数生成 kernel：写 score[node] 时同时写当前 ID buffer 的 ids[node]=node，使稳定降序排序明确以 ID 升序打破同分。没有新增生产 kernel、排序模式或改变窗口计数。新增 `hotness_pairing_test.cu` 直接运行生产 kernel 与 CUB，连续八轮检查旧排列、mask、同分顺序、最大窗口和。PR 的独立 score kernel 本次未改，不将 SSSP 修复扩展成未验证的跨应用语义变更。

`scripts/run_i15_pairing_validation.sh` 串行执行 TW/FS 两批 check=true + topology audit、四次十批无审计性能画像，最后十批只读审计要求 score_id_mismatches/permuted_ids 均为零。目录 `logs/i15_pairing_fix_20260907/`，主画像状态与末尾 audit/status.json 必须都完成才算本轮验收。性能只是纠错后的新基线，不得记为事件驱动收益。若通过，I15 下一步以正确的 (score desc, ID asc) 为 oracle，研究有限分数域与零分大集合的候选维护；先完整处理 expiry、reachability、degree、expand 事件，不重做 allocator。I15 增量算法仍未完成。

**新增前置约束**：代码发现 `comp_hotness_sssp` 按 node 编号重写 score，而 CUB sort 的 `d_id.Current()` 沿用之前排序的排列；ID 初始化目前只找到 LoadGraph 路径。先用只读审计确认真实批次的 score/ID mismatch，不能把潜在错配当稳定 tie oracle。分数还受 `buffer==UINT32_MAX` 屏蔽，故可达性变化也是事件来源；四窗口为 uint8_t，有模 256 回绕，非零计数不是全部访问事件数量。若错配确认，先单独修正并建立正确 score/ID 的基线，再做事件驱动对照，不把语义纠错收益混入结构优化收益。

`--sssp_hotness_audit=true` 为显式诊断开关，默认关闭，无审计内存/额外 kernel。在 score 写入后、排序前检查 current/window/expiring 非零集合、masked nonzero、zero score、permuted ID、score/ID mismatch 和 invalid ID；不修改任何生产状态。初始化 batch=-1 加十批更新，TW/FS 串行后台脚本 `scripts/run_i15_hotness_audit.py`，输出 `logs/i15_hotness_audit_20260906/audit.json`。审计包含额外全图读取，耗时留在 batch 内，不用于性能比较；这是前置观测，不是 I15 算法完成。下一步只有在事件集合完整、排序对应正确后才设计增量候选结构。

**研究问题**：用完整的状态变化事件维护 rolling-window score 和 cache candidate，消除每批全顶点刷新/重排；需要维护的不仅是本批 topology touched source，还包括 traversal events、历史窗口过期和 degree 变化。

1. 先定义初始化、successful-expand、窗口到期、degree change 的完整事件集合；以现有四窗口、排序 tie 行为、desired set 和 cache admission/eviction 为 oracle。到期但本批没访问的顶点也必须更新；不能只记录当前 expand。
2. 先测事件活跃集和维护工作上界，再确定索引结构；考虑 unchanged/tie 大集合，避免所谓增量索引仍每批全量输出或排序。CPU road executor 若以后接入，也必须明确它与 cache hotness 的语义关系。
3. 先让 hotness/candidate 语义等价，不同时重做 cache allocator。FS resident churn 与 topology invalidation 的分类用于判断 cache 后续空间，不能借旧 replay 数字直接假定线上 delta 很小。
4. correctness、完整 batch 收益和状态空间/显存约束通过才替换旧链；若事件集接近全图或索引开销抵消扫描收益，停止该方案。保留必要回归和开发 screening，不要求论文实验。

#### I16 历史状态

已执行结果见顶部索引与子报告。旧候选执行清单删除，CPU 传播执行器继续退休。

## 0. 最高优先级研发指令

本节保留科研与正确性原则；任务范围、允许的 batch 规模分类和比例实验以用户本次指令及文末 I19—I22 为准。历史 cohort 限制不能覆盖新计划。

> **总原则：本项目的最终性能胜出必须主要来自可发表的算法与系统架构贡献，例如减少全局传播轮次、形成 device-local incremental closure、降低跨域通信复杂度、按拓扑构造低边界执行域，以及让 CPU/GPU 分别替代对方不擅长的计算。工程优化只能消除新架构的实现税，不能作为论文主线，也不能靠反复追逐 memcpy、kernel launch、线程数、阈值或某个数据集的局部热点拼出性能优势。若一个迭代不能说明它改变了工作复杂度、同步复杂度、通信复杂度或关键路径并行结构，就不得作为主要迭代立项。**

1. **本任务是科研研发任务**。优先寻找能够形成明确研究问题、算法贡献、系统架构贡献和可证伪假设的优化；工作重心必须放在异构增量计算模型、任务划分、状态一致性、局部闭包、通信复杂度和调度算法上，而不是常数级工程调参。
2. **限制模式复杂度**。允许同一系统内按总 batch 更新数分类的常规/大 batch 两种维护策略；初版使用文末冻结的简单规模规则，禁止按图名或比例逐点调参，不以额外特例分支作为迭代主线。小型工程优化统一推迟到核心算法与架构稳定以后进行，不允许为了短期曲线引入未来需要推翻的中间方案。
3. **每次实现都按最终系统标准完成**。常规/大 batch 策略共用语义、状态、发布与检查接口；允许必要的维护策略差异，不复制整个 SSSP runtime。不为历史实验长期保留废弃 kernel、重复状态或无用代码。新架构替代旧能力时必须同步删除旧实现，负结果保存在文档、实验日志、提交或独立 artifact 中，而不是留在生产代码中。
4. **实验范围与主张匹配**。TW/FS 的既有规模 cohort 用于大 batch 维护验证，FS/WK100K 的18组新比例数据用于适应性验证，EU1000K 用于插入闭包。比例、规模和长直径证据分别解释；不把单一小图或历史不同条件结果外推为通用收益。
5. **所有迭代只用流式 batch 时间判断性能收益**。主要且唯一的性能 gate 是 batch 级 `[P0-TIMER]` 求和，即 `paper_algorithm_ms`；图加载、初始计算、首次 cache 建立、最终检查和其他 timer 外工作不进入论文算法时间，不能用完整进程 wall time 否定已经成立的 paper-time 收益。
6. **允许用一次性成本换流式性能**。可以增加初始化时间或适量 CPU 内存来降低 `paper_algorithm_ms`，但不得把原本属于 update batch 的工作移到 timer 外规避统计。初始化 wall、CPU RSS 和一次性物化量继续记录为部署诊断，不作为流式性能 gate。
7. **cache 容量由用户指定，系统不得代替用户决策**。`--cache` 是外部配置，同一对照必须使用相同的用户指定值；runtime、planner 和实验脚本都不得按数据集自动扩大、缩小或改选 cache。除该用户配置本身占用的显存外，系统不得通过新增常驻 GPU 副本、队列或 staging 换取 paper-time 收益；同一 `--cache` 下系统额外 GPU 峰值不得高于基线，并必须考虑后续 UK-2007 的可运行性。

由此派生的代码准入规则：

- 每个能力只能有一个 authoritative implementation；GPU-only、CPU-GPU 等模式通过同一执行框架的资源配置表达，不能复制执行流程。
- 新抽象必须同时减少语义重复或支撑至少两个算法/执行设备，不能只包装现有 SSSP 特例。
- 每个迭代验收正确性、完整性能、维护放大和复杂度；模式数量固定为常规/大 batch，不能用净代码行数代替架构收敛判断。
- 研究消融通过统一组件的参数化接口、独立 commit/build artifact 或离线 replay 完成，不以永久保留废弃实现为代价。

当前成立的 CPU 服务是 source-local topology mutation，GPU 承担 SSSP state/propagation/cache。I12、I15 CPU索引和CPU传播路线的否决记录保留；未来研发只按文末 I19—I22 执行。

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

#### E5 历史裁决

原验收被 F 的实际 crossover 取代，未执行矩阵和强制 CPU share 计划删除。

#### 迭代 F：deletion sub-DAG 双执行域计算（已结束，2026-08-24）

> **最终状态**：F1-C 唯一生死门未通过，F2-F4 均未进入实现。两张真实图在偏向 CPU 的成本下界中仍无净收益，继续补 production snapshot、owner runtime 或更多 cohort 只会增加已被否决路线的实现成本。F 的生产 capture 已移除，离线 trace/replay、真实图负结果和 R-MAT crossover boundary 保留为 artifact；cache patch 的工程验证转交 P0，不再延长 F。

F 直接接在 E4-R1/R2 之后，不复用 E4-R3-C 的 partition-round dispatcher。主问题收敛为：**在真实 deletion affected dependency graph 的 SCC condensation DAG 中，能否找到 predecessor/state visibility 可闭合且计算量足够大的 sub-DAG，让 CPU 与 GPU 并发完成互斥的图算法服务，从而删除 GPU 关键路径上的同一 repair work。** weak component 只作结构上界，不再是默认 owner 单元；单个 SCC 也不能被强行切成碎任务。CPU 不是 metadata 辅助线程：它必须完成 owner sub-DAG 的 incoming traversal、min-plus reduce、value/parent commit、non-sink local frontier expansion 和 closure。cache/topology touched-only patch 只为该架构消除实现税，不作为 F 的科研主贡献。

第三方实现只作为机制参考，不作为移植目标：

- `CGgraph-V1.5` 证明真实 frontier 应按 degree prefix-sum 和设备实测服务能力做互斥切分；但其全量 state H2D/merge、固定 active-work 阈值和数据集预跑比例不能进入本项目。
- `CGgraph-V1.5` 的 sink 语义必须精确区分：CPU/GPU 仍执行对 sink 的 relax/value 更新，sink 只是不会被加入下一轮 frontier；`notSinkBitset` 同时用于 CPU/GPU 分工时的有效 edge-work 估计，避免把零出度顶点分配成传播任务。本项目保留 sink 的 incoming reduce、value/parent commit 和 visited 状态，但在 owner planner 的 propagation work 与 frontier partition 中排除其出边贡献；不能把 sink 从本轮迭代计算中删除。
- `GraphBolt/KickStarter` 证明 deletion 可以分成 deleted-parent seed、affected trimming、一次 incoming pull 和后续增量传播；但其 `O(V)` bitset 清零/扫描不能用于大图生产路径。
- `RadixGraph` 证明旧快照可读、新版本日志构造、时间戳可见性和读者退出后回收能够支持读写并发；本项目只借鉴 batch-epoch publication，不接受逐边时间戳、链式全版本或独占全图 snapshot compaction。
- `POEGA` 的高低度划分可作 irregularity 消融，但固定 `degree_limit` 不是 planner，也不能作为 TW/FS/EU 的 dataset-specific gate。

当前不需要继续泛读其他仓库。只有 F1-C 暴露出具体结构缺口（例如 SCC/boundary closure、terminal sink 裁剪或 owner-local state 表示）时，才围绕该缺口定向检索；禁止先移植完整动态图库再判断是否有关键路径收益。

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

##### F1-C：deletion sub-DAG 可行性与唯一生死门

F1-C 是一个完整、有界的可行性阶段，不再把 trace 字段、单图重采、analyzer 指标或 fixture 各自命名为新迭代。已有结构工具和多图 trace 统一视为 F1-C 的已完成证据；后续只允许一次候选审计补全和一次同语义 crossover replay，然后作进入 F2 或结束 owner 路线的决策。

候选执行关系必须先分清，不能把所有 predecessor-closed sub-DAG 都按并发收益处理：

1. **独立 weak component / 无跨 owner 依赖的 branch bundle**：CPU 与 GPU 可真正并发，各自 closure 后共同 quiescence；这是首选候选。
2. **CPU 上游 predecessor-closed prefix -> GPU successor**：CPU 输入只需稳定 snapshot，但 GPU 后继必须等待 CPU 最终 state publication；这是串行替代，不得把 CPU/GPU wall 写成无条件 `max()`，只有 CPU 完整服务本身快于被删除 GPU 服务时才可能胜出。
3. **GPU predecessor -> CPU downstream suffix**：CPU 输入会随 GPU closure 改变，需要 iterative event/version；在前两类未胜出前不实现，也不能用来绕过 snapshot/critical-path gate。

现有按确定性拓扑序生成的 25/50/75/100% work prefix 只用于暴露结构与成本范围，不是生产 planner。最终候选必须同时报告 `snapshot input cut`、`CPU-owned internal service`、`CPU -> GPU successor cut`、GPU 可独立执行 work、GPU 必须等待的 dependent work 和 sink terminal commit；只报告 incoming/internal/outgoing 总数不足以批准 replay。

F1-C 的工作收敛为：

1. **结构与语义证据（已完成）**：trace/analyzer 已覆盖 affected CSR、sink、weak component、SCC condensation、snapshot boundary 和真实 changed-source event；TW/FS/R-MAT 连续 10 batch 已证明 predecessor-closed 候选的 iterative changed-boundary 为零。Europe 当前 source/update cohort 的 affected 全为零，属于无效样本，不能用于 gate。
2. **候选审计补全（唯一允许的分析补项）**：在已有 condensation DAG 上增加 CPU→GPU successor cut、independent GPU work、dependent GPU work 和 critical-path depth/work；按上述三类执行关系分组。优先选择完整独立 component 或无跨 owner 依赖的 bundle；只有独立 work 不足时才保留上游 prefix 作为“串行 CPU 替代”候选。补项只扩展离线 analyzer，不改 production runtime，不再重采已有有效 trace；Europe 只在能从现有数据/程序语义确定合法非空 source 后补一个连续 10-batch cohort，否则明确缺失，不反复试 source。
3. **同语义 crossover replay（F 的唯一实现实验）**：persistent、NUMA-aware CPU worker 完整执行候选的 snapshot gather、incoming traversal、min-plus reduce、value/parent commit、sink terminal commit、non-sink expansion、closure 和 sparse publication；GPU replay 处理互斥的剩余 destination work，并删除 CPU 已接管的相同 service。至少覆盖 Twitter、Friendster 和 R-MAT 的代表 cohort；R-MAT 只决定 workload boundary。replay 必须分别给出独立候选的 `max(CPU service, GPU independent service) + final fence`，以及 prefix 候选的 `CPU service + GPU dependent successor service`；不得把两类公式混用。
4. **支撑工程项（F1-C0，2026-08-18 已完成首轮）**：cache identity trace 揭示的放大并不只是 snapshot/diff 观测成本。旧路径中，任一 touched hot source 失效都会触发整批 `evication_cache -> compact_cache -> LoadCache`，把 source-local topology patch 放大为整个用户指定 cache 的重排与重载。生产路径现改为 producer-native touched-only cache publication：degree 不增长时复用原 cache slot；degree 增长时只把该 source 的当前 adjacency 追加搬迁到同一 `--cache` 分配的未用尾部并更新 descriptor；只有尾部容量不足才失效并回退原全量 compact。candidate 阶段精确检查所有 desired resident 是否仍有有效 cache entry，resident set 与 payload 都有效时跳过 eviction/compact/load；检查与 eviction delta 标记分离，skip 不遗留脏 delta。实现不新增常驻 GPU allocation，并修正历史 `type[1]` 实际按两个 `int` 注册的越界声明。

   Twitter100k、batch 0、`cache=2`、`check=false` 的单次 screening 中，patch 为 `18,769` records，cache invalidation 从 `17,723` 降至 `0`；旧 eviction/compact/load 为 `7.868/51.368/35.268 ms`，新路径均为 `0`，publication 为 `2.202 ms`，`total_batch` 从 `157.043` 降至 `50.961 ms`（约 `67.5%`）。随后同图 10-batch performance screening 的 10/10 batch 均为 zero invalidation/refresh skip，candidate + eviction + compact + load 从冻结 F0-L 中位基线 `1096.049 ms` 降为 `42.656 ms`（减少 `1053.393 ms`，`96.1%`）；完整 `paper_algorithm_ms` 从 F0-L 三次运行中位数 `1618.501 ms` 降为单次新路径的 `594.654 ms`（减少 `1023.847 ms`，`63.3%`）。cache tail 从初始 `196,289,923` 增至 batch 9 后 `220,503,704`，仅占 `536,870,921` edge capacity 的 `41.1%`，本 cohort 未触发容量回退。该完整时间仍是单次 10-batch screening，需交错重复后才可作为正式统计结论。

   Twitter 连续 10-batch `check=true` cohort 的 10/10 deletion-stage 与 10/10 batch check 全部通过，10/10 cache refresh skip；最终 `relaxable_edges=0`、`missing_tight_witnesses=0`，distance checksum 为冻结值 `12687655862474487153`，overall test passed。Wiki100k 的 degree-growth correctness cohort 进一步覆盖 `97,246` touched source：`cache_invalidations=0`、refresh skip、eviction/compact/load 均为 `0`，topology audit 为 zero mismatch，batch/final Bellman、tight witness 与最终检查通过；其 `check=true + topology_replay_audit=true` 的 `total_batch=1184.820 ms` 仅作正确性证据，不用于性能横比。后续仍需通过可控小容量/长序列验证尾部耗尽后的 full-compact fallback，并在 FS/EU 上完成同一 10-batch gate。

   trace 审计同时发现旧“identity unchanged”只比较 resident vertex ID，漏报同一 ID 的 degree-only 变化；现已改为精确比较 `(vertex, degree)`。cache 修复只消除既有实现税，不独立通过 F gate，也不把 CPU metadata 工作宣称为异构计算收益；F1-C 主线仍要求 CPU 接管完整 deletion sub-DAG graph service。
5. **关闭项**：insertion exact closure 在现有主图低于完整 batch 的 0.2%，不继续 CPU 分担；不恢复 static vertex owner、source ranking、packet capacity sweep 或 partition rounds；不再为 changed-source channel、任意拓扑前缀比例或单一 trace 指标单开迭代。

**F1-C 已完成证据（2026-08-19--20）**：production trace v2 与离线 analyzer 已统一覆盖 affected CSR、out-degree、sink、weak component、有向 SCC/condensation、snapshot boundary 和逐轮真实 changed source；trace 关闭时不增加 D2H。analyzer 的拓扑前缀仅作诊断，sink 始终参与本轮 reduce/commit，只有 propagation work 为零。chain + terminal-sink + duplicate-boundary fixture、trace round-trip 和 Wiki `check=true` 端到端验证均通过。原始多图结果位于 `logs/f1c2_trace_v2_20260820/`。

**候选审计与 crossover replay（2026-08-20）**：离线 analyzer 现按既有 work 排序保留 top-8 候选，并为它们计算 CPU→GPU direct successor cut（edge/source/destination）、CPU complete-service work、GPU independent/dependent complete-service work 与各自 SCC critical-path depth/work。一个 service unit 精确包含 incoming reduce、每顶点 commit 以及非 sink 的 outgoing expansion，故 sink 只省传播，不省 reduce/commit。Twitter、Friendster、R-MAT 的连续有效 trace 中，每个 batch 的 top candidate 都是 `successor_cut_edges=0`、`dependent_gpu_service_work=0` 的完整独立 component，仍为 `changed_boundary_sources=0`。一次性稀疏状态采集仅保存 `affected ∪ incoming-source` 的输入 value/parent 与 affected 最终 value/parent；三个 cohort 各只采集一次、各回放一次，结果保存在 `logs/f1_crossover_capture_20260820/`。离线 `f1_crossover_replay` 使用 persistent CPU worker 实际执行候选的 incoming min-plus reduce、commit、sink terminal commit 与 closure，GPU 对互斥的剩余 destination 执行同一语义 closure，最后稀疏合并并做 value 校验。三个 cohort 的 10/10 batch 均为 `overall_value_mismatches=0`；parent 差异是并行相同最短路的平局选择，仅作诊断。中位 independent window 为 Twitter `4.514 ms`、Friendster `44.536 ms`、R-MAT `78.908 ms`；其中 `snapshot_ms` 是离线稀疏记录索引时间，生产 snapshot 的口径由下述收尾决定单独处理。R-MAT 仍只定义 workload boundary，不进入真实图性能 gate。生产采集 flag、CUDA gather kernel、state writer 与 capture members 已在回放后移除；正常执行路径不含这项实验代码。含 cut 的低排名 prefix 若未来被选择必须使用 CPU service + successor fence + dependent GPU service；本轮不再新增 trace、production owner runtime 或参数扫描。

**F1-C 收尾决定（2026-08-20）**：上段的 `snapshot_ms` 是离线稀疏记录重建和索引成本，并非生产 authoritative GPU state 的 D2H snapshot，不能把它声称为生产 snapshot 已主导。为避免这一口径错误，按同一 deletion repair 可见边界重新比较已有日志：all-GPU 的中位 `topology + H2D + closure` 为 Twitter `3.688 ms`、Friendster `22.770 ms`、R-MAT `133.701 ms`；一次 crossover 的离线 candidate window 为 `4.514/44.536/78.908 ms`。后者仍未计入真实 D2H sparse gather、常驻 CPU state/mirror 维护、GPU 输入上传分配和生产 version/publication，因此只是对 CPU owner 有利的下界。即使在该下界，Twitter 慢 `22.4%`，Friendster 慢 `95.6%`；两张真实图均无 `net_cpu_takeover_gain > 0`。R-MAT 快 `41.0%` 只说明高 closure、无 cache 的合成边界可能存在 crossover，不满足真实图 gate。故 F1-C 否决 deletion CPU graph-computation owner，不进入 F2，也不为该路线追加采样、阈值、owner map、partition 或持久状态 runtime。临时 production capture 已回收；离线 trace/replay 与负结果保留。

**历史结论**：CPU 服务收敛到 touched-source topology mutation、reverse-delta construction、descriptor/cache publication。F 后原拟议的 dual-version pipeline 未来计划删除；R-MAT crossover 不能外推为通用 CPU owner 收益。

Twitter、Friendster、R-MAT 各完成连续 10 batch。Twitter top 诊断候选的 internal incoming / snapshot source / non-sink outgoing work 分别为 `34--4,030 / 461--37,857 / 1,146--43,029`；Friendster 为 `1,154--40,796 / 15,221--532,964 / 24,463--560,067`；R-MAT 为 `3,066--364,234 / 76,365--2,836,582 / 88,169--8,922,964`。R-MAT 因 67M vertex 在 V100 `cache=2` OOM，按机制口径使用 `cache=0`，不进入真实图性能 gate。Europe 当前 source/update cohort 10 batch affected 均为零，是无效样本。

三组有效数据的 top predecessor-closed 候选全部 `changed_boundary_sources=0`。这不是需要继续采样的概率结论，而是 affected-only pull 与 predecessor closure 的结构性质：能在 repair 中改变并影响候选的 source 必为 affected predecessor，因而已属于 internal state。F 不建设 iterative changed-source runtime。剩余未知量是一次性 snapshot/mirror 成本、CPU→GPU successor cut 与 dependent GPU critical path；真实图 snapshot source 常比 internal incoming 大一个数量级，且上游 prefix 可能把原 GPU 并行工作改成 CPU 后接 GPU 的串行链。这些未知量统一留给下一次候选补全和唯一 crossover replay，不再拆成小迭代。

每个 replay 必须处理相同逻辑记录和相同最终语义，CPU 使用启动前固定的 persistent worker pool；计入 state gather/scatter、CPU→GPU successor publication、quiescence、NUMA/RSS 和 GPU 被删除服务。不得用 synthetic edge loop、CPU 只扫不提交、GPU hot 数据对 CPU cold 数据、timer 外预处理或小图阈值作为证据。snapshot state 必须从生产 authoritative state 的真实位置读取；若为了 replay 先常驻一份 CPU 全量 value/parent mirror，其维护成本和内存必须完整计入，不能把它当免费输入。

统一决策量为：

```text
baseline_window_ms = 当前生产路径在同一 ready/visible 边界间的 wall
independent_candidate_ms = snapshot + max(CPU complete service, GPU independent service) + final publication/fence
prefix_candidate_ms = snapshot + CPU complete service + successor publication + GPU dependent successor service + final fence
net_cpu_takeover_gain = baseline_window_ms - candidate_window_ms
```

决策时按候选关系将 `candidate_window_ms` 取为 `independent_candidate_ms` 或 `prefix_candidate_ms`。二者都已包含 CPU complete service、剩余 GPU service、snapshot/publication、version/reclamation 和最终 fence；不得把 overlap 作为额外正收益重复相加，也不得把 prefix 的 dependent GPU work放进 `max()`。

F1-C gate：CPU 必须承担非零完整 sub-DAG graph service，且 GPU 删除相同 repair service。只有至少两张真实大图 `net_cpu_takeover_gain > 0`、重复方向稳定，并保守预测完整 10-batch `paper_algorithm_ms` 至少下降 5%，才允许进入 F2。R-MAT 单独胜出只证明 workload boundary。若独立 component/bundle 工作不足、prefix 串行 fence 抵消收益、snapshot/mirror 占优、sink 排除后有效 work不足或 removable GPU repair本身受 Amdahl 限制，则 F 直接否决计算 owner runtime；不再新增 vertex map、METIS、source packet、固定比例、partition round或 owner阈值变体。

##### F2—F4 取消记录

F1-C 未通过真实图 gate，F2 生产接入、F3 调度泛化与 F4 预设收官方案未执行，具体计划删除；负结果与原因保留。

##### F 失败后的转向（已执行）

F1-C 已否决 CPU graph-computation owner。停止继续增加 owner map、划分器、packet、比例、阈值和 production CPU closure runtime；可复现负结果与 crossover trace 保留，未胜出的 production capture 已移除。下一阶段由 P 接管：先收口 cache patch 和 Europe cohort，再用新基线画像决定是否存在值得实现的 dual-version topology overlap；该方向在 P3 批准前仍只是候选。

#### 迭代 P：新基线收口与下一架构决策（2026-08-24 起）

##### I4-R：resident-set delta cache（2026-08-25--26，负结果并已删除生产实现）

本轮曾实现单段、随后两段的 resident delta cache 原型。GPU 负责候选排序与 resident delta 分类，主机处理压缩后的变化记录和 extent 规划；两段式进一步允许 primary/secondary overflow 与 shrink reclaim。该实现只作为 gate 原型，不再存在于当前生产路径。

已验证：编译、cache 三项 CTest；Wiki 2-batch correctness；Twitter 10-batch correctness；Friendster 10-batch correctness，delete-stage/batch/final Bellman/Overall 全部通过。Wiki 发布从 53 秒级主机全量集合处理降到约 15--18 ms；Twitter delta 发布约 17--23 ms。Friendster 前期 resident churn 超过 crossover，统一入口自动走内部 rebuild，约 323--351 ms/batch，未再出现旧 `third_*` compaction 冲突或 illegal memory access。

轻量 performance sanity（非收官重复）已完成，日志位于 `logs/i4r_sanity_20260826/`：Twitter 10-batch `paper_algorithm_ms=1021.654`，10 批均走 delta，cache publish 合计 `294.617 ms`；Friendster 为 `6416.829 ms`，10 批均因 resident churn 超过 crossover 走内部 rebuild，cache publish 合计 `3439.229 ms`。两图均正常退出且无 CUDA/illegal-memory 错误，但相对 I3 单次基线 `646.987/4210.008 ms` 明显回退，因此 **I4-R correctness/工程 gate 通过，性能 gate 未通过，不能标记迭代完成**。

I4-R1 归因后，I4-R2 两段式在 Friendster batch 3/4 仍因极端碎片回退，且 host plan 达 `750--851 ms`，结构与性能 gate 均失败。I4-R3 已删除 allocator、delta audit/publish、两段传播和 topology capacity 复用，恢复 I3 cache 链为唯一实现；审计脚本、日志和 correctness 结果保留为负结果 artifact。后续不恢复 selectable old/new 路径。

详细论证与 P3-P5 候选见 `iteration/路线复核与下一阶段执行指引_20260823.md`。当前只执行 P0-P2，不提前写新 runtime，也不把阶段性 screening 做成论文封版实验。

##### P0：F1-C0 工程收口

> **状态（2026-08-24）：已完成。** Friendster 100k `check=true` 连续 10 batch 的 deletion-stage/batch check 与最终 Bellman 全部通过，最终 `reachable=54222900`、`relaxable_edges=0`、`missing_tight_witnesses=0`，日志位于 `logs/p0_cache_closeout_20260824T080611Z/`。新增 `cache_tail_fallback_test`，与 production `ReserveCachePatchOrInvalidate` 共用同一 device helper，定向覆盖尾部容量不足后的 cache invalidation、tail reservation 和 refresh gate；三个 cache tests 全部通过，`hybrid_sssp` 重建通过。

1. Friendster 做一次 `check=true` 的 10-batch correctness 回归，确认 cache patch、拓扑审计与最终 Bellman 闭合。
2. 用受控小容量定向触发 `cache_tail` 耗尽，验证 `patch failure -> full compact/load`；补定向测试。
3. Twitter 做已知 checksum 回归和一次性能 sanity screening。

P0 gate：Friendster correctness、fallback 定向路径、构建与现有 CTest 全部通过，且无数量级性能回退。正式 3/5-repeat 不阻塞 P0。

##### P1：Europe cohort 有效化

> **历史状态（2026-08-25 复核）**：数据有效化和 initial SSSP 修复成立，但 10-batch correctness gate 未通过，因此 P1 不能标记完成。新 symmetric-expanded 99% base 有 `107028226` 条有向边，最大 WCC `32200324` 点、覆盖 `58.9%` update 端点，确定性选择 `source=1`。删除 `Start()` 的 1000 轮伪收敛后，initial 在约 `11742` 轮自然 quiescence并通过 Bellman。早期单 batch 日志曾通过；随后六图统一回归在 Europe batch 0 deletion-stage 出现 `missing_tight_witnesses=1`，batch 1 起持续失败，最终为 `247`。该矛盾并入当前 I0--I2 处理，不能用早期单次结果覆盖长序列证据。日志位于 `logs/p1_europe_natural_init_20260824T133914Z/`、`logs/p1_europe_natural_batch1_20260824T134504Z/` 和 `logs/large_six_dataset_20260824T170000Z/`。

按 update 端点与源可达域的可解释关系选择 source，不盲扫、不按性能挑选。10 batch 中多数 batch 至少触发一种有效增量工作，整个 cohort 同时包含非零 deletion repair 与 insertion closure 样本，并通过 `check=true`。只有证据证明 update 流本身无效时才修生成脚本并记录参数。

##### P2：轻量关键路径画像

> **历史状态（2026-08-25）：TW/FS 画像完成，EU 运行完成但 correctness 失败。** TW 单次 `paper_algorithm_ms=593.507`，deletion/add/hotness/candidate 分别占 `37.14%/26.89%/28.82%/7.15%`；FS 单次 `4332.632 ms`，deletion/add/hotness/candidate/compact/cache_load 分别占 `29.91%/21.81%/8.54%/9.91%/14.93%/12.49%`，阶段残差均低于 `0.01%`。这些数据足以批准 I4 的语义原型，但在 I1 修复后必须由 I3 重采，不能直接作为性能基线。运行目录为 `logs/p2_lightweight_20260824T135650Z/`。

在含 cache patch 的当前二进制上，对 TW/FS/EU 各做一次关键路径 screening，必要时补第二次交错运行。复用现有 F0-L 脚本，记录各阶段占比、执行方和读取的拓扑版本，输出 hotness/candidate 增量维护收益上界与合法 topology overlap 上界。P2 只服务 P3 决策，不要求论文级重复或残差 `<=2%`。

P2 的原 P3 决策已由顶部 I0--I5 执行队列取代：先修 correctness，再重采基线并实施 touched-only hotness/candidate；dual-version runtime 仍须先通过至少两张真实图合法 overlap 上界 `>=5%` 的 gate。

## 11. 实验与验收要求

### 11.1 研究假设

后续实验应围绕以下可证伪假设组织，而不是只报告某组参数更快：

- **A0：结果可信**。连续 mixed batch 的 deletion-stage 和 final state 都满足 Bellman 与 existential tight witness，checksum 可重复；stored parent mismatch 仅作诊断。否则只修 correctness。
- **A1：当前回退可由少数关键阶段解释**。deletion、insertion、cache refresh 的 wall-time 分项可加和，且 deletion 内的 rebuild/invalidation、state D2H、CPU boundary/local closure、commit 和 PMA update 能解释主要成本；否则继续补观测。
- **A2：CPU 机会必须由工作而非设备空闲推导**。只有在主图上同时看到可观 CPU-ready work、CPU 路径的含通信净服务成本，以及 GPU 关键路径可被覆盖，才进入 B。单看 CPU idle、GPU utilization 或某个 kernel 慢都不足以选方案。
- **B/C 条件假设**。B1 先决定 deletion 的合法执行域，B2 只稀疏化胜出路径，B3 再检验 fixed-owner insertion 并发。C 检验一个联合假设：source-local chunked adjacency 能否把 CPU 更新的物理影响限定为 touched sources，并使 GPU topology publication 从 `O(V)` 全量 mirror 变为 `O(touched sources)` 紧凑 patch，且在计入 relocation、cache invalidation 和后续 ZC 扫边后仍降低完整 batch 时间。若只降低 update/s 或 H2D 子项，但端到端成本被 compaction、allocator 或 cache refresh 抵消，则该假设被否定，不转而扩大 CPU ownership 掩盖结果。
- **E：通用 topology-first 事件 substrate（历史，已由 F 收紧）**。E4-R 的 exact source/version 与 affected-only reverse merge 保留；E4-R3-C 已取消，production propagation 暂为 all-GPU，不再以“完成 CPU full runtime”作为 F 的前置条件。
- **F1-C：SCC-condensation sub-DAG crossover 假设**。真实 deletion affected dependency graph 中存在独立 component/bundle，或虽有 predecessor->successor 依赖但 CPU 完整 prefix service 加 successor fence 仍低于原 GPU service；CPU 完整接管 incoming traversal、reduce/commit、non-sink expansion 与 closure 后，GPU 可删除相同 destination/internal service。sink 仍参与本轮 reduce/commit，但不贡献下一轮 frontier、owner propagation work 或 outgoing edge work；收益不按 CPU 利用率、metadata 工作或 synthetic throughput 计算。
- **F2：真实执行关系假设**。独立候选的关键路径可按 `snapshot + max(CPU service, GPU independent service) + final fence` 计算；prefix 候选必须按 `snapshot + CPU service + successor publication + GPU dependent service + final fence` 计算。当前 affected-only 语义下 iterative changed-boundary 为零，不建设无必要的每轮 state gather/event channel。
- **F3：结构泛化假设**。independent component/bundle、SCC condensation sub-DAG 与 sink terminal closure 的选择可由实际 incoming/outgoing work、snapshot source、CPU->GPU cut、dependent successor work 和设备同语义服务曲线统一决定；weak component 只作候选上界，不能使用 dataset id、固定 CPU quota、degree threshold、partition round 或最后全图 sweep 制造参与。
- **G：事务化最终态协同假设（历史 I12 路线）**。mixed batch 的 deletion-only 中间 SSSP fixed point 不属于外部可见语义；CPU 可在 touched-source next chunks 中一次构造 `G_{e+1}`，同时 GPU 在 immutable `G_e`/SPT 上构造 deletion affected closure。epoch fence 后，由 final-topology boundary recovery seed 与 added-edge seed 驱动一次 device-local closure 即可得到最终 fixed point。该假设已完成语义验证，但 Friendster 性能 gate 失败；不再作为当前生产主线。

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

## 13. 迭代执行记录与当前I24（I19—I23为历史）

状态：I19 已完成，I20共享规划候选通过两轮短性能门槛并作为large开发基线；按用户要求不再等独立大图正确性检查，I21删除位置复用短测结束、默认关闭归档；I22 EU insertion低度线程调度短测已否决；距离区间候选已通过EU1M两批短筛查（完整P0下降78.34%），待反向重复和十批验收。18组比例数据、192批CPU验证、42次GPU运行全部收齐；结果与观测限制见 [I19完整报告](subiteration_file/i19_complete_results_20260915.md)。I18 已有历史编号不复用，新工作从 I19 连续编号。旧计划中未执行的候选清单删除，不再并列维护 B5/B6、R 系列或额外收口队列。

研究主线：**batch 规模改变 CPU 拓扑维护与 GPU 增量传播的相对成本；用规模分类的统一变更维护降低数据结构工作放大，用低重复传播处理长直径插入。** 论文贡献由被删除的工作、摊还维护代价、可见性协议和完整性能共同支撑，radix、warp、NUMA 等作为支撑实现，不按优化项数量累计创新点。

### 13.1 共用契约和模式边界

- 总 batch 规模定义为 B = insertion requests + deletion requests，K=1000；100K 是每批共 100,000 条，不是删/加各 100K。比例 p 定义为 insertion/B，deletion 占 1-p。
- 允许显式常规模式、大 batch 模式，以及只按 B 分类的入口；I20 已实现 `CG_BATCH_MAINTENANCE=regular|large|auto`，开发默认 regular，候选尚未通过完整性能 gate。初版冻结 B >= 1,000,000 为大 batch，否则常规。1M 是现有 100K/1M/10M 开发档位的初始边界，不是已证明的通用 crossover。
- 首先实现并验证显式模式，随后简单分类调用同一策略接口。选择器只看本批总请求数，不按图名、source、insert 比例或测得的耗时选模式。阈值只允许在 I19 证据明确否定初值时统一修订一次，并报告依据；不做逐图最优阈值搜索。
- 分类发生在本批更新开始前；跨 batch 切换不得丢失 reverse overlay、未回收块或 cache/version 状态。若维护策略转换需要工作，转换、整理和回收全部计入当前 batch，空间峰值与切换正确性一并验收。
- 常规/大 batch 共用 authoritative topology、GPU value/buffer/parent、有效更新语义、epoch 和 publication；可以有两种维护策略，不能复制整个执行框架。保留真实删除及 delete-repair-add 两阶段，不重启 I12 最终态事务。
- 完整 P0 batch 总和为性能主指标，阶段按嵌套关系分解。prepare 含 reverse 时不重复相加；初始化、检查与性能运行分列。CPU copy、实际 mutation writes、逻辑边访问、CUDA payload、物理互连字节分列；未测量不写零。
- 同代码配对固定 source、底图、更新、batch 数、cache、worker 数和 CPU/NUMA 放置；原版历史数值只作目标线。affected/SPT 平局波动与图净增减须报告，不能把最终 checksum 相同当作所有中间工作相同。
- 所有 GPU 任务串行使用一张卡，启动前确认无进程且显存为零，不影响其他用户。先 CPU 数据验证与结构 replay，再支付大图 GPU 验证。
- 已否决的 CPU propagation、I12、cache extent allocator、CPU hotness 索引不恢复。新候选必须说明消除哪类重复工作及其代价；单纯缩 vector、增加 shards/workers 或追逐局部 timer 不单独立项。

### 13.2 通信量公平对照：显式账本 + 整组 PCIe 粗粒度观测（2026-09-15 修订）

**用户授权的后台对照（2026-09-15 启动）：** `scripts/communication/run_100k_background.py`，运行目录 `logs/communication_100k_20260915_0815/`，PID与健康状态以目录内 `pid/status.json` 为准。WK/FS既有50p、EU connected-50p，均100K×10批；本版EU开启有序删除修复，原版不改算法。双方GPU0/NUMA0、SEGMENT=32、cache=2；先本版全阶段正确性，再每组三次AB/BA/AB通信采集。结果不一致/截断时保留诊断、拒绝胜负并继续下一组；采样不足统一降级。最多21次串行运行，不等待完成或反复轮询。新实验不属于旧512分段性能基线；工具可测不等于该输入正确性已通过。

**最新裁决。** 用户进一步要求尽量覆盖 zero-copy 且避免复杂编码，因此只比较 memcpy 不再是首选完整方案。两边 mapped-host 邻接均承担重要图读取，原版 `GatherTransfer()` 的旧“传输总量”连 cache hit 都计入，不能作跨域字节。是否 ZC 占主要比例尚无真实图实测，不由架构猜百分比。

**实现。** 保留同一 `communication_meter` 显式 H2D/D2H payload；增加约几十行共用 `communication_window.h` 与整组边界调用，其余工作在 `scripts/communication/` 进程外完成。原版通过 `prepare_baseline.py` 生成独立源码/构建目录并接入相同包装，无需修改原仓库。`sample_pcie.py` 用现成 NVML API 采样 GPU PCIe RX/TX、按整组窗口积分，覆盖该链路上的显式 DMA、ZC 和控制/协议流量，不修改 kernel 或加入逐边 atomic。`compare.py` 验证三份输入哈希、共同参数、GPU、batch 集合、最终 checksum；运行者仍需固定并核对 CPU/NUMA 放置、cache 预算和系统特有策略。

**共同窗口与分列。** 从第一批删除前到最后一批 cache load 同步完成，保留全部更新、传播、hotness 和 cache 服务；初始化、最终 Gather、检查和 trace 排除。原版仍是十批，本版固定同样十批。显式表按 batch 汇总所有 category，H2D/D2H 分列并可相加，D2D/H2H 不入跨域和；未分类方向拒绝完整对照。物理观测只在整组尺度报告 GPU RX/TX 估算，**不能与显式 payload 相加，不能减去 payload 冒充精确 ZC**。性能使用关闭计量的独立运行，correctness 使用同输入独立验证，最终 checksum 一致不替代 oracle。

**退化规则。** 同机实测 NVML 可看到 ZC；约2s probe 的观测/请求比分别 H2D=1.061、D2H=1.105、ZC read=1.062，原始日志见 `logs/communication_audit_20260915/`。这只验证覆盖和量级，不是误差校正系数或真实图通信占比。实际两方向采样间隔约50ms；窗口至少1s且至少50样本、最大间隔不超过100ms才标记粗粒度可用，阈值不是精度保证。任何一侧不足则双方整体通信比较降为诊断/N/A，保留公平显式账本，不继续开发复杂仪器。保存窗口平移敏感性和原始读数；正式粗粒度比较用同 cohort 交错重复，差异小于波动时不判胜负。换机器须核实 PCIe 是否覆盖 CPU–GPU 链路，不冒充 NVLink/其他互连总量。

**本次验证状态。** 双方构建和包装链接通过；4项采样测试、2项计量测试通过。规则图十批四次开关验证中，本版开/关均通过独立 CPU Dijkstra，原版开/关保持相同但错误的最终 checksum（`8853361096970885991`，oracle=`1567344166481677243`）。因此只确认计量开关不改变各自结果，双系统 correctness gate 尚未通过，不发布该输入的通信胜负；原版修复不并入本次低复杂度计量改动。见 `logs/communication_audit_20260915/pair_final/result.json`。 真实 SSSP 双边采样接线也完成，短窗口双方均标记采样不足，比较器因 checksum 不一致拒绝输出对照；未启动正式大图通信矩阵。

**验收与范围。** 计量开关、小图双边十批 CPU oracle、已知 copy/映射读 probe 为工具 gate；正式大图通信胜负仍须同 cohort 的原版/本版采集，不能由工具验证改写为已完成。此项并入 I20 开发准备与 I22 最终裁决，复用已有输入，不扩大原版比例矩阵。详细操作、边界和验证见 [通信测量说明](../scripts/communication/README.md)。

### I19：规模与插删比例下的工作放大画像

**执行状态（2026-09-15）：已完成。** 数据/结构/完整GPU画像及候选裁决见 [I19完整报告](subiteration_file/i19_complete_results_20260915.md)；显式copy之外的通信未测，原系统传输对比未实施。I19收尾时 I20/I21/I22 尚未启动；后续 I20 已进入开发验证，当前状态见下节。

**问题与假设。** 大 batch 的主要矛盾是 touched-source 邻接维护、反复构造批次表示和累计 reverse overlay，而不是 GPU repair 本身；插删比例可能改变搬移、扩容、历史 delta 与未来遍历的代价。先验证这种解释，不能预设某个结构必胜。

**数据生成（本次用户已授权，执行时无需再次请求）。** FS=Friendster，WK=Wiki，复用现有 50p/100K cohort 的底图与完整 ID 映射、固定 source 和权重规则。每图 9 个比例，插入占 10%、20%、…、90%，共 18 个逻辑数据集；每个数据集连续 10 batch，每批 100,000 条，删除数为 100000-insertion。stream-size 文件按 loader 实际字段次序输出，使用不对称 fixture 检查，不能沿用 50/50 猜字段顺序。

生成要求：

1. 先核对现有生成器、底图格式、ID universe 与边的重数语义，固定数据 seed；各比例共用同一底图，硬链接或 manifest 引用，避免复制 18 份大图。保留原数据，写入新目录。
2. 使用相同种子产生确定性的初始存在边删除池和初始不存在边插入池，每 batch 为每类操作预留最多 90K 的互斥候选，比例取嵌套前缀；整个十批不能重用已消费 occurrence。插入池优先来自同源图的 held-out 合法边，避免随机跨社区新边改变图结构；池不足则明确失败并修订生成依据，不静默重复边或注入无效删除凑数。
3. 若源数据是 multigraph，删除按 occurrence/multiplicity 校验；是否允许平行插入在 manifest 中明确，所有比例保持同一契约。不得把 source occurrence 不同误认为 endpoint pair 一定不同。
4. 流式扫描底图验证选中 pair 的初始重数，并用只存涉及 pair 的状态表逐批 replay，验证每次删除确实存在、每次插入满足约定；无需为整个 FS 构建 Python edge set。校验总条数、逐批比例、ID 范围、操作顺序、有效记录数和最终边数。
5. 每批理论净边数变化为 (2p-1)*100000，十批从 -800000 到 +800000；逐批记录实际边数、touched sources、degree 分布及活跃更新范围。净变化是这项比例实验的固有条件，不偷偷加补偿操作。共同底图/候选池不保证 touched 集或可达工作相同，必须报告实际值。
6. 每个 manifest 保存输入路径/身份、seed、节点/边数、source、比例定义、批数、哈希、候选池及重数策略、逐批有效性校验、生成命令。仅所有验证通过才写 ready；失败或不完整不可进入实验。

**实验范围。** 先用现有源码接口做 CPU topology-only replay，覆盖 18 组十批，观察 forward/reverse/publication preparation；这是机制结果，不冒充完整 SSSP。之后当前系统每组一次十批 GPU 完整运行作适应性筛查，正确性与性能计时分开；无需重跑原版比例矩阵。I20/I21 候选复用这些精确数据。FS/WK100K 比例实验不能证明 10M 模式适用性：规模轴使用已有 TW/FS 100K、1M、10M cohort，不新增规模数据；大模式实现后允许在相同 100K 比例输入上显式执行作结构边界验证，但默认分类仍是常规。

**观测与交付。** 同时报告 B、有效更新 U、touched sources S、实际扫描/搬移/写入、effective 表示次数与字节、reverse 新增/累计记录、整理成本、publication/cache 代价、RSS/GPU peak、完整 batch。既有 source_work 是工作范围指标，不改称实际扫描。输出“规模 × 阶段”和“比例 × 维护放大/逐批增长”两张表及异常解释、18 组生成器/manifest/验证结果。

**Gate。** 数据全部合法且可复现；画像可定位完整成本的主要来源。根据证据为 I20/I21 各选一个机制，写出成本预算与否决条件；若某个成本已经不足以影响目标，不启动该候选。不能从 100K 比例表现推断跨规模普遍扩展性，不能用无效更新比例解释成性能优势。

### I20：大 batch 的统一权威变更维护

**执行状态（2026-09-15）：短性能门槛通过，作为 I21 开发基线；按用户最新要求不再安排独立大图正确性检查作为前置。** 两轮正反配对完成，TW/FS10M均值下降7.36%/9.59%；保留显式候选，目标大图全阶段正确性/边界回归未封板；见 [I20开发记录](subiteration_file/i20_shared_plan_20260915.md)。

**假设。** 大 batch 下 forward、reverse 和 publication 各自重建更新含义造成重复准备；一次 source 规划产生的权威有效变更可以供多个消费者共享，使准备按 B、S、U 和必要输出组织，而非反复构造同样的重型对象。

**实现。** 在统一 mutation 接口内实现大 batch 策略：单次 source 分组，source-local 删除匹配/插入规划产生紧凑 phase 范围与有效变更，forward apply、reverse destination 视图和 descriptor/changed-source 发布共享它。不同排序视图采用索引或确有必要的物化，避免为了“单份”增加随机访问；选择依据是总访问/复制和完整时间。明确哪些 metadata 跨两个 phase 可共享、哪些 deletion-only 与 final topology 状态必须分别产生。reverse 所需分配在 forward commit 前成功，失败前可见图不变；不通过合并两次 fixed point 获益。

**验证。** 空 phase、重复/缺失删除、删后重加、容量失败、epoch、模式跨批切换和独立拓扑 oracle。使用 TW/FS 10M 两批目标、1M 模式边界及 100K 常规回归；本项历史验证已完成短配对，后续1M候选验证按I21新计划执行。代表比例预先固定 10/50/90，不按最有利结果挑选。

**Gate。** 删除至少一类系统性重复表示/遍历，报告每有效更新准备字节及时间；同 NUMA 配对完整 batch 获益，候选方向用交错重复确认，常规路径无明显退化且无新增 GPU 常驻拓扑。只减少某个 malloc/vector timer、不减少整体工作或完整时间则否决并撤回。论文定位是变更生产者与多消费者协同维护，不把 radix/线程池单独包装为创新。

### I21：1M 批量准备与发布路径优化

**2026-09-17归档修订：** A单独合并保留进入I24；B并行radix未证明增量收益，C尚未实现，不并列作为当前队列。以下为原计划，旧1M Gate不阻止I24单独合并的10M确认。

**执行状态（2026-09-16）：重新定义为下一阶段主线，先在1M开发档验证。** 原位置复用候选已归档（TW/FS10M仅下降0.76%/0.51%），不再作为后续计划。当前目标是减少批量准备中的重复排序、重复扫描和发布前重排；不改source-local authoritative拓扑布局，不恢复PMA/tombstone或CPU propagation。

**用户明确的规模策略。** 先在1M上实现、验证和裁决候选；当前16GB GPU显存约束不作为1M开发的否决条件。10M在候选稳定后再迁移验证，执行前提醒用户准备迁移/更大GPU；100M延后到更大GPU和容量方案具备后再启动。规模阈值只控制维护模式，不按图名、source或测得耗时选择。

**候选A：source列表有序合并。** delete/add阶段产生的changed-source列表各自已按source有序；发布前采用线性merge+unique，替代拼接后的全量sort+unique。必须处理空phase、重复source、无效删除和跨phase重复，保持严格递增唯一的publication契约。

**候选B：并行稳定source radix与group物化。** 保持稳定顺序、delete-before-add语义和相同分组结果，按固定worker池进行局部计数、全局前缀和及稳定scatter；不把OpenMP微实验收益直接写成生产收益。候选A先做，因为改动小、收益证据更直接；候选B随后在1M完整批次验证。

**候选C：reverse/effective准备定向优化。** 只有A/B在1M完整P0中成立后才进入。优先拆分effective生成、destination排序、slots、merge和commit；不得把嵌套timer重复相加。保持reverse Prepare成功后forward才可见的异常契约。

**1M验证与Gate。** 每个候选使用TW/FS 1M、两批、同输入、同worker/NUMA/cache和large维护模式；候选开关交错至少一轮正反配对，记录完整P0、group/prepare/preflight/reverse/publish、实际records、source-work、RSS/GPU峰值和最终距离checksum。1M候选若完整时间无约5%开发收益，或收益只来自局部timer，则撤回。通过后才迁移到10M；10M是同候选的规模确认，不重新发明一套策略。

### I22：1M通过后的10M迁移与100M延期验证

**2026-09-17修订：** TW10M执行范围由I24具体替代；100M延期不变。无条件迁移更大GPU不再适用于已有16GB同配置成功记录的TW10M。

**状态：后置计划，当前不启动。** I22原EU ordered insertion主线不再作为FS/TW扩展性主线；其已有EU结果与代码保留为独立研究证据。FS/TW的下一目标是确认1M候选能否随规模保持收益。

**10M迁移提醒。** 1M Gate通过后，必须提醒用户迁移到更大GPU/确认显存预算，再运行TW/FS 10M两批候选对照。10M不与1M结果直接合并为单一加速比；报告阶段比例、批历史、overlay增长和空间峰值。若10M收益消失，回到reverse/preflight成本定位，不继续盲目扩大线程或shard。

**100M延期。** 只有10M候选稳定、publication容量按`min(B,V)`或等价分块方案完成、chunk arena/reverse容量画像通过后，才在更大GPU上生成合法100M数据并跑双方同口径两批。100M不是把10M输入重复十次；必须重新满足删除occurrence、插入合法性、批间不重复和内存峰值记录。当前不以100M显存风险否决算法研究，但不宣称100M可运行或可能胜出。

**保留的裁决边界。** TW10M当前距历史目标约0.573秒，优先验证；FS10M仍需约2.183秒，必须组合A/B/C或新证据，不承诺必胜。正式战胜原系统仍需同语义、同输入、同资源且共同结果指纹一致；历史跨系统checksum mismatch只作目标线。

**后续交付顺序（2026-09-16修订）。**

1. 1M：完成候选A source列表有序合并；若通过，再完成候选B并行稳定source radix/group物化；必要时才进入候选C reverse/effective准备。
2. 10M：1M Gate通过后，提醒用户迁移至更大GPU并确认显存预算，再对TW/FS各做两批同候选迁移验证。
3. 100M：10M稳定且publication/chunk/reverse容量方案通过后，延后到更大GPU生成合法数据并做两批双系统筛查。

TW10M和FS10M追平目标继续保留，EU ordered insertion结果作为独立研究证据保留；不再把EU I22作为FS/TW后续主线。I21位置复用、旧PMA/extent路线、旧正式矩阵和其他未执行分支不恢复。


### I23：瓶颈驱动的批量分组构建（2026-09-16新增）

**2026-09-17完成裁决：** 六次TW1M消融完成。仅合并下降7.63%，合并+bulk下降4.07%，bulk相对仅合并回退3.86%；否决bulk，原条件队列未进入10M。下方为历史执行说明，当前转I24。

I21 A+B在1M完整Gate未通过后，按用户允许证据驱动改进方法的授权，先对group物化使用count-prefix-scatter构建，而非直接扩大线程或重做统计精简。原始排序、仅合并、合并+bulk三配置正反消融用于区分收益。TW1M通过组合与增量门槛后再TW10M；任一优于原系统为目标，无需同时追平FS/TW。当前实现与后台范围以上方I23权威状态及子报告为准；只有完整P0改善才保留，历史目标线不代替原版同口径正确性与资源核验。


### I24：TW10M publication合并定向确认（2026-09-17）

**状态：下一执行项，尚未运行。** 详细规格、实验顺序及止损以[I24计划](subiteration_file/i24_tw10m_publication_20260917.md)为准。

**机会预算。** I20 large两批均值11.288533s，历史原版10.715850s，差0.572683s；首批10M合并机制净省0.295830s，简单两倍只略超缺口，第二批和完整成本尚未确认。I23纠错后的仅合并1M改善7.63%，支持单独规模确认，不能保证10M收益。TW机会强于FS，不复活bulk/radix/线程扫参。

**运行。** 同冻结binary、同既有TW10M输入，两批×off/on/on/off四次；仅切换CG_MERGE_PUBLICATION_SOURCES。固定20 workers、NUMA0、large、reverse64、cache2、SEGMENT512、block传播，其余失败候选关闭。输入/结果指纹、GPU锁和外部占用检测、阶段及内存记录齐全；后台健康后不持续轮询。无需因旧1M组合失败而停止这一独立候选，也不自动启动FS/100M。

**裁决。** 两对完整P0均改善、均值约>=5%为开发收益；两次on均低于历史目标只记为历史线通过，随后才条件性做最小同语义原版新配对。共同checksum历史差异必须核实，不以省略reverse、减少有效更新或改cache预算求胜。若不能低于历史线，报告真实剩余预算；没有足够可消除成本则止损。默认策略不自动切换。
