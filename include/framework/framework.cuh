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
#include <thrust/sort.h>
#include <cub/cub.cuh>
#include <framework/common.h>
#include <framework/variants/api.cuh>
#include <framework/graph_datum.cuh>
#include <framework/variants/common.cuh>
#include <framework/variants/driver.cuh>
#include <framework/hybrid_policy.h>
#include <framework/dynamic_reverse_index.h>
#include <framework/topology_replay.h>
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
DECLARE_bool(topology_replay_audit);
DECLARE_int32(sssp_cpu_partition_capacity);

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
                                             unsigned int *changed_count) {
            static_assert(sizeof(TValue) == sizeof(unsigned int),
                          "GPU affected repair requires 32-bit values");
            const uint32_t tid = TID_1D;
            const uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < affected_count; i += nthreads) {
                const index_t dst = affected_vertices[i];
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
                    if (candidate_wide < static_cast<uint64_t>(best)) {
                        best = static_cast<TValue>(candidate_wide);
                        best_parent = src;
                    }
                }
                const TValue old_value = static_cast<TValue>(atomicMin(
                    reinterpret_cast<unsigned int *>(&node_value[dst]),
                    static_cast<unsigned int>(best)));
                if (best < old_value) {
                    atomicExch(reinterpret_cast<unsigned int *>(&node_buffer[dst]),
                               static_cast<unsigned int>(best));
                    atomicExch(reinterpret_cast<unsigned int *>(&node_parent[dst]),
                               static_cast<unsigned int>(best_parent));
                    atomicAdd(changed_count, 1u);
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
                                              uint32_t segment_count,
                                              uint32_t epoch,
                                              uint32_t *node_state_epoch,
                                              unsigned long long *owner_reject_count,
                                              TValue *boundary_values,
                                              index_t *boundary_parents,
                                              groute::dev::Queue<index_t> boundary_vertices) {
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
                if (segment_owners[lo] == static_cast<uint8_t>(PartitionOwner::CPU)) {
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
                    node_state_epoch[edge.v] = epoch;
                    out_active.set_bit_atomic(edge.v);
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

        struct InsertionRoundStats {
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
            // std::unique_ptr<groute::graphs::single::PMAGraphAllocator> m_vcsr_dev_graph_allocator_update;
            std::unique_ptr<groute::graphs::single::CSCGraphAllocator> m_csc_dev_graph_allocator;
            runtime::DynamicReverseIndex m_reverse_index;
            groute::Queue<index_t> m_device_affected_vertices;
            std::vector<index_t> m_affected_vertices;
            std::vector<uint64_t> m_gpu_repair_incoming_offsets;
            std::vector<index_t> m_gpu_repair_incoming_sources;
            uint64_t *m_device_gpu_repair_offsets = nullptr;
            index_t *m_device_gpu_repair_sources = nullptr;
            unsigned int *m_device_gpu_repair_changed = nullptr;
            size_t m_device_gpu_repair_offset_capacity = 0;
            size_t m_device_gpu_repair_source_capacity = 0;
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
            std::vector<index_t> m_cpu_owned_segments;
            std::vector<TValue> m_cpu_node_values;
            std::vector<TBuffer> m_cpu_node_buffers;
            std::vector<index_t> m_cpu_node_parents;
            std::deque<index_t> m_cpu_frontier;
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
            int type[1];
            int *type_device=nullptr;
            //partition_information
            unsigned int partitions_csc;
            unsigned int* partition_offset_csc;
            unsigned int max_partition_size_csc;

            unsigned int partitions_csr;
            unsigned int* partition_offset_csr;
            unsigned int max_partition_size_csr;
            std::vector<index_t> m_insertion_changed_vertices;
            std::vector<CpuRelaxProposal<TBuffer>> m_cpu_boundary_proposals;
            std::vector<CpuRelaxProposal<TBuffer>> m_cpu_compressed_proposals;
            std::vector<index_t> m_cpu_proposal_compress_keys;
            std::vector<size_t> m_cpu_proposal_compress_indices;
            std::vector<size_t> m_cpu_proposal_compress_touched_slots;
            groute::Queue<index_t> m_device_gpu_to_cpu_boundary_vertices;
            groute::Queue<index_t> m_device_insertion_changed_vertices;
            CpuRelaxProposal<TBuffer> *m_device_cpu_boundary_proposals = nullptr;
            unsigned long long *m_device_cpu_proposal_success_count = nullptr;
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
                if (FLAGS_sssp_cpu_partition_capacity < 0 ||
                    FLAGS_sssp_cpu_partition_capacity > FLAGS_SEGMENT) {
                    LOG("[DUAL-RUNTIME] protocol_error=invalid_cpu_capacity capacity=%d partitions=%d\n",
                        FLAGS_sssp_cpu_partition_capacity,
                        FLAGS_SEGMENT);
                    std::abort();
                }
                if (FLAGS_sssp_cpu_partition_capacity == 0) return;

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
        if (m_device_cpu_destination_flags != nullptr) {
            cudaFree(m_device_cpu_destination_flags);
            m_device_cpu_destination_flags = nullptr;
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

            void confirm_candidate_batch(){
                GraphDatum &graph_datum = *m_graph_datum;
                auto &app_inst = *m_app_inst;
                groute::Stream &stream_s = *m_stream;
                Stopwatch extrac(true);
                graph_datum.ensure_candidate_vertex();
                extrac.stop();
                LOG("candidate v time: %f ms (excluded)\n", extrac.ms());
                const auto &work_source = groute::dev::WorkSourceRange<index_t>(0, graph_datum.nnodes);
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                // const auto &hvcsr = m_vcsr_dev_graph_allocator->HostObject();
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, work_source.get_size());
                     Stopwatch search_rebuild(true);
                kernel::search_batch<< < grid_dims, block_dims, 0, stream_s.cuda_stream >> > (app_inst,
                vcsr_graph,
                work_source,
                graph_datum.num_of_cache_d,
                graph_datum.d_sum,
                graph_datum.d_id.Current());
                stream_s.Sync();
                search_rebuild.stop();
                LOG("search_rebuild v time: %f ms (excluded)\n", search_rebuild.ms());
                cudaDeviceSynchronize();
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
        m_vcsr_dev_graph_allocator = std::unique_ptr<groute::graphs::single::PMAGraphAllocator>(new groute::graphs::single::PMAGraphAllocator(vcsr_graph,seg_nedges_csr_max));

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
        }
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
                  if (round == 1000 ) {//FLAGS_max_iteration
                        convergence = true;
                        LOG("Max iterations reached\n");
                  }

                }
               sw_total.stop();
               m_running_info.time_total = sw_total.ms();
               LOG("Iterate all time: %f ms (excluded)\n", sw_total.ms());
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
                GROUTE_CUDA_CHECK(cudaHostRegister((void *)this->type, sizeof(int) * 2, cudaHostRegisterMapped));
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
                groute::graphs::host::PMAGraph &vcsr_graph  = m_vcsr_dev_graph_allocator->m_origin_graph;
                for(index_t i = local_begin.first; i < local_begin.first+load_update.m_batch_size[NumOfSnapShots].first; i++){
                    index_t src_add = load_update.added_edges_w[i].u;
                    index_t dst_add = load_update.added_edges_w[i].v;
                    this->added_edges_h[i].u = src_add;
                    this->added_edges_h[i].v = dst_add;
                    this->added_edges_h[i].w = (dst_add+src_add)%128 + 1;
                    if (AppImplDeviceObject::kSupportsGpuDeletionRepair) {
                        m_reverse_index.ApplyInsert(src_add, dst_add);
                    }
                    vcsr_graph.insert(src_add, dst_add, (src_add + dst_add)%128 + 1);
                }
            }

            void del_edge_pr(std::pair<index_t,index_t>& local_begin,index_t &NumOfSnapShots){
                Loader &load_update = *m_load_update;
                groute::graphs::host::PMAGraph &vcsr_graph  = m_vcsr_dev_graph_allocator->m_origin_graph;
                index_t size = load_update.m_batch_size[NumOfSnapShots].second;
                for(index_t i = local_begin.second; i < local_begin.second+ size; i++){
                    index_t src_del = load_update.deleted_edges_w[i].u;
                    index_t dst_del = load_update.deleted_edges_w[i].v;
                    vcsr_graph.del_edge(src_del, dst_del, (src_del + dst_del)%128+1);
                }
            }

            void del_edge(std::pair<index_t,index_t>& local_begin,index_t& NumOfSnapShots){
                LOG("----------Batch: %d---------\n",NumOfSnapShots);
                Loader &load_update = *m_load_update;
                groute::graphs::host::PMAGraph &vcsr_graph  = m_vcsr_dev_graph_allocator->m_origin_graph;
                PrepareTopologyReplayAudit(local_begin, NumOfSnapShots);
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
                auto &app_inst = *m_app_inst;
                Loader &load_update = *m_load_update;
                GraphDatum &graph_datum = *m_graph_datum;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                groute::Stream &stream_s = *m_stream;
                index_t size = load_update.m_batch_size[NumOfSnapShots].second;
                for(index_t i = local_begin.second; i < local_begin.second+size; i++){
                    index_t src_del = load_update.deleted_edges_w[i].u;
                    index_t dst_del = load_update.deleted_edges_w[i].v;
                    this->del_edges_h[i].u = src_del;
                    this->del_edges_h[i].v = dst_del;
                    this->del_edges_h[i].w = (src_del+dst_del)%128+1;
                }
                // LOG("DEBUG pr 1.3 \n");

                dim3 grid_dims, block_dims;
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

                KernelSizing(grid_dims, block_dims, size);
                // LOG("DEBUG pr 1.3.3 \n");
                // bool del = true;
                kernel::reset_pr_del_edges<<< grid_dims, block_dims, 0, stream_s.cuda_stream >>>(app_inst,vcsr_graph,
                this->del_edges_d,
                this->work_size_d);
                stream_s.Sync();
                // LOG("DEBUG pr 1.3.5 \n");

            }

            void read_add(std::pair<index_t,index_t> &local_begin,index_t &NumOfSnapShots){
                auto &app_inst = *m_app_inst;
                Loader &load_update = *m_load_update;
                groute::Stream &stream_s = *m_stream;
                GraphDatum &graph_datum = *m_graph_datum;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
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
                dim3 grid_dims, block_dims;
                uint32_t work_size[2];
                work_size[0] = local_begin.first;
                work_size[1] = size;
                m_insertion_seed_begin = work_size[0];
                m_insertion_seed_count = work_size[1];
                // LOG("add start %d \n",work_size[0]);
                // LOG("add size %d \n",work_size[1]);
                bool del =false;
                GROUTE_CUDA_CHECK(cudaMemcpy(this->work_size_d, &work_size[0], 2 * sizeof(uint32_t),cudaMemcpyHostToDevice));
                if (size == 0) {
                    return;
                }
                KernelSizing(grid_dims, block_dims, size);
                kernel::reset_pr_del_edges<<< grid_dims, block_dims, 0, stream_s.cuda_stream >>>(app_inst,vcsr_graph,this->added_edges_d,this->work_size_d);
                stream_s.Sync();
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

                GROUTE_CUDA_CHECK(cudaHostGetDevicePointer((void **)&this->type_device, (void *)this->type, 0));
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

                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();

                //update graph on the cpu
                read_del(local_begin,NumOfSnapShots);
                cudaDeviceSynchronize();
                read_add(local_begin,NumOfSnapShots);
                cudaDeviceSynchronize();

                add_edge_pr(local_begin,NumOfSnapShots);
                del_edge_pr(local_begin,NumOfSnapShots);
                local_begin.second += load_update.m_batch_size[NumOfSnapShots].second;
                local_begin.first += load_update.m_batch_size[NumOfSnapShots].first;

                m_vcsr_dev_graph_allocator->ReloadAllocator();
                type[0] = 1;
                float time_total = 0;
                GROUTE_CUDA_CHECK(cudaHostGetDevicePointer((void **)&this->type_device, (void *)this->type, 0));

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

            void del_topo(index_t &local_begin){
                Loader &load_update = *m_load_update;
                groute::graphs::host::PMAGraph &vcsr_graph  = m_vcsr_dev_graph_allocator->m_origin_graph;
                // index_t size = load_update.m_batch_size/(2*NumOfSnapShots);
                index_t size = load_update.m_del_size;
                for(index_t i = 0; i < size; i++){
                    index_t src_del = load_update.deleted_edges_w[i].u;
                    index_t dst_del = load_update.deleted_edges_w[i].v;
                    vcsr_graph.del_edge(src_del, dst_del, (src_del + dst_del)%128+1);
                }
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
                        0,
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
                        0,
                        sizeof(uint32_t) * graph_datum.nnodes));
                    m_insertion_epoch = 1;
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
                m_cpu_frontier.clear();
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
                m_insertion_convergence_round = 0;
                sw_epoch_prepare.stop();
                LOG("[DUAL-RUNTIME-BEGIN] batch=%u epoch=%u gpu_partitions=%d cpu_partitions=%u cpu_capacity=%u epoch_prepare_ms=%.3f\n",
                    batch,
                    m_insertion_epoch,
                    FLAGS_SEGMENT - cpu_capacity,
                    cpu_capacity,
                    cpu_capacity,
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
                GROUTE_CUDA_CHECK(cudaMemcpy(
                    &rejected_seeds,
                    m_device_seed_owner_reject_count,
                    sizeof(unsigned long long),
                    cudaMemcpyDeviceToHost));
                if (rejected_seeds != 0 || local_active != 0 ||
                    boundary_active != 0 || !m_cpu_frontier.empty()) {
                    LOG("[DUAL-RUNTIME] protocol_error=epoch_not_quiescent epoch=%u rejected=%llu local_active=%llu boundary=%u cpu_frontier=%zu\n",
                        m_insertion_epoch,
                        rejected_seeds,
                        static_cast<unsigned long long>(local_active),
                        boundary_active,
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

                Stopwatch sw_pma_insert(true);
                add_edge_pr(local_begin,NumOfSnapShots);
                sw_pma_insert.stop();
                local_begin.second += load_update.m_batch_size[NumOfSnapShots].second;
                local_begin.first += load_update.m_batch_size[NumOfSnapShots].first;

                Stopwatch sw_allocator_reload(true);
                m_vcsr_dev_graph_allocator->ReloadAllocator();
                sw_allocator_reload.stop();
                if (!m_vcsr_dev_graph_allocator->HostObject().topology_epoch().IsPublished()) {
                    LOG("[TOPOLOGY-EPOCH] protocol_error=traversal_before_publication batch=%u pending=%llu published=%llu\n",
                        NumOfSnapShots,
                        static_cast<unsigned long long>(
                            m_vcsr_dev_graph_allocator->HostObject().topology_epoch().PendingEpoch()),
                        static_cast<unsigned long long>(
                            m_vcsr_dev_graph_allocator->HostObject().topology_epoch().PublishedEpoch()));
                    std::abort();
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
                            FLAGS_SEGMENT,
                            m_insertion_epoch,
                            m_device_node_state_epoch,
                            m_device_seed_owner_reject_count,
                            m_device_gpu_to_cpu_boundary_values,
                            m_device_gpu_to_cpu_boundary_parents,
                            m_device_gpu_to_cpu_boundary_vertices.DeviceObject());
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
                sw_initial_rebuild.stop();
                // LOG("DEBUG2 \n");
                bool convergence = false;
                m_running_info.current_round = 0;
                Stopwatch sw_con(true);
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
                  const uint32_t boundary_active =
                      FLAGS_sssp_cpu_partition_capacity == 0
                          ? 0
                          : m_device_gpu_to_cpu_boundary_vertices.GetCount(*m_stream);
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
                LOG("[INSERTION-STAGE] batch=%u reset_ms=%.3f pma_insert_ms=%.3f allocator_reload_ms=%.3f initial_rebuild_ms=%.3f seed_ms=%.3f converge_ms=%.3f\n",
                    NumOfSnapShots,
                    sw_update_reset.ms(),
                    sw_pma_insert.ms(),
                    sw_allocator_reload.ms(),
                    sw_initial_rebuild.ms(),
                    sw_load.ms(),
                    sw_con.ms());
                LOG("total add time: %f ms (excluded)\n", add_time);
                // GatherCacheMiss();
                // GatherTransfer();
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
                    if (m_device_gpu_repair_offsets != nullptr) {
                        GROUTE_CUDA_CHECK(cudaFree(m_device_gpu_repair_offsets));
                    }
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_gpu_repair_offsets),
                        sizeof(uint64_t) * (affected_count + 1)));
                    m_device_gpu_repair_offset_capacity = affected_count;
                }
                if (source_count > m_device_gpu_repair_source_capacity) {
                    if (m_device_gpu_repair_sources != nullptr) {
                        GROUTE_CUDA_CHECK(cudaFree(m_device_gpu_repair_sources));
                    }
                    GROUTE_CUDA_CHECK(cudaMalloc(
                        reinterpret_cast<void **>(&m_device_gpu_repair_sources),
                        sizeof(index_t) * source_count));
                    m_device_gpu_repair_source_capacity = source_count;
                }
            }

            void RunGpuAffectedRepair(index_t batch) {
                if (m_affected_vertices.empty()) {
                    LOG("[B2-GPU-REPAIR][batch %u] affected=0\n", batch);
                    return;
                }

                Stopwatch sw_topology(true);
                m_reverse_index.MaterializeIncoming(
                    m_affected_vertices,
                    m_gpu_repair_incoming_offsets,
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
                unsigned int changed = 0;
                uint32_t iterations = 0;
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
                            m_device_gpu_repair_changed);
                    GROUTE_CUDA_CHECK(cudaMemcpy(
                        &changed,
                        m_device_gpu_repair_changed,
                        sizeof(unsigned int),
                        cudaMemcpyDeviceToHost));
                    ++iterations;
                    if (iterations > m_affected_vertices.size() + 1) {
                        LOG("[B2-GPU-REPAIR] protocol_error=no_convergence batch=%u iterations=%u affected=%llu\n",
                            batch,
                            iterations,
                            static_cast<unsigned long long>(m_affected_vertices.size()));
                        std::abort();
                    }
                } while (changed != 0);
                FinalizeGpuAffectedRepair<TValue, TBuffer><<<grid_dims, block_dims>>>(
                    m_device_affected_vertices.GetDeviceDataPtr(),
                    static_cast<uint32_t>(m_affected_vertices.size()),
                    graph_datum.GetValueDeviceObject(),
                    graph_datum.GetBufferDeviceObject(),
                    graph_datum.m_node_reset_datum);
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                sw_closure.stop();

                const uint64_t h2d_bytes =
                    sizeof(uint64_t) * m_gpu_repair_incoming_offsets.size() +
                    sizeof(index_t) * m_gpu_repair_incoming_sources.size();
                const uint64_t device_bytes =
                    sizeof(uint64_t) * (m_device_gpu_repair_offset_capacity + 1) +
                    sizeof(index_t) * m_device_gpu_repair_source_capacity +
                    sizeof(unsigned int);
                LOG("[B2-GPU-REPAIR][batch %u] affected=%llu incoming_edges=%llu topology_ms=%.3f allocation_ms=%.3f h2d_bytes=%llu h2d_ms=%.3f iterations=%u closure_ms=%.3f device_bytes=%llu\n",
                    batch,
                    static_cast<unsigned long long>(m_affected_vertices.size()),
                    static_cast<unsigned long long>(m_gpu_repair_incoming_sources.size()),
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
                    stream_s.Sync();
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

                const auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                const auto adjacency = host_pma.adjacency_view();
                m_topology_audit_sources = mutations.TouchedSources();
                std::unordered_map<index_t, std::vector<index_t>> touched_adjacency;
                touched_adjacency.reserve(m_topology_audit_sources.size());
                uint64_t graph_edge_count = 0;
                for (index_t source = 0; source < host_pma.nnodes; ++source) {
                    graph_edge_count += adjacency.Degree(source);
                }
                for (const index_t source : m_topology_audit_sources) {
                    touched_adjacency.emplace(
                        source, topology::MaterializeNeighbors(adjacency, source));
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

                const auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                const auto adjacency = host_pma.adjacency_view();
                uint64_t actual_edge_count = 0;
                for (index_t source = 0; source < host_pma.nnodes; ++source) {
                    actual_edge_count += adjacency.Degree(source);
                }

                uint64_t mismatched_sources = 0;
                index_t first_mismatch = std::numeric_limits<index_t>::max();
                topology::SourceTopologyDigest first_expected;
                topology::SourceTopologyDigest first_actual;
                for (const index_t source : m_topology_audit_sources) {
                    const auto expected = m_topology_audit_expected->Digest(source);
                    const auto actual = topology::DigestSource(adjacency, source);
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
                    FLAGS_sssp_cpu_partition_capacity == 0) return;

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
                    }
                }
            }

            void RunCpuOwnedClosureHost(
                    InsertionRoundStats &stats,
                    std::vector<CpuRelaxProposal<TBuffer>> &gpu_boundary) {
                Stopwatch sw_cpu_owner(true);
                GraphDatum &graph_datum = *m_graph_datum;
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                const auto adjacency = host_pma.adjacency_view();
                const TBuffer infinity = std::numeric_limits<TBuffer>::max();
                while (!m_cpu_frontier.empty()) {
                    const size_t wave_size = m_cpu_frontier.size();
                    ++stats.cpu_closure_rounds;
                    for (size_t wave_offset = 0; wave_offset < wave_size; ++wave_offset) {
                        const index_t src = m_cpu_frontier.front();
                        m_cpu_frontier.pop_front();
                        const TBuffer src_value = m_cpu_node_buffers[src];
                        const uint64_t degree = adjacency.Degree(src);
                        ++stats.cpu_expanded_vertices;
                        stats.cpu_edge_visits += degree;
                        for (uint64_t offset = 0; offset < degree; ++offset) {
                            const index_t dst = adjacency.EdgeAt(src, offset);
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
                InsertionRoundStats cpu_stats;
                StageGpuToCpuBoundary(cpu_stats);
                const bool cpu_closure_ran = !m_cpu_frontier.empty();
                std::vector<CpuRelaxProposal<TBuffer>> gpu_boundary;
                m_device_insertion_changed_vertices.ResetAsync(m_stream->cuda_stream);
                m_stream->Sync();
                for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; ++seg_idx) {
                    if (graph_datum.seg_active_num[seg_idx] == 0) {
                        continue;
                    }
                    active_sources += graph_datum.seg_active_num[seg_idx];
                    active_edge_span_upper_bound +=
                        m_groute_context->seg_nedge_csr[seg_idx];
                    active_partitions++;
                }
                index_t stream_id;
                using RoundClock = std::chrono::steady_clock;
                RoundClock::time_point gpu_start;
                RoundClock::time_point gpu_end;
                RoundClock::time_point cpu_start;
                RoundClock::time_point cpu_end;
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
                               ? m_device_gpu_to_cpu_boundary_parents : nullptr);
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

               PostComputationBW();
               sw_execution.stop();
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
               LOG("[DUAL-RUNTIME-ROUND] epoch=%u round=%llu gpu_kernels=%u gpu_vertices=%llu gpu_edge_span_upper_bound=%llu cpu_vertices=%llu cpu_edges=%llu cpu_closure_rounds=%llu cpu_local_relax=%llu gpu_to_cpu_items=%llu gpu_to_cpu_bytes=%llu cpu_to_gpu_items=%llu cpu_to_gpu_bytes=%llu cpu_to_gpu_success=%llu gpu_submit_ms=%.3f gpu_service_ms=%.3f cpu_service_ms=%.3f overlap_ms=%.3f cpu_wait_ms=%.3f gpu_wait_ms=%.3f concurrent=%d proposal_alloc_ms=%.3f proposal_compress_ms=%.3f proposal_h2d_ms=%.3f proposal_merge_ms=%.3f dirty_partitions=%u barriers=1 wall_ms=%.3f\n",
                   m_insertion_epoch,
                   static_cast<unsigned long long>(reported_round),
                   kernel_launches,
                   static_cast<unsigned long long>(active_sources),
                   static_cast<unsigned long long>(active_edge_span_upper_bound),
                   static_cast<unsigned long long>(cpu_stats.cpu_expanded_vertices),
                   static_cast<unsigned long long>(cpu_stats.cpu_edge_visits),
                   static_cast<unsigned long long>(cpu_stats.cpu_closure_rounds),
                   static_cast<unsigned long long>(cpu_stats.cpu_local_relax_success),
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
