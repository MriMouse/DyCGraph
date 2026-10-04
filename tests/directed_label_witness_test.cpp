#include <framework/directed_label_witness.h>
#include <algorithm>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <iostream>
#include <random>
#include <vector>

struct Reverse {
    std::vector<std::vector<uint32_t>> incoming;
    template<class F> void ForEachIncomingWhile(uint32_t v, F f) const {
        for (auto u : incoming[v]) if (!f(u)) break;
    }
};

static std::vector<uint32_t> Labels(const Reverse& graph) {
    const uint32_t n = graph.incoming.size();
    std::vector<uint32_t> labels(n);
    for (uint32_t v = 0; v < n; ++v) labels[v] = v;
    bool changed;
    do {
        changed = false;
        for (uint32_t v = 0; v < n; ++v) for (auto u : graph.incoming[v])
            if (labels[u] < labels[v]) { labels[v] = labels[u]; changed = true; }
    } while (changed);
    return labels;
}

int main() {
    // The bridge is gone: the equal-label cycle cannot prove root support.
    Reverse cycle{{{}, {2}, {1}, {2}}};
    std::vector<uint32_t> old{0, 0, 0, 0};
    sepgraph::runtime::DirectedLabelWitness disconnected(old);
    assert(!disconnected.Prove(1, cycle));
    assert(!disconnected.Prove(3, cycle));
    cycle.incoming[2].push_back(0);
    sepgraph::runtime::DirectedLabelWitness rooted(old);
    assert(rooted.Prove(3, cycle));
    assert(rooted.Prove(1, cycle));
    sepgraph::runtime::DirectedLabelWitness bounded(old, 0, 0);
    assert(!bounded.Prove(1, cycle));
    assert(bounded.Prove(0, cycle));

    // A low-ID dense SCC hides a high-ID root entrance from reverse DFS.
    // Shared forward anchors must remove that structural search trap.
    {
        Reverse trap; trap.incoming.resize(202);
        std::vector<std::vector<uint32_t>> out(202);
        auto edge = [&](uint32_t u, uint32_t v) {
            trap.incoming[v].push_back(u); out[u].push_back(v);
        };
        for (uint32_t v = 1; v < 200; ++v)
            for (uint32_t u = 1; u < 200; ++u) if (u != v) edge(u, v);
        edge(0, 200); edge(200, 1); edge(1, 201);
        std::vector<uint32_t> label(202, 0);
        auto outgoing = [&](uint32_t u, auto visit) {
            for (auto v : out[u]) if (!visit(v)) break;
        };
        sepgraph::runtime::DirectedLabelWitness reverse_only(label, 1000, 1000);
        assert(!reverse_only.Prove(201, trap));
        sepgraph::runtime::DirectedLabelWitness shared(label, 1000, 1000);
        shared.SeedRoots({201}, outgoing, 1000, 1000);
        assert(shared.Prove(201, trap));
        assert(shared.SeedEdges() <= 1000);
        // Recreate certificates after the complete cut; the SCC cannot retain
        // any proof from the preceding phase.
        out[0].clear(); trap.incoming[200].clear();
        sepgraph::runtime::DirectedLabelWitness cut(label, 1000, 1000);
        cut.SeedRoots({201}, outgoing);
        assert(!cut.Prove(201, trap));
    }

    // A wide first search followed by tiny queries must retain exact proofs
    // while resetting only entries touched by each search. This is the WK
    // shape that used to repeatedly clear a peak-sized hash bucket array.
    {
        const uint32_t width = 20000, leaves = 2000;
        Reverse wide; wide.incoming.resize(width + leaves + 2);
        std::vector<uint32_t> labels(wide.incoming.size(), 0);
        for (uint32_t u = 2; u < width + 2; ++u) wide.incoming[1].push_back(u);
        wide.incoming[2].push_back(0);
        for (uint32_t v = width + 2; v < labels.size(); ++v)
            wide.incoming[v].push_back(0);
        sepgraph::runtime::DirectedLabelWitness proof(labels);
        assert(proof.Prove(1, wide));
        for (uint32_t v = width + 2; v < labels.size(); ++v)
            assert(proof.Prove(v, wide));
        assert(proof.ResetEntries() == width + leaves);
        assert(proof.AvoidedBucketSlots() > proof.ResetEntries() * 100);
        // Disconnected equal-label vertices still cannot certify themselves.
        assert(!proof.Prove(3, wide));
    }

    // Independent fixed-point labels before/after random batch cuts. Unlimited
    // proofs must be exact; exhausted proofs must never produce false positives.
    std::mt19937 random(20260930);
    uint64_t queries = 0;
    for (int trial = 0; trial < 2000; ++trial) {
        const uint32_t n = 2 + random() % 62;
        Reverse before; before.incoming.resize(n);
        for (uint32_t v = 0; v < n; ++v) for (uint32_t u = 0; u < n; ++u)
            if (random() % 9 == 0) {
                before.incoming[v].push_back(u);
                if (random() % 5 == 0) before.incoming[v].push_back(u);
            }
        auto labels = Labels(before);
        Reverse after = before;
        for (auto& row : after.incoming)
            row.erase(std::remove_if(row.begin(), row.end(), [&](uint32_t) {
                return random() % 3 == 0;
            }), row.end());
        const auto expected = Labels(after);
        sepgraph::runtime::DirectedLabelWitness proof(labels);
        sepgraph::runtime::DirectedLabelWitness frontier(labels);
        auto outgoing = [&](uint32_t u, auto visit) {
            for (uint32_t v = 0; v < n; ++v)
                if (std::find(after.incoming[v].begin(), after.incoming[v].end(), u) != after.incoming[v].end())
                    if (!visit(v)) break;
        };
        std::vector<uint32_t> targets;
        for (uint32_t v = 0; v < n; ++v) targets.push_back(v);
        // Include truncated forward searches as well as complete certificates.
        proof.SeedRoots(targets, outgoing, random() % 100, random() % 20);
        frontier.SeedRoots(targets, outgoing, random() % 100, random() % 20);
        std::vector<uint32_t> affected;
        // All old tight deletion endpoints, after the complete batch cut.
        for (uint32_t v = 0; v < n; ++v) {
            if (labels[v] == v) continue;
            for (auto u : before.incoming[v]) {
                if (labels[u] == labels[v] &&
                    std::count(before.incoming[v].begin(), before.incoming[v].end(), u) >
                    std::count(after.incoming[v].begin(), after.incoming[v].end(), u) &&
                    !frontier.Prove(v, after)) {
                    affected.push_back(v);
                    break;
                }
            }
        }
        uint64_t forward_edges = 0;
        assert(frontier.ExpandAffected(affected, after, [&](uint32_t u, auto visit) {
            for (uint32_t v = 0; v < n; ++v)
                if (std::find(after.incoming[v].begin(), after.incoming[v].end(), u) != after.incoming[v].end())
                    if (!visit(v)) break;
        }, forward_edges));
        for (uint32_t v = 0; v < n; ++v)
            assert((std::find(affected.begin(), affected.end(), v) != affected.end()) ==
                   (labels[v] != expected[v]));
        sepgraph::runtime::DirectedLabelWitness small(labels, 17, 7);
        for (uint32_t v = 0; v < n; ++v) {
            assert(proof.Prove(v, after) == (labels[v] == expected[v]));
            assert(!small.Prove(v, after) || labels[v] == expected[v]);
            ++queries;
        }
    }
    std::cout << "directed rooted witness passed: " << queries << " randomized queries\n";
}
