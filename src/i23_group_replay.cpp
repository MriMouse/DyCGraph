// CPU mechanism probe: first real batch only, never a full SSSP result.
#include <framework/effective_update_batch.h>
#include <nlohmann/json.hpp>
#include <fstream>
#include <iostream>
#include <chrono>
using namespace sepgraph::topology;
using json = nlohmann::json;
static void Require(bool ok) { if (!ok) throw std::runtime_error("group replay mismatch"); }
int main(int argc, char** argv) {
    if (argc != 2) throw std::runtime_error("usage: i23_group_replay manifest.json");
    json m; std::ifstream manifest(argv[1]); manifest >> m;
    std::ifstream sizes(m.at("sizes").at("path").get<std::string>());
    size_t adds, dels; Require(bool(sizes >> adds >> dels));
    std::ifstream updates(m.at("updates").at("path").get<std::string>());
    TopologyMutationBatch batch;
    batch.deletions.reserve(dels); batch.additions.reserve(adds);
    for (size_t i = 0; i < adds + dels; ++i) {
        char op; uint64_t s, d, w;
        Require(bool(updates >> op >> s >> d >> w));
        Require(s < m.at("nodes").get<uint64_t>() && d < m.at("nodes").get<uint64_t>() && w == 1);
        Require(op == 'a' || op == 'd');
        (op == 'a' ? batch.additions : batch.deletions).push_back({index_t(s), index_t(d)});
    }
    Require(batch.additions.size() == adds && batch.deletions.size() == dels);
    sepgraph::concurrency::FixedWorkerPool workers(20);
    setenv("CG_BATCH_MAINTENANCE", "large", 1);
    setenv("CG_PARALLEL_SOURCE_RADIX", "0", 1);
    setenv("CG_BULK_SOURCE_GROUPS", "0", 1);
    GroupedUpdateBatch reference(batch, &workers);
    // Three bounded probes: no conclusions about full-batch throughput.
    for (int mode = 0; mode < 3; ++mode) {
        setenv("CG_PARALLEL_SOURCE_RADIX", mode == 2 ? "1" : "0", 1);
        setenv("CG_BULK_SOURCE_GROUPS", mode ? "1" : "0", 1);
        const auto start = std::chrono::steady_clock::now();
        GroupedUpdateBatch result(batch, &workers);
        const double total = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-start).count();
        Require(result.sources == reference.sources);
        for (auto phase : {UpdatePhase::Mixed, UpdatePhase::Delete, UpdatePhase::Add}) {
            Require(result.PhaseSize(phase) == reference.PhaseSize(phase));
            for (size_t i = 0; i < result.PhaseSize(phase); ++i)
                Require(result.SourceIndex(i, phase) == reference.SourceIndex(i, phase));
        }
        for (size_t i = 0; i < result.sources.size(); ++i) {
            auto a = result.View(i, UpdatePhase::Mixed), b = reference.View(i, UpdatePhase::Mixed);
            Require(a.deletions.size() == b.deletions.size() && a.additions.size() == b.additions.size());
            Require(std::equal(a.deletions.begin(), a.deletions.end(), b.deletions.begin()));
            Require(std::equal(a.additions.begin(), a.additions.end(), b.additions.begin()));
        }
        std::cout << json{{"mode", mode}, {"records", adds+dels}, {"sources", result.sources.size()},
            {"total_ms",total}, {"record_ms",result.RecordMs()}, {"sort_ms",result.SortMs()},
            {"materialize_ms",result.MaterializeMs()}, {"comparison","elementwise_passed"}} << std::endl;
    }
}
