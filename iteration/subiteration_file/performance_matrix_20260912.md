# 2026-09-12 完整 SSSP 性能矩阵

本轮由用户重新授权完整对比实验，覆盖 OK/TW/FS/EU/USA，优先使用已有数据，不生成缺失 cohort。实验后台独立运行，SSH 断开后继续；仅用 GPU 0，启动每个任务前要求显存、利用率均为 0 且没有计算进程。遇到其他用户进程时只终止本实验子进程，等待资源空闲后重试。不会终止其他用户进程。

产物目录：`logs/performance_matrix_20260912/`。入口：`scripts/prepare_performance_matrix_20260912.py`；矩阵定义：`scripts/run_performance_matrix_20260912.py`。实际执行的冻结驱动在产物目录 `runner/`，包含对既有受控运行器的环境注入、模式证据与指纹解析扩展。不要直接运行未扩展的矩阵定义文件。

## 公平性审计

- 对象是当前工作区快照与 `/home/wangshaoyan/proJect/CG/C-GpuStreamGraph` 的本地原版工作区快照，并非未经修改的 upstream commit。双方源码、逐文件 SHA256、实验补丁、二进制 SHA256、输入 SHA256 和完整命令均留档；原工作区与既有实验日志不修改。
- 两侧统一 CUDA 12.1、G++ 12、Release、V100 sm_70，独立构建 `hybrid_sssp`。
- 主指标为 `[P0-TIMER][SSSP][batch i] total_batch` 之和。包括 topology mutation、删除 invalidation/repair、插入 closure、hotness/candidate、eviction/compact/load cache 与完成同步。初始化 SSSP、首次 cache、输入读取、结果 gather/检查在外。另报进程 wall 和 RSS，不能混称主指标。
- 当前侧已有 batch 开始、删除计时结束、cache 结束的 GPU completion fence。原版实验副本补开始/结束 fence，避免异步工作逃逸到 timer 外。
- 原版 Start 的 1000 轮，以及增量 insertion/deletion 的 100 轮条件会把未收敛状态当完成。仅在实验副本删除这三个截断，保留已有自然收敛条件。超时记录失败，不用截断制造加速。保留未调用辅助方法中的截断；若任何活动路径仍打印截断提示，解析器拒绝该结果。
- 当前侧在 timer 外增加与原版相同的 reachable + `sum(distance[i]*(i+1)) mod 2^64` 指纹，跨系统对比前必须匹配且 reachable > 1。指纹一致不等价于逐顶点证明。每个 current 配置另跑两批 Bellman/tight witness 检查，stored-parent race 仍单列诊断，不伪称所有长序列均已完整验证。
- `check=false` 的主实验与 `check=true` 的验证实验分开。相同输入路径、source、batch 数、权重参数、SEGMENT=512、n_stream=3、alpha/beta 默认值、cache 容量严格配对。

## 模式与选择

`hybrid=2` 在 policy 类中表示按 segment 活动度/工作量选择 Zero_Copy / Exp_Filter / Exp_Compaction；`hybrid=1` 为 explicit，`hybrid=0` 为 zerocopy。必须区分 policy 类中存在的方法和 SSSP 实际调用路径：原版 `GetNextPolicy` 的调用位于 `Compensate`，常规 SSSP `add_edge -> update_tree_add` 与删除阶段以 `GetInitPolicy -> Zero_Copy` 初始化，并不意味着所有动态策略都在每批自动探索。SYNC/ASYNC、PUSH/PULL、DD/TD 的 DB 策略没有接入这个主增量调用链，不添加虚构开关、不改造基线算法。

每个 cohort 在 100k（缺失则最小现存档）以两批 pilot 比较原版 hybrid=2/1、当前 hybrid=0/2，固定 cache=2，随后冻结各侧较快配置。这是有限候选选择，不声称全参数全局最优。当前 hybrid=0 仍维护和使用 cache；原版 hybrid=0 跳过 cache 维护，因此不作为开启缓存的候选。

当前侧开启 `CG_MUTATION_WORKERS=20`。EU/USA 使用 `CG_ORDERED_REPAIR=1`。1000k/10000k 使用 `CG_REVERSE_SHARDS=64`，其余默认 1。`--large_batch` 只打印未接入 PMA backend 的提示，因此不将占位 flag 作为有效大 batch 模式。两侧 cache=2；遇到 OOM 时同一 cohort/scale 双方一起降至 cache=1 重跑，cache 仍开启，旧失败保留。cache=1 仍失败则保留容量边界，不悄悄改 cache=0。

## 数据与实验

- OK/FS 使用 data 根目录实际存在且 stream_size 与文件名一致的三件套。
- TW 旧根目录文件名不可靠，复用 `logs/stage_pre_i17c_20260908/twitter_true` 已有真实 1k/10k/100k（source=0 的该映射曾用于已有阶段实验，运行时仍要求非平凡 reachable）。这不是本轮重新生成的数据。
- EU/USA 主线使用 `data/road_connected_v2/*/50p`，source=1。仅有 10k/100k/1000k，1k 缺失跳过；根目录旧 disconnected 路网不混进 connected 主曲线。
- FS/TW 大规模附加线使用 `data/i17_scaling_20260911/*` 的同底图 100k/1000k/10000k，每档两批。TW source=28512093，避免此前 source=0 只可达自身的问题。此线与旧 cohort 分开报告。
- 每配置主实验运行全部可用批次（最多 10 批），三次独立进程重复并交替系统先后次序；报告中位数和原始逐批数据。两批扩展性线不可和十批主线总时间直接相比，可用 ms/batch 辅助观察。
- 用户要求的边界：FS/TW 的 10k/100k，在相同当前侧默认配置上分别只打开 ordered，或只打开 64 reverse shards；不同时打开两者。报告各自相对同 batch 数默认路径的加速与结果指纹一致性。
- 附加指标：deletion/add/cache 阶段、repair rounds/incoming edges、ordered service、reverse preparation、insertion 工作、有效更新量、采样 GPU 显存峰值、主机 RSS、进程 wall。峰值为 2 秒采样，可能漏瞬时峰值。具体字段以原始日志实际存在项为准。

## 查看与恢复

```bash
cat logs/performance_matrix_20260912/status.json
tail -f logs/performance_matrix_20260912/supervisor.log
cat logs/performance_matrix_20260912/report.md
```

`status.json` 包含 active run 和完整日志路径。`runs.json` 保存成功及失败，`comparison.csv/json` 保存当前可比结果；尚未结束时都是增量报告。构建日志分为 `current.build.log` 与 `original.build.log`。

如进程意外退出，可使用冻结驱动恢复（先确认原 PID 已退出，运行器自身也有目录锁）：

```bash
CG_STAGE_ROOT="$PWD" nohup python3 -u logs/performance_matrix_20260912/runner/run_performance_matrix_20260912.py logs/performance_matrix_20260912 </dev/null >>logs/performance_matrix_20260912/supervisor.log 2>&1 &
```

不要重复运行 preparation 覆盖冻结源码。运行失败项会保留而非自动擦除，资源冲突除外。最终是否形成有效加速结论，以 correctness、指纹、失败状态及完整结果为准。

## 启动观察

已观察两侧 pilot、首组正式十批配对、当前侧两批独立 Bellman/tight witness 检查正常完成，进程已脱离终端。当前已发现 Orkut 两侧最终 reachable/距离指纹不一致；不发布该组加速比，原因仍待独立定位。双方更新权重公式均为 `(src+dst)%128+1`，尚不能据此判定是哪侧算法或 topology 语义导致差异。当前侧两批检查通过不等价于十批全状态正确性证明。

报告经验证会拦截四种情况：等待 correctness、correctness 失败、跨系统指纹不一致、缺少有效配对。加载强化判据时重启过本实验监督进程，已完成结果与二进制保留；具体 PID 和启动观察见 `startup_observation.json`。
