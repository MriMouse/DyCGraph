# CC 真实图性能审计与删除修复改造（2026-09-23）

## 原始实验的结论

输入证据：`logs/cc_real_20260923/{runner.log,result.json,runs/}`。

| 图 | 本版十批 ms | 删除 ms | 删除占比 | 原版十批 ms | 原版最小标签不符顶点 |
|---|---:|---:|---:|---:|---:|
| OK | 5226.612 | 4541.059 | 86.88% | 2638.749 | 4 |
| TW | 28496.926 | 27909.046 | 97.94% | 未完成 | 未验证 |
| FS | 初始化 OOM | 未进入更新 | — | 14870.646 | 308 |

进一步按“同分量当且仅当同标签”检查分区：OK 的 4 个差异全部只是非最小代表，分区通过；FS 有 227 个 merge conflicts，分区失败（不是仅仅标签改名）。因此 OK 可按 partition-only 语义比较耗时，但严格最小标签契约仍不一致；FS 错误结果不能作为有效加速比基准。详见 `original_OK_partition.json`、`original_FS_partition.json` 及诊断程序 `partition_check.cpp`。两版读取同一预先对称化输入，`cc_input_symmetric=true` 不再次扩边；双向邻接增加绝对内存和扫描量，但不能解释双方的删除算法工作量差异。实际每批删除/插入数量必须按 `.sizes` 的有向 occurrence 计量，不能将双向记录数直接称为逻辑边数。

OK batch 0：affected=3,017,841，incoming=117,084,719；物化 280.715 ms，H2D 102.153 ms（492,481,612 bytes），7 轮闭包 185.427 ms。其后仍几乎每批扫描整个巨分量。TW 同样受整分量修复主导。FS 报错位置为 GraphDatum 构造过程的 Queue 分配，而非更新或最终输出。

## 与 SSSP 的机制对应

- 共用 source-local chunk、分组 regular/large/auto 维护、occurrence 删除、两阶段资源预检和 epoch 回收。
- 共用合并拓扑 publication、稀疏描述符、cache patch/tail、refresh gate 和热度统计。
- 共用严格成功事件驱动的 exact insertion frontier、block/thread/ordered 调度、CPU ownership 和 boundary runtime。
- 共用 P0 批计时、通信 ledger/window、独立正确性检查入口。
- **不能直接共用失效语义**：正权 SSSP 的距离和 parent witness 不等于零权 CC 的生成森林。相同标签形成的环不能证明删除之后仍与旧根连通。把整分量失效直接改为旧 parent 子树会重新引入原版的错误结果。
- CC 的双向 forward 本身可作为 incoming；旧实现虽省下永久 reverse index，仍在每批为 affected 物化并上传一个临时 incoming 图，导致上述放大。

## 本轮实现

新增 `include/framework/cc_union_repair.cuh`。保持保守但正确的整旧分量 affected 集合；GPU reset 将其 value 初始化为自身 ID，随后直接扫描 chunk 邻接，用 CAS 将较大根挂到较小根。每条无向边只执行一个方向的 union；自环跳过，重复 occurrence 幂等。查根采用 path splitting，避免挂接顺序形成长链和耗时波动。独立 flatten kernel 将根写为最终 value/buffer 并清除 reset 标志。

复用 collect 已置为 UINT_MAX 的 CC parent/witness 数组临时标记 changed source：其旧 cache 禁止读取；未改变的行继续利用现有 GPU 热缓存（非缓存部分仍读 chunk）。没有按度数或标签猜测 cache 是否有效，也不额外申请全 V bitmap。flatten 恢复 affected 顶点的 witness；此标记不是跨批维护的生成森林。

正确性：删除后没有边能连接不同旧分量，因此 affected 集合对当前邻接封闭；初始单点集合合法；每次 CAS 只合并某条现存边连接的集合；单调下降的根 ID 排除环；所有边处理结束后集合恰为当前连通分量，最小 ID 是唯一标签。不依赖异步标签传播的父节点，不设置静默迭代上限。

该路径省去 affected 队列 D2H、主机逐顶点分区扫描、incoming offsets/sources 物化、全邻接 H2D、副本显存和反复 pull 扫描。复用原有 value/buffer、affected queue 与 publication staging；没有新增常驻顶点数组。

关键可见性协议：删除 CPU mutation 之后、union 之前，`StageDeletionDescriptors` 在同一 stream 上用已有 sparse staging 更新 changed source 的 GPU descriptor。此时只有对 changed source 绕开 cache 的 CC executor 可以读取；不提前提交 epoch、不改 cache、不回收旧 chunk。union 完成并同步后才允许插入 mutation，插入阶段仍按原协议发布合并 delete/add source 集合及 cache。不能直接使用上一批 GPU descriptor，也不能把两个阶段各自当成完整 publication epoch。

`CG_CC_REPAIR=union|pull` 用于对照。默认 GPU CC 使用 union；显式 ordered repair、固定 CPU domain 或 component trace 保留原路径。SSSP/BFS 不切换到 CC executor。保留原路径是为了维持这些明确请求的语义及诊断信息，不能把新 GPU 路径的收益宣传成 CPU 协同收益。

另修复 worklist rebuild 的空 segment 和 cache load 的空 queue：reset queue 后直接返回，避免 launch grid=0。Compute Sanitizer 在原先回归结果看似正确的小图初始化发现大量 cudaErrorInvalidConfiguration；新修复的错误检查暴露了这个遗留问题，不能简单清除 last error 掩盖它。

## 内存与进一步重构边界

FS 使用 `hybrid=2` 会分配 legacy 显式传输/compaction 缓冲，包含 `E/4 * sizeof(index_t)` 的 device edge_dst_com（该图约 1.81 GB）、两个 V 长 subgraph 数组及多 stream segment 缓冲。另有 cache2 的两个约 2 GiB 缓存数组、大量 V 长状态/描述符/排序/队列数组。CC 双向边会放大其中按 E 分配的部分。不能把这一配置的 OOM 说成 CC 计算错误。

本轮真实 FS 验证使用当前 SSSP 主线也采用的 `hybrid=0`，显式记录配置变化；不偷偷缩 cache，不把跨配置结果当同配置加速比。新修复不会再申请整个 affected 邻接的 GPU 副本，避免初始化通过后第二次在 repair 阶段遇到 O(E) 显存需求。

要获得与 SSSP 小 affected 相近的工作量，仍需独立研究维护真实生成森林：插入合并、删除树边 cut、替代边搜索、无替代时分裂与最小标签修复；非树边删除才可凭森林证书跳过。仅在完整 batch 删除后的拓扑上成立的替代路径可作为证据，逐边在旧图上找到路径可能形成相互依赖而错误跳过批量割集。需要保留平行边计数及多阶段 oracle。并查集路径当前是降低巨分量重算成本，不是完成 fully dynamic connectivity。

## 实验记录

构建、回归、sanitizer、真实图运行命令与独立 oracle 结果保存在 `logs/cc_repair_20260923/`。最终版 OK 同 GPU2、NUMA1、20 workers、hybrid2/cache2/SEGMENT512 十批为 **1613.422 ms**，原迁移版 5226.612 ms，降低 69.13%、加速 3.24×；原版 2638.749 ms，按 partition-only 语义计原版/新版为 1.64×。新版 3,072,442 个标签逐一通过独立最小标签 oracle。该数字是一次真实图筛查，不是三轮中位数。

中间不复用 cache、不做 path splitting 的候选 OK 为 2925.413 ms，正确性通过；该候选 TW 在缓存 refresh 后暴露 `RunSyncCom` 空队列 grid=0 错误，仅完成 8 批，不能算作通过。最终版已为这个入口补 guard；失败日志保留用于解释修复依据。

## 后台实验最终结果

三图均完成十批，进程退出码及独立最终 oracle 退出码均为 0。汇总见 `logs/cc_repair_20260923/final/summary.json`。

| 图 | 改造前十批 ms | 本轮十批 ms | 相对迁移版 | 最终标签错误 |
|---|---:|---:|---:|---:|
| OK | 5226.612 | 1613.422 | 3.24× | 0 / 3,072,442 |
| TW | 28496.926 | 2400.331 | 11.87× | 0 / 34,956,270 |
| FS | 初始化 OOM | 27688.257 | 无可计算基准；hybrid2→0 | 0 / 65,608,363 |

FS 全进程 wall=1752.321 s（约 29.2 分钟，包含加载、初始化、计算和输出；外部 oracle 在进程结束后另跑），十批 P0=27.688 s，不得混用这两个口径。hybrid0/cache2 已在当前 16 GB GPU 上完整运行，不能据此声称 hybrid2 的 OOM 已修复。

FS 删除合计 25.687 s，占 P0 的 92.77%；其中 union 修复合计 25.062 s，每批 affected 55,975,491–55,975,599 个顶点。插入仅 0.769 s，eviction/compact/load 合计约 0.903 s，故当前主瓶颈仍是整旧巨分量扫描。cache2 容量 536,870,921 个邻接记录，约为 1,806,080,119 总记录的 29.7%，无法像 OK/TW 那样覆盖全图。这支持继续减少 CC 删除受影响范围的结构性优化，而不是继续移植相同的 SSSP 调度开关。

FS 原版十批 14.871 s，当前耗时仍是其约 1.86 倍；原版存在真实错误合并且 hybrid 配置不同，不能发布有效的同语义加速比。明确结论：OK/TW 获得显著改进，FS 达到完整运行和最终正确性门槛，但尚未达到性能追平目标。下一步应围绕受维护的生成森林、树边删除及替代边搜索建立 CC 专用增量算法，而不是把这轮并查集重算称为已完成的小范围增量修复。

验证补充：CC 16 场景、262 个阶段通过；OK 真实图另外 20 个增删阶段和最终状态均通过独立 oracle；缓存版混合批次 Compute Sanitizer 为 0 错误；9 项相关 CTest 通过；共享 BFS 30 个阶段、SSSP GPU/CPU 两种配置的最终距离通过独立参考校验。本轮真实图性能为单轮筛查，未进行三轮中位数实验。

## 后续修复（2026-09-24）

本报告上方保留上一轮测量。后续已用当前邻接的采样连通证据跳过冗余分量内部扫描，并缩小 CPU per-source mutation 统计。FS 十批从 27.688 s 降为 4.948 s，最终标签全通过；OK/TW 的同配置收益及 OK 额外维护开关见 [后续报告](cc_sampled_repair_20260924.md)。新方法仍不是维护动态生成森林，不能将此收益描述为非树边删除的常数开销。
