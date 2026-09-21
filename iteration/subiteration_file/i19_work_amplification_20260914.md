# I19：规模与插删比例下的工作放大画像

状态：I19 已完成（2026-09-15）。最终数据、完整结果与 I20/I21 裁决见 [完成报告](i19_complete_results_20260915.md)；下文保留执行过程，旧“待完成”状态以完成报告为准。只执行 I19，不提前实现 I20/I21/I22。正式数据/实验目录为 `data/i19_ratios_20260914_v2/`、`logs/i19_20260914_v2/`；初次采样 pilot 保存在无 `_v2` 的同名目录，已撤销 ready，不进入结论。

## 问题与方法

验证总请求 B、有效操作 U、touched sources S、邻接实际读取/存活边搬移和 reverse 历史工作之间的关系。CPU-only replay 调用当前 `GroupedUpdateBatch`、`SourceLocalChunkStore::ApplyGroupedPhase` 和 `DynamicReverseIndex`，保留 delete/add 两阶段、有效变更 observer、epoch/reclaim；独立 forward 顺序邻接与 reverse multiplicity oracle 在每个 phase 后检查，计时排除 oracle。

Replay 只物化所选输入全部 touched sources 的初始邻接。reverse base 也限制在这些 source 上，overlay preparation 的有效输入和历史合并为生产实现；这不是全图 SSSP，不用它代替完整 P0。它的 epoch/reclaim 时间不是 GPU descriptor staging/publication 时间，`descriptor_payload_bytes` 是两 phase changed-source descriptor 的**逻辑范围**，不是已执行的 memcpy。实际 publication/cache 以生产 GPU 日志为准。CPU RSS 包含 oracle 与稀疏装载，不能当作生产拓扑额外常驻空间。

## 采样审计与一次修订

原有 Wiki 使用 source occurrence permutation，FS 使用完整源图的 sorted dense ID 映射。新生成器以流式 occurrence subsequence 核对现有底图，不修改底图、不重建新 cohort 的 base；FS 从完整源图恢复 ID 映射并保存映射哈希，Wiki 保留原始 ID 和完整 source 的 `max_id+1` universe。

初版使用 `SplitMix64(occurrence XOR seed XOR operation_salt)` 分别排名两个池。FS 的 p10/p50/p90 每批 S 范围为 `94336–94686 / 75377–75783 / 94429–94915`。审计发现不同 XOR 盐使两个池在 XOR 邻近 occurrence 上复用相同 hash 值；源文件按 source 局部排列时，会人为关联插入与删除的 source。实测两类各 900,000 候选中有 449,768 对相同 rank，其中 432,912 对来自同一 source（`sampling_audit.json`）。这不违反更新合法性，却污染比例画像的结构解释。因此在任何大图 GPU 筛查前撤销该 pilot，停止自己的 CPU replay 和未启动 GPU 的排队器，保留负例。

修订为所有 occurrence 共用 **`SplitMix64(occurrence XOR 20260914)`** 排名，按其是否属于底图区分两个互斥池。固定每类 900,000 个候选，每 batch 独占 90,000 个 slot；比例取各 slot 的嵌套前缀。插入候选先保留两倍容量，再流式核对所选 pair 在底图中的重数，剔除初始存在 pair 与重复插入 pair；不足明确失败。删除按 occurrence 和 pair multiplicity 消费。两类池都来自同一源图，禁止随机跨社区补边。

每个比例保存 shared base 路径/身份/SHA256、完整 source 身份/SHA256、候选池和映射哈希、seed、source、B、比例定义、loader 字段、操作顺序、逐批 ID/重数/条数/有效操作/边数验证及生成命令。所有验证成功才写 ready；任何失败删除整个生成目录下的 ready 文件。旧 pilot 已标为 `retired_sampling_pilot`。

更新文件权重字段是 `1`；实际 SSSP 沿用 `uint32(src+dst)%128+1`。`Loader.h` 第一列 additions、第二列 deletions，已经用直接实例化生产 Loader 的 1/9、9/1 fixture 检查，另有 1/3、3/1 三批 GPU 检查。为用标准 C++ 单独编译 Loader fixture，补齐 Loader 自身依赖的 `<cassert>/<fstream>/<sstream>`，并将已有 `Record` typedef 的引用限定为 `::Record`，无语义变更。

## 观测口径和代码位置

- `src/i19_ratio_pool.cpp`、`include/utils/i19_edge_reader.h`：流式 source/base 配对、完整映射、候选排名、初始重数/degree 审计。
- `scripts/prepare_i19_ratios.py`：18 个逻辑数据集、嵌套前缀、逐批状态 replay 与 ready manifest。
- `src/i19_topology_replay.cpp`、`scripts/run_i19_cpu.py`：生产结构 replay、每阶段独立双向 oracle、内存/epoch/历史 overlay 记录；沿用现有 TW/FS 100K/1M/10M 数据，不生成规模数据。
- `include/groute/graphs/source_local_chunk_store.h`：实际 deletion matching 读取数、mutation 的邻接读取数；memmove/memcpy 按参与的邻接元素计数，不是 cache-line/物理流量。写入沿用已有真实写计数，relocation 是写入子集，不能重复相加。
- `include/framework/dynamic_reverse_index.h`：有效输入条数、被合并旧记录数、输出记录数、commit 后累计存活 overlay；取消的净零记录不计入存活 overlay。
- `include/framework/framework.cuh`：`I19-WORK` / `I19-REVERSE-WORK` 生产日志。观测新增少量每 source metadata 与聚合工作，不声称零开销。
- `scripts/run_i19.py`：单卡串行，逐任务检查 compute PID 和 memory.used=0，固定 NUMA 0、20 workers、64 shards、cache=2、ordered=0。性能关闭检查/通信计量；正确性另跑并开启已有显式 CUDA payload 账本。GPU peak 是每 2 s 采样的峰值，可能低于瞬时峰值。
- `scripts/analyze_i19.py`：保留逐批 JSON、两张主表与嵌套口径。reverse prepare 在 mutation/preflight 内，grouping 也在完整 P0 内，不重复相加。effective vector payload 与 reverse copy payload 分列，不冒充完整 CPU copy 计数；radix scratch 是额外一份有效记录工作区（大于等于 4096 条时），来源明确标为代码推导。

尚未测量的物理互连、全部 CPU memcpy、GPU cache/ZC 分类访问均写 unavailable。GPU incoming materialization 的 base/delta scans 和 insertion processed_edges 沿用既有日志；`source_work` 和 `zc_cold_edges` 仍是范围指标，不改称实际访问。

## 验证和当前进展

新增 ratio fixture 验证不对称条数、独立逐批 multiplicity、嵌套前缀、确定性、候选不足时 fail-closed、共享 occurrence 排名。CPU work fixture 验证单边删除的精确查找/搬移、追加与扩容 copy、reverse 历史抵消和累计条数。生产 Loader 不对称 fixture、chunk-store/reverse/grouped-update 及通信账本回归通过。新增三批不对称 GPU fixture 的全阶段 Bellman 与独立 CPU PQ oracle 通过，日志 `logs/i19_20260914_v2/asymmetric_smoke/`。

冻结生产二进制 SHA256：`14fa38c49a350f855abcf77cf27e5ee67db7817b9bdce78de7f6b34bdcc99d7a`。正式队列等待两图生成结束后开始 CPU 计时，避免自己的生成器与 CPU profiling 并发；全部比例及规模 CPU gate 通过后才进入大图 GPU 筛查。没有修改 propagation owner、维护模式选择或任何 I20 结构。

正式 18 组数据的生成与逐批合法性验收已完成，见 [数据验收表](i19_ratio_data_20260914.md)。修订后 FS p10/p50/p90 每批 S 范围为 `99122–99192 / 99122–99220 / 99150–99236`，不再出现初版 50% 组异常凹陷。

正式比例/规模结果、异常解释、I20/I21 的预算与否决条件将在本报告后续补齐；不能把数据合法、fixture 通过或 pilot 局部画像当作 I19 完成。


## CPU 比例画像已完成（正式 v2）

18 组×10 批，180/180 批每个 deletion/addition phase 的 independent forward/reverse oracle 通过。所有请求有效，所有批次回收后 retired capacity 为 0。以下均为十批合计/十批 U 归一化，不能与 GPU P0 混用：

| 图 | 插入比例 | CPU service ms | 邻接写入 bytes/U | 实际邻接读/U | reverse merge ms |
|---|---:|---:|---:|---:|---:|
| WK | 10% | 814.456 | 225.21 | 115.09 | 31.92 |
| WK | 90% | 520.271 | 34.44 | 14.29 | 19.83 |
| FS | 10% | 727.105 | 268.54 | 135.80 | 24.40 |
| FS | 90% | 480.701 | 38.80 | 16.50 | 16.09 |

数值以 `logs/i19_20260914_v2/analysis.json` 的原始精度为准。18 组十批末 overlay 都为 1,000,000 条；由于全十批插入 pair 唯一且从底图外选取，删除 occurrence 从底图选取，本次无跨 phase 抵消。该单调累积是输入契约的实际结果，不能宣称覆盖删除已插入边造成的 overlay 抵消；抵消路径由结构 fixture 覆盖。

初步证据更支持 I21 优先研究存活邻接搬移范围，而非立刻增加 reverse 历史整理：merge 时间只占本次 CPU service 的少量部分。最终启动预算仍要等规模轴和完整 GPU 时间，不用 100K 比例数据替代 10M 证据。


## 后台队列恢复

用户发现 GPU 无运行进程后检查：原调度器及 child 均已不存在，状态仍停留 Wiki p30 performance；该项日志包含十批、final checksum 和 Test passed，但无最终 status.json。无法从现存日志确定退出原因，不将其认定为算法错误或已验收结果。保留至 `logs/i19_20260914_v2/interrupted_attempts/`，用 nohup + 新 session + 显式日志/关闭 stdin 独立启动 runner；完整保存且二进制/manifest hash 一致的结果跳过，p30 performance 重跑。启动记录见 `background_launcher.json`。
