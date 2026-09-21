# I22 与 CGgraph 算法、架构、调度机制复核（2026-09-15）

状态：EU1000K两批block/thread配对已完成；thread候选完整时间回退82.74%，否决该候选并保留默认block，不补反向配对。I22整体仍未完成。四个历史落后配置仍是唯一性能目标，不扩展性能矩阵。

## 原始证据与源码版本区别

已阅读本地论文 `3-party-project/paper/Cui 等 - 2024 - CGgraph An Ultra-Fast Graph Processing System on Modern Commodity CPU-GPU Co-processor.pdf` 的§5.1–5.4（印刷页1411–1413），以及V1.5下：

- `project/CG_SSSP.hpp`：约350–460行执行域选择与active-edge前缀和，约896/1079行CPU窃取，`balance_CPUGPU`约1414行按activeEdgeNum和frontier前缀切分。
- `project/CG_help.hpp`：`SSSP_DEVICE_SPACE`约498行起，SSSP balance kernel按TASK_PER_BLOCK划分等边量范围，CUB BlockScan与二分将edge task映射回source，共享frontier缓冲后批量追加。
- `src/Basic/Graph/Balance/threadSteal.hpp`以及相关threadState定义。

论文CTA不是CGgraph提出的新算法：将高/中/低度任务分别交block/warp/thread；论文描述的分界为>256、32–256、<32。IWB在此基础上把过载warp的中度任务放到shared memory，交空闲warp处理，减少inter-warp divergence，并使用warp appending。论文CPU部分是顶点级任务窃取加高阶顶点边区间窃取。按需CPU/GPU分配依赖host完整图、GPU子图和每轮状态聚合；GPU调用策略依赖active edges和阈值。

**版本区别：** 本地V1.5的上述SSSP kernel可明确验证的是等边量block/块内scan和shared frontier，不能把它直接称为论文原样IWB。迁移的是机制与成本模型，不把现有CSR指针或阈值直接套进动态chunk/cache/version体系，也不将既有方法包装成新贡献。

## 四目标的机制适用性与执行顺序

| 目标/机制 | 当前证据 | 决策与准入 |
|---|---|---|
| TW1M | I20前已低于历史目标线 | 仅共享路径回归，不重新专项优化 |
| TW10M、FS10M：算法/表示 | grouping、source计划、reverse准备占主要成本；I20共享表示已获7.36%/9.59%均值收益，I21位置复用仅0.76%/0.51%单次 | 保留I20；位置复用默认关闭。后续考虑source有效变更生产与reverse消费的融合/减少重复遍历，不重复已否决per-source统计精简 |
| TW/FS：CPU顶点任务窃取 | 已有FixedWorkerPool原子领取grain=16，实现动态领取而非纯静态分配 | 不为“增加窃取”重写线程池。只有worker尾部拖延证据明确时，才做按source degree+requests工作量分块；将准备/调度成本计入完整时间 |
| TW/FS：CPU边级窃取 | 长source可有尾部，但mutation涉及occurrence匹配、紧凑搬移、source版本与分配 | 可列为条件候选：先对只读匹配/前缀规划分块，结果归约后单source提交；不能让多个worker无协议地原地compact同一source。FS当前apply不足1秒，不能声称独靠它追平剩余2.18秒 |
| EU1M：CTA低度任务粒度 | 既有插入closure每source固定128线程block；历史首两批processed_edges/processed_sources约2.1，约7300waves，约120亿/134亿边处理 | 当前首选短调度消融：显式thread/source对照block/source；只验证低度调度，不宣称完整CTA分级实现 |
| EU1M：算法级有序闭包 | 超大量重复source/edge处理与路网长传播，是I22原始机制目标 | 在本轮调度画像后优先评估距离区间/bucket服务+队列去重，减少重复边量。需要deferred事件、自然终止、value/buffer/parent提交和完整服务计时；不能用离线closure或缩seed代替 |
| GPU IWB、V1.5等边量任务划分 | 更适合混合度/中度warp长尾；EU平均工作度低，TW/FS传播占比低 | 条件纳入：先确认active degree分布/warp尾部，必要时实现thread/warp/block分级或等边量块任务；计入frontier前缀和、scan、shared队列与同步成本。不直接移植IWB当通用加速 |
| CPU/GPU按需平衡、跨域窃取 | 本项目CPU topology与GPU state/propagation异构分工；旧CPU propagation路线因完整服务成本被否决 | 可借鉴按工作量分配思想用于各域内部；不直接恢复CPU接管SSSP。只有新的完整成本下界证明状态交接+通信+双域终止仍有净收益，才重开跨域proposal；本次未立项生产实现 |
| GPU调用阈值 | 现有insertion是cooperative persistent closure，每轮无host frontier同步 | 不搬用CPU fallback阈值：它不能消除已经不存在的逐轮host launch。可研究GPU内部窄frontier/有序服务粒度，仍保持GPU权威状态 |

CPU/GPU拓扑与传播重叠仍受删除可见性和cache/version约束，不恢复已否决I12单最终态事务。任何调度机制必须减少完整成本，不能只改善线程利用率。

## 当前已实现：低度source线程调度

`include/framework/framework.cuh::RunThreadGpuClosure`及`RunExactSourceClosure`增加`CG_INSERTION_SCHEDULE=block|thread`，默认block。thread使用每线程source、线程内邻接循环，取消每source两次block barrier；保留cooperative grid wave同步、原exact-source种子、原CombineValueBuffer/AccumulateBuffer、wave-ticket去重、自然队列终止及相同四项工作量计数。

该候选不改变邻接布局，不增加CPU owner、host逐轮同步或GPU驻留拓扑；仍可能对高度source产生线程长尾，所以显式开启，不按图名隐藏选择，不把它称为完整CTA/IWB。每次kernel按自身occupancy上限配置cooperative grid，差异如实记录为调度代价。GPU计数仍可能有atomic争用，后续以完整运行解释，不先宣称算法重复量下降。

构建通过。复用三批非对称小图：thread实际启用，三批deletion-stage/batch与final Bellman通过，首批删除快照CPU PQ oracle distance_mismatches=0。该CPU快照只覆盖删除，不声称独立插入CPU oracle已完成。依据用户要求，不另排大图纯正确性矩阵。

## 当前短实验

入口`scripts/run_i22_short.py`，日志`logs/i22_thread_20260915/`。复用正式EU1000K同cohort/source1/cache2/ordered deletion1/64reverse shards/20workers，双方NUMA0、I20large、I21位置复用关闭。只改insertion schedule，双方同一新冻结二进制，各前两批完整P0，共2次。输入三文件重新记录SHA256，最终checksum双方比较；两批不与十批历史checksum混用。

保存完整P0、insertion converge、offered/processed sources、processed edges、waves、墙钟。必须区分调度带来的吞吐提升和执行顺序改变导致的实际工作量变化。完整EU十批1189.302→783.060秒目标不能由两批结果直接宣称达标；只用于决定是否值得继续。预计约10～15分钟（加载和调度可能波动），单次15分钟上限，失败或GPU资源冲突即停止，不自动扩大矩阵。

后台PID `483313`。查看：

```bash
watch -n 10 'cat logs/i22_thread_20260915/status.json'
```

`screen_complete_needs_review`表示两次完成，结果`summary.json`；`failed_or_blocked`表示异常停止，查看`driver.log`。本轮结果未出前，不称候选有效或四个目标已追平。

## 首个调度候选结果与裁决

两次运行正常完成，总墙钟约15.1分钟。每项为同cohort连续两批，不含加载的完整P0；双方最终distance checksum均为4612202113968985553，不替代全阶段独立oracle。

| 指标 | block | thread | 变化 |
|---|---:|---:|---:|
| 完整P0 | 196.539943 s | 359.154858 s | 慢82.74% |
| insertion converge | 173.949382 s | 336.080729 s | 慢93.21% |
| processed edges合计 | 25468797880 | 24862669802 | 减2.38% |
| 每批waves | 7334 / 7324 | 7334 / 7324 | 不变 |

结论：平均度低不代表thread/source映射在本runtime更快；这个独立调度候选明显回退，默认block保留，thread仅留显式关闭的实验artifact，不追加重复。未采集硬件profiler，不能把回退确定归因于某一种原因；访存合并/缓存行为、并发atomic争用、occupancy与分支开销均只是待验证解释。它也不是完整CTA分级或IWB的否定实验。

更强的算法证据是两者仍需约1.47万waves和约250亿次边松弛；单纯改变source映射几乎没有削减重复工作。因此下一候选优先GPU有序距离区间/分桶服务，处理deferred frontier和桶内自然闭包，保留exact-source seeds、GPU权威状态、动态邻接读取和最终提交。需计入队列组织/去重/桶扫描等完整开销；不将离线closure速度当生产收益。不继续thread/warp/block尺寸扫参，IWB仍按中度任务长尾证据条件准入。

本次仅审阅和更新计划，无新增后台实验。四个原始目标仍保留：TW1M仅回归，TW/FS10M继续维护成本缺口，EU1M转算法级低重复传播，未宣称追平。
