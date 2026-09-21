# I17-B：GPU 长传播成本优化收口

2026-09-08：冻结独立 replay 的 `compact` 候选，即设备控制合并与双缓冲复用。相对同二进制 `sparse`，EU/USA 完整 replay service 平均下降 11.6%/8.1%，显存减少 79.1/47.5 MiB。研究阶段成本/空间 gate 通过；生产默认仍为 pull，下一步为 I17-C 手动启用判据验证。

## 实验口径

- 使用 `logs/i16_e2_capture_20260907/` 的 EU/USA connected50 source=1 同状态快照，SHA256 与原 correctness manifest 一致。
- 每图按 sparse-compact-compact-sparse 交错执行；再各做一次 profiler，诊断轮不进入性能均值。只使用空闲 GPU 0，实验全部串行结束。
- 冻结目录：`logs/i17b_final_compact_20260908/`，含 binary/source、manifest、逐轮 JSON、memory samples、Nsight trace/stats、analysis 和 completed 状态。
- 二进制 SHA256：`f030fc6e71f005ef4597707c75dadb572cdaefe1bb30c9bf332b0294fa3cc56e`。
- `service_accounting_version=2`：complete service 包含 index/validation、boundary/count、transpose、context/allocation、H2D、closure、D2H、parent 重建和 host/device workspace 释放；结果校验、快照文件读入/销毁不计入。首次准备完整计入，不假设跨批复用。
- 不包含生产 gather/scatter、authoritative state 提交或跨批拓扑维护，不能当作完整 mixed batch 加速。`service_ms` 为释放前的历史字段，不能混用旧版 complete service（仅计 device free）。

## 最终配对

下表为两次无 profiler 运行均值；空间单位为 MiB，时间为 ms。

| 指标 | EU sparse | EU compact | USA sparse | USA compact |
|---|---:|---:|---:|---:|
| complete service | 7960.971 | 7037.937 | 3750.465 | 3445.975 |
| closure | 1752.163 | 1061.802 | 768.161 | 465.347 |
| host setup | 5199.253 | 4980.790 | 2325.815 | 2329.798 |
| parent reconstruction | 665.900 | 662.036 | 417.975 | 407.152 |
| device allocation | 795.924 | 716.844 | 484.188 | 436.698 |
| control D2H calls | 109293 | 36431 | 46170 | 15390 |
| internal edge scans | 42986793 | 42986793 | 27774193 | 27774193 |
| selection checks | 627418532 | 627418532 | 135237154 | 135237154 |

EU 两个 service 比值为 0.8661/0.9028，USA 为 0.9114/0.9263；两图 compact 的最慢样本仍快于 sparse 最快样本。closure 均约下降 39.4%。EU setup 同期约有 218 ms 波动，该分项代码未改变，不能把这部分全部归因于候选；更直接的因果证据是相同传播工作量下约 690/303 ms 的 closure 减少、控制回读从三次变为一次及确定的容量缩减。此为开发期短对照，不是置信区间或论文级重复。

## 子步骤裁决

| 子项 | 实现与证据 | 裁决 |
|---|---|---|
| B0 成本拆分 | 原 sparse profiler：EU/USA kernel 合计约 459/212 ms，cudaMemcpy API 约 1806/810 ms；后者含等待。准备仍占大头。 | 完成；纠正此前文档的 USA 122/577 ms 误录。 |
| B1 准备复用 | `reuse` 用 CSR end offsets 递减填边，省去 A+1 个 uint64 cursor；节省 host 158.2/95.0 MiB，但会反转 source 内 outgoing 顺序。 | 正确性通过，稳定收益 gate 未通过，不纳入冻结候选。首次拓扑构建成本没有消失。 |
| B2 队列复用 | selected 写 scratch 头部，deferred 写尾部；Expand 将 deferred 搬至旧 active 前缀，并从其后追加新入队项，省去第三条 A 队列。 | 作为最终组合中的空间优化保留；独立配对没有证明加速。 |
| B3 控制合并 | bucket 和 selected count 留在设备；同一默认 stream 顺序执行 Reset/Find/Partition/Expand，每轮只同步读取最终 stats。 | 保留；无跨 block 自旋或 persistent kernel。 |
| B4 桶宽/真正分桶 | compact profiler 的 Find+Partition 约 EU 159 ms、USA 64 ms，低于约 5.0/2.3 s 准备成本；现有收益不依赖减少 selection checks。 | 条件项本轮不启动，固定 delta=128，仍限于权重 1..128 的全轻边。 |

单因素日志：`logs/i17b_control_20260908/`（旧释放口径）、`logs/i17b_compact_v2_20260908/`、`logs/i17b_reuse_v2_20260908/`、`logs/i17b_reuse_confirm_20260908/`。compact 对 device-control 的 service 比值 EU 0.9947/1.0120、USA 1.0075/0.9972，不能宣称独立加速。额外 deferred copy 为 EU 292904694、USA 55007836 个条目，未隐藏新增搬运。

reuse 两组全部保留：EU 比值 1.1454/0.9858、0.9122/0.9774；USA 1.0773/1.1084、0.9817/0.9672。后一次改善不能覆盖前一次回退，也不能只引用省空间推导省时间。模式仅供独立负结果复现。

最终 profiler 中，sparse 到 compact 的 kernel 总时间反而从 EU 457 到 517 ms、USA 208 到 241 ms；cudaMemcpy API 从约 1788 到 931 ms、807 到 450 ms。说明收益主要在控制同步链，不是 relax kernel 加速。API、kernel 和 memcpy device 时间重叠，禁止相加。

## 正确性与容量

55 个回归（11 类状态 × 5 模式）通过，覆盖长链、deferred seed 被改进、循环、随机图、边界 source、多 block、满初始队列、不可达及空 affected。另有 compact/reuse 的 6 个定向 CUDA 12.1 memcheck 用例，全部 `0 errors`。系统默认 sanitizer 不支持 V100，初次尝试报设备不支持；改用 `/usr/local/cuda-12.1/bin` 后通过，不把前次工具错误计为算法错误或通过。

所有大图运行 distance mismatch、missing tight parent、invalid parent 均为零，所有队列排空后 processed=enqueued，queue peak<=A。selected peak 根据守恒式 `old_count + fresh_enqueues - new_count` 重建，不增加控制传输。

容量仍按 A 分配，不按观测峰值截断：初始 affected ID 唯一；partition 输入唯一，因此两端写入总数<=A；deferred 保持 pending=1，selected 清零；Expand 用 atomicExch 去重，新条目最多补齐 A 个不同顶点。deferred 前缀与原子追加区域不重叠，两个 kernel 的 stream 顺序确保 partition 完成后才消费。保留 overflow 检查，没有采用未经证明的小容量。

最终 GPU repair payload 仍约 558.7/341.7 MiB，高于原 pull 约 322/199 MiB。host workspace 约 1.210/0.672 GB，进程峰值 RSS 还包含快照和 CUDA context；不能把数组账本当作全进程峰值。这里只通过相对 I17-A 的成本/空间改进 gate，I18 必须验证生产共存预算、交接和释放后才能接入。

## 复现与下一步

```bash
cmake --build build --target i17a_delta_replay -j 8
python tests/i17a_sparse_test.py build/i17a_delta_replay
PATH=/usr/local/cuda-12.1/bin:$PATH python tests/i17a_sparse_test.py build/i17a_delta_replay --sanitize
python scripts/run_i17a_sparse.py logs/i17b_reproduce --baseline sparse --candidate compact
```

runner 与回归共享本仓库 GPU lock，等待 0 号卡完全空闲，检测到外来进程时只终止自身实验。上轮 `logs/i17b_compact_20260908/` 因进程冲突失败且无有效样本，未纳入本次结论。

I17-C 以 compact 为冻结候选，验证短 pilot 的人工启用建议；默认仍保持 pull。I18 才验证生产状态交接和共存空间，未取得生产速度或六图泛化结论。
