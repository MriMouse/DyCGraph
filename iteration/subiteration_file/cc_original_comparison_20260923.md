# CC 与原系统性能对比（2026-09-23）

本次为两组合成图的小规模性能筛查，不是 Wiki/Friendster 等真实大图性能结论。
原系统路径实际为 `../C-GpuStreamGraph`（Linux 路径区分大小写），commit
`7ffcb2949837ad9f05d5d77afe54c698e2887479`。

## 结果

指标为 **十批完整更新耗时之和，三轮中位数**。包含删除、插入、hotness、候选、
缓存逐出/整理/加载及同步；不包含初始化、正确性检查、最终导出。

| 输入 | 顶点 / 有向邻接记录 | 每批插入 / 删除记录 | 原系统 ms | 本系统 ms | 结论 |
|---|---:|---:|---:|---:|---|
| 64 个独立分量，每分量 256 点 | 16,384 / 262,144 | 1,000 / 1,000 | 88.846 | 12.114 | 本系统快 7.33×，耗时降低 86.37% |
| 单一连通分量 | 65,536 / 1,048,576 | 5,000 / 5,000 | 94.815 | 199.710 | 本系统慢 2.11×，耗时增加 110.63% |

三轮完整批耗时：

- 多分量：原系统 `88.815, 88.913, 88.846` ms；本系统 `12.114, 12.310, 11.958` ms。
- 单分量：原系统 `94.815, 94.865, 94.705` ms；本系统 `200.361, 181.896, 199.710` ms。

双方同名 `Iterate all time` 日志的初始计算中位数：多分量原版/本版为
`0.934/0.919 ms`，单分量为 `101.811/82.059 ms`。这不是包括解析、分配和
CUDA 启动在内的冷启动时间；进程 wall time 另存 JSON，含最终导出，不用于批处理结论。
原版额外 `CC-BENCH-INITIAL` timer 未 stop，因此该字段为零且未用于报告。

## 原因

| 本系统阶段（各阶段分别取三轮中位数） | 多分量 ms | 单分量 ms |
|---|---:|---:|
| 删除 | 7.252 | 182.032 |
| 插入 | 3.401 | 15.207 |
| hotness | 0.950 | 1.334 |
| candidate | 0.434 | 0.636 |
| eviction / compact / cache load | 0 | 0 |

多分量每批 affected 为 512 点，单分量每批 affected 为 65,536 点。
单分量的删除耗时约占完整批耗时 91.15%。当前“重置被删除边触及的旧分量”策略
即使删除非桥边也会修复整个旧分量，而原系统基于父见证的失效范围通常较小。
本次两图都保留基础连通骨架，删除不会导致分裂；不能据此证明原系统在桥删除、
分量分裂或长链上的普遍正确性。也不能用不同算法的受影响范围冒充同工作量对比。

两种输入本系统均命中缓存 refresh gate，避免原系统每批全量 cache compact 的开销。
因此小 affected 时有明显收益，巨型 affected 时则被删除修复成本抵消。
结论：不能宣称当前 CC 整体保持原系统性能；删除范围是下一项优化目标。
本次没有修改算法来追逐测试结果。

## 公平性与正确性

- GPU2，V100-SXM2 16GB，NUMA1，固定 CPU24/25；两系统均 cache=2、SEGMENT=1、
  n_stream=3、hybrid=0，CUDA12.1 Release/sm70。
- SEGMENT=1 为小图双方共同有效配置；原版在先行稀疏 256 点 fixture 的 SEGMENT=32
  初始化出现非法访存，未把崩溃时间纳入结果。
- 输入完整双向、无重复 occurrence；两系统读取完全相同的三个文件，SHA256 已保存。
  本版 `cc_input_symmetric=true`，避免只让一方承担输入规范化。
- 更新在两套互斥 shortcut 集合间交替：删除存在边、插入不存在边，无缺失删除；
  十批且每批非空。原版固定十批，所以没有使用 16 批回归输入。
- 本版 mutation workers=2，常规维护、block 插入、ordered repair 关闭；计量/trace 关闭。
  原系统保持原有 CPU 算法；双方仅共享相同 CPU affinity 约束。
- 各系统先独立 correctness run，再进行 AB / BA / AB 三轮性能运行。
- 独立 Python flood-fill 校验两图的每批最终 labels；原版导出十批结果供逐顶点对比，
  本版每批 deletion/addition 共 20 个阶段内部 oracle 均通过。所有计时运行的最终
  每个顶点输出也通过外部 oracle。全部退出码 0，无迭代上限命中。
- 输入只有两个合成图，且大于等于 1M 更新、真实大图和正式 OOM 数据集未测试。

## 原版适配范围与复现

原仓库没有被修改。`scripts/prepare_cc_baseline.py` 将 include/src/samples 复制到隔离
目录，共享只读 deps，加入同步完整批 timer 和计时外 labels 导出，并修复 main.cu 中
`Single()` 不返回 bool 的未定义行为；传播、更新、缓存、收敛条件均保持原版。
原版历史 Loader 的 reserve 后下标写等问题没有修补，不把原版改成新算法。

运行目录：`logs/cc_compare_20260923/`。

- `manifest.json`：版本、资源、二进制 SHA256 与计时口径。
- `summary.json`：逐次结果、阶段统计、affected 数与初始计算时间。
- `runs/result.json`：原始计时与正确性结果。
- `runs/{components,connected}/`：输入、每次日志、标签输出与完整命令 JSON。
- `baseline/manifest.json`、`configure.log`、`build.log`：原版插桩与构建记录。

```sh
python3 scripts/prepare_cc_baseline.py --source ../C-GpuStreamGraph --output NEW_BASELINE
cmake -S NEW_BASELINE -B NEW_BUILD -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER=/home/wangshaoyan/bin/g++ \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.1/bin/nvcc \
  -DCUDA_HOST_COMPILER=/home/wangshaoyan/bin/gcc \
  -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.1
cmake --build NEW_BUILD --target hybrid_cc -j2
python3 scripts/compare_cc.py --output NEW_RESULTS --ours build-bfs/hybrid_cc \
  --original NEW_BUILD/hybrid_cc --gpu 2
```
