# 文件级差异与证据覆盖索引

比较原仓库提交态与当前工作区；新增文件不自动等于独立创新。行数是文本差异量，不是工时。忽略构建产物、第三方依赖及数据；包含被 .gitignore 忽略的研究脚本。

| 状态 | 文件 | 当前行数 | + / − |
|---|---|---:|---:|
| modified | [include/framework/Loader.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/Loader.h) | 145 | 13 / 12 |
| added | [include/framework/affected_component_trace.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/affected_component_trace.h) | 128 | 128 / 0 |
| modified | [include/framework/algo_variants.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/algo_variants.cuh) | 2776 | 86 / 100 |
| added | [include/framework/cache_patch_trace.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/cache_patch_trace.h) | 64 | 64 / 0 |
| added | [include/framework/cache_refresh_gate.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/cache_refresh_gate.h) | 35 | 35 / 0 |
| added | [include/framework/destination_local_dependency_store.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/destination_local_dependency_store.h) | 565 | 565 / 0 |
| added | [include/framework/dual_domain_event_runtime.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/dual_domain_event_runtime.h) | 268 | 268 / 0 |
| added | [include/framework/dynamic_reverse_index.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/dynamic_reverse_index.h) | 366 | 366 / 0 |
| added | [include/framework/effective_delta_sort.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/effective_delta_sort.h) | 78 | 78 / 0 |
| added | [include/framework/effective_update_batch.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/effective_update_batch.h) | 263 | 263 / 0 |
| added | [include/framework/exact_source_frontier.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/exact_source_frontier.h) | 87 | 87 / 0 |
| added | [include/framework/f1_replay_state.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/f1_replay_state.h) | 89 | 89 / 0 |
| modified | [include/framework/framework.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/framework.cuh) | 5849 | 4135 / 474 |
| modified | [include/framework/graph_datum.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/graph_datum.cuh) | 410 | 62 / 13 |
| added | [include/framework/hotness_candidate_trace.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/hotness_candidate_trace.h) | 108 | 108 / 0 |
| added | [include/framework/i16_repair_snapshot.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/i16_repair_snapshot.h) | 53 | 53 / 0 |
| added | [include/framework/ordered_gpu_repair.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/ordered_gpu_repair.cuh) | 157 | 157 / 0 |
| added | [include/framework/owner_cost_planner.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/owner_cost_planner.h) | 103 | 103 / 0 |
| added | [include/framework/persistent_dependency_graph.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/persistent_dependency_graph.h) | 204 | 204 / 0 |
| added | [include/framework/publication_sources.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/publication_sources.h) | 24 | 24 / 0 |
| added | [include/framework/topology_replay.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/topology_replay.h) | 195 | 195 / 0 |
| modified | [include/framework/variants/api.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/variants/api.cuh) | 158 | 6 / 12 |
| modified | [include/framework/variants/driver.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/variants/driver.cuh) | 2163 | 195 / 163 |
| modified | [include/framework/variants/push_functor.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/variants/push_functor.h) | 1315 | 236 / 36 |
| modified | [include/framework/variants/sync_push_dd.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/variants/sync_push_dd.cuh) | 1579 | 128 / 112 |
| added | [include/framework/weighted_score_index.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/framework/weighted_score_index.h) | 178 | 178 / 0 |
| modified | [include/groute/device/array_bitmap.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/groute/device/array_bitmap.h) | 321 | 1 / 0 |
| modified | [include/groute/device/compressed_bitmap.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/groute/device/compressed_bitmap.cuh) | 259 | 1 / 0 |
| modified | [include/groute/device/queue.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/groute/device/queue.cuh) | 349 | 2 / 0 |
| modified | [include/groute/device/worklist_stack.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/groute/device/worklist_stack.cuh) | 250 | 4 / 0 |
| modified | [include/groute/graphs/csr_graph.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/groute/graphs/csr_graph.cuh) | 3582 | 400 / 16 |
| added | [include/groute/graphs/source_local_chunk_store.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/groute/graphs/source_local_chunk_store.h) | 905 | 905 / 0 |
| added | [include/groute/graphs/topology_contract.cuh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/groute/graphs/topology_contract.cuh) | 128 | 128 / 0 |
| modified | [include/groute/internal/cuda_utils.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/groute/internal/cuda_utils.h) | 78 | 1 / 0 |
| modified | [include/utils/app_skeleton.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/utils/app_skeleton.h) | 172 | 2 / 0 |
| added | [include/utils/communication_meter.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/utils/communication_meter.h) | 65 | 65 / 0 |
| added | [include/utils/communication_window.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/utils/communication_window.h) | 35 | 35 / 0 |
| added | [include/utils/fixed_worker_pool.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/utils/fixed_worker_pool.h) | 126 | 126 / 0 |
| added | [include/utils/i19_edge_reader.h](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/include/utils/i19_edge_reader.h) | 50 | 50 / 0 |
| added | [src/affected_component_analyzer.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/affected_component_analyzer.cpp) | 673 | 673 / 0 |
| added | [src/cache_patch_replay.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/cache_patch_replay.cpp) | 124 | 124 / 0 |
| added | [src/chunk_store_replay.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/chunk_store_replay.cpp) | 313 | 313 / 0 |
| added | [src/connected_road_generator.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/connected_road_generator.cpp) | 371 | 371 / 0 |
| added | [src/f1_crossover_replay.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/f1_crossover_replay.cu) | 183 | 183 / 0 |
| added | [src/hotness_candidate_replay.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/hotness_candidate_replay.cpp) | 93 | 93 / 0 |
| added | [src/i16_frontier_replay.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/i16_frontier_replay.cu) | 157 | 157 / 0 |
| added | [src/i16_repair_oracle.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/i16_repair_oracle.cpp) | 106 | 106 / 0 |
| added | [src/i17a_delta_replay.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/i17a_delta_replay.cu) | 302 | 302 / 0 |
| added | [src/i19_ratio_pool.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/i19_ratio_pool.cpp) | 184 | 184 / 0 |
| added | [src/i19_topology_replay.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/i19_topology_replay.cpp) | 303 | 303 / 0 |
| added | [src/i23_group_replay.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/i23_group_replay.cpp) | 54 | 54 / 0 |
| added | [src/road_source_scan.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/road_source_scan.cpp) | 85 | 85 / 0 |
| added | [src/topology_replay.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/topology_replay.cpp) | 207 | 207 / 0 |
| added | [src/utils/communication_meter.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/utils/communication_meter.cpp) | 29 | 29 / 0 |
| added | [src/verify_connected_road_dataset.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/src/verify_connected_road_dataset.cpp) | 149 | 149 / 0 |
| modified | [samples/hybrid_bfs/hybrid_bfs.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/samples/hybrid_bfs/hybrid_bfs.cu) | 202 | 11 / 17 |
| modified | [samples/hybrid_cc/hybrid_cc.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/samples/hybrid_cc/hybrid_cc.cu) | 197 | 5 / 16 |
| modified | [samples/hybrid_pr/hybrid_pr.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/samples/hybrid_pr/hybrid_pr.cu) | 206 | 5 / 0 |
| modified | [samples/hybrid_sssp/hybrid_sssp.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/samples/hybrid_sssp/hybrid_sssp.cu) | 674 | 419 / 42 |
| added | [tests/affected_component_trace_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/affected_component_trace_test.cpp) | 30 | 30 / 0 |
| added | [tests/cache_patch_trace_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/cache_patch_trace_test.cpp) | 40 | 40 / 0 |
| added | [tests/cache_refresh_gate_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/cache_refresh_gate_test.cpp) | 12 | 12 / 0 |
| added | [tests/cache_tail_fallback_test.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/cache_tail_fallback_test.cu) | 64 | 64 / 0 |
| added | [tests/check_owner_planner_decision.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/check_owner_planner_decision.py) | 5 | 5 / 0 |
| added | [tests/communication_meter_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/communication_meter_test.cpp) | 33 | 33 / 0 |
| added | [tests/communication_probe.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/communication_probe.cu) | 49 | 49 / 0 |
| added | [tests/communication_sampling_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/communication_sampling_test.py) | 32 | 32 / 0 |
| added | [tests/connected_road_generator_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/connected_road_generator_test.py) | 106 | 106 / 0 |
| added | [tests/dependency_warp_mapping_test.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/dependency_warp_mapping_test.cu) | 110 | 110 / 0 |
| added | [tests/destination_local_dependency_store_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/destination_local_dependency_store_test.cpp) | 228 | 228 / 0 |
| added | [tests/dual_domain_event_runtime_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/dual_domain_event_runtime_test.cpp) | 153 | 153 / 0 |
| added | [tests/dynamic_reverse_index_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/dynamic_reverse_index_test.cpp) | 313 | 313 / 0 |
| added | [tests/exact_source_executor_test.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/exact_source_executor_test.cu) | 193 | 193 / 0 |
| added | [tests/exact_source_frontier_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/exact_source_frontier_test.cpp) | 45 | 45 / 0 |
| added | [tests/f1_replay_state_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/f1_replay_state_test.cpp) | 31 | 31 / 0 |
| added | [tests/final_state_repair_model_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/final_state_repair_model_test.cpp) | 272 | 272 / 0 |
| added | [tests/fixtures/owner_planner_calibration.tsv](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/fixtures/owner_planner_calibration.tsv) | 5 | 5 / 0 |
| added | [tests/fixtures/owner_planner_topology.tsv](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/fixtures/owner_planner_topology.tsv) | 6 | 6 / 0 |
| added | [tests/fixtures/owner_planner_work.tsv](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/fixtures/owner_planner_work.tsv) | 2 | 2 / 0 |
| added | [tests/fixtures/topology_replay_batch_sizes.txt](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/fixtures/topology_replay_batch_sizes.txt) | 2 | 2 / 0 |
| added | [tests/fixtures/topology_replay_graph.txt](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/fixtures/topology_replay_graph.txt) | 5 | 5 / 0 |
| added | [tests/fixtures/topology_replay_updates.txt](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/fixtures/topology_replay_updates.txt) | 6 | 6 / 0 |
| added | [tests/grouped_update_batch_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/grouped_update_batch_test.cpp) | 97 | 97 / 0 |
| added | [tests/hotness_event_model_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/hotness_event_model_test.cpp) | 191 | 191 / 0 |
| added | [tests/hotness_pairing_test.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/hotness_pairing_test.cu) | 65 | 65 / 0 |
| added | [tests/hotness_trace_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/hotness_trace_test.cpp) | 45 | 45 / 0 |
| added | [tests/i16_capture_smoke.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i16_capture_smoke.py) | 43 | 43 / 0 |
| added | [tests/i16_frontier_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i16_frontier_test.py) | 35 | 35 / 0 |
| added | [tests/i16_motivation_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i16_motivation_test.py) | 82 | 82 / 0 |
| added | [tests/i16_paired_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i16_paired_test.py) | 43 | 43 / 0 |
| added | [tests/i16_repair_oracle_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i16_repair_oracle_test.py) | 85 | 85 / 0 |
| added | [tests/i16_road_validation_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i16_road_validation_test.py) | 100 | 100 / 0 |
| added | [tests/i17_scaling_generator_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i17_scaling_generator_test.py) | 28 | 28 / 0 |
| added | [tests/i17a_sparse_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i17a_sparse_test.py) | 88 | 88 / 0 |
| added | [tests/i17b5_pull_smoke.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i17b5_pull_smoke.py) | 48 | 48 / 0 |
| added | [tests/i19_gpu_smoke.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i19_gpu_smoke.py) | 53 | 53 / 0 |
| added | [tests/i19_loader_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i19_loader_test.cpp) | 18 | 18 / 0 |
| added | [tests/i19_ratios_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i19_ratios_test.py) | 74 | 74 / 0 |
| added | [tests/i19_work_metrics_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i19_work_metrics_test.cpp) | 51 | 51 / 0 |
| added | [tests/i22_ordered_insertion_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i22_ordered_insertion_test.py) | 89 | 89 / 0 |
| added | [tests/i23_bulk_group_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/i23_bulk_group_test.py) | 90 | 90 / 0 |
| added | [tests/owner_cost_planner_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/owner_cost_planner_test.cpp) | 27 | 27 / 0 |
| added | [tests/owner_planner_calibration.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/owner_planner_calibration.cu) | 57 | 57 / 0 |
| added | [tests/persistent_dependency_graph_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/persistent_dependency_graph_test.cpp) | 85 | 85 / 0 |
| added | [tests/publication_sources_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/publication_sources_test.cpp) | 21 | 21 / 0 |
| added | [tests/road_source_scan_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/road_source_scan_test.py) | 27 | 27 / 0 |
| added | [tests/source_local_chunk_store_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/source_local_chunk_store_test.cpp) | 466 | 466 / 0 |
| added | [tests/stage_pre_i17c_test.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/stage_pre_i17c_test.py) | 97 | 97 / 0 |
| added | [tests/topology_contract_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/topology_contract_test.cpp) | 124 | 124 / 0 |
| added | [tests/weighted_score_index_test.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tests/weighted_score_index_test.cpp) | 71 | 71 / 0 |
| added | [scripts/analyze_current_substages.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_current_substages.py) | 99 | 99 / 0 |
| added | [scripts/analyze_e0b_trace.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_e0b_trace.py) | 223 | 223 / 0 |
| added | [scripts/analyze_e4a2_capacity.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_e4a2_capacity.cpp) | 127 | 127 / 0 |
| added | [scripts/analyze_f0l_trace.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_f0l_trace.py) | 148 | 148 / 0 |
| added | [scripts/analyze_i11_final_state_upper_bound.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_i11_final_state_upper_bound.py) | 67 | 67 / 0 |
| added | [scripts/analyze_i17_communication.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_i17_communication.py) | 28 | 28 / 0 |
| added | [scripts/analyze_i17_target_pair.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_i17_target_pair.py) | 29 | 29 / 0 |
| added | [scripts/analyze_i17b5_existing.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_i17b5_existing.py) | 45 | 45 / 0 |
| added | [scripts/analyze_i19.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_i19.py) | 133 | 133 / 0 |
| added | [scripts/analyze_i8_mutation_ablation.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_i8_mutation_ablation.py) | 67 | 67 / 0 |
| added | [scripts/analyze_i9_critical_path.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_i9_critical_path.py) | 100 | 100 / 0 |
| added | [scripts/analyze_performance_matrix_20260912.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/analyze_performance_matrix_20260912.py) | 118 | 118 / 0 |
| added | [scripts/audit_i4_hotness_semantics.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/audit_i4_hotness_semantics.py) | 22 | 22 / 0 |
| added | [scripts/communication/README.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/communication/README.md) | 100 | 100 / 0 |
| added | [scripts/communication/compare.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/communication/compare.py) | 62 | 62 / 0 |
| added | [scripts/communication/prepare_baseline.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/communication/prepare_baseline.py) | 70 | 70 / 0 |
| added | [scripts/communication/run_100k_background.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/communication/run_100k_background.py) | 268 | 268 / 0 |
| added | [scripts/communication/sample_pcie.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/communication/sample_pcie.py) | 146 | 146 / 0 |
| added | [scripts/communication/smoke_pair.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/communication/smoke_pair.py) | 82 | 82 / 0 |
| added | [scripts/diagnose_i0_failures.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/diagnose_i0_failures.py) | 65 | 65 / 0 |
| added | [scripts/evaluate_e4r3_shadow.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/evaluate_e4r3_shadow.py) | 61 | 61 / 0 |
| added | [scripts/generate_connected_road_datasets.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/generate_connected_road_datasets.py) | 129 | 129 / 0 |
| added | [scripts/generate_uk2007_datasets.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/generate_uk2007_datasets.py) | 78 | 78 / 0 |
| added | [scripts/pause_trim_stage_pre_i17c.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/pause_trim_stage_pre_i17c.py) | 24 | 24 / 0 |
| added | [scripts/prepare_i17_scaling.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/prepare_i17_scaling.py) | 78 | 78 / 0 |
| added | [scripts/prepare_i19_ratios.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/prepare_i19_ratios.py) | 158 | 158 / 0 |
| added | [scripts/prepare_performance_matrix_20260912.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/prepare_performance_matrix_20260912.py) | 87 | 87 / 0 |
| added | [scripts/prepare_stage_twitter.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/prepare_stage_twitter.py) | 93 | 93 / 0 |
| added | [scripts/profile_current_runtime.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/profile_current_runtime.py) | 149 | 149 / 0 |
| added | [scripts/resume_stage_pre_i17c_short.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/resume_stage_pre_i17c_short.py) | 38 | 38 / 0 |
| added | [scripts/run_c4_current_vs_original.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_c4_current_vs_original.sh) | 457 | 457 / 0 |
| added | [scripts/run_current_vs_cgpustreamgraph_fs_tw.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_current_vs_cgpustreamgraph_fs_tw.sh) | 279 | 279 / 0 |
| added | [scripts/run_f0l_critical_path.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_f0l_critical_path.sh) | 70 | 70 / 0 |
| added | [scripts/run_final_system_sweep.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_final_system_sweep.py) | 15 | 15 / 0 |
| added | [scripts/run_i10_topology_contract.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i10_topology_contract.sh) | 22 | 22 / 0 |
| added | [scripts/run_i13_smoke.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i13_smoke.sh) | 38 | 38 / 0 |
| added | [scripts/run_i14_validation.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i14_validation.py) | 87 | 87 / 0 |
| added | [scripts/run_i15_candidate_replay.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i15_candidate_replay.py) | 117 | 117 / 0 |
| added | [scripts/run_i15_hotness_audit.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i15_hotness_audit.py) | 78 | 78 / 0 |
| added | [scripts/run_i15_pairing_validation.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i15_pairing_validation.sh) | 7 | 7 / 0 |
| added | [scripts/run_i16_frontier_replay.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i16_frontier_replay.py) | 109 | 109 / 0 |
| added | [scripts/run_i16_motivation.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i16_motivation.py) | 143 | 143 / 0 |
| added | [scripts/run_i16_paired.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i16_paired.py) | 230 | 230 / 0 |
| added | [scripts/run_i16_road_validation.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i16_road_validation.py) | 416 | 416 / 0 |
| added | [scripts/run_i17_eu_background.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17_eu_background.py) | 127 | 127 / 0 |
| added | [scripts/run_i17_scaling.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17_scaling.py) | 83 | 83 / 0 |
| added | [scripts/run_i17_scaling_supplement.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17_scaling_supplement.py) | 35 | 35 / 0 |
| added | [scripts/run_i17_social_probe.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17_social_probe.py) | 178 | 178 / 0 |
| added | [scripts/run_i17_target_check.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17_target_check.py) | 65 | 65 / 0 |
| added | [scripts/run_i17a_delta.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17a_delta.py) | 46 | 46 / 0 |
| added | [scripts/run_i17a_sparse.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17a_sparse.py) | 206 | 206 / 0 |
| added | [scripts/run_i17b5_screen.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17b5_screen.py) | 55 | 55 / 0 |
| added | [scripts/run_i17b_reverse_probe.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i17b_reverse_probe.py) | 88 | 88 / 0 |
| added | [scripts/run_i19.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i19.py) | 167 | 167 / 0 |
| added | [scripts/run_i19_cpu.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i19_cpu.py) | 55 | 55 / 0 |
| added | [scripts/run_i20_screen.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i20_screen.py) | 280 | 280 / 0 |
| added | [scripts/run_i21_publication.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i21_publication.py) | 142 | 142 / 0 |
| added | [scripts/run_i21_radix_queue.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i21_radix_queue.py) | 42 | 42 / 0 |
| added | [scripts/run_i22_ordered_short.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i22_ordered_short.py) | 90 | 90 / 0 |
| added | [scripts/run_i22_scope.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i22_scope.py) | 150 | 150 / 0 |
| added | [scripts/run_i22_short.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i22_short.py) | 86 | 86 / 0 |
| added | [scripts/run_i6_overlap_observation.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i6_overlap_observation.sh) | 96 | 96 / 0 |
| added | [scripts/run_i7_mutation_ablation.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i7_mutation_ablation.sh) | 35 | 35 / 0 |
| added | [scripts/run_i8_mutation_repeats.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i8_mutation_repeats.sh) | 90 | 90 / 0 |
| added | [scripts/run_i9_critical_path_audit.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_i9_critical_path_audit.sh) | 17 | 17 / 0 |
| added | [scripts/run_iter_b2_gpu_delete.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_iter_b2_gpu_delete.sh) | 112 | 112 / 0 |
| added | [scripts/run_performance_matrix_20260912.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_performance_matrix_20260912.py) | 116 | 116 / 0 |
| added | [scripts/run_stage_pre_i17c.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/run_stage_pre_i17c.py) | 537 | 537 / 0 |
| added | [scripts/start_stage_pre_i17c.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/start_stage_pre_i17c.py) | 40 | 40 / 0 |
| added | [scripts/temp_scripts/analyze_i17b5_continue.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/analyze_i17b5_continue.py) | 30 | 30 / 0 |
| added | [scripts/temp_scripts/e1a_edge_counter.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/e1a_edge_counter.cpp) | 57 | 57 / 0 |
| added | [scripts/temp_scripts/e1b_balanced_partition.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/e1b_balanced_partition.cpp) | 134 | 134 / 0 |
| added | [scripts/temp_scripts/e1b_metis_bipartition.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/e1b_metis_bipartition.cpp) | 97 | 97 / 0 |
| added | [scripts/temp_scripts/e1b_rcm_partitioner.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/e1b_rcm_partitioner.cpp) | 116 | 116 / 0 |
| added | [scripts/temp_scripts/make_e2_test_domain_map.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/make_e2_test_domain_map.cpp) | 22 | 22 / 0 |
| added | [scripts/temp_scripts/prepare_europe_symmetric_100k.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/prepare_europe_symmetric_100k.py) | 54 | 54 / 0 |
| added | [scripts/temp_scripts/run_e1a_topology_quota.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e1a_topology_quota.sh) | 31 | 31 / 0 |
| added | [scripts/temp_scripts/run_e1b_balanced_wiki.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e1b_balanced_wiki.sh) | 19 | 19 / 0 |
| added | [scripts/temp_scripts/run_e1b_bipartition_wiki.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e1b_bipartition_wiki.sh) | 19 | 19 / 0 |
| added | [scripts/temp_scripts/run_e1b_metis_cross_graph.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e1b_metis_cross_graph.sh) | 43 | 43 / 0 |
| added | [scripts/temp_scripts/run_e1b_metis_wiki.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e1b_metis_wiki.sh) | 28 | 28 / 0 |
| added | [scripts/temp_scripts/run_e1b_rcm_wiki.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e1b_rcm_wiki.sh) | 19 | 19 / 0 |
| added | [scripts/temp_scripts/run_e2_domain_smoke.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e2_domain_smoke.sh) | 57 | 57 / 0 |
| added | [scripts/temp_scripts/run_e2_fs_tw_correctness.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e2_fs_tw_correctness.sh) | 78 | 78 / 0 |
| added | [scripts/temp_scripts/run_e2_wiki_correctness.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e2_wiki_correctness.sh) | 49 | 49 / 0 |
| added | [scripts/temp_scripts/run_e3a_fs_tw_correctness.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e3a_fs_tw_correctness.sh) | 113 | 113 / 0 |
| added | [scripts/temp_scripts/run_e3b_async_cross_graph.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e3b_async_cross_graph.sh) | 55 | 55 / 0 |
| added | [scripts/temp_scripts/run_e4a2_cross_graph.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e4a2_cross_graph.sh) | 38 | 38 / 0 |
| added | [scripts/temp_scripts/run_e4r1_exact_source_gate.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_e4r1_exact_source_gate.sh) | 111 | 111 / 0 |
| added | [scripts/temp_scripts/run_europe_natural_init.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_europe_natural_init.sh) | 20 | 20 / 0 |
| added | [scripts/temp_scripts/run_f1c2_trace_v2.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_f1c2_trace_v2.sh) | 85 | 85 / 0 |
| added | [scripts/temp_scripts/run_i0_failure_prefixes.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_i0_failure_prefixes.sh) | 55 | 55 / 0 |
| added | [scripts/temp_scripts/run_i17b5_continue.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_i17b5_continue.py) | 86 | 86 / 0 |
| added | [scripts/temp_scripts/run_i2_six_graph_correctness.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_i2_six_graph_correctness.sh) | 86 | 86 / 0 |
| added | [scripts/temp_scripts/run_i3_current_baseline.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_i3_current_baseline.sh) | 39 | 39 / 0 |
| added | [scripts/temp_scripts/run_large_six_dataset_comparison.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_large_six_dataset_comparison.sh) | 180 | 180 / 0 |
| added | [scripts/temp_scripts/run_p0_cache_closeout.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_p0_cache_closeout.sh) | 44 | 44 / 0 |
| added | [scripts/temp_scripts/run_p1_europe_correctness.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_p1_europe_correctness.sh) | 20 | 20 / 0 |
| added | [scripts/temp_scripts/run_p2_lightweight_screening.sh](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/run_p2_lightweight_screening.sh) | 74 | 74 / 0 |
| added | [scripts/temp_scripts/select_europe_cohort_source.cpp](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/temp_scripts/select_europe_cohort_source.cpp) | 118 | 118 / 0 |
| added | [scripts/test_current_substages.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/test_current_substages.py) | 74 | 74 / 0 |
| added | [scripts/topology_cpu_quota.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/scripts/topology_cpu_quota.py) | 213 | 213 / 0 |
| added | [tools/summarize_coop_logs.py](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/tools/summarize_coop_logs.py) | 714 | 714 / 0 |
| modified | [CMakeLists.txt](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/CMakeLists.txt) | 272 | 198 / 11 |
| removed | [samples/hybrid_sssp/hybrid_sssp copy.cu](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/samples/hybrid_sssp/hybrid_sssp copy.cu) | 0 | 0 / 297 |

## 子报告完整覆盖

以下逐文件保留标题索引，用于检查历史子方向是否遗漏；正文结论仍须服从时间及源码优先级。

### [iteration/cggraph_cpu_gpu_dev_implementation_plan.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/cggraph_cpu_gpu_dev_implementation_plan.md)
内容 SHA256：`400e6ed5bb60e2e39da9de2e6ecfb0068938f7b3f20a3dd23add4286868b3f70`

- L1：C-GpuStreamGraph CPU-GPU 协同开发实施文档
- L11：当前权威状态（2026-09-17）
- L82：迭代论文索引
- L114：当前 I17 子任务的代码位置补充
- L123：动态工作区：当前状态、下一步与维护规则
- L129：迭代时间线与状态总表（截至 2026-09-05）
- L150：文档维护
- L154：I0—I15 已执行研发记录（历史）
- L158：I0：冻结证据并建立最小失败前缀（预计半天）
- L177：I1：跳过（历史）
- L181：I2：六图 correctness 封板（预计半天 GPU 调度 + 长任务时间）
- L191：I3：可信基线与决策数据重采（预计 1 天）
- L206：I4：touched-only hotness/candidate（预计 2--4 天）
- L212：I4-R：cache resident-set delta 原型（正确性通过，性能未通过）
- L216：I4-R1：回退归因与真实 delta 审计（已完成）
- L229：I4-R2：按证据收敛唯一 cache 实现（已否决）
- L242：I4-R3：轻量验收与代码裁决（已完成）
- L250：I5：source-local CPU topology mutation 多核化（已完成）
- L274：I6：已完成的合法 CPU/GPU overlap 审计（不进入实现）
- L292：I7：CPU topology mutation 首轮资源消融（已完成，研究 gate 待补）
- L305：I8：mutation 因果与重复性闭合（已完成）
- L325：I9：source-local mutation 关键路径边界审计（已完成）
- L341：I10：CPU/GPU topology 可见性与资源契约封板（已完成）
- L355：I11--I15 统一研究主线：源粒度事务化 mixed-batch 流水线
- L375：I11：最终态 repair 语义与可证伪模型（已完成）
- L391：I12：事务化 mixed-batch 核心实现（预计 3--5 天）
- L409：I12 之后的路线调整（2026-09-05）
- L429：I13：默认路径恢复与冗余事务代码清理（已完成）
- L447：I13 后工作量归因与队列修订（2026-09-06）
- L477：I14：统一有效更新批次与双向拓扑维护（已完成，保留）
- L503：I15：事件驱动的 hotness/candidate 维护（进行中：分数配对修正验收）
- L528：I16 历史状态
- L532：0. 最高优先级研发指令
- L555：1. 当前默认口径
- L570：2. 语义边界
- L594：3. 计时与正确性
- L619：4. Hot Cache 规则
- L635：5. 关键代码入口
- L650：6. 参数口径
- L674：7. 已验证结论
- L676：7.1 正向结论
- L699：7.2 Friendster 最新结论
- L721：7.3 负结果
- L732：8. 已形成的创新工作点
- L746：9. 当前主要问题
- L760：9.1 代码实现审查结论（2026-07-12）
- L776：9.2 结构性瓶颈，而非工程小优化
- L792：9.3 最新瓶颈重判与四轮对抗性分析（2026-08-17）
- L834：10. 完整研发时间线与后续方向
- L838：10.1--10.6 packet v1：机制验证、负结果与冻结（2026-07-09--11）
- L847：10.7 迭代七：从 packet 到双执行域的架构判定（2026-07-12）
- L865：10.8--10.9：seed frontier 暴露 deletion 契约缺口（2026-07-12--14）
- L881：10.9.4 端到端对照触发的二次重排（2026-07-14）
- L907：迭代 A：可信正确性与关键路径归因
- L915：迭代 B1：deletion 执行域判定与公平对照
- L921：迭代 B2：选定 deletion 路径的事件驱动稀疏化
- L927：迭代 B3：single-runtime insertion owner protocol 与并发证伪
- L935：迭代 C：CPU 权威更新与 GPU 拓扑发布（C1--C4，2026-07-27--28）
- L958：迭代 D：去除 C3 集成税的微调迭代
- L1016：迭代 E：边界感知的 CPU-GPU 双执行域增量闭包
- L1022：E0：冻结研究基线与机会空间
- L1046：E1：通用 topology-first 异构区域划分
- L1083：E2：建立 vertex-state ownership 与本地域完整闭包
- L1111：E3：异步双执行器与边界消息通道
- L1149：E4：消除执行粒度放大后再做结构 owner planner
- L1181：E4-R：基于A2负结果重排关键路径（2026-08-12）
- L1240：E5 历史裁决
- L1244：迭代 F：deletion sub-DAG 双执行域计算（已结束，2026-08-24）
- L1260：F0-L：TW/FS/EU 关键路径与可接管任务审计
- L1279：F1-C：deletion sub-DAG 可行性与唯一生死门
- L1332：F2—F4 取消记录
- L1336：F 失败后的转向（已执行）
- L1340：迭代 P：新基线收口与下一架构决策（2026-08-24 起）
- L1342：I4-R：resident-set delta cache（2026-08-25--26，负结果并已删除生产实现）
- L1354：P0：F1-C0 工程收口
- L1364：P1：Europe cohort 有效化
- L1370：P2：轻量关键路径画像
- L1378：11. 实验与验收要求
- L1380：11.1 研究假设
- L1394：12. 构建与运行模板
- L1443：13. 迭代执行记录与当前I24（I19—I23为历史）
- L1449：13.1 共用契约和模式边界
- L1461：13.2 通信量公平对照：显式账本 + 整组 PCIe 粗粒度观测（2026-09-15 修订）
- L1477：I19：规模与插删比例下的工作放大画像
- L1500：I20：大 batch 的统一权威变更维护
- L1512：I21：1M 批量准备与发布路径优化
- L1528：I22：1M通过后的10M迁移与100M延期验证
- L1549：I23：瓶颈驱动的批量分组构建（2026-09-16新增）
- L1556：I24：TW10M publication合并定向确认（2026-09-17）

### [iteration/subiteration_file/connected_road_dataset_generation.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/connected_road_dataset_generation.md)
内容 SHA256：`25075fe76eacbd6927a094b7cd32f6a74f663e4fa83a017f26e5cefe3d1f692a`

- L1：EU / USA 连通核心数据生成
- L5：目的与边界
- L11：算法
- L23：使用
- L50：校验与证据
- L58：实际规模

### [iteration/subiteration_file/expansion_bottleneck_assessment_20260916.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/expansion_bottleneck_assessment_20260916.md)
内容 SHA256：`383fa984fab3f41e7eb19e0d0cd416334859a0bc686c0ffe1a2704cb956985ce`

- L1：FS/TW扩展性瓶颈评估（2026-09-16）
- L3：结论
- L7：劣势来源
- L14：已否决与剩余机会
- L24：2026-09-17复核修正（优先于上文收口判断）

### [iteration/subiteration_file/fable5结论.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/fable5结论.md)
内容 SHA256：`dcbf4de0d48911925294d721e8ec04e48167230c20d6a465b90db7ac132a9378`


### [iteration/subiteration_file/final_system_sweep_20260916.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/final_system_sweep_20260916.md)
内容 SHA256：`289cfbcb4d3c902368008ad8e5e7e1fb14354fac6a412307647e2d169de10c76`

- L1：最后一轮系统并行度筛查（2026-09-16）
- L10：2026-09-17完成复核

### [iteration/subiteration_file/formal_experiment_optimization_plan_20260913.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/formal_experiment_optimization_plan_20260913.md)
内容 SHA256：`80ddec12221e2a61bc371cedf196364f5865e72c60053cb2e49db045ef710ecc`

- L1：2026-09-13 性能缺口记录与旧计划清理
- L5：原始缺口（历史三次运行中位数）
- L18：已完成后续证据

### [iteration/subiteration_file/i11_final_state_repair_semantics.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i11_final_state_repair_semantics.md)
内容 SHA256：`f010195a878ffea724e1b3136a1b073186f2970c42d5f00fbf4e6a2467cf94fe`

- L1：I11 Final-State Repair Semantics
- L3：Scope
- L20：Preconditions And Invariants
- L45：Why The Seed Set Is Complete
- L63：Epoch Fence
- L81：Oracle Evidence
- L90：Existing-Log Structural Bound
- L105：Decision

### [iteration/subiteration_file/i12_i10_baseline_manifest.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i12_i10_baseline_manifest.md)
内容 SHA256：`906e89ede1ef436d1f7f6809238a69254fd3f9021b833319fbc470f87570a204`

- L1：I12 Entry Baseline Manifest
- L9：Source And Build Identity
- L24：Entry Verification
- L39：Pre-I12 Working Tree
- L73：Frozen Performance Evidence

### [iteration/subiteration_file/i15_event_contract.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i15_event_contract.md)
内容 SHA256：`89b79a5930ed02bcca7d3e83f78130805d51ddc62bc75ce83b42e77a0da78cd2`

- L1：I15 hotness/candidate event contract
- L8：Sampling and window semantics
- L26：Authoritative Events
- L52：Candidate Oracle
- L79：Executable Model and Remaining Gate
- L103：Independent Index Screening

### [iteration/subiteration_file/i17b53_batch_reverse_screen.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b53_batch_reverse_screen.md)
内容 SHA256：`042ed1234dfff9ceb831613bf808f6fab76de5211ea0c477f4c4afc0b85f8da7`

- L1：B5.3 批量 reverse 首候选筛查
- L5：实现
- L11：两批结果
- L26：证据与后续

### [iteration/subiteration_file/i17b541_fs1000k_test.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b541_fs1000k_test.md)
内容 SHA256：`abfbe64530f567ade3de308e8d3bc75103938d1bf68ff52267ced0193979eee0`

- L1：B5.4.1 FS 1000k 实测

### [iteration/subiteration_file/i17b543_reverse_shards.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b543_reverse_shards.md)
内容 SHA256：`c77e96353a53c473bfdbab2a3a0d04016031097711b0a2c97de8b53e9709030e`

- L1：I17-B5.4.3：reverse 分项归因与 destination 分片（定向验证完成）
- L17：输入与编译口径更正
- L23：候选
- L31：观测契约
- L35：验证与结果
- L41：本轮单 map 分项实测
- L54：64 分片两批筛查
- L60：同二进制十批对照：1/64 分片、精确扩容
- L81：几何扩容补充候选（实测完成，不保留运行时分支）
- L87：后续瓶颈边界
- L95：FS 1000k 真实正确性检查
- L101：FS 100k 固定开销与规模比例
- L114：Twitter 与小 batch 边界
- L120：本轮裁决与剩余工作

### [iteration/subiteration_file/i17b54_attribution_20260910.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b54_attribution_20260910.md)
内容 SHA256：`f3685d53da39303607d662e9b9fd92e4aec0598baf8eac2e20e3a671dfe168ec`

- L1：I17-B5.4.0 性能损失归因

### [iteration/subiteration_file/i17b5_incoming_source_order_20260914.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b5_incoming_source_order_20260914.md)
内容 SHA256：`146537bb5130fc502648432757546589553b3096989f010b08f67fdc3001a3b5`

- L1：I17-B5：复用 source 顺序与并行 incoming 物化（2026-09-14）
- L3：范围和依据
- L9：本轮候选
- L16：验证与实验状态
- L28：追加候选：warp incoming min-plus 归约
- L36：NUMA 混杂与对照修订
- L42：最终候选同 NUMA 单次开发配对
- L62：最终正确性与保留裁决
- L68：重复确认、收尾和下一步
- L78：口径补充

### [iteration/subiteration_file/i17b5_workspace_screen.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b5_workspace_screen.md)
内容 SHA256：`dc0c28b6a77a4f40f5a0d90fcc474986280e085705b65678a95721bf45aeb28c`

- L1：I17-B5.1 workspace screening
- L6：Protocol
- L23：Results
- L47：Evidence and Disposition

### [iteration/subiteration_file/i17b6_completed_analysis.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b6_completed_analysis.md)
内容 SHA256：`2e8bb79105e0bd1b30b46a0acbb474e76de15ea188773f60383671ad1df61154`

- L1：I17-B6 完成结果复核与必要补测
- L18：Twitter 结论撤回与纠正
- L24：失败与补测裁决

### [iteration/subiteration_file/i17b6_scaling_ordered.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b6_scaling_ordered.md)
内容 SHA256：`d66bc63ab8c600d0be7643515f730dbe985b21079bc3f3b90c6ea3edec40bddb`

- L1：I17-B6 大 batch 与运行时 ordered 短测（2026-09-11）
- L5：数据口径
- L14：实现与边界
- L22：验证与实验
- L32：查看

### [iteration/subiteration_file/i17b7_b5_progress_20260914.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b7_b5_progress_20260914.md)
内容 SHA256：`98d223075fe2ceb139524a27c2ff37cbc065d97c5f07bce7b1b00f6ce524c407`

- L1：I17-B7 / B5 开发记录（2026-09-14）
- L5：B7：显式拷贝 payload 计量接口
- L19：B5：稀疏 mutation 统计空间精简（否决并撤回）
- L35：B5：稳定 radix mixed-source grouping（保留，局部开发改善）

### [iteration/subiteration_file/i17b_gpu_cost_results.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i17b_gpu_cost_results.md)
内容 SHA256：`77093563825ace556c7e3e1923d3a7e566232ac9a068ac6451413c255b27a4c4`

- L1：I17-B：GPU 长传播成本优化收口
- L5：实验口径
- L14：最终配对
- L31：子步骤裁决
- L47：正确性与容量
- L57：复现与下一步

### [iteration/subiteration_file/i19_complete_results_20260915.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i19_complete_results_20260915.md)
内容 SHA256：`896ff89aacb6c19d42513c4ba05075b41ad358b172d11ef2f5b6cecb6a6ee7a8`

- L1：I19 完整结果与机制裁决（2026-09-15）
- L7：固定 100K 比例完整结果
- L31：规模轴与剩余瓶颈
- L48：工作放大与候选裁决
- L62：传输量与验收边界

### [iteration/subiteration_file/i19_profile_tables_20260915.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i19_profile_tables_20260915.md)
内容 SHA256：`0abccd437e5dfa3abce4c31f8417464fa29b19534e0df38b7bcd31f0475a9994`

- L1：I19 画像表（自动生成）
- L33：比例 × 完整阶段（十批合计）
- L56：规模 × 阶段（现有 cohort，同一 I19 二进制，各两批）

### [iteration/subiteration_file/i19_ratio_data_20260914.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i19_ratio_data_20260914.md)
内容 SHA256：`2a6da7aff4c02f67e0d32448aab7f718ea5e6bb4e6a31a4de78f3d7b601d9d5c`

- L1：I19 正式数据验收（共享 occurrence 排名）

### [iteration/subiteration_file/i19_work_amplification_20260914.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i19_work_amplification_20260914.md)
内容 SHA256：`5a950cec4ba0aaa184d5f75ae7f237c76138cab94665e96e20872a2dc3d71f31`

- L1：I19：规模与插删比例下的工作放大画像
- L5：问题与方法
- L11：采样审计与一次修订
- L23：观测口径和代码位置
- L36：验证和当前进展
- L47：CPU 比例画像已完成（正式 v2）
- L63：后台队列恢复

### [iteration/subiteration_file/i20_shared_plan_20260915.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i20_shared_plan_20260915.md)
内容 SHA256：`b4cee97f3961126753d87a0a745655b81a7e66326ab4c5c61c5cac82d891d4f7`

- L1：I20 共享 source 规划与有效变更候选（2026-09-15）
- L5：机制与范围
- L16：验证与计量
- L24：原长队列设计（已取消，不作为当前待办）
- L34：后台执行记录
- L40：用户要求缩短后的当前计划
- L54：短筛查结果与反向确认
- L74：反向配对审阅结论（2026-09-15）
- L91：后续用户指令覆盖（2026-09-15）

### [iteration/subiteration_file/i21_delete_positions_20260915.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i21_delete_positions_20260915.md)
内容 SHA256：`39b8af43ca11ae43023315c9e6c800b313ea8ff69014d3845f4f164d78a3fe36`

- L1：I21 删除位置复用与连续存活区间搬移（2026-09-15）
- L5：为什么调整原先预想
- L11：实现与成本契约
- L21：已完成的验证
- L27：短筛查与裁决
- L49：完成结果与裁决

### [iteration/subiteration_file/i21_publication_1m_20260916.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i21_publication_1m_20260916.md)
内容 SHA256：`9fad856cc0ee338f913d2812af51dfae43d721e5fb799aa652a3275ba5d77184`

- L1：I21 候选A：1M publication source有序合并
- L3：范围与实现
- L11：验证
- L19：后台1M配对
- L27：A结果与后续裁决

### [iteration/subiteration_file/i21_radix_tw_20260916.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i21_radix_tw_20260916.md)
内容 SHA256：`9297552a0eaf3018259247ea21ca4ea4f57a5b2c7252675b698e370b431897ee`

- L1：I21 A+B：TW 1M优先、条件性10M
- L3：决策变化
- L7：实现
- L13：验证
- L19：后台队列
- L30：完成裁决与后继

### [iteration/subiteration_file/i22_cggraph_scheduling_20260915.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i22_cggraph_scheduling_20260915.md)
内容 SHA256：`443fe2bf92b41068a8badf8074134aa52aa92c80b4aa40fbf8ac3c835002e42c`

- L1：I22 与 CGgraph 算法、架构、调度机制复核（2026-09-15）
- L5：原始证据与源码版本区别
- L17：四目标的机制适用性与执行顺序
- L33：当前已实现：低度source线程调度
- L41：当前短实验
- L55：首个调度候选结果与裁决

### [iteration/subiteration_file/i22_ordered_insertion_20260916.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i22_ordered_insertion_20260916.md)
内容 SHA256：`7729abd5aec1625b7db7e847ac5a602366e570f2d778b2f51383dbc9f50a09fa`

- L1：I22 GPU 插入距离区间闭包（2026-09-16）
- L3：范围与依据
- L9：实现与正确性契约
- L15：验证与实验状态
- L23：首次失败定位
- L27：修复后验证和后台交付
- L38：两批短配对结果与裁决（2026-09-16）
- L57：用户授权的适用范围后台筛查（2026-09-16）
- L66：适用范围筛查结果与整合裁决（2026-09-16）
- L92：大直径模式首次默认绑定（历史接线，已由下方优先级修订替代）
- L108：模式绑定核验结果
- L115：最终模式优先级：无需手动unset（2026-09-16）

### [iteration/subiteration_file/i23_bulk_groups_20260916.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i23_bulk_groups_20260916.md)
内容 SHA256：`800259c5494f77bc330216cbb2f09f135e2d92ba3592702501cd8989ae2162cd`

- L1：I23：TW批量source分组构建，1M瓶颈驱动的三配置消融
- L3：来由与现有结果
- L21：新机制
- L34：CPU实测与验证
- L52：后台完整消融与10M准入
- L67：2026-09-17最终裁决（覆盖上文运行中状态）

### [iteration/subiteration_file/i24_tw10m_publication_20260917.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i24_tw10m_publication_20260917.md)
内容 SHA256：`635e891f758dbaaeb0fbe61b57e702021b7bc6c47951066ee41db4f0d780c0aa`

- L1：I24：TW 10M publication合并定向确认
- L5：1. 已知事实与历史纠错
- L20：2. 问题与可证伪假设
- L30：3. 固定实验与资源
- L51：4. 验收与止损
- L59：5. 交付
- L63：6. 本轮执行记录（2026-09-17）
- L74：7. 四次配对完成与结果复核（2026-09-17）

### [iteration/subiteration_file/i25_reverse_radix_20260917.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/i25_reverse_radix_20260917.md)
内容 SHA256：`43819bd50a43edfd46ad66b8a0fe3e82e91296a70823291bf5bb8756e3dfd562`

- L1：I25：TW10M reverse准备并行化，检验能否与历史原版拉开距离
- L5：1. 本轮授权与目标
- L11：2. 当前瓶颈与路线选择
- L32：3. 实现与边界
- L38：4. 验证和后台实验
- L47：5. 裁决与止损
- L57：6. 完整结果与裁决

### [iteration/subiteration_file/paper_plan_and_research_directions.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/paper_plan_and_research_directions.md)
内容 SHA256：`7290537971879ad2fc1e6a6b0fcbef75f71f605e65d8074410d939e44c064b58`

- L1：论文规划与后续研究方向
- L8：第一部分：后续优化方向（均为论文级贡献）
- L10：方向 A：事务化 Mixed-Batch Topology Construction（I12，已验证语义但性能否决）
- L31：方向 B：高直径图的 GPU-Efficient Deletion Repair（新发现）
- L62：方向 C：Hotness/Candidate 增量维护
- L76：方向 D：更大 Batch Size 下的 Scalability
- L89：方向 E：外部系统对照（I15，论文必须项）
- L101：第二部分：论文组织结构
- L103：论文定位
- L116：论文章节结构（建议）
- L118：一、Introduction（约 1.5 页）
- L140：二、Background and Motivation（约 2 页）
- L167：三、System Design：Data Organization（约 3 页）
- L207：四、System Design：Incremental Computation（约 3 页）
- L248：五、Evaluation（约 3 页）
- L292：六、Related Work（约 1 页）
- L305：七、Conclusion（约 0.5 页）
- L314：第三部分：近期写作优先级
- L316：Introduction 写作要点
- L322：Background 写作要点
- L326：Method 章节写作要点
- L334：附：已冻结的硬约束（写论文时不要违反）

### [iteration/subiteration_file/performance_matrix_20260912.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/performance_matrix_20260912.md)
内容 SHA256：`d65ca730a1f8e42fbe470c1f4bbee0fdb31d0e9c4df0e4997b058ffa2677d298`

- L1：2026-09-12 完整 SSSP 性能矩阵
- L7：公平性审计
- L17：模式与选择
- L25：数据与实验
- L35：查看与恢复
- L53：启动观察

### [iteration/subiteration_file/performance_matrix_20260912_analysis/tables.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/performance_matrix_20260912_analysis/tables.md)
内容 SHA256：`3a3c5721c2fd945a25ad80520e4d0e12f679ac4388e7205fac10c7d9f3f62af4`

- L1：2026-09-12 性能矩阵数据复核

### [iteration/subiteration_file/performance_matrix_20260912_review.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/performance_matrix_20260912_review.md)
内容 SHA256：`f770fe6c42f4cf772229adc2bf44742257fcafdc64fbf94134dd324181ad071c`

- L1：2026-09-13 完整性能矩阵复核与后续实验建议
- L5：1. 实验完成了，但跨系统加速结论没有通过
- L15：2. 指纹问题：已证实的事实与尚待定位的原因
- L30：3. 性能反映的三个机制问题
- L32：3.1 路网：删除优化把矛盾转移到了插入
- L44：3.2 社交图大批：不能用路网插入方案统一解释
- L52：3.3 小批：固定缓存维护成本成为下限
- L58：4. 模式边界、失败与容量结论
- L77：5. 建议调整后的短实验队列（尚未启动）

### [iteration/subiteration_file/pre_i17c_stage_matrix.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/pre_i17c_stage_matrix.md)
内容 SHA256：`50a37ab7e1071d94838c918502b5cd55da2b547e19b3e3cb7232ed3e3c3b96fb`

- L1：I17-C 前阶段性大矩阵
- L7：后台入口
- L29：数据矩阵
- L50：公平口径与参数
- L66：性能与正确性
- L74：两项瓶颈实验
- L81：启动验证

### [iteration/subiteration_file/scaling_feasibility_10m_100m_20260916.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/scaling_feasibility_10m_100m_20260916.md)
内容 SHA256：`496da595abc072ae6663300f59e39c49fd3a3cf1af4b957d2911278e72dc36a0`

- L1：FS/TW 10M、100M 扩展性优化可行性复核（2026-09-16）
- L5：结论与证据等级
- L12：1. 当前10M到底差多少
- L23：2. 重新分解近期成本
- L49：3. 本轮实跑的机制实验
- L53：3.1 稳定并行source radix
- L68：3.2 publication source列表的线性合并
- L79：3.3 对胜出机会的含义
- L88：4. 100M的机会、容量和数据边界
- L90：4.1 为何仍可能有算法优势
- L96：4.2 publication显存是具体风险
- L105：4.3 主存不是本机首要硬容量限制，但布局仍影响时间
- L113：4.4 100M不是仅把10M时间乘十
- L119：5. 建议的最小继续投入范围

### [iteration/subiteration_file/system_review_20260912.md](/home/wangshaoyan/proJect/C-GpuStreamGraph-CG/iteration/subiteration_file/system_review_20260912.md)
内容 SHA256：`4c5ad53115d13073fdff2eb9feec498fe5643dd272ad4546064f723485740fe6`

- L1：系统与后续迭代复核（2026-09-12）
- L7：1. 当前系统定位
- L17：2. 近期实验的有效结论
- L42：3. 需要修订的实施安排
- L44：3.1 I17-C 的“完成”超过已展示证据
- L52：3.2 插入已有普通去重与设备端循环
- L60：3.3 显存问题应先处理生命周期，再判断表示替换
- L70：3.4 parent 应成为独立契约项
- L80：3.5 长传播有显式容量边界
- L86：4. 建议的新队列
- L100：5. 实验方法的最低补强
- L109：6. 文档与论文安排
- L117：证据入口
