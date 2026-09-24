# hybrid_cc 语义迁移与验证（2026-09-23）

本次以工作区当前 hybrid_sssp 副本为骨架，将 samples/hybrid_cc 改为无向图
Connected Components。结果为分量内最小顶点 ID，孤立点结果为自身 ID；
输出两列 vertex/component_label，不输出 SSSP distance/parent。

## 算法替换

- 初始化每个顶点的 buffer 为自身 ID；value 从 identity 开始，由初始闭包提交。
- GPU 传播、CPU closure、added-edge seed、跨域 proposal 和两种删除 repair
  统一零边代价；插入只在标签严格降低时产生传播事件。
- 删除不能仅沿 SSSP parent subtree：零代价环没有正权距离下降约束，原 witness
  和 ordered repair 的同标签择父不构成受维护的 CC 生成森林。
- 删除在 GPU 上标记被删除边端点的旧分量，复用分量根的 buffer，不新增常驻数组。
  收集受影响分量的顶点，重置 value/buffer 为各自 ID，再通过当前 reverse index
  进行局部闭包。自环删除不触发标签修复；不同旧分量间的缺失删除也不触发。
  同分量内的缺失删除、平行边删除允许保守修复。
- `--check` 使用独立 union-find，不能只检查边两端标签相等，以免漏掉断连后的旧标签。

## 保留的系统路径

保留 chunk arena/source-local 更新、regular/large/auto 分组维护、反向索引、
publication merge、cache patch/tail/refresh gate、hotness、exact frontier、
block/thread/ordered 插入调度、ordered 删除修复、CPU 分区和固定 domain map、
P0 计时与通信 ledger/window。共享所有权参数继续使用 sssp_cpu_* 名称。
I16 weighted snapshot 格式不适用 CC，明确拒绝而非生成误标快照。

共享接口增加编译期 kComponentLabels，SSSP/BFS 默认 false。修复混合插入的
重复 exact seed 队列未在分段队列接管后清空的问题；修复整个插入/删除输入为空时
cudaHostRegister 的零字节参数。静态图 Context 放行由 CC 显式选择，其他应用默认不变。
未覆盖工作区已有 BFS、论文、实现计划等修改。

## 输入契约

采用无向多重图双向存储：基础图、每个删除阶段、每个插入阶段都必须包含数量相同的
(u,v)/(v,u)。自环无需额外反向记录，batch size 统计有向 occurrence 数。
启动时验证基础图及更新的对称性，错误返回非零退出码。权重不参与计算。
静态 CC 可省略两个更新路径。详见 samples/hybrid_cc/README.md。

## 验证结果

构建：CUDA 12.1 / sm_70，build-bfs 中 hybrid_cc、hybrid_bfs、hybrid_sssp 均成功。

- `python3 tests/cc_dynamic_smoke.py --binary build-bfs/hybrid_cc --gpu 2
  --output logs/cc_smoke_20260923_verified`：15 个配置/契约场景通过，230 个增删阶段
  标签 checksum 与独立 Python flood-fill 一致，所有最终输出逐顶点一致。
  覆盖桥/环删除、分裂/合并、平行 occurrence、自环、零度孤立点、空阶段、
  缺失删除、随机混合批次、非单位权重、三种调度、三种维护模式、缓存开关、
  CPU 分区、固定 CPU/GPU 域、sparse、check=false、静态和非对称输入拒绝。
- `logs/cc_contract_20260923/`：通信计量开启后 16 批最终标签与关闭时相同；
  静态与非对称图/更新契约通过。
- `logs/cc_shared_bfs_20260923/`：已有 BFS semantics 测试，30 个增删阶段及初始结果通过。
- `logs/cc_shared_sssp_20260923/`：同一 16 批输入的 GPU 和 CPU 分区两种 SSSP 路径，
  64 个阶段 checksum 和全部最终距离与独立 Python Dijkstra 一致。
- 9 个 CTest 通过：communication_meter（开/关）、grouped_update_batch、
  topology_replay_fixture、cache_patch_trace、cache_refresh_gate、source_local_chunk_store、
  dynamic_reverse_index、exact_source_frontier。
- git diff --check、Python 语法检查通过。

## 性能证据边界

本次验证没有正式大图吞吐量门槛。check=false 小图运行仅验证优化路径不依赖校验器，
不能据此发布 SSSP/CC 或新旧 CC 性能胜负。

删除组件标记不增加常驻 GPU 数组，但收集阶段每非空删除批扫描 O(V) 标签，
repair 的受影响集可能是整个旧巨型分量。保留所有系统性能组件，不等于证明巨型
分量删除时批耗时不回退；进一步缩小到生成森林子树需要额外维护可靠的 CC 森林，
不能直接复用当前 SSSP parent。该性能边界不应被隐藏为“只替换加法为 min 即可”。
