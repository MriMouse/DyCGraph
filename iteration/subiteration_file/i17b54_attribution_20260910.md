# I17-B5.4.0 性能损失归因

复算 `logs/stage_pre_i17c_20260908/runs.json` 中 Friendster 1000k 三次十批结果。当前系统 paper 平均约 1945 ms/batch；原仓库同 cohort 的 SSSP paper 平均约 1293--1354 ms/batch，差距约 0.6 s/batch。两侧 hybrid 参数不同（当前 h2，原仓库 h1），因此这是差距定位证据，不是最终同语义性能结论。

当前 FS 1000k 的主要分项：reverse prepare 约 755 ms/batch，forward prepare 约 263 ms/batch，mixed-source grouping 约 130 ms/batch；GPU repair/cache 分项合计约 190 ms，不能解释主要差距。原仓库 traversal 日志中 host update+reload 约 0.52 s/batch，GPU compute 约 0.65--0.8 s。当前额外成本集中在两阶段 topology preparation、reverse overlay 和 sparse publication 前的 CPU 数据组织。

结论：下一步优先验证批内公共准备合并，目标是减少 delete/add 两个 phase 重复的 effective record 构造、目标分组和准备遍历；不先重写 GPU repair。由于 deletion 中间态仍必须独立可见，合并只能共享只读索引和分组，不能把两阶段提交合成一个最终态提交。

记录位置：阶段矩阵原始日志、`logs/i17b5_20260909/b53_screen2/` 候选短测，以及本文件对应的计划条目。下一次候选须固定 hybrid/cache/source 参数并计入完整 paper time。
