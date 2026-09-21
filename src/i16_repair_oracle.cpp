#include <framework/i16_repair_snapshot.h>
#include <nlohmann/json.hpp>
#include <chrono>
#include <functional>
#include <iostream>
#include <queue>
#include <sys/resource.h>

using Clock = std::chrono::steady_clock;
double Ms(Clock::time_point t) { return std::chrono::duration<double, std::milli>(Clock::now()-t).count(); }
void Require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
int main(int argc, char **argv) {
    try {
        Require(argc == 3, "Usage: i16_repair_oracle SNAPSHOT REPORT.json");
        auto total = Clock::now();
        const auto s = i16::Load(argv[1]);
        const double read_ms = Ms(total);
        auto setup = Clock::now();
        Require(s.nodes && s.source < s.nodes && s.affected.size() < UINT32_MAX, "Invalid graph dimensions");
        const uint32_t n = s.affected.size();
        Require(s.offsets.size() == size_t(n)+1 && s.offsets[0] == 0 &&
                s.offsets.back() == s.incoming.size() && std::is_sorted(s.offsets.begin(), s.offsets.end()), "Invalid CSR");
        Require(s.before.size() == s.after.size(), "State count mismatch");
        std::vector<uint32_t> local(s.nodes, UINT32_MAX), values(s.nodes, UINT32_MAX);
        std::vector<uint8_t> seen(s.nodes, 0);
        for (uint32_t i=0; i<n; ++i) {
            const auto v=s.affected[i];
            Require(v<s.nodes && local[v]==UINT32_MAX, "Duplicate/invalid affected ID"); local[v]=i;
        }
        uint64_t outside_changes=0;
        for (size_t i=0; i<s.before.size(); ++i) {
            const auto a=s.before[i], b=s.after[i];
            Require(a.vertex<s.nodes && !seen[a.vertex] && a.vertex==b.vertex, "Invalid state IDs");
            seen[a.vertex]=1; values[a.vertex]=a.value;
            if (local[a.vertex]==UINT32_MAX)
                outside_changes += a.value!=b.value || a.buffer!=b.buffer || a.parent!=b.parent;
            else Require(b.buffer==b.value, "Final affected buffer differs from value");
            if (a.vertex==s.source) Require(a.value==0 && b.value==0, "Source distance contract");
        }
        Require(outside_changes==0, "Repair changed an external source");
        std::vector<uint64_t> offsets(size_t(n)+1, 0);
        std::vector<uint32_t> distance(n, UINT32_MAX);
        uint64_t internal=0, boundary=0, boundary_finite=0;
        for (uint32_t i=0; i<n; ++i) {
            const auto dst=s.affected[i]; Require(seen[dst], "Missing affected state");
            distance[i]=values[dst];
            for (uint64_t e=s.offsets[i]; e<s.offsets[i+1]; ++e) {
                const auto src=s.incoming[e]; Require(src<s.nodes && seen[src], "Missing incoming source state");
                if (local[src]!=UINT32_MAX) { ++offsets[local[src]+1]; ++internal; }
                else {
                    ++boundary;
                    if (values[src]!=UINT32_MAX) {
                        ++boundary_finite;
                        const uint64_t candidate=uint64_t(values[src])+i16::Weight(src,dst);
                        if (candidate<distance[i]) distance[i]=candidate;
                    }
                }
            }
        }
        for (uint32_t i=0; i<n; ++i) offsets[i+1]+=offsets[i];
        auto cursor=offsets;
        std::vector<uint32_t> outgoing(internal);
        for (uint32_t i=0; i<n; ++i)
            for (uint64_t e=s.offsets[i]; e<s.offsets[i+1]; ++e) {
                const auto src=s.incoming[e];
                if (local[src]!=UINT32_MAX) outgoing[cursor[local[src]]++]=i;
            }
        const double setup_ms=Ms(setup);
        auto closure=Clock::now();
        using Entry=std::pair<uint32_t,uint32_t>;
        std::priority_queue<Entry,std::vector<Entry>,std::greater<Entry>> queue;
        uint64_t pushes=0,pops=0,stale=0,relax=0,improvements=0,peak=0,seeds=0;
        for (uint32_t i=0; i<n; ++i) if (distance[i]!=UINT32_MAX) { queue.push({distance[i],i}); ++pushes; ++seeds; }
        peak=queue.size();
        while (!queue.empty()) {
            const auto entry=queue.top(); queue.pop(); ++pops;
            const auto d=entry.first, u=entry.second;
            if (d!=distance[u]) { ++stale; continue; }
            for (uint64_t e=offsets[u]; e<offsets[u+1]; ++e) {
                ++relax; const auto v=outgoing[e];
                const uint64_t candidate=uint64_t(d)+i16::Weight(s.affected[u],s.affected[v]);
                if (candidate<distance[v]) {
                    distance[v]=candidate; queue.push({distance[v],v}); ++pushes; ++improvements;
                }
            }
            peak=std::max<uint64_t>(peak,queue.size());
        }
        const double closure_ms=Ms(closure);
        uint64_t mismatches=0, first=UINT32_MAX;
        for (const auto &state:s.after) if (local[state.vertex]!=UINT32_MAX && distance[local[state.vertex]]!=state.value) {
            ++mismatches; first=std::min<uint64_t>(first,state.vertex);
        }
        struct rusage usage{}; getrusage(RUSAGE_SELF,&usage);
        nlohmann::json report={{"state",mismatches?"failed":"passed"},{"batch",s.batch},
            {"affected",n},{"incoming",s.incoming.size()},{"internal",internal},{"boundary",boundary},
            {"finite_boundary_edges",boundary_finite},{"seed_vertices",seeds},{"pq_pushes",pushes},
            {"pq_pops",pops},{"stale_pops",stale},{"queue_peak",peak},{"internal_relaxations",relax},
            {"improvements",improvements},{"distance_mismatches",mismatches},{"first_mismatch",first},
            {"external_state_changes",outside_changes},{"read_ms",read_ms},{"setup_ms",setup_ms},
            {"closure_ms",closure_ms},{"service_ms",setup_ms+closure_ms},{"total_ms",Ms(total)},
            {"peak_rss_kib",usage.ru_maxrss},{"weight_rule","uint32(src+dst)%128+1"},
            {"scope","offline oracle; excludes GPU capture/transfer/scatter; not production speedup"}};
        std::ofstream out(argv[2]); out<<report.dump(2)<<'\n'; Require(bool(out),"Report write failed");
        std::cout<<report.dump()<<'\n'; return mismatches?2:0;
    } catch (const std::exception &e) { std::cerr<<e.what()<<'\n'; return 1; }
}
