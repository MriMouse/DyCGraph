# PR 算子迁移与高性能路径保留（2026-09-24）

## 范围与语义

将用户放在 `samples/hybrid_pr` 的 SSSP 副本改造成 PR，恢复 CMake 原本指向的
`hybrid_pr.cu` / `hybrid_pr_host.cu` / `hybrid_pr_common.h`，修正 main 的算法入口。
用户保存的 `samples/old_hybrid_pr` 保持原样；`samples/hybrid_sssp` 不改算法。

当前实施计划的生产架构是 **CPU source-local topology mutation + GPU
state/propagation/cache**，本次沿用这一分工。历史 CPU propagation owner 已在
SSSP 主线退休；其代码和研究记录继续保留，但不能把 SSSP 的最小值边界消息
直接用在可正可负的 PR 残差上。

PR 与旧样例一致：

```
x = 0.15 * 1 + 0.85 * P^T * x
```

`P[u,v]` 是按出度归一化的边重数；不使用输入权重。零出度行全为零，不做
悬挂质量重分配，不将结果归一化为概率。初始 rank=0、residual=0.15。
每批先删除再插入，在 final topology 上收敛；与旧 PR 一样不输出独立的
删除中间 fixed point。不能用 SSSP 两次 fixed point 的时间直接作 PR 对照。

## 增量算子与正确性

始终保留 `r = 0.15 + 0.85 P^T x - x`，忽略浮点舍入时：

1. 对分组更新的 touched source，在旧图和旧 cache 上散播
   `-0.85*x[u]/old_degree[u]`。仅扫描 touched row，不扫描全图。
2. 同步旧行读取，再复用 delete/add grouped mutation、source publication
   merge/sort、epoch 校验、cache patch/invalidation。
3. 同一 CUDA stream 在 descriptor/cache 发布后散播
   `+0.85*x[u]/new_degree[u]`，形成 `r_new = r_old + 0.85*(P_new^T-P_old^T)*x`。
   旧、新 degree 为零时对应散播为空。未修改 source 的贡献自然抵消，无需访问。
4. `abs(r[v]) > error` 才活跃；consume 将该残差加进 rank 并清零，scatter
   沿当前邻接传播 `0.85*r[v]/degree[v]`。低于阈值的残差留在原处，不能丢弃。

出度变化影响**全部 surviving edges**，不能只对新增/删除边应用旧系数。
缺失删除等无效请求可能保守地撤销/补偿该 source，但不会改变逻辑拓扑。
重复边按 occurrence 计数。删后重加可产生冗余 frontier，但没有 rank reset。

新增 `include/framework/pr_residual.cuh`：两个去重 frontier、queued 标记和
按 frontier 位置存储的 delta，使用独立 consume/scatter kernel 边界。
标记仅在 consume 阶段清零，scatter 阶段仅追加；每个 next frontier 至多 V
个顶点。只在残差从阈值内跨到阈值外时尝试 CAS 入队，减少高入度目的点的
标记争用。消去正负残差后可能留下多余队列项，consume 会重查条件。

frontier 空才成功；`pr_max_rounds` 耗尽、非有限值、publication 协议错误均失败。
旧 PR 的固定 100 轮、仅负残差增量条件和零出度除法均不再使用。

## 机制保留与边界

| 机制 | PR 接入 |
|---|---|
| source-local pinned chunk / worker pool | 原路径复用，无整图拓扑重建 |
| regular/large/auto 分组维护 | `PrepareGroupedUpdates` + `ApplyEffectivePhase` 原路径 |
| publication 合并、epoch、cache patch | 原路径，旧读完成后 mutation，新读排在发布后 |
| CTA/warp degree 调度 | 复用 `CTAWorkSchedulerNew`，cache / chunk 双邻接路径 |
| exact source frontier 思路 | 改为加法与双向阈值的事件队列；每轮不做 O(V) rebuild/sort |
| hotness ID/score 配对、窗口、cache gate | 复用生产评分/排序和 refresh gate；PR 取消 infinity mask |
| cache eviction / compaction / load | 原路径复用，入口显式设置 coarse 调度保证实际填充 |
| 通信记录、整组窗口、完整 P0 | PR target 加入 memcpy wrappers；队列控制传输归 Control |
| SSSP parent / reverse repair / ordered distance | 不适用于 PR，不调用；SSSP/BFS/CC 原有实现保留 |

新增常驻 runtime 空间约 `16*V + 4*S_max + 8` 字节，另有 CPU touched-source
列表；叠加在共享 engine 现有数组之上。每批修正工作与 touched source 的旧、新
出边量相关；最坏可能覆盖全图。每轮 kernel 数为两次，另有计数清零和小量
D2H 终止检测；hotness/candidate 等共享 cache 服务仍可能扫描 V。
**没有宣称整批已经完全 O(affected)。**

PR 当前固定 GPU residual propagation + CPU topology maintenance。
显式 SSSP CPU partition/domain 参数报不兼容；距离区间 ordered repair 和
SSSP insertion schedule 不选择 PR kernel。`--sparse` 接受但 PR 始终用稀疏
frontier；`--hybrid` 不切换其 residual executor。详细参数见
[PR README](../../samples/hybrid_pr/README.md)。

## 验证与接入修正

GPU 2，2 mutation workers，小图测试使用 32 segments / 3 streams / hybrid=0。
构建使用已有 `build-bfs`、CUDA 12.1。没有修改 frozen baseline binary。

- `tests/pr_dynamic_smoke.py` 最终 12 个场景通过：cached / uncached /
  large+merged+通信计量 / unchecked 四组十批；整流为空、纯插、纯删；静态；
  迭代上限、负阈值、不兼容 owner、输出失败四项返回码契约。
- 4096 顶点 fixture 包含正负传播、环、自环、孤立点、零出度转换、平行边、
  缺失删除、删后重加和 degree=1779 的 hub，触发 CTA 高出度路径。
- 正常运行共 47 次内置阶段/最终检查通过（不计故意输出失败的检查）。
  CPU double Jacobi 全量重算、rank L1、residual invariant 与 residual 上限检查；
  Python 独立 replay 更新并重算八个正常场景的最终输出。四个十批配置最终
  mean absolute rank error 均约 `6.413e-6`；它不是 per-vertex 最大误差。
- CUDA memcheck：十批 cached 动态运行，`ERROR SUMMARY: 0 errors`。
- 最终共享源码重新构建 SSSP/BFS/CC；各三批、共 18 个中间阶段检查通过，
  256 顶点的最终输出逐点匹配独立 Dijkstra / BFS / 连通分量参考。
  结果见 `shared_result.json`，未改变这些应用的算法或默认策略。

日志目录：`logs/pr_migration_20260924/`。最终 PR 结果：
`final_smoke/result.json`；内存检查：`memcheck.log`；共享回归程序和结果也在此目录。

接入中实际暴露并修正的问题保留在 `smoke*` 失败日志中：

1. 旧 `GetNodeNum()` 读取未绑定的 host CSR，返回 0；PR 改用当前 GraphDatum 节点数。
2. 新入口未执行旧 `Start()` 的 option 初始化，默认 NONE 使 cache load 只写
   元数据；显式设定 coarse，保留原 cache 装填路径，cached/uncached 通过。
3. 静态图入口原仅为 CC 开放；按 `kSignedResidual` 策略放开 PR，不改变其它算法。
4. Skeleton 丢弃应用布尔失败；PR main 仿照现有 CC 保存失败状态并返回非零。

## 性能结论范围

本次完成算法和高性能基础设施接线、正确性与内存检查；未做真实大图与旧 PR
的同资源性能对照。因此不宣称已量化加速、无性能回退或大图容量验证完成。
测试时间包含合成小图运行环境，不作为发表性能结果。后续对照必须固定 PR
变体、error、batch 语义、NUMA/GPU/cache 配置，以完整 update+propagation+cache
服务时间比较，并关闭 oracle/计量诊断再计时。
