# CPU/GPU 调度优化：三步实施计划

日期：2026-09-26。依据当前代码静态审查；不把可消除的调用次数等同于实测加速。

## 2026-09-27 回退记录

- 用户反馈第一步 `OPT=1` 实验明显降低性能，因此已局部撤销第一步源码、`OPT` 开关及专用测试注册，恢复实验前的 hotness、候选计数和同步路径。
- 保留 PR 收敛相关修改及其他工作区内容；未修改现有构建产物、实验日志或正在运行的二进制。后续需要重新构建才能让可执行文件使用恢复后的源码。
- 下文为原实施计划与历史记录，第一步现已撤销，第二、三步未实施。此次仅做静态还原核对，未运行性能实验。

## 实验隔离与状态（历史记录）

- 用户正在运行 `logs/paper_data_single_20260926/status.json` 对应的 32 项实验。检查时为 running，19/32，PR / OK / 100k / original。
- runner 是 `scripts/run_paper_data_single_20260926.py`，只执行已有二进制，不执行构建、源码解释或自动重载。current 分别来自 `build/hybrid_sssp`、`build-bfs/hybrid_pr`，original 来自实验目录下 `original_src/build/`。
- 本轮仅修改源码、增加测试源文件和本文档；不构建、不执行 GPU 测试、不启动性能任务、不修改实验二进制、脚本、输入、环境、日志或状态。编译也延后，避免与实验争用 CPU/内存带宽。
- 三步计划统一通过环境变量 `OPT=1` 启用，未设置或 `OPT=0` 保持原控制路径；其他值报错。不保留旧开关别名。后续第二、三步也必须复用 `include/framework/optimization_config.h::optimization::Enabled()`，不增加独立步骤开关；`OPT=1` 启用届时已实施的全部步骤。
- 正在运行的旧二进制不受新源码影响，隔离保证是其二进制未被替换。runner 仅清除继承的 `CG_*` 环境，不会清除 `OPT`；未来使用新二进制做对照时，必须显式指定 `OPT=0/1` 并记录，不能依赖 runner 自动清除。本轮不修改正在运行的 runner 或环境。
- 第一步源码已实施，尚未编译、尚未进行 GPU 正确性或性能验证；不能称为验收通过。第二、三步均未实施。实验结束后使用单独构建目录验证，不覆盖本轮基准二进制。

## 第一步：合并 hotness 与候选选择的控制链

**分组理由：**这些操作共用 score/ID、degree、prefix 与 cache gate；把 CPU 二分移到设备之前，必须同时明确 CUB 与相邻 kernel 的 stream 顺序。融合 degree 提取和 hotness 滚动减少一次扫描/启动，其收益可能被排序占比、额外单线程查找 kernel 和短任务开销抵消，应作为一条完整控制链评价。

实施内容：

1. 为 `GraphDatum::sort_vtx_by_hotness`、`ensure_candidate_vertex` 增加可选 stream 参数，保留旧调用的默认 stream。候选路径将 hotness 计算、CUB 排序、degree 提取/窗口滚动放在主 stream；候选 scan、设备查找和结果回读也使用该 stream。
2. 将 `extract_vtx_degree` 和 `reset_hotness` 融成 `ExtractDegreesAndRotate`：degree 按排序后的 ID 获取，hotness 按原 vertex ID 滚动。score/ID 配对、稳定排序及审计在窗口滚动前观察旧状态的语义不变。
3. 将 `CacheCandidateCount` 的 CPU 二分和多次标量 D2H 改成一次 GPU 二分、一次最终计数回读。严格保留旧 `< capacity` 边界，包括恰好填满、零度顶点及尾部零度，不借优化修改准入规则。
4. 候选路径删除 hotness 中间和 gate 处不再需要的全设备同步，保留 hotness 阶段结束、CPU 读取 admitted、CPU 读取 gate 标志及候选标记发布前的必要 stream 完成边界。保留原 gate、eviction、compaction、load 决策。
5. 候选日志报告完成后的 `hotness_pipeline_ms`，不把异步提交耗时标为 kernel 执行耗时。旧路径保留原日志；不变更 P0 整批计时边界。

代码：`include/framework/cache_control.cuh`、`graph_datum.cuh`、`framework.cuh`。新增常驻 device scalar 4 字节，随 GraphDatum 分配/释放，无每批分配。旧 trace 的独立诊断回读保持原样，不进入本次性能优化。

验证源：`tests/cache_control_test.cu`，注册为 `cache_control_test`。覆盖空集合、禁用容量、单点、零度/重复 prefix、严格边界、64 位尾和比较、随机前缀；非阻塞 stream 上 CUB 排序→融合扫描→前缀和→设备查找，并比较多轮 score/ID、degree、hotness 窗口和独立 CPU oracle。

待实验结束后的验收：

- 独立构建 SSSP/BFS/CC/PR 和新测试；新测试、已有 cache gate/patch/tail 测试以及相关四应用 smoke。
- 比较 `OPT=0/1` 的 audit、candidate 数、refresh 决策、最终状态；容量边界及非默认 stream 检查必须通过。
- 同条件短交错配对，记录 hotness/candidate 和完整 P0，覆盖 refresh 与 no-refresh、短批次与 cache 维护占比较高的场景。没有方向稳定的完整收益，不转为默认。
- 若回退，先区分二分控制收益与融合访存影响，再做有针对性的消融；不靠扩大分段数或只报局部 timer 宣称收益。

## 第二步：合并 cache 分段提交、压缩与拓扑发布

**分组理由：**分段 rebuild 内部同步、逐队列 GetCount、全 stream 等待、共享 cache tail 和后续 copy/index 发布是一条依赖链。单独删除等待容易破坏共享状态；只删一层同步又可能被下一层小回读抵消。并发增加还可能加剧 tail 原子竞争和 zero-copy 带宽竞争，必须一起审查。

计划内容：

1. 将 `RebuildArrayWorklist_identify`、`RebuildWorklist_delta` 的逐 segment 主机等待移到消费者边界；限定 cache 调用点，避免改变其他历史路径的同步契约。
2. 将 `RunSyncCom`、`RunSyncPushDDBAmend_cache` 的逐 segment `GetCount` 改为批量计数回读或 kernel 设备计数输入；结合第 1 项避免“多 stream 外观、主机串行提交”。评估小 segment 合并，保留空段语义与队列容量检查。
3. 把 `HostRiverElement` 的 D2H→两次 H2D 标量更新改为设备操作；核实 host mirror 的所有消费者后再决定是否保留一次汇总回读。
4. 梳理 `copy_cache`、`copy_index`、load 的真实生产者/消费者；同 stream 连续提交，跨 stream 使用 event，不做机械删除 `cudaDeviceSynchronize`。若收益来自减少完整 cache 搬运，再独立审查缓冲区交换，不混入第一版。
5. 尝试将 descriptor scatter 并入 per-source cache patch，合并 publication 状态回读。保留 GPU reader 完成后才能 CPU mutation/reclaim、publication 后才能读取新版本的契约。
6. 按生命周期复用 ordered repair 工作区，避免每次 Run 的 malloc/free；不缓存会跨 batch 失效的拓扑内容，不用无限增长的高水位内存换取局部时间。

位置：`algo_variants.cuh` 的 cache rebuild/driver；`framework.cuh::compact_cache/LoadCache`；`csr_graph.cuh::HostRiverElement/PublishSparse/CompleteSparsePublication`；`ordered_gpu_repair.cuh::Device/Run`。

验收重点：多 stream 和 32/512 分段、空段、满 cache、增长/失效/退化、refresh/no-refresh、跨批 descriptor 可见性、显存峰值与整个 cache 阶段/P0。对 cache tail 分配顺序变化，检查语义与容量，不能要求物理偏移完全一致，也不能把偏移变化造成的后续工作差异藏掉。

## 第三步：传播闭包设备化与全局屏障/负载适配

**分组理由：**设备端循环、kernel 融合、全局屏障和驻留 block 数强相关。消除主机往返可能增加 GPU barrier 成本、驻留约束和长行拖尾，必须连同调度粒度与实际边扫描工作量评价；不把不同算法的退出条件混用。

计划内容（按独立正确性边界依次推进，不一次改完全部算法）：

1. SSSP/BFS invalidation：将 frontier begin/end、计数和退出留在 GPU；保留 affected 去重、容量和父依赖语义。它与后续 repair 是两个闭包，不跨越 CPU 物理删除边界融合。
2. 默认 pull repair：设备端清零→松弛→全局完成→终止判断，保留轮数上限及错误回传。ordered repair：设备化 Reset→Find→Partition→Expand 与 queue-empty/overflow 判断；选桶和分区所需的全局可见性仍保留。
3. PR：设备化 Consume→Scatter→count 循环；所有 Consume 完成后才能 Scatter，防止覆盖新残差和破坏 queued 标记，保留非有限值及迭代上限检查。
4. 已有 cooperative insertion：审查相邻冗余 `grid.sync` 和队列交换协议，减少可证明冗余的屏障；再考虑 source 度数适配、统计原子聚合。已有 thread/source 回退证据意味着不能用线程利用率代替完整收益。
5. CC sampled union 当前已经同 stream 连续提交，不是主机逐轮闭包；Sample→Snapshot→Select→Hook→Flatten 的全局依赖优先保留，仅在有证据时考虑受控融合。

验收重点：跨 block 可见性、无任务/窄/宽 frontier、长链/循环/高出度、队列满载、cooperative launch 容量、parent/tight witness、PR signed residual；分别统计 host 控制次数、GPU barrier/波数、真实扫描边数及完整 batch。kernel/CPU API 时间可能重叠，不相加估算收益。

## 本轮检查记录

- 已核对 runner 的可执行文件路径和无构建行为，源码修改前工作区干净。
- `git diff --check` 和新增文件空白检查通过；已按本机 CUDA 12.1 的 CUB 头文件核对显式 stream 参数顺序。仅为静态检查，不证明可编译或运行正确。
- 本轮仅允许轻量静态检查；编译、CTest、sanitizer、GPU oracle 和性能配对均待现有实验结束。不得把“测试源已添加”写成“测试通过”。
- 步骤之间以上一步正确性验收为前提；第二、三步保持计划状态，不在本轮顺带实施。
