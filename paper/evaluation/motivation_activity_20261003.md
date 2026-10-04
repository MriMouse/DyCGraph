# CPU/GPU 活跃度补充实验

脚本 `scripts/run_motivation_activity.py`，输出 `paper/evaluation/raw/motivation_activity_20261003/`。

沿用动机实验冻结的两系统二进制、TW/FS 100K 数据、源点、GPU0、NUMA0 和所有算法参数；`CG_MOTIVATION_MODE=off`，不启用计数扫描或计时同步。每系统每图两次，共八个进程，顺序 current/original/original/current。无需修改算法或编译。独立 Python 进程通过 NVML（ctypes，直接访问驱动，无第三方 Python 依赖）每约 100ms 采样；每两秒检查其他 GPU 进程，发现争用的运行不进入均值。

## 时间窗口

利用现有日志的 `batch number 0` 和 `[P0-TIMER][SSSP][batch 9]`，汇总完整十批增量窗口。排除读图、初始遍历与缓存装载、最终结果输出；包含增量拓扑维护、计算和缓存维护。`stdbuf -oL -eL` 让两个系统的 C stdio 日志及时输出；外部读取线程记录收到边界的单调时间和进程 CPU 时间。这避免改代码，但边界有管道调度延迟，并非精确的内部计时。原始逐批 P0 时间也保留，便于核对窗口长度。

## 指标

- `cpu_seconds`：窗口末减窗口初的 `/proc/PID/stat` utime+stime，包含目标进程全部线程，不含采样进程。分辨率见 manifest 中 CLK_TCK。
- `cpu_average_cores`：CPU 秒数 / 窗口墙钟秒数，例如 3.2 表示平均消耗 3.2 个逻辑核。
- `cpu_one_core_pct`：上述值乘 100，允许超过 100%。不按整机数百核归一化，避免误导。
- `gpu_pct`：NVML utilization.gpu，驱动自身采样窗口内至少有 kernel 执行的时间比例；对外部读取序列按实际间隔加权，截取十批窗口。
- `memory_busy_pct`：NVML utilization.memory，设备内存读写忙碌时间比例；**不是显存容量占比，也不是带宽占峰值比例**。
- `gpu_busy_seconds_estimate`：窗口时间 × gpu_pct / 100，粗略 GPU 忙碌时间估计，不能替代 CUDA kernel duration。

NVML 本身使用约 1/6 秒至 1 秒的采样窗口（取决于硬件），100ms 读取不会提高原生时间分辨率，重复读数保留。窗口前后可能混入邻接阶段的数据，尤其 current 的完整十批仅约 3–5 秒。此结果用于**粗粒度活跃度描述**，不用于精确逐批归因或证明硬件计算效率；不输出逐批 GPU 使用率。CPU 时间也包括驱动等待/忙等，不能解释为全部有效 CPU 图计算。若论文需要精确重叠率/SM occupancy，应另做 profiler 实验，本次不引入它们。

每次先计算整个窗口平均，最终对两次成功运行取算术平均，不跨两次按时长混合。失败不补零。初始化期间仅保留最近一秒 GPU 样本；完整增量窗口保存到 `*.samples.json`。`*.result.json` 包含边界、CPU 时间、原始 P0 批时间及采样数。`averages.csv` / `averages.json` 是汇总，`status.json` / `runner.log` 是进度。小图已验证两系统边界捕获、CPU读取、NVML接口和汇总流程；继承原动机实验对 Grapin 正确性的限制。

外部采样仍有少量 CPU/驱动查询及日志刷新开销，不宣称零扰动；不使用该运行替换原先的无采样性能结果。无需再跑计数模式，每轮运行结束进程退出即停止采样，日常执行默认不采样。

```bash
cat paper/evaluation/raw/motivation_activity_20261003/status.json
tail -n 20 paper/evaluation/raw/motivation_activity_20261003/runner.log
```
