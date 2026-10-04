# PR差距与CPU公平性复核

用户确认排除Ingress全图拓扑重建。已导出 `raw/ingress_20261002/window_analysis/selected_window_runs.csv`，列出每次10批 `sum(reset_ms+compute_ms)`，同时保留完整更新计算时间和排除的拓扑时间，不覆盖原始结果。后台继续SIGSTOP暂停；加载中的旧runner仍使用旧汇总逻辑，恢复前须重启并处理暂停污染的那次运行，不能直接SIGCONT作为新窗口正式任务。

## CPU证据

扫描四算法各24份current命令，共96份，全部为 `numactl --cpunodebind=0`、`CG_MUTATION_WORKERS=20`、`CUDA_VISIBLE_DEVICES=0`。实际current日志的CPU mutation行包含 `workers=20`。这表示单插槽允许范围内20个更新worker，并非整个程序严格只有20个OS线程，也不代表每个worker固定绑定一个不同物理核。

node0有20物理核、40逻辑CPU（0-19,40-59）。Ingress使用同一集合，app_concurrency=20，单MPI rank，实际进程/线程mask已检查。因此current与Ingress的CPU可用插槽和显式主要计算worker预算对齐；current另外使用GPU0。

original的96份命令也绑定node0并使用GPU0，但均未设置CG_MUTATION_WORKERS。不能声称original也启用了相同的20-worker更新实现；它使用原算法线程策略。公平的是允许使用的CPU集合，不是强行令不同实现实际线程数相同。历史命令只能证明配置，不能回溯每个历史线程的实际调度。

## PR为什么不能直接和论文68.2s比较

已有Ingress OK/1k总时间29.009s，其中拓扑21.472s。排除拓扑得到7.537s，包含旧贡献回收1.937s和新贡献重放/收敛5.600s。这一减少完全可由现有阶段计时解释；尚不能说明论文同样排除这个阶段。

实际Ingress两次的批次轮数分别为24–30和24–28，全部标记converged，没有任何batch强制跑满100轮。current r1为24–32轮（合计262），original r1为25–28轮（合计260），与Ingress接近。100只是上限。论文正文没有提供可确认同一error、归一化、悬挂点策略和轮数上限的证据，不能断言论文跑了100轮或以轮数比例解释全部差距。

需要纠正此前“仅语义适配”的描述：新增RunPaperPR在每轮先冻结残差，仅对abs(residual)>1e-6的顶点传播；原worker用atomic_exch消费所有残差，kernel只检查非零，并采用全局L1停止。新路径仍扫描全部顶点，但可以跳过大量很小的非零残差的出边传播。此修改既统一了current/original残差语义，也改变了调度/执行工作量，可能明显加速，不能称其性能与论文未修改Ingress实现等价。两阶段冻结还改变了原有同轮消费新消息的执行顺序。

目前验证证明小图数值及残差不变量通过，不证明已复现论文实现或完整大图结果。论文OK图比本地图略小、线程预算更大，不能把这些差异当成我们更快的充分原因。要解释68.2→7.54的幅度，需要论文使用的具体代码/参数，或在相同本地图和硬件上对原生传播调度与阈值过滤分别做受控比较；当前暂停期间未启动新实验。

当前可支持的结论：与current的CPU资源约束相符；PR目标残差语义和轮数上限已对齐；但PR执行调度已修改、论文停止策略未核实、排除全图拓扑的窗口与现有current/original含拓扑指标存在不对称。不能据此宣称完整公平性或论文复现已经得到证明。
