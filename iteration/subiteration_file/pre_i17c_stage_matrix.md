# I17-C 前阶段性大矩阵

2026-09-09 缩减：用户最多再等半天，剩余性能配置每侧只跑一次，已经完成的样本全部保留，报告仍取有效样本中位数并在 CSV 列出样本数。R-MAT 未完成的 r1 当前侧已中止，不补重复；此前四个 cohort 三次重复保留。冻结 runner 已单独修订，hash 记录于运行目录 short_resume_amendment.json，原 provenance 保留。恢复时使用冻结 runner 的 `--repeats 1`；manifest 的 deadline_epoch 为本次恢复起 12 小时，截止后状态 budget_exhausted，未完成项仍为 pending，不能宣称全图正确性收口。预实验、公平计时、十批正确性保持原协议，两项 worker 诊断已完成，无需追加。

2026-09-08 用户要求新增。I17-C 暂缓，本轮只运行现有生产 SSSP 路线，不将独立 I17-B ordered replay 伪装成生产加速。

## 后台入口

运行目录：`logs/stage_pre_i17c_20260908/`。独立 session 总控 PID 记录于 `supervisor.pid`，当前启动为 **531840**；已确认 PPID=1、SID=PID，stdin 为 `/dev/null`，stdout/stderr 写 `supervisor.out`，不依赖 SSH。准备阶段写 `twitter_prepare.log`，GPU 矩阵阶段写 `status.json` 和逐 run 日志。机器重启或手动停止后可重启同目录，已经写入 `runs.json` 的结果不重跑，未完成尝试保留并另起日志。

恢复命令（先检查现有 PID/status，禁止重复启动）：

```bash
CG_STAGE_ROOT=/home/wangshaoyan/proJect/C-GpuStreamGraph-CG \
nohup setsid python -u logs/stage_pre_i17c_20260908/runner/start_stage_pre_i17c.py \
  logs/stage_pre_i17c_20260908 \
  >> logs/stage_pre_i17c_20260908/supervisor.out 2>&1 < /dev/null &
```

查看：

```bash
cat logs/stage_pre_i17c_20260908/status.json
tail -n 30 logs/stage_pre_i17c_20260908/supervisor.out
```

每次实验完成刷新 `runs.json`、`comparison.csv/json`、`correctness.json`、`bottlenecks.json`、`worker_probe.json`、`report.md`。正式报告开始生成于 Twitter 数据准备之后；未完成时行状态为 pending，不应当作最终结果。

## 数据矩阵

所有更新规模以 stream 文件实际计数为准，10 batch，k=1000。缺失规模明列，不更名凑齐，不从其他保留率补文件。

| Cohort | 有效规模（每批） | 分组 |
|---|---|---|
| Orkut、Wiki | 1k/10k/100k | 主矩阵 |
| Twitter 新冻结 cohort | 1k/10k/100k | 主矩阵，准备已完成 |
| Friendster | 1k/10k/100k/1000k | 主矩阵 |
| R-MAT FS-like | 100k | 主矩阵 |
| UK-2007 50p | 1k/10k/100k | 主矩阵，16GB 可行性未知 |
| EU/USA connected-v2 50p | 10k/100k/1000k | 主矩阵 |
| EU/USA connected-v2 75p、99p | 10k/100k/1000k | 补充矩阵，同样完整运行 |
| EU raw50、USA raw50 | EU 1k/10k/100k；USA 另有 1000k | 历史版本单列 |
| EU symmetric50、symmetric99 | 100k | 历史版本单列 |
| Twitter 旧重编号版、原始 ID 版 | 实际 200/2k/20k，文件名为 1k/10k/100k | 历史版本单列，不能计作真 100k 收口 |

预期 18 个 cohort、50 个现有/准备后的规模配置，主/补充/历史单列；正常情况下为 300 次十批性能进程，另有 pilot、正确性和诊断。两个 Twitter 历史版本来自相同图的不同 ID 空间；权重由 ID 决定，不把其性能相互相除。源点沿用既有协议：Wiki=134151、Orkut=377664、路网=1，其余=0。相同 cohort 双方读取完全相同绝对路径，首次使用 SHA256 冻结、每次执行前验证 inode/size/mtime，硬链接复用 hash。正文表的横轴输出真实 updates/batch。

Twitter 口径修正：既有 100k 文件只有 10×20k 记录。原版目录另有名为 1000k 的更大池，实际为每批 100k add+100k delete。复用现有 ID-remapper 在新目录重编号一次，再按每个原始 batch 内两种操作的前缀，各取 K/2 条，生成 K=1k/10k/100k。全批操作集合去重，add/delete 集不交叠，保证不引入跨批重复操作。复用同一基图硬链接，保留原数据和生成 manifest；此新 cohort 不与旧 I14/I16 数字直接比较。1000k/batch 的 Twitter 数据仍缺失，未声称生成。

## 公平口径与参数

原版路径明确为 `/home/wangshaoyan/proJect/CG/C-GpuStreamGraph`，不是 `Grapin-CG`。双方目录本身都有既存未提交改动，冻结的是当前工作区源码；`provenance.json` 记录 HEAD、工作区状态、2617 个源码文件 hash、二进制与 runner hash。原工作区未修改。对照应命名为“原版 GPU-only 工作区快照”，不能声称 pristine upstream。

在实验源码副本中仅对齐以下事项，并保留 `*.fairness.patch`：

1. 原版初始 SSSP 的 `round==1000` 伪收敛移除，与当前自然收敛对齐，禁止以不完整初始路网状态制造快结果。
2. 双方 batch 计时起止加入 GPU completion fence；当前还在 deletion checker 前的计时段末加 fence。初始化、首次 cache、结果检查与输出仍在主 timer 外。
3. 无其他算法补丁、无 ordered-GPU 生产接入。CUDA 12.1、g++-12、Release、sm70 相同，两个冻结副本均已构建成功。

主指标为 **10 个 `[P0-TIMER][SSSP][batch i] total_batch` 之和**，不是日志内其他 `(excluded)` 标签或运行 wall time。覆盖删除/修复、插入/收敛、hotness/candidate、eviction/compact/cache_load 及同步。原版每批 GatherValue/checksum 在 timer 外，当前 final checksum 在 timer 外；双方 hash 算法不同，不跨仓库直接比 hash。性能 `check=false`，不做全图正确性扫描；原版运行成功也不等于其正确性已被证明。

每 cohort 的 100k 配置先跑两 batch 预实验：cache=2 下当前 hybrid=0/2、原版 hybrid=1/2；再给每侧获胜路线尝试 cache=3。当前 hybrid=0 仍无条件维护/使用 cache 且启用 source-local topology/exact-source 路线，不等于关闭本仓库优化；传统 dispatch 在当前增量路径已被替代。原版 hybrid=0 会跳过 cache 维护，不作为候选。选择双方共同可行 cache，分别选最快 hybrid；cache=3 需双方归一化 pilot 时间几何均值相对 cache=2 改善超过 3%，否则优先 2。这是有限候选短测结果，不宣称穷尽所有参数最优。

双方 `cache` 必须相同。同值同容量：cache2=536870921 条、cache3=805306365 条，每边 4 字节，均有 cache 与 compact 双缓冲。若完整运行 cache3 OOM，整个 cohort 的双方全部规模改为 cache2重跑，旧样本仍保留但不混入主表。CPU mutation 默认 20 workers，GPU 传播不恢复 CPU PQ。SEGMENT=512、n_stream=3、weight_num=1、weight=1 一致。

## 性能与正确性

性能每配置双方各 3 次×10 batch，顺序 current-original / original-current / current-original，报告 median 和逐批原值。cache pilot、correctness、诊断不进入性能均值。每个图完成一组选择/正确性/性能再进入下一个图，优先获得短图完整结果。

本仓库每 cohort 100k 跑完整 10 batch `check=true`：10 次 deletion-stage、10 次 batch、最终 Bellman 和 Overall 全通过，最后 checksum 与 batch9 一致，才记为 passed。检查仍遵循现有 existential tight-witness 契约，stored-parent 诊断另列，不能把非零诊断默认为完整 SPT 已验证。旧 Twitter 20k 版本只作历史验证，新 true-100k 负责本次收口。OOM/超时/缺失 batch 不得标记正确；当前正确性失败时相应速度数据保留但不给 speedup。

每个进程最长 6 小时；发生 OOM/运行失败/超时，记录失败，后续同配置重复标记 skipped_after_failure，避免重复浪费资源，其他图继续。若原版无共同可运行配置，本仓库仍运行可行的 standalone 性能与 correctness，不计算跨仓库速度比。UK/原始 Twitter 等大 ID 空间可能无法放入 16GB，这属于实测可行性边界，不能隐藏缺项。

## 两项瓶颈实验

1. 从所有无诊断当前性能日志汇总 deletion/add/hotness/candidate/eviction/compact/load/residual 占比、repair closure 占比、affected incoming×iterations 的重复逻辑检查量；随 batch 规模观察哪个阶段成为主导。不开额外重型 profiler，逻辑检查量不能称为 DRAM 流量或设备利用率。
2. Twitter/Friendster true100k 各做 3 batch，mutation workers 按 1-20-20-1 配对；相同 cache/hybrid/二进制，报告完整计算时间比和 final distance checksum 一致性。用于判断主机 topology 维护的剩余并行收益及 Amdahl 限制，不并入阶段性原版速度比。

主机 peak RSS 来自 `/usr/bin/time`；GPU peak 每 2s 采样，注明不是精确 allocator 高水位。只占用 GPU0，启动前同时要求 memory=0、utilization=0 且无 compute process；实验中遇外来 GPU 进程只终止自身进程组，等待空闲后重试。不会中断其他用户进程或多卡运行。

## 启动验证

七项 CPU 契约测试通过；四条真实 GPU smoke 路线（当前 h0/h2，原版 h1/h2）及当前两 batch correctness 通过。更新计数重解析为 `[4,4]`，计时序列与分项闭合。现有 I17 memcheck 也记录在目录中，但不代替生产 correctness。16:17 UTC，Twitter 准备完成并写入 `twitter_true/ready.json`；真实 1k/10k/100k 三个版本的更新数和 SHA256 已核对，manifest 确认 18 cohort、50 配置。后台已切入 Orkut 参数预实验，尚无正式矩阵性能结论。
