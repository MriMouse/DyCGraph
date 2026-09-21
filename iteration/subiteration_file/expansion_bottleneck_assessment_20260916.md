# FS/TW扩展性瓶颈评估（2026-09-16）

## 结论

当前没有足够证据支持继续盲目优化并宣称能稳定追平原系统；本轮建议收口。I21/I23已验证 publication 合并、source radix、bulk group 三类候选，未完成新的同口径原版对照，不能据此判定没有追平机会：I23 TW1M原路径1.759s，仅合并1.625s（-7.63%），合并+bulk 1.687s（-4.07%，相对原路径），bulk相对仅合并回退3.86%。10M未启动。

## 劣势来源

1. **CPU source-local mutation工作量过大。** TW1M每批100万更新，delete/add各约42.2/42.6万source，source_work约4700万；删除写入约116MB，虽有效但必须扫描并重写大量邻接。10M日志每批约260/280万source，source_work约1.2亿，mutation阶段约1.5–1.8s/phase。原版PMA路径在相同输入上不承担相同的source批量计划、chunk分配、retire/reclaim和publication协议成本。
2. **preflight/effective与reverse历史增长。** TW1M每phase preflight约105–119ms，其中reverse prepare约50ms；10M每phase preflight约0.8–0.95s，reverse排序约0.2s、slots/merge/commit和哈希扩容继续增长。preflight包含reverse，不能把子项重复相加。两批后reverse overlay约200万记录，扩展性成本会随批次积累。
3. **同步与内存系统。** CPU worker虽有20个，但每phase需等待全体source计划、预分配、apply、retire，再发布给GPU；固定worker不能消除邻接随机读、pinned host chunk写入和unordered_map rehash。bulk group只减少约26ms物化，不改变这些同步边界。
4. **GPU并非唯一瓶颈。** 1M完整P0约0.8–0.9s，CPU mutation/preflight与GPU传播交错；优化一个host timer会被另一个phase波动抵消。旧系统与当前系统的跨系统checksum/资源语义也未形成一组新的正式同口径10M对照，不能用历史目标线冒充胜出。

## 已否决与剩余机会

- B5统计结构精简已在TW10M回退，不能重做。
- I21位置复用在TW/FS10M收益不足，不能重做。
- I21 publication merge有效但平均仅约5%，两对不稳定；保留显式候选，不改默认。
- I23 bulk group CPU微探针有效，完整P0回退，已否决；不扫worker/grain参数。

理论上仍有大改机会：分块publication、reverse overlay压缩/分代、减少source邻接搬移、GPU/NUMA协同拓扑维护或改变原版/当前共同工作语义。这些都需要新的容量/正确性设计，不能在现有16GB、同语义约束下保证收益；当前证据不足以继续投入并承诺胜出。若未来有更大GPU和合法10M/100M数据，应单独立项做容量与reverse分代设计，而不是继续局部timer优化。


## 2026-09-17复核修正（优先于上文收口判断）

前次把I23仅合并收益误报为4.07%，实际为7.63%；4.07%属于合并+bulk。bulk相对仅合并回退3.86%的结论不变。此前从1M候选未过Gate推断10M只能架构重写，证据不足；1M/10M阶段占比不同，不能相互代替。最后worker筛查TW1M下降3.94%，FS下降0.073%，均为单对，不能证明稳定优势。

保留TW10M低成本验证机会：历史large均值11.2885s，对原版目标10.7159s差0.5727s；publication合并首批10M机制探针节省约0.296s，两批机械折算接近缺口，但第二批及完整效果未测，不能视为追平。FS10M差约2.1829s，证据明显更弱。主要已量化预算是grouping、prepare和preflight，reverse包含于preflight；不能把source_work当实际扫描数，也不能从候选自身日志定量归因两系统差额。更大GPU不是现有TW10M验证的必要前提，现有同配置成功记录已在前文实验中确认。

因此建议仅对TW10M保留同配置publication合并正反配对，先隔离合并效果；不再扫worker/bulk/radix，也不关闭正确性必需的reverse。通过历史目标仍须处理原版共同checksum不匹配，才能宣称正式胜出。本次仅复核及纠错，未新启动实验。
