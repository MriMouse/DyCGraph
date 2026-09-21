# I24：TW 10M publication合并定向确认

状态：2026-09-17四次TW10M配对完成并复核；当前系统均值改善5.09%，历史目标跨线边界，尚无正式原版胜出结论。此为扩展性方向唯一下一执行项，覆盖旧的1M组合Gate和全面收口建议。

## 1. 已知事实与历史纠错

| 已完成实验 | 两批完整P0 | 结论 |
|---|---|---|
| I23 TW1M 原路径 | 均值1758.9835ms | 同二进制消融参照 |
| I23 TW1M 仅publication合并 | 均值1624.7085ms，下降7.6337% | 前次误报4.07%；保留显式候选 |
| I23 TW1M 合并+bulk | 均值1687.347ms，下降4.0726% | 对仅合并回退3.8554%，不进入本轮 |
| I21 TW1M 合并+并行radix | 对原路径均值下降4.352%，两对1.842%/6.787% | 未证明radix增量收益，不进入本轮 |
| 最后TW1M worker20→32 | 1622.023→1558.158ms，下降3.937% | 单对，不能证明稳定优势 |
| 最后FS1M worker20→32 | 1749.395→1748.111ms，下降0.0734% | 无值得追求的收益 |

上述运行最终checksum均匹配各自既有当前系统参考，不等于原版共同正确性已通过。最后worker脚本未冻结binary、缺少GPU锁与自动checksum Gate，事后核对通过也不补足这些流程，不作为后续runner模板。

旧评估有两点需纠正：1M组合候选失败不能否定单独合并在10M的机会；不能断言现阶段必需架构重写或更大GPU。TW10M现有同cohort/cache2在16GB运行成功，新合并仅增加host scratch，无额外device topology。

## 2. 问题与可证伪假设

近期TW10M两批：grouping约1.692s，mutation prepare约1.549s，preflight约3.208s，其中reverse Prepare约1.580s；apply约0.840s，其中reverse Commit约0.498s。它们有嵌套关系，不得全部相加。主要预算仍在CPU批量准备和维护，而非仅GPU传播；source_work是涉及范围指标，不是实际扫描次数。没有同口径原版阶段差额证据，不能把当前最大阶段直接说成两系统差距的唯一成因。

I20 large重复均值11.288533s，历史原版目标10.715850s，差0.572683s（需下降5.07%）。若希望比历史原版快5%，需降至10.180058s，即节省1.108476s。

**本轮假设：** 两个有序changed-source列表线性合并，能在TW10M减少随source覆盖数扩大的发布前排序成本，且完整收益不被其他阶段抵消。真实10M首批CPU探针334.816→38.986ms，节省295.830ms；机械乘两批为591.660ms，仅略大于572.683ms缺口。第二批、额外scratch、allocator/cache影响和当次系统波动都未验证，因此这是薄余量机会，不是胜出预测。不能将worker、bulk、radix的不同实验收益相加。

FS10M历史缺口约2.183s，现无足够预算，本轮不扩展FS；100M继续延期。reverse分代、关闭reverse或重写GPU拓扑不是本轮既定实现，不以“最新方法”名义改变正确性契约。

## 3. 固定实验与资源

仅TW既有10M cohort，每次两批，每批总请求B=10,000,000（插入/删除各5M），固定source=28512093。使用已有`twitter_10000k_cpu_input.json`及对应performance command的路径和哈希，不新生成数据。

| 项目 | 固定配置 |
|---|---|
| binary | 当前源码构建并冻结，同一binary比较，记录SHA256 |
| 维护 | CG_BATCH_MAINTENANCE=large |
| CPU | GPU0对应既有NUMA0绑定；CG_MUTATION_WORKERS=20 |
| reverse/cache | CG_REVERSE_SHARDS=64；cache=2 |
| 传播 | CG_ORDERED_REPAIR=0；CG_INSERTION_SCHEDULE=block；hybrid=0；CPU capacity=0 |
| 分段/流 | SEGMENT=512；n_stream=3 |
| 关闭候选 | CG_BULK_SOURCE_GROUPS=0；CG_PARALLEL_SOURCE_RADIX=0；CG_REUSE_DELETE_POSITIONS=0；CG_COMM_METER=0 |
| 唯一差异 | CG_MERGE_PUBLICATION_SOURCES=0或1 |

顺序预先固定off/on/on/off，共4次串行GPU运行。不再由I21 A+B或I23 bulk的1M Gate决定是否进入；单独合并已有独立机制与1M消融证据，直接做其10M规模确认。不开启32 workers，不减cache，不关闭reverse/epoch校验/有效变更处理，不改变两次闭包。

运行前核对GPU空闲、NUMA可用、输入哈希和冻结binary。复用已有带GPU锁、外部占用检测、失败停止、checksum核对的runner；它在当前版本已支持`--dataset twitter --size 10000`，本轮不传`--radix`或`--bulk`。执行前审阅接线，并将实际环境完整写入command.json；不要直接复用简化worker sweep脚本。无需重跑旧正式矩阵或强制增加独立大图oracle前置；已有局部语义验证证据需绑定到本次binary/源码，有代码改变则补相应检查。

16GB预算依据为历史相同TW输入/cache2成功运行，而非普适显存保证；记录RSS和采样GPU峰值，OOM即失败停止，不自动换条件。按现有授权在后台执行；健康确认后不持续轮询，status/日志持久保存。

## 4. 验收与止损

1. **有效性：** 每次正常结束，batch恰为0/1，large和merge选择正确；最终checksum匹配该输入既有当前系统参考，比较有效records、changed sources、source-work、overlay与必要工作计数。checksum相同不是中间工作量全部相同的证明。
2. **当前系统收益：** 报告每次完整P0、两对收益、均值/范围、publication排序和主要阶段变化。两对完整P0都改善且均值约>=5%才作为明确开发收益；有正收益但不足5%只作边界结果，不自动推广。任何局部收益被完整回退抵消均不成立。
3. **历史目标线：** 分别列出当次off/on与10.715850s目标的差额。只有两次on均低于该线才标记“两次均低于历史目标”，仍不称正式原版胜出。均值更快但单次跨线记为边界，不挑最好一次。
4. **正式胜出：** 仅当历史目标筛查有希望，才启动最小同cohort、同资源、同计时语义的原版/候选正反配对（4次，作为后续条件步骤，不预先加入队列）。核对底图/更新哈希、权重、source、cache资源、批次定义与共同结果指纹；计时窗口包括双方完整更新/传播/cache服务。原版若仅支持十批，先对齐两批输出/窗口，不拿十批总和与两批相比。既有跨系统指纹不匹配尚未解决；若仍不匹配，先定位差异，不关闭必要工作强行求快，不公布正式加速比。共同指纹只是必要条件，不代替独立正确性依据。
5. **止损：** 本轮不自动恢复FS/100M，不追加worker、radix、bulk扫参。若两次on都无法低于历史线，则报告剩余秒数及可归因阶段；只在细分preflight明确存在大于剩余缺口的可消除成本时另立实现。否则接受TW10M在当前约束下尚无获胜证据，结束这条优化路线。

## 5. 交付

4次命令/输入/binary指纹、完整P0和阶段表、source/有效更新/overlay/内存记录、异常日志及最终裁决。分开回答：合并是否改善当前系统、是否低于历史目标、是否经过有效的原版新配对。代码默认策略不因单轮试验自动改变。

## 6. 本轮执行记录（2026-09-17）

已按本计划启动 `scripts/run_i21_publication.py --dataset twitter --size 10000`，未传radix/bulk。后台PID `3769144`，目录 `logs/i24_tw10m_publication_20260917/`；实时进度以 `status.json` 为准，异常见 `driver.log`。四次结束后由runner生成 `results.json`、`summary.json`，仍须按第4节审阅工作计数、历史线与后续准入，不能把自动完成等同正式胜出。

- 当前源码增量构建成功；冻结binary位于 `candidate/hybrid_sssp`，SHA256记录在status及每次command，相关源码指纹见 `source_sha256.json`。
- 4/4 CTest通过：publication sources、source-local chunk store、grouped update batch、dynamic reverse index；见 `ctest.log`。
- 同冻结binary、large+merge、bulk/radix/positions关闭的三批非对称小图Bellman及首批repair CPU PQ oracle通过；见 `smoke_driver.log`、`smoke/`。不是新增大图独立正确性验收。
- runner仅补充显式 `CG_INSERTION_SCHEDULE=block` 并修正过时的1M-only说明；生产实现及默认开关未改。保留GPU锁、外部进程检测、输入哈希核对、两批完整P0与参考checksum Gate、RSS与2秒GPU采样。
- 健康确认后不持续轮询，遵守主计划后台实验约定。性能尚待结果，不宣称已低于历史线，也未启动原版配对、FS或100M。


## 7. 四次配对完成与结果复核（2026-09-17）

4/4正常完成，两批0/1、large/merge接线及最终checksum `791729548754523982` 均通过runner Gate。逐项复核I19 forward/reverse工作计数及I20规划字节四次一致；publication每批input/output source数一致，reverse overlay每phase依次为5M/10M/15M/20M。无新增大图独立oracle或跨系统共同指纹通过结论。

| 顺序 | merge | 两批完整P0(ms) | 相对历史10715.850ms差额 |
|---|---:|---:|---:|
| 0 | off | 11317.119 | +601.269ms |
| 1 | on | 10719.232 | +3.382ms |
| 2 | on | 10652.624 | -63.226ms |
| 3 | off | 11200.817 | +484.967ms |

两对完整收益为5.2830%/4.8942%，均值11258.968→10685.928ms，下降5.0896%（节省573.040ms）。满足本I24“两对均改善且均值约>=5%”开发收益条件；runner沿用的“两对各>=5%”字段为false，两个判据须区别。publication排序两批均值575.795→55.381ms，减少520.414ms，解释约90.8%的完整节省。合并的完整收益得到支持，保留显式候选，默认策略不改。

候选均值低于历史线29.922ms（约0.279%），但两次一高一低，属于跨线边界；不能写成“两次均低于历史目标”，更不能宣称正式击败原版。GPU采样峰值12685–12689MiB，RSS峰值22329776–22370340KiB，未OOM。四次结果/阶段明细见同目录results.json，原始日志保留。

本次后台队列已结束。尚未启动原版新配对；如继续正式比较，需先处理既有跨系统指纹差异、对齐两批完整计时窗口，不能直接引用历史线公布加速比。未启动FS/100M或追加扫参。
