// ----------------------------------------------------------------
// SEP-Graph: Finding Shortest Execution Paths for Graph Processing under a Hybrid Framework on GPU
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE
// in the root directory of this source distribution.
// ----------------------------------------------------------------
#include <functional>
#include <fstream>
#include <limits>
#include <map>
#include <framework/framework.cuh>
#include <framework/hybrid_policy.h>
#include <framework/clion_cuda.cuh>
#include <utils/cuda_utils.h>
#include "hybrid_sssp_common.h"
#include "../../include/groute/graphs/csr_graph.cuh"

DEFINE_int32(source_node,
             0, "The source node for the SSSP traversal (clamped to [0, nnodes-1])");
DEFINE_bool(sparse,
            false, "use async/push/dd + fusion for high-diameter");
DEFINE_int32(sssp_max_batches,
             10, "Maximum number of update batches processed by hybrid_sssp");
DEFINE_string(coop_mode,
              "off", "CPU-GPU cooperative execution mode for SSSP add convergence: off/hybrid");
DEFINE_string(coop_split_mode,
              "host_select", "CPU-GPU cooperative split mode for SSSP: host_select/cpu_home");
DEFINE_int32(coop_cpu_segment_limit,
             1, "Maximum number of whole frontier segments assigned to CPU in one cooperative round");
DEFINE_int32(coop_max_cpu_sources,
             -1, "Maximum number of active SSSP sources assigned to CPU in one cooperative round; -1 reuses coop_cpu_segment_limit");
DEFINE_string(coop_segment_policy,
              "first_active", "CPU segment selection policy: first_active/active_frontier/estimated_edges");
DEFINE_int32(coop_cpu_min_degree,
             0, "Only let CPU expand active SSSP sources with out-degree >= this threshold");
DEFINE_bool(coop_cpu_dry_run,
            false, "Generate CPU-side SSSP proposals for instrumentation but keep GPU owning all segments");
DEFINE_bool(coop_compress_proposals,
            true, "Compress CPU SSSP relax proposals by destination before H2D merge");
DEFINE_int32(coop_home_min_degree,
             1024, "Minimum out-degree for a source to become CPU_HOME in coop_split_mode=cpu_home");
DEFINE_int32(coop_home_max_sources,
             4096, "Maximum number of persistent CPU_HOME sources in coop_split_mode=cpu_home");
DEFINE_string(coop_home_policy,
              "update_touched_high_degree", "CPU_HOME selection policy for coop_split_mode=cpu_home");
DEFINE_int32(coop_home_min_injected_sources,
             32, "Minimum injected CPU_HOME sources required to admit cpu_home for a batch; <=0 disables this admission threshold");
DEFINE_int32(coop_home_min_injected_edges,
             50000, "Minimum estimated injected CPU_HOME edges required to admit cpu_home for a batch; <=0 disables this admission threshold");
DEFINE_int32(coop_home_feedback_min_success_per_mille,
             1, "Disable cpu_home for the rest of a batch when first-round CPU proposal success is below this per-mille threshold and no GPU->CPU boundary appears; <=0 disables this feedback gate");
DEFINE_bool(coop_home_skip_gpu_sources,
            false, "Experimental cpu_home owner-skip path: when true, GPU skips CPU_HOME sources and CPU proposals are merged; default false keeps cpu_home diagnostic/correctness-safe");
DEFINE_bool(coop_home_diagnostic_launch,
            false, "Run the cooperative delta launch for cpu_home diagnostics even when owner-skip is disabled; default false keeps safe cpu_home on the exact GPU-only convergence path");
DEFINE_bool(coop_overlap_probe,
            false, "Run a read-only CPU overlap probe during GPU convergence sync; default false");
DEFINE_int32(coop_overlap_probe_max_sources,
             512, "Maximum batch-touched sources scanned by the CPU overlap probe per convergence round");
DEFINE_int32(coop_overlap_probe_edge_budget,
             200000, "Maximum host PMA edges read by the CPU overlap probe per convergence round");
DEFINE_bool(coop_packet_dry_run,
            false, "Run a bounded CPU SSSP proposal packet dry-run during GPU convergence; default false");
DEFINE_bool(coop_packet_diagnostic_merge,
            false, "Diagnostic only: merge CPU packet proposals through the GPU merge kernel without GPU source skip; requires coop_packet_dry_run");
DEFINE_bool(coop_packet_production_merge,
            false, "Experimental production candidate: merge CPU packet proposals without pre/post dst probes and without GPU source skip; default false");
DEFINE_bool(coop_packet_overlap_merge,
            false, "Experimental Phase 10A candidate: generate/compress CPU packet while GPU delta runs, then merge still-valid proposals after the GPU barrier without GPU source skip");
DEFINE_bool(coop_packet_skip_audit,
            false, "Experimental Phase 10B audit: skip CPU-covered active-frontier packet sources in convergence delta and merge CPU proposals through GPU authoritative merge");
DEFINE_string(coop_packet_source_policy,
              "batch_touched", "CPU packet source policy: batch_touched/active_frontier");
DEFINE_int32(coop_packet_max_sources,
             256, "Maximum sources used by the CPU packet dry-run per convergence round");
DEFINE_int32(coop_packet_edge_budget,
             200000, "Maximum host PMA edges read by the CPU packet dry-run per convergence round");
DEFINE_bool(sssp_print_checksum,
            false, "Print final SSSP distance and parent checksums");
DECLARE_int32(top_ranks);
DECLARE_bool(print_ranks);
DECLARE_string(output);
DECLARE_bool(check);
DECLARE_int32(prio_delta);

namespace hybrid_sssp
{
    template<typename TValue, typename TBuffer, typename TWeight, typename...UnusedData>
    struct SSSP : sepgraph::api::AppBase<TValue, TBuffer, TWeight>
    {
        using sepgraph::api::AppBase<TValue, TBuffer, TWeight>::AccumulateBuffer;
        index_t m_source_node;

        SSSP(index_t source_node) : m_source_node(source_node)
        {
         
        }

        __forceinline__ __device__

        TValue GetInitValue(index_t node) const override
        {
            return static_cast<TValue> (IDENTITY_ELEMENT);
        }

        __forceinline__ __device__

        TBuffer GetInitBuffer(index_t node) const override 
        {
            TBuffer buffer;
            if (node == m_source_node)//source_node = 1
            {
                buffer = 0;
            }
            else
            {
                buffer = IDENTITY_ELEMENT;
            }
            return buffer;
        }

        __forceinline__ __host__ __device__
        TBuffer GetIdentityElement() const override
        {
            return IDENTITY_ELEMENT;
        }

        __forceinline__ __device__
        utils::pair<TBuffer, bool> CombineValueBufferAmend(index_t node,int *type_device,
                                                      TValue *p_value,
                                                      TBuffer *p_buffer) override
        {
           
            return utils::pair<TBuffer, bool>(*p_buffer, true);
        }
        __forceinline__ __device__
        utils::pair<TBuffer, bool> CombineValueBuffer(index_t node,
                                                      TValue *p_value,
                                                      TBuffer *p_buffer) override
        {
            TBuffer buffer = *p_buffer;
            bool schedule = false;
            if (*p_value > buffer)
            {
                *p_value = buffer;
                schedule = true;
            }
            return utils::pair<TBuffer, bool>(buffer, schedule);
        }

        // 3: if new_path==result[dst] then
        // 4: old_p=parent[dst]
        // 5: repeat
        // 6: old_p= atomicCAS(&parent[dst],src)
        // 7: until (new_path!= result[dst]||old_p==parent[dst])
        __forceinline__ __device__
        int AccumulateBuffer(index_t src,
                             index_t dst,
                            //  TValue level, //src_level
                            //  TValue *p_level, //dst_level
                             TWeight weight,
                             TValue *p_parent,
                             TBuffer *p_buffer,    //dst_buffer
                             TBuffer buffer) override   //src_buffer
        {
            // TBuffer old_buffer = *p_buffer;
            TBuffer new_buffer = buffer + weight;
            TBuffer old_buffer=atomicMin(p_buffer, buffer + weight);;
            if(new_buffer< old_buffer){
            
                TValue old_parent = *p_parent;
                do{
                    old_parent = atomicCAS(p_parent,old_parent,src);
                    
                } while (new_buffer==*p_buffer && (*p_parent) !=src);
            }
            return new_buffer < old_buffer ? 1 : 0;
        }

        __forceinline__ __device__
        int AccumulateBuffer_add(index_t src,
                             index_t dst,
                            //  TValue level, //src_level
                            //  TValue *p_level, //dst_level
                             TWeight weight,
                             TValue *p_parent, //dst_parent
                             TValue *p_buffer,    //dst_value
                             TValue *buffer) override   //src_value
        {
            TValue incoming_value_curr = *buffer;
            if(incoming_value_curr ==UINT32_MAX){
                return 0;
            }
            TValue new_buffer = incoming_value_curr + weight;
            TValue new_parent = src;
            // TValue new_level = level+1;
            TValue old_value;
            old_value = atomicMin(p_buffer, new_buffer);
            TValue old_parent = *p_parent;
        // TValue curr_buffer = *p_buffer;
            // if(new_buffer == curr_buffer){
            do{
                if(new_buffer==old_value){
                    old_parent = atomicCAS(p_parent,old_parent,src);
                }
            } while (new_buffer==old_value && old_parent !=src);
            return 1;
        }

        // __forceinline__ __device__
        // bool reduce()

        __forceinline__ __device__
        int AccumulateBuffer_del(index_t src,
                             index_t dst,
                             TValue *p_parent,
                             TBuffer *p_buffer,    //dst_buffer
                             TValue *p_value) override   //dst_value
        {
            if(*p_parent == src){
                *p_buffer = UINT32_MAX;
                *p_value = UINT32_MAX;
                *p_parent = UINT32_MAX;
                this->m_vcsr_graph.vertices_[dst].deletion = true;
            }
            return 1;
        }

        __forceinline__ __device__

        bool IsActiveNode(index_t node, TBuffer buffer,TValue value) const override
        {
            return buffer < value;
        }
        
        
        __forceinline__ __device__
        TValue sum_value(index_t node, TValue value,TBuffer buffer) const override
        {
            if(value > buffer * 2)
                return TValue(2);

            return TValue(1);
        }


        __forceinline__ __device__

        bool IsHighPriority(TBuffer current_priority, TBuffer buffer) const override
        {
            return current_priority > buffer;
        }
    };
}

struct BellmanRelaxCheckResult {
    uint64_t relaxable_edges = 0;
    index_t first_src = UINT32_MAX;
    index_t first_dst = UINT32_MAX;
    distance_t src_distance = UINT32_MAX;
    distance_t dst_distance = UINT32_MAX;
    uint64_t candidate_distance = std::numeric_limits<uint64_t>::max();
};

static BellmanRelaxCheckResult CheckBellmanRelaxed(
        const groute::graphs::host::PMAGraph &graph,
        const std::vector<distance_t> &distances) {
    BellmanRelaxCheckResult result;

    const index_t nnodes = std::min<index_t>(graph.nnodes, distances.size());
    for (index_t src = 0; src < nnodes; src++) {
        if (distances[src] == UINT32_MAX) {
            continue;
        }

        const uint64_t edge_start = graph.sync_vertices_[src].index;
        const uint64_t degree = graph.sync_vertices_[src].degree;
        for (uint64_t edge_offset = 0; edge_offset < degree; edge_offset++) {
            const index_t dst = graph.edges_[edge_start + edge_offset];
            if (dst >= distances.size()) {
                continue;
            }

            const uint64_t weight = (static_cast<uint64_t>(src) + dst) % 128 + 1;
            const uint64_t candidate = static_cast<uint64_t>(distances[src]) + weight;
            if (candidate < distances[dst]) {
                if (result.relaxable_edges == 0) {
                    result.first_src = src;
                    result.first_dst = dst;
                    result.src_distance = distances[src];
                    result.dst_distance = distances[dst];
                    result.candidate_distance = candidate;
                }
                result.relaxable_edges++;
            }
        }
    }

    return result;
}


/**
 * Δ = cw/d,
    where d is the average degree in the graph, w is the average
    edge weight, and c is the warp width (32 on our GPUs).
 * @return
 */

bool HybridSSSP()
{
    assert(UINT32_MAX == UINT_MAX);
    // typedef sepgraph::engine::Engine<distance_t, distance_t, distance_t, hybrid_sssp::SSSP, index_t> HybridEngine;
    typedef sepgraph::engine::Engine<distance_t, distance_t, distance_t, hybrid_sssp::SSSP, index_t> HybridEngine;
    HybridEngine engine(sepgraph::policy::AlgoType::TRAVERSAL_SCHEME);
    engine.LoadGraph();

    index_t source_node = min(max((index_t) 0, (index_t) FLAGS_source_node), engine.GetGraphDatum().nnodes - 1);

    sepgraph::common::EngineOptions engine_opt;


    const groute::graphs::host::PMAGraph &vcsr_graph = engine.PMAGraph();
    double weight_sum = 0;

    /**
     * We select a similar heuristic, Δ = cw/d,
        where d is the average degree in the graph, w is the average
        edge weight, and c is the warp width (32 on our GPUs)
        Link: https://people.csail.mith.edu/jshun/papers/DBGO14.pdf
     */
    // int init_prio = 32 * (weight_sum / vcsr_graph.nedges) /
    //                 (1.0 * csr_graph.nedges / csr_graph.nnodes);
    int init_prio = 32 * (weight_sum / vcsr_graph.nedges) /
                (1.0 * vcsr_graph.nedges / vcsr_graph.nnodes);

    printf("Priority delta: %u\n", init_prio);

    if (FLAGS_sparse)
    {
        engine_opt.SetFused();
        engine_opt.SetTwoLevelBasedPriority(init_prio);
        engine_opt.ForceVariant(sepgraph::common::AlgoVariant::ASYNC_PUSH_DD);
        engine_opt.SetLoadBalancing(sepgraph::common::MsgPassing::PUSH, sepgraph::common::LoadBalancing::NONE);
    }

    if (FLAGS_prio_delta > 0)
    {
        LOG("Enable priority for scale-free dataset\n");
        engine_opt.SetTwoLevelBasedPriority(FLAGS_prio_delta);
    }

    engine.SetOptions(engine_opt);
    engine.InitGraph(source_node);
    engine.Start(init_prio);
    //PrintCacheNode() are used to detect the cache is right or not.
    bool success = true;
    engine.compute_hot_vertices_sssp();
    engine.confirm_candidate_batch();
    engine.LoadCache();
    // engine.PrintCacheNode();
    engine.get_update_file();
    std::pair<index_t,index_t> local_begin;
    local_begin.first = 0; //first is add
    local_begin.second = 0; // second is del
    index_t NumOfSnapShots = 0;
    const index_t available_batches = static_cast<index_t>(engine.GetUpdateBatchCount());
    const index_t max_batches = std::min<index_t>(FLAGS_sssp_max_batches, available_batches);
    if (FLAGS_sssp_max_batches > available_batches) {
        std::cout << "[SSSP] clamp sssp_max_batches from " << FLAGS_sssp_max_batches
                  << " to available update batches " << available_batches << std::endl;
    }
    while(true){
        if(NumOfSnapShots==max_batches) break;
        std::cout<<"batch number "<<NumOfSnapShots<<std::endl;
        Stopwatch sw_paper_batch(true);
        engine.del_edge(local_begin,NumOfSnapShots);
        engine.add_edge(local_begin,NumOfSnapShots);
        engine.compute_hot_vertices_sssp();
        engine.confirm_candidate_batch();
        engine.evication_cache();
        engine.compact_cache();
        engine.LoadCache();
        sw_paper_batch.stop();
        LOG("[P0-TIMER][SSSP][batch %d] total_batch: %.3f ms\n",
            NumOfSnapShots,
            sw_paper_batch.ms());
        NumOfSnapShots+=1;
    }
    engine.GatherValue();
    engine.GatherParent();
    engine.GatherBuffer();
    const auto &distances = engine.GetGraphDatum().host_value;
    const auto &parents = engine.GetGraphDatum().host_parent;
    const auto &deltas = engine.GetGraphDatum().host_buffer;
    uint64_t reachable_count = 0;
    for (index_t node = 0; node < distances.size(); node++) {
        if (distances[node] != UINT32_MAX) {
            reachable_count++;
        }
    }

    if (FLAGS_check) {
        BellmanRelaxCheckResult bellman_result = CheckBellmanRelaxed(engine.PMAGraph(), distances);
        bool source_ok = source_node < distances.size() && distances[source_node] == 0;
        if (source_ok && bellman_result.relaxable_edges == 0) {
            LOG("[SSSP-BELLMAN-CHECK] passed reachable=%llu relaxable_edges=0\n",
                static_cast<unsigned long long>(reachable_count));
        } else {
            success = false;
            LOG("[SSSP-BELLMAN-CHECK] failed source_ok=%d relaxable_edges=%llu first_src=%u first_dst=%u src_dist=%u dst_dist=%u candidate=%llu\n",
                source_ok ? 1 : 0,
                static_cast<unsigned long long>(bellman_result.relaxable_edges),
                bellman_result.first_src,
                bellman_result.first_dst,
                bellman_result.src_distance,
                bellman_result.dst_distance,
                static_cast<unsigned long long>(bellman_result.candidate_distance));
        }
    }

    LOG("[COOP-CHECK] final_reachable=%llu checksum=%s\n",
        static_cast<unsigned long long>(reachable_count),
        FLAGS_sssp_print_checksum ? "enabled" : "disabled");

    if (FLAGS_sssp_print_checksum) {
        uint64_t distance_checksum = 1469598103934665603ull;
        uint64_t parent_checksum = 1099511628211ull;
        for (index_t node = 0; node < distances.size(); node++) {
            if (distances[node] == UINT32_MAX) {
                continue;
            }
            distance_checksum ^= static_cast<uint64_t>(node) + 0x9e3779b97f4a7c15ull +
                                 (static_cast<uint64_t>(distances[node]) << 6) +
                                 (static_cast<uint64_t>(distances[node]) >> 2);
            distance_checksum *= 1099511628211ull;
            parent_checksum ^= static_cast<uint64_t>(node) + 0x517cc1b727220a95ull +
                               (static_cast<uint64_t>(parents[node]) << 7) +
                               (static_cast<uint64_t>(parents[node]) >> 3);
            parent_checksum *= 1469598103934665603ull;
        }
        LOG("[COOP-CHECK] distance_checksum=%llu parent_checksum=%llu\n",
            static_cast<unsigned long long>(distance_checksum),
            static_cast<unsigned long long>(parent_checksum));
    }

    if (!FLAGS_output.empty()) {
        std::ofstream output(FLAGS_output, std::ios::out | std::ios::trunc);
        for (index_t node = 0; node < distances.size(); node++) {
            output << node << " " << distances[node] << " " << parents[node] << " " << deltas[node] << "\n";
        }
    }
    // std::ofstream valid("/home/hdd/yongze/datasets/quafu-3.txt",std::ios::out|std::ios::trunc);
    // if(!valid.is_open()){
    //     std::cerr << "Error: Unable to open file for writing." << std::endl;
    //     return 1;
    // }
    // for(index_t i = 0; i<vcsr_graph.nnodes; i++){
    //     uint32_t vd;
    //     if(distances[i]== UINT32_MAX){
    //          vd = INT32_MAX;
    //     }else{
    //         vd = distances[i];
    //     }
    //     // printf("v %d data %d parent %d\n",i,distances[i],parents[i]);
    //     valid<<i<<" "<<vd<<" "<<parents[i]<<std::endl;
    // } 
    
    cudaDeviceSynchronize();
    return success;
}
