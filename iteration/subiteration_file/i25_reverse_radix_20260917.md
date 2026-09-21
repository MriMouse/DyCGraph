# I25：TW10M reverse准备并行化，检验能否与历史原版拉开距离

状态：2026-09-17四次配对完成并复核，完整P0均值回退0.79%，否决本候选作为性能优化，默认关闭。

## 1. 本轮授权与目标

用户要求最后基于瓶颈寻找能明显领先原版的方法，允许CPU计算和数据访问/组织调整；若证据不足则如实承认。该授权允许新候选，不再把此前收口建议视为禁止实现。仍遵守后台长实验、完整计时、语义正确、同输入/cache与资源比较要求。

以比历史原版快5%作为本轮“拉开距离”的明确开发筛查目标（是本轮采用的判据，不是用户指定的百分比）：TW两批完整P0须低于10180.0575ms。I24仅合并均值10685.928ms，仍需减少505.8705ms；若要快10%，须低于9644.265ms，仍需减少1041.663ms。最终正式胜出仍需新的同语义原版配对与共同指纹，历史线只作筛查。

## 2. 当前瓶颈与路线选择

基于I24两次merge=1日志，两批阶段合计的均值：

| 项目 | ms | 解释 |
|---|---:|---|
| mixed grouping | 1707.092 | 其中source sort 752.189、物化653.053；此前1M source并行/物化组合负结果，不能直接叠加收益 |
| CPU mutation | 6143.230 | 包含下述prepare/preflight/apply等，不能重复求和 |
| mutation prepare | 1558.936 | source-local准备 |
| preflight | 3259.685 | 包含reverse Prepare |
| forward apply | 837.393 | 邻接应用 |
| reverse destination sort | 787.038 | 4个phase各5M有效记录，当前串行稳定radix |
| reverse group | 304.779 | 首phase pending增长占较多 |
| reverse slots | 265.452 | 分片unordered_map预留及索引 |
| reverse merge | 210.332 | 既有worker池并行 |
| reverse Commit | 488.760 | swap、统计及旧vector释放，独立于Prepare |

已有reverse串行排序是可定位、尚未验证的并行机会，不能与I21 mixed source radix当作同一结果。787ms为整项上界，不是可承诺节省；为了达到5%历史领先目标，单独此项需减少约64.3%，是否可达由整系统实验决定。

暂不恢复CPU SSSP owner：历史F1-C在真实图净接管收益失败，snapshot/mirror、后继依赖和跨域同步是成本；当前新证据主要指向CPU维护，而不是GPU传播。新负载不能凭旧结论永久否定CPU，但没有新的可移除GPU关键路径预算，不先重建完整owner runtime。CPU本来已负责topology，当前方法增加其维护阶段的实际并行度。

## 3. 实现与边界

新增默认关闭 `CG_PARALLEL_REVERSE_RADIX=1`。`SortEffectiveDeltas`接受可选worker pool；DynamicReverseIndex复用已有merge worker池，不新增线程池或GPU存储。按连续逻辑分区统计256桶，再按bucket/分区顺序做prefix，并行scatter；稳定性与调度无关，source已排序时仍只做destination四遍，否则做source+destination八遍。小于65536条或worker不足的输入走原串行路径；原小列表comparison sort保留。

scratch与原radix同阶且数量不增加，额外histogram约workers×256×sizeof(size_t)，20 workers约40KiB。没有跳过有效更新、reverse、epoch或删除/插入两次闭包。准备失败仍发生在reverse可见提交之前。默认不改，收益待测。

## 4. 验证和后台实验

- hybrid_sssp及dynamic_reverse_index_test构建通过，日志build.log。
- 4/4相关CTest通过（CG_PARALLEL_REVERSE_RADIX=1）。排序测试覆盖65535/65536/65537边界、500K记录、任意/source有序输入、极端ID和重复，候选与stable_sort参考逐元素比对。扩大TestManyDestinations至33001 destinations/66002记录，实际进入并行路径并检查重复计数、Prepare不可见/被抛弃及Commit抵消，1/64 shards均覆盖。
- 同冻结binary、large/merge/reverse-radix开启的三批非对称GPU smoke，Bellman和首批CPU PQ通过；小输入走排序串行回退，不能冒充GPU大batch并行路径独立oracle。
- runner新增`--reverse-radix`，固定publication merge=1，唯一差异为reverse radix=0/1/1/0。与bulk/source radix参数互斥，其他CG环境重置；关闭bulk/source radix/positions/ordered，20 workers/NUMA0/reverse64/cache2及同TW10M两批cohort。
- 后台PID **3962971**，目录 `logs/i25_reverse_radix_20260917/`；`status.json`实时、`driver.log`异常、每次command/results保存数据和binary指纹、完整P0、原始阶段、checksum、RSS及2秒GPU采样。源码指纹见source_sha256.json。
- runner字段`merge`在本I25中作为历史兼容的variant键（0/1），实际publication始终开启；应读取`publication_merge`和`reverse_radix`字段，勿误读为publication消融。

## 5. 裁决与止损

先核对4次正常退出、批次0/1、参考checksum和有效记录/source/reverse工作一致；再报告完整P0两对、均值/范围、reverse排序及总preflight变化，不能从sort单项外推。

两次候选均低于10180.0575ms才记为“本轮两次均比历史线快至少5%”；若只是追平或收益被抵消，如实标为未满足用户目标。原版正式比较前仍需解决共同指纹和计时窗口。

reverse Commit约489ms及group/slots是条件性剩余方向，只有I25细分结果能给出覆盖剩余差额的预算时，才考虑批量记录存储/回收组织的进一步实现；不把几项理论最大值直接相加、不自动扫线程或重新恢复失败的source/bulk候选。若无足够预算，接受当前仍未证明明显胜过原版，结束本轮尝试。FS10M缺口更大，先不扩大队列；100M未启动。

目前无新的性能结论。健康确认后按主计划不持续轮询。

## 6. 完整结果与裁决

4/4正常完成，最终checksum均为791729548754523982，I19 forward/reverse及I20工作计数逐项一致。publication始终开启，仅reverse排序开关变化。

| 顺序 | reverse并行 | 两批完整P0(ms) |
|---|---|---:|
| 0 | off | 10719.566 |
| 1 | on | 10908.152 |
| 2 | on | 10787.569 |
| 3 | off | 10806.187 |

off均值10762.8765ms，on均值10847.8605ms，回退0.7896%；两对为回退1.7593%和改善0.1723%。两次候选均慢于历史原版10715.850ms，距10180.0575ms目标分别仍差728.0945/607.5115ms。未满足用户希望明显领先的目标，不保留为推荐优化；代码仅默认关闭的实验路径，不启用默认，不追加扫参。

两批reverse排序均值796.9235→436.8755ms，确实节省360.048ms（45.18%），不足原先为5%领先所需约506ms。group均值325.199→354.410ms、slots272.8105→376.2415ms、merge221.2085→280.3795ms均增长，抵消约191.813ms；总preflight3280.6265→3155.880ms只减少124.7465ms。完整mutation均值6183.015→6138.257ms仅减少44.758ms，mixed grouping1710.9515→1757.9685ms增加47.017ms，最终完整P0反而增加84.984ms。这些是观测到的阶段变化；没有硬件counter证据，不断言具体cache/NUMA因果。嵌套计时不能重复相加。

reverse Commit候选均值501.1665ms，即使不现实地全部消除也不足候选均值距5%目标的667.803ms；group/slots虽有成本，但没有实际可消除的量化证据，不能将整项最大值当净收益承诺或据此盲目重写。此次不追加记录组织实现或CPU owner runtime：结论是当前已验证方法没有达到明显领先目标，而不是证明所有算法均不可能。若继续大改，需要单独建立新结构的维护/读取/容量与完整成本证据。

采样GPU峰值12685–12689MiB，RSS峰值22364892–22371100KiB，无OOM。完整日志、command、results和summary保留。后台已结束，未启动新实验、FS/100M或原版配对。保留I24 publication合并这一已证明改善自身系统的显式候选；目前仅有接近历史原版水平的证据，无正式同语义原版胜出结论。本轮最后尝试据此收口。
