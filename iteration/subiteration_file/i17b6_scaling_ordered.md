# I17-B6 大 batch 与运行时 ordered 短测（2026-09-11）

按最新要求启动，不追加稳定性矩阵。状态、报告根目录：`logs/i17_scaling_20260911/`。

## 数据口径

`prepare_i17_scaling.py` 复用 data 的 Friendster SplitMix64、ID 映射与采样组件，Twitter 读取已有 packed uint64 原始边。
FS 50% 底图、TW 10% 底图；每图三档共用底图和全源图排序 dense ID 映射。
每档真实每批 100k/1000k/10000k 条更新，各两批，每批插入删除各半。每批小档为大档的嵌套样本；每种操作按源边 occurrence 不放回抽样。
旧 TW 1000k 文件实际每批只有 200k，不能继续使用其文件名作为规模依据。
新 cohort 的 ID、底图与旧 TW 不同，不能把新旧结果直接当同状态配对；保留 100k 新参照。
输出位于 `data/i17_scaling_20260911/{friendster,twitter}`；只有 `ready.json` 出现才可使用。

## 实现与边界

新增 `include/framework/ordered_gpu_repair.cuh`，从已验证 compact replay 的设备选桶、队列分区、稀疏扩展提取算法，进程内接入 `RunGpuAffectedRepair`。
`CG_ORDERED_REPAIR=1` 人工开启；新 EU/USA 实验默认开启，并追加同 binary pull 对照。
GPU 初始化边界种子，在 affected 子图上建立 outgoing CSR，按 128 距离桶传播；GPU 发布最终距离后，从 incoming edges 重建 tight parent，并由原 Finalize 清除 reset 状态。
完整 batch 包含转置、分配、H2D、发布、释放。`I17-ORDERED` 单列 prepare/closure/publish/扫描/额外显存；外层 `B2 closure_ms` 包含整个 ordered 调用，不能误当纯传播时间。
运行时全局默认仍为 pull；CPU owner/component trace 不支持 ordered，显式报错。插入阶段暂未更换算法。

## 验证与实验

- hybrid_sssp 编译通过。
- 三批小图 CG_ORDERED_REPAIR=1 capture smoke 通过，独立 CPU oracle 距离 mismatch=0；包括删除、插入及恢复删除边。
- topology_contract/source_local_chunk_store/dynamic_reverse_index 三项 CTest 通过。
- 小数据生成器测试验证真实条数、底图硬链接、批内嵌套和更新合法性。
- 后台队列：USA 100k 两批 check=true；USA/EU 100k/1000k 各 ordered/pull 两批 check=false；TW/FS 100k/1000k/10000k 各 64/1 reverse shards 两批；每图 10000k 另两批 check=true。
- 初步 USA 100k 第零批删除：affected=12,449,097；ordered 准备 1480.525 ms、传播 461.637 ms、发布 17.071 ms，扫描 27,774,193 边；完整 repair wall 3479.745 ms。删除阶段 distance/Bellman/tight witness 通过。该值不是完整两批结果，也不是最终 speedup。
- 历史 stored-parent race 仍以 existential tight witness 为 gate；USA 该批 invalid_parent_witness=1，未声称消除此问题。

## 查看

```bash
cat logs/i17_scaling_20260911/experiments/status.json
cat data/i17_scaling_20260911/{friendster,twitter}/status.json
cat logs/i17_scaling_20260911/experiments/report.md
```

`status.json` 每 5 秒更新当前 GPU run/PID/完成批数；数据生成状态按 chunk 更新，selecting 期间可看 `generate_fs.log` / `generate_tw.log`。
每项最长两小时，数据等待最长一天，失败会写状态并停止后续 GPU 实验。每项命令、binary SHA256、输入 stat、原始日志、RSS 和分项均保存。
结果未完成前不宣称 10000k 扩展性已解决；接下来用 paper 两批合计、reverse/CPU mutation、ordered 准备/传播与 insertion 分项裁决后续瓶颈。

首组完整性能（USA 100k、两批、check=false）：ordered 16.492 s，pull 80.405 s，4.875x；外层 repair closure 4.449 / 68.871 s，插入 7.240 / 7.261 s。另行两批 ordered check=true 的删除阶段、批末与 final Bellman 通过；stored-parent 不一致仍是已知诊断，未修复。配对最终 checksum 相同：True。数据生成与剩余队列继续后台运行。
