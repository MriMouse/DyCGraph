# I16 显式 CPU PQ 完整修复实验

## 最终结果与决策

本轮已完成，`logs/i16_cpu_pq_validation_20260907/status.json` 为 completed，PID 1816308 已退出。两图各三批 deletion-stage/batch/final Bellman 检查全部通过，publication 无错误，final reachable 分别为 26,156,568/13,127,169。重新解析日志与归档 checks 一致，每批 deletion-stage 与 batch distance checksum 均与冻结的原 GPU 三批基线一致。两个最终 checksum 为 EU `3684615018189870922`、USA `14266692420180536690`。

| 实际运行指标，秒 | EU b0 | EU b1 | EU b2 | USA b0 | USA b1 | USA b2 |
|---|---:|---:|---:|---:|---:|---:|
| incoming topology | 1.944 | 2.053 | 2.725 | 1.135 | 1.205 | 1.324 |
| gather，含 ID 去重/分配 | 5.607 | 5.735 | 6.850 | 3.445 | 3.430 | 3.516 |
| CPU setup/transpose | 5.019 | 5.222 | 6.080 | 2.297 | 2.428 | 2.535 |
| PQ closure | 7.643 | 7.934 | 9.334 | 3.976 | 3.980 | 4.140 |
| tight parent 重建 | 0.891 | 0.956 | 1.089 | 0.594 | 0.574 | 0.604 |
| scatter/同步/释放 | 0.092 | 0.094 | 0.111 | 0.057 | 0.056 | 0.058 |
| repair service，不含 topology | 19.295 | 19.980 | 23.516 | 10.391 | 10.489 | 10.874 |
| 完整 mixed batch | 34.278 | 28.282 | 32.032 | 16.690 | 15.013 | 16.814 |

三批完整 batch 均值为 EU 31.531 秒、USA 16.172 秒。首批与之前无快照 E1 的 GPU batch 111.916/41.663 秒相比呈现明显下降，但这不是同次 A-B-B-A；旧 E2 三批首批还含 snapshot 开销，不能将旧数据混合作为正式 speedup 分母。当前只有 check=true 单次完整成本筛查，尚未通过 E3/E4 稳定性能 gate。

每批 GPU staging 都为 20,971,520 bytes，避免的 GPU incoming 副本为 EU 337,112,428/343,487,104/406,286,600 bytes，USA 208,946,524/209,764,556/213,906,932 bytes。解析器确认 staging 不超过被替代预算；整程序 GPU 峰值与 CPU RSS 尚未建立相同条件的配对测量，保留为下一 gate。

CPU PQ internal scans 与 internal edges 相等：每条可达 internal 边仅在优先队列有效出队时扫描一次；边界/transpose/parent 扫描另计。CSV 的 CPU 行 `iterations=0`、`logical_incoming_checks=0` 是沿用 GPU 列的无适用项，不代表 CPU 无工作，CPU 工作量应读取 `internal_scans`、`repair_service_ms` 与完整日志。

全图 stored-parent 诊断仍存在：EU 删除阶段 4/155/58、batch 619/879/1007；USA 删除阶段 2/69/18、batch 807/901/718。候选只重建 affected parent，外部状态不回写，插入仍走原实现；不将本轮正确距离解释成全图 parent 已修复。不同 run 的 parent/affected 可不同，因此验收对照逐阶段距离，不能比较 affected ID 作为强制相等契约。

**本轮收口为“显式 CPU PQ 真实交接与三批正确性/完整成本筛查通过”。** 实验模式保留，默认仍为 GPU pull。下一轮固定同图同参数、无 capture/诊断 trace，以相同 binary 显式 GPU/CPU 模式做三批 A-B-B-A，并记录完整 batch、整程序 GPU 峰值、CPU RSS；两个配对同向改善及既定性能/内存 gate 通过后才开展两图十批 correctness 与 TW/FS 回归。无需微调算法参数、扩大图比例/批规模或恢复 GPU frontier。当前没有新后台任务。

SSSP/BFS/CC/PR 全部构建通过；CPU helper CTest、独立 Python fixture、ASan/UBSan、五项 runner 回归、GPU 三批 smoke 和 `git diff --check` 均通过。

## 本轮微调

普通 GPU frontier 的同状态距离/tight parent 已过，但双队列暂存预算和重复传播未满足接入条件。继续已计划的 CPU PQ 分支，本轮把“离线服务比较”收紧为“真实运行时读取、求解、回写及连续状态检查”。不继续调整 frontier 线程数/队列容量，不扩展数据矩阵。

新增 `--i16_cpu_pq=true` 为显式实验模式，默认关闭，不能与 CPU insertion ownership、domain map 或 snapshot capture 同用。既有 GPU pull 保持默认，不做自动 selector、固定 CPU quota 或 CPU/GPU 同时传播。当前阶段只做三批 check=true，尚未准入 E3/E4 配对或默认生产切换。

## 状态与成本

1. 沿用真实物理删除、invalidation 和 authoritative reverse incoming materialization。
2. 在 repair 边界构造 `affected ∪ incoming sources ∪ source`，从真实 GPU value/buffer/parent 分块 gather。CPU 只在当前修复中建立临时状态与索引，不维护跨批全图 CPU value mirror。
3. 使用标准 priority queue 做 multi-source Dijkstra，权重为 `uint32(src+dst)%128+1`，uint64 累加、INF 截断。有限 affected 初值及有限外部边界均为种子。
4. 基于最终距离扫描 incoming，选择最小 ID 的 tight predecessor；任何有限非 source 顶点缺少 tight parent 直接报错。不可达点 parent 清为 INF。更新只写 affected，外部源状态不回写。
5. 分块 scatter affected value/buffer/parent，并清除其 reset flag，GPU 同步后才继续原有插入流程。

`[I16-CPU-REPAIR]` 单列 topology、gather（含 ID 去重与临时分配）、CPU setup/closure/parent、scatter（含 GPU 同步及暂存释放）、service、internal scans、PQ pushes/stale/queue peak。service 不含前面的 topology；它们均进入 deletion 与完整 batch wall。CPU 临时容器析构也留在外层 batch 计时内，不能仅将内层 service 当成完整 deletion 时间。`[P0-DELETE-ATTR]` 明确标记 cpu_pq；解析器按 executor 区分，不将 PQ 当作 GPU pull 轮数。

## 内存账本

本分支在 `EnsureGpuAffectedRepairCapacity()` 和 incoming H2D 之前分流，故每批不分配 GPU incoming offsets/sources 副本。GPU staging 仅有每顶点 uint32 ID 和 16-byte state，容量为 `min(1M, union_size, floor(avoided_bytes/20))`，其中 `avoided_bytes=8*(affected+1)+4*incoming+4`，保证小图也不凭空放宽预算。暂存最多 20 MiB，gather 与 scatter 复用，scatter 后释放。

其余初始化常驻分配保持原状，包括目前 CPU 模式并不需要的旧 GPU changed-vertices 数组；本轮不借机整理 allocator。针对该替换阶段已有“减少 incoming 副本、增加更小暂存”的确定性账本，但没有把它当成实测整程序峰值结论。CPU 临时内存为 `O(V+A+E_in)`，包含 ID、value/seen、outgoing CSR、前后 state 和 PQ；后续性能 gate 仍须记录 CPU RSS 与完整 GPU 分配高水位。

## 测试与执行

`i16_cpu_repair_test` 直接测试候选求解 helper，与独立 Python shortest path 逐点比较，并逐 parent 检查存在实际 incoming tight edge。覆盖长链、多入口、重复边、环、不可达、source、有限初值、INF/溢出及坏文件/重复 ID/错距离拒绝；CTest 通过。runner 五项回归通过，包括 CPU metric 缺失/显存预算越界拒绝。

三批实机小图 `tests/i16_capture_smoke.py --cpu-pq` 通过，与原 GPU smoke 的每阶段 checksum 一致，删除阶段 invalid_parent_witness 为 0。日志 `logs/i16_cpu_smoke.log`。

真实数据队列启动 PID 1816308，目录 `logs/i16_cpu_pq_validation_20260907/`：

```bash
python3 -u scripts/run_i16_road_validation.py logs/i16_cpu_pq_validation_20260907 \
  --suite connected50 --batches 3 --cpu-pq
```

EU50p -> USA50p，source=1，100k mixed，三批，各 50k add+50k delete，cache=2、capacity=0、workers=20。输入 checksum/连通证书审计，冻结 binary、候选源码、runner 和原三批 correctness。对照每一批删除阶段和最终距离 checksum，任意不一致即停止。只使用完全空闲 GPU 0，单卡串行，单进程 wall 上限两小时。资源阻塞后同命令加 `--resume`，其他失败不得静默跳过。

完成后先判断六批 correctness、逐阶段距离一致性和状态交接成本；通过才计划无 trace 同数据配对及显存/RSS gate。旧 parent 诊断不能由 CPU affected 修复推断全图已修复，插入之后仍要检查。最终结论以 status、correctness 和 work_summary 为准，不按启动状态提前记成功。
