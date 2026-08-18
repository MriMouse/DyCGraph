#include <cstdlib>
#include <vector>

#include <framework/owner_cost_planner.h>

static void Require(bool value) { if (!value) std::abort(); }

int main() {
    using namespace sepgraph::runtime;
    OwnerCostPlanner planner({100.0, 1000.0, 50.0, 2.0});
    OwnerPlanCandidate gpu{"all_gpu", {}, 0, 10000, 0, 100, 20, 0, 0, true};
    OwnerPlanCandidate low_cut{"edge_cut", {1, 0}, 800, 9200, 20, 100, 20, 800, 0, true};
    OwnerPlanCandidate high_cut{"high_cut", {1, 0}, 800, 9200, 500, 100, 20, 800, 0, true};
    auto decision = planner.Choose({gpu, low_cut});
    Require(decision.candidate == 1);
    decision = planner.Choose({gpu, high_cut});
    Require(decision.candidate == 0);
    low_cut.memory_eligible = false;
    decision = planner.Choose({gpu, low_cut});
    Require(decision.candidate == 0);

    bool rejected = false;
    try { OwnerCostPlanner invalid({0.0, 1.0, 1.0, 0.0}); }
    catch (const std::invalid_argument &) { rejected = true; }
    Require(rejected);
    return 0;
}
