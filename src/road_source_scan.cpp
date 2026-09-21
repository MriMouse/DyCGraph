#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <numeric>
#include <tuple>
#include <vector>

struct Candidate {
    uint32_t source, reachable, deletion_records, deletion_batches;
};
bool Better(const Candidate &a, const Candidate &b) {
    return std::make_tuple(a.deletion_batches, a.deletion_records, a.reachable, UINT32_MAX-a.source) >
           std::make_tuple(b.deletion_batches, b.deletion_records, b.reachable, UINT32_MAX-b.source);
}

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    std::ifstream graph(argv[1]), updates(argv[2]), sizes(argv[3]);
    if (!graph || !updates || !sizes) return 3;
    uint32_t u, v, maximum = 0;
    std::vector<std::pair<uint32_t,uint32_t>> edges;
    while (graph >> u >> v) { edges.emplace_back(u,v); maximum=std::max({maximum,u,v}); }
    if (!graph.eof()) return 4;
    const size_t n = size_t(maximum)+1;
    std::vector<uint64_t> offsets(n+1,0);
    for (auto edge:edges) ++offsets[edge.first+1];
    std::partial_sum(offsets.begin(),offsets.end(),offsets.begin());
    std::vector<uint32_t> destinations(edges.size());
    auto cursor=offsets;
    for (auto edge:edges) destinations[cursor[edge.first]++]=edge.second;
    edges.clear(); edges.shrink_to_fit(); cursor.clear(); cursor.shrink_to_fit();
    std::vector<uint32_t> delete_count(n,0), delete_mask(n,0);
    uint32_t adds, dels, batch=0;
    while (sizes >> adds >> dels) {
        if (batch>=32) return 5;
        uint32_t actual_add=0, actual_del=0;
        for (uint64_t i=0;i<uint64_t(adds)+dels;++i) {
            char op; uint32_t weight;
            if (!(updates>>op>>u>>v>>weight) || u>=n || v>=n) return 6;
            if (op=='d') { ++delete_count[u]; delete_mask[u]|=uint32_t(1)<<batch; ++actual_del; }
            else if (op=='a') ++actual_add;
            else return 7;
        }
        if (actual_add!=adds || actual_del!=dels) return 8;
        ++batch;
    }
    char extra;
    if (updates>>extra || !sizes.eof()) return 9;
    std::vector<uint32_t> seen(n,UINT32_MAX), queue;
    std::vector<Candidate> best;
    uint32_t max_reachable=0, max_source=0;
    uint64_t work=0;
    for (uint32_t source=0;source<n;++source) {
        if (offsets[source]==offsets[source+1]) continue;
        queue.clear(); queue.push_back(source); seen[source]=source;
        uint32_t count=0, mask=0;
        for (size_t i=0;i<queue.size();++i) {
            const auto vertex=queue[i];
            count+=delete_count[vertex]; mask|=delete_mask[vertex];
            for (auto e=offsets[vertex];e<offsets[vertex+1];++e) {
                ++work;
                const auto dst=destinations[e];
                if (seen[dst]!=source) { seen[dst]=source; queue.push_back(dst); }
            }
        }
        if (queue.size()>max_reachable) { max_reachable=queue.size(); max_source=source; }
        Candidate candidate{source,uint32_t(queue.size()),count,uint32_t(__builtin_popcount(mask))};
        if (best.size()<8 || Better(candidate,best.back())) {
            best.push_back(candidate); std::sort(best.begin(),best.end(),Better);
            if(best.size()>8) best.pop_back();
        }
        if (source%1000000==0) std::cerr<<"source="<<source<<" scanned_edges="<<work<<'\n';
    }
    std::cout<<"{\"vertices\":"<<n<<",\"edges\":"<<destinations.size()
        <<",\"max_reachable\":"<<max_reachable<<",\"max_reachable_source\":"<<max_source
        <<",\"scanned_edges\":"<<work<<",\"candidates\":[";
    for (size_t i=0;i<best.size();++i) {
        const auto &c=best[i];
        if(i) std::cout<<',';
        std::cout<<"{\"source\":"<<c.source<<",\"reachable\":"<<c.reachable
            <<",\"deletion_records\":"<<c.deletion_records<<",\"deletion_batches\":"<<c.deletion_batches<<'}';
    }
    std::cout<<"]}\n";
}
