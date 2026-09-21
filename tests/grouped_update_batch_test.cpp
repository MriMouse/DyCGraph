#include <framework/effective_update_batch.h>
#include <map>
#include <random>
#include <stdexcept>

using namespace sepgraph::topology;
static void Require(bool value) { if (!value) throw std::runtime_error("grouped batch ordering mismatch"); }
static void BulkBoundaryCases() {
    sepgraph::concurrency::FixedWorkerPool workers(7);
    for (int phase = 0; phase < 3; ++phase) {
        TopologyMutationBatch input;
        for (unsigned i = 0; i < 8193; ++i) {
            auto& edges = phase == 0 || (phase == 2 && i % 2) ? input.deletions : input.additions;
            edges.push_back({0xffffffffU, i % 127});
        }
        setenv("CG_BULK_SOURCE_GROUPS", "0", 1);
        GroupedUpdateBatch reference(input, &workers);
        setenv("CG_BULK_SOURCE_GROUPS", "1", 1);
        GroupedUpdateBatch candidate(input, &workers);
        Require(candidate.BulkSourceGroups());
        Require(candidate.sources == reference.sources);
        const auto a = candidate.View(0, UpdatePhase::Mixed);
        const auto b = reference.View(0, UpdatePhase::Mixed);
        Require(a.deletions.size() == b.deletions.size() && a.additions.size() == b.additions.size());
        Require(std::equal(a.deletions.begin(), a.deletions.end(), b.deletions.begin()));
        Require(std::equal(a.additions.begin(), a.additions.end(), b.additions.begin()));
        Require(candidate.PhaseSize(UpdatePhase::Delete) == reference.PhaseSize(UpdatePhase::Delete));
        Require(candidate.PhaseSize(UpdatePhase::Add) == reference.PhaseSize(UpdatePhase::Add));
    }
    setenv("CG_BULK_SOURCE_GROUPS", "bad", 1);
    bool rejected = false;
    try { GroupedUpdateBatch invalid; } catch (const std::invalid_argument&) { rejected = true; }
    Require(rejected);
    unsetenv("CG_BULK_SOURCE_GROUPS");
}
int main() {
    BulkBoundaryCases();
    sepgraph::concurrency::FixedWorkerPool workers(7);
    setenv("CG_BATCH_MAINTENANCE", "auto", 1);
    TopologyMutationBatch boundary;
    boundary.additions.resize(999999, {0, 1});
    Require(!GroupedUpdateBatch(boundary).LargeMaintenance());
    boundary.deletions.push_back({0, 1});
    Require(GroupedUpdateBatch(boundary).LargeMaintenance());
    setenv("CG_BATCH_MAINTENANCE", "large", 1);
    Require(GroupedUpdateBatch().LargeMaintenance());
    setenv("CG_BATCH_MAINTENANCE", "regular", 1);
    Require(!GroupedUpdateBatch(boundary).LargeMaintenance());
    setenv("CG_BATCH_MAINTENANCE", "invalid", 1);
    bool rejected = false;
    try { GroupedUpdateBatch invalid; } catch (const std::invalid_argument &) { rejected = true; }
    Require(rejected);
    unsetenv("CG_BATCH_MAINTENANCE");
    std::mt19937 random(20260914);
    for (const char* bulk : {"0", "1"}) {
    setenv("CG_BULK_SOURCE_GROUPS", bulk, 1);
    for (const char* mode : {"0", "1"}) {
    setenv("CG_PARALLEL_SOURCE_RADIX", mode, 1);
    for (size_t count : {0, 1, 4095, 4096, 4097, 100000}) {
        TopologyMutationBatch input;
        std::map<index_t, std::pair<std::vector<index_t>, std::vector<index_t>>> expected;
        for (size_t i = 0; i < count; ++i) {
            // Repeated full-width IDs exercise every digit and stable ordering.
            const index_t src = (random() % 127) * 0x02040801U;
            const index_t dst = random() % 31;
            if (i % 3) {
                input.deletions.push_back({src, dst});
                expected[src].first.push_back(dst);
            } else {
                input.additions.push_back({src, dst});
                expected[src].second.push_back(dst);
            }
        }
        GroupedUpdateBatch grouped(input, &workers);
        Require(grouped.ParallelSourceRadix() == (mode[0] == '1' && count >= 4096));
        Require(grouped.BulkSourceGroups() == (bulk[0] == '1' && count >= 4096));
        Require(grouped.sources.size() == expected.size());
        size_t i = 0, deletes = 0, adds = 0;
        for (const auto &entry : expected) {
            Require(grouped.sources[i] == entry.first);
            const auto both = grouped.View(i, UpdatePhase::Mixed);
            Require(both.deletions.size() == entry.second.first.size());
            Require(both.additions.size() == entry.second.second.size());
            Require(std::equal(both.deletions.begin(), both.deletions.end(), entry.second.first.begin()));
            Require(std::equal(both.additions.begin(), both.additions.end(), entry.second.second.begin()));
            Require(grouped.View(i, UpdatePhase::Add).deletions.empty());
            Require(grouped.View(i, UpdatePhase::Delete).additions.empty());
            if (!entry.second.first.empty()) Require(grouped.SourceIndex(deletes++, UpdatePhase::Delete) == i);
            if (!entry.second.second.empty()) Require(grouped.SourceIndex(adds++, UpdatePhase::Add) == i);
            ++i;
        }
        Require(grouped.PhaseSize(UpdatePhase::Delete) == deletes);
        Require(grouped.PhaseSize(UpdatePhase::Add) == adds);
    }
}
}
}
