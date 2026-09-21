# I17-B6 完成结果复核与必要补测

全部时间为两批 paper 合计，单位秒。同二进制、同输入配对；没有重复稳定性实验，不把小差异当稳定收益。原始结果在 `logs/i17_scaling_20260911/experiments/results.json`。

| 图 / 每批更新 | pull | ordered | 加速 | ordered 插入占比 |
|---|---:|---:|---:|---:|
| USA 100k | 80.405 | 16.492 | 4.88x | 43.9% |
| USA 1000k | 186.018 | 76.336 | 2.44x | 77.0% |
| EU 100k | 233.636 | 36.374 | 6.42x | 47.5% |
| EU 1000k | 571.462 | 221.641 | 2.58x | 82.3% |

四组最终 distance checksum 相同。USA 100k 另做两批 check=true，distance/Bellman/existential tight witness 通过；EU 本轮没有同等全阶段正确性验证。历史 stored-parent 不一致未解决。

路网删除重复扫描瓶颈已明显缓解，1000k 的主要矛盾转到插入传播；reverse 两批不到约 1.2 秒，不是主要数据结构瓶颈。USA/EU ordered 1000k/100k 耗时比为 4.63/6.09。不可用这些两批与原仓库历史十批直接算加速，表中基线是当前 pull。

FS 1000k：64/1 分片为 2.833/3.641 秒，整批下降 22.2%；reverse 0.263/0.992 秒，下降 73.5%。FS 100k：0.644/0.513 秒，64 分片反而慢 25.5%，主要差异在删除阶段而非 reverse（reverse 0.027/0.063 秒）。这组单次短测不支持小批稳定收益，更不是相对原仓库退化的证据；新 cohort 与历史不直接配对。

## Twitter 结论撤回与纠正

此前 Twitter 三档沿用 source=0，新 dense ID 映射下 final_reachable=1，E4-R1 insertion processed_edges=0，各档最终 checksum 恒定。因此 0.381/1.849/16.614 秒（64 分片）只能说明 topology mutation、准备成本；1000k→10000k 约 8.99 倍不能当真实 SSSP 传播扩展性证据。

该错误来自实验源点选择，不是数据条数错误；数据无需重新生成。补测同一底图实际有出边的源点 28512093（底图首条源点），100k/1000k/10000k 各两批，仅64分片，最大档 check=true。必须复核 final_reachable 与 processed_edges 后才能使用新结果。runner 已修正后续 Twitter 源点。

## 失败与补测裁决

唯一实际失败项 FS 10000k s64：415 秒 wall 后，在第一批插入 BeginInsertionEpoch 中 cudaMalloc node_state_epoch 时 OOM（65,608,366 * 4 = 262,433,464 bytes，约250.3 MiB）。不是时间上限，也不是 reverse 错误。第一批已完成：删除 4.429 秒（其中修复 wall 1.152秒），reverse delete/add 0.832/0.631秒；插入 topology mutation 2.038秒。此时还有 240MB patch staging、约124MB repair incoming 工作区，且 cache=2 的两份边缓存合计约4GiB。失败分配仅为触发点，不能把全部 OOM 归因于该数组。

不原样重跑 s64，不补同配置 s1，也不恢复整个队列。只跑一项同 frozen binary、cache=0、64分片、两批 check=true，隔离缓存与大批临时工作区共存限制。其结果是容量诊断，不能当 cache=2 配对性能或“默认配置已修复”。若成功，后续应处理峰值显存预算/阶段临时空间复用；若仍失败，依据新失败位置进一步裁决。

已启动 `scripts/run_i17_scaling_supplement.py`，仅四项（FS容量诊断+TW三档），每项30分钟上限，单项失败不阻断独立补测，不修改已有 frozen binary。

```bash
cat logs/i17_scaling_20260911/supplement/status.json
cat logs/i17_scaling_20260911/supplement/results.json
```

每项完整日志、manifest、summary、RSS 在对应子目录。原始 failed 状态保留，补测独立存档。
