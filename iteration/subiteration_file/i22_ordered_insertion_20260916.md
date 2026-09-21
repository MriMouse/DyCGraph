# I22 GPU 插入距离区间闭包（2026-09-16）

## 范围与依据

本轮按用户要求集中一个数据集，选择 EU1000K；不恢复四项全矩阵。I19完成、I20共享规划保留、I21默认关闭，I22 thread/source已否决。TW1M已低于历史目标线但非双方同条件正式扩展性验收，TW/FS10M缺口保留。

上一轮 EU 两批 block/thread 分别处理254.69亿/248.63亿边，waves均7334/7324，thread完整成本回退82.74%。因此改为控制重复松弛，而非继续调线程粒度。

## 实现与正确性契约

`framework.cuh::RunExactGpuClosure<..., Ordered>`增加显式`CG_INSERTION_SCHEDULE=ordered`，默认仍block。每轮在当前队列GPU buffer上归约最小距离，仅服务 `[min,min+127]` 的任务，较远任务不提交value而带入下一队列；carry与松弛事件使用同一wave ticket去重。较远顶点被再次改善时，其pending任务仍保留，下一轮读取最新buffer。直到队列为空才结束；ticket复用前主动失败，避免静默丢任务。

宽度128来自所有输入共享的权重规则`(src+dst)%128+1`，不按EU名称、顶点ID、batch序号或测得耗时选策略。它是距离窗口原型，不声称实现完整delta-stepping/light-heavy分桶。扫描所有pending任务与carry可能成为新瓶颈，须计入完整P0；不得只比较processed_edges。复用动态邻接、GPU权威状态、Combine/Accumulate和既有hotness/cache服务，不新增CPU propagation或常驻GPU图副本。工作区增加一个uint64最小值，旧四项计数口径不变。

## 验证与实验状态

开发首版构建通过，但三批小图首次试跑遇到CUDA错误；失败日志保留于`logs/i22_ordered_20260916/smoke/`与`window_smoke/`。故没有直接放行EU大图。定位与后续验证见下方追加记录。

新增`tests/i22_ordered_insertion_test.py`：远距离竞争shortcut、断链、删后恢复三个mixed batch；用独立Python Dijkstra计算每次删除后与插入后的完整距离checksum，共六个stage及final对照，另检查Bellman通过。旧非对称fixture另保留删除快照CPU PQ验证。

准备脚本`scripts/run_i22_ordered_short.py`：同一冻结二进制、EU历史cohort/source1/cache2、NUMA0、20workers、64reverse shards、I20large、I21关闭、ordered deletion开启；block/ordered各连续两批，共两次。输入哈希、完整P0、插入时间、offered/processed sources、processed edges、waves、RSS、checksum分列。每次15分钟上限、GPU共享锁及外来进程检测；候选失败即停止，不自动扩大矩阵。两批收益不等于EU十批1189.302→783.060秒目标达标。

### 首次失败定位

统一kernel选择时错误沿用`decltype(DeviceObject())`作为实参类型；该接口返回`const PMAGraph&`，而cooperative launch参数区传入的是按值graph对象。原代码occupancy与launch使用不同模板类型，本次合并暴露ABI不匹配。改为先创建按值graph，再以`decltype(graph)`同时选择kernel和查询occupancy。首次失败不能解释为有序算法失败。原始sanitizer还记录初始化中的既有invalid-configuration调用，未将其记为通过；以修复后实际fixture结果作本轮gate。

### 修复后验证和后台交付

- `build_v2.log`：hybrid_sssp构建成功；`smoke_driver_v2.log`：ordered三批非对称插删Bellman及首批删除CPU PQ通过。
- `window_smoke_v2/result.json`：六阶段独立Dijkstra checksum逐项一致，final一致；其三批offered sources为641/2238/641，processed sources为548/2041/548，说明fixture确实覆盖pending携带和重复事件处理，不只是单条链。
- `block_smoke_driver.log`：默认block三批Bellman与删除CPU PQ回归通过。Python语法与本轮C++ diff whitespace检查通过。未宣称完整sanitizer通过。
- occupancy现在对实际按值kernel实例查询；双方使用同一冻结二进制重新配对，不将旧block时间作为本次配对基线。
- 后台runner PID **1447857**，目录`logs/i22_ordered_20260916/`；`status.json`记录实时状态，`summary.json`仅在两次完成且checksum一致后产生。`candidate/hybrid_sssp`与`framework_frozen.cuh`冻结本轮输入代码。旧失败二进制和日志保留。

启动时只完成候选实现与小图gate；后续短配对结果见下节，重复性与EU连续十批验收仍未完成。健康确认后按用户既有要求不持续轮询长实验。后续先审阅完整P0和processed_edges：若工作下降但carry/最小值扫描抵消收益，应依据offered工作放大评估真正的稀疏桶存储，而不是扫桶宽；若完整收益成立，再安排反向重复和EU十批。TW/FS10M暂不并行开发，避免变成四数据集同时调优。


## 两批短配对结果与裁决（2026-09-16）

两次正常完成，原始`summary.json`与两侧`run.log`交叉核对。双方同一冻结二进制、800 blocks × 128 threads；最终distance checksum均为4612202113968985553，可达顶点均26156568。parent checksum不同，保留执行顺序/SPT平局差异，不把distance checksum当完整大图oracle。

| 指标（连续两批合计） | block | ordered | 变化 |
|---|---:|---:|---:|
| 完整P0 | 195.076038 s | 42.245784 s | 下降78.34%，4.62× |
| insertion converge | 172.925756 s | 20.326482 s | 下降88.25% |
| processed edges | 25,366,217,005 | 108,131,195 | 下降99.57% |
| offered sources | 12,273,604,385 | 5,821,183,779 | 仍有大量carry/扫描 |
| waves（逐批） | 7334 / 7324 | 22293 / 22455 | 增加，非轮数下降 |
| 含初始化进程墙钟 | 370.061 s | 214.748 s | 与P0分列 |
| 最大RSS（KiB） | 13,654,992 | 13,663,540 | 约增加8.35 MiB |

逐批P0为91.981/103.095→20.773/21.473秒，两个batch方向一致。完整P0扣除insertion converge为22.150→21.919秒，主要收益确实来自插入闭包。距离窗口大幅减少实际边松弛，即使waves增多、pending扫描仍大，完整服务收益仍成立；不是仅局部计时获益。

**裁决：保留显式ordered候选，短筛查通过，默认block暂不修改。** 本次是一轮block→ordered，两批，不是交错重复，也未重跑原版；不能外推为EU十批已追平历史783.060秒目标。下一步应做反向短配对确认与EU连续十批验收，不因首次大收益立即继续调桶宽。用户此次询问结果，本次仅审阅并回写结论，未启动新实验；I22整体仍未完成。


## 用户授权的适用范围后台筛查（2026-09-16）

按用户最新要求新增单次粗筛，不做交错重复、CPU oracle、Bellman或checksum检验。范围：FS/TW/EU/USA各10K、100K，FS/TW各1M、10M，共12组，每组block→ordered各一次、连续两批，共24次GPU运行；不与历史不同cohort时间直接配对。

入口`scripts/run_i22_scope.py`，目录`logs/i22_scope_20260916/`，启动PID1609502。复用I22已验证冻结二进制并保存SHA256、源码快照、输入路径/大小/mtime与每次命令。NUMA0、GPU0、20workers；维护模式auto（小batch regular，大batch large），删除有序开关、reverse shards与source/cache/hybrid沿用各组现有manifest，组内不变。USA沿用hybrid2，其余hybrid0；这是组间既有配置差异，不将组间绝对时间作策略对照。

每次20分钟上限；运行失败/超时写失败条目并继续，其配对不计算收益，GPU冲突则停止整队列。`status.json`每5秒更新当前任务、子PID、已完成次数；`report.md`每对结束追加完整P0与插入时间对比；详细边/source/waves见`results.json`。无自动切换默认策略或后续实验。结果仅用于适用范围及整合入口的初步判断，不宣称正确性验收、稳定加速或跨图自动选择器成立。尤其不能把EU1M收益直接推广到所有小batch，也不能按图名硬编码生产策略。


## 适用范围筛查结果与整合裁决（2026-09-16）

24/24次正常完成，12/12配对完整；每次两批、每组仅block→ordered一轮，按用户要求没有正确性检验或交错重复。以下完整P0包含全部batch服务，不含初始化。

| 输入 | block P0 s | ordered P0 s | 完整降幅 | 插入降幅 |
|---|---:|---:|---:|---:|
| fs_10k | 0.285 | 0.286 | -0.15% | -53.78% |
| fs_100k | 0.527 | 0.503 | 4.48% | -18.73% |
| tw_10k | 0.062 | 0.060 | 2.99% | -48.96% |
| tw_100k | 0.229 | 0.219 | 4.33% | -30.22% |
| eu_10k | 6.810 | 5.164 | 24.17% | 55.99% |
| eu_100k | 29.464 | 16.004 | 45.68% | 80.94% |
| usa_10k | 3.290 | 2.202 | 33.07% | 63.34% |
| usa_100k | 13.334 | 7.406 | 44.45% | 81.83% |
| fs_scaling_1000k | 2.038 | 1.930 | 5.32% | -17.34% |
| fs_scaling_10000k | 13.735 | 14.111 | -2.73% | -19.36% |
| tw_scaling_1000k | 1.716 | 1.705 | 0.62% | -20.37% |
| tw_scaling_10000k | 11.207 | 11.426 | -1.95% | -28.49% |

**机制判断：** EU/USA四个小batch配置插入均下降55.99%～81.83%，实际边处理下降约92.91%～97.24%，完整P0下降24.17%～45.68%；与EU1M旧短配对方向一致，支持长传播而非batch规模是适用维度。FS/TW八组插入全部回退（17.34%～53.78%，小batch绝对增加仅约0.2～0.5ms，大batch约2～23ms），边处理基本不变。FS/TW个别完整P0下降发生在插入之外，不能把这些单次波动归功于ordered；两图10M完整P0反而回退2.73%/1.95%，且大部分差值也来自其他阶段，不把全部回退都归因于新kernel。

**整合建议：不全局默认启用；纳入显式大直径/长传播策略，组合有序删除与有序插入，独立于regular/large拓扑维护。** 不按EU/USA名称硬编码、不因B>=1M自动开启。最小接线可以让未显式设置CG_INSERTION_SCHEDULE时继承CG_ORDERED_REPAIR=1的ordered选择，其他情况仍block；显式block/ordered覆盖继承，保留调度消融和回退。CG_ORDERED_REPAIR本来是删除策略开关，若采用此接线必须同步说明它成为组合策略默认来源，避免静默改义；长期可用统一传播模式入口。当前只作结果审阅与整合建议，尚未修改启用逻辑或宣称所有大直径图普适。

本筛查足以支持开发模式的整合方向，不证明大图正确性或正式稳定收益。未恢复CPU propagation、未启动后续实验；运行时GPU权威状态、非负统一边权及ticket容量等既有边界继续有效。原始数据见logs/i22_scope_20260916/{summary.json,results.json,report.md}。


## 大直径模式首次默认绑定（历史接线，已由下方优先级修订替代）

用户明确要求开启大直径模式就默认包含本方法。本次修改`framework.cuh::RunExactSourceClosure`，沿用现有`CG_ORDERED_REPAIR=1`作为大直径模式入口，不新增图名识别或batch阈值。该入口现在默认包括**有序删除修复 + GPU距离区间有序插入闭包**；这是当前权威行为，覆盖前文“尚未接线/默认不改”的历史状态。

| CG_ORDERED_REPAIR | CG_INSERTION_SCHEDULE | 实际插入策略 |
|---|---|---|
| 1 | 未设置 | ordered（大直径模式默认） |
| 未设置或非1 | 未设置 | block（普通模式默认） |
| 任意 | 显式block/thread/ordered | 显式值优先，便于消融和回退 |

已有显式环境变量不被覆盖；空字符串仍视为非法显式参数。启用大直径默认组合时，应移除遗留的`CG_INSERTION_SCHEDULE=block`设置。`CG_BATCH_MAINTENANCE`仍独立，仅决定CPU拓扑维护，不因大batch自动开启有序传播；沿用GPU ownership与关闭component trace等既有删除有序约束。`[I22-SCHEDULE]`新增`selection=explicit|mode_default`和`large_diameter=0|1`，方便核实实际选择来源。

整合依据为EU/USA10K/100K完整P0下降24.17%～45.68%、插入下降55.99%～81.83%，以及EU1M两批完整P0下降78.34%；FS/TW八组插入全回退，因此普通路径继续block。性能证据为单轮短筛查，不扩写为所有长直径图普适或正式正确性验收。本次仅改变选择默认值和日志，不改有序算法、窗口宽度或队列实现。

验证状态：见本节末追加的构建与模式接线核验结果；未启动新大图性能实验。

### 模式绑定核验结果

`logs/i22_mode_binding_20260916/build.log`构建成功。复用已有2048顶点fixture，SEGMENT=32、每项两批、check=false，普通默认block、大直径默认ordered、大直径显式block回退三项实际运行与日志来源断言全部通过，记录见`result.json`及`*_32.log`。未新增大图实验或正确性矩阵。

另保留一项既有边界：该小图SEGMENT=512、check=false开启有序删除时在第一批插入入口前报`invalid configuration argument`，本次与上一轮冻结二进制均同样SIGABRT（`diameter.log`、`prior_binary_512.log`），因此不是此次默认插入绑定引入；本次未修复该独立配置问题，也未将失败记为通过。实际绑定核验采用SEGMENT=32。日志和文档diff whitespace检查通过。


## 最终模式优先级：无需手动unset（2026-09-16）

用户要求消除环境遗留覆盖模式的使用负担。现改为模式优先：`CG_ORDERED_REPAIR=1`直接选择ordered插入，无论`CG_INSERTION_SCHEDULE`未设置、block、thread或其他遗留值。普通模式下才读取CG_INSERTION_SCHEDULE，未设置默认block，非法值仍报错。日志selection=large_diameter_mode表明大直径模式接管选择；因此无需用户unset，也无需修改shell配置。

仅改变常量默认值无法解决旧环境变量优先级问题，本次修改的是实际选择顺序。启用大直径模式始终包含两种有序传播；batch维护策略独立。前文显式block回退是历史行为，不再适用。旧消融脚本用冻结二进制所得结果仍有效；若用新二进制复跑旧脚本，CG_ORDERED_REPAIR=1下的block/ordered请求都会执行ordered，应以实际日志核验，不能误标成消融对照。

最终优先级验证：hybrid_sssp构建成功；SEGMENT=32既有小图两批运行，普通未设置→block、大直径未设置→ordered、大直径遗留block→ordered三项实际日志断言全部通过。证据`logs/i22_mode_priority_20260916/{build.log,result.json,check_binding.py}`。本次是接线检查，check=false，无新增正确性或大图性能实验。
