# I16 配对实验与 CPU Dijkstra 评估

## 配对结果与后续启动

八次运行全部完成，`logs/i16_paired_20260907/status.json` 为 completed，PID 1860933 已退出。所有 run 的三批最终 reachable/checksum 都与正确性基线一致，输入与冻结 binary hash 通过；两个配对在两图上均同向下降，预设 5% timing gate 明确通过。

| 三批总时间 | A0 GPU | B1 CPU | B2 CPU | A3 GPU | CPU/GPU 配对比 | 聚合下降 |
|---|---:|---:|---:|---:|---:|---:|
| EU50p | 339.325 s | 93.263 s | 93.533 s | 351.754 s | 0.275 / 0.266 | 72.97% |
| USA50p | 129.960 s | 48.601 s | 48.849 s | 126.786 s | 0.374 / 0.385 | 62.04% |

| 内存证据 | EU GPU / CPU | USA GPU / CPU |
|---|---:|---:|
| nvidia-smi 0.5 秒采样峰值 | 12,484 / 12,114 MiB | 8,214 / 8,028 MiB |
| GNU time 最大 RSS | 12.13 / 13.67 GiB | 5.96 / 6.74 GiB |

CPU 模式 GPU 采样峰值下降 370/186 MiB，与“省去 incoming 副本、增加固定 20 MiB staging”的分配账本方向一致；CPU RSS 增加约 1.55/0.78 GiB，来自临时状态、索引、outgoing 和 PQ。GPU 数字是采样峰值，不冒充精确 allocator 高水位，但长时间 GPU pull allocation 被数百次采样覆盖，加上确定性替换账本，足以准入十批 correctness；默认切换仍需最终回归后决定。

配对期间 CPU 算法冻结，结果证明当前 Dijkstra 已有足够端到端收益，不在十批验证前替换堆、并行化或改变索引结构。两图十批 `check=true` 已启动，PID 3514637，目录 `logs/i16_cpu_pq_10batch_20260908/`：

```bash
python3 -u scripts/run_i16_road_validation.py logs/i16_cpu_pq_10batch_20260908 \
  --suite connected50 --batches 10 --cpu-pq
```

runner 对照前三批的冻结阶段 checksum，后七批由 deletion-stage、batch 和最终 Bellman/tight-witness 检查独立验收；全部十批要求 publication 无错、更新数完整、最终 reachable 与数据证书一致。先 EU 后 USA，GPU 0 空闲检查、两小时单进程上限保持。完成后才执行 TW/FS 显式模式回归及决定是否保留 flag/默认策略。当前十批结果以 status 为准，不能把启动记为通过。

## 本轮执行

固定上一轮六批 correctness 通过的同一二进制，EU50p/USA50p connected-v2、source=1、100k mixed，各按 A(GPU pull)-B(CPU PQ)-B(CPU PQ)-A(GPU pull) 运行三批，共 8 run、24 batch。`check=false`、无 snapshot/诊断 trace、保留最终 checksum；计时和已有汇总日志保留。CPU/GPU 模式仅由显式 flag 切换，不更改算法或数据。

脚本 `scripts/run_i16_paired.py`，目录 `logs/i16_paired_20260907/`，启动 PID 1860933；实际状态看 status.json。命令：

```bash
python3 -u scripts/run_i16_paired.py logs/i16_paired_20260907
```

只在 GPU 0 显存/利用率/compute PID 全空闲时启动下一进程，不切卡，单卡串行。每 run 两小时 wall 上限，只终止自己进程组；发现外部 GPU compute 进程后停止自己的任务并标 failed，避免混入受干扰测量。`blocked_resource` 可同命令追加 `--resume`，保留已完成项；其他失败须先审查，不能静默跳过。

冻结已有 correctness 版本 binary/hash、候选源码、输入 SHA、命令及参考 checksum。每个 run 从同一初图开始，严格解析三批 timer、P0 attribution、更新数、publication 与所选 executor；最终 reachable/checksum 必须等于原三批正确性结果。缺行/重复批次、错误模式、诊断 capture 或 checksum 不一致即停。两项 parser 回归通过，覆盖两种模式及多类损坏日志拒绝。

采用同样监控方式记录两种模式的内存：GNU time 的最大 RSS 为该子进程的 OS 高水位；每 0.5 秒通过 nvidia-smi 采样本进程组的 GPU memory，记录全部样本与峰值。这是**采样峰值，不是精确 allocator 高水位**，不能仅由采样值替代显存 gate；结合上轮 staging 替代 incoming 的确定性账本判断，必要时补相同二进制的分配级高水位。监控为外部串行查询，两种模式一致；记录的实际采样时间含查询开销，周期并非硬实时 0.5 秒。

每图输出两个 CPU/GPU 三批总时比、两个配对是否同向下降、聚合降幅是否至少 5%、各 run GPU 采样峰值与 CPU RSS。先审查性能和内存，再决定两图十批 correctness 与 TW/FS 回归，不以任一单项通过自动切换默认。

## CPU 是什么算法

`include/framework/i16_cpu_repair.h` 中是单线程多源 Dijkstra。把所有有限的 affected 初始距离和外部边界候选视为不同初值的起点，相当于从一个虚拟源点接入这些起点；随后每次处理最小 tentative distance 的顶点，用 `std::priority_queue<..., greater<...>>` 实现最小二叉堆。

没有 decrease-key：距离改善时压入新条目，旧条目出队时若已过期就跳过。权重为 1..128 的正整数，符合 Dijkstra 条件。CPU helper 的独立测试和真实连续状态已验证与 GPU 基线距离一致。它只求解当前 affected 区域，外部边界距离保持不动，不能称为每批重新跑全图 Dijkstra；同时输入整理使用按原图节点数分配的临时映射，所以准备阶段仍包含 `O(V)` 工作。

原 GPU pull 的主要问题是反复检查整个 affected incoming，CPU PQ 则在顶点有效出队时扫描其出边。本轮真实图中 internal_scans=internal_edges，说明可达 internal 边没有发生普通 frontier 那样的大量重复传播。最终 tight parent 另扫 incoming 重建并回写，不靠并发竞争更新 parent。

## 要不要优化

有优化空间，但**本轮配对期间冻结算法**。先确认已经实现的完整收益，避免把数据准备、队列、监控和运行版本一起改变。

上轮三批平均成本：

| 项目 | EU | USA |
|---|---:|---:|
| gather，含 ID 构造/排序去重/分配与传输 | 6.064 秒 | 3.464 秒 |
| setup/transpose | 5.441 秒 | 2.420 秒 |
| Dijkstra PQ closure | 8.304 秒 | 4.032 秒 |
| parent 重建 | 0.979 秒 | 0.591 秒 |
| scatter/同步/释放 | 0.099 秒 | 0.057 秒 |
| 总 repair service，不含 topology | 20.930 秒 | 10.585 秒 |
| 过期出队 / 全部 pushes | 0.532% | 2.242% |

gather+setup 约占 service 的 55%/56%，大于 PQ 本身；但当前 gather 是合计，尚不能区分其中排序和 PCIe 的精确份额。heap stale 少只能说明重复队列项不是主浪费，不能证明堆操作成本可以忽略。

建议下一优化顺序：

1. 配对通过后，首先拆分 ID 构造/去重、分配、实际 H2D/D2H、索引与 transpose，确认成本归因。
2. 优先测试一次线性去重替代当前 `O(E log E)` union 排序，并研究与现有临时 membership/index 合并，避免额外全图状态副本或跨批 stale 状态。保持原算法、tight parent 和完整 timer 契约，一次只改变一个主要因素。
3. 若 PQ closure 仍占显著成本，再用整数距离的成熟 radix heap 或正确的桶算法做独立比较。即使边权上界为 128，multi-source 初始距离范围也可能很大，不能直接假定 129 个循环桶足够且安全。必须计入桶扫描、再入队与完整 batch，避免逐图桶宽调参。
4. 暂不做并行 Dijkstra 或 CPU/GPU 同时传播：目前没有证据表明新增同步、去重和内存成本值得支付。

这一评估不改变当前实验模式或默认 GPU 路径。配对结果尚未返回时，不宣称性能/显存 gate 已通过。
