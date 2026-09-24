# CC 删除扫描与维护开销修复（2026-09-23—24）

## 结论与问题定位

本次在 `cc_repair_20260923` 的正确 union 修复版上继续优化。主因不是遗漏零权 CC 插入算子，也不是输入被重复对称化，而是删除任何非自环边都会收集整个旧分量，随后扫描全部邻接。FS 每批约 5600 万 affected 顶点；原十批 repair 为 25.062 s，总 P0 为 27.688 s。GPU cache 只能覆盖约 29.7% 的双向邻接，未缓存的全边扫描使 FS 特别慢。

SSSP 的正权 parent witness 不可直接当作 CC 的生成森林。相同标签的环在删除后可能整体脱离旧根，因此本次没有恢复原系统的 parent 子树失效逻辑。输入的双向 occurrence 仍是正确的无向邻接表示；`cc_input_symmetric=true` 下不再扩边。新增边仍通过严格成功的 atomicMin 生成 exact frontier，稀疏传播及拓扑 publication 仍使用共享实现。

OK 在 GPU repair 降低后暴露 CPU 维护成本：每个 source 的 `apply_metrics` 分配一个 240 字节、30 字段的完整批统计对象，但 mutation 实际仅更新 3 个 uint64 计数。此外，现有 source 线性合并开关未启用，发布时对两个已有序列表重新排序；OK 十批这一步约 0.14 s。

## 代码变更

- `include/framework/cc_union_repair.cuh`：增加当前邻接采样、冻结 roots、选择分量与剩余边扫描。
- `include/framework/framework.cuh`：union repair 串联新 kernels，默认开启；`CG_CC_SAMPLED_REPAIR=0` 保留全扫描对照。
- `include/groute/graphs/source_local_chunk_store.h`：per-source mutation metrics 从 240 字节缩为 24 字节。仍汇总相同的 edge reads、written bytes 和 relocation bytes，不删除计量，也不改变拓扑事务/异常边界。
- 新增 `tests/cc_sampled_repair_test.cu` 与 CMake 入口；扩展 `tests/cc_dynamic_smoke.py` 的 full-scan 和 merged 配置。README 记录算法、对照开关及运行方式。

共享 metrics 改动也作用于 SSSP/BFS，因此进行了这两个程序的构建与回归。没有修改它们的传播、失效算法或 ownership 策略。

## 正确性与扫描量

1. 删除旧分量收集/reset 和 changed-source descriptor staging 保持原协议。
2. 每个 affected 顶点最多选择两条**删除完成后的现存邻接**做 union。changed row 在采样和完成扫描中都绕过旧 cache；unchanged row 可以读有效 cache 前缀，其余仍读 chunk。
3. 单独 kernel 将采样后的连通根冻结到现有 buffer 数组。取 256 个均匀分布的 affected 顶点，选取出现最多的采样分量作为跳过对象；选择质量仅影响速度。
4. 完成扫描跳过该分量的所有 source 行。采样同分量内部的边已冗余；跨分量边仍被 union。关键条件是：普通边用 `u < v` 去重，但目标在被跳过分量内的边必须允许另一方向执行，否则会漏掉割边。
5. 最终 flatten 恢复精确最小标签、buffer、reset 和 witness 状态。

证明依赖的只是现存边与无向对称性：采样不会合并无连通路径的顶点；所有采样分量之间的边仍至少从一个端点被处理，故完整分区与全边 union 相同。被冻结的 roots 在完成扫描期间不变，不能拿正在变化的 union parents 判定哪些 source 行应跳过。

新路径复用 value、buffer、affected queue 和原有两个 uint32 的 `work_size_d`，新增 device allocation 为零。不把旧标签、逐条删除前的替代路径或插入阶段的新边作为删除正确性的证据。仍然需要 O(V) 收集和 affected 顶点初始化，最坏情况下仍扫描 O(E)；这不是维护动态生成森林，也不是 SSSP 式小子树增量算法。显式 pull、CPU ownership、ordered repair 和 component trace 保留原路径。

## 同配置完整 P0 对照

指标为十批完整更新 P0 之和，包含维护、repair、插入、hotness 和 cache publication，排除初始化和独立 oracle。以下是单轮开发筛查，不是三轮中位数。各行使用相同输入、GPU/NUMA、20 workers、cache2、SEGMENT512 和 maintenance=auto；OK/TW 用 GPU0/NUMA0，FS 用 GPU2/NUMA1。OK/TW 为本次重新运行的 before binary 对照；FS before 来自已有同配置日志。

| 图 | 本轮修复前 ms | 采样 + 精简 metrics ms | 加速 | 降低 | repair 前 → 后 ms |
|---|---:|---:|---:|---:|---:|
| OK | 1552.280 | 956.441 | 1.62× | 38.38% | 216.875 → 45.904 |
| TW | 2400.663 | 1688.035 | 1.42× | 29.68% | 887.409 → 236.274 |
| FS | 27688.257 | 4948.038 | 5.60× | 82.13% | 25061.976 → 2815.200 |

OK/TW 用 hybrid2；FS 前后均用 hybrid0，没有通过本次缩 cache 或切换 hybrid 制造收益。之前原系统 FS hybrid2 与错误分区的问题仍按旧审计处理，不能把本表的 before 误称为原系统。

OK 消融（同 GPU0/NUMA0）：仅采样、auto 为 1439.771 ms；采样 + 精简 metrics、auto 为 956.441 ms。完整 CPU mutation 合计从 before 的 795.161 ms 降为 360.360 ms；其中 preflight 从 259.264 ms 降至 48.793 ms。多个嵌套 timer 不相加冒充总收益，最终以完整 P0 为准。

## OK 的现有维护开关

| 最终 binary 配置 | 十批 ms | 最终标签 oracle |
|---|---:|---|
| auto，source sort | 956.441 | 通过 |
| large，source sort | 860.712 | 通过 |
| large，source merge | 718.508 | 通过 |

第三行是已有的 `CG_BATCH_MAINTENANCE=large CG_MERGE_PUBLICATION_SOURCES=1`，不是新增算法开关。本次没有凭一个输入修改共享维护模式的默认阈值，也没有让 SSSP 默认切换开关。TW/FS 上表数字仍是 auto/source sort，不能假称三图使用了相同的这组额外配置。

用户给出的原系统 OK/TW/FS `0.8/5.8/10.2` 暂作为秒单位的目标线，原命令、输入更新量和计时口径尚未核实。本次测得 `0.718508/1.688035/4.948038` 秒均低于这些数值，但不能据此发布严格的原系统加速比。尤其当前输入每批 OK/FS 各 100000 add + 100000 delete **有向记录**，TW 为各 20000；双向记录不等于同数量的逻辑无向边。

## 验证与证据

- 三图最终独立 oracle：OK 3,072,442、TW 34,956,270、FS 65,608,363 个顶点，全部 errors=0，运行与 oracle 退出码均为 0。真实图检查是最终状态检查，不宣称所有真实图删除阶段均逐一检查。
- 最新 CC smoke：18 场景、326 个逐阶段 checksum 检查通过，覆盖 bridge/cycle、批量割集、平行边、missing delete、自环、空 phase、随机更新、cache 开关、稀疏/ordered/CPU 路径，以及新旧扫描和 merged publication。
- 独立 kernel 测试：101 个图逐顶点比较 CPU 连通分区，覆盖 partial cache、故意污染的 stale cache、多个分量；另有固定双稠密分量割边用例，确保检测错误的单向过滤。Compute Sanitizer memcheck：0 errors。
- 3 项 CTest 通过：source-local chunk store、publication source merge、sampled repair。
- 共享 SSSP GPU/CPU 两配置通过独立距离校验；BFS 18 个阶段及最终距离/parent 检查通过。

原始证据：`logs/cc_sampled_20260923/`。`summary.json` 汇总同配置对照；各目录 `result.json` 保存完整命令、环境、P0 分批时间与 oracle。`binaries.sha256` 冻结 before、sampling-only、sampling+compact 三个 binary。注意 `real/OK`、`real/TW` 是仅采样的中间版；`real/FS` 与 `compact_*` 是最终精简 metrics 版，不混为同一版本。最终 `build-bfs/hybrid_cc` 与冻结的 `hybrid_cc.compact` SHA256 一致。

## 复现

```sh
cmake --build build-bfs --target hybrid_cc cc_sampled_repair_test -j2
CUDA_VISIBLE_DEVICES=3 ctest --test-dir build-bfs \
  -R 'cc_sampled_repair_test|source_local_chunk_store_test|publication_sources_test' \
  --output-on-failure
python3 tests/cc_dynamic_smoke.py --binary build-bfs/hybrid_cc \
  --gpu 3 --output logs/NEW_CC_SMOKE
```

真实图同配置复现使用对应 `result.json` 的命令/环境。OK 的最终推荐组合示例：

```sh
CUDA_VISIBLE_DEVICES=0 CG_MUTATION_WORKERS=20 CG_REVERSE_SHARDS=64 \
CG_BATCH_MAINTENANCE=large CG_MERGE_PUBLICATION_SOURCES=1 \
CG_ORDERED_REPAIR=0 CG_CC_REPAIR=union \
numactl --cpunodebind=0 --membind=0 build-bfs/hybrid_cc \
  --format=market_big --weight_num=1 --weight=true \
  --SEGMENT=512 --n_stream=3 --hybrid=2 --cache=2 \
  --check=false --verbose=false --cc_input_symmetric=true --cc_max_batches=10 \
  --graphfile=logs/cc_real_20260923/input/OK.graph \
  --updatefile=logs/cc_real_20260923/input/OK.updates \
  --update_size=logs/cc_real_20260923/input/OK.sizes --output=NEW_OK.labels
logs/cc_real_20260923/prepare check \
  logs/cc_real_20260923/input/OK.oracle NEW_OK.labels
```

修复达到了当前三图的性能目标线和最终正确性要求。剩余边界是：采样收益依赖图结构，仍有全顶点工作量；真正的非树边删除免计算与局部分裂修复需要另外维护可靠的生成森林，不能用此次结果宣称已完成。
