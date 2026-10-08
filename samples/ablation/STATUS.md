# 本次准备验收记录（2026-10-04）

- 工作位置：`C-GpuStreamGraph-CG/samples/ablation`；未修改 `graphbolt`，未修改生产 include/samples/CMake、9 月 27 日冻结实验或正在运行的实验产物。
- 隔离输出：`build/ablation_20261004_ready`。
- `111/011/101/110/000/001/010/100` 八种组合，SSSP/BFS 共 **16 个二进制全部编译成功**。
- 四个 D=0 组合的 PMA CPU 回归全部通过，覆盖重复/缺失删除、空批、集中插入、跨 source 搬移、reverse 与 epoch；回归确实触发了旧 PMA rebalance 的边界，兼容修复记录见 README。
- 三项 Python 准备回归通过；八组合生成结果与最终生成器逐字节一致；`111` 算法/框架/driver/app 源码与 frozen current 一致（main 仅增加配置日志）。
- 全部生成源码、二进制 SHA256 已复核；冻结基线源码 SHA256 未变。编译采用 CPU39/nice19/-j1/GPU 屏蔽，未启动 GPU kernel 测试。
- 192 次主矩阵与 384 次完整矩阵已生成，仅计划。实际启动消融性能进程 **0 次**。
- 启动保护只读实测：能识别活动 Ingress runner、road/communication 父 runner 及 GPU0 进程，并拒绝启动。
- **GPU 小图正确性验证尚未执行，大图性能实验尚未执行。** 等现有实验整体结束后，按 README 先 `--mode validate`，通过后再 `--mode run`。没有预约或后台自动启动任务。

机器可读结果：`build/ablation_20261004_ready/readiness.json`。编译日志、PMA CPU 日志、source/binary manifests 在各组合子目录，参考来源 hash 在 `provenance.json`。
