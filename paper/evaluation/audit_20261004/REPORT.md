# 2026-10-04 实验审查：现有加速比能否支持论文结论

结论：**暂不建议将这张表当作已验证的论文性能结论。算术复算正确，但 original 基线存在 C++ 数组越界，CC 的算法/图语义偏离通常的连通分量，全部正式性能运行缺少结果正确性验证，PR 存在未收敛样本。** 没有证据说明 30× 一定是伪造或计时漏算；同样，没有足够证据说明这些倍率已能在等价、正确的任务上成立。

本次仅新增 `paper/evaluation/audit_20261004/` 文件。没有修改原始 CSV、日志、实验脚本、冻结源码或实验二进制。审查对象实际位于 `C-GpuStreamGraph-CG`，而会话 cwd 是旁边的 `graphbolt`。

## 1. P0：original 在正式配置下确定存在数组越界

三个 original 冻结源码树均有同一个问题：

- `../raw/sssp_bfs_20260927/original_src/include/framework/graph_datum.cuh:43`；
- `../raw/sssp_bfs_20260927/original_bfs_src/include/framework/graph_datum.cuh:43`；
- `../raw/cc_pr_20260928/original_src/include/framework/graph_datum.cuh:43`。

数组声明 `m_wl_array_in_seg[512]`，合法下标为 0…511；构造函数在 204、205 行对 `m_wl_array_in_seg[segment]`、`m_wl_array_in_seg[segment+1]` 赋值。所有正式命令使用 `--SEGMENT=512`，因此两个赋值写入下标 512、513。

越界数组后面恰好是另两个 Queue 成员，这可能解释了为什么运行没有立即崩溃，但跨数组边界访问在 C++ 中仍是未定义行为。current 的对应冻结版本已经使用 `kMaxSegments + kCombinedWorklists`，即 514 项。

**证据边界：**这是源码级确定缺陷；没有通过 sanitizer 在全规模历史二进制上量化其影响，不能声称它已经造成了某个倍率或结果错误。但是“正常退出”不能证明这个基线可靠。四种算法共 96 次 original 正式运行都使用触发该缺陷的参数。

处理建议：在新的基线副本中只修复容量/边界问题，保存补丁与二进制哈希，先验证结果，再在独立目录重跑。不能直接改历史 artifact 后继续引用原数字；也不能把由这种基础修复产生的差异归为新系统算法贡献。

## 2. P0：CC 的任务名称与通常的 CC 不一致，OK 是退化案例

manifest 与 current CC 日志明确采用 `directed_min_label`。计算的是“能够沿有向路径到达 v 的最小顶点 ID”，不是一般无向连通分量，也不是强连通分量。

OK 原始文件头是 `MatrixMarket ... symmetric`；生成器 `scripts/prepare_paper_data.py` 和 `scripts/paper_data_stream.cpp` 将存储记录原样输出，没有补反向边。独立全扫描 `OK/input_1k.txt` 得到：

| 独立扫描指标 | 结果 |
|---|---:|
| 初始边记录数 | 117,180,083 |
| src > dst | 117,180,083 |
| src < dst / 自环 | 0 / 0 |
| 出现在边中的顶点 | 3,072,437 |
| 将边视为无向后的连通分量 | 1 |

证据为 `ok_full_scan.json`；扫描实现为 `scan_ok.cpp`。三个规模的 OK 更新流也全部满足 src > dst，见 `update_scan.json`。

从此方向性可严格推出：任何到达 v 的非空路径都从较大 ID 开始；又允许 v 自身作为种子，所以 directed_min_label(v)=v。删边或加回这些边不会改变该结论。正式 OK/1k 两次 current 运行的删除受影响顶点累计数为 0，插入 closure 处理边数为 0，缓存刷新次数为 0。

**34.2995× 测到的是这个特殊方向图上的更新/维护开销优势，不能据此宣称一般 CC 计算快 34×。** 两个系统使用同样的单向输入，只说明二者的输入一致，不会恢复数据集原本的无向语义。SSSP/BFS/PR 的 OK 结果同样是在此方向图上运行。FS 的更新记录全部 src < dst，且源数据标为 undirected，也需要明确是按存储方向解释的派生图，还是原本的 Friendster 无向图；本次未全扫描 FS 初始图，不能把更新方向扫描冒充全图证明。

若论文研究常规无向社交图，应在新数据目录生成对称拓扑与对称更新，并相应说明一次逻辑更新与两条物理边的计数关系。若有意研究 directed_min_label，应更名并解释该任务，另加非退化工作负载。

## 3. P0：正式运行的 `ok` / `Test passed` 不是结果正确性证据

所有正式命令都设置 `--check=false`，SSSP/BFS/CC 还关闭了最终 checksum。性能 CSV 的 48 行也全部标记 `timing_complete_unvalidated`。

current SSSP/BFS/CC 主函数的 `success` 初始化为 true，实质结果检查受 FLAGS_check 控制；原系统 SSSP 直接 gather 后返回 success。PR 主要检查 rank/residual 是否有限。没有验证时，“Overall: Test passed”通常只说明正常完成，没有提供与独立 oracle 一致的证据。current 日志中的 `gpu_cpu_hash_mismatches=0 audit=0` 也不能解释为执行了 GPU/CPU 拓扑一致性扫描。

必须在同一图语义、重复边语义和每批快照上验证两个系统。不能只验证 current 或只核对最终 reachable 数量。建议保存每批完整结果或可复查的差异报告：SSSP 对照 Dijkstra，BFS 对照 FIFO BFS，CC 对照明确定义的独立算法，PR 对照 double 精度固定点及真实方程残差。性能运行可以单独关闭检查，但验证运行必须绑定相同二进制与输入身份。

本次在空闲 GPU 1 上用正式 PR 历史二进制做了一个独立 64 顶点、10 批更新探针，结果在 `pr_probe/`。使用 SEGMENT=1 时 current 全部 64 个顶点最大误差约 1.39e-6；original 只打印前 20 个顶点，这 20 个顶点最大误差约 1.18e-6。该小例没有揭示明显 PR 数值错误，**但不是大图正式结果的验证**。尝试 SEGMENT=32 时 original 在队列分配处报 OOM；失败日志保留为 `original.segment32.log`。该小图配置的失败也不能当作正式大图基线 OOM。

## 4. P1：PR“统一 100 轮”不等于同等收敛精度

48 次 PR 运行中，两侧各有 12 次初始化 stop=iteration_limit：WK/TW 的三个规模、两个重复。current 另有一个正式批次未收敛：

`../raw/cc_pr_20260928/PR_WK_100k_current_r2.log:142`：batch=4，rounds=100，stop=iteration_limit，active=7。original 没有批次达到迭代上限。

runner 明确允许 `iteration_limit` 并仍将该运行记作 ok。这是“有界迭代预算”口径，不是“收敛到指定误差”的口径。相同 error=1e-6、相同 max_rounds=100 不能证明初始化状态相同、最终 rank 误差相同，或不同调度的一轮包含同样工作。

此外，两侧把 dangling 顶点的传播贡献丢弃，current 检查器求解的是 `x = 0.15·1 + 0.85 P^T x`，dangling 行为零，没有标准 dangling mass 再分配。可以研究这种变体，但需说明；不能不加定义地与其他实现的标准 PageRank 混表。

建议对等精度实验以固定点残差/与独立解的误差门控；有界预算实验单独报告误差、未收敛标记及时间。当前至少 PR WK/100k 不宜当作两侧均完全收敛的结果，WK/TW 初始化也需补查。

## 5. 已复算：未发现求和、平均、单位或十批数量错误

`audit.py` 独立从原始日志提取计时，没有调用原实验的汇总函数：

- 192 次正式运行均有且仅有顺序 0…9 的十个 P0 timer，总计 1,920 个值；
- 每次日志求和与 runs.csv 一致；48 行两次运行算术平均与 performmance.csv 一致；original/current 比例也一致，容差仅用于四位小数舍入；
- current 可用的 P0-ATTR 总和与 P0-TIMER 一致；
- 唯一逐批 JSON 缺件是 `CC_OK_10k_original_r2.batches.json`；对应日志仍完整，可以复算，未补写原文件；
- 两侧/两重复的图路径、更新路径、规模文件、源点、weight 参数、error/rounds、SEGMENT、n_stream、cache 相同；有逐次输入 size/mtime 身份的记录与当前文件仍匹配。历史完整输入内容未做哈希，不能把 size/mtime 一致等同于历史内容的密码学证明。

见 `summary.json`、`runs_recomputed.csv`、`comparisons_recomputed.csv`、`command_input_check.json`。因此不能用“均值算错了”解释这些倍率。

## 6. current 高加速的可观察原因：稀疏变化与不同维护路径

以 OK/1k 第一次 current 正式运行为例，十批合计：

| 指标 | SSSP | BFS | CC |
|---|---:|---:|---:|
| P0 总时间 / ms | 36.650 | 35.311 | 35.608 |
| 有效删除记录 | 5,000 | 5,000 | 5,000 |
| 有效插入记录 | 5,000 | 5,000 | 5,000 |
| 删除 repair affected 累计 | 151 | 24 | 0 |
| 插入 closure processed_edges 累计 | 916 | 943 | 0 |
| 完整缓存刷新次数 | 0 | 0 | 0 |
| hotness + candidate / ms | 15.729 | 15.650 | 17.826 |

这些日志证明 current 确实消费了更新记录，**但记录数不等于需要重新计算的顶点数或边数**。affected 累计也不等于跨批去重后的顶点数。OK SSSP/BFS 最终 reachable=316,201，只约占 loader 的 3,072,442 个顶点的 10.29%。固定一个源点、均匀抽样边更新，很容易产生小传播工作量。其他图在 1k 下也有非常少的实际 closure 边，详见复算 CSV；这并非仅 OK 的特征。

original 每批无条件执行 eviction/compact/LoadCache；current 判断是否需要刷新，并对变化源做稀疏维护。OK/1k 第一次 original SSSP 单是十次 compact 内部 timer 就累计 353.834 ms，而 current 完整 P0 合计仅 36.650 ms。BFS/CC 也有类似现象。这是可解释的系统级收益，**不能全部称为遍历 kernel 或传播算法加速**。内部 `(excluded)` 文本表示该内部指标不是主指标，不能把被外层 P0 覆盖的实际执行时间再扣除；也不能将内部 timer 与 P0 相加。

按冻结 SSSP/BFS 的代码边界，P0 覆盖 del/add、CPU mutation、publication、传播和执行了的缓存维护，并在边界同步 CUDA。current 在删除和插入之间暂停检查，正式配置关闭检查/通信记录。这次未发现足以解释 30× 的同步缺口。历史旧 CC 的 whole-window 诊断与 P0 相差 0.43%，也只支持那个旧版本/具体输入，不能代替当前全部 192 次的边界验证。current PR 在 UpdatePageRank 开头同步、cache 后同步，未发现明显异步 GPU 工作被甩到 timer 之外。

发布前需要独立 whole-loop wall timer 与各批 P0 的同跑对照，并做：传播与维护分项、原系统合理参数调优、维护策略消融、不同源点/种子和更高影响的更新负载。收益本身可能真实，贡献归因和适用范围必须与证据匹配。

## 7. P1：排除初始化后快很多，完整进程并不快很多

P0 刻意排除读图、初始遍历、更新文件解析、初始缓存和 current 反向索引构建。这是合法的稳态增量指标，但需要明确状态已经预构建。

| OK/1k | 十批增量加速比 | 历史完整进程 original/current |
|---|---:|---:|
| SSSP | 30.0466× | 0.8999× |
| BFS | 31.5108× | 0.9476× |
| CC | 34.2995× | 1.2382× |
| PR | 33.8343× | 1.0741× |

在 47 个有两側完整 wall_seconds 的组合中，40 个 current 完整进程平均耗时更长。wall 指标含文件解析、初始化、输出、进程启动及缓存状态影响，不是严格受控的另一套端到端 benchmark，因此这里只用它证明**不能把 P0 倍率外推到整个应用**。

例如 current SSSP OK/1k 仅 base reverse index 构建，两个重复均值约为十批增量均值的 96.86 倍；TW/1k 为 77.57 倍。这些预处理不是漏计，而是被定义排除。需要分别报告 initialization、steady-state、完整生命周期，以及长流中何时摊销。没有相同边界的数据，不能精确推算 break-even。

## 8. P1/P2：样本与 provenance 仍不足

只有两个独立进程重复；十个 batch 是同一进程连续状态上的相关样本，不能冒充 20 个独立重复。current SSSP WK/10k 的两重复差值占均值 17.31%。这不会把 30× 自动变成 1×，但两个样本不足以支持稳健置信区间、尾延迟或普遍性结论。需要多个独立进程、不同更新种子/源点，并把配对方式与离散度写入报告。

SSSP/BFS 的四个保留二进制均匹配 manifest 哈希。CC/PR manifest 中的每个路径也匹配其声明的文件哈希，但 **current CC 的 manifest 指向旧 latest_build/hash=125222…，正式 24 次 current CC command 指向 fixed_build/hash=aab224…**。逐次命令哈希与目前保留的实际二进制一致；不能误读为“二进制被篡改”，实际问题是顶层 manifest 已过时。fixed_build 中有部分源码文件哈希清单，但没有同目录完整可重建的源码树，应补齐精确源快照与构建记录。

current CC 修复后重跑并复用旧 original 数据，原先 ABBA 的同一时段配对已不成立。影响尚未量化；最终验证应让修正后的基线与 current 在同一实验轮次中交错执行。current 使用 20 mutation workers，而两侧统一 NUMA 绑定并不等同于相同线程实现/使用量；需要报告实际 CPU 核数与资源预算，分别说明系统性能比较与固定资源消融。

original BFS 还是 original SSSP 引擎的单位权适配。必须明确这一身份并验证适配结果，不能写成未经修改的原仓库 BFS。

CSV 后来加入的 ingress 字段标记 `reset_plus_replay_compute_excluding_topology`，与 current 的拓扑更新+增量传播+维护不属于同一计时边界；部分 TW/FS ingress 只有一个重复。本次没有审查其全部源码/日志，因此不判断这些数值是否正确；仅从字段即可确定不能直接把所有列当成同口径排名。

## 建议的最小重新封板顺序

1. 保留现有数据；将它标为历史、未验证的性能观测。
2. 在新目录修复 original 数组边界；核对真实算法、方向性、权重、重复边和更新计数定义。
3. 给双方同一精确 artifact 做独立每批正确性验证；PR 额外报告方程残差与误差，隔离有界未收敛实验。
4. 用同跑 whole-loop timer 核对 P0；分别记录预处理、传播、拓扑、缓存维护。优化的条件性跳过可以保留，但须证明结果与缓存内容正确。
5. 对已通过验证的版本同轮交错重跑，多进程重复与多工作负载种子；补有影响的删除/插入、源点变化、对称社交图或明确的有向任务。
6. 从新 raw 只读生成新的统计表与完整 provenance。只有完成前述门控，才将相应倍率升级为论文结论。

本次没有“修正”原表中的倍率。当前证据更支持：**高倍率至少部分来自轻量传播与避免全局维护；发表风险主要在基线未定义行为、任务退化/语义、正确性缺证和结论口径，而不在已经复算的均值公式。**
