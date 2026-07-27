cmake_minimum_required(VERSION 2.8)
add_definitions(-w)
# project(SEP-Graph)
project(SEP-Graph LANGUAGES CUDA CXX)
enable_testing()
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

set_source_files_properties(samples/hybrid_bfs/hybrid_bfs_host.cpp PROPERTIES LANGUAGE CUDA)

cuda_add_executable(hybrid_bfs src/utils/parser.cpp src/utils/utils.cpp src/utils/to_json.cpp #src/groute/graphs/csr_graph.cpp
        samples/hybrid_bfs/hybrid_bfs.cu
        samples/hybrid_bfs/hybrid_bfs_host.cpp
        samples/hybrid_bfs/main.cpp)
target_link_libraries(hybrid_bfs ${EXTRA_LIBS} pthread)
#$target_compile_definitions(hybrid_bfs PUBLIC ARRAY_BITMAP)

cuda_add_executable(hybrid_sssp src/utils/parser.cpp src/utils/utils.cpp src/utils/to_json.cpp #src/groute/graphs/csr_graph.cpp
        samples/hybrid_sssp/hybrid_sssp.cu
       samples/hybrid_sssp/hybrid_sssp_host.cu
        samples/hybrid_sssp/main.cu)
target_link_libraries(hybrid_sssp ${EXTRA_LIBS} pthread)

cuda_add_executable(hybrid_cc src/utils/parser.cpp src/utils/utils.cpp src/utils/to_json.cpp #src/groute/graphs/csr_graph.cpp
        samples/hybrid_cc/hybrid_cc.cu
        samples/hybrid_cc/main.cu)
target_link_libraries(hybrid_cc ${EXTRA_LIBS} pthread)

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
target_link_libraries(source_local_chunk_store_test ${CUDA_LIBRARIES})
add_test(NAME source_local_chunk_store_test COMMAND source_local_chunk_store_test)
