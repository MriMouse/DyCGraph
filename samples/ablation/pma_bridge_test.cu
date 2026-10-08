#ifdef NDEBUG
#undef NDEBUG
#endif
#include <groute/graphs/csr_graph.cuh>
#include <framework/dynamic_reverse_index.h>
#include <cassert>
#include <iostream>
#include <map>
#include <numeric>
int main() {
    constexpr index_t n = 64;
    std::vector<uint64_t> rows(n+1);
    std::vector<index_t> edges;
    std::vector<std::vector<index_t>> oracle(n);
    for (index_t s=0;s<n;++s) {
        rows[s]=edges.size();
        oracle[s] = {(s+1)%n,(s+1)%n};
        edges.insert(edges.end(),oracle[s].begin(),oracle[s].end());
    }
    rows[n]=edges.size();
    groute::graphs::host::PMAGraph graph;
    graph.Bind(n,edges.size(),rows.data(),edges.data(),nullptr,nullptr);
    sepgraph::topology::SourceLocalChunkStore store(graph);
    sepgraph::runtime::DynamicReverseIndex reverse;
    reverse.Build(graph,1);
    bool saw_relocation = false;
    for (unsigned batch=0;batch<12;++batch) {
        sepgraph::topology::TopologyMutationBatch updates;
        // Duplicate and missing deletes, insertion-only hot source, and no-op.
        if (batch != 11) {
            updates.deletions={{0,1},{0,1},{0,1},{63,0},{5,6}};
            for (unsigned j=0;j<8;++j) updates.additions.push_back({0,(j+batch+2)%n});
            updates.additions.push_back({63,0});
        }
        sepgraph::topology::GroupedUpdateBatch grouped(updates);
        for (auto phase : {sepgraph::topology::UpdatePhase::Delete,sepgraph::topology::UpdatePhase::Add}) {
            const auto old = [&] { std::vector<sepgraph::topology::TopologyDescriptor> d;
                for(index_t s=0;s<n;++s)d.push_back(store.Descriptor(s));return d;}();
            store.ApplyGroupedPhase(grouped,phase,reverse);
            const auto &requests = phase==sepgraph::topology::UpdatePhase::Delete ? updates.deletions : updates.additions;
            for (const auto &e: requests) {
                if (phase==sepgraph::topology::UpdatePhase::Delete) {
                    auto it=std::find(oracle[e.source].begin(),oracle[e.source].end(),e.destination);
                    if(it!=oracle[e.source].end())oracle[e.source].erase(it);
                } else oracle[e.source].push_back(e.destination);
            }
            uint64_t total=0;
            for(index_t s=0;s<n;++s) {
                assert(store.Neighbors(s)==oracle[s]);total+=oracle[s].size();
                const auto &d=store.Descriptor(s);
                if(d.index!=old[s].index || d.slab_id!=old[s].slab_id) {
                    assert(std::binary_search(store.ChangedSources().begin(),store.ChangedSources().end(),s));
                    if(s!=0 && s!=5 && s!=63)saw_relocation=true;
                }
                const uint64_t absolute=(uint64_t(d.slab_id)<<32)|d.index;
                assert(absolute==graph.sync_vertices_[s].index);
            }
            assert(store.EdgeCount()==total);
            std::vector<index_t> destinations(n);std::iota(destinations.begin(),destinations.end(),0);
            std::vector<uint64_t> offsets;std::vector<index_t> sources;
            reverse.MaterializeIncoming(destinations,offsets,sources);
            for(index_t d=0;d<n;++d) {
                std::vector<index_t> expected;
                for(index_t s=0;s<n;++s)for(auto v:oracle[s])if(v==d)expected.push_back(s);
                expected.erase(std::unique(expected.begin(),expected.end()),expected.end());
                assert(std::vector<index_t>(sources.begin()+offsets[d],sources.begin()+offsets[d+1])==expected);
            }
        }
        assert(!store.IsPublished());store.Publish();assert(store.PublishedEpoch()==batch+1);
    }
    assert(saw_relocation);
    std::cout<<"pma_bridge_test: passed (CPU only; duplicates, no-op, relocation, reverse, epochs)\n";
}
