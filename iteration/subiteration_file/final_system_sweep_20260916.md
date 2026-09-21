# 最后一轮系统并行度筛查（2026-09-16）

用户授权最后尝试，并允许在1M/10M扩展性模式中切换组件。基于此前bulk/radix失败，先固定large、publication merge、reverse64、NUMA0/cache2，在TW/FS1M比较mutation workers=20/32；关闭bulk和parallel radix。此项仅判断CPU并行度不足能否解释劣势，不作为新算法或论文创新。

脚本`scripts/run_final_system_sweep.py`，日志`logs/final_system_sweep_20260916/`，PID2793485。四次串行，每次两批；输出完整P0和checksum。当前运行中；完成后以完整P0和同输入checksum裁决，单次配对只能筛方向，不能正式宣称胜出。此前启动目录创建冲突已修正，失败未运行GPU。

TW1M已完成：20 workers两批1622.023ms，32 workers1558.158ms，下降3.94%；两者checksum均为15984646590043123926，匹配既有参考。FS两次仍在运行。此收益为单轮并行度筛查，未满足稳定优势证据，不启动10M；待FS结果再作最后裁决。


## 2026-09-17完成复核

四次全部完成，逐条复核均为两批、最终checksum与各自既有参考相同。TW20/32 workers为1622.023/1558.158ms（-3.937%）；FS为1749.395/1748.111ms（-0.0734%）。仅单对，不构成重复性能确认，FS效果可忽略。10M未运行。此脚本没有冻结二进制/锁卡/自动checksum Gate等完整实验防护，本轮事后checksum核对通过不能代替这些流程；后续如验证10M应使用既有带锁及输入哈希检查的runner，不复用该简化筛查脚本。
