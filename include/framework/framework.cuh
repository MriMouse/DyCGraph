// ----------------------------------------------------------------
// SEP-Graph: Finding Shortest Execution Paths for Graph Processing under a Hybrid Framework on GPU
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE
// in the root directory of this source distribution.
// ----------------------------------------------------------------
#ifndef HYBRID_FRAMEWORK_H
#define HYBRID_FRAMEWORK_H

#include <map>
#include <math.h>
#include <thrust/device_ptr.h>
#include <thrust/host_vector.h>
#include <thrust/device_vector.h>
#include <thread>
#include <cooperative_groups.h>
#include <thrust/sort.h>
#include <cub/cub.cuh>
#include <framework/common.h>
#include <framework/variants/api.cuh>
#include <framework/graph_datum.cuh>
#include <framework/variants/common.cuh>
#include <framework/variants/driver.cuh>
#include <framework/hybrid_policy.h>
#include <framework/dynamic_reverse_index.h>
#include <framework/dual_domain_event_runtime.h>
#include <framework/topology_replay.h>
#include <framework/cache_patch_trace.h>
#include <framework/cache_refresh_gate.h>
#include <framework/affected_component_trace.h>
#include <framework/algo_variants.cuh>
#include <utils/cuda_utils.h>
#include <utils/graphs/traversal.h>
#include <utils/to_json.h>
#include <groute/device/work_source.cuh>
#include "clion_cuda.cuh"
#include <groute/rmat_util.h>
#include "Loader.h"
#include <unordered_set>
#include <thrust/device_vector.h>
#include <thrust/host_vector.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <deque>
#include <limits>
#include <string>
#include <type_traits>
#include <vector>

DECLARE_int32(residence);
DECLARE_int32(priority_a);
DECLARE_int32(hybrid);
DECLARE_int32(SEGMENT);
DECLARE_int32(n_stream);
DECLARE_int32(max_iteration);
DECLARE_string(out_wl);
DECLARE_string(lb_push);
DECLARE_string(lb_pull);
DECLARE_double(alpha);
DECLARE_bool(undirected);
DECLARE_bool(wl_sort);
DECLARE_bool(wl_unique);
DECLARE_bool(verbose);

DECLARE_double(edge_factor);
DECLARE_string(updatefile);
DECLARE_string(update_size);
DECLARE_bool(weight);
DECLARE_bool(check);
DECLARE_bool(topology_replay_audit);
DECLARE_int32(sssp_cpu_partition_capacity);
DECLARE_string(sssp_cpu_domain_map);
DECLARE_string(e0b_trace_file);
DECLARE_string(f1_cache_trace_file);
DECLARE_string(f1_component_trace_file);

namespace sepgraph {
    namespace engine {
        using common::Priority;
        using common::LoadBalancing;
        using common::Scheduling;
        using common::Model;
        using common::MsgPassing;
        using common::AlgoVariant;
        using policy::AlgoType;
        using policy::PolicyDecisionMaker;
        using utils::JsonWriter;


        struct Algo {
            static const char *Name() {
                return "Hybrid Graph Engine";
            }
        };

        template<typename TBuffer>
        struct CpuRelaxProposal {
            index_t dst;
            TBuffer value;
            index_t parent;
        };

        enum class RepairBoundaryEventKind : uint8_t {
            Invalidation = 0,
            Replacement = 1
        };

        template<typename TValue>
        struct RepairBoundaryEvent {
            index_t source;
            TValue value;
            index_t parent;
            uint32_t epoch;
            uint32_t version;
            RepairBoundaryEventKind kind;
        };

        enum class PartitionOwner : uint8_t {
            GPU = 0,
            CPU = 1
        };

        template<typename TAppInst, typename TValue, typename TBuffer>
        __global__ void GpuAffectedPullRelax(TAppInst app_inst,
                                             const index_t *affected_vertices,
                                             uint32_t affected_count,
                                             const uint64_t *incoming_offsets,
                                             const index_t *incoming_sources,
                                             TValue *node_value,
                                             TBuffer *node_buffer,
                                             TValue *node_parent,
                                             TValue infinity,
                                             const uint8_t *cpu_owner_flags,
                                             unsigned int *changed_count,
                                             index_t *changed_vertices) {
            static_assert(sizeof(TValue) == sizeof(unsigned int),
                          "GPU affected repair requires 32-bit values");
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < affected_count; i += nthreads) {
                const index_t dst = affected_vertices[i];
                if (cpu_owner_flags != nullptr && cpu_owner_flags[dst]) {
                    continue;
                }
                TValue best = static_cast<TValue>(atomicAdd(
                    reinterpret_cast<unsigned int *>(&node_value[dst]), 0));
                index_t best_parent = node_parent[dst];
                for (uint64_t edge = incoming_offsets[i];
                     edge < incoming_offsets[i + 1]; ++edge) {
                    const index_t src = incoming_sources[edge];
                    const TValue src_value = static_cast<TValue>(atomicAdd(
                        reinterpret_cast<unsigned int *>(&node_value[src]), 0));
                    if (src_value == infinity) {
                        continue;
                    }
                    const uint64_t candidate_wide =
                        static_cast<uint64_t>(src_value) +
                        static_cast<uint64_t>(TAppInst::DeletionEdgeWeight(src, dst));
                    if (candidate_wide < static_cast<uint64_t>(best) ||
                        (candidate_wide == static_cast<uint64_t>(best) &&
                         (best_parent == UINT32_MAX || src < best_parent))) {
                        best = static_cast<TValue>(candidate_wide);
                        best_parent = src;
                    }
                }
                const TValue old_value = static_cast<TValue>(atomicMin(
                    reinterpret_cast<unsigned int *>(&node_value[dst]),
                    static_cast<unsigned int>(best)));
                if (best <= old_value && best_parent != UINT32_MAX) {
                    atomicExch(reinterpret_cast<unsigned int *>(&node_buffer[dst]),
                               static_cast<unsigned int>(best));
                    atomicExch(reinterpret_cast<unsigned int *>(&node_parent[dst]),
                               static_cast<unsigned int>(best_parent));
                }
                if (best < old_value) {
                    const unsigned int position = atomicAdd(changed_count, 1u);
                    if (changed_vertices != nullptr) {
                        changed_vertices[position] = dst;
                    }
                }
            }
        }

        template<typename TValue, typename TBuffer>
        __global__ void FinalizeGpuAffectedRepair(const index_t *affected_vertices,
                                                  uint32_t affected_count,
                                                  const TValue *node_value,
                                                  TBuffer *node_buffer,
                                                  bool *node_reset) {
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < affected_count; i += nthreads) {
                const index_t node = affected_vertices[i];
                node_buffer[node] = static_cast<TBuffer>(node_value[node]);
                node_reset[node] = false;
            }
        }

        template<typename TValue>
        __device__ TValue AtomicMinState(TValue *address, TValue value) {
            static_assert(sizeof(TValue) == sizeof(uint32_t),
                          "AtomicMinState requires a 32-bit state type");
            uint32_t *bits = reinterpret_cast<uint32_t *>(address);
            uint32_t observed_bits = *bits;
            while (value < *reinterpret_cast<TValue *>(&observed_bits)) {
                const uint32_t desired_bits = *reinterpret_cast<uint32_t *>(&value);
                const uint32_t previous_bits = atomicCAS(bits, observed_bits, desired_bits);
                if (previous_bits == observed_bits) {
                    break;
                }
                observed_bits = previous_bits;
            }
            return *reinterpret_cast<TValue *>(&observed_bits);
        }

        template<typename TValue, typename TWEdge>
        __global__ void SeedAddedEdgeFrontier(const TWEdge *added_edges,
                                              const uint32_t *work_size,
                                              const TValue *node_value,
                                              TValue *node_buffer,
                                              TValue *node_parent,
                                              TValue infinity,
                                              BitmapDeviceObject out_active,
                                              const index_t *segment_end_nodes,
                                              const uint8_t *segment_owners,
                                              const uint8_t *cpu_home_flags,
                                              uint32_t segment_count,
                                              uint32_t epoch,
                                              uint32_t *node_state_epoch,
                                              unsigned long long *owner_reject_count,
                                              TValue *boundary_values,
                                              index_t *boundary_parents,
                                              groute::dev::Queue<index_t> boundary_vertices,
                                              groute::dev::Queue<index_t> exact_sources) {
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            const uint32_t begin = work_size[0];
            const uint32_t count = work_size[1];
            for (uint32_t offset = tid; offset < count; offset += nthreads) {
                const TWEdge edge = added_edges[begin + offset];
                uint32_t lo = 0;
                uint32_t hi = segment_count;
                while (lo < hi) {
                    const uint32_t mid = lo + (hi - lo) / 2;
                    if (edge.v < segment_end_nodes[mid]) {
                        hi = mid;
                    } else {
                        lo = mid + 1;
                    }
                }
                if (lo >= segment_count) {
                    if (owner_reject_count != nullptr) {
                        atomicAdd(owner_reject_count, 1ULL);
                    }
                    continue;
                }
                (void)segment_owners;
                if (node_value[edge.u] == infinity) {
                    continue;
                }
                const uint64_t candidate_wide =
                    static_cast<uint64_t>(node_value[edge.u]) +
                    static_cast<uint64_t>(edge.w);
                if (candidate_wide >= static_cast<uint64_t>(infinity)) {
                    continue;
                }
                const TValue candidate = static_cast<TValue>(candidate_wide);
                const bool cpu_owned = cpu_home_flags != nullptr
                    ? cpu_home_flags[edge.v] != 0
                    : segment_owners[lo] == static_cast<uint8_t>(PartitionOwner::CPU);
                if (cpu_owned) {
                    const TValue old = AtomicMinState(&boundary_values[edge.v], candidate);
                    if (candidate < old) {
                        boundary_parents[edge.v] = edge.u;
                        boundary_vertices.append(edge.v);
                    }
                    continue;
                }
                const TValue old_buffer = AtomicMinState(&node_buffer[edge.v], candidate);
                if (candidate < old_buffer && candidate == node_buffer[edge.v]) {
                    atomicExch(reinterpret_cast<uint32_t *>(&node_parent[edge.v]), edge.u);
                    const uint32_t seed_ticket = epoch << 16;
                    if (atomicExch(node_state_epoch + edge.v, seed_ticket) !=
                        seed_ticket) {
                        exact_sources.append(edge.v);
                    }
                }
            }
        }

        template<typename TBuffer>
        __global__ void GatherAndResetBoundary(
                const index_t *vertices,
                uint32_t count,
                TBuffer *boundary_values,
                index_t *boundary_parents,
                CpuRelaxProposal<TBuffer> *proposals,
                TBuffer infinity) {
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < count; i += nthreads) {
                const index_t dst = vertices[i];
                const TBuffer value = atomicExch(&boundary_values[dst], infinity);
                proposals[i] = {dst, value, boundary_parents[dst]};
            }
        }

        template<typename TValue, typename TBuffer>
        __global__ void GatherSuccessfulPropagation(
                const index_t *vertices,
                uint32_t count,
                const TValue *parents,
                CpuRelaxProposal<TBuffer> *records) {
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < count; i += nthreads) {
                const index_t dst = vertices[i];
                records[i] = {dst, TBuffer{}, static_cast<index_t>(parents[dst])};
            }
        }

        template<typename TBuffer>
        __global__ void MergeCpuRelaxProposals(CpuRelaxProposal<TBuffer> *proposals,
                                               uint32_t proposal_count,
                                               TBuffer *node_buffer,
                                               TBuffer *node_parent,
                                               BitmapDeviceObject out_active,
                                               groute::dev::Queue<index_t> changed_vertices,
                                               unsigned long long *success_count) {
            uint32_t tid = TID_1D;
            uint32_t nthreads = TOTAL_THREADS_1D;

            for (uint32_t i = tid; i < proposal_count; i += nthreads) {
                CpuRelaxProposal<TBuffer> proposal = proposals[i];
                TBuffer old_buffer = AtomicMinState(&node_buffer[proposal.dst], proposal.value);
                if (proposal.value < old_buffer) {
                    if (success_count != nullptr) {
                        atomicAdd(success_count, 1ULL);
                    }
                    static_assert(sizeof(TBuffer) == sizeof(uint32_t),
                                  "CPU proposal merge requires 32-bit state");
                    uint32_t *parent_bits = reinterpret_cast<uint32_t *>(
                        &node_parent[proposal.dst]);
                    uint32_t old_parent_bits = *parent_bits;
                    const uint32_t proposal_parent_bits = proposal.parent;
                    do {
                        old_parent_bits = atomicCAS(parent_bits,
                                                    old_parent_bits,
                                                    proposal_parent_bits);
                    } while (proposal.value == node_buffer[proposal.dst] &&
                             *parent_bits != proposal_parent_bits);
                    out_active.set_bit_atomic(proposal.dst);
                    changed_vertices.append(proposal.dst);
                }
            }
        }

        template<typename TValue, typename TBuffer>
        __global__ void GatherCpuOwnedState(const index_t *vertices,
                                            uint32_t count,
                                            const TValue *values,
                                            const TBuffer *buffers,
                                            const TValue *parents,
                                            TValue *cpu_values,
                                            TBuffer *cpu_buffers,
                                            TValue *cpu_parents) {
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < count; i += nthreads) {
                const index_t vertex = vertices[i];
                cpu_values[i] = values[vertex];
                cpu_buffers[i] = buffers[vertex];
                cpu_parents[i] = parents[vertex];
            }
        }

        template<typename TAppInst, typename TPMAGraph, typename TValue,
                 typename TBuffer>
        __global__ void ExpandExactGpuSources(
                TAppInst app_inst,
                const index_t *sources,
                uint32_t source_count,
                TPMAGraph graph,
                TValue *values,
                TBuffer *buffers,
                TValue *parents,
                groute::dev::Queue<index_t> changed_vertices,
                unsigned long long *processed_sources,
                unsigned long long *processed_edges) {
            const uint32_t source_index = blockIdx.x;
            if (source_index >= source_count) return;
            const index_t source = sources[source_index];
            __shared__ TBuffer source_value;
            __shared__ bool expand;
            if (threadIdx.x == 0) {
                const auto combined = app_inst.CombineValueBuffer(
                    source, &values[source], &buffers[source]);
                source_value = combined.first;
                expand = combined.second;
                if (expand) {
                    atomicAdd(processed_sources, 1ULL);
                    atomicAdd(processed_edges,
                        static_cast<unsigned long long>(graph.degree(source)));
                }
            }
            __syncthreads();
            if (!expand) return;

            const uint64_t edge_begin = graph.begin_edge(source);
            const uint32_t degree = graph.degree(source);
            for (uint32_t offset = threadIdx.x; offset < degree;
                 offset += blockDim.x) {
                const index_t destination = graph.edge_dest(edge_begin + offset);
                if (destination == static_cast<index_t>(-1)) continue;
                const index_t weight = (source + destination) % 128 + 1;
                if (app_inst.AccumulateBuffer(source, destination, weight,
                        &parents[destination], &buffers[destination], source_value)) {
                    changed_vertices.append(destination);
                }
            }
        }

        template<typename TAppInst, typename TPMAGraph, typename TValue,
                 typename TBuffer>
        __global__ void RunExactGpuClosure(
                TAppInst app_inst,
                groute::dev::Queue<index_t> input,
                groute::dev::Queue<index_t> output,
                TPMAGraph graph,
                TValue *values,
                TBuffer *buffers,
                TValue *parents,
                uint32_t epoch,
                uint32_t *node_state_epoch,
                unsigned long long *metrics) {
            cooperative_groups::grid_group grid =
                cooperative_groups::this_grid();
            __shared__ TBuffer source_value;
            __shared__ bool expand;
            while (true) {
                grid.sync();
                const uint32_t source_count = input.count();
                if (source_count == 0) break;
                if (blockIdx.x == 0 && threadIdx.x == 0) {
                    output.reset();
                    atomicAdd(metrics + 0,
                        static_cast<unsigned long long>(source_count));
                    atomicAdd(metrics + 3, 1ULL);
                }
                grid.sync();
                for (uint32_t source_index = blockIdx.x;
                     source_index < source_count;
                     source_index += gridDim.x) {
                    const index_t source = input.read(source_index);
                    if (threadIdx.x == 0) {
                        const auto combined = app_inst.CombineValueBuffer(
                            source, &values[source], &buffers[source]);
                        source_value = combined.first;
                        expand = combined.second;
                        if (expand) {
                            atomicAdd(metrics + 1, 1ULL);
                            atomicAdd(metrics + 2,
                                static_cast<unsigned long long>(
                                    graph.degree(source)));
                        }
                    }
                    __syncthreads();
                    if (expand) {
                        const uint64_t edge_begin = graph.begin_edge(source);
                        const uint32_t degree = graph.degree(source);
                        for (uint32_t offset = threadIdx.x; offset < degree;
                             offset += blockDim.x) {
                            const index_t destination =
                                graph.edge_dest(edge_begin + offset);
                            if (destination == static_cast<index_t>(-1)) continue;
                            const index_t weight =
                                (source + destination) % 128 + 1;
                            if (app_inst.AccumulateBuffer(source, destination,
                                    weight, &parents[destination],
                                    &buffers[destination], source_value)) {
                                const uint32_t wave_ticket =
                                    (epoch << 16) |
                                    (static_cast<uint32_t>(metrics[3]) & 0xffffU);
                                if (atomicExch(node_state_epoch + destination,
                                        wave_ticket) != wave_ticket) {
                                    output.append(destination);
                                }
                            }
                        }
                    }
                    __syncthreads();
                }
                grid.sync();
                if (blockIdx.x == 0 && threadIdx.x == 0) input.reset();
                grid.sync();
                const auto previous = input;
                input = output;
                output = previous;
            }
            grid.sync();
            if (blockIdx.x == 0 && threadIdx.x == 0) {
                input.reset();
                output.reset();
            }
            grid.sync();
        }

        template<typename TValue, typename TBuffer>
        __global__ void GatherSparseCpuState(CpuRelaxProposal<TBuffer> *states,
                                             uint32_t count,
                                             const TValue *values,
                                             const TValue *parents) {
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < count; i += nthreads) {
                const index_t vertex = states[i].dst;
                states[i].value = static_cast<TBuffer>(values[vertex]);
                states[i].parent = static_cast<index_t>(parents[vertex]);
            }
        }

        template<typename TValue, typename TBuffer>
        __global__ void ScatterCpuOwnedState(const index_t *vertices,
                                             uint32_t count,
                                             const TValue *cpu_values,
                                             const TBuffer *cpu_buffers,
                                             const TValue *cpu_parents,
                                             TValue *values,
                                             TBuffer *buffers,
                                             TValue *parents) {
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < count; i += nthreads) {
                const index_t vertex = vertices[i];
                values[vertex] = cpu_values[i];
                buffers[vertex] = cpu_buffers[i];
                parents[vertex] = cpu_parents[i];
            }
        }

        template<typename TValue, typename TBuffer>
        __global__ void ScatterCpuDirtyState(
                const CpuRelaxProposal<TBuffer> *states,
                uint32_t count,
                TValue *values,
                TBuffer *buffers,
                TValue *parents) {
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < count; i += nthreads) {
                const CpuRelaxProposal<TBuffer> state = states[i];
                values[state.dst] = static_cast<TValue>(state.value);
                buffers[state.dst] = state.value;
                parents[state.dst] = static_cast<TValue>(state.parent);
            }
        }

        struct InsertionRoundStats {
            uint64_t cpu_removed_gpu_sources = 0;
            uint64_t cpu_removed_gpu_source_edges = 0;
            uint64_t cpu_state_scatter_vertices = 0;
            uint64_t cpu_state_scatter_bytes = 0;
            double cpu_state_scatter_ms = 0.0;
            uint64_t cpu_expanded_vertices = 0;
            uint64_t cpu_edge_visits = 0;
            uint64_t cpu_proposals_success = 0;
            double h2d_proposal_ms = 0.0;
            double merge_ms = 0.0;
            double allocation_ms = 0.0;
            double proposal_compress_ms = 0.0;
            uint64_t cpu_local_relax_success = 0;
            uint64_t cpu_closure_rounds = 0;
            uint64_t cpu_to_gpu_boundary_proposals = 0;
            uint64_t cpu_to_gpu_boundary_bytes = 0;
            uint64_t gpu_to_cpu_boundary_items = 0;
            uint64_t gpu_to_cpu_boundary_bytes = 0;
            double gpu_submit_ms = 0.0;
            double gpu_service_ms = 0.0;
            double cpu_service_ms = 0.0;
            double overlap_ms = 0.0;
            double cpu_wait_ms = 0.0;
            double gpu_wait_ms = 0.0;
            bool concurrent = false;
        };


      template<typename TValue, typename TBuffer, typename TWeight, template<typename, typename, typename, typename ...> class TAppImpl, typename... UnusedData>
      class     Engine {
        private:
        typedef TAppImpl<TValue, TBuffer, TWeight, UnusedData...> AppImplDeviceObject;
        typedef graphs::GraphDatum<TValue, TBuffer, TWeight> GraphDatum;
        typedef Loader<index_t, index_t, index_t> Loader;
        // typedef EdgePair<uint32_t,uint32_t> Edge;
        typedef WEdgePair<uint32_t,uint32_t,uint32_t>  WEdge;
        // using WeightedDynT = groute::graphs::single::TestGraph<TValue, TBuffer, TValue,true>;
        cudaDeviceProp m_dev_props;

            // Graph data
            std::unique_ptr<utils::traversal::Context<Algo>> m_groute_context;
            std::unique_ptr<groute::Stream> m_stream;
            std::unique_ptr<groute::graphs::single::CSRGraphAllocator> m_csr_dev_graph_allocator;
            std::unique_ptr<groute::graphs::single::PMAGraphAllocator> m_vcsr_dev_graph_allocator;
            std::unique_ptr<topology::SourceLocalChunkStore> m_chunk_store;
            std::vector<index_t> m_topology_patch_sources;
            // std::unique_ptr<groute::graphs::single::PMAGraphAllocator> m_vcsr_dev_graph_allocator_update;
            std::unique_ptr<groute::graphs::single::CSCGraphAllocator> m_csc_dev_graph_allocator;
            runtime::DynamicReverseIndex m_reverse_index;
            std::vector<uint64_t> m_gpu_repair_incoming_offsets;
            std::vector<index_t> m_gpu_repair_incoming_sources;
            uint64_t *m_device_gpu_repair_offsets = nullptr;
            index_t *m_device_gpu_repair_sources = nullptr;
            size_t m_device_gpu_repair_offset_capacity = 0;
            size_t m_device_gpu_repair_source_capacity = 0;
            groute::Queue<index_t> m_device_affected_vertices;
            std::vector<index_t> m_affected_vertices;
            unsigned int *m_device_gpu_repair_changed = nullptr;
            index_t *m_device_gpu_repair_changed_vertices = nullptr;
            std::vector<uint8_t> m_partition_owners;
            index_t *m_device_partition_end_nodes = nullptr;
            uint8_t *m_device_partition_owners = nullptr;
            uint32_t *m_device_node_state_epoch = nullptr;
            unsigned long long *m_device_seed_owner_reject_count = nullptr;
            uint32_t m_insertion_epoch = 0;
            uint64_t m_insertion_convergence_round = 0;
            bool m_insertion_epoch_active = false;
            index_t m_insertion_seed_begin = 0;
            index_t m_insertion_seed_count = 0;
            TBuffer *m_device_gpu_to_cpu_boundary_values = nullptr;
            index_t *m_device_gpu_to_cpu_boundary_parents = nullptr;
            std::vector<uint8_t> m_node_cpu_owner;
            std::vector<index_t> m_cpu_owned_vertices;
            index_t *m_device_cpu_owned_vertices = nullptr;
            TValue *m_device_cpu_owned_values = nullptr;
            TBuffer *m_device_cpu_owned_buffers = nullptr;
            TValue *m_device_cpu_owned_parents = nullptr;
            std::vector<TValue> m_compact_cpu_values;
            std::vector<TBuffer> m_compact_cpu_buffers;
            std::vector<TValue> m_compact_cpu_parents;
            bool m_cpu_domain_map_enabled = false;
            bool m_cpu_domain_state_initialized = false;
            uint32_t m_cpu_domain_state_epoch = 0;
            std::vector<index_t> m_cpu_owned_segments;
            std::vector<TValue> m_cpu_node_values;
            std::vector<TBuffer> m_cpu_node_buffers;
            std::vector<index_t> m_cpu_node_parents;
            std::deque<index_t> m_cpu_frontier;
            std::vector<index_t> m_cpu_dirty_vertices;
            std::vector<uint32_t> m_repair_source_versions;
            std::vector<uint32_t> m_repair_source_accepted_versions;
            std::vector<uint8_t> m_insertion_seed_partitions;
            uint32_t m_last_insertion_dirty_partitions = 0;
            std::unique_ptr<topology::SparseTopologyReplayModel> m_topology_audit_expected;
            std::vector<index_t> m_topology_audit_sources;
            uint32_t m_topology_audit_batch = 0;

            std::unique_ptr<AppImplDeviceObject> m_app_inst;
            groute::Stream stream[64];
            // App instance
            std::unique_ptr<GraphDatum> m_graph_datum;
            std::unique_ptr<Loader> m_load_update;
            policy::TRunningInfo m_running_info;
            TBuffer current_priority;  // put it into running info
            PolicyDecisionMaker m_policy_decision_maker;
            EngineOptions m_engine_options;
            WEdge* added_edges_h=nullptr;
            WEdge* added_edges_d=nullptr;
            WEdge* del_edges_h=nullptr;
            WEdge* del_edges_d=nullptr;
            uint32_t* work_size_d = nullptr;
            int type[2] = {0, 0};
            int *type_device=nullptr;
            bool type_host_registered = false;
            //partition_information
            unsigned int partitions_csc;
            unsigned int* partition_offset_csc;
            unsigned int max_partition_size_csc;

            unsigned int partitions_csr;
            unsigned int* partition_offset_csr;
            unsigned int max_partition_size_csr;
            std::vector<index_t> m_insertion_changed_vertices;
            struct E0BRegionActivity {
                uint64_t active_vertices = 0;
                uint64_t scanned_edges = 0;
            };
            std::ofstream m_e0b_trace;
            std::ofstream m_f1_cache_trace;
            std::ofstream m_f1_component_trace;
            std::vector<cache_patch::CandidateRecord> m_f1_previous_cache_candidates;
            uint64_t m_f1_previous_cache_edges = 0;
            bool m_f1_cache_trace_initialized = false;
            cache_patch::RefreshGate m_cache_refresh_gate;
            std::vector<E0BRegionActivity> m_e0b_region_activity;
            std::vector<std::pair<index_t, uint64_t>> m_e0b_active_sources;
            std::vector<std::pair<index_t, index_t>> m_e0b_success_records;
            std::map<std::pair<index_t, index_t>, uint64_t> m_e0b_success_edges;
            uint64_t m_e0b_success_total = 0;
            std::vector<CpuRelaxProposal<TBuffer>> m_cpu_boundary_proposals;
            std::vector<CpuRelaxProposal<TBuffer>> m_cpu_compressed_proposals;
            std::vector<index_t> m_cpu_proposal_compress_keys;
            std::vector<size_t> m_cpu_proposal_compress_indices;
            std::vector<size_t> m_cpu_proposal_compress_touched_slots;
            groute::Queue<index_t> m_device_gpu_to_cpu_boundary_vertices;
            groute::Queue<index_t> m_device_insertion_changed_vertices;
            bool m_exact_source_frontier_ready = false;
            uint32_t m_exact_source_frontier_count = 0;
            CpuRelaxProposal<TBuffer> *m_device_cpu_boundary_proposals = nullptr;
            unsigned long long *m_device_cpu_proposal_success_count = nullptr;
            unsigned long long *m_device_exact_source_counts = nullptr;
            uint8_t *m_device_cpu_destination_flags = nullptr;
            size_t m_device_cpu_boundary_proposal_capacity = 0;
            // Loader<index_t,index_t,index_t> load_update;
            // WeightedDynT result_graph;



            void RefreshSegmentActiveCountsFromQueues() {
                GraphDatum &graph_datum = *m_graph_datum;
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    const index_t stream_id = seg % FLAGS_n_stream;
                    const index_t active =
                        graph_datum.m_wl_array_in_seg[seg].GetCount(stream[stream_id]);
                    graph_datum.seg_active_num[seg] = active;
                    m_running_info.input_active_count_seg[seg] = active;
                }
            }

            void PrepareCpuOwnerRuntimeStorage() {
                const bool use_domain_map = !FLAGS_sssp_cpu_domain_map.empty();
                if (use_domain_map && FLAGS_sssp_cpu_partition_capacity != 0) {
                    LOG("[E2-DOMAIN] protocol_error=domain_map_conflicts_with_capacity capacity=%d\n",
                        FLAGS_sssp_cpu_partition_capacity);
                    std::abort();
                }
                if (!use_domain_map &&
                    (FLAGS_sssp_cpu_partition_capacity < 0 ||
                     FLAGS_sssp_cpu_partition_capacity > FLAGS_SEGMENT)) {
                    LOG("[DUAL-RUNTIME] protocol_error=invalid_cpu_capacity capacity=%d partitions=%d\n",
                        FLAGS_sssp_cpu_partition_capacity,
                        FLAGS_SEGMENT);
                    std::abort();
                }
                if (!use_domain_map && FLAGS_sssp_cpu_partition_capacity == 0) return;

                GraphDatum &graph_datum = *m_graph_datum;
                GROUTE_CUDA_CHECK(cudaMalloc(
                    reinterpret_cast<void **>(&m_device_cpu_destination_flags),
                    sizeof(uint8_t) * graph_datum.nnodes));
                GROUTE_CUDA_CHECK(cudaMalloc(
                    reinterpret_cast<void **>(&m_device_gpu_to_cpu_boundary_values),
                    sizeof(TBuffer) * graph_datum.nnodes));
                GROUTE_CUDA_CHECK(cudaMalloc(
                    reinterpret_cast<void **>(&m_device_gpu_to_cpu_boundary_parents),
                    sizeof(index_t) * graph_datum.nnodes));
                m_node_cpu_owner.assign(graph_datum.nnodes, 0);
                m_cpu_node_values.resize(graph_datum.nnodes);
                m_cpu_node_buffers.resize(graph_datum.nnodes);
                m_cpu_node_parents.resize(graph_datum.nnodes);
                GROUTE_CUDA_CHECK(cudaMemset(
                    m_device_cpu_destination_flags, 0, graph_datum.nnodes));
                GROUTE_CUDA_CHECK(cudaMemset(
                    m_device_gpu_to_cpu_boundary_values,
                    0xff,
                    sizeof(TBuffer) * graph_datum.nnodes));

                if (use_domain_map) {
                    std::ifstream input(FLAGS_sssp_cpu_domain_map,
                                        std::ios::binary | std::ios::ate);
                    const std::streamsize expected =
                        static_cast<std::streamsize>(graph_datum.nnodes) *
                        sizeof(uint16_t);
                    const std::streamsize actual = input.is_open()
                        ? static_cast<std::streamsize>(input.tellg()) : -1;
                    if (!input.is_open() || actual != expected) {
                        LOG("[E2-DOMAIN] invalid_map path=%s expected_bytes=%lld actual_bytes=%lld\n",
                            FLAGS_sssp_cpu_domain_map.c_str(),
                            static_cast<long long>(expected),
                            static_cast<long long>(actual));
                        std::abort();
                    }
                    input.seekg(0);
                    std::vector<uint16_t> domains(graph_datum.nnodes);
                    input.read(reinterpret_cast<char *>(domains.data()), expected);
                    if (!input) {
                        LOG("[E2-DOMAIN] read_failed path=%s\n",
                            FLAGS_sssp_cpu_domain_map.c_str());
                        std::abort();
                    }
                    for (index_t vertex = 0; vertex < graph_datum.nnodes; ++vertex) {
                        if (domains[vertex] > 1) {
                            LOG("[E2-DOMAIN] invalid_owner vertex=%u owner=%u\n",
                                vertex, static_cast<unsigned>(domains[vertex]));
                            std::abort();
                        }
                        if (domains[vertex] == 0) {
                            m_node_cpu_owner[vertex] = 1;
                            m_cpu_owned_vertices.push_back(vertex);
                        }
                    }
                    const size_t count = m_cpu_owned_vertices.size();
                    m_compact_cpu_values.resize(count);
                    m_compact_cpu_buffers.resize(count);
                    m_compact_cpu_parents.resize(count);
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_cpu_owned_vertices),
                        sizeof(TValue) * count));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_cpu_owned_values),
                        sizeof(TValue) * count));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_cpu_owned_buffers),
                        sizeof(TBuffer) * count));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_cpu_owned_parents),
                        sizeof(TValue) * count));
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        m_device_cpu_owned_vertices, m_cpu_owned_vertices.data(),
                        sizeof(index_t) * count, cudaMemcpyHostToDevice));
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        m_device_cpu_destination_flags, m_node_cpu_owner.data(),
                        graph_datum.nnodes, cudaMemcpyHostToDevice));
                    m_cpu_domain_map_enabled = true;
                    LOG("[E2-DOMAIN] loaded path=%s cpu_vertices=%llu cpu_vertex_share=%.6f\n",
                        FLAGS_sssp_cpu_domain_map.c_str(),
                        static_cast<unsigned long long>(count),
                        graph_datum.nnodes == 0 ? 0.0
                            : static_cast<double>(count) / graph_datum.nnodes);
                }
            }

            template<typename DevicePtr>
            void EnsureInsertionDeviceCapacity(DevicePtr **device_buffer,
                                          size_t *capacity,
                                          size_t needed,
                                          InsertionRoundStats &stats) {
                if (needed <= *capacity) {
                    return;
                }

                Stopwatch sw_alloc(true);
                if (*device_buffer != nullptr) {
                    GROUTE_CUDA_CHECK(cudaFree(*device_buffer));
                }
                using ElementT = typename std::remove_pointer<DevicePtr>::type;
                GROUTE_CUDA_CHECK(cudaMalloc((void **)device_buffer, sizeof(ElementT) * needed));
                *capacity = needed;
                sw_alloc.stop();
                stats.allocation_ms += sw_alloc.ms();
            }


            template<typename Proposal>
            void CompressCpuRelaxProposals(std::vector<Proposal> &proposals,
                                           InsertionRoundStats &stats) {
                if (proposals.empty()) {
                    return;
                }

                Stopwatch sw_compress(true);
                size_t table_size = 1;
                while (table_size < proposals.size() * 2) {
                    table_size <<= 1;
                }
                const index_t empty_key = std::numeric_limits<index_t>::max();
                if (m_cpu_proposal_compress_keys.size() < table_size) {
                    m_cpu_proposal_compress_keys.assign(table_size, empty_key);
                    m_cpu_proposal_compress_indices.resize(table_size);
                    m_cpu_proposal_compress_touched_slots.clear();
                }

                const size_t table_mask = table_size - 1;
                m_cpu_compressed_proposals.clear();
                m_cpu_compressed_proposals.reserve(proposals.size());
                m_cpu_proposal_compress_touched_slots.clear();

                for (const auto &proposal : proposals) {
                    size_t slot = (static_cast<size_t>(proposal.dst) * 11400714819323198485ull) & table_mask;
                    while (true) {
                        const index_t key = m_cpu_proposal_compress_keys[slot];
                        if (key == empty_key) {
                            m_cpu_proposal_compress_keys[slot] = proposal.dst;
                            m_cpu_proposal_compress_indices[slot] = m_cpu_compressed_proposals.size();
                            m_cpu_proposal_compress_touched_slots.push_back(slot);
                            m_cpu_compressed_proposals.push_back(proposal);
                            break;
                        }
                        if (key == proposal.dst) {
                            Proposal &current = m_cpu_compressed_proposals[m_cpu_proposal_compress_indices[slot]];
                            if (proposal.value < current.value ||
                                (proposal.value == current.value && proposal.parent < current.parent)) {
                                current = proposal;
                            }
                            break;
                        }
                        slot = (slot + 1) & table_mask;
                    }
                }

                proposals.swap(m_cpu_compressed_proposals);
                for (const size_t slot : m_cpu_proposal_compress_touched_slots) {
                    m_cpu_proposal_compress_keys[slot] = empty_key;
                }
                sw_compress.stop();
                stats.proposal_compress_ms += sw_compress.ms();
            }


            template<typename Proposal>
            void CommitCpuBoundaryProposals(std::vector<Proposal> &proposals,
                                       InsertionRoundStats &stats,
                                       groute::dev::Queue<index_t> changed_vertices) {
                if (proposals.empty()) {
                    return;
                }
                CompressCpuRelaxProposals(proposals, stats);
                const size_t proposal_bytes = sizeof(Proposal) * proposals.size();

                EnsureInsertionDeviceCapacity(&m_device_cpu_boundary_proposals,
                                         &m_device_cpu_boundary_proposal_capacity,
                                         proposals.size(),
                                         stats);
                if (m_device_cpu_proposal_success_count == nullptr) {
                    Stopwatch sw_alloc(true);
                    GROUTE_CUDA_CHECK(cudaMalloc(&m_device_cpu_proposal_success_count,
                                                 sizeof(unsigned long long)));
                    sw_alloc.stop();
                    stats.allocation_ms += sw_alloc.ms();
                }

                Stopwatch sw_h2d(true);
                GROUTE_CUDA_CHECK(cudaMemcpy(m_device_cpu_boundary_proposals,
                                             proposals.data(),
                                             proposal_bytes,
                                             cudaMemcpyHostToDevice));
                sw_h2d.stop();
                stats.h2d_proposal_ms += sw_h2d.ms();

                dim3 grid_dims, block_dims;
                Stopwatch sw_merge(true);
                GROUTE_CUDA_CHECK(cudaMemset(m_device_cpu_proposal_success_count,
                                             0,
                                             sizeof(unsigned long long)));
                KernelSizing(grid_dims, block_dims, proposals.size());
                MergeCpuRelaxProposals<TBuffer><<<grid_dims, block_dims>>>(m_device_cpu_boundary_proposals,
                                                                           proposals.size(),
                                                                           m_graph_datum->GetBufferDeviceObject(),
                                                                           m_graph_datum->GetParentDeviceObject(),
                                                                           m_graph_datum->m_wl_bitmap_out_high.DeviceObject(),
                                                                           changed_vertices,
                                                                           m_device_cpu_proposal_success_count);
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                unsigned long long success_count = 0;
                GROUTE_CUDA_CHECK(cudaMemcpy(&success_count,
                                             m_device_cpu_proposal_success_count,
                                             sizeof(unsigned long long),
                                             cudaMemcpyDeviceToHost));
                stats.cpu_proposals_success += success_count;
                sw_merge.stop();
                stats.merge_ms += sw_merge.ms();
            }

            public:
            Engine(AlgoType algo_type) :
            m_running_info(algo_type),
            m_policy_decision_maker(m_running_info) {
                int dev_id = 0;

                GROUTE_CUDA_CHECK(cudaGetDeviceProperties(&m_dev_props, dev_id));
                m_groute_context = std::unique_ptr<utils::traversal::Context<Algo>>
                (new utils::traversal::Context<Algo>(1));

                //create stream /*CODE by ax range 118 to 121*/
                for(int i = 0; i < FLAGS_n_stream; i++)
                {
                    stream[i] = m_groute_context->CreateStream(dev_id);
                }

        m_stream = std::unique_ptr<groute::Stream>(new groute::Stream(dev_id));
    }

    ~Engine() {
        if (m_device_gpu_repair_offsets != nullptr) {
            cudaFree(m_device_gpu_repair_offsets);
            m_device_gpu_repair_offsets = nullptr;
        }
        if (m_device_gpu_repair_sources != nullptr) {
            cudaFree(m_device_gpu_repair_sources);
            m_device_gpu_repair_sources = nullptr;
        }
        if (m_device_gpu_repair_changed != nullptr) {
            cudaFree(m_device_gpu_repair_changed);
            m_device_gpu_repair_changed = nullptr;
        }
        if (m_device_gpu_repair_changed_vertices != nullptr) {
            cudaFree(m_device_gpu_repair_changed_vertices);
            m_device_gpu_repair_changed_vertices = nullptr;
        }
        if (m_device_partition_end_nodes != nullptr) {
            cudaFree(m_device_partition_end_nodes);
            m_device_partition_end_nodes = nullptr;
        }
        if (m_device_partition_owners != nullptr) {
            cudaFree(m_device_partition_owners);
            m_device_partition_owners = nullptr;
        }
        if (m_device_node_state_epoch != nullptr) {
            cudaFree(m_device_node_state_epoch);
            m_device_node_state_epoch = nullptr;
        }
        if (m_device_seed_owner_reject_count != nullptr) {
            cudaFree(m_device_seed_owner_reject_count);
            m_device_seed_owner_reject_count = nullptr;
        }
        if (m_device_gpu_to_cpu_boundary_values != nullptr) {
            cudaFree(m_device_gpu_to_cpu_boundary_values);
            m_device_gpu_to_cpu_boundary_values = nullptr;
        }
        if (m_device_gpu_to_cpu_boundary_parents != nullptr) {
            cudaFree(m_device_gpu_to_cpu_boundary_parents);
            m_device_gpu_to_cpu_boundary_parents = nullptr;
        }
        if (m_device_cpu_boundary_proposals != nullptr) {
            cudaFree(m_device_cpu_boundary_proposals);
            m_device_cpu_boundary_proposals = nullptr;
        }
        if (m_device_cpu_proposal_success_count != nullptr) {
            cudaFree(m_device_cpu_proposal_success_count);
            m_device_cpu_proposal_success_count = nullptr;
        }
        if (m_device_exact_source_counts != nullptr) {
            cudaFree(m_device_exact_source_counts);
            m_device_exact_source_counts = nullptr;
        }
        if (m_device_cpu_destination_flags != nullptr) {
            cudaFree(m_device_cpu_destination_flags);
            m_device_cpu_destination_flags = nullptr;
        }
        if (m_device_cpu_owned_vertices != nullptr) {
            cudaFree(m_device_cpu_owned_vertices);
            m_device_cpu_owned_vertices = nullptr;
        }
        if (m_device_cpu_owned_values != nullptr) {
            cudaFree(m_device_cpu_owned_values);
            m_device_cpu_owned_values = nullptr;
        }
        if (m_device_cpu_owned_buffers != nullptr) {
            cudaFree(m_device_cpu_owned_buffers);
            m_device_cpu_owned_buffers = nullptr;
        }
        if (m_device_cpu_owned_parents != nullptr) {
            cudaFree(m_device_cpu_owned_parents);
            m_device_cpu_owned_parents = nullptr;
        }
    }

    void SetOptions(EngineOptions &engine_options) {
        m_engine_options = engine_options;
    }

    index_t GetNodeNum(){
      return m_groute_context->host_graph.nnodes;
    }
            void compute_hot_vertices_pr(){
                GraphDatum &graph_datum = *m_graph_datum;
                auto &app_inst = *m_app_inst;
                groute::Stream &stream_s = *m_stream;
                const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                const auto &hvcsr = m_vcsr_dev_graph_allocator->HostObject();
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, work_source.get_size());
                Stopwatch sw_ch(true);
                kernel::comp_hotness_pr<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source,
                    graph_datum.m_node_buffer_datum,
                    graph_datum.d_hotness);
                stream_s.Sync();
                sw_ch.stop();
                LOG("comp_hotness time: %f ms (excluded)\n", sw_ch.ms());
                graph_datum.sort_vtx_by_hotness();
                // graph_datum.CompareDeviceResult();
                Stopwatch extrac(true);
                kernel::extract_vtx_degree<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source,
                    graph_datum.d_id,
                    graph_datum.d_v);
                stream_s.Sync();
                extrac.stop();
                kernel::reset_hotness<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source,
                    graph_datum.d_hotness);
                    stream_s.Sync();
                LOG("extract degree time: %f ms (excluded)\n", extrac.ms());
                cudaDeviceSynchronize();
            }

            void compute_hot_vertices_sssp(){
                GraphDatum &graph_datum = *m_graph_datum;
                auto &app_inst = *m_app_inst;
                groute::Stream &stream_s = *m_stream;
                const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                const auto &hvcsr = m_vcsr_dev_graph_allocator->HostObject();
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, work_source.get_size());
                Stopwatch sw_ch(true);
                kernel::comp_hotness_sssp<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source,
                    graph_datum.m_node_buffer_datum,
                    graph_datum.d_hotness);
                stream_s.Sync();
                sw_ch.stop();
                LOG("comp_hotness time: %f ms (excluded)\n", sw_ch.ms());
                graph_datum.sort_vtx_by_hotness();
                LOG("sort vtx ms (excluded)\n");
                cudaDeviceSynchronize();
                // graph_datum.CompareDeviceResult();
                Stopwatch extrac(true);
                kernel::extract_vtx_degree<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source,
                    graph_datum.d_id,
                    graph_datum.d_v);
                stream_s.Sync();
                extrac.stop();
                kernel::reset_hotness<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source,
                    graph_datum.d_hotness);
                    stream_s.Sync();
                LOG("extract degree time: %f ms (excluded)\n", extrac.ms());
                cudaDeviceSynchronize();
            }

            index_t CacheCandidateCount() {
                GraphDatum &graph_datum = *m_graph_datum;
                const index_t nnodes = graph_datum.nnodes;
                if (nnodes == 0 || graph_datum.num_of_cache == 0) return 0;
                index_t final_prefix = 0;
                index_t final_degree = 0;
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    &final_prefix, graph_datum.d_sum + nnodes - 1,
                    sizeof(final_prefix), cudaMemcpyDeviceToHost));
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    &final_degree, graph_datum.d_v + nnodes - 1,
                    sizeof(final_degree), cudaMemcpyDeviceToHost));
                if (static_cast<uint64_t>(final_prefix) + final_degree <
                    graph_datum.num_of_cache) return nnodes;
                index_t low = 0;
                index_t high = nnodes - 1;
                while (low < high) {
                    const index_t middle = low + (high - low) / 2;
                    index_t prefix = 0;
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        &prefix, graph_datum.d_sum + middle + 1,
                        sizeof(prefix), cudaMemcpyDeviceToHost));
                    if (static_cast<uint64_t>(prefix) < graph_datum.num_of_cache) {
                        low = middle + 1;
                    } else {
                        high = middle;
                    }
                }
                return low;
            }

            void EnsureTypeDevicePointer() {
                if (!type_host_registered) {
                    GROUTE_CUDA_CHECK(cudaHostRegister(
                        type, sizeof(type), cudaHostRegisterMapped));
                    type_host_registered = true;
                }
                if (type_device == nullptr) {
                    GROUTE_CUDA_CHECK(cudaHostGetDevicePointer(
                        reinterpret_cast<void **>(&type_device), type, 0));
                }
            }

            void confirm_candidate_batch(){
                GraphDatum &graph_datum = *m_graph_datum;
                auto &app_inst = *m_app_inst;
                groute::Stream &stream_s = *m_stream;
                Stopwatch extrac(true);
                graph_datum.ensure_candidate_vertex();
                extrac.stop();
                LOG("candidate v time: %f ms (excluded)\n", extrac.ms());
                const index_t admitted = CacheCandidateCount();
                const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, admitted);
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                // const auto &hvcsr = m_vcsr_dev_graph_allocator->HostObject();
                dim3 grid_dims, block_dims;
                Stopwatch search_rebuild(true);
                type[0] = 0;
                EnsureTypeDevicePointer();
                if (admitted != 0 && m_cache_refresh_gate.published()) {
                    KernelSizing(grid_dims, block_dims, work_source.get_size());
                    kernel::search_batch<<<grid_dims, block_dims, 0, stream_s.cuda_stream>>>(
                        app_inst, vcsr_graph, work_source,
                        graph_datum.d_id.Current(), type_device);
                    stream_s.Sync();
                }
                search_rebuild.stop();
                cudaDeviceSynchronize();
                const bool missing_desired = !m_cache_refresh_gate.published() || type[0] != 0;
                const bool refresh = m_cache_refresh_gate.Observe(admitted, missing_desired);
                if (refresh && admitted != 0) {
                    KernelSizing(grid_dims, block_dims, work_source.get_size());
                    kernel::mark_cache_candidates<<<grid_dims, block_dims, 0,
                        stream_s.cuda_stream>>>(vcsr_graph, work_source,
                                                graph_datum.d_id.Current());
                    stream_s.Sync();
                }
                LOG("[F1-CACHE-GATE] desired_vertices=%u published_vertices=%llu missing_desired=%u refresh_required=%u candidate_ms=%.3f\n",
                    admitted,
                    static_cast<unsigned long long>(m_cache_refresh_gate.published_vertices()),
                    missing_desired ? 1U : 0U, refresh ? 1U : 0U,
                    search_rebuild.ms());
            }

            bool CacheRefreshRequired() const {
                return m_cache_refresh_gate.refresh_required();
            }

            void MarkCachePublished() {
                m_cache_refresh_gate.Publish();
            }

            void TraceCacheCandidates(uint32_t batch) {
                if (FLAGS_f1_cache_trace_file.empty()) return;
                GraphDatum &graph_datum = *m_graph_datum;
                const index_t nnodes = graph_datum.nnodes;
                index_t admitted = 0;
                if (nnodes > 1 && graph_datum.num_of_cache != 0) {
                    index_t final_prefix = 0;
                    index_t final_degree = 0;
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        &final_prefix, graph_datum.d_sum + nnodes - 1,
                        sizeof(final_prefix), cudaMemcpyDeviceToHost));
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        &final_degree, graph_datum.d_v + nnodes - 1,
                        sizeof(final_degree), cudaMemcpyDeviceToHost));
                    if (static_cast<uint64_t>(final_prefix) + final_degree <
                        graph_datum.num_of_cache) {
                        admitted = nnodes;
                    } else {
                        index_t low = 0;
                        index_t high = nnodes - 1;
                        while (low < high) {
                            const index_t middle = low + (high - low) / 2;
                            index_t prefix = 0;
                            GROUTE_CUDA_CHECK(cudaMemcpy(
                                &prefix, graph_datum.d_sum + middle + 1,
                                sizeof(prefix), cudaMemcpyDeviceToHost));
                            if (static_cast<uint64_t>(prefix) < graph_datum.num_of_cache) {
                                low = middle + 1;
                            } else {
                                high = middle;
                            }
                        }
                        admitted = low;
                    }
                }
                std::vector<index_t> ids(admitted);
                if (admitted != 0) {
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        ids.data(), graph_datum.d_id.Current(),
                        sizeof(index_t) * admitted, cudaMemcpyDeviceToHost));
                }
                if (!m_f1_cache_trace.is_open()) {
                    m_f1_cache_trace.open(FLAGS_f1_cache_trace_file,
                                          std::ios::out | std::ios::binary | std::ios::trunc);
                    if (!m_f1_cache_trace) {
                        LOG("[F1-CACHE-TRACE] protocol_error=open_failed file=%s\n",
                            FLAGS_f1_cache_trace_file.c_str());
                        std::abort();
                    }
                    const uint64_t magic = cache_patch::kTraceMagic;
                    m_f1_cache_trace.write(reinterpret_cast<const char *>(&magic), sizeof(magic));
                }
                const auto adjacency =
                    m_vcsr_dev_graph_allocator->HostObject().adjacency_view();
                std::vector<cache_patch::CandidateRecord> records;
                records.reserve(ids.size());
                for (const index_t id : ids) {
                    records.push_back({id, adjacency.Degree(id)});
                }
                const uint64_t capacity_edges = graph_datum.num_of_cache;
                const bool unchanged =
                    m_f1_cache_trace_initialized &&
                    records == m_f1_previous_cache_candidates;
                const uint64_t count = unchanged ? 0 : records.size();
                m_f1_cache_trace.write(reinterpret_cast<const char *>(&batch), sizeof(batch));
                m_f1_cache_trace.write(reinterpret_cast<const char *>(&capacity_edges),
                                       sizeof(capacity_edges));
                m_f1_cache_trace.write(reinterpret_cast<const char *>(&count), sizeof(count));
                uint64_t admitted_edges = unchanged ? m_f1_previous_cache_edges : 0;
                if (!unchanged) {
                    for (const auto &record : records) {
                        admitted_edges += record.degree;
                        m_f1_cache_trace.write(
                            reinterpret_cast<const char *>(&record.vertex),
                            sizeof(record.vertex));
                        m_f1_cache_trace.write(
                            reinterpret_cast<const char *>(&record.degree),
                            sizeof(record.degree));
                    }
                }
                m_f1_previous_cache_candidates = std::move(records);
                m_f1_previous_cache_edges = admitted_edges;
                m_f1_cache_trace_initialized = true;
                m_f1_cache_trace.flush();
                LOG("[F1-CACHE-TRACE] batch=%u admitted_vertices=%llu admitted_edges=%llu changed_records=%llu capacity_edges=%llu bytes=%llu\n",
                    batch,
                    static_cast<unsigned long long>(ids.size()),
                    static_cast<unsigned long long>(admitted_edges),
                    static_cast<unsigned long long>(count),
                    static_cast<unsigned long long>(capacity_edges),
                    static_cast<unsigned long long>(sizeof(batch) + sizeof(capacity_edges) +
                                                    sizeof(count) + count *
                                                        (sizeof(index_t) + sizeof(uint32_t))));
            }

            void LoadCache(){
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                Loader &load_update = *m_load_update;
                groute::Stream &stream_s = *m_stream;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                AlgoVariant next_policy[FLAGS_SEGMENT];
                for(index_t i = 0; i < FLAGS_SEGMENT; i++){
                    next_policy[i] = m_policy_decision_maker.GetInitPolicy();
                }
                Stopwatch sw_load(true);
                index_t seg_snode,seg_enode;
                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                        RebuildWorklist_delta(app_inst,vcsr_graph,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }
                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                ExecutePolicy_MF_topo(next_policy);
                cudaDeviceSynchronize();
                sw_load.stop();
                LOG("加载缓存数据时间  : %f ms \n",sw_load.ms());
            }

            void ExecutePolicy_MF_topo(AlgoVariant *algo_variant) {
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                index_t seg_snode,seg_enode;
                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    stream_id = seg_idx % FLAGS_n_stream;
                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        m_vcsr_dev_graph_allocator->SwitchZC();
                        zcflag = true;
                        RunSyncPushDDBAmend_cache(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                           vcsr_graph,
                        //    type_device,
                           graph_datum,
                           m_engine_options,
                           stream[stream_id]);
                    }
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
            }
//Loadgraph from the data structure to the segment_structure
        void LoadGraph() {
      Stopwatch sw_load(true);
      groute::graphs::host::PMAGraph &vcsr_graph = m_groute_context->host_pma_small;
      if (FLAGS_SEGMENT <= 0 ||
          FLAGS_SEGMENT > static_cast<int32_t>(GraphDatum::kMaxSegments)) {
          LOG("[SEGMENT-ERROR] configured=%d valid_range=[1,%u]\n",
              FLAGS_SEGMENT,
              GraphDatum::kMaxSegments);
          std::exit(EXIT_FAILURE);
      }
      index_t m_nsegs = FLAGS_SEGMENT;
      uint64_t seg_sedge_csr, seg_eedge_csr;
      index_t seg_snode,seg_enode, seg_nnodes;
      uint64_t seg_nedges_csr;
      uint64_t seg_nedges = round_up(vcsr_graph.elem_capacity, m_nsegs);
      uint64_t seg_nedges_csr_max = 0;  //dev memory
      uint64_t edge_num = 0;
      index_t node_id = 0;
      uint64_t out_degree;
      std::vector<index_t> nnodes_num;
      seg_snode = node_id;
      m_groute_context->seg_snode[0] = seg_snode;
      vcsr_graph.sync_vertices_[vcsr_graph.nnodes].index =  vcsr_graph.elem_capacity;
      for(index_t seg_idx = 0; node_id < vcsr_graph.nnodes ; seg_idx++){
          if (seg_idx >= static_cast<index_t>(FLAGS_SEGMENT)) {
              LOG("[SEGMENT-ERROR] generated_more_than_configured configured=%d node=%u\n",
                  FLAGS_SEGMENT,
                  node_id);
              std::abort();
          }
          m_groute_context->seg_snode[seg_idx] = node_id;
          while(edge_num < seg_nedges && node_id < vcsr_graph.nnodes){
            out_degree = vcsr_graph.end_edge(node_id) - vcsr_graph.begin_edge(node_id);
            edge_num = edge_num + out_degree;
            node_id++;
           }
           if(node_id == vcsr_graph.nnodes){
                seg_enode = node_id ;
            }
           else{
                seg_enode = node_id;
           }
            seg_nnodes = seg_enode - seg_snode;

            m_running_info.nnodes_seg[seg_idx] = seg_nnodes;
            nnodes_num.push_back(seg_nnodes);

            m_groute_context->seg_enode[seg_idx] = seg_enode;
            seg_sedge_csr = vcsr_graph.sync_vertices_[seg_snode].index;
            seg_eedge_csr = vcsr_graph.sync_vertices_[seg_enode].index;
            seg_nedges_csr = seg_eedge_csr - seg_sedge_csr;

            m_running_info.total_workload_seg[seg_idx] = seg_nedges_csr;
            seg_nedges_csr_max = max(seg_nedges_csr_max,seg_nedges_csr);

            m_groute_context->seg_sedge_csr[seg_idx] = seg_sedge_csr;
            m_groute_context->seg_nedge_csr[seg_idx] = seg_nedges_csr;

            // LOG("seg_idx : %d, seg_snode : %d,seg_enode : %d, seg_sedge_csr : %d,seg_eedge_csr : %d, seg_nedge_csr : %d\n", seg_idx, seg_snode, seg_enode, m_groute_context->seg_sedge_csr[seg_idx], seg_eedge_csr, m_groute_context->seg_nedge_csr[seg_idx]);
            edge_num = 0;
              seg_snode = node_id;
            }

        if (nnodes_num.size() > static_cast<size_t>(FLAGS_SEGMENT)) {
            LOG("[SEGMENT-ERROR] generated=%llu configured=%d\n",
                static_cast<unsigned long long>(nnodes_num.size()),
                FLAGS_SEGMENT);
            std::abort();
        }
        while (nnodes_num.size() < static_cast<size_t>(FLAGS_SEGMENT)) {
            const index_t seg_idx = static_cast<index_t>(nnodes_num.size());
            const index_t empty_node = vcsr_graph.nnodes;
            const uint64_t empty_edge = vcsr_graph.sync_vertices_[empty_node].index;
            m_groute_context->seg_snode[seg_idx] = empty_node;
            m_groute_context->seg_enode[seg_idx] = empty_node;
            m_groute_context->seg_sedge_csr[seg_idx] = empty_edge;
            m_groute_context->seg_nedge_csr[seg_idx] = 0;
            m_running_info.nnodes_seg[seg_idx] = 0;
            m_running_info.total_workload_seg[seg_idx] = 0;
            nnodes_num.push_back(0);
        }

        m_groute_context->segment_ct = FLAGS_SEGMENT;
        m_groute_context->SetDevice(0);

        // m_csr_dev_graph_allocator = std::unique_ptr<groute::graphs::single::CSRGraphAllocator>(
        //     new groute::graphs::single::CSRGraphAllocator(csr_graph,seg_nedges_csr_max));
        LOG("seg_nedges_csr_max = %d\n",seg_nedges_csr_max);
        uint64_t chunk_required_edges = 0;
        for (index_t source = 0; source < vcsr_graph.nnodes; ++source) {
            chunk_required_edges += topology::SourceLocalChunkStore::RequiredChunkCapacity(
                vcsr_graph.sync_vertices_[source].degree);
        }
        const uint64_t chunk_headroom = std::max<uint64_t>(
            chunk_required_edges / 8, 1ULL << 20);
        topology::ChunkArenaOptions chunk_options;
        chunk_options.capacity_edges = chunk_required_edges + chunk_headroom;
        chunk_options.slab_capacity_edges = 1ULL << 24;
        chunk_options.minimum_chunk_edges = 4;
        chunk_options.pinned = true;
        m_chunk_store.reset(new topology::SourceLocalChunkStore(
            vcsr_graph.nnodes, chunk_options));
        for (index_t source = 0; source < vcsr_graph.nnodes; ++source) {
            const uint64_t begin = vcsr_graph.sync_vertices_[source].index;
            const index_t degree = vcsr_graph.sync_vertices_[source].degree;
            m_chunk_store->LoadSource(source, std::vector<index_t>(
                vcsr_graph.edges_ + begin, vcsr_graph.edges_ + begin + degree));
        }
        m_chunk_store->FinalizeLoad(vcsr_graph.nedges);
        m_vcsr_dev_graph_allocator = std::unique_ptr<groute::graphs::single::PMAGraphAllocator>(new groute::graphs::single::PMAGraphAllocator(vcsr_graph,seg_nedges_csr_max));
        m_vcsr_dev_graph_allocator->BindChunkStore(*m_chunk_store);
        LOG("[C3-CHUNK-LOAD] edges=%llu capacity_edges=%llu slabs=%zu metadata_bytes=%llu\n",
            static_cast<unsigned long long>(m_chunk_store->EdgeCount()),
            static_cast<unsigned long long>(chunk_options.capacity_edges),
            m_chunk_store->SlabCount(),
            static_cast<unsigned long long>(m_chunk_store->MetadataBytes()));

        if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
            const uint32_t hardware_workers = std::thread::hardware_concurrency();
            const uint32_t reverse_workers = std::max<uint32_t>(
                1, std::min<uint32_t>(20, hardware_workers == 0 ? 1 : hardware_workers));
            Stopwatch sw_reverse_index(true);
            m_reverse_index.Build(vcsr_graph, reverse_workers);
            sw_reverse_index.stop();
            LOG("[CPU-REVERSE-INDEX] base_edges=%llu workers=%u build_ms=%.3f overlay_edges=0\n",
                static_cast<unsigned long long>(m_reverse_index.BaseEdgeCount()),
                reverse_workers,
                sw_reverse_index.ms());
        }

        m_graph_datum = std::unique_ptr<GraphDatum>(new GraphDatum(vcsr_graph,seg_nedges_csr_max,nnodes_num));
        m_device_affected_vertices = std::move(groute::Queue<index_t>(
            std::max<uint32_t>(vcsr_graph.nnodes, 1)));
        m_device_affected_vertices.ResetAsync(m_stream->cuda_stream);
        if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
            GROUTE_CUDA_CHECK(cudaMalloc(
                reinterpret_cast<void **>(&m_device_gpu_repair_changed),
                sizeof(unsigned int)));
            GROUTE_CUDA_CHECK(cudaMalloc(
                reinterpret_cast<void **>(&m_device_gpu_repair_changed_vertices),
                sizeof(index_t) * std::max<uint32_t>(vcsr_graph.nnodes, 1)));
        }
        m_repair_source_versions.assign(vcsr_graph.nnodes, 0);
        m_repair_source_accepted_versions.assign(vcsr_graph.nnodes, 0);
        m_stream->Sync();
        const uint64_t changed_queue_capacity_u64 =
            std::max<uint64_t>(std::max<uint64_t>(vcsr_graph.nnodes, 1),
                               std::min<uint64_t>(vcsr_graph.elem_capacity,
                                                  seg_nedges_csr_max * std::max<uint32_t>(FLAGS_n_stream, 1)));
        m_device_insertion_changed_vertices =
            std::move(groute::Queue<index_t>(static_cast<uint32_t>(
                std::min<uint64_t>(changed_queue_capacity_u64,
                                   std::numeric_limits<uint32_t>::max()))));
        m_device_gpu_to_cpu_boundary_vertices =
            std::move(groute::Queue<index_t>(static_cast<uint32_t>(
                std::min<uint64_t>(std::max<uint64_t>(vcsr_graph.nnodes, 1),
                                   std::numeric_limits<uint32_t>::max()))));
        m_device_gpu_to_cpu_boundary_vertices.ResetAsync(m_stream->cuda_stream);
        m_stream->Sync();
        PrepareCpuOwnerRuntimeStorage();
        if (!FLAGS_e0b_trace_file.empty()) {
            if (FLAGS_sssp_cpu_partition_capacity != 0 ||
                !FLAGS_sssp_cpu_domain_map.empty()) {
                LOG("[E0B-TRACE] protocol_error=trace_requires_capacity_zero capacity=%d\n",
                    FLAGS_sssp_cpu_partition_capacity);
                std::abort();
            }
            m_e0b_trace.open(FLAGS_e0b_trace_file,
                             std::ios::out | std::ios::trunc);
            if (!m_e0b_trace.is_open()) {
                LOG("[E0B-TRACE] protocol_error=open_failed path=%s\n",
                    FLAGS_e0b_trace_file.c_str());
                std::abort();
            }
            m_e0b_trace
                << "# E0B_TRACE_V1 segments=" << FLAGS_SEGMENT
                << " fields=type,epoch,round,region_metrics\n";
            for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                m_e0b_trace << "V\t" << seg << '\t'
                            << m_groute_context->seg_snode[seg] << '\t'
                            << m_groute_context->seg_enode[seg] << '\n';
            }
            m_e0b_trace.flush();
            m_e0b_region_activity.resize(FLAGS_SEGMENT);
            LOG("[E0B-TRACE] enabled=1 path=%s segments=%d\n",
                FLAGS_e0b_trace_file.c_str(), FLAGS_SEGMENT);
        }

        sw_load.stop();

        m_running_info.time_load_graph = sw_load.ms();

        LOG("Load graph time: %f ms (excluded)\n", sw_load.ms());

        m_running_info.nnodes = m_groute_context->nvtxs;
        m_running_info.nedges = m_groute_context->nedges;
        m_running_info.total_workload = m_groute_context->nedges * FLAGS_edge_factor;
        current_priority = m_engine_options.GetPriorityThreshold();
    }
    /*
        * Init Graph Value and buffer fields
        */

        void InitGraph(UnusedData &...data) {
            Stopwatch sw_init(true);

            m_app_inst = std::unique_ptr<AppImplDeviceObject>(new AppImplDeviceObject(data...));
            groute::Stream &stream_s = *m_stream;
            GraphDatum &graph_datum = *m_graph_datum;
            const auto &dev_vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
            const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
            dim3 grid_dims, block_dims;

            m_app_inst->m_vcsr_graph = dev_vcsr_graph;
            m_app_inst->m_nnodes = graph_datum.nnodes;
            m_app_inst->m_nedges = graph_datum.nedges;
            m_app_inst->m_p_current_round = graph_datum.m_current_round.dev_ptr;
            // Launch kernel to init value/buffer fields
            KernelSizing(grid_dims, block_dims, work_source.get_size());
            auto &app_inst = *m_app_inst;
            // auto &result_dyn_graph = result_graph.dyn();
            // result_dyn_graph.Allocate(graph_datum.nnodes);
            kernel::InitGraph
            << < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                work_source,
                graph_datum.d_id,
                graph_datum.d_hotness,
                graph_datum.GetParentDeviceObject(),
                graph_datum.GetValueDeviceObject(),
                graph_datum.GetBufferDeviceObject());
            stream_s.Sync();

            index_t seg_snode,seg_enode;
            index_t stream_id;

            for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                stream_id = seg_idx % FLAGS_n_stream;
                seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                seg_enode = m_groute_context->seg_enode[seg_idx];
                    RebuildArrayWorklist(app_inst,
                    graph_datum,
                    stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
            }

            for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                stream[stream_idx].Sync();
            }
            // m_groute_context->host_pma_small.PrintHistogram(graph_datum.m_in_degree.dev_ptr,graph_datum.m_out_degree.dev_ptr);
            m_running_info.time_init_graph = sw_init.ms();

            sw_init.stop();

            LOG("InitGraph: %f ms (excluded)\n", sw_init.ms());
        }

        void SaveToJson() {
            JsonWriter &writer = JsonWriter::getInst();

            writer.write("time_input_active_node", m_running_info.time_overhead_input_active_node);
            writer.write("time_output_active_node", m_running_info.time_overhead_output_active_node);
            writer.write("time_input_workload", m_running_info.time_overhead_input_workload);
            writer.write("time_output_workload", m_running_info.time_overhead_output_workload);
            writer.write("time_queue2bitmap", m_running_info.time_overhead_queue2bitmap);
            writer.write("time_bitmap2queue", m_running_info.time_overhead_bitmap2queue);
            writer.write("time_rebuild_worklist", m_running_info.time_overhead_rebuild_worklist);
            writer.write("time_priority_sample", m_running_info.time_overhead_sample);
            writer.write("time_sort_worklist", m_running_info.time_overhead_wl_sort);
            writer.write("time_unique_worklist", m_running_info.time_overhead_wl_unique);
            writer.write("time_kernel", m_running_info.time_kernel);
            writer.write("time_total", m_running_info.time_total);
            writer.write("time_per_round", m_running_info.time_total / m_running_info.current_round);
            writer.write("num_iteration", (int) m_running_info.current_round);

            if (m_engine_options.IsForceVariant()) {
                writer.write("force_variant", m_engine_options.GetAlgoVariant().ToString());
            }

            if (m_engine_options.IsForceLoadBalancing(MsgPassing::PUSH)) {
                writer.write("force_push_load_balancing",
                 LBToString(m_engine_options.GetLoadBalancing(MsgPassing::PUSH)));
            }

            if (m_engine_options.IsForceLoadBalancing(MsgPassing::PULL)) {
                writer.write("force_pull_load_balancing",
                 LBToString(m_engine_options.GetLoadBalancing(MsgPassing::PULL)));
            }

            if (m_engine_options.GetPriorityType() == Priority::NONE) {
                writer.write("priority_type", "none");
                } else if (m_engine_options.GetPriorityType() == Priority::LOW_HIGH) {
                    writer.write("priority_type", "low_high");
                    writer.write("priority_delta", m_engine_options.GetPriorityThreshold());
                    } else if (m_engine_options.GetPriorityType() == Priority::SAMPLING) {
                        writer.write("priority_type", "sampling");
                        writer.write("cut_threshold", m_engine_options.GetCutThreshold());
                    }

                    writer.write("fused_kernel", m_engine_options.IsFused() ? "YES" : "NO");
                    writer.write("max_iteration_reached",
                     m_running_info.current_round == 1000 ? "YES" : "NO");
                //writer.write("date", get_now());
                writer.write("device", m_dev_props.name);
                writer.write("dataset", FLAGS_graphfile);
                writer.write("nnodes", (int) m_graph_datum->nnodes);
                writer.write("nedges", (int) m_graph_datum->nedges);
                writer.write("algo_type", m_running_info.m_algo_type == AlgoType::TRAVERSAL_SCHEME ? "TRAVERSAL_SCHEME"
                   : "ITERATIVE_SCHEME");
        }

            void PrintInfo() {
                LOG("--------------Overhead--------------\n");
                LOG("Rebuild worklist: %f\n", m_running_info.time_overhead_rebuild_worklist);
                LOG("Priority sample: %f\n", m_running_info.time_overhead_sample);
                LOG("hybrid Worlist: %f\n", m_running_info.time_overhead_hybrid);
                LOG("Unique Worklist: %f\n", m_running_info.time_overhead_wl_unique);
                LOG("--------------Time statistics---------\n");
                LOG("Kernel time: %f\n", m_running_info.time_kernel);
                LOG("Total time: %f\n", m_running_info.time_total);
                LOG("Total rounds: %d\n", m_running_info.current_round);
                LOG("Time/round: %f\n", m_running_info.time_total / m_running_info.current_round);
                LOG("filter_num: %d\n", m_running_info.explicit_num);
                LOG("zerocopy_num: %d\n", m_running_info.zerocopy_num);
                LOG("compaction_num: %d\n", m_running_info.compaction_num);


                LOG("--------------Engine info-------------\n");
                if (m_engine_options.IsForceVariant()) {
                    LOG("Force variant: %s\n", m_engine_options.GetAlgoVariant().ToString().data());
                }

                if (m_engine_options.IsForceLoadBalancing(MsgPassing::PUSH)) {
                    LOG("Force Push Load balancing: %s\n",
                        LBToString(m_engine_options.GetLoadBalancing(MsgPassing::PUSH)).data());
                }

                if (m_engine_options.IsForceLoadBalancing(MsgPassing::PULL)) {
                    LOG("Force Pull Load balancing: %s\n",
                        LBToString(m_engine_options.GetLoadBalancing(MsgPassing::PULL)).data());
                }

                if (m_engine_options.GetPriorityType() == Priority::NONE) {
                    LOG("Priority type: NONE\n");
                    } else if (m_engine_options.GetPriorityType() == Priority::LOW_HIGH) {
                        LOG("Priority type: LOW_HIGH\n");
                        LOG("Priority delta: %f\n", m_engine_options.GetPriorityThreshold());
                        } else if (m_engine_options.GetPriorityType() == Priority::SAMPLING) {
                            LOG("Priority type: Sampling\n");
                            LOG("Cut threshold: %f\n", m_engine_options.GetCutThreshold());
                        }

                        LOG("Fused kernel: %s\n", m_engine_options.IsFused() ? "YES" : "NO");
                        LOG("Max iteration reached: %s\n", m_running_info.current_round == 1000 ? "YES" : "NO");


                        LOG("-------------Misc-------------------\n");
                //LOG("Date: %s\n", get_now().data());
                LOG("Device: %s\n", m_dev_props.name);
                LOG("Dataset: %s\n", FLAGS_graphfile.data());
                LOG("Algo type: %s\n",
                    m_running_info.m_algo_type == AlgoType::TRAVERSAL_SCHEME ? "TRAVERSAL_SCHEME" : "ITERATIVE_SCHEME");
            }

            //traditional graph processing
            void Start(index_t priority_detal = 0) {

                GraphDatum &graph_datum = *m_graph_datum;
                graph_datum.priority_detal = priority_detal;
                AlgoVariant next_policy[FLAGS_SEGMENT];
                for(index_t i = 0; i < FLAGS_SEGMENT; i++){
                    next_policy[i] = m_policy_decision_maker.GetInitPolicy();
                }
                bool convergence = false;
                Stopwatch sw_total(true);
                LoadOptions();
                int round = 0;
                while (!convergence) {
                  PreComputationBW();
                  ExecutePolicy_Converge(next_policy);
                //   GatherTransfer();
                  round++;
                  int convergence_check = 0;
                  for(index_t seg_id = 0; seg_id < FLAGS_SEGMENT; seg_id++){
                       if(m_running_info.input_active_count_seg[seg_id] == 0){
                           convergence_check++;
                       }
                   }
                  if(convergence_check == FLAGS_SEGMENT){
                        convergence = true;
                  }
                }
               sw_total.stop();
               m_running_info.time_total = sw_total.ms();
               LOG("Iterate all time: %f ms (excluded)\n", sw_total.ms());
               if (m_cpu_domain_map_enabled) {
                   Stopwatch sw_domain_init(true);
                   GatherCpuDomainState();
                   sw_domain_init.stop();
                   const uint64_t bytes =
                       static_cast<uint64_t>(m_cpu_owned_vertices.size()) *
                       (sizeof(TValue) + sizeof(TBuffer) + sizeof(TValue));
                   LOG("[E2C-PERSISTENT-STATE] event=initialize cpu_vertices=%llu bytes=%llu state_epoch=%u init_ms=%.3f (excluded)\n",
                       static_cast<unsigned long long>(m_cpu_owned_vertices.size()),
                       static_cast<unsigned long long>(bytes),
                       m_cpu_domain_state_epoch, sw_domain_init.ms());
               }
            }

            void PrintCacheL1(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                graph_datum.GatherCacheL1();
            }

            void PrintCacheL3(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                graph_datum.GatherCacheL3();
            }
            void PrintCacheNode_verify(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                //把缓存边数据拷贝回CPU，获得host_cache
                graph_datum.GatherCacheL1();
                //把缓存点索引拷贝回CPU获得vertices_【node】.virtual_start
                m_vcsr_dev_graph_allocator->BackNode();
                LOG("--------Verify cache index----------\n");
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->HostObject();
                const auto adjacency = vcsr_graph.adjacency_view();
                uint64_t num_of_dst = 0;
                for(index_t i = 0; i<vcsr_graph.nnodes; i++){
                    if(vcsr_graph.vertices_[i].cache){
                        uint32_t hot_deg = adjacency.Degree(i);
                        uint64_t start_d = vcsr_graph.vertices_[i].virtual_start;
                        uint32_t dev_deg = vcsr_graph.vertices_[i].virtual_degree;
                        uint64_t size = vcsr_graph.vertices_[i].virtual_degree+vcsr_graph.vertices_[i].virtual_start;
                        // printf("vtx %d h_0 %d  h_1 %d h_2 %d h_3 %d\n",i,vcsr_graph.vertices_[i].hotness[0],vcsr_graph.vertices_[i].hotness[1],vcsr_graph.vertices_[i].hotness[2],vcsr_graph.vertices_[i].hotness[3]);
                        // for(auto j = 0; j<  dev_deg ;j++){
                        //     printf("src %d cache_dst %d  ",i,graph_datum.host_cache[start_d+j]);
                        //     printf("hot_dst %d\n",vcsr_graph.edges_[start_h+j]);

                        // }
                        if(size>=graph_datum.num_of_cache){
                            printf("node %d d_start %d size %d\n",i,start_d,dev_deg);
                        }
                        if(start_d>=graph_datum.num_of_cache){
                            printf("node %d d_start  %d\n",i,start_d);
                        }
                        if(hot_deg!=dev_deg)LOG("%d h_deg %d d_deg %d\n",i,hot_deg,vcsr_graph.vertices_[i].virtual_degree);
                        for(auto j = 0; j< hot_deg; j++){
                            if(adjacency.EdgeAt(i, j)!=graph_datum.host_cache[start_d+j]){
                                printf("src %d cache_dst %d  ",i,graph_datum.host_cache[start_d+j]);
                                printf("hot_dst %d\n",adjacency.EdgeAt(i, j));

                            }
                        }
                    }
                }
                printf("dst为-1的边数量 %d\n",num_of_dst);
                LOG("--------Verify Passed----------\n");
                // m_vcsr_dev_graph_allocator->BackNodeToD();
            }

            void PrintCacheNode_verify_L3(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                //把缓存边数据拷贝回CPU，获得host_cache
                graph_datum.GatherCacheL3();
                //把缓存点索引拷贝回CPU获得vertices_【node】.virtual_start
                m_vcsr_dev_graph_allocator->BackNode();
                LOG("--------Verify cache index----------\n");
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->HostObject();
                const auto adjacency = vcsr_graph.adjacency_view();
                uint64_t num_of_dst = 0;
                for(index_t i = 0; i<vcsr_graph.nnodes; i++){
                    if(vcsr_graph.vertices_[i].cache){
                        uint32_t hot_deg = adjacency.Degree(i);
                        uint64_t start_d = vcsr_graph.vertices_[i].third_start;
                        uint32_t dev_deg = vcsr_graph.vertices_[i].third_degree;
                        uint64_t size = start_d+dev_deg;
                        // printf("vtx %d h_0 %d  h_1 %d h_2 %d h_3 %d\n",i,vcsr_graph.vertices_[i].hotness[0],vcsr_graph.vertices_[i].hotness[1],vcsr_graph.vertices_[i].hotness[2],vcsr_graph.vertices_[i].hotness[3]);
                        // for(auto j = 0; j<  dev_deg ;j++){
                        //     printf("src %d cache_dst %d  ",i,graph_datum.host_cache[start_d+j]);
                        //     printf("hot_dst %d\n",vcsr_graph.edges_[start_h+j]);

                        // }
                        if(size>=graph_datum.num_of_cache){
                            printf("node %d d_start %d size %d\n",i,start_d,dev_deg);
                        }
                        if(start_d>=graph_datum.num_of_cache){
                            printf("node %d d_start  %d\n",i,start_d);
                        }
                        if(hot_deg!=dev_deg)LOG("%d h_deg %d d_deg %d\n",i,hot_deg,dev_deg);
                        for(auto j = 0; j< hot_deg; j++){
                            if(adjacency.EdgeAt(i, j)!=graph_datum.host_cache_l3[start_d+j]){
                                printf("src %d cache_dst %d  ",i,graph_datum.host_cache_l3[start_d+j]);
                                printf("hot_dst %d\n",adjacency.EdgeAt(i, j));

                            }
                        }
                    }
                }
                printf("dst为-1的边数量 %d\n",num_of_dst);
                LOG("--------Verify Passed----------\n");
                // m_vcsr_dev_graph_allocator->BackNodeToD();
            }

            void Compare_to_cache(){
                GraphDatum &graph_datum = *m_graph_datum;
                graph_datum.GatherCacheL3();
                graph_datum.GatherCacheL1();
                for(uint64_t j =0; j < graph_datum.num_of_cache;j++){
                    if(graph_datum.host_cache[j]!=graph_datum.host_cache_l3[j]){
                        printf("err %d -> %d\n",graph_datum.host_cache[j],graph_datum.host_cache_l3[j]);
                    }
                }
            }

            void PrintCacheNode(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                //把缓存边数据拷贝回CPU，获得host_cache
                graph_datum.GatherCacheL1();
                //把缓存点索引拷贝回CPU获得vertices_【node】.virtual_start
                m_vcsr_dev_graph_allocator->BackNode();
                LOG("--------Verify cache index----------\n");
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->HostObject();
                const auto adjacency = vcsr_graph.adjacency_view();
                uint64_t num_of_dst = 0;
                for(index_t i = 0; i<vcsr_graph.nnodes; i++){
                    for(auto k = 0; k< adjacency.Degree(i); k++){
                        if(adjacency.EdgeAt(i, k)==std::numeric_limits<index_t>::max()) {
                            printf("wrong src %d dst %d\n",i,adjacency.EdgeAt(i, k));
                            num_of_dst++;}
                    }
                    if(vcsr_graph.vertices_[i].cache){

                        uint64_t start_h = adjacency.Begin(i);
                        uint32_t hot_deg = adjacency.Degree(i);
                        uint64_t start_d = vcsr_graph.vertices_[i].virtual_start;
                        uint32_t dev_deg = vcsr_graph.vertices_[i].virtual_degree;
                        uint64_t size = vcsr_graph.vertices_[i].virtual_degree+vcsr_graph.vertices_[i].virtual_start;
                        printf("node %d gpu index  %d gpu deg %d\n",i,start_d,dev_deg);
                        printf("node %d cpu index  %d cpu deg %d\n",i,start_h,hot_deg);
                        for(auto j = 0; j<  dev_deg ;j++){
                            printf("src %d cache_dst %d  ",i,graph_datum.host_cache[start_d+j]);
                            printf("hot_dst %d\n",vcsr_graph.edges_[start_h+j]);

                        }
                        if(size>=graph_datum.num_of_cache){
                            printf("node %d d_start %d size %d\n",i,start_d,dev_deg);
                        }
                        if(start_d>=graph_datum.num_of_cache){
                            printf("node %d d_start  %d\n",i,start_d);
                        }
                        if(hot_deg!=dev_deg)LOG("%d h_deg %d d_deg %d\n",i,hot_deg,vcsr_graph.vertices_[i].virtual_degree);
                        for(auto j = 0; j< hot_deg; j++){
                            if(adjacency.EdgeAt(i, j)!=graph_datum.host_cache[start_d+j]){
                                printf("src %d cache_dst %d  ",i,graph_datum.host_cache[start_d+j]);
                                printf("hot_dst %d\n",adjacency.EdgeAt(i, j));

                            }
                        }
                    }
                }
                printf("dst为-1的边数量 %d\n",num_of_dst);
                LOG("--------Verify Passed----------\n");
                // m_vcsr_dev_graph_allocator->BackNodeToD();
            }

            void PrintCacheNode_v2(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                // graph_datum.GatherCacheL1();
                // Stopwatch watch(true);
                m_vcsr_dev_graph_allocator->BackNode();
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->HostObject();
                uint64_t cache_edges = 0;
                uint32_t nodes = 0;
                for(index_t i = 0; i<vcsr_graph.nnodes; i++){
                    if(vcsr_graph.vertices_[i].cache){
                        auto start_h = vcsr_graph.vertices_[i].virtual_start;
                        auto hot_deg = vcsr_graph.vertices_[i].virtual_degree;
                        cache_edges+=hot_deg;
                        nodes++;
                    }
                }
                printf("actually L1 cache nnodes %d  nedges %d\n",nodes,cache_edges);
                // watch.stop();
                // printf("printcache time %f\n",watch.ms());
                // m_vcsr_dev_graph_allocator->BackNodeToD();
            }

            void PrintCacheNode_L3(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                // graph_datum.GatherCacheL1();
                // Stopwatch watch(true);
                m_vcsr_dev_graph_allocator->BackNode();
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->HostObject();
                uint64_t cache_edges = 0;
                uint32_t nodes = 0;
                for(index_t i = 0; i<vcsr_graph.nnodes; i++){
                    if(vcsr_graph.vertices_[i].cache){
                        auto start_h = vcsr_graph.vertices_[i].third_start;
                        auto hot_deg = vcsr_graph.vertices_[i].third_degree;
                        cache_edges+=hot_deg;
                        nodes++;
                    }
                }
                printf("actually L3 cache nnodes %d  nedges %d\n",nodes,cache_edges);
                // watch.stop();
                // printf("printcache time %f\n",watch.ms());
                // m_vcsr_dev_graph_allocator->BackNodeToD();
            }

            const groute::graphs::host::CSRGraph &CSRGraph() const {
                return m_groute_context->host_graph;
            }

            // const groute::graphs::host::CSRGraph &ValidateGraph() const {
            //     return m_groute_context->host_validate_graph;
            // }

            const groute::graphs::host::PMAGraph &PMAGraph() const {
                return m_groute_context->host_pma_small;
            }

            const topology::SourceLocalChunkStore &ChunkStore() const {
                return *m_chunk_store;
            }

            const GraphDatum &GetGraphDatum() const {
                return *m_graph_datum;
            }

            void ExecutePolicy_All(AlgoVariant *algo_variant) {
                auto &app_inst = *m_app_inst;
                // auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                Stopwatch sw_execution(true);
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t seg_snode,seg_enode;
                // m_groute_context->segment_ct = FLAGS_SEGMENT;
                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];                            // start edge
                    seg_nedges_csr = m_groute_context->seg_nedge_csr[seg_idx];

                    stream_id = seg_idx % FLAGS_n_stream;

                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        m_vcsr_dev_graph_allocator->SwitchZC();
                        zcflag = true;
                        RunSyncPushDDB_ALL(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                           vcsr_graph,
                           graph_datum,
                            m_engine_options,
                           stream[stream_id]);
                    }
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
               sw_execution.stop();
               LOG("part add edge time: %f ms (excluded)\n", sw_execution.ms());
            //    sw_round.stop();

            }

            //memory free policy for gpu incremental graph processing
            void ExecutePolicy_MF(AlgoVariant *algo_variant,int *type_device) {
                LOG("------MF PUSH------\n");
                auto &app_inst = *m_app_inst;
                // auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t seg_snode,seg_enode;
                index_t seg_idx_new;

                m_groute_context->segment_ct = FLAGS_SEGMENT;
                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){

                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];                            // start edge
                    seg_nedges_csr = m_groute_context->seg_nedge_csr[seg_idx];

                    stream_id = seg_idx % FLAGS_n_stream;

                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        m_vcsr_dev_graph_allocator->SwitchZC();
                        zcflag = true;
                        RunSyncPushDDBAmend(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                           vcsr_graph,type_device,
                           graph_datum,
                           m_engine_options,
                           stream[stream_id]);
                    }
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
            }

            //Cache filling
            void ExecutePolicy_MF_Cache(AlgoVariant *algo_variant,int *type_device) {
                auto &app_inst = *m_app_inst;
                // auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t seg_snode,seg_enode;
                index_t seg_idx_new;

                m_groute_context->segment_ct = FLAGS_SEGMENT;
                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){

                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];                            // start edge
                    seg_nedges_csr = m_groute_context->seg_nedge_csr[seg_idx];

                    stream_id = seg_idx % FLAGS_n_stream;

                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        m_vcsr_dev_graph_allocator->SwitchZC();
                        zcflag = true;
                        RunSyncPushDDBCache(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                           vcsr_graph,type_device,
                           graph_datum,
                           m_engine_options,
                           stream[stream_id]);
                    }
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
            }


            void ExecutePolicy_Com(AlgoVariant *algo_variant) {
                auto &app_inst = *m_app_inst;
                // auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t seg_snode,seg_enode;
                Stopwatch sw_execution(true);
                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];                            // start edge
                    seg_nedges_csr = m_groute_context->seg_nedge_csr[seg_idx];
                    stream_id = seg_idx % FLAGS_n_stream;
                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        m_vcsr_dev_graph_allocator->SwitchZC();
                        zcflag = true;
                        RunSyncCom(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                               vcsr_graph,
                               graph_datum,
                               m_engine_options,
                           stream[stream_id]);
                    }
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
                sw_execution.stop();
               LOG("flush cache(compact time): %f ms (excluded)\n", sw_execution.ms());
            }


            void get_update_file(){
                m_load_update = std::unique_ptr<Loader>(new Loader(FLAGS_update_size,FLAGS_weight));
                Loader &load_update = *m_load_update;
                load_update.ReadWeightList(FLAGS_updatefile);
                this->added_edges_h = (WEdge*)malloc(sizeof(WEdge)*(load_update.m_add_size));
                this->del_edges_h = (WEdge*)malloc(sizeof(WEdge)*(load_update.m_del_size));
                GROUTE_CUDA_CHECK(cudaHostRegister((void *)(this->added_edges_h), sizeof(WEdge) * (load_update.m_add_size), cudaHostRegisterMapped));

                GROUTE_CUDA_CHECK(cudaHostRegister((void *)(this->del_edges_h), sizeof(WEdge) * (load_update.m_del_size), cudaHostRegisterMapped));

                GROUTE_CUDA_CHECK(cudaMalloc(&(this->work_size_d), 2 * sizeof(uint32_t)));
                EnsureTypeDevicePointer();
                size_t max_patch_records = 0;
                for (const auto &batch_size : load_update.m_batch_size) {
                    max_patch_records = std::max<size_t>(
                        max_patch_records,
                        static_cast<size_t>(batch_size.first) + batch_size.second);
                }
                m_vcsr_dev_graph_allocator->ReserveSparsePublicationCapacity(
                    max_patch_records, FLAGS_check);
            }

            size_t GetUpdateBatchCount() const {
                return m_load_update ? m_load_update->m_batch_size.size() : 0;
            }

            void add_edge(std::pair<index_t,index_t>& local_begin,index_t& NumOfSnapShots){
                Loader &load_update = *m_load_update;

                update_tree_add(local_begin,NumOfSnapShots);
            }

            void compute_hot_vertices(){
                GraphDatum &graph_datum = *m_graph_datum;
                auto &app_inst = *m_app_inst;
                groute::Stream &stream_s = *m_stream;
                const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                const auto &hvcsr = m_vcsr_dev_graph_allocator->HostObject();
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, work_source.get_size());
                kernel::comp_hotness<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source,
                    graph_datum.d_hotness);
                graph_datum.sort_vtx_by_hotness();

                cudaDeviceSynchronize();
                graph_datum.CompareDeviceResult();
                cudaDeviceSynchronize();
            }

            void add_edge_pr(std::pair<index_t,index_t>& local_begin,index_t &NumOfSnapShots){
                Loader &load_update = *m_load_update;
                topology::TopologyMutationBatch additions;
                additions.additions.reserve(
                    load_update.m_batch_size[NumOfSnapShots].first);
                for(index_t i = local_begin.first; i < local_begin.first+load_update.m_batch_size[NumOfSnapShots].first; i++){
                    index_t src_add = load_update.added_edges_w[i].u;
                    index_t dst_add = load_update.added_edges_w[i].v;
                    this->added_edges_h[i].u = src_add;
                    this->added_edges_h[i].v = dst_add;
                    this->added_edges_h[i].w = (dst_add+src_add)%128 + 1;
                    if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
                        m_reverse_index.ApplyInsert(src_add, dst_add);
                    }
                    additions.additions.push_back({src_add, dst_add});
                    m_topology_patch_sources.push_back(src_add);
                }
                const auto metrics = m_chunk_store->ApplyPendingAdditions(additions);
                LOG("[C3-CPU-MUTATION][batch %u phase=add] epoch=%llu touched=%llu changed=%llu written_bytes=%llu relocation_bytes=%llu mutation_ms=%.3f allocation_ms=%.3f\n",
                    NumOfSnapShots,
                    static_cast<unsigned long long>(metrics.epoch),
                    static_cast<unsigned long long>(metrics.touched_sources),
                    static_cast<unsigned long long>(metrics.changed_sources),
                    static_cast<unsigned long long>(metrics.mutation_written_bytes),
                    static_cast<unsigned long long>(metrics.relocation_copied_bytes),
                    metrics.mutation_ms, metrics.allocation_ms);
            }

            void del_edge_pr(std::pair<index_t,index_t>& local_begin,index_t &NumOfSnapShots){
                Loader &load_update = *m_load_update;
                topology::TopologyMutationBatch deletions;
                index_t size = load_update.m_batch_size[NumOfSnapShots].second;
                deletions.deletions.reserve(size);
                for(index_t i = local_begin.second; i < local_begin.second+ size; i++){
                    index_t src_del = load_update.deleted_edges_w[i].u;
                    index_t dst_del = load_update.deleted_edges_w[i].v;
                    deletions.deletions.push_back({src_del, dst_del});
                    m_topology_patch_sources.push_back(src_del);
                }
                const auto metrics = m_chunk_store->ApplyBatch(deletions);
                LOG("[C3-CPU-MUTATION][batch %u phase=delete] epoch=%llu touched=%llu changed=%llu missing_deletes=%llu written_bytes=%llu mutation_ms=%.3f\n",
                    NumOfSnapShots,
                    static_cast<unsigned long long>(metrics.epoch),
                    static_cast<unsigned long long>(metrics.touched_sources),
                    static_cast<unsigned long long>(metrics.changed_sources),
                    static_cast<unsigned long long>(metrics.missing_deletes),
                    static_cast<unsigned long long>(metrics.mutation_written_bytes),
                    metrics.mutation_ms);
            }

            void del_edge(std::pair<index_t,index_t>& local_begin,index_t& NumOfSnapShots){
                LOG("----------Batch: %d---------\n",NumOfSnapShots);
                Loader &load_update = *m_load_update;
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                const uint64_t reclaimed = m_chunk_store->ReclaimThrough(
                    m_chunk_store->PublishedEpoch());
                LOG("[C3-RECLAIM][batch %u] completed_epoch=%llu reclaimed_blocks=%llu\n",
                    NumOfSnapShots,
                    static_cast<unsigned long long>(m_chunk_store->PublishedEpoch()),
                    static_cast<unsigned long long>(reclaimed));
                PrepareTopologyReplayAudit(local_begin, NumOfSnapShots);
                m_topology_patch_sources.clear();
                index_t size = load_update.m_batch_size[NumOfSnapShots].second;
                for(index_t i = local_begin.second; i < local_begin.second+size; i++){
                    index_t src_del = load_update.deleted_edges_w[i].u;
                    index_t dst_del = load_update.deleted_edges_w[i].v;
                    this->del_edges_h[i].u = src_del;
                    this->del_edges_h[i].v = dst_del;
                    this->del_edges_h[i].w = (src_del+dst_del)%128+1;
                    if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
                        m_reverse_index.ApplyDelete(src_del, dst_del);
                    }
                }
                update_tree_del(local_begin,NumOfSnapShots);
            }

            void read_del(std::pair<index_t,index_t> &local_begin,index_t &NumOfSnapShots){
                Loader &load_update = *m_load_update;
                index_t size = load_update.m_batch_size[NumOfSnapShots].second;
                for(index_t i = local_begin.second; i < local_begin.second+size; i++){
                    index_t src_del = load_update.deleted_edges_w[i].u;
                    index_t dst_del = load_update.deleted_edges_w[i].v;
                    this->del_edges_h[i].u = src_del;
                    this->del_edges_h[i].v = dst_del;
                    this->del_edges_h[i].w = (src_del+dst_del)%128+1;
                }
                // LOG("DEBUG pr 1.3 \n");

                uint32_t work_size[2];
                index_t start = local_begin.second;
                work_size[0] = start;
                work_size[1] = size;
                // LOG("DEBUG pr 1.3.1 \n");
                LOG("del start %d \n",work_size[0]);
                LOG("del size %d \n",work_size[1]);
                GROUTE_CUDA_CHECK(cudaHostGetDevicePointer((void **)&(this->del_edges_d), (void *)(this->del_edges_h), 0));
                GROUTE_CUDA_CHECK(cudaMemcpy(this->work_size_d, &work_size[0], 2 * sizeof(uint32_t),cudaMemcpyHostToDevice));
                if (size == 0) {
                    return;
                }
                // LOG("DEBUG pr 1.3.2 \n");

                // Cache validity is changed by the version-checked topology
                // scatter so publication and invalidation share one stream.

            }

            void read_add(std::pair<index_t,index_t> &local_begin,index_t &NumOfSnapShots){
                Loader &load_update = *m_load_update;
                index_t size = load_update.m_batch_size[NumOfSnapShots].first;
                for(index_t i = local_begin.first; i < local_begin.first+size; i++){
                    index_t src_add = load_update.added_edges_w[i].u;
                    index_t dst_add = load_update.added_edges_w[i].v;
                    this->added_edges_h[i].u = src_add;
                    this->added_edges_h[i].v = dst_add;
                    this->added_edges_h[i].w = (src_add+dst_add)%128+1;
                    // printf("host add edge %d %d\n",src_add,dst_add);
                }
                // LOG("DEBUG pr 1.2 \n");
                GROUTE_CUDA_CHECK(cudaHostGetDevicePointer((void **)&(this->added_edges_d), (void *)(this->added_edges_h), 0));
                uint32_t work_size[2];
                work_size[0] = local_begin.first;
                work_size[1] = size;
                m_insertion_seed_begin = work_size[0];
                m_insertion_seed_count = work_size[1];
                // LOG("add start %d \n",work_size[0]);
                // LOG("add size %d \n",work_size[1]);
                GROUTE_CUDA_CHECK(cudaMemcpy(this->work_size_d, &work_size[0], 2 * sizeof(uint32_t),cudaMemcpyHostToDevice));
                if (size == 0) {
                    return;
                }
                // Touched cached sources are invalidated by PublishSparse.
                // LOG("DEBUG pr 1.2.5 \n");
            }

            void Cancelation(std::pair<index_t,index_t>& local_begin,index_t& NumOfSnapShots){
                //回收
                LOG("====this is %d batch====\n",NumOfSnapShots);
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                Loader &load_update = *m_load_update;
                groute::Stream &stream_s = *m_stream;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                type[0] = -1;

                EnsureTypeDevicePointer();
                index_t seg_snode,seg_enode;
                index_t stream_id;
                // LOG("cancel: -----------1-------\n");
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                        RebuildWorklist_AllVertices(app_inst,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }
                // std::cout<<"pr active all node "<<vcsr_graph.nnodes<<std::endl;
                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                AlgoVariant next_policy[FLAGS_SEGMENT];
                for(index_t i = 0; i < FLAGS_SEGMENT; i++){
                    next_policy[i] = m_policy_decision_maker.GetInitPolicy();
                }
                // LOG("cancel: -----------2-----\n");
                // PrintCacheNode();
                Stopwatch sw_execution(true);
                ExecutePolicy_MF(next_policy,type_device);
                // GatherTransfer();
                count();
                sw_execution.stop();
                LOG("取消时间: %f ms (excluded)\n", sw_execution.ms());
                // PrintCacheNode();

                // printf("---------------for cache------------------\n");
                // for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                //     stream_id = seg_idx % FLAGS_n_stream;
                //     seg_snode = m_groute_context->seg_snode[seg_idx];
                //     seg_enode = m_groute_context->seg_enode[seg_idx];
                //         RebuildWorklist_AllVertices(app_inst,
                //         graph_datum,
                //         stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                // }

                // for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                //     stream[stream_idx].Sync();
                // }
                // ExecutePolicy_MF_Cache(next_policy,type_device);


            }
            void ResetCacheMiss(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, work_source.get_size());
            kernel::reset_cache
            << < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (
                work_source,
                graph_datum.count_gpu);
            stream_s.Sync();
                graph_datum.ResetCacheMiss();
            }

            void Resettransfer(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, work_source.get_size());
            kernel::reset_cache
            << < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (
                work_source,
                graph_datum.total_act_d);
            stream_s.Sync();
                graph_datum.Resettransfer();
            }

            void GatherCacheMiss(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->HostObject();
                graph_datum.GatherCacheMiss();
                uint64_t cache_miss =0;
                // UINT64_MAX
                for(index_t i=0;i<vcsr_graph.nnodes;i++){
                    cache_miss += graph_datum.count_cpu[i];
                    graph_datum.count_cpu[i] = 0;
                }
                printf("缓存未命中数量 %llu\n",cache_miss);
                ResetCacheMiss();
            }

            void GatherTransfer(){
                GraphDatum &graph_datum = *m_graph_datum;
                groute::Stream &stream_s = *m_stream;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->HostObject();
                graph_datum.Gathertransfer();
                uint64_t transfer =0;
                // UINT64_MAX
                for(index_t i=0;i<vcsr_graph.nnodes;i++){
                    transfer += graph_datum.total_act[i];
                    graph_datum.total_act[i] = 0;
                }
                printf("传输总量 %llu\n",transfer);
                Resettransfer();;
            }
            void Compensate(std::pair<index_t,index_t>& local_begin,index_t& NumOfSnapShots){
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                Loader &load_update = *m_load_update;
                groute::Stream &stream_s = *m_stream;
                index_t seg_snode,seg_enode;
                index_t stream_id;
                AlgoVariant next_policy[FLAGS_SEGMENT];
                for(index_t i = 0; i < FLAGS_SEGMENT; i++){
                    next_policy[i] = m_policy_decision_maker.GetInitPolicy();
                }

                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                const uint64_t reclaimed = m_chunk_store->ReclaimThrough(
                    m_chunk_store->PublishedEpoch());
                LOG("[C3-RECLAIM][batch %u] completed_epoch=%llu reclaimed_blocks=%llu\n",
                    NumOfSnapShots,
                    static_cast<unsigned long long>(m_chunk_store->PublishedEpoch()),
                    static_cast<unsigned long long>(reclaimed));

                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();

                //update graph on the cpu
                read_del(local_begin,NumOfSnapShots);
                cudaDeviceSynchronize();
                read_add(local_begin,NumOfSnapShots);
                cudaDeviceSynchronize();

                m_topology_patch_sources.clear();
                del_edge_pr(local_begin,NumOfSnapShots);
                add_edge_pr(local_begin,NumOfSnapShots);
                local_begin.second += load_update.m_batch_size[NumOfSnapShots].second;
                local_begin.first += load_update.m_batch_size[NumOfSnapShots].first;

                std::sort(m_topology_patch_sources.begin(), m_topology_patch_sources.end());
                m_topology_patch_sources.erase(std::unique(m_topology_patch_sources.begin(),
                    m_topology_patch_sources.end()), m_topology_patch_sources.end());
                m_vcsr_dev_graph_allocator->PublishSparse(
                    m_topology_patch_sources, stream_s.cuda_stream, FLAGS_check,
                    graph_datum.cache_edges_l1, graph_datum.num_of_cache);
                uint64_t zc_cold_edges = m_chunk_store->EdgeCount();
                if (FLAGS_cache != 0) {
                    zc_cold_edges = 0;
                    for (const index_t source : m_topology_patch_sources) {
                        zc_cold_edges += m_chunk_store->Descriptor(source).degree;
                    }
                }
                for (index_t stream_idx = 0; stream_idx < FLAGS_n_stream; ++stream_idx) {
                    m_vcsr_dev_graph_allocator->WaitForSparsePublication(
                        stream[stream_idx].cuda_stream);
                }
                type[0] = 1;
                float time_total = 0;
                EnsureTypeDevicePointer();

                //incremental computation
                Stopwatch sw_execution(true);
                ExecutePolicy_MF(next_policy,type_device);
                // GatherTransfer();
                // PostComputationBW();
                sw_execution.stop();
                time_total +=sw_execution.ms();
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                        RebuildArrayWorklistINC(app_inst,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }
                for(index_t stream_idx = 0; stream_idx <  FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                const auto publication =
                    m_vcsr_dev_graph_allocator->CompleteSparsePublication();
                if (publication.stale_rejects != 0 ||
                    publication.hash_mismatches != 0) {
                    LOG("[C3-PUBLISH] protocol_error batch=%u stale_version_rejects=%llu gpu_cpu_hash_mismatches=%llu\n",
                        NumOfSnapShots, publication.stale_rejects,
                        publication.hash_mismatches);
                    std::abort();
                }
                LOG("[C3-PUBLISH][batch %u] epoch=%llu patch_records=%zu patch_bytes=%llu h2d_count=%u publication_ms=%.3f stale_version_rejects=%llu cache_invalidations=%llu cache_tail=%llu cache_capacity=%llu zc_cold_edges=%llu gpu_cpu_hash_mismatches=%llu audit=%u\n",
                    NumOfSnapShots,
                    static_cast<unsigned long long>(m_chunk_store->PublishedEpoch()),
                    m_topology_patch_sources.size(),
                    static_cast<unsigned long long>(m_topology_patch_sources.size() * sizeof(topology::TopologyPatchRecord)),
                    m_topology_patch_sources.empty() ? 0U : 1U,
                    publication.publication_ms, publication.stale_rejects,
                    publication.cache_invalidations,
                    publication.cache_tail,
                    static_cast<unsigned long long>(graph_datum.num_of_cache),
                    static_cast<unsigned long long>(zc_cold_edges),
                    publication.hash_mismatches, FLAGS_check ? 1U : 0U);
                LOG("------------PR mf compensate-----------\n");
                count();
                for(index_t stream_idx = 0; stream_idx <  FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                bool convergence = false;
                int current_rount =0 ;
                // m_running_info.current_round = 0;
                while(!convergence){
                  Stopwatch sw_execution_round(true);
                  ExecutePolicy_MF_Converge(next_policy);
                //   GatherTransfer();
                  current_rount++;
                  sw_execution_round.stop();
                  time_total +=sw_execution_round.ms();
                  PostComputationBW_Inc();
                  if (current_rount == 100 ) {//FLAGS_max_iteration
                        convergence = true;
                        LOG("Max iterations reached\n");
                  }
                }
                // sw_execution.stop();

                LOG("迭代时间: %f ms (excluded)\n", time_total);
                LOG("round num : %d  (excluded)\n", current_rount);
                // PrintCacheNode_v2();
                // GatherCacheMiss();
                // GatherTransfer();
                // PrintCacheNode_v2();
            }


            void compact_cache() {
                groute::Stream &stream_s = *m_stream;
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t seg_snode,seg_enode;
                Stopwatch sw_execution(true);
                index_t stream_id;
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                        RebuildArrayWorklist_identify(app_inst,vcsr_graph,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }
                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
               cudaDeviceSynchronize();
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];                            // start edge
                    seg_nedges_csr = m_groute_context->seg_nedge_csr[seg_idx];
                    stream_id = seg_idx % FLAGS_n_stream;

                    m_vcsr_dev_graph_allocator->SwitchZC();
                    zcflag = true;
                    RunSyncCom(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                               vcsr_graph,
                               graph_datum,
                               m_engine_options,
                        stream[stream_id]);
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
               cudaDeviceSynchronize();
               m_vcsr_dev_graph_allocator->HostRiverElement();
               dim3 grid_dims, block_dims;
               const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.num_of_cache);
               KernelSizing(grid_dims, block_dims, work_source.get_size());
                kernel::copy_cache<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (graph_datum.cache_edges_l1,graph_datum.cache_edges_com,work_source);
                stream_s.Sync();
                cudaDeviceSynchronize();
                const auto &work_source_flush_vertex = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
                KernelSizing(grid_dims, block_dims, work_source_flush_vertex.get_size());
                kernel::copy_index<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source_flush_vertex);
                    stream_s.Sync();
                sw_execution.stop();
               LOG("合并缓存时间 cache(compact time): %f ms (excluded)\n", sw_execution.ms());
            }

            void evication_cache(){
                groute::Stream &stream_s = *m_stream;
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();

                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t seg_snode,seg_enode;
                Stopwatch sw_execution(true);
                index_t stream_id;
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, work_source.get_size());
                kernel::flush_cache<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                    vcsr_graph,
                    work_source,
                    graph_datum.d_hotness);
                stream_s.Sync();
                sw_execution.stop();
                LOG("缓存逐出时间 %f\n",sw_execution.ms());
            }


            void ExecutePolicy_MF_Converge(AlgoVariant *algo_variant) {
                // printf("conver iter\n");
                auto &app_inst = *m_app_inst;
                auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                Stopwatch sw_execution(true);
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t seg_snode,seg_enode;

                m_groute_context->segment_ct = FLAGS_SEGMENT;
                index_t seg_exc = 0;
                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];                            // start edge
                    seg_nedges_csr = m_groute_context->seg_nedge_csr[seg_idx];
                    stream_id = seg_idx % FLAGS_n_stream;
                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        m_vcsr_dev_graph_allocator->SwitchZC();
                        zcflag = true;
                        RunSyncPushDDB_MFC(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                           vcsr_graph,
                           graph_datum,
                           m_engine_options,
                           stream[stream_id]);
                    }
                    // act_num+= graph_datum.m_wl_array_in[seg_idx];
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }

            //    PostComputationBW_Inc();

            //    sw_round.stop();

            }
            void PostComputationBW_Inc() {
                // printf("------------PostComputationBW-----------\n");
                int dev_id = 0;
                const groute::Stream &stream_seg = m_groute_context->CreateStream(dev_id);
                GraphDatum &graph_datum = *m_graph_datum;
                AppImplDeviceObject &app_inst = *m_app_inst;
                m_running_info.current_round = m_graph_datum->m_current_round.get_val_D2H();

                Stopwatch sw_unique(true);

                index_t seg_snode,seg_enode;
                index_t stream_id;

                Stopwatch sw_rebuild(true);
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                    RebuildArrayWorklistINC(app_inst,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }

                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                sw_rebuild.stop();
                uint64_t active_count_overall = 0;
                m_running_info.time_overhead_rebuild_worklist += sw_rebuild.ms();
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    index_t active_count = graph_datum.m_wl_array_in_seg[seg_idx].GetCount(stream[stream_id]);
                    graph_datum.seg_active_num[seg_idx] = active_count;

                    m_running_info.input_active_count_seg[seg_idx] = active_count;

                    uint32_t work_size = active_count;
                    dim3 grid_dims, block_dims;
                    // active_count_overall+=work_size;

                }
                // printf("Round act node %d\n",active_count_overall);
                sw_unique.stop();
                m_running_info.time_overhead_wl_unique += sw_unique.ms();

          }

            void reset_delta_vertices(){
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                index_t seg_snode,seg_enode;
                index_t stream_id;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                        RebuildArrayWorklist_reset_delta(app_inst,vcsr_graph,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }
                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                   stream[stream_idx].Sync();
                }
            }

            void GatherCpuDomainState() {
                if (!m_cpu_domain_map_enabled || m_cpu_owned_vertices.empty()) return;
                GraphDatum &graph_datum = *m_graph_datum;
                const uint32_t count = static_cast<uint32_t>(m_cpu_owned_vertices.size());
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, count);
                GatherCpuOwnedState<TValue, TBuffer><<<grid_dims, block_dims>>>(
                    m_device_cpu_owned_vertices, count,
                    graph_datum.GetValueDeviceObject(),
                    graph_datum.GetBufferDeviceObject(),
                    graph_datum.GetParentDeviceObject(),
                    m_device_cpu_owned_values,
                    m_device_cpu_owned_buffers,
                    m_device_cpu_owned_parents);
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_compact_cpu_values.data(), m_device_cpu_owned_values,
                    sizeof(TValue) * count, cudaMemcpyDeviceToHost));
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_compact_cpu_buffers.data(), m_device_cpu_owned_buffers,
                    sizeof(TBuffer) * count, cudaMemcpyDeviceToHost));
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_compact_cpu_parents.data(), m_device_cpu_owned_parents,
                    sizeof(TValue) * count, cudaMemcpyDeviceToHost));
                for (uint32_t i = 0; i < count; ++i) {
                    const index_t vertex = m_cpu_owned_vertices[i];
                    m_cpu_node_values[vertex] = m_compact_cpu_values[i];
                    m_cpu_node_buffers[vertex] = m_compact_cpu_buffers[i];
                    m_cpu_node_parents[vertex] =
                        static_cast<index_t>(m_compact_cpu_parents[i]);
                }
                m_cpu_domain_state_initialized = true;
                m_cpu_domain_state_epoch = m_insertion_epoch;
            }

            void ScatterCpuDomainState() {
                if (!m_cpu_domain_map_enabled || m_cpu_owned_vertices.empty()) return;
                GraphDatum &graph_datum = *m_graph_datum;
                const uint32_t count = static_cast<uint32_t>(m_cpu_owned_vertices.size());
                for (uint32_t i = 0; i < count; ++i) {
                    const index_t vertex = m_cpu_owned_vertices[i];
                    m_compact_cpu_values[i] = m_cpu_node_values[vertex];
                    m_compact_cpu_buffers[i] = m_cpu_node_buffers[vertex];
                    m_compact_cpu_parents[i] =
                        static_cast<TValue>(m_cpu_node_parents[vertex]);
                }
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_device_cpu_owned_values, m_compact_cpu_values.data(),
                    sizeof(TValue) * count, cudaMemcpyHostToDevice));
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_device_cpu_owned_buffers, m_compact_cpu_buffers.data(),
                    sizeof(TBuffer) * count, cudaMemcpyHostToDevice));
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_device_cpu_owned_parents, m_compact_cpu_parents.data(),
                    sizeof(TValue) * count, cudaMemcpyHostToDevice));
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, count);
                ScatterCpuOwnedState<TValue, TBuffer><<<grid_dims, block_dims>>>(
                    m_device_cpu_owned_vertices, count,
                    m_device_cpu_owned_values,
                    m_device_cpu_owned_buffers,
                    m_device_cpu_owned_parents,
                    graph_datum.GetValueDeviceObject(),
                    graph_datum.GetBufferDeviceObject(),
                    graph_datum.GetParentDeviceObject());
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
            }

            void ScatterCpuDomainDirtyState(InsertionRoundStats &stats) {
                if (!m_cpu_domain_map_enabled || m_cpu_dirty_vertices.empty()) return;
                Stopwatch sw_scatter(true);
                std::sort(m_cpu_dirty_vertices.begin(), m_cpu_dirty_vertices.end());
                m_cpu_dirty_vertices.erase(
                    std::unique(m_cpu_dirty_vertices.begin(), m_cpu_dirty_vertices.end()),
                    m_cpu_dirty_vertices.end());
                m_cpu_boundary_proposals.clear();
                m_cpu_boundary_proposals.reserve(m_cpu_dirty_vertices.size());
                for (const index_t vertex : m_cpu_dirty_vertices) {
                    m_cpu_boundary_proposals.push_back({
                        vertex, m_cpu_node_buffers[vertex],
                        m_cpu_node_parents[vertex]});
                }
                EnsureInsertionDeviceCapacity(
                    &m_device_cpu_boundary_proposals,
                    &m_device_cpu_boundary_proposal_capacity,
                    m_cpu_boundary_proposals.size(), stats);
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_device_cpu_boundary_proposals,
                    m_cpu_boundary_proposals.data(),
                    sizeof(CpuRelaxProposal<TBuffer>) * m_cpu_boundary_proposals.size(),
                    cudaMemcpyHostToDevice));
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, m_cpu_boundary_proposals.size());
                ScatterCpuDirtyState<TValue, TBuffer><<<grid_dims, block_dims>>>(
                    m_device_cpu_boundary_proposals,
                    m_cpu_boundary_proposals.size(),
                    m_graph_datum->GetValueDeviceObject(),
                    m_graph_datum->GetBufferDeviceObject(),
                    m_graph_datum->GetParentDeviceObject());
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                stats.cpu_state_scatter_vertices += m_cpu_dirty_vertices.size();
                stats.cpu_state_scatter_bytes +=
                    sizeof(CpuRelaxProposal<TBuffer>) * m_cpu_dirty_vertices.size();
                m_cpu_dirty_vertices.clear();
                sw_scatter.stop();
                stats.cpu_state_scatter_ms += sw_scatter.ms();
            }

            void BeginInsertionEpoch(index_t batch) {
                Stopwatch sw_epoch_prepare(true);
                GraphDatum &graph_datum = *m_graph_datum;
                if (m_device_partition_end_nodes == nullptr) {
                    std::vector<index_t> segment_end_nodes(FLAGS_SEGMENT);
                    for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                        segment_end_nodes[seg] = m_groute_context->seg_enode[seg];
                    }
                    m_partition_owners.assign(
                        FLAGS_SEGMENT,
                        static_cast<uint8_t>(PartitionOwner::GPU));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_partition_end_nodes),
                        sizeof(index_t) * FLAGS_SEGMENT));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_partition_owners),
                        sizeof(uint8_t) * FLAGS_SEGMENT));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_node_state_epoch),
                        sizeof(uint32_t) * graph_datum.nnodes));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_seed_owner_reject_count),
                        sizeof(unsigned long long)));
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        m_device_partition_end_nodes,
                        segment_end_nodes.data(),
                        sizeof(index_t) * FLAGS_SEGMENT,
                        cudaMemcpyHostToDevice));
                    GROUTE_CUDA_CHECK(cudaMemset(
                        m_device_node_state_epoch,
                        0xff,
                        sizeof(uint32_t) * graph_datum.nnodes));
                }

                if (m_insertion_epoch_active) {
                    LOG("[DUAL-RUNTIME] protocol_error=nested_epoch active_epoch=%u\n",
                        m_insertion_epoch);
                    std::abort();
                }
                ++m_insertion_epoch;
                if (m_insertion_epoch == 0) {
                    GROUTE_CUDA_CHECK(cudaMemset(
                        m_device_node_state_epoch,
                        0xff,
                        sizeof(uint32_t) * graph_datum.nnodes));
                    m_insertion_epoch = 1;
                } else if ((m_insertion_epoch & 0xffffU) == 0) {
                    GROUTE_CUDA_CHECK(cudaMemset(
                        m_device_node_state_epoch,
                        0xff,
                        sizeof(uint32_t) * graph_datum.nnodes));
                }

                Stopwatch sw_owner_plan(true);
                uint64_t owner_flag_bytes = 0;
                for (const index_t seg : m_cpu_owned_segments) {
                    const index_t begin = m_groute_context->seg_snode[seg];
                    const index_t end = m_groute_context->seg_enode[seg];
                    owner_flag_bytes += end - begin;
                    std::fill(m_node_cpu_owner.begin() + begin,
                              m_node_cpu_owner.begin() + end, 0);
                    GROUTE_CUDA_CHECK(cudaMemset(
                        m_device_cpu_destination_flags + begin,
                        0,
                        end - begin));
                }
                m_cpu_owned_segments.clear();
                std::fill(m_partition_owners.begin(),
                          m_partition_owners.end(),
                          static_cast<uint8_t>(PartitionOwner::GPU));
                const index_t cpu_capacity =
                    static_cast<index_t>(FLAGS_sssp_cpu_partition_capacity);
                std::vector<std::pair<uint32_t, index_t>> ranked_segments;
                ranked_segments.reserve(FLAGS_SEGMENT);
                std::vector<uint32_t> seed_counts(FLAGS_SEGMENT, 0);
                for (index_t offset = 0; offset < m_insertion_seed_count; ++offset) {
                    const index_t dst =
                        added_edges_h[m_insertion_seed_begin + offset].v;
                    const index_t *position = std::upper_bound(
                        m_groute_context->seg_enode,
                        m_groute_context->seg_enode + FLAGS_SEGMENT,
                        dst);
                    if (position != m_groute_context->seg_enode + FLAGS_SEGMENT) {
                        ++seed_counts[position - m_groute_context->seg_enode];
                    }
                }
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    ranked_segments.push_back({seed_counts[seg], seg});
                }
                std::sort(ranked_segments.begin(), ranked_segments.end(),
                          [](const std::pair<uint32_t, index_t> &lhs,
                             const std::pair<uint32_t, index_t> &rhs) {
                              return lhs.first != rhs.first
                                  ? lhs.first > rhs.first
                                  : lhs.second < rhs.second;
                          });
                for (index_t ordinal = 0; ordinal < cpu_capacity; ++ordinal) {
                    const index_t seg = ranked_segments[ordinal].second;
                    m_partition_owners[seg] =
                        static_cast<uint8_t>(PartitionOwner::CPU);
                    m_cpu_owned_segments.push_back(seg);
                }
                m_insertion_seed_partitions.assign(FLAGS_SEGMENT, 0);
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    if (seed_counts[seg] != 0 &&
                        m_partition_owners[seg] ==
                            static_cast<uint8_t>(PartitionOwner::GPU)) {
                        m_insertion_seed_partitions[seg] = 1;
                    }
                }
                for (const index_t seg : m_cpu_owned_segments) {
                    const index_t begin = m_groute_context->seg_snode[seg];
                    const index_t end = m_groute_context->seg_enode[seg];
                    const size_t count = end - begin;
                    owner_flag_bytes += count;
                    std::fill(m_node_cpu_owner.begin() + begin,
                              m_node_cpu_owner.begin() + end, 1);
                    GROUTE_CUDA_CHECK(cudaMemset(
                        m_device_cpu_destination_flags + begin,
                        1,
                        count));
                }
                sw_owner_plan.stop();
                if (cpu_capacity != 0) {
                    Stopwatch sw_cpu_state_d2h(true);
                    uint64_t cpu_state_d2h_bytes = 0;
                    for (const index_t seg : m_cpu_owned_segments) {
                        const index_t begin = m_groute_context->seg_snode[seg];
                        const index_t end = m_groute_context->seg_enode[seg];
                        const size_t count = end - begin;
                        cpu_state_d2h_bytes +=
                            (sizeof(TValue) + sizeof(TBuffer) + sizeof(index_t)) * count;
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            m_cpu_node_values.data() + begin,
                            graph_datum.GetValueDeviceObject() + begin,
                            sizeof(TValue) * count, cudaMemcpyDeviceToHost));
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            m_cpu_node_buffers.data() + begin,
                            graph_datum.GetBufferDeviceObject() + begin,
                            sizeof(TBuffer) * count, cudaMemcpyDeviceToHost));
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            m_cpu_node_parents.data() + begin,
                            graph_datum.GetParentDeviceObject() + begin,
                            sizeof(index_t) * count, cudaMemcpyDeviceToHost));
                    }
                    sw_cpu_state_d2h.stop();
                    m_device_gpu_to_cpu_boundary_vertices.ResetAsync(
                        m_stream->cuda_stream);
                    m_stream->Sync();
                    LOG("[DUAL-RUNTIME-PREP] batch=%u epoch=%u cpu_partitions=%u owner_flag_bytes=%llu cpu_state_d2h_bytes=%llu owner_plan_ms=%.3f cpu_state_d2h_ms=%.3f\n",
                        batch,
                        m_insertion_epoch,
                        cpu_capacity,
                        static_cast<unsigned long long>(owner_flag_bytes),
                        static_cast<unsigned long long>(cpu_state_d2h_bytes),
                        sw_owner_plan.ms(),
                        sw_cpu_state_d2h.ms());
                }
                if (m_cpu_domain_map_enabled &&
                    !m_cpu_domain_state_initialized) {
                    Stopwatch sw_cpu_state_d2h(true);
                    GatherCpuDomainState();
                    sw_cpu_state_d2h.stop();
                    const uint64_t cpu_state_d2h_bytes =
                        static_cast<uint64_t>(m_cpu_owned_vertices.size()) *
                        (sizeof(TValue) + sizeof(TBuffer) + sizeof(TValue));
                    LOG("[E2-DOMAIN-PREP] batch=%u epoch=%u cpu_vertices=%llu cpu_state_d2h_bytes=%llu cpu_state_d2h_ms=%.3f\n",
                        batch, m_insertion_epoch,
                        static_cast<unsigned long long>(m_cpu_owned_vertices.size()),
                        static_cast<unsigned long long>(cpu_state_d2h_bytes),
                        sw_cpu_state_d2h.ms());
                } else if (m_cpu_domain_map_enabled) {
                    LOG("[E2C-PERSISTENT-STATE][batch %u] event=reuse state_epoch=%u cpu_vertices=%llu cpu_state_d2h_bytes=0\n",
                        batch, m_cpu_domain_state_epoch,
                        static_cast<unsigned long long>(m_cpu_owned_vertices.size()));
                }
                m_cpu_frontier.clear();
                m_cpu_dirty_vertices.clear();
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_device_partition_owners,
                    m_partition_owners.data(),
                    sizeof(uint8_t) * FLAGS_SEGMENT,
                    cudaMemcpyHostToDevice));
                GROUTE_CUDA_CHECK(cudaMemset(
                    m_device_seed_owner_reject_count,
                    0,
                    sizeof(unsigned long long)));
                m_insertion_epoch_active = true;
                m_exact_source_frontier_ready = false;
                m_exact_source_frontier_count = 0;
                graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT].ResetAsync(
                    m_stream->cuda_stream);
                graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT + 1].ResetAsync(
                    m_stream->cuda_stream);
                m_insertion_convergence_round = 0;
                sw_epoch_prepare.stop();
                LOG("[DUAL-RUNTIME-BEGIN] batch=%u epoch=%u gpu_partitions=%d cpu_partitions=%u cpu_capacity=%u domain_map=%d epoch_prepare_ms=%.3f\n",
                    batch,
                    m_insertion_epoch,
                    FLAGS_SEGMENT - cpu_capacity,
                    m_cpu_domain_map_enabled ? 1U : cpu_capacity,
                    cpu_capacity,
                    m_cpu_domain_map_enabled ? 1 : 0,
                    sw_epoch_prepare.ms());
            }

            void EndInsertionEpoch(index_t batch) {
                if (!m_insertion_epoch_active) {
                    return;
                }
                uint64_t local_active = 0;
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    local_active += m_graph_datum->seg_active_num[seg];
                }
                unsigned long long rejected_seeds = 0;
                const uint32_t boundary_active =
                    m_device_gpu_to_cpu_boundary_vertices.GetCount(*m_stream);
                const uint32_t exact_input_active =
                    m_graph_datum->m_wl_array_in_seg[FLAGS_SEGMENT].GetCount(*m_stream);
                const uint32_t exact_output_active =
                    m_graph_datum->m_wl_array_in_seg[FLAGS_SEGMENT + 1].GetCount(*m_stream);
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    &rejected_seeds,
                    m_device_seed_owner_reject_count,
                    sizeof(unsigned long long),
                    cudaMemcpyDeviceToHost));
                if (rejected_seeds != 0 || local_active != 0 ||
                    boundary_active != 0 || exact_input_active != 0 ||
                    exact_output_active != 0 || !m_cpu_frontier.empty()) {
                    LOG("[DUAL-RUNTIME] protocol_error=epoch_not_quiescent epoch=%u rejected=%llu local_active=%llu boundary=%u exact_input=%u exact_output=%u cpu_frontier=%zu\n",
                        m_insertion_epoch,
                        rejected_seeds,
                        static_cast<unsigned long long>(local_active),
                        boundary_active,
                        exact_input_active,
                        exact_output_active,
                        m_cpu_frontier.size());
                    std::abort();
                }
                m_insertion_epoch_active = false;
                LOG("[DUAL-RUNTIME-END] batch=%u epoch=%u seed_owner_rejects=%llu local_active=%llu\n",
                    batch,
                    m_insertion_epoch,
                    rejected_seeds,
                    static_cast<unsigned long long>(local_active));
            }

            void update_tree_add(std::pair<index_t,index_t> &local_begin,index_t &NumOfSnapShots){
                // LOG("-----perform add-----\n");
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                Loader &load_update = *m_load_update;
                groute::Stream &stream_s = *m_stream;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                //init the zero copy policy
                AlgoVariant next_policy[FLAGS_SEGMENT];
                for(index_t i = 0; i < FLAGS_SEGMENT; i++){
                    next_policy[i] = m_policy_decision_maker.GetInitPolicy();
                }
                Stopwatch sw_update_reset(true);
                read_del(local_begin,NumOfSnapShots);
                cudaDeviceSynchronize();
                read_add(local_begin,NumOfSnapShots);
                cudaDeviceSynchronize();
                sw_update_reset.stop();

                Stopwatch sw_cpu_mutation(true);
                add_edge_pr(local_begin,NumOfSnapShots);
                sw_cpu_mutation.stop();
                local_begin.second += load_update.m_batch_size[NumOfSnapShots].second;
                local_begin.first += load_update.m_batch_size[NumOfSnapShots].first;

                std::sort(m_topology_patch_sources.begin(), m_topology_patch_sources.end());
                m_topology_patch_sources.erase(std::unique(m_topology_patch_sources.begin(),
                    m_topology_patch_sources.end()), m_topology_patch_sources.end());
                m_vcsr_dev_graph_allocator->PublishSparse(
                    m_topology_patch_sources, stream_s.cuda_stream, FLAGS_check,
                    graph_datum.cache_edges_l1, graph_datum.num_of_cache);
                for (index_t stream_idx = 0; stream_idx < FLAGS_n_stream;
                     ++stream_idx) {
                    m_vcsr_dev_graph_allocator->WaitForSparsePublication(
                        stream[stream_idx].cuda_stream);
                }
                if (!m_chunk_store->IsPublished()) {
                    LOG("[TOPOLOGY-EPOCH] protocol_error=traversal_before_publication batch=%u pending=%llu published=%llu\n",
                        NumOfSnapShots,
                        static_cast<unsigned long long>(
                            m_chunk_store->PendingEpoch()),
                        static_cast<unsigned long long>(
                            m_chunk_store->PublishedEpoch()));
                    std::abort();
                }
                uint64_t zc_cold_edges = m_chunk_store->EdgeCount();
                if (FLAGS_cache != 0) {
                    zc_cold_edges = 0;
                    for (const index_t source : m_topology_patch_sources) {
                        zc_cold_edges += m_chunk_store->Descriptor(source).degree;
                    }
                }
                VerifyTopologyReplayAudit(NumOfSnapShots);
                if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
                    BeginInsertionEpoch(NumOfSnapShots);
                }
                index_t seg_snode,seg_enode;
                index_t stream_id;
                float add_time = 0;
                Stopwatch sw_load(true);
                if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
                    const index_t add_size = load_update.m_batch_size[NumOfSnapShots].first;
                    if (add_size > 0) {
                        dim3 grid_dims, block_dims;
                        KernelSizing(grid_dims, block_dims, add_size);
                        SeedAddedEdgeFrontier<TValue><<<grid_dims,
                                                       block_dims,
                                                       0,
                                                       stream_s.cuda_stream>>>(
                            this->added_edges_d,
                            this->work_size_d,
                            graph_datum.GetValueDeviceObject(),
                            graph_datum.GetBufferDeviceObject(),
                            graph_datum.GetParentDeviceObject(),
                            std::numeric_limits<TValue>::max(),
                            graph_datum.m_wl_bitmap_out_high.DeviceObject(),
                            m_device_partition_end_nodes,
                            m_device_partition_owners,
                            m_cpu_domain_map_enabled ? m_device_cpu_destination_flags : nullptr,
                            FLAGS_SEGMENT,
                            m_insertion_epoch,
                            m_device_node_state_epoch,
                            m_device_seed_owner_reject_count,
                            m_device_gpu_to_cpu_boundary_values,
                            m_device_gpu_to_cpu_boundary_parents,
                            m_device_gpu_to_cpu_boundary_vertices.DeviceObject(),
                            graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT].DeviceObject());
                        stream_s.Sync();
                    }
                    LOG("[SSSP-SEED-FRONTIER] batch=%u added_edges=%u mode=direct_added_edge\n",
                        NumOfSnapShots,
                        add_size);
                } else {
                    for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                        stream_id = seg_idx % FLAGS_n_stream;
                        seg_snode = m_groute_context->seg_snode[seg_idx];
                        seg_enode = m_groute_context->seg_enode[seg_idx];
                        RebuildWorklist_AllVertices(app_inst,
                            graph_datum,
                            stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                    }
                    for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                        stream[stream_idx].Sync();
                    }
                    ExecutePolicy_All(next_policy);
                }
                sw_load.stop();
                add_time+=sw_load.ms();
                Stopwatch sw_initial_rebuild(true);
                cudaDeviceSynchronize();
                const auto publication =
                    m_vcsr_dev_graph_allocator->CompleteSparsePublication();
                if (publication.stale_rejects != 0 ||
                    publication.hash_mismatches != 0) {
                    LOG("[C3-PUBLISH] protocol_error batch=%u stale_version_rejects=%llu gpu_cpu_hash_mismatches=%llu\n",
                        NumOfSnapShots, publication.stale_rejects,
                        publication.hash_mismatches);
                    std::abort();
                }
                LOG("[C3-PUBLISH][batch %u] epoch=%llu patch_records=%zu patch_bytes=%llu h2d_count=%u publication_ms=%.3f stale_version_rejects=%llu cache_invalidations=%llu cache_tail=%llu cache_capacity=%llu zc_cold_edges=%llu gpu_cpu_hash_mismatches=%llu audit=%u\n",
                    NumOfSnapShots,
                    static_cast<unsigned long long>(m_chunk_store->PublishedEpoch()),
                    m_topology_patch_sources.size(),
                    static_cast<unsigned long long>(m_topology_patch_sources.size() * sizeof(topology::TopologyPatchRecord)),
                    m_topology_patch_sources.empty() ? 0U : 1U,
                    publication.publication_ms, publication.stale_rejects,
                    publication.cache_invalidations,
                    publication.cache_tail,
                    static_cast<unsigned long long>(graph_datum.num_of_cache),
                    static_cast<unsigned long long>(zc_cold_edges),
                    publication.hash_mismatches, FLAGS_check ? 1U : 0U);
                const bool exact_all_gpu = m_insertion_epoch_active &&
                    !m_cpu_domain_map_enabled &&
                    FLAGS_sssp_cpu_partition_capacity == 0;
                if (exact_all_gpu) {
                    m_exact_source_frontier_ready = true;
                    m_exact_source_frontier_count =
                        graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT].GetCount(stream_s);
                    for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                        graph_datum.seg_active_num[seg] = 0;
                        m_running_info.input_active_count_seg[seg] = 0;
                    }
                    if (m_exact_source_frontier_count != 0) {
                        graph_datum.seg_active_num[0] = m_exact_source_frontier_count;
                        m_running_info.input_active_count_seg[0] =
                            m_exact_source_frontier_count;
                    }
                    LOG("[E4-R1-SEED] batch=%u exact_sources=%u seed_partition_rebuilds=0\n",
                        NumOfSnapShots, m_exact_source_frontier_count);
                } else {
                    for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                        stream_id = seg_idx % FLAGS_n_stream;
                        if (m_insertion_epoch_active &&
                            !m_insertion_seed_partitions[seg_idx]) {
                            graph_datum.m_wl_array_in_seg[seg_idx].ResetAsync(
                                stream[stream_id].cuda_stream);
                            graph_datum.seg_active_num[seg_idx] = 0;
                            m_running_info.input_active_count_seg[seg_idx] = 0;
                            continue;
                        }
                        seg_snode = m_groute_context->seg_snode[seg_idx];
                        seg_enode = m_groute_context->seg_enode[seg_idx];
                        RebuildArrayWorklist(app_inst,
                            graph_datum,
                            stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx,
                            m_insertion_epoch_active ? m_device_node_state_epoch : nullptr,
                            m_insertion_epoch);
                    }
                    for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                        stream[stream_idx].Sync();
                    }
                    RefreshSegmentActiveCountsFromQueues();
                }
                sw_initial_rebuild.stop();
                // LOG("DEBUG2 \n");
                bool convergence = false;
                m_running_info.current_round = 0;
                Stopwatch sw_con(true);
                if (exact_all_gpu) {
                    RunExactSourceClosure();
                    convergence = true;
                }
                while(!convergence){
                //   PreComputationBW();
                  ExecutePolicy_Converge(next_policy);
                  ++m_insertion_convergence_round;
                //   GatherTransfer();
                //   ExecutePolicy_SC(next_policy);
                  int convergence_check = 0;
                  for(index_t seg_id = 0; seg_id < FLAGS_SEGMENT; seg_id++){
                       if(m_running_info.input_active_count_seg[seg_id] == 0){
                           convergence_check++;
                       }
                   }
                  const bool cpu_owner_enabled =
                      FLAGS_sssp_cpu_partition_capacity != 0 ||
                      m_cpu_domain_map_enabled;
                  const uint32_t boundary_active = cpu_owner_enabled
                      ? m_device_gpu_to_cpu_boundary_vertices.GetCount(*m_stream)
                      : 0;
                  if(convergence_check == FLAGS_SEGMENT &&
                     m_cpu_frontier.empty() && boundary_active == 0){
                        convergence = true;
                  }
                  if (m_insertion_convergence_round > graph_datum.nnodes) {
                        LOG("[DUAL-RUNTIME] protocol_error=non_quiescent epoch=%u rounds=%llu bound=%u\n",
                            m_insertion_epoch,
                            static_cast<unsigned long long>(m_insertion_convergence_round),
                            graph_datum.nnodes);
                        std::abort();
                  }
                }
                sw_con.stop();
                if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
                    EndInsertionEpoch(NumOfSnapShots);
                }
                add_time+=sw_con.ms();
                LOG("[INSERTION-STAGE] batch=%u reset_ms=%.3f cpu_mutation_ms=%.3f topology_publication_audit_ms=%.3f initial_rebuild_ms=%.3f seed_ms=%.3f converge_ms=%.3f\n",
                    NumOfSnapShots,
                    sw_update_reset.ms(),
                    sw_cpu_mutation.ms(),
                    publication.publication_ms,
                    sw_initial_rebuild.ms(),
                    sw_load.ms(),
                    sw_con.ms());
                LOG("total add time: %f ms (excluded)\n", add_time);
                // GatherCacheMiss();
                // GatherTransfer();
            }

            void RunExactSourceClosure() {
                GraphDatum &graph_datum = *m_graph_datum;
                auto &app_inst = *m_app_inst;
                auto &input = graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT];
                auto &output = graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT + 1];
                if (!m_dev_props.cooperativeLaunch) {
                    LOG("[E4-R1] protocol_error=cooperative_launch_unsupported device=%s\n",
                        m_dev_props.name);
                    std::abort();
                }
                if (m_device_exact_source_counts == nullptr) {
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_exact_source_counts),
                        4 * sizeof(unsigned long long)));
                }
                GROUTE_CUDA_CHECK(cudaMemset(m_device_exact_source_counts, 0,
                    4 * sizeof(unsigned long long)));
                int blocks_per_sm = 0;
                GROUTE_CUDA_CHECK(cudaOccupancyMaxActiveBlocksPerMultiprocessor(
                    &blocks_per_sm,
                    RunExactGpuClosure<AppImplDeviceObject,
                        decltype(m_vcsr_dev_graph_allocator->DeviceObject()),
                        TValue, TBuffer>,
                    128, 0));
                const int grid_blocks = blocks_per_sm * m_dev_props.multiProcessorCount;
                if (grid_blocks <= 0) {
                    LOG("[E4-R1] protocol_error=no_resident_cooperative_blocks\n");
                    std::abort();
                }
                const auto graph = m_vcsr_dev_graph_allocator->DeviceObject();
                auto input_device = input.DeviceObject();
                auto output_device = output.DeviceObject();
                TValue *values = graph_datum.GetValueDeviceObject();
                TBuffer *buffers = graph_datum.GetBufferDeviceObject();
                TValue *parents = graph_datum.GetParentDeviceObject();
                uint32_t epoch = m_insertion_epoch;
                uint32_t *node_state_epoch = m_device_node_state_epoch;
                unsigned long long *metrics = m_device_exact_source_counts;
                void *arguments[] = {&app_inst, &input_device, &output_device,
                    const_cast<void **>(reinterpret_cast<void *const *>(&graph)),
                    &values, &buffers, &parents, &epoch, &node_state_epoch,
                    &metrics};
                GROUTE_CUDA_CHECK(cudaLaunchCooperativeKernel(
                    reinterpret_cast<void *>(RunExactGpuClosure<
                        AppImplDeviceObject, decltype(graph), TValue, TBuffer>),
                    grid_blocks, 128, arguments, 0, m_stream->cuda_stream));
                m_stream->Sync();
                unsigned long long host_metrics[4] = {0, 0, 0, 0};
                GROUTE_CUDA_CHECK(cudaMemcpy(host_metrics,
                    m_device_exact_source_counts, sizeof(host_metrics),
                    cudaMemcpyDeviceToHost));
                if (host_metrics[3] > 0xffffULL) {
                    LOG("[E4-R1] protocol_error=wave_ticket_overflow epoch=%u waves=%llu\n",
                        m_insertion_epoch, host_metrics[3]);
                    std::abort();
                }
                m_insertion_convergence_round = host_metrics[3];
                m_exact_source_frontier_count = 0;
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    graph_datum.seg_active_num[seg] = 0;
                    m_running_info.input_active_count_seg[seg] = 0;
                }
                LOG("[E4-R1-CLOSURE] epoch=%u offered_sources=%llu processed_sources=%llu processed_edges=%llu local_waves=%llu seed_partition_rebuilds=0 host_frontier_syncs=0 final_quiescence_syncs=1\n",
                    m_insertion_epoch, host_metrics[0], host_metrics[1],
                    host_metrics[2], host_metrics[3]);
            }

            void CollectDeletionAffectedVertices(index_t batch) {
                Stopwatch sw_d2h(true);
                const uint32_t affected_count =
                    m_device_affected_vertices.GetCount(*m_stream);
                m_affected_vertices.resize(affected_count);
                if (affected_count != 0) {
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        m_affected_vertices.data(),
                        m_device_affected_vertices.GetDeviceDataPtr(),
                        sizeof(index_t) * affected_count,
                        cudaMemcpyDeviceToHost));
                }
                sw_d2h.stop();

                std::vector<uint8_t> active_partitions(FLAGS_SEGMENT, 0);
                for (const index_t node : m_affected_vertices) {
                    const index_t *begin = m_groute_context->seg_enode;
                    const index_t *end = begin + FLAGS_SEGMENT;
                    const index_t *position = std::upper_bound(begin, end, node);
                    if (position != end) {
                        active_partitions[position - begin] = 1;
                    }
                }
                const uint32_t active_partition_count = static_cast<uint32_t>(
                    std::count(active_partitions.begin(), active_partitions.end(), uint8_t{1}));
                const uint64_t metadata_device_bytes =
                    static_cast<uint64_t>(m_graph_datum->nnodes) * sizeof(index_t);
                LOG("[B2-AFFECTED][batch %u] vertices=%u active_partitions=%u d2h_bytes=%llu d2h_ms=%.3f metadata_device_bytes=%llu\n",
                    batch,
                    affected_count,
                    active_partition_count,
                    static_cast<unsigned long long>(sizeof(index_t) * affected_count),
                    sw_d2h.ms(),
                    static_cast<unsigned long long>(metadata_device_bytes));
            }

            void EnsureGpuAffectedRepairCapacity(size_t affected_count,
                                                  size_t source_count) {
                if (affected_count > m_device_gpu_repair_offset_capacity) {
                    if (m_device_gpu_repair_offsets != nullptr)
                        GROUTE_CUDA_CHECK(cudaFree(m_device_gpu_repair_offsets));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_gpu_repair_offsets),
                        sizeof(uint64_t) * (affected_count + 1)));
                    m_device_gpu_repair_offset_capacity = affected_count;
                }
                if (source_count > m_device_gpu_repair_source_capacity) {
                    if (m_device_gpu_repair_sources != nullptr)
                        GROUTE_CUDA_CHECK(cudaFree(m_device_gpu_repair_sources));
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_gpu_repair_sources),
                        sizeof(index_t) * source_count));
                    m_device_gpu_repair_source_capacity = source_count;
                }
            }

            uint64_t GatherGpuRepairBoundaryEvents(
                    const std::vector<index_t> &sources,
                    RepairBoundaryEventKind kind,
                    uint32_t epoch,
                    InsertionRoundStats &stats,
                    std::vector<RepairBoundaryEvent<TValue>> &events) {
                m_cpu_boundary_proposals.clear();
                m_cpu_boundary_proposals.reserve(sources.size());
                for (const index_t source : sources) {
                    if (!m_node_cpu_owner[source]) {
                        m_cpu_boundary_proposals.push_back({source, TBuffer{}, 0});
                    }
                }
                std::sort(m_cpu_boundary_proposals.begin(),
                          m_cpu_boundary_proposals.end(),
                          [](const CpuRelaxProposal<TBuffer> &lhs,
                             const CpuRelaxProposal<TBuffer> &rhs) {
                              return lhs.dst < rhs.dst;
                          });
                m_cpu_boundary_proposals.erase(
                    std::unique(m_cpu_boundary_proposals.begin(),
                                m_cpu_boundary_proposals.end(),
                                [](const CpuRelaxProposal<TBuffer> &lhs,
                                   const CpuRelaxProposal<TBuffer> &rhs) {
                                    return lhs.dst == rhs.dst;
                                }),
                    m_cpu_boundary_proposals.end());
                if (m_cpu_boundary_proposals.empty()) return 0;

                EnsureInsertionDeviceCapacity(
                    &m_device_cpu_boundary_proposals,
                    &m_device_cpu_boundary_proposal_capacity,
                    m_cpu_boundary_proposals.size(), stats);
                const size_t bytes = sizeof(CpuRelaxProposal<TBuffer>) *
                                     m_cpu_boundary_proposals.size();
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_device_cpu_boundary_proposals,
                    m_cpu_boundary_proposals.data(), bytes,
                    cudaMemcpyHostToDevice));
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, m_cpu_boundary_proposals.size());
                GatherSparseCpuState<TValue, TBuffer><<<grid_dims, block_dims>>>(
                    m_device_cpu_boundary_proposals,
                    static_cast<uint32_t>(m_cpu_boundary_proposals.size()),
                    m_graph_datum->GetValueDeviceObject(),
                    m_graph_datum->GetParentDeviceObject());
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_cpu_boundary_proposals.data(),
                    m_device_cpu_boundary_proposals, bytes,
                    cudaMemcpyDeviceToHost));
                events.clear();
                events.reserve(m_cpu_boundary_proposals.size());
                for (const auto &state : m_cpu_boundary_proposals) {
                    const uint32_t version = ++m_repair_source_versions[state.dst];
                    events.push_back({state.dst, static_cast<TValue>(state.value),
                                      state.parent, epoch, version, kind});
                }
                return sizeof(RepairBoundaryEvent<TValue>) * events.size();
            }

            void ScatterCpuRepairEvents(
                    const std::vector<RepairBoundaryEvent<TValue>> &events,
                    InsertionRoundStats &stats) {
                if (events.empty()) return;
                m_cpu_boundary_proposals.clear();
                m_cpu_boundary_proposals.reserve(events.size());
                for (const auto &event : events) {
                    m_cpu_boundary_proposals.push_back(
                        {event.source, static_cast<TBuffer>(event.value), event.parent});
                }
                EnsureInsertionDeviceCapacity(
                    &m_device_cpu_boundary_proposals,
                    &m_device_cpu_boundary_proposal_capacity,
                    m_cpu_boundary_proposals.size(), stats);
                const size_t bytes = sizeof(CpuRelaxProposal<TBuffer>) *
                                     m_cpu_boundary_proposals.size();
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_device_cpu_boundary_proposals,
                    m_cpu_boundary_proposals.data(), bytes,
                    cudaMemcpyHostToDevice));
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, m_cpu_boundary_proposals.size());
                ScatterCpuDirtyState<TValue, TBuffer><<<grid_dims, block_dims>>>(
                    m_device_cpu_boundary_proposals,
                    m_cpu_boundary_proposals.size(),
                    m_graph_datum->GetValueDeviceObject(),
                    m_graph_datum->GetBufferDeviceObject(),
                    m_graph_datum->GetParentDeviceObject());
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                stats.cpu_state_scatter_vertices += events.size();
                stats.cpu_state_scatter_bytes += bytes;
            }

            struct CpuAffectedClosureStats {
                uint64_t relaxations = 0;
                uint64_t scanned_edges = 0;
                uint64_t rounds = 0;
            };

            CpuAffectedClosureStats RunCpuOwnedAffectedPullClosure() {
                const TValue infinity = std::numeric_limits<TValue>::max();
                CpuAffectedClosureStats stats;
                bool changed = false;
                do {
                    ++stats.rounds;
                    changed = false;
                    for (size_t i = 0; i < m_affected_vertices.size(); ++i) {
                        const index_t dst = m_affected_vertices[i];
                        if (!m_node_cpu_owner[dst]) continue;
                        TValue best = m_cpu_node_values[dst];
                        index_t best_parent = m_cpu_node_parents[dst];
                        for (uint64_t edge = m_gpu_repair_incoming_offsets[i];
                             edge < m_gpu_repair_incoming_offsets[i + 1]; ++edge) {
                            ++stats.scanned_edges;
                            const index_t src = m_gpu_repair_incoming_sources[edge];
                            const TValue src_value = m_cpu_node_values[src];
                            if (src_value == infinity) continue;
                            const uint64_t candidate_wide =
                                static_cast<uint64_t>(src_value) +
                                static_cast<uint64_t>(
                                    AppImplDeviceObject::DeletionEdgeWeight(src, dst));
                            if (candidate_wide < static_cast<uint64_t>(best) ||
                                (candidate_wide == static_cast<uint64_t>(best) &&
                                 (best_parent == UINT32_MAX || src < best_parent))) {
                                best = static_cast<TValue>(candidate_wide);
                                best_parent = src;
                            }
                        }
                        const bool value_improved = best < m_cpu_node_values[dst];
                        const bool parent_repaired =
                            best_parent != std::numeric_limits<index_t>::max() &&
                            best == m_cpu_node_values[dst] &&
                            best_parent != m_cpu_node_parents[dst];
                        if (value_improved || parent_repaired) {
                            m_cpu_node_values[dst] = best;
                            m_cpu_node_buffers[dst] = best;
                            m_cpu_node_parents[dst] = best_parent;
                            m_cpu_dirty_vertices.push_back(dst);
                            if (value_improved) {
                                ++stats.relaxations;
                                changed = true;
                            }
                        }
                    }
                } while (changed);
                return stats;
            }

            void TraceAffectedComponents(
                    index_t batch,
                    const std::vector<index_t> &changed_source_events,
                    bool changed_source_events_available) {
                if (FLAGS_f1_component_trace_file.empty()) return;
                if (!m_f1_component_trace.is_open()) {
                    m_f1_component_trace.open(FLAGS_f1_component_trace_file,
                        std::ios::out | std::ios::binary | std::ios::trunc);
                    if (!m_f1_component_trace) {
                        LOG("[F1-COMPONENT-TRACE] protocol_error=open_failed file=%s\n",
                            FLAGS_f1_component_trace_file.c_str());
                        std::abort();
                    }
                    affected_component::WriteHeader(m_f1_component_trace);
                }
                std::vector<uint32_t> degrees;
                degrees.reserve(m_affected_vertices.size());
                const auto adjacency =
                    m_vcsr_dev_graph_allocator->HostObject().adjacency_view();
                for (const index_t vertex : m_affected_vertices) {
                    degrees.push_back(adjacency.Degree(vertex));
                }
                affected_component::WriteBatch(
                    m_f1_component_trace, batch, m_affected_vertices, degrees,
                    m_gpu_repair_incoming_offsets, m_gpu_repair_incoming_sources,
                    changed_source_events, changed_source_events_available);
                m_f1_component_trace.flush();
                LOG("[F1-COMPONENT-TRACE] batch=%u affected=%llu incoming=%llu bytes=%llu\n",
                    batch,
                    static_cast<unsigned long long>(m_affected_vertices.size()),
                    static_cast<unsigned long long>(m_gpu_repair_incoming_sources.size()),
                    static_cast<unsigned long long>(
                        sizeof(uint32_t) + 3 * sizeof(uint64_t) + sizeof(uint8_t) +
                        sizeof(index_t) * (m_affected_vertices.size() +
                                           m_gpu_repair_incoming_sources.size() +
                                           changed_source_events.size()) +
                        sizeof(uint32_t) * m_affected_vertices.size() +
                        sizeof(uint64_t) * m_gpu_repair_incoming_offsets.size()));
            }

            void RunGpuAffectedRepair(index_t batch) {
                if (m_affected_vertices.empty()) {
                    m_gpu_repair_incoming_offsets.assign(1, 0);
                    m_gpu_repair_incoming_sources.clear();
                    TraceAffectedComponents(batch, {}, true);
                    LOG("[B2-GPU-REPAIR][batch %u] affected=0\n", batch);
                    return;
                }

                Stopwatch sw_topology(true);
                const auto incoming_metrics = m_reverse_index.MaterializeIncoming(
                    m_affected_vertices, m_gpu_repair_incoming_offsets,
                    m_gpu_repair_incoming_sources);
                sw_topology.stop();

                Stopwatch sw_allocate(true);
                EnsureGpuAffectedRepairCapacity(m_affected_vertices.size(),
                                                m_gpu_repair_incoming_sources.size());
                sw_allocate.stop();

                Stopwatch sw_h2d(true);
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_device_gpu_repair_offsets,
                    m_gpu_repair_incoming_offsets.data(),
                    sizeof(uint64_t) * m_gpu_repair_incoming_offsets.size(),
                    cudaMemcpyHostToDevice));
                if (!m_gpu_repair_incoming_sources.empty()) {
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        m_device_gpu_repair_sources,
                        m_gpu_repair_incoming_sources.data(),
                        sizeof(index_t) * m_gpu_repair_incoming_sources.size(),
                        cudaMemcpyHostToDevice));
                }
                sw_h2d.stop();

                GraphDatum &graph_datum = *m_graph_datum;
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, m_affected_vertices.size());
                Stopwatch sw_closure(true);
                const bool owner_local_repair = m_cpu_domain_map_enabled;
                std::vector<index_t> trace_changed_source_events;
                if (owner_local_repair) {
                    if (!m_cpu_domain_state_initialized) {
                        LOG("[E2C-DELETE] protocol_error=repair_before_state_initialize batch=%u\n",
                            batch);
                        std::abort();
                    }
                    const TValue infinity = std::numeric_limits<TValue>::max();
                    for (const index_t vertex : m_affected_vertices) {
                        if (m_node_cpu_owner[vertex]) {
                            m_cpu_node_values[vertex] = infinity;
                            m_cpu_node_buffers[vertex] = infinity;
                            m_cpu_node_parents[vertex] =
                                std::numeric_limits<index_t>::max();
                        }
                    }
                }

                unsigned int changed = 0;
                uint32_t iterations = 0;
                uint64_t cpu_relaxations = 0;
                uint64_t boundary_bytes = 0;
                uint64_t boundary_events_sent = 0;
                uint64_t boundary_events_accepted = 0;
                uint64_t boundary_events_rejected = 0;
                InsertionRoundStats repair_stats{};
                const uint32_t repair_epoch = m_cpu_domain_state_epoch + 1;
                std::vector<index_t> pending_gpu_sources;
                std::unordered_set<index_t> gpu_sources_with_cpu_dependency;
                std::unordered_set<index_t> cpu_sources_with_gpu_dependency;
                uint64_t gpu_owned_incoming_edges = 0;
                if (owner_local_repair) {
                    for (size_t i = 0; i < m_affected_vertices.size(); ++i) {
                        if (!m_node_cpu_owner[m_affected_vertices[i]]) {
                            gpu_owned_incoming_edges +=
                                m_gpu_repair_incoming_offsets[i + 1] -
                                m_gpu_repair_incoming_offsets[i];
                        }
                        for (uint64_t edge = m_gpu_repair_incoming_offsets[i];
                             edge < m_gpu_repair_incoming_offsets[i + 1]; ++edge) {
                            const index_t source = m_gpu_repair_incoming_sources[edge];
                            if (m_node_cpu_owner[m_affected_vertices[i]] &&
                                !m_node_cpu_owner[source]) {
                                pending_gpu_sources.push_back(source);
                                gpu_sources_with_cpu_dependency.insert(source);
                            } else if (!m_node_cpu_owner[m_affected_vertices[i]] &&
                                       m_node_cpu_owner[source]) {
                                cpu_sources_with_gpu_dependency.insert(source);
                            }
                        }
                    }
                }

                if (!owner_local_repair) {
                    do {
                        GROUTE_CUDA_CHECK(cudaMemset(
                            m_device_gpu_repair_changed, 0, sizeof(unsigned int)));
                        GpuAffectedPullRelax<AppImplDeviceObject, TValue, TBuffer>
                            <<<grid_dims, block_dims>>>(
                                *m_app_inst,
                                m_device_affected_vertices.GetDeviceDataPtr(),
                                static_cast<uint32_t>(m_affected_vertices.size()),
                                m_device_gpu_repair_offsets,
                                m_device_gpu_repair_sources,
                                graph_datum.GetValueDeviceObject(),
                                graph_datum.GetBufferDeviceObject(),
                                graph_datum.GetParentDeviceObject(),
                                std::numeric_limits<TValue>::max(),
                                nullptr,
                                m_device_gpu_repair_changed,
                                FLAGS_f1_component_trace_file.empty() ? nullptr :
                                    m_device_gpu_repair_changed_vertices);
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            &changed,
                            m_device_gpu_repair_changed,
                            sizeof(unsigned int),
                            cudaMemcpyDeviceToHost));
                        if (!FLAGS_f1_component_trace_file.empty() && changed != 0) {
                            const size_t begin = trace_changed_source_events.size();
                            trace_changed_source_events.resize(begin + changed);
                            GROUTE_CUDA_CHECK(cudaMemcpy(
                                trace_changed_source_events.data() + begin,
                                m_device_gpu_repair_changed_vertices,
                                sizeof(index_t) * changed,
                                cudaMemcpyDeviceToHost));
                        }
                        ++iterations;
                        if (iterations > m_affected_vertices.size() + 1) {
                            LOG("[B2-GPU-REPAIR] protocol_error=no_convergence batch=%u iterations=%u affected=%llu\n",
                                batch,
                                iterations,
                                static_cast<unsigned long long>(m_affected_vertices.size()));
                            std::abort();
                        }
                    } while (changed != 0);
                } else {
                    using BoundaryEvent = RepairBoundaryEvent<TValue>;
                    const size_t channel_capacity = std::max<size_t>(
                        1, std::max(m_affected_vertices.size(),
                                    pending_gpu_sources.size()));
                    runtime::DualDomainEventRuntime<BoundaryEvent> event_runtime(
                        channel_capacity);
                    runtime::SourceVersionGate cpu_version_gate(graph_datum.nnodes);
                    runtime::SourceVersionGate gpu_version_gate(graph_datum.nnodes);
                    event_runtime.BeginEpoch(repair_epoch);
                    cpu_version_gate.BeginEpoch(repair_epoch);
                    gpu_version_gate.BeginEpoch(repair_epoch);
                    std::atomic<bool> stop_cpu{false};
                    std::atomic<uint64_t> cpu_relaxations_async{0};
                    std::atomic<uint64_t> sent_async{0};
                    std::atomic<uint64_t> accepted_async{0};
                    std::atomic<uint64_t> rejected_async{0};
                    std::atomic<uint64_t> boundary_bytes_async{0};
                    std::atomic<uint64_t> cpu_scanned_edges_async{0};
                    std::atomic<uint64_t> cpu_closure_rounds_async{0};
                    std::atomic<uint64_t> cpu_closure_calls_async{0};
                    std::atomic<uint64_t> cpu_idle_polls_async{0};
                    std::atomic<uint64_t> event_candidate_records_async{0};
                    std::atomic<bool> cpu_initial_work{true};
                    using RuntimeClock = std::chrono::steady_clock;
                    const auto runtime_origin = RuntimeClock::now();
                    auto runtime_ms = [&]() {
                        return std::chrono::duration<double, std::milli>(
                            RuntimeClock::now() - runtime_origin).count();
                    };
                    std::vector<std::pair<double, double>> cpu_useful_intervals;
                    std::vector<std::pair<double, double>> gpu_useful_intervals;
                    event_runtime.AddLocalWork(runtime::ExecutionDomain::CPU);
                    Stopwatch sw_dependency_fence(true);
                    do {
                        GROUTE_CUDA_CHECK(cudaMemset(
                            m_device_gpu_repair_changed, 0,
                            sizeof(unsigned int)));
                        GpuAffectedPullRelax<AppImplDeviceObject, TValue, TBuffer>
                            <<<grid_dims, block_dims>>>(
                                *m_app_inst,
                                m_device_affected_vertices.GetDeviceDataPtr(),
                                static_cast<uint32_t>(m_affected_vertices.size()),
                                m_device_gpu_repair_offsets,
                                m_device_gpu_repair_sources,
                                graph_datum.GetValueDeviceObject(),
                                graph_datum.GetBufferDeviceObject(),
                                graph_datum.GetParentDeviceObject(),
                                std::numeric_limits<TValue>::max(),
                                m_device_cpu_destination_flags,
                                m_device_gpu_repair_changed,
                                nullptr);
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            &changed, m_device_gpu_repair_changed,
                            sizeof(unsigned int), cudaMemcpyDeviceToHost));
                        ++iterations;
                    } while (changed != 0);
                    sw_dependency_fence.stop();
                    std::vector<BoundaryEvent> initial_events;
                    event_candidate_records_async.fetch_add(
                        pending_gpu_sources.size(), std::memory_order_relaxed);
                    boundary_bytes_async.fetch_add(
                        GatherGpuRepairBoundaryEvents(
                            pending_gpu_sources,
                            RepairBoundaryEventKind::Invalidation,
                            repair_epoch, repair_stats, initial_events),
                        std::memory_order_relaxed);
                    for (const auto &event : initial_events) {
                        if (!event_runtime.TryPublish(
                                runtime::ExecutionDomain::GPU, event)) {
                            LOG("[E3B-DELETE] protocol_error=initial_channel_capacity events=%llu capacity=%llu\n",
                                static_cast<unsigned long long>(initial_events.size()),
                                static_cast<unsigned long long>(channel_capacity));
                            std::abort();
                        }
                        sent_async.fetch_add(1, std::memory_order_relaxed);
                    }

                    std::thread cpu_executor([&]() {
                        std::vector<BoundaryEvent> accepted_events;
                        while (!stop_cpu.load(std::memory_order_acquire)) {
                            accepted_events.clear();
                            bool run_closure = cpu_initial_work.exchange(
                                false, std::memory_order_acq_rel);
                            BoundaryEvent event{};
                            while (event_runtime.TryReceive(
                                       runtime::ExecutionDomain::CPU, event)) {
                                if (cpu_version_gate.Accept(
                                        event.epoch, event.source, event.version)) {
                                    if (accepted_events.empty() && !run_closure) {
                                        event_runtime.AddLocalWork(
                                            runtime::ExecutionDomain::CPU);
                                    }
                                    run_closure = true;
                                    m_cpu_node_values[event.source] = event.value;
                                    m_cpu_node_parents[event.source] = event.parent;
                                    accepted_events.push_back(event);
                                    accepted_async.fetch_add(1, std::memory_order_relaxed);
                                } else {
                                    rejected_async.fetch_add(1, std::memory_order_relaxed);
                                }
                                event_runtime.CompleteEvent(
                                    runtime::ExecutionDomain::CPU);
                            }
                            if (!run_closure) {
                                cpu_idle_polls_async.fetch_add(
                                    1, std::memory_order_relaxed);
                                std::this_thread::yield();
                                continue;
                            }
                            m_cpu_dirty_vertices.clear();
                            const double cpu_begin_ms = runtime_ms();
                            const CpuAffectedClosureStats closure_stats =
                                RunCpuOwnedAffectedPullClosure();
                            cpu_useful_intervals.push_back(
                                {cpu_begin_ms, runtime_ms()});
                            cpu_relaxations_async.fetch_add(
                                closure_stats.relaxations, std::memory_order_relaxed);
                            cpu_scanned_edges_async.fetch_add(
                                closure_stats.scanned_edges, std::memory_order_relaxed);
                            cpu_closure_rounds_async.fetch_add(
                                closure_stats.rounds, std::memory_order_relaxed);
                            cpu_closure_calls_async.fetch_add(
                                1, std::memory_order_relaxed);
                            event_candidate_records_async.fetch_add(
                                m_cpu_dirty_vertices.size(), std::memory_order_relaxed);
                            for (const index_t vertex : m_cpu_dirty_vertices) {
                                const uint32_t version =
                                    ++m_repair_source_versions[vertex];
                                const BoundaryEvent output{
                                    vertex, m_cpu_node_values[vertex],
                                    m_cpu_node_parents[vertex], repair_epoch,
                                    version, RepairBoundaryEventKind::Replacement};
                                while (!event_runtime.TryPublish(
                                           runtime::ExecutionDomain::CPU, output)) {
                                    std::this_thread::yield();
                                }
                                sent_async.fetch_add(1, std::memory_order_relaxed);
                                boundary_bytes_async.fetch_add(
                                    sizeof(BoundaryEvent), std::memory_order_relaxed);
                            }
                            event_runtime.CompleteLocalWork(
                                runtime::ExecutionDomain::CPU);
                        }
                    });

                    bool gpu_active = false;
                    uint64_t coordinator_polls = 0;
                    uint64_t coordinator_idle_polls = 0;
                    Stopwatch sw_async_runtime(true);
                    while (true) {
                        ++coordinator_polls;
                        std::vector<BoundaryEvent> cpu_events;
                        BoundaryEvent cpu_event{};
                        bool activates_gpu = false;
                        while (event_runtime.TryReceive(
                                   runtime::ExecutionDomain::GPU, cpu_event)) {
                            if (gpu_version_gate.Accept(
                                    cpu_event.epoch, cpu_event.source,
                                    cpu_event.version)) {
                                cpu_events.push_back(cpu_event);
                                accepted_async.fetch_add(1, std::memory_order_relaxed);
                                activates_gpu = activates_gpu ||
                                    cpu_sources_with_gpu_dependency.count(
                                        cpu_event.source) != 0;
                            } else {
                                rejected_async.fetch_add(1, std::memory_order_relaxed);
                            }
                            if (activates_gpu && !gpu_active) {
                                event_runtime.AddLocalWork(
                                    runtime::ExecutionDomain::GPU);
                                gpu_active = true;
                            }
                            event_runtime.CompleteEvent(
                                runtime::ExecutionDomain::GPU);
                        }
                        ScatterCpuRepairEvents(cpu_events, repair_stats);

                        if (gpu_active) {
                            const double gpu_begin_ms = runtime_ms();
                            GROUTE_CUDA_CHECK(cudaMemset(
                                m_device_gpu_repair_changed, 0,
                                sizeof(unsigned int)));
                            GpuAffectedPullRelax<AppImplDeviceObject, TValue, TBuffer>
                                <<<grid_dims, block_dims>>>(
                                    *m_app_inst,
                                    m_device_affected_vertices.GetDeviceDataPtr(),
                                    static_cast<uint32_t>(m_affected_vertices.size()),
                                    m_device_gpu_repair_offsets,
                                    m_device_gpu_repair_sources,
                                    graph_datum.GetValueDeviceObject(),
                                    graph_datum.GetBufferDeviceObject(),
                                    graph_datum.GetParentDeviceObject(),
                                    std::numeric_limits<TValue>::max(),
                                    m_device_cpu_destination_flags,
                                    m_device_gpu_repair_changed,
                                    m_device_gpu_repair_changed_vertices);
                            GROUTE_CUDA_CHECK(cudaMemcpy(
                                &changed, m_device_gpu_repair_changed,
                                sizeof(unsigned int), cudaMemcpyDeviceToHost));
                            gpu_useful_intervals.push_back(
                                {gpu_begin_ms, runtime_ms()});
                            ++iterations;
                            if (iterations > m_affected_vertices.size() + 1) {
                                LOG("[E3B-DELETE] protocol_error=no_convergence batch=%u iterations=%u\n",
                                    batch, iterations);
                                std::abort();
                            }
                            if (changed != 0) {
                                std::vector<index_t> changed_sources(changed);
                                GROUTE_CUDA_CHECK(cudaMemcpy(
                                    changed_sources.data(),
                                    m_device_gpu_repair_changed_vertices,
                                    sizeof(index_t) * changed,
                                    cudaMemcpyDeviceToHost));
                                pending_gpu_sources.clear();
                                for (const index_t source : changed_sources) {
                                    if (gpu_sources_with_cpu_dependency.count(source) != 0) {
                                        pending_gpu_sources.push_back(source);
                                    }
                                }
                                std::vector<BoundaryEvent> gpu_events;
                                event_candidate_records_async.fetch_add(
                                    pending_gpu_sources.size(),
                                    std::memory_order_relaxed);
                                boundary_bytes_async.fetch_add(
                                    GatherGpuRepairBoundaryEvents(
                                        pending_gpu_sources,
                                        RepairBoundaryEventKind::Replacement,
                                        repair_epoch, repair_stats, gpu_events),
                                    std::memory_order_relaxed);
                                for (const auto &event : gpu_events) {
                                    while (!event_runtime.TryPublish(
                                               runtime::ExecutionDomain::GPU,
                                               event)) {
                                        std::this_thread::yield();
                                    }
                                    sent_async.fetch_add(1, std::memory_order_relaxed);
                                }
                            } else {
                                event_runtime.CompleteLocalWork(
                                    runtime::ExecutionDomain::GPU);
                                gpu_active = false;
                            }
                        }

                        if (event_runtime.ObserveQuiescence(repair_epoch)) break;
                        if (!gpu_active) {
                            ++coordinator_idle_polls;
                            std::this_thread::yield();
                        }
                    }
                    stop_cpu.store(true, std::memory_order_release);
                    cpu_executor.join();
                    sw_async_runtime.stop();
                    double cpu_useful_ms = 0.0;
                    double gpu_useful_ms = 0.0;
                    double useful_overlap_ms = 0.0;
                    for (const auto &interval : cpu_useful_intervals) {
                        cpu_useful_ms += interval.second - interval.first;
                    }
                    for (const auto &interval : gpu_useful_intervals) {
                        gpu_useful_ms += interval.second - interval.first;
                    }
                    for (const auto &cpu_interval : cpu_useful_intervals) {
                        for (const auto &gpu_interval : gpu_useful_intervals) {
                            useful_overlap_ms += std::max(
                                0.0, std::min(cpu_interval.second,
                                              gpu_interval.second) -
                                     std::max(cpu_interval.first,
                                              gpu_interval.first));
                        }
                    }
                    const auto runtime_snapshot = event_runtime.Snapshot();
                    cpu_relaxations = cpu_relaxations_async.load();
                    boundary_bytes = boundary_bytes_async.load();
                    boundary_events_sent = sent_async.load();
                    boundary_events_accepted = accepted_async.load();
                    boundary_events_rejected = rejected_async.load();
                    const uint64_t candidate_records =
                        event_candidate_records_async.load();
                    const double coalescing_ratio = candidate_records == 0 ? 0.0 :
                        1.0 - static_cast<double>(boundary_events_sent) /
                                  static_cast<double>(candidate_records);
                    LOG("[E3B-RUNTIME][batch %u] gpu_iterations=%u coordinator_polls=%llu coordinator_idle_polls=%llu cpu_idle_polls=%llu channel_capacity=%llu peak_inflight=%llu dependency_fence_ms=%.3f async_runtime_ms=%.3f cpu_useful_ms=%.3f gpu_useful_ms=%.3f useful_overlap_ms=%.3f cpu_closure_calls=%llu cpu_closure_rounds=%llu cpu_scanned_edges=%llu gpu_scanned_edges=%llu event_candidate_records=%llu coalescing_ratio=%.6f global_barriers=1 cpu_to_gpu_queued=%llu gpu_to_cpu_queued=%llu local_credit=%llu event_credit=%llu\n",
                        batch, iterations,
                        static_cast<unsigned long long>(coordinator_polls),
                        static_cast<unsigned long long>(coordinator_idle_polls),
                        static_cast<unsigned long long>(cpu_idle_polls_async.load()),
                        static_cast<unsigned long long>(channel_capacity),
                        static_cast<unsigned long long>(event_runtime.PeakOutstandingEvents()),
                        sw_dependency_fence.ms(), sw_async_runtime.ms(),
                        cpu_useful_ms, gpu_useful_ms, useful_overlap_ms,
                        static_cast<unsigned long long>(cpu_closure_calls_async.load()),
                        static_cast<unsigned long long>(cpu_closure_rounds_async.load()),
                        static_cast<unsigned long long>(cpu_scanned_edges_async.load()),
                        static_cast<unsigned long long>(
                            gpu_owned_incoming_edges * iterations),
                        static_cast<unsigned long long>(candidate_records),
                        coalescing_ratio,
                        static_cast<unsigned long long>(runtime_snapshot.cpu_to_gpu_queued),
                        static_cast<unsigned long long>(runtime_snapshot.gpu_to_cpu_queued),
                        static_cast<unsigned long long>(runtime_snapshot.local_work),
                        static_cast<unsigned long long>(runtime_snapshot.outstanding_events));
                }
                FinalizeGpuAffectedRepair<TValue, TBuffer><<<grid_dims, block_dims>>>(
                    m_device_affected_vertices.GetDeviceDataPtr(),
                    static_cast<uint32_t>(m_affected_vertices.size()),
                    graph_datum.GetValueDeviceObject(),
                    graph_datum.GetBufferDeviceObject(),
                    graph_datum.m_node_reset_datum);
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                TraceAffectedComponents(batch, trace_changed_source_events,
                                        !owner_local_repair);
                sw_closure.stop();
                if (owner_local_repair) {
                    ++m_cpu_domain_state_epoch;
                    const long long outstanding_credit =
                        static_cast<long long>(boundary_events_sent) -
                        static_cast<long long>(boundary_events_accepted) -
                        static_cast<long long>(boundary_events_rejected);
                    LOG("[E3B-DELETE][batch %u] cpu_affected_relax=%llu boundary_bytes=%llu events_sent=%llu events_accepted=%llu stale_or_duplicate=%llu outstanding_credit=%lld cpu_state_scatter_vertices=%llu cpu_state_scatter_bytes=%llu state_epoch=%u\n",
                        batch,
                        static_cast<unsigned long long>(cpu_relaxations),
                        static_cast<unsigned long long>(boundary_bytes),
                        static_cast<unsigned long long>(boundary_events_sent),
                        static_cast<unsigned long long>(boundary_events_accepted),
                        static_cast<unsigned long long>(boundary_events_rejected),
                        outstanding_credit,
                        static_cast<unsigned long long>(repair_stats.cpu_state_scatter_vertices),
                        static_cast<unsigned long long>(repair_stats.cpu_state_scatter_bytes),
                        m_cpu_domain_state_epoch);
                    if (outstanding_credit != 0) {
                        LOG("[E3B-DELETE] protocol_error=credit_leak batch=%u outstanding=%lld\n",
                            batch, outstanding_credit);
                        std::abort();
                    }
                }

                const uint64_t h2d_bytes =
                    sizeof(uint64_t) * m_gpu_repair_incoming_offsets.size() +
                    sizeof(index_t) * m_gpu_repair_incoming_sources.size();
                const uint64_t device_bytes =
                    sizeof(uint64_t) * (m_device_gpu_repair_offset_capacity + 1) +
                    sizeof(index_t) * m_device_gpu_repair_source_capacity +
                    sizeof(unsigned int);
                LOG("[B2-GPU-REPAIR][batch %u] affected=%llu incoming_edges=%llu base_edges_scanned=%llu delta_records_scanned=%llu merge_output_sources=%llu topology_ms=%.3f allocation_ms=%.3f h2d_bytes=%llu h2d_ms=%.3f iterations=%u closure_ms=%.3f device_bytes=%llu\n",
                    batch,
                    static_cast<unsigned long long>(m_affected_vertices.size()),
                    static_cast<unsigned long long>(m_gpu_repair_incoming_sources.size()),
                    static_cast<unsigned long long>(incoming_metrics.base_edges_scanned),
                    static_cast<unsigned long long>(incoming_metrics.delta_records_scanned),
                    static_cast<unsigned long long>(incoming_metrics.output_sources),
                    sw_topology.ms(),
                    sw_allocate.ms(),
                    static_cast<unsigned long long>(h2d_bytes),
                    sw_h2d.ms(),
                    iterations,
                    sw_closure.ms(),
                    static_cast<unsigned long long>(device_bytes));
            }

            void update_tree_del(std::pair<index_t,index_t> &local_begin,index_t &NumOfSnapShots){
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                Loader &load_update = *m_load_update;
                groute::Stream &stream_s = *m_stream;
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                GROUTE_CUDA_CHECK(cudaHostGetDevicePointer((void **)&(this->del_edges_d), (void *)(this->del_edges_h), 0));
                dim3 grid_dims, block_dims;
                uint32_t work_size[2];
                index_t start = local_begin.second;
                index_t size = load_update.m_batch_size[NumOfSnapShots].second;
                m_device_affected_vertices.ResetAsync(stream_s.cuda_stream);
                m_affected_vertices.clear();
                GROUTE_CUDA_CHECK(cudaMemsetAsync(graph_datum.m_node_reset_datum,
                                                  0,
                                                  sizeof(bool) * graph_datum.nnodes,
                                                  stream_s.cuda_stream));
                if (size == 0) {
                    del_edge_pr(local_begin, NumOfSnapShots);
                    stream_s.Sync();
                    m_gpu_repair_incoming_offsets.assign(1, 0);
                    m_gpu_repair_incoming_sources.clear();
                    TraceAffectedComponents(NumOfSnapShots, {}, true);
                    LOG("[B2-GPU-REPAIR][batch %u] affected=0 reason=no_deleted_edges\n",
                        NumOfSnapShots);
                    return;
                }
                work_size[0] = start;
                work_size[1] = size;
                GROUTE_CUDA_CHECK(cudaMemcpy(this->work_size_d, &work_size[0], 2 * sizeof(uint32_t),cudaMemcpyHostToDevice));
                KernelSizing(grid_dims, block_dims, size);
                Stopwatch sw_del(true);
                Stopwatch sw_reset_seed(true);
                kernel::reset_del_edges<<<grid_dims, block_dims, 0, stream_s.cuda_stream>>>(
                    app_inst,
                    graph_datum.GetParentDeviceObject(),
                    graph_datum.GetValueDeviceObject(),
                    graph_datum.GetBufferDeviceObject(),
                    this->del_edges_d,
                    this->work_size_d,
                    graph_datum.m_node_reset_datum,
                    m_device_affected_vertices.DeviceObject());
                stream_s.Sync();
                sw_reset_seed.stop();

                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                m_vcsr_dev_graph_allocator->SwitchZC();
                Stopwatch sw_invalidation(true);
                uint32_t frontier_begin = 0;
                uint32_t frontier_end = m_device_affected_vertices.GetCount(stream_s);
                uint32_t invalidation_rounds = 0;
                while (frontier_begin < frontier_end) {
                    const uint32_t frontier_count = frontier_end - frontier_begin;
                    RunSyncPushDDB_del(
                        app_inst,
                        true,
                        vcsr_graph,
                        graph_datum,
                        m_device_affected_vertices.GetDeviceDataPtr() + frontier_begin,
                        frontier_count,
                        m_device_affected_vertices.DeviceObject(),
                        m_engine_options,
                        stream_s);
                    stream_s.Sync();
                    const uint32_t new_end =
                        m_device_affected_vertices.GetCount(stream_s);
                    if (new_end < frontier_end || new_end > graph_datum.nnodes) {
                        LOG("[B2-INVALIDATION] protocol_error=invalid_queue_size batch=%u previous=%u current=%u nnodes=%u\n",
                            NumOfSnapShots, frontier_end, new_end, graph_datum.nnodes);
                        std::abort();
                    }
                    frontier_begin = frontier_end;
                    frontier_end = new_end;
                    ++invalidation_rounds;
                }
                sw_invalidation.stop();
                if (frontier_end != 0) {
                    KernelSizing(grid_dims, block_dims, frontier_end);
                    kernel::reset_affected_values<<<grid_dims, block_dims, 0,
                        stream_s.cuda_stream>>>(
                            app_inst,
                            m_device_affected_vertices.GetDeviceDataPtr(),
                            frontier_end,
                            graph_datum.GetValueDeviceObject(),
                            graph_datum.GetBufferDeviceObject());
                }
                CollectDeletionAffectedVertices(NumOfSnapShots);
                Stopwatch sw_physical_delete(true);
                del_edge_pr(local_begin, NumOfSnapShots);
                sw_physical_delete.stop();
                Stopwatch sw_repair(true);
                if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
                    RunGpuAffectedRepair(NumOfSnapShots);
                }
                sw_repair.stop();
                sw_del.stop();
                const double attributed_ms =
                    sw_reset_seed.ms() + sw_invalidation.ms() +
                    sw_physical_delete.ms() + sw_repair.ms();
                LOG("[P0-DELETE-ATTR][batch %u] repair_executor=gpu affected=%u invalidation_rounds=%u reset_seed_ms=%.3f initial_rebuild_ms=0.000 invalidation_ms=%.3f pma_delete_ms=%.3f repair_wall_ms=%.3f residual_ms=%.3f total_ms=%.3f\n",
                    NumOfSnapShots,
                    static_cast<uint32_t>(m_affected_vertices.size()),
                    invalidation_rounds,
                    sw_reset_seed.ms(),
                    sw_invalidation.ms(),
                    sw_physical_delete.ms(),
                    sw_repair.ms(),
                    sw_del.ms() - attributed_ms,
                    sw_del.ms());
                LOG("删除 time: %f ms (excluded)\n", sw_del.ms());
                // GatherCacheMiss();
                // GatherTransfer();
                // local_begin.second += load_update.m_batch_size[NumOfSnapShots].second;
                // NumOfSnapShots++;
            }

            void GatherValue() {
                return m_graph_datum->GatherValue();
            }

            void GatherReset() {
                // return m_graph_datum->GatherValue();
                return m_graph_datum->GatherReset();
                // m_graph_datum->GatherBuffer();
                // auto &ranks=this->GetGraphDatum().host_value;
                // auto &deltas=this->GetGraphDatum().host_buffer;
                // for(index_t i = 0 ; i < 100; i++){
                //     printf("%d rank %f delta %f\n",i,ranks[i],deltas[i]);
                // }

            }

            void GatherParent() {
                return m_graph_datum->GatherParent();
            }

            void GatherBuffer() {
                return m_graph_datum->GatherBuffer();
            }

            void GatherLevel(){
                return m_graph_datum->GatherLevel();
            }

            groute::graphs::dev::CSRGraph CSRDeviceObject() const {
                return m_csr_dev_graph_allocator->DeviceObject();
            }

            const groute::Stream &getStream() const {
                return *m_stream;
            }

            private:
            void PrepareTopologyReplayAudit(
                const std::pair<index_t, index_t> &local_begin,
                index_t batch) {
                if (!FLAGS_topology_replay_audit) return;
                if (m_topology_audit_expected) {
                    LOG("[TOPOLOGY-AUDIT] protocol_error=unfinished_audit previous_batch=%u next_batch=%u\n",
                        m_topology_audit_batch, batch);
                    std::abort();
                }

                Loader &load_update = *m_load_update;
                topology::TopologyMutationBatch mutations;
                const index_t add_count = load_update.m_batch_size[batch].first;
                const index_t delete_count = load_update.m_batch_size[batch].second;
                mutations.deletions.reserve(delete_count);
                mutations.additions.reserve(add_count);
                for (index_t i = local_begin.second;
                     i < local_begin.second + delete_count; ++i) {
                    mutations.deletions.push_back(
                        {load_update.deleted_edges_w[i].u,
                         load_update.deleted_edges_w[i].v});
                }
                for (index_t i = local_begin.first;
                     i < local_begin.first + add_count; ++i) {
                    mutations.additions.push_back(
                        {load_update.added_edges_w[i].u,
                         load_update.added_edges_w[i].v});
                }

                m_topology_audit_sources = mutations.TouchedSources();
                std::unordered_map<index_t, std::vector<index_t>> touched_adjacency;
                touched_adjacency.reserve(m_topology_audit_sources.size());
                const uint64_t graph_edge_count = m_chunk_store->EdgeCount();
                for (const index_t source : m_topology_audit_sources) {
                    touched_adjacency.emplace(
                        source, m_chunk_store->Neighbors(source));
                }

                m_topology_audit_expected.reset(
                    new topology::SparseTopologyReplayModel(
                        std::move(touched_adjacency), graph_edge_count));
                m_topology_audit_expected->ApplyBatch(mutations);
                m_topology_audit_batch = batch;
            }

            void VerifyTopologyReplayAudit(index_t batch) {
                if (!FLAGS_topology_replay_audit) return;
                if (!m_topology_audit_expected || m_topology_audit_batch != batch) {
                    LOG("[TOPOLOGY-AUDIT] protocol_error=missing_expected_state batch=%u\n",
                        batch);
                    std::abort();
                }

                const uint64_t actual_edge_count = m_chunk_store->EdgeCount();

                uint64_t mismatched_sources = 0;
                index_t first_mismatch = std::numeric_limits<index_t>::max();
                topology::SourceTopologyDigest first_expected;
                topology::SourceTopologyDigest first_actual;
                for (const index_t source : m_topology_audit_sources) {
                    const auto expected = m_topology_audit_expected->Digest(source);
                    const auto actual = m_chunk_store->Digest(source);
                    if (!(expected == actual)) {
                        if (mismatched_sources == 0) {
                            first_mismatch = source;
                            first_expected = expected;
                            first_actual = actual;
                        }
                        ++mismatched_sources;
                    }
                }
                const uint64_t expected_edge_count =
                    m_topology_audit_expected->EdgeCount();
                LOG("[TOPOLOGY-AUDIT][batch %u] touched_sources=%zu mismatched_sources=%llu expected_edges=%llu actual_edges=%llu first_mismatch=%u expected_degree=%llu actual_degree=%llu expected_ordered_hash=%llu actual_ordered_hash=%llu expected_multiset_hash=%llu actual_multiset_hash=%llu\n",
                    batch,
                    m_topology_audit_sources.size(),
                    static_cast<unsigned long long>(mismatched_sources),
                    static_cast<unsigned long long>(expected_edge_count),
                    static_cast<unsigned long long>(actual_edge_count),
                    first_mismatch,
                    static_cast<unsigned long long>(first_expected.degree),
                    static_cast<unsigned long long>(first_actual.degree),
                    static_cast<unsigned long long>(first_expected.ordered_hash),
                    static_cast<unsigned long long>(first_actual.ordered_hash),
                    static_cast<unsigned long long>(first_expected.multiset_hash),
                    static_cast<unsigned long long>(first_actual.multiset_hash));

                m_topology_audit_expected.reset();
                m_topology_audit_sources.clear();
                if (mismatched_sources != 0 ||
                    expected_edge_count != actual_edge_count) {
                    std::abort();
                }
            }

            void LoadOptions() {
                if (!m_engine_options.IsForceLoadBalancing(MsgPassing::PUSH)) {
                    if (FLAGS_lb_push.size() == 0) {
                        if (m_groute_context->host_pma_small.avg_degree() >= 0) { //all FINE_GRAINED
                            m_engine_options.SetLoadBalancing(MsgPassing::PUSH, LoadBalancing::FINE_GRAINED);
                        }
                        } else {
                            if (FLAGS_lb_push == "none") {
                                m_engine_options.SetLoadBalancing(MsgPassing::PUSH, LoadBalancing::NONE);
                                } else if (FLAGS_lb_push == "coarse") {
                                    m_engine_options.SetLoadBalancing(MsgPassing::PUSH, LoadBalancing::COARSE_GRAINED);
                                    } else if (FLAGS_lb_push == "fine") {
                                        m_engine_options.SetLoadBalancing(MsgPassing::PUSH, LoadBalancing::FINE_GRAINED);
                                        } else if (FLAGS_lb_push == "hybrid") {
                                            m_engine_options.SetLoadBalancing(MsgPassing::PUSH, LoadBalancing::HYBRID);
                                            } else {
                                                fprintf(stderr, "unknown push load-balancing policy");
                                                exit(1);
                                            }
                                        }
                                    }

                if (!m_engine_options.IsForceLoadBalancing(MsgPassing::PULL)) {
                    if (FLAGS_lb_pull.size() == 0) {
                        if (m_groute_context->host_pma_small.avg_degree() >= 5) {
                            m_engine_options.SetLoadBalancing(MsgPassing::PULL, LoadBalancing::FINE_GRAINED);
                        }
                        } else {
                            if (FLAGS_lb_pull == "none") {
                                m_engine_options.SetLoadBalancing(MsgPassing::PULL, LoadBalancing::NONE);
                                } else if (FLAGS_lb_pull == "coarse") {
                                    m_engine_options.SetLoadBalancing(MsgPassing::PULL, LoadBalancing::COARSE_GRAINED);
                                    } else if (FLAGS_lb_pull == "fine") {
                                        m_engine_options.SetLoadBalancing(MsgPassing::PULL, LoadBalancing::FINE_GRAINED);
                                        } else if (FLAGS_lb_pull == "hybrid") {
                                            m_engine_options.SetLoadBalancing(MsgPassing::PULL, LoadBalancing::HYBRID);
                                            } else {
                                                fprintf(stderr, "unknown pull load-balancing policy");
                                                exit(1);
                                            }
                                        }
                                    }

                                    if (FLAGS_alpha == 0) {
                                        fprintf(stderr, "Warning: alpha = 0, A general method AsyncPushDD is used\n");
                                        m_engine_options.ForceVariant(AlgoVariant::ASYNC_PUSH_DD);
                                    }
                                }


            void PreComputationBW() {// Reorganizing nothing, just reset the round and record the workload.
                const int dev_id = 0;
                const groute::Stream &stream = m_groute_context->CreateStream(dev_id);
                GraphDatum &graph_datum = *m_graph_datum;
                m_running_info.current_round++;
                graph_datum.m_current_round.set_val_H2DAsync(m_running_info.current_round, stream.cuda_stream);

                stream.Sync();
            }


            void ExecutePolicy_add(AlgoVariant *algo_variant) {
                // LOG("------ExecutePolicy_ADD------\n");
                auto &app_inst = *m_app_inst;
                auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr,seg_nedges_csr;
                index_t seg_snode,seg_enode;
                index_t seg_idx_new;

                m_groute_context->segment_ct = FLAGS_SEGMENT;
                Stopwatch sw_execution(true);

                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];                            // start edge
                    seg_nedges_csr = m_groute_context->seg_nedge_csr[seg_idx];

                    stream_id = seg_idx % FLAGS_n_stream;

                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        // m_running_info.zerocopy_num++;
                        m_vcsr_dev_graph_allocator->SwitchZC();
                        // m_graph_datum->m_vcsr_edge_weight_datum.SwitchZC();
                        zcflag = true;
                        RunSyncPushDDB_ADD(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                           vcsr_graph,
                           graph_datum,
                           m_engine_options,
                           stream[stream_id]);
                    }
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
                sw_execution.stop();
               LOG("插入刷新缓存 time: %f ms (excluded)\n", sw_execution.ms());
            }

            void StageGpuToCpuBoundary(InsertionRoundStats &stats) {
                if (!m_insertion_epoch_active ||
                    (FLAGS_sssp_cpu_partition_capacity == 0 &&
                     !m_cpu_domain_map_enabled)) return;

                GraphDatum &graph_datum = *m_graph_datum;
                const TBuffer infinity = std::numeric_limits<TBuffer>::max();
                const uint32_t boundary_count =
                    m_device_gpu_to_cpu_boundary_vertices.GetCount(*m_stream);
                m_cpu_boundary_proposals.clear();
                if (boundary_count != 0) {
                    EnsureInsertionDeviceCapacity(&m_device_cpu_boundary_proposals,
                                             &m_device_cpu_boundary_proposal_capacity,
                                             boundary_count,
                                             stats);
                    dim3 grid_dims, block_dims;
                    KernelSizing(grid_dims, block_dims, boundary_count);
                    GatherAndResetBoundary<TBuffer><<<grid_dims, block_dims>>>(
                        m_device_gpu_to_cpu_boundary_vertices.GetDeviceDataPtr(),
                        boundary_count,
                        m_device_gpu_to_cpu_boundary_values,
                        m_device_gpu_to_cpu_boundary_parents,
                        m_device_cpu_boundary_proposals,
                        infinity);
                    m_cpu_boundary_proposals.resize(boundary_count);
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        m_cpu_boundary_proposals.data(),
                        m_device_cpu_boundary_proposals,
                        sizeof(CpuRelaxProposal<TBuffer>) * boundary_count,
                        cudaMemcpyDeviceToHost));
                    m_device_gpu_to_cpu_boundary_vertices.ResetAsync(
                        m_stream->cuda_stream);
                    m_stream->Sync();
                    stats.gpu_to_cpu_boundary_items += boundary_count;
                    stats.gpu_to_cpu_boundary_bytes +=
                        sizeof(CpuRelaxProposal<TBuffer>) * boundary_count;
                }

                for (const auto &proposal : m_cpu_boundary_proposals) {
                    if (proposal.value == infinity) continue;
                    if (proposal.dst >= graph_datum.nnodes ||
                        !m_node_cpu_owner[proposal.dst]) {
                        LOG("[DUAL-RUNTIME] protocol_error=gpu_to_cpu_owner_violation epoch=%u dst=%u\n",
                            m_insertion_epoch, proposal.dst);
                        std::abort();
                    }
                    const TBuffer current = std::min(
                        static_cast<TBuffer>(m_cpu_node_values[proposal.dst]),
                        m_cpu_node_buffers[proposal.dst]);
                    if (proposal.value < current) {
                        m_cpu_node_values[proposal.dst] =
                            static_cast<TValue>(proposal.value);
                        m_cpu_node_buffers[proposal.dst] = proposal.value;
                        m_cpu_node_parents[proposal.dst] = proposal.parent;
                        m_cpu_frontier.push_back(proposal.dst);
                        m_cpu_dirty_vertices.push_back(proposal.dst);
                    }
                }
            }

            void StageCpuOwnedActiveSources(InsertionRoundStats &stats) {
                if (!m_cpu_domain_map_enabled || !m_insertion_epoch_active) return;
                GraphDatum &graph_datum = *m_graph_datum;
                uint64_t staged = 0;
                uint64_t staged_edges = 0;
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    const index_t count = graph_datum.seg_active_num[seg];
                    if (count == 0) continue;
                    std::vector<index_t> active_sources(count);
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        active_sources.data(),
                        graph_datum.m_wl_array_in_seg[seg].GetDeviceDataPtr(),
                        sizeof(index_t) * count, cudaMemcpyDeviceToHost));
                    std::vector<index_t> gpu_sources;
                    gpu_sources.reserve(count);
                    for (const index_t src : active_sources) {
                        if (src < graph_datum.nnodes && m_node_cpu_owner[src]) {
                            m_cpu_frontier.push_back(src);
                            ++staged;
                            staged_edges += m_chunk_store->Descriptor(src).degree;
                        } else {
                            gpu_sources.push_back(src);
                        }
                    }
                    if (!gpu_sources.empty()) {
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            graph_datum.m_wl_array_in_seg[seg].GetDeviceDataPtr(),
                            gpu_sources.data(),
                            sizeof(index_t) * gpu_sources.size(),
                            cudaMemcpyHostToDevice));
                    }
                    graph_datum.seg_active_num[seg] = gpu_sources.size();
                    m_running_info.input_active_count_seg[seg] = gpu_sources.size();
                }
                stats.cpu_removed_gpu_sources += staged;
                stats.cpu_removed_gpu_source_edges += staged_edges;
                if (staged != 0) {
                    LOG("[E2-DOMAIN-SOURCE] epoch=%u round=%llu staged_cpu_sources=%llu removed_gpu_source_edges=%llu\n",
                        m_insertion_epoch,
                        static_cast<unsigned long long>(m_insertion_convergence_round + 1),
                        static_cast<unsigned long long>(staged),
                        static_cast<unsigned long long>(staged_edges));
                }
            }

            void RunCpuOwnedClosureHost(
                    InsertionRoundStats &stats,
                    std::vector<CpuRelaxProposal<TBuffer>> &gpu_boundary) {
                Stopwatch sw_cpu_owner(true);
                GraphDatum &graph_datum = *m_graph_datum;
                const TBuffer infinity = std::numeric_limits<TBuffer>::max();
                while (!m_cpu_frontier.empty()) {
                    const size_t wave_size = m_cpu_frontier.size();
                    ++stats.cpu_closure_rounds;
                    for (size_t wave_offset = 0; wave_offset < wave_size; ++wave_offset) {
                        const index_t src = m_cpu_frontier.front();
                        m_cpu_frontier.pop_front();
                        const TBuffer src_value = m_cpu_node_buffers[src];
                        const uint64_t degree = m_chunk_store->Descriptor(src).degree;
                        ++stats.cpu_expanded_vertices;
                        stats.cpu_edge_visits += degree;
                        for (uint64_t offset = 0; offset < degree; ++offset) {
                            const index_t dst = m_chunk_store->SlabData(
                                m_chunk_store->Descriptor(src).slab_id)[
                                    m_chunk_store->Descriptor(src).index + offset];
                            if (dst >= graph_datum.nnodes) continue;
                            const uint64_t candidate_wide =
                                static_cast<uint64_t>(src_value) +
                                static_cast<uint64_t>((src + dst) % 128 + 1);
                            if (candidate_wide >= static_cast<uint64_t>(infinity)) continue;
                            const TBuffer candidate = static_cast<TBuffer>(candidate_wide);
                            if (m_node_cpu_owner[dst]) {
                                const TBuffer current = std::min(
                                    static_cast<TBuffer>(m_cpu_node_values[dst]),
                                    m_cpu_node_buffers[dst]);
                                if (candidate < current) {
                                    m_cpu_node_values[dst] = static_cast<TValue>(candidate);
                                    m_cpu_node_buffers[dst] = candidate;
                                    m_cpu_node_parents[dst] = src;
                                    m_cpu_frontier.push_back(dst);
                                    m_cpu_dirty_vertices.push_back(dst);
                                    ++stats.cpu_local_relax_success;
                                }
                            } else {
                                gpu_boundary.push_back({dst, candidate, src});
                            }
                        }
                    }
                }
                sw_cpu_owner.stop();
                stats.cpu_service_ms += sw_cpu_owner.ms();
            }

            void CommitCpuOwnedClosure(
                    std::vector<CpuRelaxProposal<TBuffer>> &gpu_boundary,
                    bool cpu_closure_ran,
                    InsertionRoundStats &stats) {
                GraphDatum &graph_datum = *m_graph_datum;
                if (!cpu_closure_ran) return;
                if (m_cpu_domain_map_enabled) {
                    ScatterCpuDomainDirtyState(stats);
                } else {
                    for (const index_t seg : m_cpu_owned_segments) {
                        const index_t begin = m_groute_context->seg_snode[seg];
                        const index_t end = m_groute_context->seg_enode[seg];
                        const size_t count = end - begin;
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            graph_datum.GetValueDeviceObject() + begin,
                            m_cpu_node_values.data() + begin,
                            sizeof(TValue) * count, cudaMemcpyHostToDevice));
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            graph_datum.GetBufferDeviceObject() + begin,
                            m_cpu_node_buffers.data() + begin,
                            sizeof(TBuffer) * count, cudaMemcpyHostToDevice));
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            graph_datum.GetParentDeviceObject() + begin,
                            m_cpu_node_parents.data() + begin,
                            sizeof(index_t) * count, cudaMemcpyHostToDevice));
                    }
                }

                for (const auto &proposal : gpu_boundary) {
                    if (proposal.dst >= graph_datum.nnodes ||
                        m_node_cpu_owner[proposal.dst]) {
                        LOG("[DUAL-RUNTIME] protocol_error=cpu_to_gpu_owner_violation epoch=%u dst=%u\n",
                            m_insertion_epoch, proposal.dst);
                        std::abort();
                    }
                }
                if (!gpu_boundary.empty()) {
                    CommitCpuBoundaryProposals(gpu_boundary,
                                          stats,
                                          m_device_insertion_changed_vertices.DeviceObject());
                }
                stats.cpu_to_gpu_boundary_proposals += gpu_boundary.size();
                stats.cpu_to_gpu_boundary_bytes +=
                    sizeof(CpuRelaxProposal<TBuffer>) * gpu_boundary.size();
            }

            void CaptureE0BActiveWork() {
                if (!m_e0b_trace.is_open() || !m_insertion_epoch_active) return;
                std::fill(m_e0b_region_activity.begin(),
                          m_e0b_region_activity.end(), E0BRegionActivity{});
                m_e0b_active_sources.clear();
                m_e0b_success_records.clear();
                m_e0b_success_edges.clear();
                m_e0b_success_total = 0;
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    const index_t count = m_graph_datum->seg_active_num[seg];
                    if (count == 0) continue;
                    const index_t stream_id = seg % FLAGS_n_stream;
                    std::vector<index_t> active_sources(count);
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        active_sources.data(),
                        m_graph_datum->m_wl_array_in_seg[seg].GetDeviceDataPtr(),
                        sizeof(index_t) * count,
                        cudaMemcpyDeviceToHost));
                    E0BRegionActivity &activity = m_e0b_region_activity[seg];
                    activity.active_vertices += count;
                    for (const index_t src : active_sources) {
                        if (src >= m_graph_datum->nnodes) {
                            LOG("[E0B-TRACE] protocol_error=active_source_oob src=%u nnodes=%u\n",
                                src, m_graph_datum->nnodes);
                            std::abort();
                        }
                        activity.scanned_edges +=
                            m_chunk_store->Descriptor(src).degree;
                        m_e0b_active_sources.push_back(
                            {src, m_chunk_store->Descriptor(src).degree});
                    }
                    (void)stream_id;
                }
            }

            void CaptureE0BSuccessfulPropagation(uint32_t changed_count) {
                if (!m_e0b_trace.is_open() || !m_insertion_epoch_active ||
                    changed_count == 0) return;
                InsertionRoundStats allocation_stats;
                EnsureInsertionDeviceCapacity(&m_device_cpu_boundary_proposals,
                                              &m_device_cpu_boundary_proposal_capacity,
                                              changed_count,
                                              allocation_stats);
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, changed_count);
                GatherSuccessfulPropagation<TValue, TBuffer>
                    <<<grid_dims, block_dims, 0, m_stream->cuda_stream>>>(
                        m_device_insertion_changed_vertices.GetDeviceDataPtr(),
                        changed_count,
                        m_graph_datum->GetParentDeviceObject(),
                        m_device_cpu_boundary_proposals);
                m_cpu_boundary_proposals.resize(changed_count);
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    m_cpu_boundary_proposals.data(),
                    m_device_cpu_boundary_proposals,
                    sizeof(CpuRelaxProposal<TBuffer>) * changed_count,
                    cudaMemcpyDeviceToHost));
                std::sort(m_cpu_boundary_proposals.begin(),
                          m_cpu_boundary_proposals.end(),
                          [](const CpuRelaxProposal<TBuffer> &lhs,
                             const CpuRelaxProposal<TBuffer> &rhs) {
                              return lhs.dst != rhs.dst
                                  ? lhs.dst < rhs.dst
                                  : lhs.parent < rhs.parent;
                          });
                index_t previous_dst = std::numeric_limits<index_t>::max();
                for (const auto &record : m_cpu_boundary_proposals) {
                    if (record.dst == previous_dst) continue;
                    previous_dst = record.dst;
                    if (record.dst >= m_graph_datum->nnodes ||
                        record.parent >= m_graph_datum->nnodes) continue;
                    const index_t src_region = FindSegmentForVertexHost(record.parent);
                    const index_t dst_region = FindSegmentForVertexHost(record.dst);
                    if (src_region >= FLAGS_SEGMENT || dst_region >= FLAGS_SEGMENT) {
                        LOG("[E0B-TRACE] protocol_error=region_lookup_failed src=%u dst=%u\n",
                            record.parent, record.dst);
                        std::abort();
                    }
                    ++m_e0b_success_edges[{src_region, dst_region}];
                    m_e0b_success_records.push_back({record.parent, record.dst});
                    ++m_e0b_success_total;
                }
            }

            void EmitE0BTrace(const InsertionRoundStats &stats, double round_wall_ms) {
                if (!m_e0b_trace.is_open() || !m_insertion_epoch_active) return;
                uint64_t active_total = 0;
                uint64_t scanned_total = 0;
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    const E0BRegionActivity &activity = m_e0b_region_activity[seg];
                    active_total += activity.active_vertices;
                    scanned_total += activity.scanned_edges;
                    if (activity.active_vertices == 0) continue;
                    m_e0b_trace << "A\t" << m_insertion_epoch << '\t'
                                << (m_insertion_convergence_round + 1) << '\t'
                                << seg << '\t' << activity.active_vertices << '\t'
                                << activity.scanned_edges << '\n';
                }
                for (const auto &source : m_e0b_active_sources) {
                    m_e0b_trace << "S\t" << m_insertion_epoch << '\t'
                                << (m_insertion_convergence_round + 1) << '\t'
                                << source.first << '\t' << source.second << '\n';
                }
                for (const auto &entry : m_e0b_success_edges) {
                    m_e0b_trace << "P\t" << m_insertion_epoch << '\t'
                                << (m_insertion_convergence_round + 1) << '\t'
                                << entry.first.first << '\t' << entry.first.second
                                << '\t' << entry.second << '\n';
                }
                for (const auto &edge : m_e0b_success_records) {
                    m_e0b_trace << "E\t" << m_insertion_epoch << '\t'
                                << (m_insertion_convergence_round + 1) << '\t'
                                << edge.first << '\t' << edge.second << '\n';
                }
                m_e0b_trace << "R\t" << m_insertion_epoch << '\t'
                            << (m_insertion_convergence_round + 1) << '\t'
                            << active_total << '\t' << scanned_total << '\t'
                            << m_e0b_success_total << '\t' << stats.gpu_service_ms
                            << '\t' << round_wall_ms << '\n';
                m_e0b_trace.flush();
            }

            void ExecutePolicy_Converge(AlgoVariant *algo_variant) {
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                Stopwatch sw_execution(true);
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr;
                index_t seg_snode,seg_enode;

                m_groute_context->segment_ct = FLAGS_SEGMENT;

                uint64_t active_sources = 0;
                uint64_t active_edge_span_upper_bound = 0;
                uint32_t active_partitions = 0;
                uint32_t kernel_launches = 0;
                using RoundClock = std::chrono::steady_clock;
                RoundClock::time_point gpu_start;
                RoundClock::time_point gpu_end;
                RoundClock::time_point cpu_start;
                RoundClock::time_point cpu_end;
                const bool exact_all_gpu = m_insertion_epoch_active &&
                    !m_cpu_domain_map_enabled &&
                    FLAGS_sssp_cpu_partition_capacity == 0;
                InsertionRoundStats cpu_stats;
                if (!m_exact_source_frontier_ready) CaptureE0BActiveWork();
                StageGpuToCpuBoundary(cpu_stats);
                StageCpuOwnedActiveSources(cpu_stats);
                const bool cpu_closure_ran = !m_cpu_frontier.empty();
                std::vector<CpuRelaxProposal<TBuffer>> gpu_boundary;
                groute::Queue<index_t> &exact_input =
                    graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT];
                groute::Queue<index_t> &exact_output =
                    graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT + 1];
                if (exact_all_gpu) {
                    exact_output.ResetAsync(m_stream->cuda_stream);
                } else {
                    m_device_insertion_changed_vertices.ResetAsync(
                        m_stream->cuda_stream);
                }
                m_stream->Sync();
                if (m_insertion_epoch_active && m_device_exact_source_counts == nullptr) {
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_exact_source_counts),
                        4 * sizeof(unsigned long long)));
                }
                if (m_insertion_epoch_active) {
                    GROUTE_CUDA_CHECK(cudaMemset(m_device_exact_source_counts, 0,
                        4 * sizeof(unsigned long long)));
                }
                if (exact_all_gpu && m_exact_source_frontier_ready) {
                    active_sources = m_exact_source_frontier_count;
                    active_partitions = active_sources == 0 ? 0 : 1;
                    const auto &vcsr_graph =
                        m_vcsr_dev_graph_allocator->DeviceObject();
                    if (active_sources != 0) {
                        gpu_start = RoundClock::now();
                        ExpandExactGpuSources<<<active_sources, 128, 0,
                            stream[0].cuda_stream>>>(
                            app_inst,
                            exact_input.GetDeviceDataPtr(),
                            active_sources, vcsr_graph,
                            graph_datum.GetValueDeviceObject(),
                            graph_datum.GetBufferDeviceObject(),
                            graph_datum.GetParentDeviceObject(),
                            exact_output.DeviceObject(),
                            m_device_exact_source_counts,
                            m_device_exact_source_counts + 1);
                        kernel_launches = 1;
                    }
                } else {
                    for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; ++seg_idx) {
                        if (graph_datum.seg_active_num[seg_idx] == 0) continue;
                        active_sources += graph_datum.seg_active_num[seg_idx];
                        active_edge_span_upper_bound +=
                            m_groute_context->seg_nedge_csr[seg_idx];
                        active_partitions++;
                    }
                }
                index_t stream_id;
                const auto gpu_submit_start = RoundClock::now();
                std::thread cpu_worker;
                const auto launch_cpu_worker = [&]() {
                    if (!cpu_closure_ran || cpu_worker.joinable()) return;
                    cpu_worker = std::thread([&]() {
                        cpu_start = RoundClock::now();
                        RunCpuOwnedClosureHost(cpu_stats, gpu_boundary);
                        cpu_end = RoundClock::now();
                    });
                };
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    if (exact_all_gpu && m_exact_source_frontier_ready) break;
                    if (graph_datum.seg_active_num[seg_idx] == 0) {
                        continue;
                    }
                    if (m_insertion_epoch_active &&
                        m_partition_owners[seg_idx] ==
                            static_cast<uint8_t>(PartitionOwner::CPU)) {
                        LOG("[DUAL-RUNTIME] protocol_error=cpu_owner_in_gpu_worklist epoch=%u segment=%u\n",
                            m_insertion_epoch, seg_idx);
                        std::abort();
                    }
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];                                    // end node
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];                            // start edge

                    stream_id = seg_idx % FLAGS_n_stream;

                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        if (kernel_launches == 0) {
                            gpu_start = RoundClock::now();
                        }
                        if (exact_all_gpu) {
                            ExpandExactGpuSources<<<graph_datum.seg_active_num[seg_idx],
                                128, 0, stream[stream_id].cuda_stream>>>(
                                app_inst,
                                graph_datum.m_wl_array_in_seg[seg_idx].GetDeviceDataPtr(),
                                graph_datum.seg_active_num[seg_idx], vcsr_graph,
                                graph_datum.GetValueDeviceObject(),
                                graph_datum.GetBufferDeviceObject(),
                                graph_datum.GetParentDeviceObject(),
                                m_device_insertion_changed_vertices.DeviceObject(),
                                m_device_exact_source_counts,
                                m_device_exact_source_counts + 1);
                        } else {
                            m_vcsr_dev_graph_allocator->SwitchZC();
                            zcflag = true;
                            RunSyncPushDDB_Delta(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                               vcsr_graph,
                               graph_datum,
                                   m_engine_options,
                                   stream[stream_id],
                                   m_device_insertion_changed_vertices.DeviceObject(),
                                   m_insertion_epoch_active,
                                   m_insertion_epoch_active ? m_device_cpu_destination_flags : nullptr,
                                   m_insertion_epoch_active
                                       ? m_device_gpu_to_cpu_boundary_vertices.DeviceObject()
                                       : groute::dev::Queue<index_t>(nullptr, nullptr, 0),
                                   m_insertion_epoch_active
                                   ? m_device_gpu_to_cpu_boundary_values : nullptr,
                                   m_insertion_epoch_active
                                   ? m_device_gpu_to_cpu_boundary_parents : nullptr,
                                   graph_datum.seg_active_num[seg_idx]);
                        }
                        kernel_launches++;
                        launch_cpu_worker();
                    }
               }
               const auto gpu_submit_end = RoundClock::now();
               if (kernel_launches != 0) {
                   cpu_stats.gpu_submit_ms =
                       std::chrono::duration<double, std::milli>(
                           gpu_submit_end - gpu_submit_start).count();
               }

               launch_cpu_worker();
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
               gpu_end = RoundClock::now();
               unsigned long long exact_counts[2] = {0, 0};
               if (m_insertion_epoch_active && !m_cpu_domain_map_enabled &&
                   FLAGS_sssp_cpu_partition_capacity == 0) {
                   GROUTE_CUDA_CHECK(cudaMemcpy(exact_counts,
                       m_device_exact_source_counts, sizeof(exact_counts),
                       cudaMemcpyDeviceToHost));
                   if (exact_counts[0] == 0 && exact_counts[1] != 0) {
                       LOG("[E4-R1] protocol_error=edges_without_processed_source epoch=%u round=%llu sources=%llu edges=%llu\n",
                           m_insertion_epoch,
                           static_cast<unsigned long long>(m_insertion_convergence_round + 1),
                           exact_counts[0], exact_counts[1]);
                       std::abort();
                   }
                   LOG("[E4-R1-EXACT] epoch=%u round=%llu offered_sources=%llu processed_sources=%llu logical_edges=%llu processed_edges=%llu partition_rebuilds=0 frontier_syncs=1\n",
                       m_insertion_epoch,
                       static_cast<unsigned long long>(m_insertion_convergence_round + 1),
                       static_cast<unsigned long long>(active_sources),
                       exact_counts[0], exact_counts[1], exact_counts[1]);
               }
               if (cpu_worker.joinable()) {
                   cpu_worker.join();
               }
               const auto joined_at = RoundClock::now();

               if (kernel_launches != 0) {
                   cpu_stats.gpu_service_ms =
                       std::chrono::duration<double, std::milli>(
                           gpu_end - gpu_start).count();
               }
               if (cpu_closure_ran && kernel_launches != 0) {
                   const auto overlap_start = std::max(cpu_start, gpu_start);
                   const auto overlap_end = std::min(cpu_end, gpu_end);
                   if (overlap_end > overlap_start) {
                       cpu_stats.overlap_ms =
                           std::chrono::duration<double, std::milli>(
                               overlap_end - overlap_start).count();
                   }
                   cpu_stats.concurrent = cpu_stats.overlap_ms > 0.0;
                   if (cpu_end > gpu_end) {
                       cpu_stats.gpu_wait_ms =
                           std::chrono::duration<double, std::milli>(
                               joined_at - gpu_end).count();
                   } else if (gpu_end > cpu_end) {
                       cpu_stats.cpu_wait_ms =
                           std::chrono::duration<double, std::milli>(
                               gpu_end - cpu_end).count();
                   }
               }

               CommitCpuOwnedClosure(gpu_boundary, cpu_closure_ran, cpu_stats);
               StageGpuToCpuBoundary(cpu_stats);

               if (exact_all_gpu) {
                   AdvanceExactSourceFrontier(exact_input, exact_output);
               } else {
                   PostComputationBW();
               }
               sw_execution.stop();
               EmitE0BTrace(cpu_stats, sw_execution.ms());
               const uint64_t reported_round = m_insertion_epoch_active
                   ? m_insertion_convergence_round + 1
                   : m_running_info.current_round;
               if (FLAGS_verbose) {
                   uint64_t next_active_sources = 0;
                   uint32_t next_active_partitions = 0;
                   for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; ++seg_idx) {
                       next_active_sources += graph_datum.seg_active_num[seg_idx];
                       next_active_partitions +=
                           graph_datum.seg_active_num[seg_idx] == 0 ? 0 : 1;
                   }
                   LOG("[P0-FRONTIER][insert] state_round=%llu active_sources=%llu active_partitions=%u active_edge_span_upper_bound=%llu kernel_launches=%u post_rebuild_partitions=%d next_active_sources=%llu next_active_partitions=%u round_wall_ms=%.3f\n",
                       static_cast<unsigned long long>(reported_round),
                       static_cast<unsigned long long>(active_sources),
                       active_partitions,
                       static_cast<unsigned long long>(active_edge_span_upper_bound),
                       kernel_launches,
                       m_insertion_epoch_active
                           ? m_last_insertion_dirty_partitions
                           : static_cast<uint32_t>(FLAGS_SEGMENT),
                       static_cast<unsigned long long>(next_active_sources),
                       next_active_partitions,
                       sw_execution.ms());
               }
               LOG("[DUAL-RUNTIME-ROUND] epoch=%u round=%llu gpu_kernels=%u gpu_vertices=%llu gpu_edge_span_upper_bound=%llu removed_gpu_sources=%llu removed_gpu_source_edges=%llu cpu_vertices=%llu cpu_edges=%llu cpu_closure_rounds=%llu cpu_local_relax=%llu cpu_state_scatter_vertices=%llu cpu_state_scatter_bytes=%llu cpu_state_scatter_ms=%.3f gpu_to_cpu_items=%llu gpu_to_cpu_bytes=%llu cpu_to_gpu_items=%llu cpu_to_gpu_bytes=%llu cpu_to_gpu_success=%llu gpu_submit_ms=%.3f gpu_service_ms=%.3f cpu_service_ms=%.3f overlap_ms=%.3f cpu_wait_ms=%.3f gpu_wait_ms=%.3f concurrent=%d proposal_alloc_ms=%.3f proposal_compress_ms=%.3f proposal_h2d_ms=%.3f proposal_merge_ms=%.3f dirty_partitions=%u barriers=1 wall_ms=%.3f\n",
                   m_insertion_epoch,
                   static_cast<unsigned long long>(reported_round),
                   kernel_launches,
                   static_cast<unsigned long long>(active_sources),
                   static_cast<unsigned long long>(active_edge_span_upper_bound),
                   static_cast<unsigned long long>(cpu_stats.cpu_removed_gpu_sources),
                   static_cast<unsigned long long>(cpu_stats.cpu_removed_gpu_source_edges),
                   static_cast<unsigned long long>(cpu_stats.cpu_expanded_vertices),
                   static_cast<unsigned long long>(cpu_stats.cpu_edge_visits),
                   static_cast<unsigned long long>(cpu_stats.cpu_closure_rounds),
                   static_cast<unsigned long long>(cpu_stats.cpu_local_relax_success),
                   static_cast<unsigned long long>(cpu_stats.cpu_state_scatter_vertices),
                   static_cast<unsigned long long>(cpu_stats.cpu_state_scatter_bytes),
                   cpu_stats.cpu_state_scatter_ms,
                   static_cast<unsigned long long>(cpu_stats.gpu_to_cpu_boundary_items),
                   static_cast<unsigned long long>(cpu_stats.gpu_to_cpu_boundary_bytes),
                   static_cast<unsigned long long>(cpu_stats.cpu_to_gpu_boundary_proposals),
                   static_cast<unsigned long long>(cpu_stats.cpu_to_gpu_boundary_bytes),
                   static_cast<unsigned long long>(cpu_stats.cpu_proposals_success),
                   cpu_stats.gpu_submit_ms,
                   cpu_stats.gpu_service_ms,
                   cpu_stats.cpu_service_ms,
                   cpu_stats.overlap_ms,
                   cpu_stats.cpu_wait_ms,
                   cpu_stats.gpu_wait_ms,
                   cpu_stats.concurrent ? 1 : 0,
                   cpu_stats.allocation_ms,
                   cpu_stats.proposal_compress_ms,
                   cpu_stats.h2d_proposal_ms,
                   cpu_stats.merge_ms,
                   m_last_insertion_dirty_partitions,
                   sw_execution.ms());

            //    sw_round.stop();

            }

            void PostComputationBW() {
                // printf("------------PostComputationBW-----------\n");
                int dev_id = 0;
                const groute::Stream &stream_seg = m_groute_context->CreateStream(dev_id);
                GraphDatum &graph_datum = *m_graph_datum;
                AppImplDeviceObject &app_inst = *m_app_inst;
                m_running_info.current_round = m_graph_datum->m_current_round.get_val_D2H();
                std::vector<uint8_t> dirty_segments(
                    FLAGS_SEGMENT, m_insertion_epoch_active ? 0 : 1);
                if (m_insertion_epoch_active) {
                    const uint32_t changed_count =
                        m_device_insertion_changed_vertices.GetCount(*m_stream);
                    m_insertion_changed_vertices.resize(changed_count);
                    if (changed_count != 0) {
                        GROUTE_CUDA_CHECK(cudaMemcpy(
                            m_insertion_changed_vertices.data(),
                            m_device_insertion_changed_vertices.GetDeviceDataPtr(),
                            sizeof(index_t) * changed_count,
                            cudaMemcpyDeviceToHost));
                        for (const index_t dst : m_insertion_changed_vertices) {
                            const index_t seg = FindSegmentForVertexHost(dst);
                            if (seg < FLAGS_SEGMENT) dirty_segments[seg] = 1;
                        }
                    }
                    CaptureE0BSuccessfulPropagation(changed_count);
                }
                m_last_insertion_dirty_partitions = static_cast<uint32_t>(
                    std::count(dirty_segments.begin(), dirty_segments.end(), uint8_t{1}));
                Stopwatch sw_unique(true);

                index_t seg_snode,seg_enode;
                index_t stream_id;

                Stopwatch sw_rebuild(true);
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    if (!dirty_segments[seg_idx]) {
                        graph_datum.seg_active_num[seg_idx] = 0;
                        m_running_info.input_active_count_seg[seg_idx] = 0;
                        continue;
                    }
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                    RebuildArrayWorklist(app_inst,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx,
                        m_insertion_epoch_active ? m_device_node_state_epoch : nullptr,
                        m_insertion_epoch);
                }

                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                sw_rebuild.stop();
                m_running_info.time_overhead_rebuild_worklist += sw_rebuild.ms();
                if (m_insertion_epoch_active) {
                    for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; ++seg_idx) {
                        if (!dirty_segments[seg_idx]) continue;
                        const index_t sid = seg_idx % FLAGS_n_stream;
                        const index_t active =
                            graph_datum.m_wl_array_in_seg[seg_idx].GetCount(stream[sid]);
                        graph_datum.seg_active_num[seg_idx] = active;
                        m_running_info.input_active_count_seg[seg_idx] = active;
                    }
                } else {
                    RefreshSegmentActiveCountsFromQueues();
                }
                // printf("static num nodes %d\n",act);
                sw_unique.stop();
                m_running_info.time_overhead_wl_unique += sw_unique.ms();
          }

            void AdvanceExactSourceFrontier(groute::Queue<index_t> &input,
                                            groute::Queue<index_t> &output) {
                GraphDatum &graph_datum = *m_graph_datum;
                const uint32_t changed_count = output.GetCount(*m_stream);
                input.Swap(output);
                m_exact_source_frontier_ready = true;
                m_exact_source_frontier_count = changed_count;
                m_last_insertion_dirty_partitions = 0;
                for (index_t seg = 0; seg < FLAGS_SEGMENT; ++seg) {
                    graph_datum.seg_active_num[seg] = 0;
                    m_running_info.input_active_count_seg[seg] = 0;
                }
                if (changed_count != 0) {
                    graph_datum.seg_active_num[0] = changed_count;
                    m_running_info.input_active_count_seg[0] = changed_count;
                }
                LOG("[E4-R1-FRONTIER] epoch=%u round=%llu changed_events=%u bitmap_scanned_vertices=0 rebuilt_partitions=0\n",
                    m_insertion_epoch,
                    static_cast<unsigned long long>(m_insertion_convergence_round + 1),
                    changed_count);
            }

            index_t FindSegmentForVertexHost(index_t vertex) const {
                index_t lo = 0;
                index_t hi = FLAGS_SEGMENT;
                while (lo < hi) {
                    const index_t mid = lo + (hi - lo) / 2;
                    if (vertex < m_groute_context->seg_enode[mid]) {
                        hi = mid;
                    } else {
                        lo = mid + 1;
                    }
                }
                return lo;
            }


            void count() {
                // printf("------------PostComputationBW-----------\n");
                int dev_id = 0;
                const groute::Stream &stream_seg = m_groute_context->CreateStream(dev_id);
                GraphDatum &graph_datum = *m_graph_datum;
                AppImplDeviceObject &app_inst = *m_app_inst;
                m_running_info.current_round = m_graph_datum->m_current_round.get_val_D2H();

                // Stopwatch sw_unique(true);

                index_t seg_snode,seg_enode;
                index_t stream_id;
                uint64_t act = 0;
                // sw_rebuild.stop();
                // m_running_info.time_overhead_rebuild_worklist += sw_rebuild.ms();
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    index_t active_count = graph_datum.m_wl_array_in_seg[seg_idx].GetCount(stream[stream_id]);
                    graph_datum.seg_active_num[seg_idx] = active_count;

                    m_running_info.input_active_count_seg[seg_idx] = active_count;

                    uint32_t work_size = active_count;
                    dim3 grid_dims, block_dims;
                    // act += work_size;

                }
                // printf("static num nodes %d\n",act);
                // sw_unique.stop();
                // m_running_info.time_overhead_wl_unique += sw_unique.ms();

          }

           void CombineTask(AlgoVariant *algo_variant) {
                // LOG("------------CombineTask-----------\n");
                int dev_id = 0;
                const groute::Stream &stream_seg = m_groute_context->CreateStream(dev_id);
                GraphDatum &graph_datum = *m_graph_datum;
                AppImplDeviceObject &app_inst = *m_app_inst;
                graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT].ResetAsync(stream_seg.cuda_stream);
                graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT + 1].ResetAsync(stream_seg.cuda_stream);
                stream_seg.Sync();
                Stopwatch sw_unique(true);
                index_t seg_snode,seg_enode;
                index_t stream_id;
                index_t task = 1;// zero:0 exp_filter:1 exp_compaction:2
                bool zc = false;
                bool compaction = false;
                Stopwatch sw_rebuild(true);
                index_t seg_idx_ct = 0;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];
                    if(algo_variant[seg_idx] == AlgoVariant::Zero_Copy){
                        task = 0;
                        zc = true;
                        while(algo_variant[seg_idx + 1] == AlgoVariant::Zero_Copy && seg_idx < FLAGS_SEGMENT - 1){
                            seg_idx++;
                        }
                    }
                    if(algo_variant[seg_idx] == AlgoVariant::Exp_Compaction){
                        task = 2;
                        compaction = true;
                        // LOG("Compaction\n");
                        while(algo_variant[seg_idx + 1] == AlgoVariant::Exp_Compaction && seg_idx < FLAGS_SEGMENT - 1){
                            seg_idx++;
                        }
                    }
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                    if(task == 0){
                        task = 1;
                        // LOG("zc end %d start %d\n",seg_enode,seg_snode);
                        RebuildArrayWorklist_zero(app_inst,
                            graph_datum,
                            stream[stream_id],seg_snode,seg_enode - seg_snode,FLAGS_SEGMENT);
                    }
                    else if(task == 1)
                    {
                        algo_variant[seg_idx_ct] = AlgoVariant::Exp_Filter;
                        m_groute_context->segment_id_ct[seg_idx_ct++] = seg_idx;
                        // LOG("ef end %d start %d\n",seg_enode,seg_snode);
                        RebuildArrayWorklist(app_inst,
                            graph_datum,
                            stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                    }
                    else if(task == 2){
                        task = 1;
                        // LOG("ec end %d start %d\n",seg_enode,seg_snode);
                        RebuildArrayWorklist_compaction(app_inst,
                            graph_datum,
                            stream[stream_id],seg_snode,seg_enode - seg_snode,FLAGS_SEGMENT + 1);
                    }
                }
                if(zc){
                    m_groute_context->segment_id_ct[seg_idx_ct] = seg_idx_ct;
                    algo_variant[seg_idx_ct++] = AlgoVariant::Zero_Copy;
                }
                if(compaction){
                    m_groute_context->segment_id_ct[seg_idx_ct] = seg_idx_ct;
                    algo_variant[seg_idx_ct++] = AlgoVariant::Exp_Compaction;
                }

                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                m_groute_context->segment_ct = seg_idx_ct;
                // printf("seg_idx_ct %d\n======",seg_idx_ct);
                sw_rebuild.stop();
                m_running_info.time_overhead_rebuild_worklist += sw_rebuild.ms();
                for(index_t seg_idx = 0; seg_idx < seg_idx_ct ; seg_idx++){
                    uint32_t seg_idx_new = m_groute_context->segment_id_ct[seg_idx];
                    // printf("seg_idx_new %d",seg_idx_new);
                    stream_id = seg_idx % FLAGS_n_stream;
                    index_t active_count = graph_datum.m_wl_array_in_seg[seg_idx_new].GetCount(stream[stream_id]);
                    // printf(": active %d\n",active_count);
                    uint32_t work_size = active_count;
                    dim3 grid_dims, block_dims;

                    if(FLAGS_priority_a == 1){
                        // printf("FLAGS_priority_a ");
                            Stopwatch sw_priority(true);
                            if(algo_variant[seg_idx_new] == AlgoVariant::Zero_Copy){
                                graph_datum.seg_res_num[seg_idx_new] = 1;
                                continue;
                            }
                            if(algo_variant[seg_idx_new] == AlgoVariant::Exp_Compaction){
                                graph_datum.seg_res_num[seg_idx_new] = 0;
                                continue;
                            }
                            graph_datum.m_seg_value.set_val_H2DAsync(0, stream[stream_id].cuda_stream);
                            KernelSizing(grid_dims, block_dims, work_size);
                            kernel::SumResQueue << < grid_dims, block_dims, 0, stream[stream_id].cuda_stream >> >
                                (app_inst,
                                    groute::dev::WorkSourceArray<index_t>(
                                    graph_datum.m_wl_array_in_seg[seg_idx_new].GetDeviceDataPtr(),
                                    work_size),
                                graph_datum.GetValueDeviceObject(),
                                graph_datum.GetBufferDeviceObject(),
                                graph_datum.m_seg_value.dev_ptr);

                            stream[stream_id].Sync();
                            graph_datum.seg_res_num[seg_idx_new] = graph_datum.m_seg_value.get_val_D2H();
                            sw_priority.stop();
                            m_running_info.time_overhead_sample += sw_priority.ms();
                    }

                }
                graph_datum.Compaction_num = 0;
                sw_unique.stop();
                m_running_info.time_overhead_wl_unique += sw_unique.ms();

          }

          void Compaction() {
                int dev_id = 0;
                const groute::Stream &stream_seg = m_groute_context->CreateStream(dev_id);
                GraphDatum &graph_datum = *m_graph_datum;
                AppImplDeviceObject &app_inst = *m_app_inst;
                // auto csr_graph = m_csr_dev_graph_allocator->DeviceObject();
                auto vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                // auto &csr_graph_host = m_csr_dev_graph_allocator->HostObject();
                auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                thrust::device_ptr<uint32_t> ptr_labeling(graph_datum.activeNodesLabeling.dev_ptr);
                thrust::device_ptr<uint32_t> ptr_labeling_prefixsum(graph_datum.prefixLabeling.dev_ptr);

                graph_datum.subgraphnodes = thrust::reduce(ptr_labeling, ptr_labeling + graph_datum.nnodes);

                thrust::exclusive_scan(ptr_labeling, ptr_labeling + graph_datum.nnodes, ptr_labeling_prefixsum);

                kernel::makeQueue<<<graph_datum.nnodes/512+1, 512>>>(vcsr_graph.subgraph_activenode, graph_datum.activeNodesLabeling.dev_ptr, graph_datum.prefixLabeling.dev_ptr, graph_datum.nnodes);

                GROUTE_CUDA_CHECK(cudaMemcpy(vcsr_graph_host.subgraph_activenode, vcsr_graph.subgraph_activenode, graph_datum.subgraphnodes*sizeof(uint32_t), cudaMemcpyDeviceToHost));

                thrust::device_ptr<uint32_t> ptr_degrees(graph_datum.activeNodesDegree.dev_ptr);
                thrust::device_ptr<uint32_t> ptr_degrees_prefixsum(graph_datum.prefixSumDegrees.dev_ptr);

                thrust::exclusive_scan(ptr_degrees, ptr_degrees + graph_datum.nnodes, ptr_degrees_prefixsum);

                kernel::makeActiveNodesPointer<<<graph_datum.nnodes/512+1, 512>>>(vcsr_graph.subgraph_rowstart, graph_datum.activeNodesLabeling.dev_ptr, graph_datum.prefixLabeling.dev_ptr, graph_datum.prefixSumDegrees.dev_ptr, graph_datum.nnodes);

                GROUTE_CUDA_CHECK(cudaMemcpy(vcsr_graph_host.subgraph_rowstart, vcsr_graph.subgraph_rowstart, graph_datum.subgraphnodes*sizeof(uint32_t), cudaMemcpyDeviceToHost));

                uint32_t numActiveEdges = 0;
                uint32_t endid = vcsr_graph_host.subgraph_activenode[graph_datum.subgraphnodes-1];
                // uint32_t outDegree = vcsr_graph_host.end_edge(endid) - vcsr_graph_host.begin_edge(endid);
                uint64_t outDegree = vcsr_graph_host.sync_vertices_[endid].index;
                if(graph_datum.subgraphnodes > 0)
                    numActiveEdges = vcsr_graph_host.subgraph_rowstart[graph_datum.subgraphnodes-1] + outDegree;

                graph_datum.subgraphedges = numActiveEdges;
                uint32_t last = numActiveEdges;

                GROUTE_CUDA_CHECK(cudaMemcpy(vcsr_graph.subgraph_rowstart + graph_datum.subgraphnodes, &last, sizeof(uint32_t), cudaMemcpyHostToDevice));

                GROUTE_CUDA_CHECK(cudaMemcpy(vcsr_graph_host.subgraph_rowstart, vcsr_graph.subgraph_rowstart, (graph_datum.subgraphnodes + 1)*sizeof(uint32_t), cudaMemcpyDeviceToHost));

                uint32_t numThreads = 32;

                if(graph_datum.subgraphnodes < 5000)
                    numThreads = 1;
                std::thread runThreads[numThreads];
          }

      };


  }
}

#endif //HYBRID_FRAMEWORK_H
