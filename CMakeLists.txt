cmake_minimum_required(VERSION 2.8)
add_definitions(-w)
# project(SEP-Graph)
project(SEP-Graph LANGUAGES CUDA CXX)
enable_testing()
add_executable(road_source_scan src/road_source_scan.cpp)
add_test(NAME road_source_scan_test
    COMMAND python3 ${PROJECT_SOURCE_DIR}/tests/road_source_scan_test.py $<TARGET_FILE:road_source_scan>)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
############## DEPENDENCIES ##############
find_package(CUDA 9 REQUIRED)

message("-- CUDA Version: ${CUDA_VERSION_STRING}")

# GFlags
add_subdirectory(deps/gflags)
include_directories(${PROJECT_BINARY_DIR}/deps/gflags/include)
link_directories(${PROJECT_BINARY_DIR}/deps/gflags/lib)

# CUB
# include_directories(${PROJECT_SOURCE_DIR}/deps/cub)

# JSON
include_directories(${PROJECT_SOURCE_DIR}/deps/json)
add_executable(connected_road_generator src/connected_road_generator.cpp)
add_executable(i16_repair_oracle src/i16_repair_oracle.cpp)
target_include_directories(i16_repair_oracle PRIVATE ${PROJECT_SOURCE_DIR}/include)
add_test(NAME i16_repair_oracle_test COMMAND python3 ${PROJECT_SOURCE_DIR}/tests/i16_repair_oracle_test.py $<TARGET_FILE:i16_repair_oracle>)
add_executable(verify_connected_road_dataset src/verify_connected_road_dataset.cpp)
add_test(NAME connected_road_generator_test
    COMMAND python3 ${PROJECT_SOURCE_DIR}/tests/connected_road_generator_test.py
        $<TARGET_FILE:connected_road_generator> $<TARGET_FILE:verify_connected_road_dataset>)

include_directories(${PROJECT_SOURCE_DIR}/deps/SlabHash/src)
include_directories(${PROJECT_SOURCE_DIR}/deps//SlabHash/SlabAlloc/src)

# # # STDGPU
set(STDGPU_BUILD_EXAMPLES OFF CACHE INTERNAL "")
set(STDGPU_BUILD_BENCHMARKS OFF CACHE INTERNAL "")
set(STDGPU_BUILD_TESTS OFF CACHE INTERNAL "")

add_subdirectory(deps/stdgpu)
include_directories(${PROJECT_BINARY_DIR}/deps/stdgpu/bin/include)
link_directories(${PROJECT_BINARY_DIR}/deps/stdgpu/bin/lib)
set_property(TARGET stdgpu PROPERTY CMAKE_CUDA_SEPARABLE_COMPILATION ON)
set_property(TARGET stdgpu PROPERTY CUDA_ARCHITECTURES 70)
############## BUILD ##############

set(EXTRA_LIBS stdgpu gflags pthread ${CUDA_TOOLKIT_TARGET_DIR}/lib64/stubs/libcuda.so ${CUDA_TOOLKIT_TARGET_DIR}/lib64/libnvToolsExt.so)

if (CMAKE_BUILD_TYPE STREQUAL "Debug")
    message("Debug mode")
    set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS};-gencode;arch=compute_70,code=sm_70;-g;-lineinfo;-Xcompiler;-ggdb;-std=c++17 -O3)
else ()
     set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS};-gencode;arch=compute_70,code=sm_70;-O3;-DNDEBUG;-Xcompiler;-DNDEBUG;-std=c++17 -O3)
endif ()

set(CUDA_PROPAGATE_HOST_FLAGS OFF)

# Addresses a bug where code is not compiled as C++11 in non-CUDA code and older g++ versions
# set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++11 -O3 -DNDEBUG")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++17 -O3 -DNDEBUG")
message("-- Host Compiler: ${CUDA_HOST_COMPILER}")

include_directories(${PROJECT_SOURCE_DIR} ${PROJECT_SOURCE_DIR}/include)

# hybrid apps
cuda_add_executable(hybrid_pr src/utils/parser.cpp src/utils/utils.cpp src/utils/to_json.cpp #src/groute/graphs/csr_graph.cpp
       samples/hybrid_pr/hybrid_pr.cu
       samples/hybrid_pr/hybrid_pr_host.cu
       samples/hybrid_pr/main.cu)
target_link_libraries(hybrid_pr ${EXTRA_LIBS} pthread)


cuda_add_executable(hybrid_bfs src/utils/parser.cpp src/utils/utils.cpp src/utils/to_json.cpp #src/groute/graphs/csr_graph.cpp
        samples/hybrid_bfs/hybrid_bfs.cu
        samples/hybrid_bfs/hybrid_bfs_host.cu
        samples/hybrid_bfs/main.cu)
target_link_libraries(hybrid_bfs ${EXTRA_LIBS} pthread)
target_sources(hybrid_bfs PRIVATE src/utils/communication_meter.cpp)
target_include_directories(hybrid_bfs PRIVATE ${CUDA_INCLUDE_DIRS})
set_property(TARGET hybrid_bfs APPEND_STRING PROPERTY LINK_FLAGS
    " -Wl,--wrap=cudaMemcpy -Wl,--wrap=cudaMemcpyAsync")
#$target_compile_definitions(hybrid_bfs PUBLIC ARRAY_BITMAP)

cuda_add_executable(hybrid_sssp src/utils/parser.cpp src/utils/utils.cpp src/utils/to_json.cpp #src/groute/graphs/csr_graph.cpp
        samples/hybrid_sssp/hybrid_sssp.cu
       samples/hybrid_sssp/hybrid_sssp_host.cu
        samples/hybrid_sssp/main.cu)
target_link_libraries(hybrid_sssp ${EXTRA_LIBS} pthread)
target_sources(hybrid_sssp PRIVATE src/utils/communication_meter.cpp)
target_include_directories(hybrid_sssp PRIVATE ${CUDA_INCLUDE_DIRS})
set_property(TARGET hybrid_sssp APPEND_STRING PROPERTY LINK_FLAGS
    " -Wl,--wrap=cudaMemcpy -Wl,--wrap=cudaMemcpyAsync")
add_executable(communication_meter_test tests/communication_meter_test.cpp src/utils/communication_meter.cpp)
target_include_directories(communication_meter_test PRIVATE ${CUDA_INCLUDE_DIRS})
add_test(NAME communication_meter_test COMMAND communication_meter_test)
add_test(NAME communication_meter_disabled_test COMMAND communication_meter_test disabled)
add_executable(grouped_update_batch_test tests/grouped_update_batch_test.cpp)
add_test(NAME grouped_update_batch_test COMMAND grouped_update_batch_test)

cuda_add_executable(hybrid_cc src/utils/parser.cpp src/utils/utils.cpp src/utils/to_json.cpp #src/groute/graphs/csr_graph.cpp
        samples/hybrid_cc/hybrid_cc.cu
        samples/hybrid_cc/hybrid_cc_host.cu
        samples/hybrid_cc/main.cu)
target_link_libraries(hybrid_cc ${EXTRA_LIBS} pthread)
target_sources(hybrid_cc PRIVATE src/utils/communication_meter.cpp)
target_include_directories(hybrid_cc PRIVATE ${CUDA_INCLUDE_DIRS})
set_property(TARGET hybrid_cc APPEND_STRING PROPERTY LINK_FLAGS
    " -Wl,--wrap=cudaMemcpy -Wl,--wrap=cudaMemcpyAsync")

add_executable(gtools src/utils/parser.cpp src/utils/utils.cpp
        samples/tools/gtools.cpp)
target_link_libraries(gtools gflags)

add_executable(topology_replay src/topology_replay.cpp)
add_test(
    NAME topology_replay_fixture
    COMMAND topology_replay
        --graph ${PROJECT_SOURCE_DIR}/tests/fixtures/topology_replay_graph.txt
        --updates ${PROJECT_SOURCE_DIR}/tests/fixtures/topology_replay_updates.txt
        --batch-sizes ${PROJECT_SOURCE_DIR}/tests/fixtures/topology_replay_batch_sizes.txt)
set_tests_properties(
    topology_replay_fixture
    PROPERTIES PASS_REGULAR_EXPRESSION
        "batch=1 additions=1 deletions=1 touched_sources=2 changed_sources=1 missing_deletes=1 invalid_additions=0 graph_edges=6")

add_executable(topology_contract_test tests/topology_contract_test.cpp)
set_source_files_properties(tests/topology_contract_test.cpp PROPERTIES LANGUAGE CUDA)
target_link_libraries(topology_contract_test ${CUDA_TOOLKIT_TARGET_DIR}/lib64/stubs/libcuda.so)
add_test(NAME topology_contract_test COMMAND topology_contract_test)

add_executable(cache_patch_trace_test tests/cache_patch_trace_test.cpp)
add_test(NAME cache_patch_trace_test COMMAND cache_patch_trace_test)

add_executable(cache_refresh_gate_test tests/cache_refresh_gate_test.cpp)
add_test(NAME cache_refresh_gate_test COMMAND cache_refresh_gate_test)

add_executable(cache_tail_fallback_test tests/cache_tail_fallback_test.cu)
set_source_files_properties(tests/cache_tail_fallback_test.cu PROPERTIES LANGUAGE CUDA)
target_link_libraries(cache_tail_fallback_test ${CUDA_TOOLKIT_TARGET_DIR}/lib64/stubs/libcuda.so)
add_test(NAME cache_tail_fallback_test COMMAND cache_tail_fallback_test)

add_executable(cache_patch_replay src/cache_patch_replay.cpp)

add_executable(affected_component_trace_test tests/affected_component_trace_test.cpp)
add_test(NAME affected_component_trace_test COMMAND affected_component_trace_test)

add_executable(f1_replay_state_test tests/f1_replay_state_test.cpp)
add_test(NAME f1_replay_state_test COMMAND f1_replay_state_test)

add_executable(affected_component_analyzer src/affected_component_analyzer.cpp)
add_test(NAME affected_component_analyzer_fixture
         COMMAND affected_component_analyzer --self-test)
set_tests_properties(
    affected_component_analyzer_fixture
    PROPERTIES PASS_REGULAR_EXPRESSION
        "d0_vertices=3 d0_scc=3 d0_sinks=1 d0_incoming=6 d0_internal=2 d0_snapshot_boundary_edges=4 d0_snapshot_boundary_sources=2 d0_changed_boundary_sources=1 d0_changed_boundary_events=1 d0_outgoing=3")
add_test(NAME affected_component_successor_audit_fixture
         COMMAND affected_component_analyzer --self-test)
set_tests_properties(
    affected_component_successor_audit_fixture
    PROPERTIES PASS_REGULAR_EXPRESSION
        "d1_successor_cut_edges=1 d1_successor_cut_sources=1 d1_successor_cut_destinations=1.*d1_dependent_gpu_vertices=1.*d1_cpu_critical_path_depth=2.*d1_independent_gpu_critical_path_depth=1.*d1_dependent_gpu_critical_path_depth=1")

cuda_add_executable(f1_crossover_replay src/f1_crossover_replay.cu)
cuda_add_executable(i16_frontier_replay src/i16_frontier_replay.cu)
target_link_libraries(i16_frontier_replay ${CUDA_LIBRARIES})
target_link_libraries(f1_crossover_replay ${CUDA_LIBRARIES} pthread)

add_executable(chunk_store_replay src/chunk_store_replay.cpp)
target_link_libraries(chunk_store_replay ${CUDA_LIBRARIES})
add_test(
    NAME chunk_store_replay_fixture
    COMMAND chunk_store_replay
        --graph ${PROJECT_SOURCE_DIR}/tests/fixtures/topology_replay_graph.txt
        --updates ${PROJECT_SOURCE_DIR}/tests/fixtures/topology_replay_updates.txt
        --batch-sizes ${PROJECT_SOURCE_DIR}/tests/fixtures/topology_replay_batch_sizes.txt
        --pageable)
set_tests_properties(
    chunk_store_replay_fixture
    PROPERTIES PASS_REGULAR_EXPRESSION
        "batch=1.*topology_mismatches=0 isolation_violations=0 graph_edges=6 oracle_edges=6")

add_executable(source_local_chunk_store_test tests/source_local_chunk_store_test.cpp)
target_link_libraries(source_local_chunk_store_test ${CUDA_LIBRARIES} pthread)
add_test(NAME source_local_chunk_store_test COMMAND source_local_chunk_store_test)

add_executable(dual_domain_event_runtime_test tests/dual_domain_event_runtime_test.cpp)
target_link_libraries(dual_domain_event_runtime_test pthread)
add_test(NAME dual_domain_event_runtime_test COMMAND dual_domain_event_runtime_test)

add_executable(persistent_dependency_graph_test tests/persistent_dependency_graph_test.cpp)
add_test(NAME persistent_dependency_graph_test COMMAND persistent_dependency_graph_test)

add_executable(destination_local_dependency_store_test
    tests/destination_local_dependency_store_test.cpp)
target_link_libraries(destination_local_dependency_store_test ${CUDA_LIBRARIES})
add_test(NAME destination_local_dependency_store_test
    COMMAND destination_local_dependency_store_test)

add_executable(dynamic_reverse_index_test tests/dynamic_reverse_index_test.cpp)
target_link_libraries(dynamic_reverse_index_test ${CUDA_LIBRARIES} pthread)
add_test(NAME dynamic_reverse_index_test COMMAND dynamic_reverse_index_test)

cuda_add_executable(hotness_pairing_test tests/hotness_pairing_test.cu)
target_link_libraries(hotness_pairing_test ${CUDA_LIBRARIES} stdgpu gflags)
add_test(NAME hotness_pairing_test COMMAND hotness_pairing_test)

add_executable(hotness_event_model_test tests/hotness_event_model_test.cpp)
add_test(NAME hotness_event_model_test COMMAND hotness_event_model_test)

add_executable(weighted_score_index_test tests/weighted_score_index_test.cpp)
add_test(NAME weighted_score_index_test COMMAND weighted_score_index_test)
add_executable(hotness_candidate_replay src/hotness_candidate_replay.cpp)
add_executable(hotness_trace_test tests/hotness_trace_test.cpp)
add_test(NAME hotness_trace_test COMMAND hotness_trace_test ${PROJECT_BINARY_DIR}/i15_trace_fixture.bin)
set_tests_properties(hotness_trace_test PROPERTIES FIXTURES_SETUP i15_trace)
add_test(NAME hotness_candidate_replay_fixture
    COMMAND hotness_candidate_replay ${PROJECT_BINARY_DIR}/i15_trace_fixture.bin)
set_tests_properties(hotness_candidate_replay_fixture PROPERTIES
    FIXTURES_REQUIRED i15_trace PASS_REGULAR_EXPRESSION "I15-INDEX-TOTAL.*batches=4.*mismatches=0")

add_executable(final_state_repair_model_test
    tests/final_state_repair_model_test.cpp)
add_test(NAME final_state_repair_model_test
    COMMAND final_state_repair_model_test)

add_executable(owner_cost_planner_test tests/owner_cost_planner_test.cpp)
add_test(NAME owner_cost_planner_test COMMAND owner_cost_planner_test)

cuda_add_executable(dependency_warp_mapping_test
    tests/dependency_warp_mapping_test.cu)
target_link_libraries(dependency_warp_mapping_test ${CUDA_LIBRARIES})
add_test(NAME dependency_warp_mapping_test COMMAND dependency_warp_mapping_test)

add_executable(exact_source_frontier_test tests/exact_source_frontier_test.cpp)
add_test(NAME exact_source_frontier_test COMMAND exact_source_frontier_test)

cuda_add_executable(exact_source_executor_test tests/exact_source_executor_test.cu)
target_link_libraries(exact_source_executor_test ${CUDA_LIBRARIES})
add_test(NAME exact_source_executor_test COMMAND exact_source_executor_test)

cuda_add_executable(owner_planner_calibration tests/owner_planner_calibration.cu)
target_link_libraries(owner_planner_calibration ${CUDA_LIBRARIES})
add_test(NAME owner_planner_shadow_fixture
    COMMAND python3 ${PROJECT_SOURCE_DIR}/scripts/evaluate_e4r3_shadow.py
        --calibration ${PROJECT_SOURCE_DIR}/tests/fixtures/owner_planner_calibration.tsv
        --topology ${PROJECT_SOURCE_DIR}/tests/fixtures/owner_planner_topology.tsv
        --work ${PROJECT_SOURCE_DIR}/tests/fixtures/owner_planner_work.tsv
        --dataset fixture
        --output ${PROJECT_BINARY_DIR}/owner_planner_shadow_fixture.tsv)
set_tests_properties(owner_planner_shadow_fixture PROPERTIES
    PASS_REGULAR_EXPRESSION "")
add_test(NAME owner_planner_shadow_decision
    COMMAND python3 ${PROJECT_SOURCE_DIR}/tests/check_owner_planner_decision.py
        ${PROJECT_BINARY_DIR}/owner_planner_shadow_fixture.tsv.decision full)

cuda_add_executable(i17a_delta_replay src/i17a_delta_replay.cu)
target_link_libraries(i17a_delta_replay ${CUDA_LIBRARIES})

# I19: CPU-only ratio generation and production topology preparation replay.
add_executable(i19_ratio_pool src/i19_ratio_pool.cpp)
add_executable(i19_topology_replay src/i19_topology_replay.cpp)
target_link_libraries(i19_topology_replay ${CUDA_LIBRARIES} pthread)
add_test(NAME i19_ratios_test COMMAND python3 ${PROJECT_SOURCE_DIR}/tests/i19_ratios_test.py
    $<TARGET_FILE:i19_ratio_pool> $<TARGET_FILE:i19_topology_replay>)
add_executable(i19_loader_test tests/i19_loader_test.cpp)
target_link_libraries(i19_loader_test ${CUDA_LIBRARIES})
add_test(NAME i19_loader_test COMMAND i19_loader_test ${PROJECT_BINARY_DIR}/i19_loader_sizes.txt)
add_executable(i19_work_metrics_test tests/i19_work_metrics_test.cpp)
target_link_libraries(i19_work_metrics_test ${CUDA_LIBRARIES} pthread)
add_test(NAME i19_work_metrics_test COMMAND i19_work_metrics_test)

add_executable(publication_sources_test tests/publication_sources_test.cpp)
add_test(NAME publication_sources_test COMMAND publication_sources_test)

add_executable(i23_group_replay src/i23_group_replay.cpp)
target_link_libraries(i23_group_replay pthread)

cuda_add_executable(cc_sampled_repair_test tests/cc_sampled_repair_test.cu)
target_link_libraries(cc_sampled_repair_test ${CUDA_LIBRARIES})
add_test(NAME cc_sampled_repair_test COMMAND cc_sampled_repair_test)
