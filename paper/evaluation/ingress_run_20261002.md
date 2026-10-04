# Ingress 10-batch 正式对比实验

2026-10-02，在用户授权下适配并启动。此处是 **Ingress 原生引擎的流式/语义适配版**，不是未经修改的上游二进制。原始 current/origin raw 未修改。

## 运行范围与入口

- BFS、SSSP、CC、PR × OK、WK、TW、FS × 1k、10k、100k，48格，每格2次，96次串行运行。
- 输入 `data/paper_data`，逐格原始命令、源点、CPU配置记录于 `raw/ingress_20261002/plan.json`。
- 启动：`bash scripts/start_ingress_paper_matrix.sh`。Python使用新session启动，脱离SSH，runner自身持有排他文件锁，支持只跳过命令签名相同且已成功的结果。
- 后台状态：`raw/ingress_20261002/status.json`；PID：`runner.pid`；队列日志：`runner.log`。
- 原始结果：同目录 `<algorithm>_<dataset>_<scale>_ingress_r<repeat>.log/.command.json/.result.json`；汇总 `runs.csv` 和 `averages.csv`。汇总保存毫秒及秒，不把缺失项填成0。
- 2026-10-02 16:34 UTC首次正式启动PID为2015104。状态文件是后续进度的权威来源。

## 计时窗口

1. 格式转换、初始图加载/序列化或反序列化、初始算法求解、更新文本读取：均不计入结果。
2. 每批开始计时：更新分组、依赖重置或PR旧贡献回收、实际拓扑重建、状态重放/PR新贡献、计算至收敛或PR轮数上限。
3. 每批结束打印 `[PAPER-BATCH]`；结果是严格10个batch标记的 `paper_algorithm_ms` 之和。各批另记录 `reset_ms`、`topology_ms`、`compute_ms`，脚本验证三项之和等于总时间。
4. 检查输出、日志与全图结果文件输出在计时外；正式运行关闭全图结果输出。旧 `run algorithm`、`Inc time` 不作为本次paper指标。

Ingress 使用 immutable fragment。适配器从当前内存邻接提取边，按次数删除，再插入，调用原生 `ImmutableEdgecutFragment::Init` 重建；整个过程位于每批计时内。保留原顶点映射，保留重边、自环，不添加反向边。不提前生成十份更新后的图快照，不把重建成本排除。此过程仍为O(E)每批，结果中须如实描述。

## PR和其他算法语义

- PR：`alpha=.85`，非归一化 `base=.15`，悬挂点不发送；按每顶点有符号残差绝对值 `>1e-6` 决定活动。保留小于阈值的残差；每轮先固定本轮残差，再传播。初始与每批最多100轮，允许提前收敛，日志区分 `converged` 和 `iteration_limit`，后者不能当作收敛证明。
- 继续使用Ingress原生 `AmendValue(-1/+1)` 进行全图旧贡献回收和新贡献重放；每批保留rank和未应用的残差。
- 原kernel的 `1/out_degree` 整数除法已改为浮点。paper模式使用明确的damping参数和悬挂点语义。
- BFS/SSSP继续使用原生遍历worker；源点分别为OK=377664、WK=134151、TW=28512093、FS=0。
- **SSSP实际传播权重为 `(src+dst)%128+1`**，由现有raw快照的 `TraversalEdgeWeight/DeletionEdgeWeight` 确认。早期审计中的“SSSP单位权”陈述已纠正。BFS单位权；CC沿有向边传播最小标签；PR忽略权重。
- 新初始图转换保留每条边出现次数，顶点文件列出0..max_ID。文本权重预存SSSP规则；BFS在paper模式下按单位权解释。
- 小图验证揭示的父依赖自环问题已修复：先保存本轮采用的父依赖，再传播，防止自环覆盖父记录；跨batch保留依赖数组，受影响顶点重置其依赖。

## CPU资源公平性

机器：2 × Intel Xeon Gold 5218R，每插槽20物理核、40逻辑CPU。

- 从每格current原始command.json读取 `--cpunodebind`，Ingress沿用同一NUMA节点。当前矩阵为node0：CPU `0-19,40-59`，不使用node1执行算法线程。
- `app_concurrency=20`，与原始 `CG_MUTATION_WORKERS=20` 对齐；只运行一个进程中的MPI rank，不启动多机或多个MPI rank。worker读取流时也会检查 `worker_num()==1`。
- `OMP_NUM_THREADS=20`；BLAS线程限制为1。主线程/MPI管理线程不等于额外计算rank；允许的CPU集合仍在一个插槽内。
- 不强加 `--membind`：已有基线仅指定CPU节点，未硬限制内存节点，因此保留相同政策。若内存跨NUMA分配不应宣称严格单节点内存。
- Release、O3、原生自动引擎选择和分段分区保留；使用原生std::thread并行路径。Cilk未编译，不设置 `cilk=true`。仅链接OpenMP不代表Cilk或所有嵌套循环自动并行。
- 数据转换是计时外的单线程准备步骤；正式应用受NUMA约束。各次运行串行，准备和计时不会彼此并行干扰。
- 本系统同时使用GPU，因此只能称单插槽CPU资源约束相同，不能称CPU与GPU硬件资源完全相同。历史基线没有独占物理核心的保证，本次也不能消除其他用户/系统服务的干扰。

## 序列化与空间

新文件全部位于 `Ingress/paper_data_matrix/v2`，保存转换后的初始边文件、顶点文件和初始fragment缓存。仅初始图缓存，**不保存十份逐批全图快照**。

缓存命名空间包括初始文件全量SHA256、转换器SHA256、实验二进制SHA256、顶点数量、fragment类型（uint16/EmptyType）、有向性、分区方式及rank数量。不同更新序列可以共享相同初始图缓存，因为本次不缓存任何更新后的状态；更新文件和batch文件另外记录哈希，并进入运行签名。转换前后检查原始文件大小/mtime是否变化。

中断的首次缓存不会直接复用；未产生完成标记的目录重命名为 `.incomplete.*` 保留待排查。不自动清理其他目录。转换前检查可用空间；不足则明确失败。

## 验证与可复现性

- 独立编译目录：`Ingress/build_paper`，旧build/build_release二进制未覆盖。
- `tests/ingress_paper_stream_test.py`：3组图（含重边、自环、孤立点、有向环、混合增删），4算法，1/20线程，共24次运行，初始+10批，共264状态独立验证。BFS/SSSP用Dijkstra参考，CC独立标签传播，PR双精度参考及残差不变量。
- `tests/ingress_paper_contract_test.py`：输入转换计数/权重/顶点集合，初始缓存复用，NUMA0/1命令，PR上限1轮后跨批残差不变量及100轮收敛，共33状态。两份验证结果均绑定实际二进制哈希，契约验证另绑定转换器哈希。
- 实验runner只接受通过这些验证的binary/converter。完整图正式性能运行不导出全图做独立对拍，因此不将其标成“全规模正确性已验证”。
- `raw/ingress_20261002/source_before` 保存此次修改前涉及的Ingress文件；`source_after`保存已验证的适配源码和脚本快照；`fairness_audit.json`及每次command.json记录配置/二进制身份。
