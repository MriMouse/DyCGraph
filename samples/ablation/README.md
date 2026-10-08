# 三组件消融：准备完成后手动运行

本目录是独立的消融 sample/构建工具。**不修改生产 include、原 samples、9 月 27 日冻结源码、正在运行的 road/communication 实验。准备和编译都不会自动开始 GPU 实验。** 默认来源：`paper/evaluation/raw/sssp_bfs_20260927/current_src`（实验记录 HEAD `64dea19f87e68cbd9f11d57effcfce6391b2af93`），不是当前 HEAD；这样避免后续 BFS/CC/PR 改动混入消融。

## 三个开关

开关是**生成源码时的开关**，每个组合单独编译。`111` 的算法/框架文件与上述 frozen current 逐字节相同，仅程序 main 增加配置日志。生产系统没有增加运行时 if 或额外维护开销。仅支持 SSSP/BFS 两个 target。

| 位置 / 参数 | 1：保留 | 0：关闭 |
|---|---|---|
| D / `--storage` | source-local chunk 权威拓扑 | 使用仓库保留的老 `host::PMAGraph` 的逐边 insert/del、位移及 weighted rebalance；不维护第二份 chunk 邻接 |
| W / `--worklist` | compact affected、独立删后 repair、added-edge seed、exact source closure | 删除每轮扫描全部 V，重建待失效 worklist；插入全顶点启动，沿用现有 legacy 分段执行和每轮全 segment worklist rebuild。删后距离恢复合入插入侧的最终拓扑收敛 |
| V / `--view` | effective reverse 增量、稀疏 descriptor 发布、resident patch、cache refresh gate | 每批完整 `(V+1)` descriptor H2D；read_del/read_add 按原 `reset_pr_del_edges` 失效 touched cache；每批执行 eviction/compact/load；保留 W=1 时 reverse 改为每 phase 全图重建 |

主表使用已有的 `111` 完整系统作为基线，实际只运行三种消融：`011`（去存储优化）、`101`（去精细 worklist）、`110`（去增量视图维护）。另外准备了 `000/001/010/100`，共八种组合。主表不是依次累计关闭；如果展示累计结果请明确顺序。

有序删除/插入属于 W 执行组；本次沿用社交图实验 `CG_ORDERED_REPAIR=0`。不要把关闭 W 和另改 ordered 配置混成一个单因素结果。

## 耦合、适配成本与证据边界

1. **PMA 的重平衡会移动未被请求触及的 source。** D=0 在每次物理 phase 后完整比较 descriptor，把发生地址移动的 source 也加入发布；最大 sparse staging 按 V 预留。为保持其他开关独立，仍沿用 current 的 source 分组、先删除后插入和 effective occurrence 契约；这是替换存储后端，不是替换整个 origin 批处理入口。新增的适配扫描、effective occurrence 规划、descriptor/epoch 桥接都在 P0 中计时。初始 PMA 构建和 bridge 分配仍与原计时口径一样位于初始化。PMA 通过多个 mapped base alias 接入 GPU 的 slab/offset ABI，没有复制邻接到 chunks，也没有把“完整系统加上 PMA 工作”冒充消融。
2. PMA 使用 frozen current 中保留的原 PMA 实现，参考 `../C-GpuStreamGraph/include/groute/graphs/csr_graph.cuh` 的对应方法。保留其布局、密度阈值、逐边位移和 weighted positions。为保证可用性，隔离副本修复了删除后密度计数/逻辑边数、resize 无符号循环及固定 backing capacity 越界，并为“剩余窗口全部向右移动、找不到左移 anchor”的旧 rebalance 边界增加临时缓冲重分布。此边界已由 CPU 回归真实触发；普通重平衡仍走旧搬移逻辑。超过预留容量明确报错，不静默写越界。
3. **原系统没有本系统的 reverse repair index。** W=1/V=0 不能直接删除它，否则 W 的算法失去输入。因此采用全量重建，成本计入消融。这是“关闭增量维护、保留精细算法”的适配，不能声称原系统本来就每批重建 reverse。W=0 不构建/更新 reverse。
4. W=0 保留 current 的删除依赖正确性判定与 reset 值语义，改变工作发现粒度及恢复执行路径；不引回原版 100 轮截断。末尾精确结果检查继续保留。原版式最终态恢复不承诺删除中间态已收敛，因此仅 W=0 跳过“删除阶段 fixed point”检查；批末/final 检查不跳过。
5. V=0 仍需 epoch/同步和 source 列表来支持另外两个组件及审计；普通运行不再传 sparse patch、不执行 cache patch，也不做 refresh gate 判定。check 模式传递的 patch 仅服务 digest 检查，禁止把 correctness 模式拿去测性能。
6. `000` 是在 current 正确性与权重语义上的组件消融，**不是原仓库二进制复现**；9 月 27 日 original 仍是外部基线。原实验也没有 GPU 正确性验收，不能把历史计时完成当作正确性证据。

## 已准备的目录和命令

下面命令均在 `C-GpuStreamGraph-CG` 根目录执行。当前准备目录：`build/ablation_20261004_ready`。每种组合都有独立的 `src/`、`build/`、源码/二进制 SHA256、编译日志。默认 72 次计时计划在 `build/ablation_20261004_ready/plan/plan.json`，没有执行（3 个消融 × SSSP/BFS × TW/FS × 1k/10k/100k × 两轮）。

重新生成新的独立目录（拒绝覆盖已有目录）：

```bash
python3 samples/ablation/prepare.py --out build/ablation_new \
  --variants 111 011 101 110 001 010 100 000
# 或单个配置：三个参数要一起指定
python3 samples/ablation/prepare.py --out build/ablation_one \
  --storage 0 --worklist 1 --view 1
python3 samples/ablation/build.py build/ablation_new
```

编译脚本限定单核 CPU39（NUMA1）、nice19、`-j1`、`CUDA_VISIBLE_DEVICES=''`，显式指定 SM70，避免 CMake 自动探测 GPU。可用 `--cpu` 改编译核。只运行不使用 CUDA runtime 的 PMA CPU bridge 回归；不运行项目 ctest 全集。

**等现有实验全部结束，再执行以下 GPU 验证。不会后台等待空档自行开跑。**

```bash
python3 samples/ablation/experiment.py build/ablation_20261004_ready \
  --mode validate --variants 011 101 110 --datasets TW FS \
  --out build/ablation_validation_20261004
```

验证生成 64 点、五批更新的小图，覆盖重复/缺失删除、集中插入、删除-only、插入-only、空批、不可达分量连接与断开。每个组合、每个算法启用 `check=true`，逐批距离 checksum 必须与独立 Python Dijkstra oracle 一致；GPU/协议错误、检查失败、缺失 batch 都失败。它是小图正确性门槛，不代表所有大图已经验证。

验证通过后再跑主矩阵：

```bash
python3 samples/ablation/experiment.py build/ablation_20261004_ready \
  --mode run --variants 011 101 110 --datasets TW FS \
  --validation build/ablation_validation_20261004 \
  --out paper/evaluation/raw/ablation_20261004
```

默认三个消融配置 × SSSP/BFS × TW/FS × 1k/10k/100k × 两轮 = **72 次**。第二轮反转配置顺序，串行运行。`111` 作为已有基线用于柱状图归一化；如需 runner 自己生成基线，可显式加入 `--variants 111 011 101 110`。可用 `--datasets TW`、`--scales 1k` 先做小范围试跑。重复次数/超时分别用 `--repeats`/`--timeout`。默认 `--mode plan` 只输出计划，既不编译也不运行。

实验沿用 9 月 27 日 current 的 argv/env：GPU0、NUMA0、hybrid=0、cache=2、SEGMENT=512、3 streams、mutation workers=20、reverse shards=64、publication merge=1、regular、ordered=0、CPU propagation partition=0；SSSP 原合成权重，BFS 单位权。输入仍为原路径，不复制或重写大图。独立运行日志保存具体命令与环境，禁用 profiler/check/checksum，计时唯一指标为十批 `[P0-TIMER] total_batch` 之和。

## 输出与运行保护

- `source_manifest.json`、`binary_manifest.json` 固定源码和二进制，构建/运行前检查 SHA256；更改二进制后必须重新验证。
- `inputs.json` 保存路径、size、mtime，运行前复核输入未变化；不将它声称为全文件内容 hash。
- `runs.json/csv` 保存每轮完整批时间，`*.batches.json` 保留逐批值；`summary.csv` 为两轮均值、每批均值、相对 `111` 的时间比（大于 1 表示去掉组件后更慢）。
- GPU 正确性输出在独立 validation 目录，计时结果在独立 run 目录。禁止复用已有输出目录，失败/超时立即停止，不补零、不中途改源码补跑并混合均值。
- 启动前及每个子进程前检查正在运行的实验程序/父 runner 与 GPU compute 进程；发现占用直接拒绝。消融 runner 之间另有文件锁。外部 runner 不共用该锁，因此仍需等原实验整体结束，不应与其他 GPU 作业同时启动。
- 没有自动后台启动、没有 kill 外部进程、没有修改 GPU 设置。超时清理只针对本 runner 创建的子进程组。

轻量检查：`python3 samples/ablation/test_preparation.py`。构建状态：`cat build/ablation_20261004_ready/build_status.log`。本次准备的实际验收记录见 `STATUS.md`。

## 2026-10-05：V 定义修订

新版 V=0 保留 W 所需的 reverse 增量维护，仅关闭稀疏 descriptor 发布、resident patch 和 refresh gate；采用 origin 的 touched-source 失效及每批 eviction/compact/LoadCache。原版保留有效缓存块，不是每批清空全部缓存。旧 reverse 全量重建版 110 只作历史对照，不能混入新版结果。新版独立构建于 `build/ablation_20261005_view_v2`。剩余配置只运行一次；单次汇总取 repeat=1，历史重复记录保留但不参与均值。
