# PR 收敛口径对齐（2026-09-27）

用户最终选择：两个系统都按残差阈值提前停止，初始化和每个增量批次最多 100 轮；直接修改原旧系统。此前只改隔离副本的限制已撤销。

- 原系统实际路径：`../C-GpuStreamGraph`（大小写与口述不同），现已应用收敛补丁；二进制 `build/hybrid_pr`。应用前核对三个目标文件 SHA256 与记录一致。原有 CMakeLists.txt 改动保留。
- 早期隔离副本：`../C-GpuStreamGraph-pr-aligned`，源码同步最终补丁；实验请使用原目录中新编译的二进制。
- 当前系统二进制：`build/hybrid_pr`。
- 双方使用 `--error=1e-6 --pr_max_rounds=100`。`pr_max_rounds` 允许 1–100，较小值用于截断测试。不要用旧的 `max_iteration` 控制 PR。
- 活跃条件是每顶点 `abs(residual) > error`；不是全图残差总和，也不是相对 rank 误差。等于阈值不活跃。
- 日志 `stop=converged` 表示队列清空，`stop=iteration_limit` 表示达到上限仍有待处理顶点。后者不能当作达到目标精度。
- 当前版达到上限保留残差和待处理队列，下一批合并新激活顶点；`--check=true` 仍检查目标精度，截断后未达标会失败。`--check=false` 可继续截断实验。
- 旧版原有 `--check` 不实际校验 PR（会输出 Result not checked）；不能将旧版进程退出 0 视作独立精度验证。

旧版修改仅包含：PR 参数及验证、初始化从最多 1000 改为参数控制（PR 默认 100）、增量循环增加空活跃队列提前退出及停止原因日志。其他算法的初始化默认上限仍为 1000。补丁为 `legacy_pr_alignment.patch`，可在新的源码副本内使用 `patch -p1 < PATCH` 应用。`legacy_source_sha256.json` 记录三个原始文件的校验值。依赖和数据符号链接保持链接，未复制数据集。

编译旧副本：

```sh
cmake -S ../C-GpuStreamGraph-pr-aligned -B ../C-GpuStreamGraph-pr-aligned/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-12.1/bin/nvcc \
  -DCUDA_NVCC_EXECUTABLE=/usr/local/cuda-12.1/bin/nvcc \
  -DCUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda-12.1 \
  -DTHRUST_INCLUDE_DIR=/usr/local/cuda-12.1/targets/x86_64-linux/include
cmake --build ../C-GpuStreamGraph-pr-aligned/build --target hybrid_pr -j2
cmake --build build --target hybrid_pr -j2
```

验证：

- 两个二进制编译通过；当前版 `tests/pr_dynamic_smoke.py` 的 14 个场景通过，结果见 `current_smoke_result.json`。
- 原有 100 边长路径用例在新上限下会截断并被精度检查拒绝；达标回归的路径改为 20 边，并增加专门的 1 轮截断后连续 10 批残差恒等式校验。未提高误差阈值来掩盖截断。
- 配对小图为该测试生成的 4096 顶点图及 10 批更新；双方相同参数 `--format=market_big --weight=true --weight_num=0 --SEGMENT=1 --n_stream=1 --hybrid=0 --cache=0 --error=1e-6`，当前版额外开启独立精度检查。32 分段/2 GB 缓存时旧版小图在 queue 分配 OOM，故配对验证双方均使用单分段/无缓存，未改旧版分配逻辑。
- 初始化均为 74 轮。增量轮数如下（批次从 0 开始）：

| 系统 | 0（空批） | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 旧版副本 | 1 | 3 | 79 | 1 | 1 | 2 | 41 | 39 | 78 | 41 |
| 当前版 | 0 | 3 | 79 | 1 | 1 | 2 | 41 | 39 | 78 | 41 |

- 两边以 `--pr_max_rounds=1` 运行均记录上限停止，当前版截断后继续批次的残差恒等式检查通过。日志见当前目录。

停止规则一致不意味着任意数据集轮数必然相同。旧版全图撤销/补偿、当前版只处理修改源点，以及不同内核内更新顺序和浮点累加，仍可能造成轮数差异；空批次已有实例。正式实验必须同时记录轮数、停止原因、结果精度和完整批次耗时。触及 100 轮但未达标的结果不能纳入“同精度 PR 加速比”。本次没有重跑 OK/EU/FS 大图性能实验，没有更新加速比结论。

## 原系统直接修改的性能范围审计

最终补丁复用原有 `count()`（批次入口）和 `PostComputationBW_Inc()`（每轮结束）已回传的 `input_active_count_seg`。没有为停止检查额外读取 GPU 队列计数，没有新增 CUDA memcpy、同步或 kernel；仅增加每轮 CPU 分段计数求和和分支。修正了早期隔离补丁中重复 `GetCount()` 的额外同步。初始化的停止摘要在原计时器停止后打印；增量摘要在循环外打印。

计算内核、缓存策略、图更新、工作队列重建与既有传输路径未修改。所有已执行轮次仍走原路径。CPU 判断与日志不可能数学意义上零耗时，因此不能承诺端到端性能完全不变；实际耗时也会因提前退出而减少。这是停止规则的公平对齐，不是“同轮数、同精度、同耗时”已经得到证明。旧版自报增量迭代时间仍只累计原有计算区间，不能直接当完整批次耗时与当前版相除。

原目录最终验证：`cmake --build ../C-GpuStreamGraph/build --target hybrid_pr -j2` 成功。新二进制在相同小图上初始化 74 轮、10 批轮数与早期副本一致；`--pr_max_rounds=1` 时初始化及全部 10 批均正确标记 `iteration_limit`。记录见 `original_matched.log`、`original_capped.log` 和 `original_validation.json`。两仓库 `git diff --check` 通过。
