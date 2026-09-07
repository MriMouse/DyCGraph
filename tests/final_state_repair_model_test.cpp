#include <algorithm>
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstdint>
#include <iostream>
#include <limits>
#include <queue>
#include <random>
#include <tuple>
#include <utility>
#include <vector>

namespace {

using Node = uint32_t;
using Distance = uint64_t;
constexpr Distance kInfinity = std::numeric_limits<Distance>::max() / 4;

struct Edge {
    Node source;
    Node destination;
    uint32_t weight;

    bool operator==(const Edge &other) const {
        return source == other.source && destination == other.destination &&
               weight == other.weight;
    }
};

struct State {
    std::vector<Distance> distance;
    std::vector<Node> parent;
};

uint32_t Weight(Node source, Node destination) {
    return (source + destination) % 7 + 1;
}

State Dijkstra(Node node_count, Node source, const std::vector<Edge> &edges) {
    std::vector<std::vector<Edge>> outgoing(node_count);
    for (const Edge &edge : edges) outgoing[edge.source].push_back(edge);
    State state{std::vector<Distance>(node_count, kInfinity),
                std::vector<Node>(node_count, node_count)};
    using Item = std::pair<Distance, Node>;
    std::priority_queue<Item, std::vector<Item>, std::greater<Item>> queue;
    state.distance[source] = 0;
    queue.push({0, source});
    while (!queue.empty()) {
        const auto [distance, node] = queue.top();
        queue.pop();
        if (distance != state.distance[node]) continue;
        for (const Edge &edge : outgoing[node]) {
            const Distance candidate = distance + edge.weight;
            if (candidate < state.distance[edge.destination] ||
                (candidate == state.distance[edge.destination] &&
                 node < state.parent[edge.destination])) {
                state.distance[edge.destination] = candidate;
                state.parent[edge.destination] = node;
                queue.push({candidate, edge.destination});
            }
        }
    }
    return state;
}

bool EraseOne(std::vector<Edge> &edges, const Edge &target) {
    const auto found = std::find(edges.begin(), edges.end(), target);
    if (found == edges.end()) return false;
    edges.erase(found);
    return true;
}

std::vector<Edge> ApplyDeleteThenAdd(std::vector<Edge> edges,
                                     const std::vector<Edge> &deletions,
                                     const std::vector<Edge> &additions) {
    for (const Edge &edge : deletions) EraseOne(edges, edge);
    edges.insert(edges.end(), additions.begin(), additions.end());
    return edges;
}

bool ContainsArc(const std::vector<Edge> &edges, Node source, Node destination) {
    return std::any_of(edges.begin(), edges.end(), [&](const Edge &edge) {
        return edge.source == source && edge.destination == destination;
    });
}

// I11 model: invalidate only old-tree dependencies absent from the final
// multigraph, then run one monotone closure on the final topology.  The model
// deliberately has no deletion-only fixed point.
State UnifiedFinalStateRepair(Node node_count, Node source,
                              const std::vector<Edge> &old_edges,
                              const std::vector<Edge> &deletions,
                              const std::vector<Edge> &additions) {
    const State old = Dijkstra(node_count, source, old_edges);
    const std::vector<Edge> final_edges =
        ApplyDeleteThenAdd(old_edges, deletions, additions);

    std::vector<std::vector<Node>> tree_children(node_count);
    std::vector<uint8_t> affected(node_count, 0);
    for (Node node = 0; node < node_count; ++node) {
        if (old.parent[node] < node_count) {
            tree_children[old.parent[node]].push_back(node);
            if (!ContainsArc(final_edges, old.parent[node], node)) {
                affected[node] = 1;
            }
        }
    }
    std::queue<Node> descendants;
    for (Node node = 0; node < node_count; ++node) {
        if (affected[node]) descendants.push(node);
    }
    while (!descendants.empty()) {
        const Node node = descendants.front();
        descendants.pop();
        for (const Node child : tree_children[node]) {
            if (!affected[child]) {
                affected[child] = 1;
                descendants.push(child);
            }
        }
    }

    State result = old;
    for (Node node = 0; node < node_count; ++node) {
        if (affected[node]) {
            result.distance[node] = kInfinity;
            result.parent[node] = node_count;
        }
    }

    std::vector<std::vector<Edge>> outgoing(node_count);
    for (const Edge &edge : final_edges) outgoing[edge.source].push_back(edge);
    std::queue<Node> frontier;
    std::vector<uint8_t> queued(node_count, 0);
    auto offer = [&](Node node) {
        if (!queued[node]) {
            queued[node] = 1;
            frontier.push(node);
        }
    };

    // Boundary recovery and added-edge improvement are the two complete seed
    // classes.  Edges internal to the affected set become useful after their
    // source is recovered and are handled by the same closure.
    for (const Edge &edge : final_edges) {
        if (result.distance[edge.source] == kInfinity) continue;
        if (!affected[edge.destination] &&
            std::find(additions.begin(), additions.end(), edge) == additions.end()) {
            continue;
        }
        const Distance candidate = result.distance[edge.source] + edge.weight;
        if (candidate < result.distance[edge.destination] ||
            (candidate == result.distance[edge.destination] &&
             edge.source < result.parent[edge.destination])) {
            const bool decreased = candidate < result.distance[edge.destination];
            result.distance[edge.destination] = candidate;
            result.parent[edge.destination] = edge.source;
            if (decreased) offer(edge.destination);
        }
    }
    while (!frontier.empty()) {
        const Node node = frontier.front();
        frontier.pop();
        queued[node] = 0;
        for (const Edge &edge : outgoing[node]) {
            if (result.distance[node] == kInfinity) continue;
            const Distance candidate = result.distance[node] + edge.weight;
            if (candidate < result.distance[edge.destination] ||
                (candidate == result.distance[edge.destination] &&
                 node < result.parent[edge.destination])) {
                const bool decreased = candidate < result.distance[edge.destination];
                result.distance[edge.destination] = candidate;
                result.parent[edge.destination] = node;
                if (decreased) offer(edge.destination);
            }
        }
    }
    return result;
}

void CheckCase(Node node_count, Node source, const std::vector<Edge> &old_edges,
               const std::vector<Edge> &deletions,
               const std::vector<Edge> &additions) {
    const std::vector<Edge> final_edges =
        ApplyDeleteThenAdd(old_edges, deletions, additions);
    const State expected = Dijkstra(node_count, source, final_edges);
    const State actual = UnifiedFinalStateRepair(
        node_count, source, old_edges, deletions, additions);
    assert(actual.distance == expected.distance);
    for (Node node = 0; node < node_count; ++node) {
        if (node == source || actual.distance[node] == kInfinity) continue;
        assert(actual.parent[node] < node_count);
        bool witnessed = false;
        for (const Edge &edge : final_edges) {
            if (edge.source == actual.parent[node] && edge.destination == node &&
                actual.distance[edge.source] + edge.weight == actual.distance[node]) {
                witnessed = true;
                break;
            }
        }
        assert(witnessed);
    }
}

void TestNamedCases() {
    // Deleted tree edge is re-added in the same transaction.
    CheckCase(4, 0, {{0, 1, Weight(0, 1)}, {1, 2, Weight(1, 2)}},
              {{0, 1, Weight(0, 1)}}, {{0, 1, Weight(0, 1)}});
    // One duplicate remains, so the old dependency is still valid.
    CheckCase(4, 0,
              {{0, 1, Weight(0, 1)}, {0, 1, Weight(0, 1)},
               {1, 2, Weight(1, 2)}},
              {{0, 1, Weight(0, 1)}}, {});
    // Alternative tight predecessor and an added shortcut crossing domains.
    CheckCase(6, 0,
              {{0, 1, 1}, {0, 2, 1}, {1, 3, 2}, {2, 3, 2}, {3, 4, 2}},
              {{1, 3, 2}}, {{2, 5, 1}, {5, 4, 1}});
    // Added edge starts inside an invalidated subtree and becomes useful only
    // after boundary recovery.
    CheckCase(6, 0,
              {{0, 1, 1}, {1, 2, 1}, {2, 3, 1}, {0, 4, 5}, {4, 2, 5}},
              {{1, 2, 1}}, {{2, 5, 1}, {4, 2, 1}});
    CheckCase(3, 0, {{0, 1, 1}}, {}, {});
    CheckCase(3, 0, {{0, 1, 1}}, {{0, 1, 1}}, {});
    CheckCase(3, 0, {{0, 1, 1}}, {}, {{1, 2, 1}});
}

void TestRandomCounterexampleSearch() {
    std::mt19937 generator(0x11f1a1u);
    constexpr Node kNodes = 8;
    for (uint32_t trial = 0; trial < 20000; ++trial) {
        std::vector<Edge> old_edges;
        for (Node source = 0; source < kNodes; ++source) {
            for (Node destination = 0; destination < kNodes; ++destination) {
                if (source == destination || generator() % 5 != 0) continue;
                old_edges.push_back({source, destination, Weight(source, destination)});
                if (generator() % 11 == 0) old_edges.push_back(old_edges.back());
            }
        }
        std::vector<Edge> deletions;
        for (const Edge &edge : old_edges) {
            if (generator() % 13 == 0) deletions.push_back(edge);
        }
        std::vector<Edge> additions;
        const uint32_t addition_count = generator() % 5;
        for (uint32_t i = 0; i < addition_count; ++i) {
            Node source = generator() % kNodes;
            Node destination = generator() % kNodes;
            if (source == destination) destination = (destination + 1) % kNodes;
            additions.push_back({source, destination, Weight(source, destination)});
        }
        // Regularly exercise delete-then-readd and missing delete semantics.
        if (!deletions.empty() && generator() % 3 == 0) {
            additions.push_back(deletions.front());
        }
        if (generator() % 7 == 0) {
            deletions.push_back({0, kNodes - 1, Weight(0, kNodes - 1)});
        }
        CheckCase(kNodes, 0, old_edges, deletions, additions);
    }
}

}  // namespace

int main() {
    TestNamedCases();
    TestRandomCounterexampleSearch();
    std::cout << "final_state_repair_model_test: passed trials=20000\n";
    return 0;
}
