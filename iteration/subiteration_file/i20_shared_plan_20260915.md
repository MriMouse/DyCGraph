# I20 共享 source 规划与有效变更候选（2026-09-15）

状态：两轮短配对已完成并审阅，达到继续保留候选的开发收益门槛；目标大图全阶段正确性与模式边界回归尚未完成，I20未封板。**按用户 2026-09-15 后续要求缩短实验：原长队列已取消，首轮 TW/FS10M 各 regular/large 一对已完成；用户已要求补反向配对，当前只新增各 large→regular 一对，共 4 次 GPU 运行。**I21/I22 未启动。实验入口为 `scripts/run_i20_screen.py`，证据目录 `logs/i20_20260915/`。

## 机制与范围

遵循 I19 裁决，首个候选删除两类重复物化：

- `SourceLocalChunkStore` 大模式保留单份 `PreparedResult` 内的 source 规划，以 changed-source 索引供 effective emission、allocation、forward apply 和 retire 共用，取消第二份 `PreparedSource` 重型数组及其 move 遍历。常规路径保留作同代码对照。索引随机访问及保留结果布局的代价由完整性能裁决。
- forward effective 缓冲区在提交前交由 `DynamicReverseIndex::Prepare(vector&&)` 消费，直接过滤、排序和准备 reverse；取消 reverse 输入的全量复制。常规 const-reference API 仍复制，任意旧 observer 的 const-reference Prepare 仍兼容。reverse 的排序 scratch 和最终 overlay 必要输出仍存在，不声称消除所有重复表示或所有内存流量。

变更语义仍由原 deletion 匹配产生；不合并 deletion/addition 两次 fixed point，不修改 GPU authoritative state，也不增加 GPU 常驻拓扑。reverse 准备成功后才进入 forward 可见修改，原 epoch/publication/reclaim 路径共用。

`CG_BATCH_MAINTENANCE=regular|large|auto`：开发默认 regular；large 显式启用候选；auto 在每批分组开始时只按 B>=1,000,000 选择，100K 为常规、1M/10M 为大模式。选择不使用图名、比例或耗时。策略不增加跨批持久拓扑状态；跨批切换由同一 store/reverse 对上的独立 oracle 检查。

## 验证与计量

四项相关 CTest 已通过：grouped ordering/1M 阈值、source-local chunk store、dynamic reverse、I19 work metrics；source-local 和 work metrics 另外强制 large 通过。dynamic reverse 测试在连续批次交替 regular/large，覆盖重复/无效更新、空 phase、删除阶段可见性、删后重加、reverse oracle、epoch 和 preflight 失败。

GPU large 三批非对称 smoke 的 deletion-stage、batch、final Bellman 全部通过，捕获的首批 deletion repair 快照 CPU PQ oracle 通过（distance_mismatches=0）；不将首批快照 oracle 称为三批 CPU SSSP oracle。CPU 192 批与大图配对尚待运行结果确认。`tests/i19_gpu_smoke.py` 增加可选 output/binary 参数以复用原 CPU PQ 与 Bellman oracle，无需覆盖历史日志。

新增 source-plan duplicate/index 字节和 reverse 实际输入 copy 字节。指标是选定表示的 payload/布局账本，不是完整 CPU memcpy 或 DRAM 流量；radix scratch、容器容量及 allocator 成本仍需看完整时间/RSS。历史 I19 reverse_copy_bytes 在本轮改为 observer 实际复制量，大模式为零；不能把零理解为 reverse 没有排序、合并或写入。

## 原长队列设计（已取消，不作为当前待办）

1. 冻结源码与二进制、核验复用输入哈希。旧 baseline 仅归档；性能 A/B 使用同一候选二进制的 regular/large，避免通信工具修订或构建差异混入。
2. 显式 large：TW/FS 100K、1M、10M 共 12 批 CPU 双向 oracle，以及 FS/WK 18 组十批共 180 批 CPU oracle。
3. 单卡串行、NUMA 0、20 workers、64 reverse shards、cache=2、ordered=0、计量关闭；TW10M 和 FS10M 各 regular-large-large-regular，两批完整 P0 对照。
4. TW/FS10M large 各两批全阶段 GPU correctness；TW/FS100K/1M regular/large 开发回归。
5. runner 保存结果后标为待审阅，不自动启用默认 auto 或继续 I21。审阅完整收益、机制字节、阶段/affected 差异；如继续保留，再做预先固定 10/50/90 代表比例的完整 GPU gate。

开发继续预算仍是完整 P0 稳定改善约 5%，不是已实现的收益或正式三次中位数 gate。未达门槛时根据画像调整或撤回候选；不将局部 copy/malloc 改善等同追平。大规模任务按用户要求后台运行，出现 CPU/GPU/checksum 失败或 GPU 资源冲突自动停止，并写 status.json；无人值守脚本不修改生产默认值。

## 后台执行记录

2026-09-15 启动：`python3 -u scripts/run_i20_screen.py --output logs/i20_20260915`，runner PID `116967`。完整队列为 4 次 CPU replay 进程（192 批），随后 18 次串行 GPU 运行（8 次目标 ABBA、2 次目标正确性、8 次规模回归）。启动时先核验输入哈希；实时状态以 `logs/i20_20260915/status.json` 为准，PID 仅为本次启动记录，不构成未来恢复指令。

候选默认不启用、尚无新加速结论。结果未出前，不将 I20 写为完成，也不启动依赖结果的 I21/I22。

## 用户要求缩短后的当前计划

原 runner 已停止，其 CPU 子进程组也已退出。取消时仅 TW100K 两批 CPU 双向 oracle 通过；1M/10M 与比例 CPU gate 未完成，尚未启动任何大图 GPU 实验。部分日志原样保留，旧 status.json 标记 `stopped_for_short_screen`。

当前入口默认短筛查，长队列只有显式 `--full` 才可启动，不自动补跑：

1. 复用本轮已通过的单元测试、三批 GPU Bellman、首批 CPU PQ oracle 和 TW100K 两批 topology oracle；不重新执行 192 批 CPU oracle，也不把复用证据冒充目标大图全阶段正确性。
2. 同一冻结二进制、同输入、同 NUMA/worker/cache：TW10M regular→large，FS10M regular→large，各两批完整服务，共 4 次 GPU 运行。仍核验输入哈希、策略日志、批数和历史已验距离 checksum。
3. 只判断完整 P0 的收益方向与被删除的表示字节；一次 A/B 不能证明稳定改善或正式胜出。无明显收益则先审阅/调整或撤回，不继续整套矩阵；有希望才追加反向配对，然后做有针对性的完整正确性与代表比例检查。

历史 I19 单次总墙钟：TW10M 127.3 s，FS10M 421.3 s；四次约18.3分钟，加哈希和环境波动预估20～30分钟，不是时间保证。之前队列不能仅凭运行数断言需要十多个小时，但确实将首轮筛查和后置回归混在一起。

短队列启动：`python3 -u scripts/run_i20_screen.py --output logs/i20_short_20260915`，PID `125971`，实时状态 `logs/i20_short_20260915/status.json`。本轮仍不自动启用候选或推进 I21/I22。

## 短筛查结果与反向确认

首轮4次运行已完成，总墙钟约19分钟。两批完整 P0：TW10M regular 12076.906 ms、large 11381.281 ms（下降5.76%）；FS10M 15152.987→13668.661 ms（下降9.80%）。四次最终距离checksum均与历史已验参考一致。仅单次配对，不构成稳定性能结论或目标大图全阶段correctness封板。

2026-09-15 用户授权补反向确认：相同冻结二进制、输入哈希与所有参数，TW10M large→regular，FS10M large→regular，共4次，无CPU长矩阵或其他回归。启动命令：

```bash
python3 -u scripts/run_i20_screen.py --output logs/i20_reverse_20260915 --reverse-of logs/i20_short_20260915
```

本次 runner PID `170909`。脚本核验前次状态、二进制、输入与命令/环境一致；完成后 `combined_results.json` 合并两轮8次结果，`screen_summary.json` 同时报告每次配对降幅、两次方向是否一致及合并均值收益。两轮之间有时间间隔，属于开发配对确认，不冒充连续无间隔ABBA或正式三次中位数。

在项目目录查看进度：

```bash
watch -n 10 'cat logs/i20_reverse_20260915/status.json'
```

`completed_gpu_runs` 为完成次数，`total_gpu_runs=4`；`state=screen_complete_needs_review` 表示全部完成，`failed_or_blocked` 表示异常停止，可查看同目录driver.log。状态中started/updated为UTC Unix时间。预计20～30分钟，受加载/调度影响，不是时限保证。候选仍不自动启用，I21/I22未启动。

## 反向配对审阅结论（2026-09-15）

反向4次运行全部完成，墙钟1143.2秒（19.1分钟）。与首轮合计8次，所有最终distance checksum与各自历史已验参考一致，模式、输入、二进制和NUMA/worker/cache设置核验通过。后台队列已结束，本次审阅没有追加运行。

| 目标 | 首轮降幅 | 反向降幅 | regular两次均值 | large两次均值 | 均值降幅 |
|---|---:|---:|---:|---:|---:|
| TW10M | 5.76% | 8.93% | 12.185163 s | 11.288533 s | 7.36% |
| FS10M | 9.80% | 9.39% | 15.099269 s | 13.650626 s | 9.59% |

单位为两批完整P0合计，不含加载。两图两轮各自均超过5%开发预算，方向在调换顺序后保持；允许继续保留候选做定向验收，不将两次均值称为正式三次中位数，也不声称统计显著性。

机制证据：同图四次forward写入量与source_work完全相同。TW/FS每轮都删除320 MB reverse输入副本；source重型重复表示分别约1.808/2.506 GB，替代索引约86.119/119.344 MB。这是选定布局/payload账本，不是完整DRAM流量或峰值内存下降量。prepare两次均值TW 2286.155→1572.263 ms、FS 2968.919→2006.200 ms；mutation均值分别下降733.266/1157.916 ms，与完整P0收益方向相符。不同run的affected存在SPT平局波动，不声称逐阶段工作完全相同；closure均值TW 412.855→417.365 ms、FS 348.354→346.063 ms，不能把主要收益归于传播工作减少。原始分解见 `logs/i20_reverse_20260915/review_stages.json`。

距离历史原版目标：TW均值11.288533 s相对10.716 s仍需净减少0.572533 s（当前的5.07%）；FS13.650626 s相对11.468 s仍需减少2.182626 s（15.99%）。原版未重测，目标线不是本次公平双系统对照。

裁决：共享规划/缓冲区消费候选通过短性能开发门槛，暂保留显式large，默认regular不改。下一步优先TW/FS10M候选各两批全阶段正确性；通过后按需要补最小100K/1M模式边界与代表比例验证，不恢复已取消的192批/18次长矩阵。I21须以此后剩余成本为预算；I22未启动。上述是待执行任务，本次未启动。

## 后续用户指令覆盖（2026-09-15）

用户明确要求不再单独进行大图正确性检查，直接继续瓶颈优化；因此上节“下一步先全阶段检查”的安排不再执行。I20候选保留为large开发基线，I21已实现删除位置复用并启动4次短性能筛查，见[i21记录](i21_delete_positions_20260915.md)。未执行的correctness/完整矩阵仍如实保留边界，不构成暂停优化的门槛。
