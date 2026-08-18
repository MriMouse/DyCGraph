#include <cstdlib>
#include <stdexcept>
#include <vector>

#include <framework/exact_source_frontier.h>

using sepgraph::runtime::ExactSourceEvent;
using sepgraph::runtime::ExactSourceFrontier;

static void Require(bool condition) { if (!condition) std::abort(); }

int main() {
    ExactSourceFrontier frontier(6);
    frontier.BeginEpoch(1);
    Require(frontier.Offer({3, 1, 1}));
    Require(frontier.Offer({1, 1, 1}));
    Require(!frontier.Offer({3, 1, 1}));
    Require(frontier.Offer({3, 1, 2}));
    Require(!frontier.Offer({3, 1, 1}));
    Require(frontier.Offer({5, 1, 4}));
    const std::vector<uint32_t> degrees{0, 2, 4, 7, 0, 3};
    Require((frontier.Seal([&](index_t source) { return degrees[source]; }) ==
             std::vector<index_t>{1, 3, 5}));
    const auto metrics = frontier.Metrics();
    Require(metrics.offered_events == 6);
    Require(metrics.accepted_events == 4);
    Require(metrics.stale_or_duplicate_events == 2);
    Require(metrics.coalesced_events == 1);
    Require(metrics.unique_sources == 3);
    Require(metrics.logical_edges == 12);

    bool rejected = false;
    try { frontier.BeginEpoch(1); }
    catch (const std::logic_error &) { rejected = true; }
    Require(rejected);
    frontier.BeginEpoch(2);
    rejected = false;
    try { frontier.Offer(ExactSourceEvent{6, 2, 1}); }
    catch (const std::out_of_range &) { rejected = true; }
    Require(rejected);
    Require(frontier.Offer({0, 2, 1}));
    Require(frontier.Seal([&](index_t source) { return degrees[source]; }).size() == 1);
    Require(frontier.Metrics().logical_edges == 0);
    return 0;
}
