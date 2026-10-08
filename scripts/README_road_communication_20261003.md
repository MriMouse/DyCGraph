# EU/USA 路网性能与 BFS/SSSP 通信量

启动（输出目录必须不存在）：

```bash
python3 scripts/run_road_communication_20261003.py --out paper/evaluation/raw/road_communication_NEW
```

当前后台输出：`paper/evaluation/raw/road_communication_connected_20261003`。

```bash
watch -n 5 'cat paper/evaluation/raw/road_communication_connected_20261003/status.json'
tail -f paper/evaluation/raw/road_communication_connected_20261003/runner.log
python3 scripts/summarize_road_communication.py paper/evaluation/raw/road_communication_connected_20261003
```

`status.json` 给出子进程 PID、当前单元、日志、已完成次数和错误；当前详细执行输出在其中的 `log` 文件。SSH 断开不影响运行。任务顺序为构建、六秒 H2D/D2H/Zero-Copy 校准、20 批小图冒烟、OK 实际通信试跑、连通路网生成/独立校验、路网性能、通信量。执行错误立即停止并保存状态；触及迭代上限则标记 nonconverged，不发布有效均值/比值。不要同时启动其他 GPU0 或同 NUMA 的性能任务。

路网：SSSP/BFS × EU/USA × 1k/10k/100k × current/original/ingress × 两遍，72 次。GPU 二进制直接冻结自 9 月 27 日基础实验，current 唯一模式变化为 `CG_ORDERED_REPAIR=1`；数据使用 connected-road-v2 99% 保边路网，补齐 1k/10k/100k 三档，seed=42，source=1，GPU0/NUMA0。相同 10 批输入、源点、缓存及基础参数，双向顺序抵消部分顺序偏差。Ingress 使用已通过小图及接口契约验证的二进制和相同转换器、20 线程；不运行 SHGraph。`road_averages.csv` 只对两次完整结果求均值。Ingress 同时报告 compute、reset、topology 和完整时间；不能将排除了拓扑重建的 compute 指标误称为公平端到端时间。

通信量：SSSP/BFS × TW/FS × 1k/10k/100k。双方相同输入、相同循环批次数，合法的十批正向更新 + 十批反向恢复构成循环。逐条检查涉及边的增删合法性并验证恢复底图，不直接重复会产生非法增删的更新文件。这是循环工作负载，不能描述为独立随机流。

每个单元先预跑双方，按较短窗口选共同循环数（上限 128），目标至少五秒；预跑不进入均值。正式执行 AB/BA 两次，并分别执行一次显式通信账本测量。NVML 使用独立线程，保留全部原始采样；每个正式窗口必须至少五秒、50 个样本、最大间隔不超过 100ms、有完整边界，否则标记不合格而不是挑选最好一次。超过上限仍不足也如实标记。两秒校准在本机仅约39个样本，初次失败已归档；当前将真实负载延长到六秒，没有放宽标准或空等填充窗口。

PCIe RX=H2D，TX=D2H，包含显式状态/拓扑/缓存传播及 Zero-Copy。它是设备总线估计，包含协议开销，不能当作精确逻辑字节；不能独立分解出准确 Zero-Copy 字节。统一 cudaMemcpy/Async 计数器给出双方显式请求字节量，包含成功提交的异步拷贝，不引入额外同步、指针查询或内核原子操作。类别标注不对称，因此比较只用统一方向聚合；未分类方向保留。两个指标重叠，禁止相加或相减推算 Zero-Copy。

采样版关闭账本，计数版单独执行；路网性能关闭二者。计量窗口统一从初始图/缓存完成后到全部批次完成，包括更新、传播和缓存维护，排除初始化和最终输出 gather。原始日志、命令、环境、输入身份、二进制 SHA256、脚本快照和测量协议均保留。origin 通信副本将批次大小 vector 的越界下标写改为 emplace_back，支持超过 10 批；仅输入读取变化，位于测量窗口外，变更差异另存。最终状态 checksum 不同会阻止发布跨系统比值；相同也不代表通过逐批独立正确性认证。

主要文件：`protocol.json`、`inputs.json`、`binaries.json`、`calibration.json`、`smoke.json`、`results.json`、`runs.csv`、`road_averages.csv`、`communication_comparisons.json`、逐次 `.samples.json` / `.physical.json` / `.log`。

连通路网按原始 symmetric 语义展开双向道路，保护随机顺序 Kruskal 森林。所有更新均为真实道路、双向成对增删；删除只选择非保护边。这能测量大直径传播，但不代表对全部边均匀删除，不能与旧 paper_data 路网结果混算加速比。最初两秒校准、旧路网可达性诊断及输入读取器失败保留在 `raw/road_communication_20261003`，不进入正式结果。

2026-10-04 范围更正：通信量仅 TW/FS，已完成的 72 次路网运行保留，不重复运行。OK/WK 额外测量已移入 excluded_OK_WK，不参与正式汇总；当前由 scripts/resume_tw_fs.py 继续后台执行。

2026-10-04 后续减负方案：完成 TW/SSSP 1k、10k 后，取消其余单元的专门预跑。根据既有测量中最短的每循环耗时估算，目标 10 秒，至少 4 个循环、最多 128 个循环，双方相同批数。每单元直接执行 AB/BA 四次物理测量及两次独立显式计数，正常共 6 次。仅正式窗口不足 5 秒时共同增加批数并重跑四次物理测量，旧尝试全部保存，不按流量大小挑结果；采样间隔异常、checksum 不同仍标记无效，不靠反复重跑凑有效。完成单元跳过，已有同批数正式测量可恢复复用。每单元批次数决定保存在 direct_measurement_plans.json。切换器会等当前 100k 输入合法性审计完成，状态见 switch_status.json。

## 单独重跑路网 origin（解除迭代上限）

脚本 `scripts/rerun_road_original_converged.py` 默认仅检查和显示计划，不编译、不运行实验：

```bash
python3 scripts/rerun_road_original_converged.py
```

后续统一排期时执行（前台串行，可由总调度脚本调用）：

```bash
python3 scripts/rerun_road_original_converged.py --run
```

仅运行 SSSP/BFS × EU/USA × 1k/10k/100k × 两遍，共 24 次 origin。
从原实验使用的 `sssp_bfs_20260927/original_src` 与 `original_bfs_src` 复制独立源码并重新编译；四处强制迭代终止条件增加路网路径判断，`/road_inputs/EU/` 和 `/road_inputs/USA/` 跳过上限，按原有 active frontier 为空的条件退出。其他路径保留原限制。补丁保存为各算法的 `*_convergence.diff`。

完整复用原路网 `.command.json` 参数、环境和输入，运行前验证记录的路网 SHA256；必须出现完整的十批计时且没有 `Max iterations reached` 才记为有效。默认不设墙钟超时，可用 `--timeout 秒数` 设置；超时会失败退出，不计有效均值。

默认输出到新目录 `paper/evaluation/raw/road_original_converged_20261005`（必须不存在，可用 `--out` 指定）。新 `results.json` 和 `road_averages.csv` 合并旧 current/ingress 路网结果与新 origin 结果；旧实验目录不覆盖。`status.json` 记录进度及失败原因，逐次保留日志、命令，记录新二进制 SHA256。没有重跑通信量实验。

## 2026-10-05 公平性复核与后台续跑

```bash
# 只读审查（参数、资源、输入身份、六个计算二进制 SHA256）
python3 scripts/run_road_then_communication.py --check
# 启动脱离终端的串行队列：origin 路网 → 未完成通信单元
python3 scripts/run_road_then_communication.py
```

队列默认目录为 `paper/evaluation/raw/road_origin_then_communication_20261005`，
`runner.pid`、`runner.log`、`status.json` 是队列入口；路网结果位于其 `road/` 子目录，
通信续跑仍写原实验目录。运行时持有原实验 `runner.lock`，防止重复调度；
origin 失败则不启动通信。通信不设墙钟超时，异常或并发 GPU 使用会失败退出。
每个任务记录子进程 PID、时间、命令、日志；脚本快照与 SHA256 保存在队列目录。

origin 除四处路网迭代上限判断外，修复原 Loader 对 reserve-only vector 的下标写入，
改为 emplace_back；该修复在计时外，不改批次内容、图算法或 kernel。
额外运行 2048 点长路径冒烟：旧二进制应触及上限，新二进制应完成十批而不触及上限。
这只验证终止行为，不是独立的最短路正确性证明。

通信保留七个已完成单元（包括五个 checksum 不一致的无效单元），
剩余五个 BFS 单元继续运行。中断的 BFS/TW/10k 单元整组重新测量，沿用已选循环数，
避免将跨两次会话的测量拼成 AB/BA 对；原日志和记录先归档到队列的
`communication_before_resume/`。没有按性能或通信量择优重跑；checksum、采样质量、
收敛状态门槛全部保留，无效单元不产生比值。

公平性边界（也写入 `fairness_audit.json`）：

- 相同图/更新/源点/批数、GPU0/NUMA0、缓存、分段和线程设置；保留双方既有模式
  current hybrid=0 / origin hybrid=2，current 路网用 ordered repair。
- 双方 P0 时间包含删除、添加、传播和缓存维护，排除初始化及最终 gather。
  current 暂停计时用于诊断的区间在 check=false 时不做图算法工作；并非逐条指令相同的计时包装。
- origin BFS 是单位权 SSSP 适配版，不称为作者提供的原生 BFS。
- origin 补跑和旧 current/ingress 不同期；不能称为本轮交错配对测试。
- 路网保护生成树，删除采样有偏；不推广为所有路网更新分布。
- 收敛及十批计时不证明结果正确，origin 冻结程序没有独立距离检查；发表最终加速比前仍需逐批独立正确性验证。
- 通信最终 checksum 相同也不证明每批正确；已有五组不一致明确排除，不隐去。
- NVML 是设备总线估计，不是精确逻辑字节，不分解精确 Zero-Copy 流量。
