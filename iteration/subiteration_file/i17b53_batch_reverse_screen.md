# B5.3 批量 reverse 首候选筛查

2026-09-09：首候选完成实现和 FS 1000k 四次两批筛查，保留研究候选，尚未通过 B5 完整 gate。

## 实现

排序后生成 destination 范围并统计新增槽位。需要扩容时按当前槽位数加真正新增数 reserve，随后完成全部槽位创建。固定线程池并行构建各 destination 的新 vector；只读旧 vector，不在并行区修改共享 map。Commit 保持 vector swap 和空槽位清理，Prepare 失败后的 pending 可在下次 Prepare 清理。

本轮使用 reverse 专属线程池，生产 Build 请求 20 workers；没有复用 source mutation 的同一实例。新增成本包括线程资源、pending 的两个 size_t 范围字段、分组遍历和槽位预查询；无新增 pinned/device 数组。目标 vector 仍逐个分配，未实现连续输出存储。没有将 B5.1 的 records workspace 复用重新引入。

## 两批结果

同一 FS 1000k 输入、source=0、hybrid=2、cache=2、20 mutation workers、GPU 0、Release/GCC-12/CUDA 12.1。每次连续两批，check=false，图加载不计入 paper。基线为阶段矩阵冻结二进制；源码与候选 SSSP 计时围栏相同。

| 顺序 | 两批 paper ms | 两批 reverse prepare ms |
|---|---:|---:|
| baseline 0 | 3801.065 | 1270.624 |
| candidate 1 | 3580.595 | 1075.509 |
| candidate 2 | 3830.865 | 1104.491 |
| baseline 3 | 4061.174 | 1242.751 |

paper 均值 3931.120 -> 3705.730 ms，下降 5.73%；reverse 均值 1256.688 -> 1090.000 ms，下降 13.26%。相邻两组 paper 下降 5.80%/5.67%。基线和候选两次 spread 分别约 6.62%/6.75%，不能仅凭均值认定收益超过运行波动；相邻配对方向一致是继续验证的理由。候选第二次 source group 和 apply 也变慢，尚不能断言波动原因。

四次均正常退出、每批输入 100 万且删/加各 50 万有效记录；最终距离 checksum 均为 4613270879134330002。parent checksum 不同，check=false 未验证 parent witness，不能作为正确性 gate。三项 topology CTest 通过；另扩展 reverse 单测至 257 个目标，覆盖多个线程工作块、重复记录抵消、准备取消、提交和清空 overlay，测试通过。

## 证据与后续

- 原始四次日志、time 和 results.json：`logs/i17b5_20260909/b53_screen2/`。
- 冻结候选源码、测试与二进制：`logs/i17b5_20260909/b53_candidate/`。
- 二进制 SHA256：`88fed6fda4ebc44a7c735e2e268bd11f6e9eccbeae5aaa775c3ae15db313c43f`。
- 首对 RSS 均约 55.3 GiB，由初始化主导，不能代替新增 workspace/线程资源账本。

下一步按 B5.3 既定 gate 做十批交错，覆盖 batch 3/7 的历史峰值；补 FS/TW 100k 和小 batch 回归，以及删除/插入距离、tight witness 和跨批空间检查。收益中槽位准备和并行 merge 的独立贡献尚未分离，需在后续验证中用少量阶段级诊断解释，不宣称全部来自并行。当前只完成首候选尝试，不宣布 B5 收口，不进入 B6，也不恢复大矩阵。
