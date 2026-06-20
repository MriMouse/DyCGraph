// ----------------------------------------------------------------
// SEP-Graph: Finding Shortest Execution Paths for Graph Processing under a Hybrid Framework on GPU
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE
// in the root directory of this source distribution.
// ----------------------------------------------------------------
#ifndef HYBRID_FRAMEWORK_H
#define HYBRID_FRAMEWORK_H

#include <functional>
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

DECLARE_double(edge_factor);
DECLARE_string(updatefile);
DECLARE_string(update_size);
DECLARE_bool(weight);
DECLARE_string(coop_mode);
DECLARE_string(coop_split_mode);
DECLARE_int32(coop_cpu_segment_limit);
DECLARE_int32(coop_max_cpu_sources);
DECLARE_string(coop_segment_policy);
DECLARE_int32(coop_cpu_min_degree);
DECLARE_bool(coop_cpu_dry_run);
DECLARE_bool(coop_compress_proposals);
DECLARE_int32(coop_home_min_degree);
DECLARE_int32(coop_home_max_sources);
DECLARE_string(coop_home_policy);
DECLARE_int32(coop_home_min_injected_sources);
DECLARE_int32(coop_home_min_injected_edges);
DECLARE_int32(coop_home_feedback_min_success_per_mille);
DECLARE_bool(coop_home_skip_gpu_sources);
DECLARE_bool(coop_home_diagnostic_launch);
DECLARE_bool(coop_overlap_probe);
DECLARE_int32(coop_overlap_probe_max_sources);
DECLARE_int32(coop_overlap_probe_edge_budget);
DECLARE_bool(coop_packet_dry_run);
DECLARE_bool(coop_packet_diagnostic_merge);
DECLARE_bool(coop_packet_production_merge);
DECLARE_bool(coop_packet_overlap_merge);
DECLARE_string(coop_packet_source_policy);
DECLARE_int32(coop_packet_max_sources);
DECLARE_int32(coop_packet_edge_budget);

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

        template<typename TValue>
        struct CpuSourceCommit {
            index_t src;
            TValue value;
        };

        template<typename TBuffer>
        __global__ void MergeCpuRelaxProposals(CpuRelaxProposal<TBuffer> *proposals,
                                               uint32_t proposal_count,
                                               TBuffer *node_buffer,
                                               TBuffer *node_parent,
                                               BitmapDeviceObject out_active,
                                               groute::dev::Queue<index_t> changed_vertices,
                                               const uint8_t *shadow_valid_flags,
                                               unsigned long long *success_count) {
            uint32_t tid = TID_1D;
            uint32_t nthreads = TOTAL_THREADS_1D;

            for (uint32_t i = tid; i < proposal_count; i += nthreads) {
                CpuRelaxProposal<TBuffer> proposal = proposals[i];
                TBuffer old_buffer = atomicMin(&node_buffer[proposal.dst], proposal.value);
                if (proposal.value < old_buffer) {
                    if (success_count != nullptr) {
                        atomicAdd(success_count, 1ULL);
                    }
                    TBuffer old_parent = node_parent[proposal.dst];
                    do {
                        old_parent = atomicCAS(&node_parent[proposal.dst], old_parent, proposal.parent);
                    } while (proposal.value == node_buffer[proposal.dst] &&
                             node_parent[proposal.dst] != proposal.parent);
                    out_active.set_bit_atomic(proposal.dst);
                    if (shadow_valid_flags != nullptr && shadow_valid_flags[proposal.dst]) {
                        changed_vertices.append(proposal.dst);
                    }
                }
            }
        }

        template<typename TValue>
        __global__ void MergeCpuSourceCommits(CpuSourceCommit<TValue> *commits,
                                              uint32_t commit_count,
                                              TValue *node_value) {
            uint32_t tid = TID_1D;
            uint32_t nthreads = TOTAL_THREADS_1D;

            for (uint32_t i = tid; i < commit_count; i += nthreads) {
                CpuSourceCommit<TValue> commit = commits[i];
                node_value[commit.src] = commit.value;
            }
        }

        __global__ void SetCoopShadowFlags(const index_t *vertices,
                                           uint32_t vertex_count,
                                           uint8_t *shadow_valid_flags,
                                           uint8_t value) {
            uint32_t tid = TID_1D;
            uint32_t nthreads = TOTAL_THREADS_1D;

            if (shadow_valid_flags == nullptr) {
                return;
            }
            for (uint32_t i = tid; i < vertex_count; i += nthreads) {
                shadow_valid_flags[vertices[i]] = value;
            }
        }

        __global__ void SetCoopShadowFlagRange(index_t begin_vertex,
                                               index_t end_vertex,
                                               uint8_t *shadow_valid_flags,
                                               uint8_t value) {
            uint32_t tid = TID_1D;
            uint32_t nthreads = TOTAL_THREADS_1D;

            if (shadow_valid_flags == nullptr) {
                return;
            }
            const index_t count = end_vertex - begin_vertex;
            for (index_t i = tid; i < count; i += nthreads) {
                shadow_valid_flags[begin_vertex + i] = value;
            }
        }

        __global__ void SetCoopHomeFlags(const index_t *vertices,
                                         uint32_t vertex_count,
                                         uint8_t *home_flags,
                                         uint8_t value) {
            uint32_t tid = TID_1D;
            uint32_t nthreads = TOTAL_THREADS_1D;

            if (home_flags == nullptr) {
                return;
            }
            for (uint32_t i = tid; i < vertex_count; i += nthreads) {
                home_flags[vertices[i]] = value;
            }
        }

        template<typename TValue, typename TBuffer>
        __global__ void PackCpuActiveSourceState(const index_t *active_vertices,
                                                 uint32_t active_count,
                                                 const TValue *node_value,
                                                 const TBuffer *node_buffer,
                                                 TValue *source_values,
                                                 TBuffer *source_buffers) {
            uint32_t tid = TID_1D;
            uint32_t nthreads = TOTAL_THREADS_1D;

            for (uint32_t i = tid; i < active_count; i += nthreads) {
                const index_t src = active_vertices[i];
                source_values[i] = node_value[src];
                source_buffers[i] = node_buffer[src];
            }
        }

        enum class CoopExecMode {
            OFF,
            HYBRID
        };

        enum class CoopSplitMode {
            HOST_SELECT,
            CPU_HOME
        };

        enum class CoopHome : uint8_t {
            GPU_HOME = 0,
            CPU_HOME = 1
        };

        enum class CoopSegmentOwner {
            GPU,
            CPU
        };

        struct CoopSourceCandidate {
            index_t src;
            index_t seg_idx;
            uint64_t degree;
            uint8_t cached;
            uint64_t score;
            uint8_t force_expand = 0;
        };

        __global__ void MarkCpuSourceOwnerEpoch(const CoopSourceCandidate *candidates,
                                                uint32_t candidate_count,
                                                uint32_t *owner_epoch,
                                                uint32_t epoch) {
            uint32_t tid = TID_1D;
            uint32_t nthreads = TOTAL_THREADS_1D;
            for (uint32_t i = tid; i < candidate_count; i += nthreads) {
                owner_epoch[candidates[i].src] = epoch;
            }
        }

        struct CoopOverlapProbeStats {
            uint64_t candidate_sources = 0;
            uint64_t selected_sources = 0;
            uint64_t cached_sources = 0;
            uint64_t non_cached_sources = 0;
            uint64_t edge_visits = 0;
            uint64_t edge_budget = 0;
            uint64_t host_pma_read_bytes = 0;
            uint64_t structural_proposals = 0;
            uint64_t dst_checksum = 0;
            double cpu_wall_ms = 0.0;
        };

        struct CoopPacketDryRunStats {
            uint64_t candidate_sources = 0;
            uint64_t selected_sources = 0;
            uint64_t source_state_snapshots = 0;
            uint64_t reachable_sources = 0;
            uint64_t active_sources = 0;
            uint64_t edge_visits = 0;
            uint64_t edge_budget = 0;
            uint64_t generated_proposals = 0;
            uint64_t compressed_proposals = 0;
            uint64_t compressed_unique_dst = 0;
            uint64_t estimated_success_before_gpu = 0;
            uint64_t estimated_success_after_gpu = 0;
            uint64_t pre_after_success_gap = 0;
            uint64_t dst_ge32_count = 0;
            uint64_t dst_ge32_sum = 0;
            uint64_t dst_ge128_count = 0;
            uint64_t dst_ge128_sum = 0;
            uint64_t dst_ge512_count = 0;
            uint64_t dst_ge512_sum = 0;
            uint64_t dst_ge1024_count = 0;
            uint64_t dst_ge1024_sum = 0;
            uint64_t expected_avoided_gpu_edges = 0;
            uint64_t cached_sources = 0;
            uint64_t non_cached_sources = 0;
            uint64_t host_pma_read_bytes = 0;
            uint64_t state_snapshot_bytes = 0;
            uint64_t dst_state_probe_bytes = 0;
            uint64_t pre_dst_state_probe_bytes = 0;
            uint64_t post_dst_state_probe_bytes = 0;
            uint64_t diagnostic_merge_success = 0;
            uint64_t diagnostic_merge_h2d_bytes = 0;
            uint64_t proposal_checksum = 0;
            double source_state_snapshot_ms = 0.0;
            double cpu_wall_ms = 0.0;
            double proposal_compress_ms = 0.0;
            double dst_state_probe_ms = 0.0;
            double pre_dst_state_probe_ms = 0.0;
            double post_dst_state_probe_ms = 0.0;
            double diagnostic_merge_h2d_ms = 0.0;
            double diagnostic_merge_kernel_ms = 0.0;
            double diagnostic_merge_wall_ms = 0.0;
        };

        struct CoopRoundStats {
            uint64_t active_vertices = 0;
            uint64_t gpu_frontier_vertices = 0;
            uint64_t cpu_cached_source_vertices = 0;
            uint64_t cpu_non_cached_source_vertices = 0;
            uint64_t cpu_cached_edges = 0;
            uint64_t cpu_non_cached_edges = 0;
            uint64_t cpu_host_pma_edge_visits = 0;
            uint32_t cpu_segments = 0;
            uint32_t gpu_segments = 0;
            uint64_t cpu_frontier_vertices = 0;
            uint64_t cpu_expanded_vertices = 0;
            uint64_t active_degree_sum = 0;
            uint64_t cpu_edge_visits = 0;
            uint64_t cpu_proposals = 0;
            uint64_t cpu_proposals_generated = 0;
            uint64_t cpu_proposals_survived = 0;
            uint64_t cpu_proposals_compressed = 0;
            uint64_t cpu_proposals_success = 0;
            uint64_t cpu_unique_dst = 0;
            uint64_t gpu_skipped_cpu_sources = 0;
            uint64_t state_d2h_bytes = 0;
            uint64_t d2h_frontier_bytes = 0;
            uint64_t h2d_proposal_bytes = 0;
            uint64_t shadow_hits = 0;
            uint64_t shadow_misses = 0;
            uint64_t shadow_dirty_vertices = 0;
            uint64_t shadow_invalidated_vertices = 0;
            uint64_t delta_state_d2h_bytes = 0;
            uint64_t state_request_h2d_bytes = 0;
            uint64_t dirty_queue_d2h_bytes = 0;
            double state_d2h_ms = 0.0;
            double d2h_frontier_ms = 0.0;
            double cpu_ms = 0.0;
            double h2d_proposal_ms = 0.0;
            double merge_ms = 0.0;
            double allocation_ms = 0.0;
            double proposal_compress_ms = 0.0;
            double delta_state_d2h_ms = 0.0;
            double state_request_h2d_ms = 0.0;
            double dirty_queue_d2h_ms = 0.0;
            double round_wall_ms = 0.0;
            double collect_stats_ms = 0.0;
            double reset_buffers_ms = 0.0;
            double source_select_ms = 0.0;
            double owner_mark_ms = 0.0;
            double changed_queue_reset_ms = 0.0;
            double cpu_generate_wall_ms = 0.0;
            double gpu_launch_submit_ms = 0.0;
            double gpu_sync_ms = 0.0;
            double gpu_skip_counter_d2h_ms = 0.0;
            double merge_wall_ms = 0.0;
            double shadow_refresh_wall_ms = 0.0;
            double shadow_apply_ms = 0.0;
            double post_bw_ms = 0.0;
            double post_bw_rebuild_worklist_ms = 0.0;
            double post_bw_active_count_ms = 0.0;
            double post_bw_queue_reset_ms = 0.0;
            double post_bw_other_ms = 0.0;
            uint32_t gpu_kernel_launches = 0;
            uint32_t active_gpu_segments = 0;
            uint64_t cpu_home_sources = 0;
            uint64_t gpu_home_sources = 0;
            uint64_t cpu_home_edges_est = 0;
            uint64_t cpu_home_active_sources = 0;
            uint64_t cpu_home_injected_sources = 0;
            uint64_t gpu_home_active_sources = 0;
            uint64_t cpu_local_edge_visits = 0;
            uint64_t cpu_local_relax_success = 0;
            uint64_t cpu_local_frontier_pushes = 0;
            uint64_t cpu_to_gpu_boundary_proposals = 0;
            uint64_t cpu_to_gpu_boundary_success = 0;
            uint64_t cpu_home_commit_count = 0;
            uint64_t gpu_relax_success = 0;
            uint64_t gpu_relax_cpu_home_success = 0;
            uint64_t gpu_relax_dst_degree_sum = 0;
            uint64_t gpu_relax_dst_high_degree_count = 0;
            uint64_t gpu_relax_dst_high_degree_sum = 0;
            uint64_t gpu_relax_dst_batch_touched_count = 0;
            uint64_t gpu_relax_unique_dst = 0;
            uint64_t gpu_relax_unique_dst_degree_sum = 0;
            uint64_t gpu_relax_unique_dst_ge32_count = 0;
            uint64_t gpu_relax_unique_dst_ge32_sum = 0;
            uint64_t gpu_relax_unique_dst_ge128_count = 0;
            uint64_t gpu_relax_unique_dst_ge128_sum = 0;
            uint64_t gpu_relax_unique_dst_ge512_count = 0;
            uint64_t gpu_relax_unique_dst_ge512_sum = 0;
            uint64_t gpu_relax_unique_dst_ge1024_count = 0;
            uint64_t gpu_relax_unique_dst_ge1024_sum = 0;
            uint64_t gpu_relax_unique_dst_batch_touched_count = 0;
            uint64_t gpu_relax_unique_dst_cpu_home_count = 0;
            uint64_t gpu_relax_dst_queue_items = 0;
            uint64_t gpu_relax_dst_queue_bytes = 0;
            double gpu_relax_dst_queue_d2h_ms = 0.0;
            uint64_t gpu_to_cpu_boundary_items = 0;
            uint64_t gpu_to_cpu_boundary_bytes = 0;
            uint64_t gpu_to_cpu_boundary_unique = 0;
            uint64_t full_frontier_d2h_bytes = 0;
            double gpu_to_cpu_boundary_d2h_ms = 0.0;
            double full_frontier_d2h_ms = 0.0;
        };


      template<typename TValue, typename TBuffer, typename TWeight, template<typename, typename, typename, typename ...> class TAppImpl, typename... UnusedData>
      class 	Engine {
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
            std::vector<index_t> m_coop_active_vertices;
            std::vector<TValue> m_coop_active_values;
            std::vector<TBuffer> m_coop_active_buffers;
            std::vector<index_t> m_coop_state_request_vertices;
            std::vector<uint32_t> m_coop_state_request_active_indices;
            std::vector<CoopSourceCandidate> m_coop_cpu_source_candidates;
            std::vector<TValue> m_coop_shadow_values;
            std::vector<TBuffer> m_coop_shadow_buffers;
            std::vector<uint8_t> m_coop_shadow_valid;
            std::vector<index_t> m_coop_changed_vertices;
            std::vector<CpuRelaxProposal<TBuffer>> m_coop_cpu_proposals;
            std::vector<CpuRelaxProposal<TBuffer>> m_coop_cpu_compressed_proposals;
            std::vector<CpuSourceCommit<TValue>> m_coop_source_commits;
            std::vector<index_t> m_coop_compress_keys;
            std::vector<size_t> m_coop_compress_indices;
            std::vector<size_t> m_coop_compress_touched_slots;
            std::vector<uint8_t> m_coop_home;
            std::vector<index_t> m_coop_batch_touched_sources;
            std::vector<index_t> m_coop_cpu_home_injected_sources;
            bool m_coop_cpu_home_batch_enabled = true;
            uint64_t m_coop_cpu_home_injected_edges_est = 0;
            bool m_coop_home_initialized = false;
            uint64_t m_coop_home_edges_est = 0;
            uint64_t m_coop_home_cpu_source_count = 0;
            groute::Queue<index_t> m_coop_device_gpu_to_cpu_boundary_vertices;
            groute::Queue<index_t> m_coop_device_gpu_relax_dst_vertices;
            groute::Queue<index_t> m_coop_device_changed_vertices;
            CpuRelaxProposal<TBuffer> *m_coop_device_proposals = nullptr;
            CpuSourceCommit<TValue> *m_coop_device_commits = nullptr;
            CoopSourceCandidate *m_coop_device_cpu_source_candidates = nullptr;
            unsigned long long *m_coop_device_proposal_success_count = nullptr;
            unsigned long long *m_coop_device_gpu_skipped_cpu_sources = nullptr;
            unsigned long long *m_coop_device_gpu_relax_success_count = nullptr;
            unsigned long long *m_coop_device_gpu_relax_cpu_home_success_count = nullptr;
            unsigned long long *m_coop_device_gpu_relax_dst_degree_sum = nullptr;
            unsigned long long *m_coop_device_gpu_relax_dst_high_degree_count = nullptr;
            unsigned long long *m_coop_device_gpu_relax_dst_high_degree_sum = nullptr;
            unsigned long long *m_coop_device_gpu_relax_dst_batch_touched_count = nullptr;
            uint32_t *m_coop_device_cpu_source_owner_epoch = nullptr;
            uint8_t *m_coop_device_cpu_home_flags = nullptr;
            uint8_t *m_coop_device_batch_touched_flags = nullptr;
            uint32_t m_coop_cpu_source_epoch = 1;
            TValue *m_coop_device_active_values = nullptr;
            TBuffer *m_coop_device_active_buffers = nullptr;
            index_t *m_coop_device_state_request_vertices = nullptr;
            uint8_t *m_coop_device_shadow_valid_flags = nullptr;
            size_t m_coop_device_proposal_capacity = 0;
            size_t m_coop_device_commit_capacity = 0;
            size_t m_coop_device_cpu_source_candidate_capacity = 0;
            size_t m_coop_device_active_state_capacity = 0;
            size_t m_coop_device_state_request_capacity = 0;
            uint64_t m_coop_attr_sequence = 0;
            // Loader<index_t,index_t,index_t> load_update;
            // WeightedDynT result_graph;

            CoopExecMode GetCoopMode() const {
                if (FLAGS_coop_mode == "off") {
                    return CoopExecMode::OFF;
                }
                if (FLAGS_coop_mode == "hybrid") {
                    return CoopExecMode::HYBRID;
                }
                LOG("[COOP-DECISION] mode=off reason=unknown_coop_mode_%s\n", FLAGS_coop_mode.c_str());
                return CoopExecMode::OFF;
            }

            CoopSplitMode GetCoopSplitMode() const {
                if (FLAGS_coop_split_mode == "cpu_home") {
                    return CoopSplitMode::CPU_HOME;
                }
                if (FLAGS_coop_split_mode != "host_select") {
                    LOG("[COOP-DECISION] unknown_split_mode=%s fallback=host_select\n",
                        FLAGS_coop_split_mode.c_str());
                }
                return CoopSplitMode::HOST_SELECT;
            }

            int GetCoopMaxCpuSources() const {
                if (FLAGS_coop_max_cpu_sources >= 0) {
                    return FLAGS_coop_max_cpu_sources;
                }
                return FLAGS_coop_cpu_segment_limit;
            }

            void CollectCoopRoundStats(CoopRoundStats &stats) {
                for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++) {
                    const index_t stream_id = seg_idx % FLAGS_n_stream;
                    const uint64_t active_count = m_graph_datum->m_wl_array_in_seg[seg_idx].GetCount(stream[stream_id]);
                    stats.active_vertices += active_count;
                }
            }

            std::vector<CoopSegmentOwner> ChooseCoopSegments(CoopRoundStats &stats) {
                std::vector<CoopSegmentOwner> owners(FLAGS_SEGMENT, CoopSegmentOwner::GPU);
                if (FLAGS_coop_cpu_dry_run || stats.active_vertices == 0 || FLAGS_coop_cpu_segment_limit <= 0) {
                    return owners;
                }

                struct Candidate {
                    index_t seg_idx;
                    uint64_t active_count;
                    uint64_t seg_edges;
                    uint64_t active_degree_sum;
                    uint64_t high_degree_count;
                    uint64_t high_degree_sum;
                    uint64_t score;
                };

                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                std::vector<index_t> segment_active_vertices;
                std::vector<Candidate> candidates;
                candidates.reserve(FLAGS_SEGMENT);
                for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++) {
                    const index_t stream_id = seg_idx % FLAGS_n_stream;
                    const uint64_t active_count = m_graph_datum->m_wl_array_in_seg[seg_idx].GetCount(stream[stream_id]);
                    if (active_count == 0) {
                        continue;
                    }
                    const uint64_t seg_edges = m_groute_context->seg_nedge_csr[seg_idx];
                    uint64_t active_degree_sum = 0;
                    uint64_t high_degree_count = 0;
                    uint64_t high_degree_sum = 0;
                    segment_active_vertices.resize(active_count);
                    GROUTE_CUDA_CHECK(cudaMemcpyAsync(segment_active_vertices.data(),
                                                      m_graph_datum->m_wl_array_in_seg[seg_idx].GetDeviceDataPtr(),
                                                      sizeof(index_t) * active_count,
                                                      cudaMemcpyDeviceToHost,
                                                      stream[stream_id].cuda_stream));
                    stream[stream_id].Sync();
                    for (uint64_t i = 0; i < active_count; i++) {
                        const index_t src = segment_active_vertices[i];
                        if (src >= host_pma.nnodes) {
                            continue;
                        }
                        const uint64_t degree = host_pma.sync_vertices_[src].degree;
                        active_degree_sum += degree;
                        if (degree >= static_cast<uint64_t>(std::max(FLAGS_coop_cpu_min_degree, 0))) {
                            high_degree_count++;
                            high_degree_sum += degree;
                        }
                    }
                    if (FLAGS_coop_cpu_min_degree > 0 && high_degree_count == 0) {
                        continue;
                    }
                    uint64_t score = active_count;
                    if (FLAGS_coop_segment_policy == "estimated_edges") {
                        score = FLAGS_coop_cpu_min_degree > 0 ? high_degree_sum : active_degree_sum;
                    }
                    candidates.push_back({seg_idx, active_count, seg_edges, active_degree_sum, high_degree_count, high_degree_sum, score});
                }

                if (FLAGS_coop_segment_policy == "active_frontier" ||
                    FLAGS_coop_segment_policy == "estimated_edges") {
                    std::stable_sort(candidates.begin(), candidates.end(),
                                     [](const Candidate &lhs, const Candidate &rhs) {
                                         if (lhs.score != rhs.score) {
                                             return lhs.score > rhs.score;
                                         }
                                         if (lhs.active_count != rhs.active_count) {
                                             return lhs.active_count > rhs.active_count;
                                         }
                                         return lhs.seg_idx < rhs.seg_idx;
                                     });
                } else if (FLAGS_coop_segment_policy != "first_active") {
                    LOG("[COOP-DECISION] unknown_segment_policy=%s fallback=first_active\n",
                        FLAGS_coop_segment_policy.c_str());
                }

                const int limit = std::min<int>(FLAGS_coop_cpu_segment_limit, candidates.size());
                for (int i = 0; i < limit; i++) {
                    owners[candidates[i].seg_idx] = CoopSegmentOwner::CPU;
                }
                return owners;
            }

            void ResetCoopRoundBuffers() {
                m_coop_active_vertices.clear();
                m_coop_state_request_vertices.clear();
                m_coop_state_request_active_indices.clear();
                m_coop_cpu_source_candidates.clear();
                m_coop_changed_vertices.clear();
                m_coop_cpu_proposals.clear();
                m_coop_cpu_compressed_proposals.clear();
                m_coop_source_commits.clear();
            }

            void EnsureCoopSourceOwnerStorage() {
                if (m_graph_datum == nullptr || m_coop_device_cpu_source_owner_epoch != nullptr) {
                    return;
                }
                const uint32_t nnodes = std::max<uint32_t>(m_graph_datum->nnodes, 1);
                GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_cpu_source_owner_epoch,
                                             sizeof(uint32_t) * nnodes));
                GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_cpu_source_owner_epoch,
                                             0,
                                             sizeof(uint32_t) * nnodes));
            }

            void EnsureCoopGpuRelaxCounterStorage() {
                if (m_coop_device_gpu_relax_success_count == nullptr) {
                    GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_gpu_relax_success_count,
                                                 sizeof(unsigned long long)));
                    GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_gpu_relax_success_count,
                                                 0,
                                                 sizeof(unsigned long long)));
                }
                if (m_coop_device_gpu_relax_cpu_home_success_count == nullptr) {
                    GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_gpu_relax_cpu_home_success_count,
                                                 sizeof(unsigned long long)));
                    GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_gpu_relax_cpu_home_success_count,
                                                 0,
                                                 sizeof(unsigned long long)));
                }
                if (m_coop_device_gpu_relax_dst_degree_sum == nullptr) {
                    GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_gpu_relax_dst_degree_sum,
                                                 sizeof(unsigned long long)));
                    GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_gpu_relax_dst_degree_sum,
                                                 0,
                                                 sizeof(unsigned long long)));
                }
                if (m_coop_device_gpu_relax_dst_high_degree_count == nullptr) {
                    GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_gpu_relax_dst_high_degree_count,
                                                 sizeof(unsigned long long)));
                    GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_gpu_relax_dst_high_degree_count,
                                                 0,
                                                 sizeof(unsigned long long)));
                }
                if (m_coop_device_gpu_relax_dst_high_degree_sum == nullptr) {
                    GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_gpu_relax_dst_high_degree_sum,
                                                 sizeof(unsigned long long)));
                    GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_gpu_relax_dst_high_degree_sum,
                                                 0,
                                                 sizeof(unsigned long long)));
                }
                if (m_coop_device_gpu_relax_dst_batch_touched_count == nullptr) {
                    GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_gpu_relax_dst_batch_touched_count,
                                                 sizeof(unsigned long long)));
                    GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_gpu_relax_dst_batch_touched_count,
                                                 0,
                                                 sizeof(unsigned long long)));
                }
            }

            void EnsureCoopHomeDeviceStorage() {
                if (m_graph_datum == nullptr || m_coop_device_cpu_home_flags != nullptr) {
                    return;
                }
                const uint32_t nnodes = std::max<uint32_t>(m_graph_datum->nnodes, 1);
                GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_cpu_home_flags,
                                             sizeof(uint8_t) * nnodes));
                GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_cpu_home_flags,
                                             0,
                                             sizeof(uint8_t) * nnodes));
            }

            void EnsureCoopBatchTouchedDeviceStorage() {
                if (m_graph_datum == nullptr || m_coop_device_batch_touched_flags != nullptr) {
                    return;
                }
                const uint32_t nnodes = std::max<uint32_t>(m_graph_datum->nnodes, 1);
                GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_batch_touched_flags,
                                             sizeof(uint8_t) * nnodes));
                GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_batch_touched_flags,
                                             0,
                                             sizeof(uint8_t) * nnodes));
            }

            void EnsureCoopStateRequestCapacityNoStats(size_t needed) {
                if (needed <= m_coop_device_state_request_capacity) {
                    return;
                }
                if (m_coop_device_state_request_vertices != nullptr) {
                    cudaFree(m_coop_device_state_request_vertices);
                    m_coop_device_state_request_vertices = nullptr;
                }
                GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_state_request_vertices,
                                             sizeof(index_t) * needed));
                m_coop_device_state_request_capacity = needed;
            }

            void SyncCpuHomeFlagsToDevice(const std::vector<index_t> &vertices,
                                          uint8_t value) {
                if (vertices.empty()) {
                    return;
                }
                EnsureCoopHomeDeviceStorage();
                EnsureCoopStateRequestCapacityNoStats(vertices.size());
                GROUTE_CUDA_CHECK(cudaMemcpy(m_coop_device_state_request_vertices,
                                             vertices.data(),
                                             sizeof(index_t) * vertices.size(),
                                             cudaMemcpyHostToDevice));
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, vertices.size());
                SetCoopHomeFlags<<<grid_dims, block_dims>>>(
                    m_coop_device_state_request_vertices,
                    vertices.size(),
                    m_coop_device_cpu_home_flags,
                    value);
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
            }

            void SyncBatchTouchedFlagsToDevice(const std::vector<index_t> &vertices) {
                EnsureCoopBatchTouchedDeviceStorage();
                if (m_coop_device_batch_touched_flags == nullptr) {
                    return;
                }
                const uint32_t nnodes = std::max<uint32_t>(m_graph_datum->nnodes, 1);
                GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_batch_touched_flags,
                                             0,
                                             sizeof(uint8_t) * nnodes));
                if (vertices.empty()) {
                    return;
                }
                EnsureCoopStateRequestCapacityNoStats(vertices.size());
                GROUTE_CUDA_CHECK(cudaMemcpy(m_coop_device_state_request_vertices,
                                             vertices.data(),
                                             sizeof(index_t) * vertices.size(),
                                             cudaMemcpyHostToDevice));
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, vertices.size());
                SetCoopHomeFlags<<<grid_dims, block_dims>>>(
                    m_coop_device_state_request_vertices,
                    vertices.size(),
                    m_coop_device_batch_touched_flags,
                    1);
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
            }

            void AdvanceCoopSourceEpoch() {
                if (m_coop_cpu_source_epoch == std::numeric_limits<uint32_t>::max()) {
                    EnsureCoopSourceOwnerStorage();
                    GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_cpu_source_owner_epoch,
                                                 0,
                                                 sizeof(uint32_t) * std::max<uint32_t>(m_graph_datum->nnodes, 1)));
                    m_coop_cpu_source_epoch = 1;
                } else {
                    m_coop_cpu_source_epoch++;
                }
            }

            void MarkCpuSourcesForGpuSkip(CoopRoundStats &stats) {
                EnsureCoopSourceOwnerStorage();
                AdvanceCoopSourceEpoch();
                if (m_coop_device_gpu_skipped_cpu_sources == nullptr) {
                    Stopwatch sw_alloc(true);
                    GROUTE_CUDA_CHECK(cudaMalloc(&m_coop_device_gpu_skipped_cpu_sources,
                                                 sizeof(unsigned long long)));
                    sw_alloc.stop();
                    stats.allocation_ms += sw_alloc.ms();
                }
                GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_gpu_skipped_cpu_sources,
                                             0,
                                             sizeof(unsigned long long)));
                if (m_coop_cpu_source_candidates.empty()) {
                    return;
                }
                EnsureCoopDeviceCapacity(&m_coop_device_cpu_source_candidates,
                                         &m_coop_device_cpu_source_candidate_capacity,
                                         m_coop_cpu_source_candidates.size(),
                                         stats);
                GROUTE_CUDA_CHECK(cudaMemcpy(m_coop_device_cpu_source_candidates,
                                             m_coop_cpu_source_candidates.data(),
                                             sizeof(CoopSourceCandidate) * m_coop_cpu_source_candidates.size(),
                                             cudaMemcpyHostToDevice));
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, m_coop_cpu_source_candidates.size());
                MarkCpuSourceOwnerEpoch<<<grid_dims, block_dims>>>(m_coop_device_cpu_source_candidates,
                                                                   m_coop_cpu_source_candidates.size(),
                                                                   m_coop_device_cpu_source_owner_epoch,
                                                                   m_coop_cpu_source_epoch);
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
            }

            void SelectCpuSourcesForRound(CoopRoundStats &stats) {
                const int max_cpu_sources = GetCoopMaxCpuSources();
                if (FLAGS_coop_cpu_dry_run || max_cpu_sources <= 0) {
                    return;
                }
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                m_coop_cpu_source_candidates.clear();

                std::vector<index_t> segment_active_vertices;
                for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++) {
                    const index_t stream_id = seg_idx % FLAGS_n_stream;
                    const uint32_t active_count = graph_datum.m_wl_array_in_seg[seg_idx].GetCount(stream[stream_id]);
                    if (active_count == 0) {
                        continue;
                    }
                    segment_active_vertices.resize(active_count);
                    Stopwatch sw_d2h(true);
                    GROUTE_CUDA_CHECK(cudaMemcpyAsync(segment_active_vertices.data(),
                                                      graph_datum.m_wl_array_in_seg[seg_idx].GetDeviceDataPtr(),
                                                      sizeof(index_t) * active_count,
                                                      cudaMemcpyDeviceToHost,
                                                      stream[stream_id].cuda_stream));
                    stream[stream_id].Sync();
                    sw_d2h.stop();
                    stats.d2h_frontier_ms += sw_d2h.ms();
                    stats.d2h_frontier_bytes += sizeof(index_t) * active_count;

                    for (uint32_t i = 0; i < active_count; i++) {
                        const index_t src = segment_active_vertices[i];
                        if (src >= host_pma.nnodes) {
                            continue;
                        }
                        const uint64_t degree = host_pma.sync_vertices_[src].degree;
                        if (degree == 0) {
                            continue;
                        }
                        if (FLAGS_coop_cpu_min_degree > 0 &&
                            degree < static_cast<uint64_t>(FLAGS_coop_cpu_min_degree)) {
                            continue;
                        }
                        const uint8_t cached = host_pma.vertices_[src].cache ? 1 : 0;
                        const uint64_t cache_penalty = cached ? 0 : (degree + 1);
                        const uint64_t score = degree + cache_penalty;
                        m_coop_cpu_source_candidates.push_back({src, seg_idx, degree, cached, score});
                    }
                }

                std::stable_sort(m_coop_cpu_source_candidates.begin(),
                                 m_coop_cpu_source_candidates.end(),
                                 [](const CoopSourceCandidate &lhs, const CoopSourceCandidate &rhs) {
                                     if (lhs.score != rhs.score) {
                                         return lhs.score > rhs.score;
                                     }
                                     if (lhs.degree != rhs.degree) {
                                         return lhs.degree > rhs.degree;
                                     }
                                     return lhs.src < rhs.src;
                                 });

                const size_t source_limit = max_cpu_sources > 0
                                                ? static_cast<size_t>(max_cpu_sources)
                                                : 0;
                if (source_limit == 0 || m_coop_cpu_source_candidates.empty()) {
                    m_coop_cpu_source_candidates.clear();
                    return;
                }
                if (m_coop_cpu_source_candidates.size() > source_limit) {
                    m_coop_cpu_source_candidates.resize(source_limit);
                }
                stats.cpu_frontier_vertices += m_coop_cpu_source_candidates.size();
                for (const auto &candidate : m_coop_cpu_source_candidates) {
                    stats.active_degree_sum += candidate.degree;
                    if (candidate.cached) {
                        stats.cpu_cached_source_vertices++;
                        stats.cpu_cached_edges += candidate.degree;
                    } else {
                        stats.cpu_non_cached_source_vertices++;
                        stats.cpu_non_cached_edges += candidate.degree;
                    }
                }
            }

            void EnsureCoopHomeStorage() {
                if (m_graph_datum == nullptr) {
                    return;
                }
                const size_t nnodes = m_graph_datum->nnodes;
                if (m_coop_home.size() != nnodes) {
                    m_coop_home.assign(nnodes, static_cast<uint8_t>(CoopHome::GPU_HOME));
                    m_coop_home_initialized = true;
                    m_coop_home_edges_est = 0;
                    m_coop_home_cpu_source_count = 0;
                } else if (!m_coop_home_initialized) {
                    std::fill(m_coop_home.begin(), m_coop_home.end(), static_cast<uint8_t>(CoopHome::GPU_HOME));
                    m_coop_home_initialized = true;
                    m_coop_home_edges_est = 0;
                    m_coop_home_cpu_source_count = 0;
                }
            }

            bool IsCpuHome(index_t src) const {
                return src < m_coop_home.size() &&
                       m_coop_home[src] == static_cast<uint8_t>(CoopHome::CPU_HOME);
            }

            bool TryPromoteCpuHome(index_t src,
                                   uint64_t degree,
                                   uint8_t cached) {
                if (src >= m_coop_home.size()) {
                    return false;
                }
                if (IsCpuHome(src)) {
                    return true;
                }
                if (FLAGS_coop_cpu_dry_run) {
                    return false;
                }
                if (FLAGS_coop_home_max_sources <= 0 ||
                    m_coop_home_cpu_source_count >= static_cast<uint64_t>(FLAGS_coop_home_max_sources)) {
                    return false;
                }
                if (FLAGS_coop_home_policy != "update_touched_high_degree") {
                    LOG("[COOP-HOME] unknown_home_policy=%s fallback=update_touched_high_degree\n",
                        FLAGS_coop_home_policy.c_str());
                }
                if (cached) {
                    return false;
                }
                if (degree < static_cast<uint64_t>(std::max(FLAGS_coop_home_min_degree, 0))) {
                    return false;
                }
                m_coop_home[src] = static_cast<uint8_t>(CoopHome::CPU_HOME);
                m_coop_home_cpu_source_count++;
                m_coop_home_edges_est += degree;
                return true;
            }

            void SelectCpuHomeSourcesForRound(CoopRoundStats &stats) {
                EnsureCoopHomeStorage();
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                m_coop_cpu_source_candidates.clear();
                std::unordered_set<index_t> selected_cpu_sources;

                if (!m_coop_cpu_home_batch_enabled) {
                    stats.full_frontier_d2h_ms = 0.0;
                    stats.full_frontier_d2h_bytes = 0;
                    stats.cpu_home_sources = m_coop_home_cpu_source_count;
                    stats.gpu_home_sources = m_coop_home.size() >= m_coop_home_cpu_source_count
                                                 ? m_coop_home.size() - m_coop_home_cpu_source_count
                                                 : 0;
                    stats.cpu_home_edges_est = m_coop_home_edges_est;
                    return;
                }

                if (!m_coop_cpu_home_injected_sources.empty()) {
                    uint64_t injected = 0;
                    for (const index_t src : m_coop_cpu_home_injected_sources) {
                        if (src >= host_pma.nnodes || !IsCpuHome(src)) {
                            continue;
                        }
                        if (!selected_cpu_sources.insert(src).second) {
                            continue;
                        }
                        const uint64_t degree = host_pma.sync_vertices_[src].degree;
                        if (degree == 0) {
                            continue;
                        }
                        const uint8_t cached = host_pma.vertices_[src].cache ? 1 : 0;
                        const uint64_t score = degree + (cached ? 0 : degree + 1);
                        m_coop_cpu_source_candidates.push_back({src, 0, degree, cached, score, 1});
                        injected++;
                        stats.cpu_home_injected_sources++;
                        stats.cpu_frontier_vertices++;
                        stats.active_degree_sum += degree;
                        if (cached) {
                            stats.cpu_cached_source_vertices++;
                            stats.cpu_cached_edges += degree;
                        } else {
                            stats.cpu_non_cached_source_vertices++;
                            stats.cpu_non_cached_edges += degree;
                        }
                    }
                    LOG("[COOP-HOME-INJECT] pending=%lu injected=%lu consumed=1\n",
                        static_cast<unsigned long>(m_coop_cpu_home_injected_sources.size()),
                        static_cast<unsigned long>(injected));
                    m_coop_cpu_home_injected_sources.clear();
                    m_coop_cpu_home_injected_edges_est = 0;
                }

                stats.full_frontier_d2h_ms = 0.0;
                stats.full_frontier_d2h_bytes = 0;
                stats.cpu_home_sources = m_coop_home_cpu_source_count;
                stats.gpu_home_sources = m_coop_home.size() >= m_coop_home_cpu_source_count
                                             ? m_coop_home.size() - m_coop_home_cpu_source_count
                                             : 0;
                stats.cpu_home_edges_est = m_coop_home_edges_est;
                stats.cpu_home_active_sources = m_coop_cpu_source_candidates.size();
            }

            void PrepareInjectedCpuHomeSourcesForInitialAdd(CoopRoundStats &stats) {
                if (m_coop_cpu_home_injected_sources.empty()) {
                    return;
                }
                EnsureCoopHomeStorage();
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                m_coop_cpu_source_candidates.clear();
                std::unordered_set<index_t> selected_cpu_sources;
                uint64_t prepared = 0;
                for (const index_t src : m_coop_cpu_home_injected_sources) {
                    if (src >= host_pma.nnodes || !IsCpuHome(src)) {
                        continue;
                    }
                    if (!selected_cpu_sources.insert(src).second) {
                        continue;
                    }
                    const uint64_t degree = host_pma.sync_vertices_[src].degree;
                    if (degree == 0) {
                        continue;
                    }
                    const uint8_t cached = host_pma.vertices_[src].cache ? 1 : 0;
                    const uint64_t score = degree + (cached ? 0 : degree + 1);
                    m_coop_cpu_source_candidates.push_back({src, 0, degree, cached, score, 1});
                    prepared++;
                }
                if (prepared == 0) {
                    return;
                }
                SyncCpuHomeFlagsToDevice(m_coop_cpu_home_injected_sources, static_cast<uint8_t>(CoopHome::CPU_HOME));
                if (FLAGS_coop_home_skip_gpu_sources) {
                    MarkCpuSourcesForGpuSkip(stats);
                }
                LOG("[COOP-HOME-INIT-SKIP] pending=%lu prepared=%lu owner_epoch=%u\n",
                    static_cast<unsigned long>(m_coop_cpu_home_injected_sources.size()),
                    static_cast<unsigned long>(prepared),
                    m_coop_cpu_source_epoch);
            }

            void DrainCpuHomeBoundaryQueue(CoopRoundStats &stats) {
                if (!m_coop_cpu_home_batch_enabled) {
                    return;
                }
                if (m_coop_device_gpu_to_cpu_boundary_vertices.GetCount(*m_stream) == 0) {
                    stats.gpu_to_cpu_boundary_bytes = 0;
                    stats.gpu_to_cpu_boundary_items = 0;
                    stats.gpu_to_cpu_boundary_unique = 0;
                    return;
                }

                const uint32_t boundary_count = m_coop_device_gpu_to_cpu_boundary_vertices.GetCount(*m_stream);
                if (boundary_count == 0) {
                    return;
                }

                std::vector<index_t> boundary_vertices(boundary_count);
                Stopwatch sw_d2h(true);
                GROUTE_CUDA_CHECK(cudaMemcpy(boundary_vertices.data(),
                                             m_coop_device_gpu_to_cpu_boundary_vertices.GetDeviceDataPtr(),
                                             sizeof(index_t) * boundary_count,
                                             cudaMemcpyDeviceToHost));
                sw_d2h.stop();
                stats.gpu_to_cpu_boundary_d2h_ms += sw_d2h.ms();
                stats.gpu_to_cpu_boundary_bytes += sizeof(index_t) * boundary_count;
                stats.gpu_to_cpu_boundary_items += boundary_count;

                std::sort(boundary_vertices.begin(), boundary_vertices.end());
                boundary_vertices.erase(std::unique(boundary_vertices.begin(), boundary_vertices.end()),
                                        boundary_vertices.end());
                stats.gpu_to_cpu_boundary_unique += boundary_vertices.size();

                if (!boundary_vertices.empty()) {
                    m_coop_cpu_home_injected_sources.insert(m_coop_cpu_home_injected_sources.end(),
                                                            boundary_vertices.begin(),
                                                            boundary_vertices.end());
                    std::sort(m_coop_cpu_home_injected_sources.begin(),
                              m_coop_cpu_home_injected_sources.end());
                    m_coop_cpu_home_injected_sources.erase(
                        std::unique(m_coop_cpu_home_injected_sources.begin(),
                                    m_coop_cpu_home_injected_sources.end()),
                        m_coop_cpu_home_injected_sources.end());
                }
            }

            void CollectGpuRelaxDstUniqueStats(CoopRoundStats &stats) {
                const uint32_t dst_count = m_coop_device_gpu_relax_dst_vertices.GetCount(*m_stream);
                if (dst_count == 0) {
                    return;
                }

                std::vector<index_t> dst_vertices(dst_count);
                Stopwatch sw_d2h(true);
                GROUTE_CUDA_CHECK(cudaMemcpy(dst_vertices.data(),
                                             m_coop_device_gpu_relax_dst_vertices.GetDeviceDataPtr(),
                                             sizeof(index_t) * dst_count,
                                             cudaMemcpyDeviceToHost));
                sw_d2h.stop();

                stats.gpu_relax_dst_queue_items += dst_count;
                stats.gpu_relax_dst_queue_bytes += sizeof(index_t) * dst_count;
                stats.gpu_relax_dst_queue_d2h_ms += sw_d2h.ms();

                std::sort(dst_vertices.begin(), dst_vertices.end());
                dst_vertices.erase(std::unique(dst_vertices.begin(), dst_vertices.end()),
                                   dst_vertices.end());

                const auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                for (const index_t dst : dst_vertices) {
                    if (dst >= host_pma.nnodes) {
                        continue;
                    }
                    const uint64_t degree = host_pma.sync_vertices_[dst].degree;
                    stats.gpu_relax_unique_dst++;
                    stats.gpu_relax_unique_dst_degree_sum += degree;
                    if (degree >= 32) {
                        stats.gpu_relax_unique_dst_ge32_count++;
                        stats.gpu_relax_unique_dst_ge32_sum += degree;
                    }
                    if (degree >= 128) {
                        stats.gpu_relax_unique_dst_ge128_count++;
                        stats.gpu_relax_unique_dst_ge128_sum += degree;
                    }
                    if (degree >= 512) {
                        stats.gpu_relax_unique_dst_ge512_count++;
                        stats.gpu_relax_unique_dst_ge512_sum += degree;
                    }
                    if (degree >= 1024) {
                        stats.gpu_relax_unique_dst_ge1024_count++;
                        stats.gpu_relax_unique_dst_ge1024_sum += degree;
                    }
                    if (dst < m_coop_home.size() &&
                        m_coop_home[dst] == static_cast<uint8_t>(CoopHome::CPU_HOME)) {
                        stats.gpu_relax_unique_dst_cpu_home_count++;
                    }
                    if (std::binary_search(m_coop_batch_touched_sources.begin(),
                                           m_coop_batch_touched_sources.end(),
                                           dst)) {
                        stats.gpu_relax_unique_dst_batch_touched_count++;
                    }
                }
            }

            void PromoteBatchTouchedCpuHomeSources(CoopRoundStats *stats = nullptr) {
                m_coop_cpu_home_injected_edges_est = 0;
                if (m_coop_batch_touched_sources.empty()) {
                    SyncBatchTouchedFlagsToDevice(m_coop_batch_touched_sources);
                    return;
                }
                EnsureCoopHomeStorage();
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                std::sort(m_coop_batch_touched_sources.begin(), m_coop_batch_touched_sources.end());
                m_coop_batch_touched_sources.erase(
                    std::unique(m_coop_batch_touched_sources.begin(), m_coop_batch_touched_sources.end()),
                    m_coop_batch_touched_sources.end());
                SyncBatchTouchedFlagsToDevice(m_coop_batch_touched_sources);

                uint64_t promoted = 0;
                uint64_t considered = 0;
                m_coop_cpu_home_injected_sources.clear();
                for (const index_t src : m_coop_batch_touched_sources) {
                    if (src >= host_pma.nnodes) {
                        continue;
                    }
                    considered++;
                    const uint64_t degree = host_pma.sync_vertices_[src].degree;
                    const uint8_t cached = host_pma.vertices_[src].cache ? 1 : 0;
                    const bool was_cpu_home = IsCpuHome(src);
                    if (TryPromoteCpuHome(src, degree, cached) && !was_cpu_home) {
                        promoted++;
                        m_coop_cpu_home_injected_sources.push_back(src);
                        m_coop_cpu_home_injected_edges_est += degree;
                    }
                }
                std::sort(m_coop_cpu_home_injected_sources.begin(),
                          m_coop_cpu_home_injected_sources.end());
                m_coop_cpu_home_injected_sources.erase(
                    std::unique(m_coop_cpu_home_injected_sources.begin(),
                                m_coop_cpu_home_injected_sources.end()),
                    m_coop_cpu_home_injected_sources.end());
                SyncCpuHomeFlagsToDevice(m_coop_cpu_home_injected_sources, static_cast<uint8_t>(CoopHome::CPU_HOME));
                if (stats != nullptr) {
                    stats->cpu_home_sources = m_coop_home_cpu_source_count;
                    stats->gpu_home_sources = m_coop_home.size() >= m_coop_home_cpu_source_count
                                                 ? m_coop_home.size() - m_coop_home_cpu_source_count
                                                 : 0;
                    stats->cpu_home_edges_est = m_coop_home_edges_est;
                }
                LOG("[COOP-HOME] batch_touched_sources=%lu considered=%lu promoted=%lu cpu_home_sources=%lu cpu_home_edges_est=%lu policy=%s min_degree=%d max_sources=%d\n",
                    static_cast<unsigned long>(m_coop_batch_touched_sources.size()),
                    static_cast<unsigned long>(considered),
                    static_cast<unsigned long>(promoted),
                    static_cast<unsigned long>(m_coop_home_cpu_source_count),
                    static_cast<unsigned long>(m_coop_home_edges_est),
                    FLAGS_coop_home_policy.c_str(),
                    FLAGS_coop_home_min_degree,
                    FLAGS_coop_home_max_sources);
            }

            void ApplyCpuHomeAdmissionForBatch() {
                if (GetCoopMode() != CoopExecMode::HYBRID ||
                    GetCoopSplitMode() != CoopSplitMode::CPU_HOME) {
                    m_coop_cpu_home_batch_enabled = false;
                    m_coop_cpu_home_injected_sources.clear();
                    m_coop_cpu_home_injected_edges_est = 0;
                    return;
                }

                const uint64_t min_injected_sources =
                    static_cast<uint64_t>(std::max(FLAGS_coop_home_min_injected_sources, 0));
                const uint64_t min_injected_edges =
                    static_cast<uint64_t>(std::max(FLAGS_coop_home_min_injected_edges, 0));
                const uint64_t injected_sources = m_coop_cpu_home_injected_sources.size();
                const uint64_t injected_edges = m_coop_cpu_home_injected_edges_est;
                m_coop_cpu_home_batch_enabled =
                    injected_sources >= min_injected_sources &&
                    injected_edges >= min_injected_edges;

                LOG("[COOP-HOME-ADMISSION] enabled=%d reason=%s injected_sources=%lu injected_edges_est=%lu min_sources=%lu min_edges=%lu cpu_home_sources=%lu cpu_home_edges_est=%lu\n",
                    m_coop_cpu_home_batch_enabled ? 1 : 0,
                    m_coop_cpu_home_batch_enabled ? "cpu_home_admitted" : "cpu_home_disabled_low_work",
                    static_cast<unsigned long>(injected_sources),
                    static_cast<unsigned long>(injected_edges),
                    static_cast<unsigned long>(min_injected_sources),
                    static_cast<unsigned long>(min_injected_edges),
                    static_cast<unsigned long>(m_coop_home_cpu_source_count),
                    static_cast<unsigned long>(m_coop_home_edges_est));

                if (!m_coop_cpu_home_batch_enabled) {
                    m_coop_cpu_home_injected_sources.clear();
                    m_coop_cpu_home_injected_edges_est = 0;
                }
            }


            template<typename DevicePtr>
            void EnsureCoopDeviceCapacity(DevicePtr **device_buffer,
                                          size_t *capacity,
                                          size_t needed,
                                          CoopRoundStats &stats) {
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

            void EnsureCoopActiveStateCapacity(size_t needed, CoopRoundStats &stats) {
                if (needed <= m_coop_device_active_state_capacity) {
                    return;
                }

                Stopwatch sw_alloc(true);
                if (m_coop_device_active_values != nullptr) {
                    GROUTE_CUDA_CHECK(cudaFree(m_coop_device_active_values));
                }
                if (m_coop_device_active_buffers != nullptr) {
                    GROUTE_CUDA_CHECK(cudaFree(m_coop_device_active_buffers));
                }
                GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_active_values,
                                             sizeof(TValue) * needed));
                GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_active_buffers,
                                             sizeof(TBuffer) * needed));
                m_coop_device_active_state_capacity = needed;
                sw_alloc.stop();
                stats.allocation_ms += sw_alloc.ms();
            }

            void EnsureCoopStateRequestCapacity(size_t needed, CoopRoundStats &stats) {
                if (needed <= m_coop_device_state_request_capacity) {
                    return;
                }

                Stopwatch sw_alloc(true);
                if (m_coop_device_state_request_vertices != nullptr) {
                    GROUTE_CUDA_CHECK(cudaFree(m_coop_device_state_request_vertices));
                }
                GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_state_request_vertices,
                                             sizeof(index_t) * needed));
                m_coop_device_state_request_capacity = needed;
                sw_alloc.stop();
                stats.allocation_ms += sw_alloc.ms();
            }

            void EnsureCoopShadowStorage() {
                if (m_graph_datum == nullptr) {
                    return;
                }
                const size_t nnodes = m_graph_datum->nnodes;
                if (m_coop_shadow_valid.size() == nnodes) {
                    return;
                }
                m_coop_shadow_values.resize(nnodes);
                m_coop_shadow_buffers.resize(nnodes);
                m_coop_shadow_valid.assign(nnodes, 0);
            }

            void FetchCoopStateForVertices(const std::vector<index_t> &vertices,
                                           std::vector<TValue> &values,
                                           std::vector<TBuffer> &buffers,
                                           CoopRoundStats &stats,
                                           bool count_as_delta_sync) {
                if (vertices.empty()) {
                    return;
                }

                GraphDatum &graph_datum = *m_graph_datum;
                EnsureCoopActiveStateCapacity(vertices.size(), stats);
                EnsureCoopStateRequestCapacity(vertices.size(), stats);
                values.resize(vertices.size());
                buffers.resize(vertices.size());

                Stopwatch sw_h2d(true);
                GROUTE_CUDA_CHECK(cudaMemcpy(m_coop_device_state_request_vertices,
                                             vertices.data(),
                                             sizeof(index_t) * vertices.size(),
                                             cudaMemcpyHostToDevice));
                sw_h2d.stop();
                stats.state_request_h2d_ms += sw_h2d.ms();
                stats.state_request_h2d_bytes += sizeof(index_t) * vertices.size();

                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, vertices.size());
                Stopwatch sw_d2h(true);
                PackCpuActiveSourceState<TValue, TBuffer><<<grid_dims, block_dims>>>(
                    m_coop_device_state_request_vertices,
                    vertices.size(),
                    graph_datum.GetValueDeviceObject(),
                    graph_datum.GetBufferDeviceObject(),
                    m_coop_device_active_values,
                    m_coop_device_active_buffers);
                GROUTE_CUDA_CHECK(cudaMemcpy(values.data(),
                                             m_coop_device_active_values,
                                             sizeof(TValue) * vertices.size(),
                                             cudaMemcpyDeviceToHost));
                GROUTE_CUDA_CHECK(cudaMemcpy(buffers.data(),
                                             m_coop_device_active_buffers,
                                             sizeof(TBuffer) * vertices.size(),
                                             cudaMemcpyDeviceToHost));
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                sw_d2h.stop();

                const uint64_t state_bytes = (sizeof(TValue) + sizeof(TBuffer)) * vertices.size();
                if (count_as_delta_sync) {
                    stats.delta_state_d2h_ms += sw_d2h.ms();
                    stats.delta_state_d2h_bytes += state_bytes;
                } else {
                    stats.state_d2h_ms += sw_d2h.ms();
                    stats.state_d2h_bytes += state_bytes;
                }
            }

            void RefreshCoopShadowFromChangedQueue(CoopRoundStats &stats) {
                const uint32_t changed_count = m_coop_device_changed_vertices.GetCount(*m_stream);
                if (changed_count == 0) {
                    return;
                }

                m_coop_changed_vertices.resize(changed_count);
                Stopwatch sw_d2h(true);
                GROUTE_CUDA_CHECK(cudaMemcpy(m_coop_changed_vertices.data(),
                                             m_coop_device_changed_vertices.GetDeviceDataPtr(),
                                             sizeof(index_t) * changed_count,
                                             cudaMemcpyDeviceToHost));
                sw_d2h.stop();
                stats.dirty_queue_d2h_ms += sw_d2h.ms();
                stats.dirty_queue_d2h_bytes += sizeof(index_t) * changed_count;

                EnsureCoopShadowStorage();
                std::sort(m_coop_changed_vertices.begin(), m_coop_changed_vertices.end());
                m_coop_changed_vertices.erase(std::unique(m_coop_changed_vertices.begin(),
                                                          m_coop_changed_vertices.end()),
                                              m_coop_changed_vertices.end());
                stats.shadow_dirty_vertices += m_coop_changed_vertices.size();

                std::vector<TValue> values;
                std::vector<TBuffer> buffers;
                FetchCoopStateForVertices(m_coop_changed_vertices, values, buffers, stats, true);
                for (size_t i = 0; i < m_coop_changed_vertices.size(); i++) {
                    const index_t vertex = m_coop_changed_vertices[i];
                    if (vertex < m_coop_shadow_valid.size()) {
                        m_coop_shadow_values[vertex] = values[i];
                        m_coop_shadow_buffers[vertex] = buffers[i];
                        m_coop_shadow_valid[vertex] = 1;
                    }
                }
                m_coop_changed_vertices.clear();
            }

            void SetCoopShadowInterestForCpuSegments(const std::vector<CoopSegmentOwner> &owners) {
                if (m_coop_device_shadow_valid_flags == nullptr || m_graph_datum == nullptr) {
                    return;
                }

                GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_shadow_valid_flags,
                                             0,
                                             sizeof(uint8_t) * std::max<uint32_t>(m_graph_datum->nnodes, 1)));
                for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++) {
                    if (owners[seg_idx] != CoopSegmentOwner::CPU) {
                        continue;
                    }
                    const index_t seg_snode = m_groute_context->seg_snode[seg_idx];
                    const index_t seg_enode = m_groute_context->seg_enode[seg_idx];
                    if (seg_enode <= seg_snode) {
                        continue;
                    }
                    dim3 grid_dims, block_dims;
                    KernelSizing(grid_dims, block_dims, seg_enode - seg_snode);
                    SetCoopShadowFlagRange<<<grid_dims, block_dims>>>(
                        seg_snode,
                        seg_enode,
                        m_coop_device_shadow_valid_flags,
                        1);
                }
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
            }

            void ApplyCpuSourceCommitsToShadow(const std::vector<CpuSourceCommit<TValue>> &source_commits) {
                if (source_commits.empty()) {
                    return;
                }

                EnsureCoopShadowStorage();
                for (const auto &commit : source_commits) {
                    if (commit.src >= m_coop_shadow_valid.size() || !m_coop_shadow_valid[commit.src]) {
                        continue;
                    }
                    m_coop_shadow_values[commit.src] = commit.value;
                    m_coop_shadow_buffers[commit.src] = static_cast<TBuffer>(commit.value);
                }
            }

            template<typename Proposal>
            void CompressCpuRelaxProposals(std::vector<Proposal> &proposals,
                                           CoopRoundStats &stats) {
                if (proposals.empty()) {
                    return;
                }

                Stopwatch sw_compress(true);
                size_t table_size = 1;
                while (table_size < proposals.size() * 2) {
                    table_size <<= 1;
                }
                const index_t empty_key = std::numeric_limits<index_t>::max();
                if (m_coop_compress_keys.size() < table_size) {
                    m_coop_compress_keys.assign(table_size, empty_key);
                    m_coop_compress_indices.resize(table_size);
                    m_coop_compress_touched_slots.clear();
                }

                const size_t table_mask = table_size - 1;
                m_coop_cpu_compressed_proposals.clear();
                m_coop_cpu_compressed_proposals.reserve(proposals.size());
                m_coop_compress_touched_slots.clear();

                for (const auto &proposal : proposals) {
                    size_t slot = (static_cast<size_t>(proposal.dst) * 11400714819323198485ull) & table_mask;
                    while (true) {
                        const index_t key = m_coop_compress_keys[slot];
                        if (key == empty_key) {
                            m_coop_compress_keys[slot] = proposal.dst;
                            m_coop_compress_indices[slot] = m_coop_cpu_compressed_proposals.size();
                            m_coop_compress_touched_slots.push_back(slot);
                            m_coop_cpu_compressed_proposals.push_back(proposal);
                            break;
                        }
                        if (key == proposal.dst) {
                            Proposal &current = m_coop_cpu_compressed_proposals[m_coop_compress_indices[slot]];
                            if (proposal.value < current.value ||
                                (proposal.value == current.value && proposal.parent < current.parent)) {
                                current = proposal;
                            }
                            break;
                        }
                        slot = (slot + 1) & table_mask;
                    }
                }

                stats.cpu_unique_dst += m_coop_cpu_compressed_proposals.size();
                stats.cpu_proposals_compressed += m_coop_cpu_compressed_proposals.size();
                if (FLAGS_coop_compress_proposals) {
                    proposals.swap(m_coop_cpu_compressed_proposals);
                }
                for (const size_t slot : m_coop_compress_touched_slots) {
                    m_coop_compress_keys[slot] = empty_key;
                }
                sw_compress.stop();
                stats.proposal_compress_ms += sw_compress.ms();
            }

            template<typename Proposal>
            void GenerateCpuSSSPProposalsForSegment(index_t seg_idx,
                                                    std::vector<Proposal> &proposals,
                                                    std::vector<CpuSourceCommit<TValue>> &source_commits,
                                                    CoopRoundStats &stats) {
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                const uint32_t active_count = graph_datum.m_wl_array_in_seg[seg_idx].GetCount(stream[seg_idx % FLAGS_n_stream]);
                if (active_count == 0) {
                    return;
                }

                index_t stream_id = seg_idx % FLAGS_n_stream;
                Stopwatch sw_alloc(true);
                m_coop_active_vertices.resize(active_count);
                m_coop_active_values.resize(active_count);
                m_coop_active_buffers.resize(active_count);
                sw_alloc.stop();
                stats.allocation_ms += sw_alloc.ms();

                Stopwatch sw_d2h(true);
                GROUTE_CUDA_CHECK(cudaMemcpyAsync(m_coop_active_vertices.data(),
                                                  graph_datum.m_wl_array_in_seg[seg_idx].GetDeviceDataPtr(),
                                                  sizeof(index_t) * active_count,
                                                  cudaMemcpyDeviceToHost,
                                                  stream[stream_id].cuda_stream));
                stream[stream_id].Sync();
                sw_d2h.stop();
                stats.d2h_frontier_ms += sw_d2h.ms();
                stats.d2h_frontier_bytes += sizeof(index_t) * active_count;
                stats.cpu_frontier_vertices += active_count;

                EnsureCoopShadowStorage();
                m_coop_state_request_vertices.clear();
                m_coop_state_request_active_indices.clear();
                for (uint32_t active_idx = 0; active_idx < active_count; active_idx++) {
                    const index_t src = m_coop_active_vertices[active_idx];
                    if (src < m_coop_shadow_valid.size() && m_coop_shadow_valid[src]) {
                        const TValue shadow_value = m_coop_shadow_values[src];
                        const TBuffer shadow_buffer = m_coop_shadow_buffers[src];
                        if (shadow_buffer < shadow_value) {
                            m_coop_active_values[active_idx] = shadow_value;
                            m_coop_active_buffers[active_idx] = shadow_buffer;
                            stats.shadow_hits++;
                        } else {
                            m_coop_state_request_vertices.push_back(src);
                            m_coop_state_request_active_indices.push_back(active_idx);
                            stats.shadow_misses++;
                        }
                    } else {
                        m_coop_state_request_vertices.push_back(src);
                        m_coop_state_request_active_indices.push_back(active_idx);
                        stats.shadow_misses++;
                    }
                }

                if (!m_coop_state_request_vertices.empty()) {
                    std::vector<TValue> fetched_values;
                    std::vector<TBuffer> fetched_buffers;
                    FetchCoopStateForVertices(m_coop_state_request_vertices,
                                              fetched_values,
                                              fetched_buffers,
                                              stats,
                                              false);
                    for (size_t i = 0; i < m_coop_state_request_vertices.size(); i++) {
                        const index_t src = m_coop_state_request_vertices[i];
                        const uint32_t active_idx = m_coop_state_request_active_indices[i];
                        m_coop_active_values[active_idx] = fetched_values[i];
                        m_coop_active_buffers[active_idx] = fetched_buffers[i];
                        if (src < m_coop_shadow_valid.size()) {
                            m_coop_shadow_values[src] = fetched_values[i];
                            m_coop_shadow_buffers[src] = fetched_buffers[i];
                            m_coop_shadow_valid[src] = 1;
                        }
                    }
                    dim3 flag_grid_dims, flag_block_dims;
                    KernelSizing(flag_grid_dims, flag_block_dims, m_coop_state_request_vertices.size());
                    SetCoopShadowFlags<<<flag_grid_dims, flag_block_dims>>>(
                        m_coop_device_state_request_vertices,
                        m_coop_state_request_vertices.size(),
                        m_coop_device_shadow_valid_flags,
                        1);
                    GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                }

                Stopwatch sw_cpu(true);
                const size_t proposals_before = proposals.size();
                for (uint32_t active_idx = 0; active_idx < active_count; active_idx++) {
                    const index_t src = m_coop_active_vertices[active_idx];
                    const TValue src_value = m_coop_active_values[active_idx];
                    const TBuffer src_buffer = m_coop_active_buffers[active_idx];
                    if (src >= host_pma.nnodes) {
                        continue;
                    }

                    if (src_buffer == static_cast<TBuffer>(std::numeric_limits<uint32_t>::max())) {
                        continue;
                    }

                    source_commits.push_back({src, static_cast<TValue>(src_buffer)});
                    if (src_value <= src_buffer) {
                        continue;
                    }

                    const uint64_t edge_start = host_pma.sync_vertices_[src].index;
                    const uint64_t degree = host_pma.sync_vertices_[src].degree;
                    stats.active_degree_sum += degree;
                    if (FLAGS_coop_cpu_min_degree > 0 &&
                        degree < static_cast<uint64_t>(FLAGS_coop_cpu_min_degree)) {
                        continue;
                    }
                    stats.cpu_expanded_vertices++;
                    stats.cpu_edge_visits += degree;
                    stats.cpu_host_pma_edge_visits += degree;
                    if (host_pma.vertices_[src].cache) {
                        stats.cpu_cached_source_vertices++;
                        stats.cpu_cached_edges += degree;
                    } else {
                        stats.cpu_non_cached_source_vertices++;
                        stats.cpu_non_cached_edges += degree;
                    }

                    for (uint64_t edge_offset = 0; edge_offset < degree; edge_offset++) {
                        const index_t dst = host_pma.edges_[edge_start + edge_offset];
                        const TBuffer weight = static_cast<TBuffer>((src + dst) % 128 + 1);
                        const TBuffer new_value = src_buffer + weight;
                        if (dst < graph_datum.nnodes) {
                            proposals.push_back({dst, new_value, src});
                        }
                    }
                }
                sw_cpu.stop();
                stats.cpu_ms += sw_cpu.ms();
                stats.cpu_proposals_generated = stats.cpu_edge_visits;
                stats.cpu_proposals_survived += proposals.size() - proposals_before;
            }

            template<typename Proposal>
            void GenerateCpuSSSPProposalsForSources(std::vector<Proposal> &proposals,
                                                    std::vector<CpuSourceCommit<TValue>> &source_commits,
                                                    CoopRoundStats &stats) {
                if (m_coop_cpu_source_candidates.empty()) {
                    return;
                }

                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                const uint32_t active_count = static_cast<uint32_t>(m_coop_cpu_source_candidates.size());

                Stopwatch sw_alloc(true);
                m_coop_active_vertices.resize(active_count);
                m_coop_active_values.resize(active_count);
                m_coop_active_buffers.resize(active_count);
                sw_alloc.stop();
                stats.allocation_ms += sw_alloc.ms();

                for (uint32_t active_idx = 0; active_idx < active_count; active_idx++) {
                    m_coop_active_vertices[active_idx] = m_coop_cpu_source_candidates[active_idx].src;
                }

                EnsureCoopShadowStorage();
                m_coop_state_request_vertices.clear();
                m_coop_state_request_active_indices.clear();
                for (uint32_t active_idx = 0; active_idx < active_count; active_idx++) {
                    const index_t src = m_coop_active_vertices[active_idx];
                    if (src < m_coop_shadow_valid.size() && m_coop_shadow_valid[src]) {
                        const TValue shadow_value = m_coop_shadow_values[src];
                        const TBuffer shadow_buffer = m_coop_shadow_buffers[src];
                        if (shadow_buffer < shadow_value) {
                            m_coop_active_values[active_idx] = shadow_value;
                            m_coop_active_buffers[active_idx] = shadow_buffer;
                            stats.shadow_hits++;
                        } else {
                            m_coop_state_request_vertices.push_back(src);
                            m_coop_state_request_active_indices.push_back(active_idx);
                            stats.shadow_misses++;
                        }
                    } else {
                        m_coop_state_request_vertices.push_back(src);
                        m_coop_state_request_active_indices.push_back(active_idx);
                        stats.shadow_misses++;
                    }
                }

                if (!m_coop_state_request_vertices.empty()) {
                    std::vector<TValue> fetched_values;
                    std::vector<TBuffer> fetched_buffers;
                    FetchCoopStateForVertices(m_coop_state_request_vertices,
                                              fetched_values,
                                              fetched_buffers,
                                              stats,
                                              false);
                    for (size_t i = 0; i < m_coop_state_request_vertices.size(); i++) {
                        const index_t src = m_coop_state_request_vertices[i];
                        const uint32_t active_idx = m_coop_state_request_active_indices[i];
                        m_coop_active_values[active_idx] = fetched_values[i];
                        m_coop_active_buffers[active_idx] = fetched_buffers[i];
                        if (src < m_coop_shadow_valid.size()) {
                            m_coop_shadow_values[src] = fetched_values[i];
                            m_coop_shadow_buffers[src] = fetched_buffers[i];
                            m_coop_shadow_valid[src] = 1;
                        }
                    }
                    dim3 flag_grid_dims, flag_block_dims;
                    KernelSizing(flag_grid_dims, flag_block_dims, m_coop_state_request_vertices.size());
                    SetCoopShadowFlags<<<flag_grid_dims, flag_block_dims>>>(
                        m_coop_device_state_request_vertices,
                        m_coop_state_request_vertices.size(),
                        m_coop_device_shadow_valid_flags,
                        1);
                    GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                }

                Stopwatch sw_cpu(true);
                const size_t proposals_before = proposals.size();
                for (uint32_t active_idx = 0; active_idx < active_count; active_idx++) {
                    const index_t src = m_coop_active_vertices[active_idx];
                    const TValue src_value = m_coop_active_values[active_idx];
                    const TBuffer src_buffer = m_coop_active_buffers[active_idx];
                    const bool force_expand = m_coop_cpu_source_candidates[active_idx].force_expand != 0;
                    if (src >= host_pma.nnodes) {
                        continue;
                    }
                    const TBuffer inf = static_cast<TBuffer>(std::numeric_limits<uint32_t>::max());
                    TBuffer base_value = src_buffer < static_cast<TBuffer>(src_value)
                                             ? src_buffer
                                             : static_cast<TBuffer>(src_value);
                    if (base_value == inf) {
                        continue;
                    }

                    source_commits.push_back({src, static_cast<TValue>(base_value)});
                    if (!force_expand && src_value <= src_buffer) {
                        continue;
                    }

                    const uint64_t edge_start = host_pma.sync_vertices_[src].index;
                    const uint64_t degree = host_pma.sync_vertices_[src].degree;
                    stats.cpu_expanded_vertices++;
                    stats.cpu_edge_visits += degree;
                    stats.cpu_host_pma_edge_visits += degree;

                    for (uint64_t edge_offset = 0; edge_offset < degree; edge_offset++) {
                        const index_t dst = host_pma.edges_[edge_start + edge_offset];
                        const TBuffer weight = static_cast<TBuffer>((src + dst) % 128 + 1);
                        const TBuffer new_value = base_value + weight;
                        if (dst < graph_datum.nnodes) {
                            proposals.push_back({dst, new_value, src});
                        }
                    }
                }
                sw_cpu.stop();
                stats.cpu_ms += sw_cpu.ms();
                stats.cpu_proposals_generated += stats.cpu_edge_visits;
                stats.cpu_proposals_survived += proposals.size() - proposals_before;
            }

            template<typename Proposal>
            void MergeCpuSSSPProposals(std::vector<Proposal> &proposals,
                                       std::vector<CpuSourceCommit<TValue>> &source_commits,
                                       CoopRoundStats &stats,
                                       groute::dev::Queue<index_t> changed_vertices) {
                if (proposals.empty() && source_commits.empty()) {
                    return;
                }

                CompressCpuRelaxProposals(proposals, stats);
                stats.cpu_proposals += proposals.size();
                const size_t proposal_bytes = sizeof(Proposal) * proposals.size();
                const size_t commit_bytes = sizeof(CpuSourceCommit<TValue>) * source_commits.size();

                if (!proposals.empty()) {
                    EnsureCoopDeviceCapacity(&m_coop_device_proposals,
                                             &m_coop_device_proposal_capacity,
                                             proposals.size(),
                                             stats);
                    if (m_coop_device_proposal_success_count == nullptr) {
                        Stopwatch sw_alloc(true);
                        GROUTE_CUDA_CHECK(cudaMalloc(&m_coop_device_proposal_success_count,
                                                     sizeof(unsigned long long)));
                        sw_alloc.stop();
                        stats.allocation_ms += sw_alloc.ms();
                    }
                }
                if (!source_commits.empty()) {
                    EnsureCoopDeviceCapacity(&m_coop_device_commits,
                                             &m_coop_device_commit_capacity,
                                             source_commits.size(),
                                             stats);
                }

                Stopwatch sw_h2d(true);
                if (!proposals.empty()) {
                    GROUTE_CUDA_CHECK(cudaMemcpy(m_coop_device_proposals,
                                                 proposals.data(),
                                                 proposal_bytes,
                                                 cudaMemcpyHostToDevice));
                }
                if (!source_commits.empty()) {
                    GROUTE_CUDA_CHECK(cudaMemcpy(m_coop_device_commits,
                                                 source_commits.data(),
                                                 commit_bytes,
                                                 cudaMemcpyHostToDevice));
                }
                sw_h2d.stop();
                stats.h2d_proposal_ms += sw_h2d.ms();
                stats.h2d_proposal_bytes += proposal_bytes + commit_bytes;

                dim3 grid_dims, block_dims;
                Stopwatch sw_merge(true);
                if (!source_commits.empty()) {
                    KernelSizing(grid_dims, block_dims, source_commits.size());
                    MergeCpuSourceCommits<TValue><<<grid_dims, block_dims>>>(m_coop_device_commits,
                                                                              source_commits.size(),
                                                                              m_graph_datum->GetValueDeviceObject());
                }
                if (!proposals.empty()) {
                    GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_proposal_success_count,
                                                 0,
                                                 sizeof(unsigned long long)));
                    KernelSizing(grid_dims, block_dims, proposals.size());
                    MergeCpuRelaxProposals<TBuffer><<<grid_dims, block_dims>>>(m_coop_device_proposals,
                                                                               proposals.size(),
                                                                               m_graph_datum->GetBufferDeviceObject(),
                                                                               m_graph_datum->GetParentDeviceObject(),
                                                                               m_graph_datum->m_wl_bitmap_out_high.DeviceObject(),
                                                                               changed_vertices,
                                                                               m_coop_device_shadow_valid_flags,
                                                                               m_coop_device_proposal_success_count);
                }
                GROUTE_CUDA_CHECK(cudaDeviceSynchronize());
                if (!proposals.empty()) {
                    unsigned long long success_count = 0;
                    GROUTE_CUDA_CHECK(cudaMemcpy(&success_count,
                                                 m_coop_device_proposal_success_count,
                                                 sizeof(unsigned long long),
                                                 cudaMemcpyDeviceToHost));
                    stats.cpu_proposals_success += success_count;
                }
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
        if (m_coop_device_proposals != nullptr) {
            cudaFree(m_coop_device_proposals);
            m_coop_device_proposals = nullptr;
        }
        if (m_coop_device_commits != nullptr) {
            cudaFree(m_coop_device_commits);
            m_coop_device_commits = nullptr;
        }
        if (m_coop_device_cpu_source_candidates != nullptr) {
            cudaFree(m_coop_device_cpu_source_candidates);
            m_coop_device_cpu_source_candidates = nullptr;
        }
        if (m_coop_device_proposal_success_count != nullptr) {
            cudaFree(m_coop_device_proposal_success_count);
            m_coop_device_proposal_success_count = nullptr;
        }
        if (m_coop_device_gpu_skipped_cpu_sources != nullptr) {
            cudaFree(m_coop_device_gpu_skipped_cpu_sources);
            m_coop_device_gpu_skipped_cpu_sources = nullptr;
        }
        if (m_coop_device_gpu_relax_success_count != nullptr) {
            cudaFree(m_coop_device_gpu_relax_success_count);
            m_coop_device_gpu_relax_success_count = nullptr;
        }
        if (m_coop_device_gpu_relax_cpu_home_success_count != nullptr) {
            cudaFree(m_coop_device_gpu_relax_cpu_home_success_count);
            m_coop_device_gpu_relax_cpu_home_success_count = nullptr;
        }
        if (m_coop_device_gpu_relax_dst_degree_sum != nullptr) {
            cudaFree(m_coop_device_gpu_relax_dst_degree_sum);
            m_coop_device_gpu_relax_dst_degree_sum = nullptr;
        }
        if (m_coop_device_gpu_relax_dst_high_degree_count != nullptr) {
            cudaFree(m_coop_device_gpu_relax_dst_high_degree_count);
            m_coop_device_gpu_relax_dst_high_degree_count = nullptr;
        }
        if (m_coop_device_gpu_relax_dst_high_degree_sum != nullptr) {
            cudaFree(m_coop_device_gpu_relax_dst_high_degree_sum);
            m_coop_device_gpu_relax_dst_high_degree_sum = nullptr;
        }
        if (m_coop_device_gpu_relax_dst_batch_touched_count != nullptr) {
            cudaFree(m_coop_device_gpu_relax_dst_batch_touched_count);
            m_coop_device_gpu_relax_dst_batch_touched_count = nullptr;
        }
        if (m_coop_device_cpu_source_owner_epoch != nullptr) {
            cudaFree(m_coop_device_cpu_source_owner_epoch);
            m_coop_device_cpu_source_owner_epoch = nullptr;
        }
        if (m_coop_device_cpu_home_flags != nullptr) {
            cudaFree(m_coop_device_cpu_home_flags);
            m_coop_device_cpu_home_flags = nullptr;
        }
        if (m_coop_device_batch_touched_flags != nullptr) {
            cudaFree(m_coop_device_batch_touched_flags);
            m_coop_device_batch_touched_flags = nullptr;
        }
        if (m_coop_device_active_values != nullptr) {
            cudaFree(m_coop_device_active_values);
            m_coop_device_active_values = nullptr;
        }
        if (m_coop_device_active_buffers != nullptr) {
            cudaFree(m_coop_device_active_buffers);
            m_coop_device_active_buffers = nullptr;
        }
        if (m_coop_device_state_request_vertices != nullptr) {
            cudaFree(m_coop_device_state_request_vertices);
            m_coop_device_state_request_vertices = nullptr;
        }
        if (m_coop_device_shadow_valid_flags != nullptr) {
            cudaFree(m_coop_device_shadow_valid_flags);
            m_coop_device_shadow_valid_flags = nullptr;
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
          m_groute_context->seg_snode[seg_idx] = node_id;
          while(edge_num < seg_nedges){
            out_degree = vcsr_graph.end_edge(node_id) - vcsr_graph.begin_edge(node_id);
            edge_num = edge_num + out_degree;
            if(node_id < vcsr_graph.nnodes){
                node_id ++;
            }else{
                break;
            }
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

        m_groute_context->segment_ct = FLAGS_SEGMENT;
        m_groute_context->SetDevice(0);

        // m_csr_dev_graph_allocator = std::unique_ptr<groute::graphs::single::CSRGraphAllocator>(
        //     new groute::graphs::single::CSRGraphAllocator(csr_graph,seg_nedges_csr_max));
        LOG("seg_nedges_csr_max = %d\n",seg_nedges_csr_max);
        m_vcsr_dev_graph_allocator = std::unique_ptr<groute::graphs::single::PMAGraphAllocator>(new groute::graphs::single::PMAGraphAllocator(vcsr_graph,seg_nedges_csr_max));

        m_graph_datum = std::unique_ptr<GraphDatum>(new GraphDatum(vcsr_graph,seg_nedges_csr_max,nnodes_num));
        if (m_coop_device_shadow_valid_flags != nullptr) {
            GROUTE_CUDA_CHECK(cudaFree(m_coop_device_shadow_valid_flags));
            m_coop_device_shadow_valid_flags = nullptr;
        }
        GROUTE_CUDA_CHECK(cudaMalloc((void **)&m_coop_device_shadow_valid_flags,
                                     sizeof(uint8_t) * std::max<uint32_t>(vcsr_graph.nnodes, 1)));
        GROUTE_CUDA_CHECK(cudaMemset(m_coop_device_shadow_valid_flags,
                                     0,
                                     sizeof(uint8_t) * std::max<uint32_t>(vcsr_graph.nnodes, 1)));
        const uint64_t changed_queue_capacity_u64 =
            std::max<uint64_t>(std::max<uint64_t>(vcsr_graph.nnodes, 1),
                               std::min<uint64_t>(vcsr_graph.elem_capacity,
                                                  seg_nedges_csr_max * std::max<uint32_t>(FLAGS_n_stream, 1)));
        m_coop_device_changed_vertices =
            std::move(groute::Queue<index_t>(static_cast<uint32_t>(
                std::min<uint64_t>(changed_queue_capacity_u64,
                                   std::numeric_limits<uint32_t>::max()))));
        m_coop_device_gpu_to_cpu_boundary_vertices =
            std::move(groute::Queue<index_t>(static_cast<uint32_t>(
                std::min<uint64_t>(std::max<uint64_t>(vcsr_graph.nnodes, 1),
                                   std::numeric_limits<uint32_t>::max()))));
        m_coop_device_gpu_relax_dst_vertices =
            std::move(groute::Queue<index_t>(static_cast<uint32_t>(
                std::min<uint64_t>(changed_queue_capacity_u64,
                                   std::numeric_limits<uint32_t>::max()))));
        m_coop_device_gpu_to_cpu_boundary_vertices.ResetAsync(m_stream->cuda_stream);
        m_coop_device_gpu_relax_dst_vertices.ResetAsync(m_stream->cuda_stream);
        m_stream->Sync();

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
                uint64_t num_of_dst = 0;
                for(index_t i = 0; i<vcsr_graph.nnodes; i++){
                    if(vcsr_graph.vertices_[i].cache){
                        uint64_t start_h = vcsr_graph.sync_vertices_[i].index;
                        uint32_t hot_deg = vcsr_graph.sync_vertices_[i].degree;
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
                        if(hot_deg!=dev_deg)LOG("%d h_deg %d d_deg %d\n",i,vcsr_graph.sync_vertices_[i].degree,vcsr_graph.vertices_[i].virtual_degree);
                        for(auto j = 0; j<  vcsr_graph.sync_vertices_[i].degree ;j++){
                            if(vcsr_graph.edges_[start_h+j]!=graph_datum.host_cache[start_d+j]){
                                printf("src %d cache_dst %d  ",i,graph_datum.host_cache[start_d+j]);
                                printf("hot_dst %d\n",vcsr_graph.edges_[start_h+j]);
                                
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
                uint64_t num_of_dst = 0;
                for(index_t i = 0; i<vcsr_graph.nnodes; i++){
                    if(vcsr_graph.vertices_[i].cache){
                        uint64_t start_h = vcsr_graph.sync_vertices_[i].index;
                        uint32_t hot_deg = vcsr_graph.sync_vertices_[i].degree;
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
                        for(auto j = 0; j<  vcsr_graph.sync_vertices_[i].degree ;j++){
                            if(vcsr_graph.edges_[start_h+j]!=graph_datum.host_cache_l3[start_d+j]){
                                printf("src %d cache_dst %d  ",i,graph_datum.host_cache_l3[start_d+j]);
                                printf("hot_dst %d\n",vcsr_graph.edges_[start_h+j]);
                                
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
                uint64_t num_of_dst = 0;
                for(index_t i = 0; i<vcsr_graph.nnodes; i++){
                    for(auto k = 0; k<  vcsr_graph.sync_vertices_[i].degree ;k++){
                        if(vcsr_graph.edges_[vcsr_graph.sync_vertices_[i].index+k]==-1) {
                            printf("wrong src %d dst %d\n",i,vcsr_graph.edges_[vcsr_graph.sync_vertices_[i].index+k]);
                            num_of_dst++;}
                    }
                    if(vcsr_graph.vertices_[i].cache){
                        
                        uint64_t start_h = vcsr_graph.sync_vertices_[i].index;
                        uint32_t hot_deg = vcsr_graph.sync_vertices_[i].degree;
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
                        if(hot_deg!=dev_deg)LOG("%d h_deg %d d_deg %d\n",i,vcsr_graph.sync_vertices_[i].degree,vcsr_graph.vertices_[i].virtual_degree);
                        for(auto j = 0; j<  vcsr_graph.sync_vertices_[i].degree ;j++){
                            if(vcsr_graph.edges_[start_h+j]!=graph_datum.host_cache[start_d+j]){
                                printf("src %d cache_dst %d  ",i,graph_datum.host_cache[start_d+j]);
                                printf("hot_dst %d\n",vcsr_graph.edges_[start_h+j]);
                                
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
                           stream[stream_id],
                           GetCoopMode() == CoopExecMode::HYBRID &&
                               GetCoopSplitMode() == CoopSplitMode::CPU_HOME &&
                               FLAGS_coop_home_skip_gpu_sources
                               ? m_coop_device_cpu_source_owner_epoch
                               : nullptr,
                           GetCoopMode() == CoopExecMode::HYBRID &&
                               GetCoopSplitMode() == CoopSplitMode::CPU_HOME &&
                               FLAGS_coop_home_skip_gpu_sources
                               ? m_coop_cpu_source_epoch
                               : 0,
                           GetCoopMode() == CoopExecMode::HYBRID &&
                               GetCoopSplitMode() == CoopSplitMode::CPU_HOME &&
                               FLAGS_coop_home_skip_gpu_sources
                               ? m_coop_device_gpu_skipped_cpu_sources
                               : nullptr); 
                    }
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }
               if (GetCoopMode() == CoopExecMode::HYBRID &&
                   GetCoopSplitMode() == CoopSplitMode::CPU_HOME &&
                   FLAGS_coop_home_skip_gpu_sources &&
                   m_coop_device_gpu_skipped_cpu_sources != nullptr) {
                   unsigned long long skipped = 0;
                   GROUTE_CUDA_CHECK(cudaMemcpy(&skipped,
                                                m_coop_device_gpu_skipped_cpu_sources,
                                                sizeof(unsigned long long),
                                                cudaMemcpyDeviceToHost));
                   LOG("[COOP-HOME-INIT-SKIP] gpu_skipped_cpu_sources=%llu\n", skipped);
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
                index_t size = load_update.m_batch_size[NumOfSnapShots].second;
                for(index_t i = local_begin.second; i < local_begin.second+size; i++){
                    index_t src_del = load_update.deleted_edges_w[i].u;
                    index_t dst_del = load_update.deleted_edges_w[i].v;
                    this->del_edges_h[i].u = src_del;
                    this->del_edges_h[i].v = dst_del;
                    this->del_edges_h[i].w = (src_del+dst_del)%128+1;
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
                m_coop_batch_touched_sources.clear();
                m_coop_batch_touched_sources.reserve(size);
                for(index_t i = local_begin.first; i < local_begin.first+size; i++){
                    index_t src_add = load_update.added_edges_w[i].u;
                    index_t dst_add = load_update.added_edges_w[i].v;
                    this->added_edges_h[i].u = src_add;
                    this->added_edges_h[i].v = dst_add;
                    this->added_edges_h[i].w = (src_add+dst_add)%128+1;
                    m_coop_batch_touched_sources.push_back(src_add);
                    // printf("host add edge %d %d\n",src_add,dst_add);
                }
                // LOG("DEBUG pr 1.2 \n");
                GROUTE_CUDA_CHECK(cudaHostGetDevicePointer((void **)&(this->added_edges_d), (void *)(this->added_edges_h), 0));
                dim3 grid_dims, block_dims;
                uint32_t work_size[2];
                work_size[0] = local_begin.first;
                work_size[1] = size;
                // LOG("add start %d \n",work_size[0]);
                // LOG("add size %d \n",work_size[1]);
                bool del =false;
                GROUTE_CUDA_CHECK(cudaMemcpy(this->work_size_d, &work_size[0], 2 * sizeof(uint32_t),cudaMemcpyHostToDevice));
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
                if (GetCoopMode() == CoopExecMode::HYBRID &&
                    GetCoopSplitMode() == CoopSplitMode::CPU_HOME) {
                    PromoteBatchTouchedCpuHomeSources();
                }
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
                // just update the vertex
                read_del(local_begin,NumOfSnapShots);
                cudaDeviceSynchronize();
                read_add(local_begin,NumOfSnapShots);
                cudaDeviceSynchronize();
                add_edge_pr(local_begin,NumOfSnapShots);
                del_edge_pr(local_begin,NumOfSnapShots);
                local_begin.second += load_update.m_batch_size[NumOfSnapShots].second;
                local_begin.first += load_update.m_batch_size[NumOfSnapShots].first;
                m_vcsr_dev_graph_allocator->ReloadAllocator();
                if (GetCoopMode() == CoopExecMode::HYBRID &&
                    GetCoopSplitMode() == CoopSplitMode::CPU_HOME &&
                    (FLAGS_coop_home_skip_gpu_sources || FLAGS_coop_home_diagnostic_launch)) {
                    CoopRoundStats init_skip_stats;
                    m_coop_cpu_home_batch_enabled = true;
                    PromoteBatchTouchedCpuHomeSources(&init_skip_stats);
                    ApplyCpuHomeAdmissionForBatch();
                    if (m_coop_cpu_home_batch_enabled) {
                        PrepareInjectedCpuHomeSourcesForInitialAdd(init_skip_stats);
                    }
                }
                index_t seg_snode,seg_enode;
                index_t stream_id;
                float add_time = 0;
                Stopwatch sw_load(true);
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];
                    seg_enode = m_groute_context->seg_enode[seg_idx];  
                        RebuildWorklist_AllVertices(app_inst,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }
                std::cout<<"sssp active all node "<<vcsr_graph.nnodes<<std::endl;
                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                // LOG("DEBUG1 \n");
                // PreComputationBW();
                ExecutePolicy_All(next_policy);
                // GatherTransfer();
                sw_load.stop();
                add_time+=sw_load.ms();
                // GatherCacheMiss();
                // GatherTransfer();
                cudaDeviceSynchronize();
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
			        seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
			        seg_enode = m_groute_context->seg_enode[seg_idx];  
			        RebuildArrayWorklist(app_inst,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }
                // LOG("DEBUG2 \n");
                bool convergence = false;
                m_running_info.current_round = 0;
                Stopwatch sw_con(true);
                while(!convergence){
                //   PreComputationBW();
                  if (GetCoopMode() == CoopExecMode::OFF) {
                      ExecutePolicy_Converge(next_policy);
                  } else {
                      ExecutePolicy_Converge_Coop(next_policy);
                  }
                //   GatherTransfer();
                //   ExecutePolicy_SC(next_policy);
                  int convergence_check = 0;
                  for(index_t seg_id = 0; seg_id < FLAGS_SEGMENT; seg_id++){
                       if(m_running_info.input_active_count_seg[seg_id] == 0){
                           convergence_check++;
                       }
                   }
                  if(convergence_check == FLAGS_SEGMENT){
                        convergence = true;
                  }
                  if (m_running_info.current_round == 100 ) {//FLAGS_max_iteration
                        convergence = true;
                        LOG("Max iterations reached\n");
                  } 
                }
                sw_con.stop();
                add_time+=sw_con.ms();
                LOG("total add time: %f ms (excluded)\n", add_time);
                // GatherCacheMiss();
                // GatherTransfer();
            }

            void update_tree_del(std::pair<index_t,index_t> &local_begin,index_t &NumOfSnapShots){
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                Loader &load_update = *m_load_update;
                groute::Stream &stream_s = *m_stream;
                const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                AlgoVariant next_policy[FLAGS_SEGMENT];
                for(index_t i = 0; i < FLAGS_SEGMENT; i++){
                    next_policy[i] = m_policy_decision_maker.GetInitPolicy();
                }
                // m_vcsr_dev_graph_allocator->ReloadAllocator();
                GROUTE_CUDA_CHECK(cudaHostGetDevicePointer((void **)&(this->del_edges_d), (void *)(this->del_edges_h), 0));
                dim3 grid_dims, block_dims;
                uint32_t work_size[2];
                index_t start = local_begin.second;
                index_t size = load_update.m_batch_size[NumOfSnapShots].second;
                work_size[0] = start;
                work_size[1] = size;
                GROUTE_CUDA_CHECK(cudaMemcpy(this->work_size_d, &work_size[0], 2 * sizeof(uint32_t),cudaMemcpyHostToDevice));
                //(1) you need reset the parent, value, buffer of deleted edge dst, 如果删除边的源点是终点的parent
                KernelSizing(grid_dims, block_dims, size);
                // Stopwatch sw_load(true);
                Stopwatch sw_del(true);
                kernel::reset_del_edges<<< grid_dims, block_dims, 0, stream_s.cuda_stream >>>(app_inst,vcsr_graph,graph_datum.GetParentDeviceObject(),graph_datum.GetValueDeviceObject(),graph_datum.GetBufferDeviceObject(),graph_datum.cache_edges_l1,graph_datum.cache_edges_l2,this->del_edges_d,this->work_size_d,graph_datum.m_node_reset_datum);
                stream_s.Sync(); 
                cudaDeviceSynchronize();
                index_t seg_snode,seg_enode;
                index_t stream_id;
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
                    seg_snode = m_groute_context->seg_snode[seg_idx];
                    seg_enode = m_groute_context->seg_enode[seg_idx];  
                        // RebuildArrayWorklistAdd(app_inst,vcsr_graph,
                        RebuildArrayWorklistDel(app_inst,vcsr_graph,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }
                bool convergence = false;
                m_running_info.current_round = 0;
                while(!convergence){
                  PreComputationBW();
                  ExecutePolicy_del_con(next_policy);
                //   GatherTransfer();
                  int convergence_check = 0;
                  for(index_t seg_id = 0; seg_id < FLAGS_SEGMENT; seg_id++){
                       if(m_running_info.input_active_count_seg[seg_id] == 0){
                           convergence_check++;
                       }
                   }
                  if(convergence_check == FLAGS_SEGMENT){
                        convergence = true;
                  }
                  if (m_running_info.current_round == 100 ) {//FLAGS_max_iteration
                        convergence = true;
                        LOG("Max iterations reached\n");
                  } 
                }
                sw_del.stop();
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


            void ExecutePolicy_del_con(AlgoVariant *algo_variant) {
                // LOG("------ExecutePolicy_del------\n");
                auto &app_inst = *m_app_inst;
                // auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                Stopwatch sw_execution(true);
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
                        RunSyncPushDDB_del(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                           vcsr_graph,
                           graph_datum,
                           m_engine_options,
                           stream[stream_id]); 
                    }
                }
                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                        stream[stream_idx].Sync();
                }
               PostComputationBW_del();
               sw_execution.stop();
            //    LOG("iter once for del time: %f ms (excluded)\n", sw_execution.ms());

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

            void ExecutePolicy_Converge(AlgoVariant *algo_variant) {
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
                // vcsr_graph_host
                index_t seg_exc = 0;

                index_t stream_id;
                // LOG("debug 1\n");
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
                        RunSyncPushDDB_Delta(app_inst,seg_snode,seg_enode,seg_sedge_csr,seg_idx,zcflag,
                           vcsr_graph,
                           graph_datum,
                           m_engine_options,
                           stream[stream_id]); 
                    }
               }
               for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                     stream[stream_idx].Sync();
               }

               PostComputationBW();
               
            //    sw_round.stop();

            }

            void RunCpuOverlapProbeDryRun(CoopOverlapProbeStats &probe) {
                Stopwatch sw_probe(true);
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                std::vector<index_t> touched = m_coop_batch_touched_sources;
                std::sort(touched.begin(), touched.end());
                touched.erase(std::unique(touched.begin(), touched.end()), touched.end());

                probe.candidate_sources = touched.size();
                probe.edge_budget = static_cast<uint64_t>(std::max(FLAGS_coop_overlap_probe_edge_budget, 0));
                const uint64_t max_sources =
                    static_cast<uint64_t>(std::max(FLAGS_coop_overlap_probe_max_sources, 0));
                uint64_t checksum = 1469598103934665603ull;

                for (const index_t src : touched) {
                    if (max_sources > 0 && probe.selected_sources >= max_sources) {
                        break;
                    }
                    if (probe.edge_budget > 0 && probe.edge_visits >= probe.edge_budget) {
                        break;
                    }
                    if (src >= host_pma.nnodes) {
                        continue;
                    }

                    const uint64_t degree = host_pma.sync_vertices_[src].degree;
                    if (degree == 0) {
                        continue;
                    }
                    if (FLAGS_coop_cpu_min_degree > 0 &&
                        degree < static_cast<uint64_t>(FLAGS_coop_cpu_min_degree)) {
                        continue;
                    }

                    probe.selected_sources++;
                    if (host_pma.vertices_[src].cache) {
                        probe.cached_sources++;
                    } else {
                        probe.non_cached_sources++;
                    }

                    const uint64_t edge_start = host_pma.sync_vertices_[src].index;
                    uint64_t edges_to_read = degree;
                    if (probe.edge_budget > 0) {
                        edges_to_read = std::min(edges_to_read, probe.edge_budget - probe.edge_visits);
                    }
                    for (uint64_t edge_offset = 0; edge_offset < edges_to_read; edge_offset++) {
                        const index_t dst = host_pma.edges_[edge_start + edge_offset];
                        checksum ^= static_cast<uint64_t>(src) + 0x9e3779b97f4a7c15ull +
                                    (static_cast<uint64_t>(dst) << 6) + (checksum >> 2);
                    }
                    probe.edge_visits += edges_to_read;
                    probe.structural_proposals += edges_to_read;
                }

                probe.dst_checksum = checksum;
                probe.host_pma_read_bytes =
                    probe.edge_visits * sizeof(index_t) +
                    probe.selected_sources *
                        (sizeof(host_pma.sync_vertices_[0]) + sizeof(host_pma.vertices_[0]));
                sw_probe.stop();
                probe.cpu_wall_ms = sw_probe.ms();
            }

            void LaunchGpuDeltaAndSync(AlgoVariant *algo_variant,
                                       double &gpu_launch_submit_ms,
                                       double &gpu_sync_wait_ms,
                                       uint32_t &gpu_kernel_launches) {
                auto &app_inst = *m_app_inst;
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr;
                index_t seg_snode, seg_enode;
                index_t stream_id;
                gpu_kernel_launches = 0;

                m_groute_context->segment_ct = FLAGS_SEGMENT;

                Stopwatch sw_launch(true);
                for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++) {
                    seg_snode = m_groute_context->seg_snode[seg_idx];
                    seg_enode = m_groute_context->seg_enode[seg_idx];
                    seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];
                    stream_id = seg_idx % FLAGS_n_stream;

                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    if (algo_variant[seg_idx] == AlgoVariant::Zero_Copy) {
                        m_vcsr_dev_graph_allocator->SwitchZC();
                        zcflag = true;
                        RunSyncPushDDB_Delta(app_inst,
                                             seg_snode,
                                             seg_enode,
                                             seg_sedge_csr,
                                             seg_idx,
                                             zcflag,
                                             vcsr_graph,
                                             graph_datum,
                                             m_engine_options,
                                             stream[stream_id]);
                        gpu_kernel_launches++;
                    }
                }
                sw_launch.stop();
                gpu_launch_submit_ms = sw_launch.ms();

                Stopwatch sw_sync(true);
                for (index_t stream_idx = 0; stream_idx < FLAGS_n_stream; stream_idx++) {
                    stream[stream_idx].Sync();
                }
                sw_sync.stop();
                gpu_sync_wait_ms = sw_sync.ms();
            }

            void ExecutePolicy_Converge_OverlapProbe(AlgoVariant *algo_variant,
                                                     uint64_t coop_seq,
                                                     uint32_t coop_round,
                                                     const char *split_mode_name) {
                CoopOverlapProbeStats probe;
                std::thread cpu_probe_thread([this, &probe]() {
                    RunCpuOverlapProbeDryRun(probe);
                });

                double gpu_launch_submit_ms = 0.0;
                double gpu_sync_wait_ms = 0.0;
                uint32_t gpu_kernel_launches = 0;
                LaunchGpuDeltaAndSync(algo_variant,
                                      gpu_launch_submit_ms,
                                      gpu_sync_wait_ms,
                                      gpu_kernel_launches);

                if (cpu_probe_thread.joinable()) {
                    cpu_probe_thread.join();
                }

                const double overlap_window_ms = gpu_launch_submit_ms + gpu_sync_wait_ms;
                const double hidden_ms = std::min(probe.cpu_wall_ms, overlap_window_ms);
                const double exposed_ms = probe.cpu_wall_ms > overlap_window_ms
                                              ? probe.cpu_wall_ms - overlap_window_ms
                                              : 0.0;
                const double hidden_ratio = probe.cpu_wall_ms > 0.0
                                                ? hidden_ms / probe.cpu_wall_ms
                                                : 0.0;

                LOG("[COOP-OVERLAP] seq=%lu round=%u split_mode=%s phase=9A_read_only_probe candidate_sources=%lu selected_sources=%lu cached_sources=%lu non_cached_sources=%lu edge_visits=%lu structural_proposals=%lu host_pma_read_bytes=%lu edge_budget=%lu cpu_wall_ms=%f gpu_launch_submit_ms=%f gpu_sync_wait_ms=%f overlap_window_ms=%f cpu_overlap_hidden_ms=%f cpu_overlap_exposed_ms=%f hidden_ratio=%f gpu_kernel_launches=%u dst_checksum=%lu note=no_device_state_change\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    split_mode_name,
                    probe.candidate_sources,
                    probe.selected_sources,
                    probe.cached_sources,
                    probe.non_cached_sources,
                    probe.edge_visits,
                    probe.structural_proposals,
                    probe.host_pma_read_bytes,
                    probe.edge_budget,
                    probe.cpu_wall_ms,
                    gpu_launch_submit_ms,
                    gpu_sync_wait_ms,
                    overlap_window_ms,
                    hidden_ms,
                    exposed_ms,
                    hidden_ratio,
                    gpu_kernel_launches,
                    probe.dst_checksum);

                PostComputationBW();
            }

            void RunCpuPacketDryRun(const std::vector<index_t> &sources,
                                    const std::vector<TValue> &source_values,
                                    const std::vector<TBuffer> &source_buffers,
                                    std::vector<CpuRelaxProposal<TBuffer>> &proposals,
                                    CoopPacketDryRunStats &packet) {
                Stopwatch sw_cpu(true);
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                uint64_t checksum = 1469598103934665603ull;

                for (size_t i = 0; i < sources.size(); i++) {
                    if (packet.edge_budget > 0 && packet.edge_visits >= packet.edge_budget) {
                        break;
                    }
                    const index_t src = sources[i];
                    if (src >= host_pma.nnodes) {
                        continue;
                    }
                    const TBuffer inf = static_cast<TBuffer>(std::numeric_limits<uint32_t>::max());
                    const TBuffer src_buffer = source_buffers[i];
                    const TValue src_value = source_values[i];
                    TBuffer base_value = src_buffer < static_cast<TBuffer>(src_value)
                                             ? src_buffer
                                             : static_cast<TBuffer>(src_value);
                    if (base_value == inf) {
                        continue;
                    }
                    packet.reachable_sources++;
                    if (src_buffer >= static_cast<TBuffer>(src_value)) {
                        continue;
                    }
                    packet.active_sources++;

                    const uint64_t degree = host_pma.sync_vertices_[src].degree;
                    if (degree == 0) {
                        continue;
                    }
                    const uint64_t edge_start = host_pma.sync_vertices_[src].index;
                    uint64_t edges_to_read = degree;
                    if (packet.edge_budget > 0) {
                        edges_to_read = std::min(edges_to_read, packet.edge_budget - packet.edge_visits);
                    }
                    for (uint64_t edge_offset = 0; edge_offset < edges_to_read; edge_offset++) {
                        const index_t dst = host_pma.edges_[edge_start + edge_offset];
                        if (dst >= graph_datum.nnodes) {
                            continue;
                        }
                        const TBuffer weight = static_cast<TBuffer>((src + dst) % 128 + 1);
                        const TBuffer new_value = base_value + weight;
                        proposals.push_back({dst, new_value, src});
                        checksum ^= static_cast<uint64_t>(dst) + 0x9e3779b97f4a7c15ull +
                                    (static_cast<uint64_t>(new_value) << 6) + (checksum >> 2);
                    }
                    packet.edge_visits += edges_to_read;
                    packet.generated_proposals += edges_to_read;
                }

                packet.proposal_checksum = checksum;
                packet.host_pma_read_bytes =
                    packet.edge_visits * sizeof(index_t) +
                    packet.selected_sources *
                        (sizeof(host_pma.sync_vertices_[0]) + sizeof(host_pma.vertices_[0]));
                sw_cpu.stop();
                packet.cpu_wall_ms = sw_cpu.ms();
            }

            void SelectCpuPacketSources(CoopPacketDryRunStats &packet,
                                        std::vector<index_t> &packet_sources,
                                        uint64_t &selected_edge_est) {
                auto &host_pma = m_vcsr_dev_graph_allocator->HostObject();
                packet.edge_budget = static_cast<uint64_t>(std::max(FLAGS_coop_packet_edge_budget, 0));
                const uint64_t max_sources =
                    static_cast<uint64_t>(std::max(FLAGS_coop_packet_max_sources, 0));
                selected_edge_est = 0;
                const std::string source_policy = FLAGS_coop_packet_source_policy;
                auto try_select_source = [&](const index_t src) {
                    packet.candidate_sources++;
                    if (max_sources > 0 && packet_sources.size() >= max_sources) {
                        return false;
                    }
                    if (packet.edge_budget > 0 && selected_edge_est >= packet.edge_budget) {
                        return false;
                    }
                    if (src >= host_pma.nnodes) {
                        return true;
                    }
                    const uint64_t degree = host_pma.sync_vertices_[src].degree;
                    if (degree == 0) {
                        return true;
                    }
                    if (FLAGS_coop_cpu_min_degree > 0 &&
                        degree < static_cast<uint64_t>(FLAGS_coop_cpu_min_degree)) {
                        return true;
                    }
                    packet_sources.push_back(src);
                    selected_edge_est += degree;
                    if (host_pma.vertices_[src].cache) {
                        packet.cached_sources++;
                    } else {
                        packet.non_cached_sources++;
                    }
                    return true;
                };

                if (source_policy == "active_frontier") {
                    GraphDatum &graph_datum = *m_graph_datum;
                    for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++) {
                        if (max_sources > 0 && packet_sources.size() >= max_sources) {
                            break;
                        }
                        if (packet.edge_budget > 0 && selected_edge_est >= packet.edge_budget) {
                            break;
                        }
                        const index_t stream_id = seg_idx % FLAGS_n_stream;
                        const uint32_t active_count =
                            graph_datum.m_wl_array_in_seg[seg_idx].GetCount(stream[stream_id]);
                        if (active_count == 0) {
                            continue;
                        }
                        std::vector<index_t> active_vertices(active_count);
                        GROUTE_CUDA_CHECK(cudaMemcpyAsync(
                            active_vertices.data(),
                            graph_datum.m_wl_array_in_seg[seg_idx].GetDeviceDataPtr(),
                            sizeof(index_t) * active_count,
                            cudaMemcpyDeviceToHost,
                            stream[stream_id].cuda_stream));
                        stream[stream_id].Sync();
                        for (const index_t src : active_vertices) {
                            if (!try_select_source(src)) {
                                break;
                            }
                        }
                    }
                    std::sort(packet_sources.begin(), packet_sources.end());
                    packet_sources.erase(std::unique(packet_sources.begin(), packet_sources.end()),
                                         packet_sources.end());
                    packet.selected_sources = packet_sources.size();
                } else {
                    if (source_policy != "batch_touched") {
                        LOG("[COOP-PACKET-WARN] unknown_source_policy=%s fallback=batch_touched\n",
                            source_policy.c_str());
                    }
                    std::vector<index_t> touched = m_coop_batch_touched_sources;
                    std::sort(touched.begin(), touched.end());
                    touched.erase(std::unique(touched.begin(), touched.end()), touched.end());
                    for (const index_t src : touched) {
                        if (!try_select_source(src)) {
                            break;
                        }
                    }
                    packet.selected_sources = packet_sources.size();
                }
            }

            void ExecutePolicy_Converge_PacketDryRun(AlgoVariant *algo_variant,
                                                     uint64_t coop_seq,
                                                     uint32_t coop_round,
                                                     const char *split_mode_name) {
                CoopPacketDryRunStats packet;

                std::vector<index_t> packet_sources;
                uint64_t selected_edge_est = 0;
                SelectCpuPacketSources(packet, packet_sources, selected_edge_est);
                const std::string source_policy = FLAGS_coop_packet_source_policy;

                CoopRoundStats state_stats;
                std::vector<TValue> source_values;
                std::vector<TBuffer> source_buffers;
                if (!packet_sources.empty()) {
                    FetchCoopStateForVertices(packet_sources,
                                              source_values,
                                              source_buffers,
                                              state_stats,
                                              false);
                }
                packet.source_state_snapshots = packet_sources.size();
                packet.state_snapshot_bytes =
                    state_stats.state_request_h2d_bytes + state_stats.state_d2h_bytes;
                packet.source_state_snapshot_ms =
                    state_stats.state_request_h2d_ms + state_stats.state_d2h_ms;

                std::vector<CpuRelaxProposal<TBuffer>> proposals;
                proposals.reserve(packet.edge_budget > 0
                                      ? static_cast<size_t>(packet.edge_budget)
                                      : static_cast<size_t>(selected_edge_est));
                RunCpuPacketDryRun(packet_sources,
                                   source_values,
                                   source_buffers,
                                   proposals,
                                   packet);

                CoopRoundStats compress_stats;
                CompressCpuRelaxProposals(proposals, compress_stats);
                packet.compressed_proposals = proposals.size();
                packet.compressed_unique_dst = proposals.size();
                packet.proposal_compress_ms = compress_stats.proposal_compress_ms;

                std::vector<index_t> dst_vertices;
                if (!proposals.empty()) {
                    dst_vertices.reserve(proposals.size());
                    for (const auto &proposal : proposals) {
                        dst_vertices.push_back(proposal.dst);
                    }
                    CoopRoundStats pre_dst_stats;
                    std::vector<TValue> pre_dst_values;
                    std::vector<TBuffer> pre_dst_buffers;
                    FetchCoopStateForVertices(dst_vertices,
                                              pre_dst_values,
                                              pre_dst_buffers,
                                              pre_dst_stats,
                                              false);
                    auto &probe_host_pma = m_vcsr_dev_graph_allocator->HostObject();
                    for (size_t i = 0; i < proposals.size(); i++) {
                        if (proposals[i].value < pre_dst_buffers[i]) {
                            packet.estimated_success_before_gpu++;
                            const index_t dst = proposals[i].dst;
                            if (dst < probe_host_pma.nnodes) {
                                const uint64_t dst_degree =
                                    probe_host_pma.sync_vertices_[dst].degree;
                                packet.expected_avoided_gpu_edges += dst_degree;
                                if (dst_degree >= 32) {
                                    packet.dst_ge32_count++;
                                    packet.dst_ge32_sum += dst_degree;
                                }
                                if (dst_degree >= 128) {
                                    packet.dst_ge128_count++;
                                    packet.dst_ge128_sum += dst_degree;
                                }
                                if (dst_degree >= 512) {
                                    packet.dst_ge512_count++;
                                    packet.dst_ge512_sum += dst_degree;
                                }
                                if (dst_degree >= 1024) {
                                    packet.dst_ge1024_count++;
                                    packet.dst_ge1024_sum += dst_degree;
                                }
                            }
                        }
                    }
                    packet.pre_dst_state_probe_bytes =
                        pre_dst_stats.state_request_h2d_bytes + pre_dst_stats.state_d2h_bytes;
                    packet.pre_dst_state_probe_ms =
                        pre_dst_stats.state_request_h2d_ms + pre_dst_stats.state_d2h_ms;
                    packet.dst_state_probe_bytes += packet.pre_dst_state_probe_bytes;
                    packet.dst_state_probe_ms += packet.pre_dst_state_probe_ms;
                }

                if (FLAGS_coop_packet_diagnostic_merge && !proposals.empty()) {
                    CoopRoundStats merge_stats;
                    std::vector<CpuSourceCommit<TValue>> no_source_commits;
                    Stopwatch sw_merge_wall(true);
                    MergeCpuSSSPProposals(proposals,
                                          no_source_commits,
                                          merge_stats,
                                          m_coop_device_changed_vertices.DeviceObject());
                    sw_merge_wall.stop();
                    packet.diagnostic_merge_success = merge_stats.cpu_proposals_success;
                    packet.diagnostic_merge_h2d_bytes = merge_stats.h2d_proposal_bytes;
                    packet.diagnostic_merge_h2d_ms = merge_stats.h2d_proposal_ms;
                    packet.diagnostic_merge_kernel_ms = merge_stats.merge_ms;
                    packet.diagnostic_merge_wall_ms = sw_merge_wall.ms();
                }

                double gpu_launch_submit_ms = 0.0;
                double gpu_sync_wait_ms = 0.0;
                uint32_t gpu_kernel_launches = 0;
                LaunchGpuDeltaAndSync(algo_variant,
                                      gpu_launch_submit_ms,
                                      gpu_sync_wait_ms,
                                      gpu_kernel_launches);

                if (!proposals.empty()) {
                    CoopRoundStats dst_stats;
                    std::vector<TValue> dst_values;
                    std::vector<TBuffer> dst_buffers;
                    FetchCoopStateForVertices(dst_vertices,
                                              dst_values,
                                              dst_buffers,
                                              dst_stats,
                                              false);
                    for (size_t i = 0; i < proposals.size(); i++) {
                        if (proposals[i].value < dst_buffers[i]) {
                            packet.estimated_success_after_gpu++;
                        }
                    }
                    packet.post_dst_state_probe_bytes =
                        dst_stats.state_request_h2d_bytes + dst_stats.state_d2h_bytes;
                    packet.post_dst_state_probe_ms =
                        dst_stats.state_request_h2d_ms + dst_stats.state_d2h_ms;
                    packet.dst_state_probe_bytes += packet.post_dst_state_probe_bytes;
                    packet.dst_state_probe_ms += packet.post_dst_state_probe_ms;
                }
                if (packet.estimated_success_before_gpu > packet.estimated_success_after_gpu) {
                    packet.pre_after_success_gap =
                        packet.estimated_success_before_gpu - packet.estimated_success_after_gpu;
                }

                const double overlap_window_ms = gpu_launch_submit_ms + gpu_sync_wait_ms;
                const double pre_gpu_probe_ms =
                    packet.cpu_wall_ms + packet.proposal_compress_ms + packet.pre_dst_state_probe_ms;
                const double hidden_ms = 0.0;
                const double exposed_ms = pre_gpu_probe_ms;
                const double hidden_ratio = 0.0;

                LOG("[COOP-PACKET-DRYRUN] seq=%lu round=%u split_mode=%s phase=9C_packet_dry_run source_policy=%s candidate_sources=%lu selected_sources=%lu source_state_snapshots=%lu reachable_sources=%lu active_sources=%lu cached_sources=%lu non_cached_sources=%lu edge_visits=%lu generated_proposals=%lu compressed_proposals=%lu estimated_success_after_gpu=%lu estimated_success_before_gpu=%lu compressed_unique_dst=%lu pre_after_success_gap=%lu expected_avoided_gpu_edges=%lu dst_ge32_count=%lu dst_ge32_sum=%lu dst_ge128_count=%lu dst_ge128_sum=%lu dst_ge512_count=%lu dst_ge512_sum=%lu dst_ge1024_count=%lu dst_ge1024_sum=%lu diagnostic_merge_enabled=%d diagnostic_merge_success=%lu diagnostic_merge_h2d_bytes=%lu diagnostic_merge_h2d_ms=%f diagnostic_merge_kernel_ms=%f diagnostic_merge_wall_ms=%f host_pma_read_bytes=%lu state_snapshot_bytes=%lu dst_state_probe_bytes=%lu pre_dst_state_probe_bytes=%lu post_dst_state_probe_bytes=%lu edge_budget=%lu source_state_snapshot_ms=%f cpu_wall_ms=%f proposal_compress_ms=%f dst_state_probe_ms=%f pre_dst_state_probe_ms=%f post_dst_state_probe_ms=%f pre_gpu_probe_ms=%f gpu_launch_submit_ms=%f gpu_sync_wait_ms=%f overlap_window_ms=%f cpu_overlap_hidden_ms=%f cpu_overlap_exposed_ms=%f hidden_ratio=%f gpu_kernel_launches=%u proposal_checksum=%lu note=%s\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    split_mode_name,
                    source_policy.c_str(),
                    packet.candidate_sources,
                    packet.selected_sources,
                    packet.source_state_snapshots,
                    packet.reachable_sources,
                    packet.active_sources,
                    packet.cached_sources,
                    packet.non_cached_sources,
                    packet.edge_visits,
                    packet.generated_proposals,
                    packet.compressed_proposals,
                    packet.estimated_success_after_gpu,
                    packet.estimated_success_before_gpu,
                    packet.compressed_unique_dst,
                    packet.pre_after_success_gap,
                    packet.expected_avoided_gpu_edges,
                    packet.dst_ge32_count,
                    packet.dst_ge32_sum,
                    packet.dst_ge128_count,
                    packet.dst_ge128_sum,
                    packet.dst_ge512_count,
                    packet.dst_ge512_sum,
                    packet.dst_ge1024_count,
                    packet.dst_ge1024_sum,
                    FLAGS_coop_packet_diagnostic_merge ? 1 : 0,
                    packet.diagnostic_merge_success,
                    packet.diagnostic_merge_h2d_bytes,
                    packet.diagnostic_merge_h2d_ms,
                    packet.diagnostic_merge_kernel_ms,
                    packet.diagnostic_merge_wall_ms,
                    packet.host_pma_read_bytes,
                    packet.state_snapshot_bytes,
                    packet.dst_state_probe_bytes,
                    packet.pre_dst_state_probe_bytes,
                    packet.post_dst_state_probe_bytes,
                    packet.edge_budget,
                    packet.source_state_snapshot_ms,
                    packet.cpu_wall_ms,
                    packet.proposal_compress_ms,
                    packet.dst_state_probe_ms,
                    packet.pre_dst_state_probe_ms,
                    packet.post_dst_state_probe_ms,
                    pre_gpu_probe_ms,
                    gpu_launch_submit_ms,
                    gpu_sync_wait_ms,
                    overlap_window_ms,
                    hidden_ms,
                    exposed_ms,
                    hidden_ratio,
                    gpu_kernel_launches,
                    packet.proposal_checksum,
                    FLAGS_coop_packet_diagnostic_merge
                        ? "pre_gpu_quality_probe_diagnostic_merge_no_gpu_skip"
                        : "pre_gpu_quality_probe_no_device_state_change_no_merge_no_gpu_skip");

                PostComputationBW();
            }

            void ExecutePolicy_Converge_PacketProductionMerge(AlgoVariant *algo_variant,
                                                              uint64_t coop_seq,
                                                              uint32_t coop_round,
                                                              const char *split_mode_name) {
                CoopPacketDryRunStats packet;
                std::vector<index_t> packet_sources;
                uint64_t selected_edge_est = 0;
                SelectCpuPacketSources(packet, packet_sources, selected_edge_est);
                const std::string source_policy = FLAGS_coop_packet_source_policy;

                CoopRoundStats state_stats;
                std::vector<TValue> source_values;
                std::vector<TBuffer> source_buffers;
                if (!packet_sources.empty()) {
                    FetchCoopStateForVertices(packet_sources,
                                              source_values,
                                              source_buffers,
                                              state_stats,
                                              false);
                }
                packet.source_state_snapshots = packet_sources.size();
                packet.state_snapshot_bytes =
                    state_stats.state_request_h2d_bytes + state_stats.state_d2h_bytes;
                packet.source_state_snapshot_ms =
                    state_stats.state_request_h2d_ms + state_stats.state_d2h_ms;

                std::vector<CpuRelaxProposal<TBuffer>> proposals;
                proposals.reserve(packet.edge_budget > 0
                                      ? static_cast<size_t>(packet.edge_budget)
                                      : static_cast<size_t>(selected_edge_est));
                RunCpuPacketDryRun(packet_sources,
                                   source_values,
                                   source_buffers,
                                   proposals,
                                   packet);

                CoopRoundStats compress_stats;
                CompressCpuRelaxProposals(proposals, compress_stats);
                packet.compressed_proposals = proposals.size();
                packet.compressed_unique_dst = proposals.size();
                packet.proposal_compress_ms = compress_stats.proposal_compress_ms;

                if (!proposals.empty()) {
                    CoopRoundStats merge_stats;
                    std::vector<CpuSourceCommit<TValue>> no_source_commits;
                    Stopwatch sw_merge_wall(true);
                    MergeCpuSSSPProposals(proposals,
                                          no_source_commits,
                                          merge_stats,
                                          m_coop_device_changed_vertices.DeviceObject());
                    sw_merge_wall.stop();
                    packet.diagnostic_merge_success = merge_stats.cpu_proposals_success;
                    packet.diagnostic_merge_h2d_bytes = merge_stats.h2d_proposal_bytes;
                    packet.diagnostic_merge_h2d_ms = merge_stats.h2d_proposal_ms;
                    packet.diagnostic_merge_kernel_ms = merge_stats.merge_ms;
                    packet.diagnostic_merge_wall_ms = sw_merge_wall.ms();
                }

                double gpu_launch_submit_ms = 0.0;
                double gpu_sync_wait_ms = 0.0;
                uint32_t gpu_kernel_launches = 0;
                LaunchGpuDeltaAndSync(algo_variant,
                                      gpu_launch_submit_ms,
                                      gpu_sync_wait_ms,
                                      gpu_kernel_launches);

                const double overlap_window_ms = gpu_launch_submit_ms + gpu_sync_wait_ms;

                LOG("[COOP-PACKET-MERGE] seq=%lu round=%u split_mode=%s phase=9F_packet_production_candidate source_policy=%s candidate_sources=%lu selected_sources=%lu source_state_snapshots=%lu reachable_sources=%lu active_sources=%lu cached_sources=%lu non_cached_sources=%lu edge_visits=%lu generated_proposals=%lu compressed_proposals=%lu compressed_unique_dst=%lu merge_success=%lu merge_h2d_bytes=%lu state_snapshot_bytes=%lu host_pma_read_bytes=%lu edge_budget=%lu source_state_snapshot_ms=%f cpu_wall_ms=%f proposal_compress_ms=%f merge_h2d_ms=%f merge_kernel_ms=%f merge_wall_ms=%f gpu_launch_submit_ms=%f gpu_sync_wait_ms=%f overlap_window_ms=%f gpu_kernel_launches=%u proposal_checksum=%lu note=production_candidate_no_dst_probe_no_gpu_skip\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    split_mode_name,
                    source_policy.c_str(),
                    packet.candidate_sources,
                    packet.selected_sources,
                    packet.source_state_snapshots,
                    packet.reachable_sources,
                    packet.active_sources,
                    packet.cached_sources,
                    packet.non_cached_sources,
                    packet.edge_visits,
                    packet.generated_proposals,
                    packet.compressed_proposals,
                    packet.compressed_unique_dst,
                    packet.diagnostic_merge_success,
                    packet.diagnostic_merge_h2d_bytes,
                    packet.state_snapshot_bytes,
                    packet.host_pma_read_bytes,
                    packet.edge_budget,
                    packet.source_state_snapshot_ms,
                    packet.cpu_wall_ms,
                    packet.proposal_compress_ms,
                    packet.diagnostic_merge_h2d_ms,
                    packet.diagnostic_merge_kernel_ms,
                    packet.diagnostic_merge_wall_ms,
                    gpu_launch_submit_ms,
                    gpu_sync_wait_ms,
                    overlap_window_ms,
                    gpu_kernel_launches,
                    packet.proposal_checksum);

                PostComputationBW();
            }

            void ExecutePolicy_Converge_PacketOverlapMerge(AlgoVariant *algo_variant,
                                                           uint64_t coop_seq,
                                                           uint32_t coop_round,
                                                           const char *split_mode_name) {
                CoopPacketDryRunStats packet;
                std::vector<index_t> packet_sources;
                uint64_t selected_edge_est = 0;
                SelectCpuPacketSources(packet, packet_sources, selected_edge_est);
                const std::string source_policy = FLAGS_coop_packet_source_policy;

                CoopRoundStats state_stats;
                std::vector<TValue> source_values;
                std::vector<TBuffer> source_buffers;
                if (!packet_sources.empty()) {
                    FetchCoopStateForVertices(packet_sources,
                                              source_values,
                                              source_buffers,
                                              state_stats,
                                              false);
                }
                packet.source_state_snapshots = packet_sources.size();
                packet.state_snapshot_bytes =
                    state_stats.state_request_h2d_bytes + state_stats.state_d2h_bytes;
                packet.source_state_snapshot_ms =
                    state_stats.state_request_h2d_ms + state_stats.state_d2h_ms;

                std::vector<CpuRelaxProposal<TBuffer>> proposals;
                proposals.reserve(packet.edge_budget > 0
                                      ? static_cast<size_t>(packet.edge_budget)
                                      : static_cast<size_t>(selected_edge_est));

                CoopRoundStats compress_stats;
                std::thread cpu_packet_thread([this,
                                               &packet_sources,
                                               &source_values,
                                               &source_buffers,
                                               &proposals,
                                               &packet,
                                               &compress_stats]() {
                    RunCpuPacketDryRun(packet_sources,
                                       source_values,
                                       source_buffers,
                                       proposals,
                                       packet);
                    CompressCpuRelaxProposals(proposals, compress_stats);
                    packet.compressed_proposals = proposals.size();
                    packet.compressed_unique_dst = proposals.size();
                    packet.proposal_compress_ms = compress_stats.proposal_compress_ms;
                });

                m_coop_device_changed_vertices.ResetAsync(m_stream->cuda_stream);
                m_stream->Sync();

                double gpu_launch_submit_ms = 0.0;
                double gpu_sync_wait_ms = 0.0;
                uint32_t gpu_kernel_launches = 0;
                LaunchGpuDeltaAndSync(algo_variant,
                                      gpu_launch_submit_ms,
                                      gpu_sync_wait_ms,
                                      gpu_kernel_launches);

                if (cpu_packet_thread.joinable()) {
                    cpu_packet_thread.join();
                }

                const uint64_t compressed_before_stale_filter = proposals.size();
                uint64_t still_valid_proposals = 0;
                uint64_t stale_proposals = 0;
                uint64_t dropped_stale_proposals = 0;
                double stale_filter_ms = 0.0;
                uint64_t stale_filter_bytes = 0;
                if (!proposals.empty()) {
                    Stopwatch sw_stale_filter(true);
                    std::vector<index_t> dst_vertices;
                    dst_vertices.reserve(proposals.size());
                    for (const auto &proposal : proposals) {
                        dst_vertices.push_back(proposal.dst);
                    }
                    CoopRoundStats dst_stats;
                    std::vector<TValue> dst_values;
                    std::vector<TBuffer> dst_buffers;
                    FetchCoopStateForVertices(dst_vertices,
                                              dst_values,
                                              dst_buffers,
                                              dst_stats,
                                              false);
                    std::vector<CpuRelaxProposal<TBuffer>> still_valid;
                    still_valid.reserve(proposals.size());
                    for (size_t i = 0; i < proposals.size(); i++) {
                        if (proposals[i].value < dst_buffers[i]) {
                            still_valid.push_back(proposals[i]);
                        }
                    }
                    still_valid_proposals = still_valid.size();
                    stale_proposals = proposals.size() - still_valid.size();
                    dropped_stale_proposals = stale_proposals;
                    proposals.swap(still_valid);
                    sw_stale_filter.stop();
                    stale_filter_ms = sw_stale_filter.ms();
                    stale_filter_bytes =
                        dst_stats.state_request_h2d_bytes + dst_stats.state_d2h_bytes;
                }

                if (!proposals.empty()) {
                    CoopRoundStats merge_stats;
                    std::vector<CpuSourceCommit<TValue>> no_source_commits;
                    Stopwatch sw_merge_wall(true);
                    MergeCpuSSSPProposals(proposals,
                                          no_source_commits,
                                          merge_stats,
                                          m_coop_device_changed_vertices.DeviceObject());
                    sw_merge_wall.stop();
                    packet.diagnostic_merge_success = merge_stats.cpu_proposals_success;
                    packet.diagnostic_merge_h2d_bytes = merge_stats.h2d_proposal_bytes;
                    packet.diagnostic_merge_h2d_ms = merge_stats.h2d_proposal_ms;
                    packet.diagnostic_merge_kernel_ms = merge_stats.merge_ms;
                    packet.diagnostic_merge_wall_ms = sw_merge_wall.ms();
                }

                uint32_t postbw_visible_active = 0;
                if (packet.diagnostic_merge_success > 0) {
                    postbw_visible_active = m_coop_device_changed_vertices.GetCount(*m_stream);
                }

                const double overlap_window_ms = gpu_launch_submit_ms + gpu_sync_wait_ms;
                const double cpu_hidden_candidate_ms =
                    packet.cpu_wall_ms + packet.proposal_compress_ms;
                const double hidden_ms = std::min(cpu_hidden_candidate_ms, overlap_window_ms);
                const double exposed_ms = cpu_hidden_candidate_ms > overlap_window_ms
                                              ? cpu_hidden_candidate_ms - overlap_window_ms
                                              : 0.0;
                const double hidden_ratio = cpu_hidden_candidate_ms > 0.0
                                                ? hidden_ms / cpu_hidden_candidate_ms
                                                : 0.0;

                LOG("[COOP-PACKET-OVERLAP] seq=%lu packet_round=%u merge_round=%u split_mode=%s phase=10A_packet_overlap_merge source_policy=%s candidate_sources=%lu selected_sources=%lu source_state_snapshots=%lu reachable_sources=%lu active_sources=%lu cached_sources=%lu non_cached_sources=%lu edge_visits=%lu generated_proposals=%lu compressed_proposals=%lu compressed_before_stale_filter=%lu still_valid_proposals=%lu stale_proposals=%lu dropped_stale_proposals=%lu merge_success=%lu merge_h2d_bytes=%lu state_snapshot_bytes=%lu stale_filter_bytes=%lu host_pma_read_bytes=%lu edge_budget=%lu source_state_snapshot_ms=%f cpu_generate_ms=%f cpu_wall_ms=%f proposal_compress_ms=%f stale_filter_ms=%f overlap_window_ms=%f hidden_cpu_ms=%f exposed_cpu_ms=%f hidden_ratio=%f gpu_launch_submit_ms=%f gpu_sync_wait_ms=%f merge_h2d_ms=%f merge_kernel_ms=%f merge_wall_ms=%f gpu_kernel_launches=%u postbw_visible_active=%u performance_claim_valid=%d proposal_checksum=%lu note=phase10A_overlap_generate_compress_then_barrier_merge_no_gpu_skip\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    coop_round,
                    split_mode_name,
                    source_policy.c_str(),
                    packet.candidate_sources,
                    packet.selected_sources,
                    packet.source_state_snapshots,
                    packet.reachable_sources,
                    packet.active_sources,
                    packet.cached_sources,
                    packet.non_cached_sources,
                    packet.edge_visits,
                    packet.generated_proposals,
                    packet.compressed_proposals,
                    compressed_before_stale_filter,
                    still_valid_proposals,
                    stale_proposals,
                    dropped_stale_proposals,
                    packet.diagnostic_merge_success,
                    packet.diagnostic_merge_h2d_bytes,
                    packet.state_snapshot_bytes,
                    stale_filter_bytes,
                    packet.host_pma_read_bytes,
                    packet.edge_budget,
                    packet.source_state_snapshot_ms,
                    packet.cpu_wall_ms,
                    packet.cpu_wall_ms,
                    packet.proposal_compress_ms,
                    stale_filter_ms,
                    overlap_window_ms,
                    hidden_ms,
                    exposed_ms,
                    hidden_ratio,
                    gpu_launch_submit_ms,
                    gpu_sync_wait_ms,
                    packet.diagnostic_merge_h2d_ms,
                    packet.diagnostic_merge_kernel_ms,
                    packet.diagnostic_merge_wall_ms,
                    gpu_kernel_launches,
                    postbw_visible_active,
                    1,
                    packet.proposal_checksum);

                PostComputationBW();
            }

            void ExecutePolicy_Converge_Coop(AlgoVariant *algo_variant) {
                Stopwatch sw_round(true);
                const uint32_t coop_round = m_running_info.current_round;
                const uint64_t coop_seq = m_coop_attr_sequence++;
                auto &app_inst = *m_app_inst;
                auto &vcsr_graph_host = m_vcsr_dev_graph_allocator->HostObject();
                GraphDatum &graph_datum = *m_graph_datum;
                bool zcflag = true;
                m_vcsr_dev_graph_allocator->AllocateDevMirror_Edge_Zero();
                uint64_t seg_sedge_csr, seg_nedges_csr;
                index_t seg_snode, seg_enode;
                const CoopSplitMode split_mode = GetCoopSplitMode();
                const bool cpu_home_mode = split_mode == CoopSplitMode::CPU_HOME;
                const bool cpu_home_owner_skip_enabled =
                    cpu_home_mode && FLAGS_coop_home_skip_gpu_sources;
                const bool cpu_home_diagnostic_launch_enabled =
                    cpu_home_mode && FLAGS_coop_home_diagnostic_launch;
                const char *split_mode_name = cpu_home_mode ? "cpu_home" : "host_select";

                if (cpu_home_mode && !m_coop_cpu_home_batch_enabled) {
                    LOG("[COOP-DECISION] seq=%lu round=%u mode=hybrid split_mode=%s policy=cpu_home_source_ownership cpu_sources=0 gpu_frontier_vertices=unknown gpu_segments=unknown active_gpu_segments=unknown reason=cpu_home_disabled_low_work\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        split_mode_name);
                    ExecutePolicy_Converge(algo_variant);
                    return;
                }

                if (cpu_home_mode &&
                    !cpu_home_owner_skip_enabled &&
                    !cpu_home_diagnostic_launch_enabled) {
                    if (FLAGS_coop_packet_overlap_merge) {
                        LOG("[COOP-DECISION] seq=%lu round=%u mode=hybrid split_mode=%s policy=cpu_home_source_ownership cpu_sources=0 gpu_frontier_vertices=unknown gpu_segments=unknown active_gpu_segments=unknown reason=cpu_home_packet_overlap_merge_gpu_authoritative_no_skip\n",
                            static_cast<unsigned long>(coop_seq),
                            coop_round,
                            split_mode_name);
                        ExecutePolicy_Converge_PacketOverlapMerge(algo_variant,
                                                                  coop_seq,
                                                                  coop_round,
                                                                  split_mode_name);
                        return;
                    }
                    if (FLAGS_coop_packet_production_merge) {
                        LOG("[COOP-DECISION] seq=%lu round=%u mode=hybrid split_mode=%s policy=cpu_home_source_ownership cpu_sources=0 gpu_frontier_vertices=unknown gpu_segments=unknown active_gpu_segments=unknown reason=cpu_home_packet_production_merge_gpu_authoritative_no_skip\n",
                            static_cast<unsigned long>(coop_seq),
                            coop_round,
                            split_mode_name);
                        ExecutePolicy_Converge_PacketProductionMerge(algo_variant,
                                                                     coop_seq,
                                                                     coop_round,
                                                                     split_mode_name);
                        return;
                    }
                    if (FLAGS_coop_packet_dry_run) {
                        LOG("[COOP-DECISION] seq=%lu round=%u mode=hybrid split_mode=%s policy=cpu_home_source_ownership cpu_sources=0 gpu_frontier_vertices=unknown gpu_segments=unknown active_gpu_segments=unknown reason=cpu_home_packet_dry_run_gpu_only_with_cpu_proposal_quality_probe\n",
                            static_cast<unsigned long>(coop_seq),
                            coop_round,
                            split_mode_name);
                        ExecutePolicy_Converge_PacketDryRun(algo_variant,
                                                            coop_seq,
                                                            coop_round,
                                                            split_mode_name);
                        return;
                    }
                    if (FLAGS_coop_overlap_probe) {
                        LOG("[COOP-DECISION] seq=%lu round=%u mode=hybrid split_mode=%s policy=cpu_home_source_ownership cpu_sources=0 gpu_frontier_vertices=unknown gpu_segments=unknown active_gpu_segments=unknown reason=cpu_home_overlap_probe_gpu_only_with_cpu_readonly_probe\n",
                            static_cast<unsigned long>(coop_seq),
                            coop_round,
                            split_mode_name);
                        ExecutePolicy_Converge_OverlapProbe(algo_variant,
                                                            coop_seq,
                                                            coop_round,
                                                            split_mode_name);
                        return;
                    }
                    LOG("[COOP-DECISION] seq=%lu round=%u mode=hybrid split_mode=%s policy=cpu_home_source_ownership cpu_sources=0 gpu_frontier_vertices=unknown gpu_segments=unknown active_gpu_segments=unknown reason=cpu_home_safe_gpu_only_default\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        split_mode_name);
                    ExecutePolicy_Converge(algo_variant);
                    return;
                }

                CoopRoundStats stats;
                {
                    Stopwatch sw_phase(true);
                    CollectCoopRoundStats(stats);
                    sw_phase.stop();
                    stats.collect_stats_ms += sw_phase.ms();
                }
                {
                    Stopwatch sw_phase(true);
                    ResetCoopRoundBuffers();
                    sw_phase.stop();
                    stats.reset_buffers_ms += sw_phase.ms();
                }
                if (cpu_home_mode) {
                    DrainCpuHomeBoundaryQueue(stats);
                }
                {
                    Stopwatch sw_phase(true);
                    if (cpu_home_mode) {
                        SelectCpuHomeSourcesForRound(stats);
                    } else {
                        SelectCpuSourcesForRound(stats);
                    }
                    sw_phase.stop();
                    stats.source_select_ms += sw_phase.ms();
                }

                {
                    Stopwatch sw_phase(true);
                    if (!cpu_home_mode || cpu_home_owner_skip_enabled) {
                        MarkCpuSourcesForGpuSkip(stats);
                    }
                    sw_phase.stop();
                    stats.owner_mark_ms += sw_phase.ms();
                }

                if (cpu_home_mode && m_coop_cpu_source_candidates.empty()) {
                    LOG("[COOP-DECISION] seq=%lu round=%u mode=hybrid split_mode=%s policy=cpu_home_source_ownership cpu_sources=0 gpu_frontier_vertices=%lu gpu_segments=%u active_gpu_segments=unknown reason=no_active_cpu_home_sources_round_continues\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        split_mode_name,
                        stats.gpu_frontier_vertices,
                        stats.gpu_segments);
                }

                stats.cpu_segments = 0;
                stats.gpu_segments = 0;
                std::vector<index_t> active_gpu_segments;
                active_gpu_segments.reserve(FLAGS_SEGMENT);
                for (index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++) {
                    const index_t stream_id = seg_idx % FLAGS_n_stream;
                    const uint64_t active_count = graph_datum.m_wl_array_in_seg[seg_idx].GetCount(stream[stream_id]);
                    if (active_count > 0) {
                        stats.gpu_segments++;
                        if (algo_variant[seg_idx] == AlgoVariant::Zero_Copy) {
                            active_gpu_segments.push_back(seg_idx);
                        }
                    }
                    stats.gpu_frontier_vertices += active_count;
                }
                stats.active_gpu_segments = static_cast<uint32_t>(active_gpu_segments.size());

                LOG("[COOP-STATS] seq=%lu round=%u split_mode=%s active_vertices=%lu cpu_frontier_vertices=pending gpu_frontier_vertices=%lu gpu_active_edges=unknown d2h_frontier_bytes=%lu d2h_frontier_ms=%f\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    split_mode_name,
                    stats.active_vertices,
                    stats.gpu_frontier_vertices,
                    stats.d2h_frontier_bytes,
                    stats.d2h_frontier_ms);
                LOG("[COOP-DECISION] seq=%lu round=%u mode=hybrid split_mode=%s policy=%s cpu_sources=%lu gpu_frontier_vertices=%lu gpu_segments=%u active_gpu_segments=%u reason=%s\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    split_mode_name,
                    cpu_home_mode ? "cpu_home_source_ownership" : "source_level",
                    static_cast<uint64_t>(m_coop_cpu_source_candidates.size()),
                    stats.gpu_frontier_vertices,
                    stats.gpu_segments,
                    stats.active_gpu_segments,
                    FLAGS_coop_cpu_dry_run ? "dry_run_gpu_owns_all_sources" :
                    (m_coop_cpu_source_candidates.empty()
                         ? (cpu_home_mode ? "no_active_cpu_home_sources" : "gpu_only_low_expected_benefit")
                         : (cpu_home_mode ? "active_cpu_home_sources" : "source_level_cpu_candidates")));
                LOG("[COOP-SPLIT] seq=%lu round=%u split_mode=%s active_sources=%lu cpu_sources=%lu gpu_sources_est=%lu cpu_active_degree_sum=%lu cpu_cached_sources=%lu cpu_non_cached_sources=%lu min_degree=%d max_cpu_sources=%d home_min_degree=%d home_max_sources=%d\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    split_mode_name,
                    stats.active_vertices,
                    static_cast<uint64_t>(m_coop_cpu_source_candidates.size()),
                    stats.gpu_frontier_vertices >= m_coop_cpu_source_candidates.size()
                        ? stats.gpu_frontier_vertices - m_coop_cpu_source_candidates.size()
                        : 0,
                    stats.active_degree_sum,
                    stats.cpu_cached_source_vertices,
                    stats.cpu_non_cached_source_vertices,
                    FLAGS_coop_cpu_min_degree,
                    GetCoopMaxCpuSources(),
                    FLAGS_coop_home_min_degree,
                    FLAGS_coop_home_max_sources);

                m_groute_context->segment_ct = FLAGS_SEGMENT;
                {
                    Stopwatch sw_phase(true);
                    m_coop_device_changed_vertices.ResetAsync(m_stream->cuda_stream);
                    if (cpu_home_mode) {
                        EnsureCoopGpuRelaxCounterStorage();
                        m_coop_device_gpu_to_cpu_boundary_vertices.ResetAsync(m_stream->cuda_stream);
                        m_coop_device_gpu_relax_dst_vertices.ResetAsync(m_stream->cuda_stream);
                        GROUTE_CUDA_CHECK(cudaMemsetAsync(m_coop_device_gpu_relax_success_count,
                                                          0,
                                                          sizeof(unsigned long long),
                                                          m_stream->cuda_stream));
                        GROUTE_CUDA_CHECK(cudaMemsetAsync(m_coop_device_gpu_relax_cpu_home_success_count,
                                                          0,
                                                          sizeof(unsigned long long),
                                                          m_stream->cuda_stream));
                        GROUTE_CUDA_CHECK(cudaMemsetAsync(m_coop_device_gpu_relax_dst_degree_sum,
                                                          0,
                                                          sizeof(unsigned long long),
                                                          m_stream->cuda_stream));
                        GROUTE_CUDA_CHECK(cudaMemsetAsync(m_coop_device_gpu_relax_dst_high_degree_count,
                                                          0,
                                                          sizeof(unsigned long long),
                                                          m_stream->cuda_stream));
                        GROUTE_CUDA_CHECK(cudaMemsetAsync(m_coop_device_gpu_relax_dst_high_degree_sum,
                                                          0,
                                                          sizeof(unsigned long long),
                                                          m_stream->cuda_stream));
                        GROUTE_CUDA_CHECK(cudaMemsetAsync(m_coop_device_gpu_relax_dst_batch_touched_count,
                                                          0,
                                                          sizeof(unsigned long long),
                                                          m_stream->cuda_stream));
                    }
                    m_stream->Sync();
                    sw_phase.stop();
                    stats.changed_queue_reset_ms += sw_phase.ms();
                }
                index_t stream_id;

                {
                    Stopwatch sw_phase(true);
                    GenerateCpuSSSPProposalsForSources(m_coop_cpu_proposals,
                                                       m_coop_source_commits,
                                                       stats);
                    sw_phase.stop();
                    stats.cpu_generate_wall_ms += sw_phase.ms();
                }
                if (cpu_home_mode) {
                    stats.cpu_local_edge_visits = stats.cpu_edge_visits;
                    stats.cpu_local_frontier_pushes = stats.cpu_proposals_survived;
                    stats.cpu_to_gpu_boundary_proposals = stats.cpu_proposals_survived;
                    stats.cpu_home_commit_count = m_coop_source_commits.size();
                }

                {
                    Stopwatch sw_phase(true);
                    for (const index_t seg_idx : active_gpu_segments) {
                        seg_snode = m_groute_context->seg_snode[seg_idx];
                        seg_enode = m_groute_context->seg_enode[seg_idx];
                        seg_sedge_csr = m_groute_context->seg_sedge_csr[seg_idx];
                        seg_nedges_csr = m_groute_context->seg_nedge_csr[seg_idx];
                        (void)seg_nedges_csr;
                        stream_id = seg_idx % FLAGS_n_stream;

                    const auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                    m_vcsr_dev_graph_allocator->SwitchZC();
                    zcflag = true;
                    RunSyncPushDDB_Delta(app_inst,
                                         seg_snode,
                                             seg_enode,
                                             seg_sedge_csr,
                                             seg_idx,
                                             zcflag,
                                             vcsr_graph,
                                             graph_datum,
                                             m_engine_options,
                                         stream[stream_id],
                                         m_coop_device_changed_vertices.DeviceObject(),
                                         m_coop_device_shadow_valid_flags,
                                         true,
                                         (!cpu_home_mode || cpu_home_owner_skip_enabled)
                                             ? m_coop_device_cpu_source_owner_epoch
                                             : nullptr,
                                         (!cpu_home_mode || cpu_home_owner_skip_enabled)
                                             ? m_coop_cpu_source_epoch
                                             : 0,
                                         (!cpu_home_mode || cpu_home_owner_skip_enabled)
                                             ? m_coop_device_gpu_skipped_cpu_sources
                                             : nullptr,
                                         m_coop_device_cpu_home_flags,
                                         cpu_home_mode ? m_coop_device_gpu_to_cpu_boundary_vertices.DeviceObject()
                                                       : groute::dev::Queue<index_t>(nullptr, nullptr, 0),
                                         cpu_home_mode ? m_coop_device_gpu_relax_dst_vertices.DeviceObject()
                                                       : groute::dev::Queue<index_t>(nullptr, nullptr, 0),
                                         cpu_home_mode ? m_coop_device_gpu_relax_success_count : nullptr,
                                         cpu_home_mode ? m_coop_device_gpu_relax_cpu_home_success_count : nullptr,
                                         cpu_home_mode ? m_coop_device_gpu_relax_dst_degree_sum : nullptr,
                                         cpu_home_mode ? m_coop_device_gpu_relax_dst_high_degree_count : nullptr,
                                         cpu_home_mode ? m_coop_device_gpu_relax_dst_high_degree_sum : nullptr,
                                         cpu_home_mode ? m_coop_device_gpu_relax_dst_batch_touched_count : nullptr,
                                         cpu_home_mode ? m_coop_device_batch_touched_flags : nullptr,
                                         cpu_home_mode ? static_cast<uint32_t>(std::max(FLAGS_coop_home_min_degree, 0)) : 0);
                        stats.gpu_kernel_launches++;
                    }
                    sw_phase.stop();
                    stats.gpu_launch_submit_ms += sw_phase.ms();
                }

                {
                    Stopwatch sw_phase(true);
                    for (index_t stream_idx = 0; stream_idx < FLAGS_n_stream; stream_idx++) {
                        stream[stream_idx].Sync();
                    }
                    sw_phase.stop();
                    stats.gpu_sync_ms += sw_phase.ms();
                }
                if (m_coop_device_gpu_skipped_cpu_sources != nullptr) {
                    Stopwatch sw_phase(true);
                    unsigned long long skipped = 0;
                    GROUTE_CUDA_CHECK(cudaMemcpy(&skipped,
                                                 m_coop_device_gpu_skipped_cpu_sources,
                                                 sizeof(unsigned long long),
                                                 cudaMemcpyDeviceToHost));
                    stats.gpu_skipped_cpu_sources += skipped;
                    sw_phase.stop();
                    stats.gpu_skip_counter_d2h_ms += sw_phase.ms();
                }
                if (cpu_home_mode &&
                    m_coop_device_gpu_relax_success_count != nullptr &&
                    m_coop_device_gpu_relax_cpu_home_success_count != nullptr) {
                    Stopwatch sw_phase(true);
                    unsigned long long gpu_relax_success = 0;
                    unsigned long long gpu_relax_cpu_home_success = 0;
                    unsigned long long gpu_relax_dst_degree_sum = 0;
                    unsigned long long gpu_relax_dst_high_degree_count = 0;
                    unsigned long long gpu_relax_dst_high_degree_sum = 0;
                    unsigned long long gpu_relax_dst_batch_touched_count = 0;
                    GROUTE_CUDA_CHECK(cudaMemcpy(&gpu_relax_success,
                                                 m_coop_device_gpu_relax_success_count,
                                                 sizeof(unsigned long long),
                                                 cudaMemcpyDeviceToHost));
                    GROUTE_CUDA_CHECK(cudaMemcpy(&gpu_relax_cpu_home_success,
                                                 m_coop_device_gpu_relax_cpu_home_success_count,
                                                 sizeof(unsigned long long),
                                                 cudaMemcpyDeviceToHost));
                    GROUTE_CUDA_CHECK(cudaMemcpy(&gpu_relax_dst_degree_sum,
                                                 m_coop_device_gpu_relax_dst_degree_sum,
                                                 sizeof(unsigned long long),
                                                 cudaMemcpyDeviceToHost));
                    GROUTE_CUDA_CHECK(cudaMemcpy(&gpu_relax_dst_high_degree_count,
                                                 m_coop_device_gpu_relax_dst_high_degree_count,
                                                 sizeof(unsigned long long),
                                                 cudaMemcpyDeviceToHost));
                    GROUTE_CUDA_CHECK(cudaMemcpy(&gpu_relax_dst_high_degree_sum,
                                                 m_coop_device_gpu_relax_dst_high_degree_sum,
                                                 sizeof(unsigned long long),
                                                 cudaMemcpyDeviceToHost));
                    GROUTE_CUDA_CHECK(cudaMemcpy(&gpu_relax_dst_batch_touched_count,
                                                 m_coop_device_gpu_relax_dst_batch_touched_count,
                                                 sizeof(unsigned long long),
                                                 cudaMemcpyDeviceToHost));
                    stats.gpu_relax_success = gpu_relax_success;
                    stats.gpu_relax_cpu_home_success = gpu_relax_cpu_home_success;
                    stats.gpu_relax_dst_degree_sum = gpu_relax_dst_degree_sum;
                    stats.gpu_relax_dst_high_degree_count = gpu_relax_dst_high_degree_count;
                    stats.gpu_relax_dst_high_degree_sum = gpu_relax_dst_high_degree_sum;
                    stats.gpu_relax_dst_batch_touched_count = gpu_relax_dst_batch_touched_count;
                    sw_phase.stop();
                    stats.gpu_skip_counter_d2h_ms += sw_phase.ms();
                    CollectGpuRelaxDstUniqueStats(stats);
                }

                if (!cpu_home_mode || cpu_home_owner_skip_enabled) {
                    Stopwatch sw_phase(true);
                    MergeCpuSSSPProposals(m_coop_cpu_proposals,
                                          m_coop_source_commits,
                                          stats,
                                          m_coop_device_changed_vertices.DeviceObject());
                    sw_phase.stop();
                    stats.merge_wall_ms += sw_phase.ms();
                } else {
                    stats.cpu_proposals += m_coop_cpu_proposals.size();
                }
                if (cpu_home_mode) {
                    stats.cpu_local_relax_success = stats.cpu_proposals_success;
                    stats.cpu_to_gpu_boundary_success = stats.cpu_proposals_success;
                }
                const uint64_t feedback_min_success_per_mille =
                    static_cast<uint64_t>(std::max(FLAGS_coop_home_feedback_min_success_per_mille, 0));
                if (cpu_home_mode &&
                    m_coop_cpu_home_batch_enabled &&
                    feedback_min_success_per_mille > 0 &&
                    stats.cpu_proposals_survived > 0 &&
                    stats.gpu_relax_cpu_home_success == 0 &&
                    stats.cpu_proposals_success * 1000ULL <
                        stats.cpu_proposals_survived * feedback_min_success_per_mille) {
                    m_coop_cpu_home_batch_enabled = false;
                    m_coop_cpu_home_injected_sources.clear();
                    m_coop_cpu_home_injected_edges_est = 0;
                    LOG("[COOP-HOME-FEEDBACK] seq=%lu round=%u action=disable_cpu_home_for_batch reason=low_cpu_success_no_gpu_to_cpu_boundary cpu_success=%lu cpu_proposals_survived=%lu gpu_relax_cpu_home_success=%lu threshold_success_per_mille=%lu\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        stats.cpu_proposals_success,
                        stats.cpu_proposals_survived,
                        stats.gpu_relax_cpu_home_success,
                        static_cast<unsigned long>(feedback_min_success_per_mille));
                }
                {
                    Stopwatch sw_phase(true);
                    RefreshCoopShadowFromChangedQueue(stats);
                    sw_phase.stop();
                    stats.shadow_refresh_wall_ms += sw_phase.ms();
                }
                {
                    Stopwatch sw_phase(true);
                    ApplyCpuSourceCommitsToShadow(m_coop_source_commits);
                    sw_phase.stop();
                    stats.shadow_apply_ms += sw_phase.ms();
                }

                LOG("[COOP-CPU] seq=%lu round=%u frontier_vertices=%lu expanded_vertices=%lu active_degree_sum=%lu edge_visits=%lu proposals=%lu proposal_generated=%lu proposal_survived=%lu proposal_compressed=%lu proposal_success=%lu unique_dst=%lu gpu_skipped_cpu_sources=%lu min_degree=%d state_d2h_bytes=%lu state_d2h_ms=%f frontier_d2h_bytes=%lu frontier_d2h_ms=%f cpu_ms=%f proposal_compress_ms=%f allocation_ms=%f host_pma_only=true host_pma_edge_visits=%lu cached_source_vertices=%lu non_cached_source_vertices=%lu cached_edges=%lu non_cached_edges=%lu cache_edge_reads=0 compression_enabled=%d\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    stats.cpu_frontier_vertices,
                    stats.cpu_expanded_vertices,
                    stats.active_degree_sum,
                    stats.cpu_edge_visits,
                    stats.cpu_proposals,
                    stats.cpu_proposals_generated,
                    stats.cpu_proposals_survived,
                    stats.cpu_proposals_compressed,
                    stats.cpu_proposals_success,
                    stats.cpu_unique_dst,
                    stats.gpu_skipped_cpu_sources,
                    FLAGS_coop_cpu_min_degree,
                    stats.state_d2h_bytes,
                    stats.state_d2h_ms,
                    stats.d2h_frontier_bytes,
                    stats.d2h_frontier_ms,
                    stats.cpu_ms,
                    stats.proposal_compress_ms,
                    stats.allocation_ms,
                    stats.cpu_host_pma_edge_visits,
                    stats.cpu_cached_source_vertices,
                    stats.cpu_non_cached_source_vertices,
                    stats.cpu_cached_edges,
                    stats.cpu_non_cached_edges,
                    FLAGS_coop_compress_proposals ? 1 : 0);
                LOG("[COOP-MERGE] seq=%lu round=%u proposals=%lu proposal_capacity=%lu commit_capacity=%lu h2d_bytes=%lu h2d_ms=%f merge_kernel_ms=%f allocation_ms=%f source_commits=%lu\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    stats.cpu_proposals,
                    static_cast<uint64_t>(m_coop_device_proposal_capacity),
                    static_cast<uint64_t>(m_coop_device_commit_capacity),
                    stats.h2d_proposal_bytes,
                    stats.h2d_proposal_ms,
                    stats.merge_ms,
                    stats.allocation_ms,
                    m_coop_source_commits.size());
                LOG("[COOP-SHADOW] seq=%lu round=%u hits=%lu misses=%lu dirty_vertices=%lu invalidated_vertices=%lu dirty_queue_d2h_bytes=%lu dirty_queue_d2h_ms=%f delta_state_d2h_bytes=%lu delta_state_d2h_ms=%f state_request_h2d_bytes=%lu state_request_h2d_ms=%f gpu_dirty_unknown_next=0\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    stats.shadow_hits,
                    stats.shadow_misses,
                    stats.shadow_dirty_vertices,
                    stats.shadow_invalidated_vertices,
                    stats.dirty_queue_d2h_bytes,
                    stats.dirty_queue_d2h_ms,
                    stats.delta_state_d2h_bytes,
                    stats.delta_state_d2h_ms,
                    stats.state_request_h2d_bytes,
                    stats.state_request_h2d_ms);
                if (cpu_home_mode) {
                    LOG("[COOP-HOME] seq=%lu round=%u cpu_home_sources=%lu gpu_home_sources=%lu cpu_home_edges_est=%lu cpu_home_active_sources=%lu cpu_home_injected_sources=%lu gpu_home_active_sources=%lu policy=%s min_degree=%d max_sources=%d\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        stats.cpu_home_sources,
                        stats.gpu_home_sources,
                        stats.cpu_home_edges_est,
                        stats.cpu_home_active_sources,
                        stats.cpu_home_injected_sources,
                        stats.gpu_home_active_sources,
                        FLAGS_coop_home_policy.c_str(),
                        FLAGS_coop_home_min_degree,
                        FLAGS_coop_home_max_sources);
                    LOG("[COOP-CPU-HOME] seq=%lu round=%u cpu_local_edge_visits=%lu cpu_local_relax_success=%lu cpu_local_frontier_pushes=%lu cpu_to_gpu_boundary_proposals=%lu cpu_to_gpu_boundary_success=%lu cpu_home_commit_count=%lu phase=8A_boundary_dst_mvp\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        stats.cpu_local_edge_visits,
                        stats.cpu_local_relax_success,
                        stats.cpu_local_frontier_pushes,
                        stats.cpu_to_gpu_boundary_proposals,
                        stats.cpu_to_gpu_boundary_success,
                        stats.cpu_home_commit_count);
                    LOG("[COOP-BOUNDARY] seq=%lu round=%u gpu_relax_success=%lu gpu_relax_cpu_home_success=%lu gpu_to_cpu_boundary_items=%lu gpu_to_cpu_boundary_bytes=%lu gpu_to_cpu_boundary_unique=%lu gpu_to_cpu_boundary_d2h_ms=%f full_frontier_d2h_bytes=%lu full_frontier_d2h_ms=%f note=phase8_boundary_queue_mvp\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        stats.gpu_relax_success,
                        stats.gpu_relax_cpu_home_success,
                        stats.gpu_to_cpu_boundary_items,
                        stats.gpu_to_cpu_boundary_bytes,
                        stats.gpu_to_cpu_boundary_unique,
                        stats.gpu_to_cpu_boundary_d2h_ms,
                        stats.full_frontier_d2h_bytes,
                        stats.full_frontier_d2h_ms);
                    LOG("[COOP-DST-DIAG] seq=%lu round=%u gpu_relax_success=%lu gpu_relax_dst_degree_sum=%lu gpu_relax_dst_high_degree_count=%lu gpu_relax_dst_high_degree_sum=%lu gpu_relax_dst_batch_touched_count=%lu gpu_relax_cpu_home_success=%lu high_degree_threshold=%u\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        stats.gpu_relax_success,
                        stats.gpu_relax_dst_degree_sum,
                        stats.gpu_relax_dst_high_degree_count,
                        stats.gpu_relax_dst_high_degree_sum,
                        stats.gpu_relax_dst_batch_touched_count,
                        stats.gpu_relax_cpu_home_success,
                        static_cast<uint32_t>(std::max(FLAGS_coop_home_min_degree, 0)));
                    LOG("[COOP-DST-UNIQUE] seq=%lu round=%u queue_items=%lu unique_dst=%lu unique_dst_degree_sum=%lu unique_dst_ge32_count=%lu unique_dst_ge32_sum=%lu unique_dst_ge128_count=%lu unique_dst_ge128_sum=%lu unique_dst_ge512_count=%lu unique_dst_ge512_sum=%lu unique_dst_ge1024_count=%lu unique_dst_ge1024_sum=%lu unique_dst_batch_touched_count=%lu unique_dst_cpu_home_count=%lu queue_bytes=%lu queue_d2h_ms=%f note=diagnostic_only_no_scheduling_change\n",
                        static_cast<unsigned long>(coop_seq),
                        coop_round,
                        stats.gpu_relax_dst_queue_items,
                        stats.gpu_relax_unique_dst,
                        stats.gpu_relax_unique_dst_degree_sum,
                        stats.gpu_relax_unique_dst_ge32_count,
                        stats.gpu_relax_unique_dst_ge32_sum,
                        stats.gpu_relax_unique_dst_ge128_count,
                        stats.gpu_relax_unique_dst_ge128_sum,
                        stats.gpu_relax_unique_dst_ge512_count,
                        stats.gpu_relax_unique_dst_ge512_sum,
                        stats.gpu_relax_unique_dst_ge1024_count,
                        stats.gpu_relax_unique_dst_ge1024_sum,
                        stats.gpu_relax_unique_dst_batch_touched_count,
                        stats.gpu_relax_unique_dst_cpu_home_count,
                        stats.gpu_relax_dst_queue_bytes,
                        stats.gpu_relax_dst_queue_d2h_ms);
                }

                {
                    Stopwatch sw_phase(true);
                    PostComputationBW(&stats);
                    sw_phase.stop();
                    stats.post_bw_ms += sw_phase.ms();
                }
                sw_round.stop();
                stats.round_wall_ms += sw_round.ms();
                const double accounted_ms =
                    stats.collect_stats_ms +
                    stats.reset_buffers_ms +
                    stats.source_select_ms +
                    stats.owner_mark_ms +
                    stats.changed_queue_reset_ms +
                    stats.cpu_generate_wall_ms +
                    stats.gpu_launch_submit_ms +
                    stats.gpu_sync_ms +
                    stats.gpu_skip_counter_d2h_ms +
                    stats.merge_wall_ms +
                    stats.shadow_refresh_wall_ms +
                    stats.shadow_apply_ms +
                    stats.post_bw_ms;
                LOG("[COOP-ATTR] seq=%lu round=%u split_mode=%s round_wall_ms=%f accounted_ms=%f unaccounted_ms=%f collect_ms=%f reset_ms=%f source_select_ms=%f owner_mark_ms=%f changed_queue_reset_ms=%f cpu_generate_wall_ms=%f gpu_launch_submit_ms=%f gpu_sync_ms=%f gpu_skip_counter_d2h_ms=%f merge_wall_ms=%f shadow_refresh_wall_ms=%f shadow_apply_ms=%f post_bw_ms=%f post_bw_rebuild_worklist_ms=%f post_bw_active_count_ms=%f post_bw_queue_reset_ms=%f post_bw_other_ms=%f gpu_segments=%u active_gpu_segments=%u gpu_kernel_launches=%u success_ratio=%f compression_ratio=%f\n",
                    static_cast<unsigned long>(coop_seq),
                    coop_round,
                    split_mode_name,
                    stats.round_wall_ms,
                    accounted_ms,
                    stats.round_wall_ms - accounted_ms,
                    stats.collect_stats_ms,
                    stats.reset_buffers_ms,
                    stats.source_select_ms,
                    stats.owner_mark_ms,
                    stats.changed_queue_reset_ms,
                    stats.cpu_generate_wall_ms,
                    stats.gpu_launch_submit_ms,
                    stats.gpu_sync_ms,
                    stats.gpu_skip_counter_d2h_ms,
                    stats.merge_wall_ms,
                    stats.shadow_refresh_wall_ms,
                    stats.shadow_apply_ms,
                    stats.post_bw_ms,
                    stats.post_bw_rebuild_worklist_ms,
                    stats.post_bw_active_count_ms,
                    stats.post_bw_queue_reset_ms,
                    stats.post_bw_other_ms,
                    stats.gpu_segments,
                    stats.active_gpu_segments,
                    stats.gpu_kernel_launches,
                    stats.cpu_proposals_compressed == 0
                        ? 0.0
                        : static_cast<double>(stats.cpu_proposals_success) /
                              static_cast<double>(stats.cpu_proposals_compressed),
                    stats.cpu_proposals_survived == 0
                        ? 0.0
                        : static_cast<double>(stats.cpu_proposals_compressed) /
                              static_cast<double>(stats.cpu_proposals_survived));
            }

            void PostComputationBW_del() {
                int dev_id = 0;
                const groute::Stream &stream_seg = m_groute_context->CreateStream(dev_id);
                GraphDatum &graph_datum = *m_graph_datum;
                AppImplDeviceObject &app_inst = *m_app_inst;
                m_running_info.current_round = m_graph_datum->m_current_round.get_val_D2H();

                Stopwatch sw_unique(true);

                index_t seg_snode,seg_enode;
                index_t stream_id;
                auto &vcsr_graph = m_vcsr_dev_graph_allocator->DeviceObject();
                Stopwatch sw_rebuild(true);
                for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT; seg_idx++){
                    stream_id = seg_idx % FLAGS_n_stream;
			        seg_snode = m_groute_context->seg_snode[seg_idx];                                    // start node
			        seg_enode = m_groute_context->seg_enode[seg_idx];  
			        RebuildWorklist_del(app_inst,vcsr_graph,
                        graph_datum,
                        stream[stream_id],seg_snode,seg_enode - seg_snode,seg_idx);
                }

                for(index_t stream_idx = 0; stream_idx < FLAGS_n_stream ; stream_idx++){
                    stream[stream_idx].Sync();
                }
                sw_rebuild.stop();
                uint64_t del_act_num_node = 0;
                m_running_info.time_overhead_rebuild_worklist += sw_rebuild.ms();
                // for(index_t seg_idx = 0; seg_idx < FLAGS_SEGMENT ; seg_idx++){
                //     stream_id = seg_idx % FLAGS_n_stream;		      

		        //     index_t active_count = graph_datum.m_wl_array_in_seg[seg_idx].GetCount(stream[stream_id]);    
		        //     graph_datum.seg_active_num[seg_idx] = active_count;

		        //     m_running_info.input_active_count_seg[seg_idx] = active_count;

		        //     uint32_t work_size = active_count;
                //     del_act_num_node+=work_size;
                // }
                // std::cout<<"删除活跃顶点 "<<del_act_num_node<<std::endl;
                sw_unique.stop();
                m_running_info.time_overhead_wl_unique += sw_unique.ms();

          }

            void PostComputationBW(CoopRoundStats *coop_stats = nullptr) {
                // printf("------------PostComputationBW-----------\n");
                Stopwatch sw_post_total(true);
                int dev_id = 0;
                Stopwatch sw_post_setup(true);
                const groute::Stream &stream_seg = m_groute_context->CreateStream(dev_id);
                GraphDatum &graph_datum = *m_graph_datum;
                AppImplDeviceObject &app_inst = *m_app_inst;
                m_running_info.current_round = m_graph_datum->m_current_round.get_val_D2H();
                sw_post_setup.stop();

                Stopwatch sw_unique(true);

                index_t seg_snode,seg_enode;
                index_t stream_id;

                Stopwatch sw_rebuild(true);
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
                uint64_t act = 0;
                sw_rebuild.stop();
                m_running_info.time_overhead_rebuild_worklist += sw_rebuild.ms();
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
                sw_unique.stop();
                m_running_info.time_overhead_wl_unique += sw_unique.ms();
                if (coop_stats != nullptr) {
                    sw_post_total.stop();
                    const double rebuild_ms = sw_rebuild.ms();
                    const double active_count_ms = sw_unique.ms() > rebuild_ms
                                                       ? sw_unique.ms() - rebuild_ms
                                                       : 0.0;
                    const double queue_reset_ms = 0.0;
                    const double known_ms = rebuild_ms + active_count_ms + queue_reset_ms;
                    coop_stats->post_bw_rebuild_worklist_ms += rebuild_ms;
                    coop_stats->post_bw_active_count_ms += active_count_ms;
                    coop_stats->post_bw_queue_reset_ms += queue_reset_ms;
                    coop_stats->post_bw_other_ms += sw_post_total.ms() > known_ms
                                                        ? sw_post_total.ms() - known_ms
                                                        : sw_post_setup.ms();
                }

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
