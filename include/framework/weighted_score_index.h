#ifndef SEPGRAPH_WEIGHTED_SCORE_INDEX_H
#define SEPGRAPH_WEIGHTED_SCORE_INDEX_H

#include <array>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>
#include <framework/hotness_candidate_trace.h>

namespace sepgraph {
namespace hotness {

// Research replay index: one intrusive degree-augmented ID treap per score.
// No production GPU state or allocator is changed by this prototype.
class WeightedScoreIndex {
    static constexpr uint32_t kNone = std::numeric_limits<uint32_t>::max();
    struct Node {
        uint64_t sum = 0;
        uint32_t left = kNone, right = kNone, count = 1, degree = 0, score = 0;
    };
public:
    WeightedScoreIndex() { roots_.fill(kNone); }

    void Initialize(const std::vector<uint32_t> &scores,
                    const std::vector<uint32_t> &degrees) {
        if (scores.size() != degrees.size() || scores.size() >= kNone)
            throw std::invalid_argument("Invalid candidate population");
        nodes_.assign(scores.size(), Node{});
        roots_.fill(kNone);
        std::array<std::vector<uint32_t>, kScoreCount> stacks;
        // Cartesian construction over ascending IDs makes initialization O(V).
        for (uint32_t v = 0; v < nodes_.size(); ++v) {
            if (scores[v] >= kScoreCount) throw std::invalid_argument("Invalid score");
            auto &node = nodes_[v];
            node.score = scores[v];
            node.degree = degrees[v];
            auto &stack = stacks[node.score];
            uint32_t left = kNone;
            while (!stack.empty() && Higher(v, stack.back())) {
                left = stack.back();
                stack.pop_back();
            }
            node.left = left;
            if (stack.empty()) roots_[node.score] = v;
            else nodes_[stack.back()].right = v;
            stack.push_back(v);
        }
        for (uint32_t root : roots_) Recount(root);
    }

    void Apply(const Change &change) {
        if (change.vertex >= nodes_.size() || change.score >= kScoreCount)
            throw std::invalid_argument("Invalid candidate change");
        auto &node = nodes_[change.vertex];
        if (node.score == change.score) {
            node.degree = change.degree;
            RefreshPath(roots_[node.score], change.vertex);
            return;
        }
        roots_[node.score] = Erase(roots_[node.score], change.vertex);
        node.left = node.right = kNone;
        node.count = 1;
        node.sum = node.degree = change.degree;
        node.score = change.score;
        roots_[node.score] = Insert(roots_[node.score], change.vertex);
    }

    uint32_t CandidateCount(uint64_t capacity) const {
        if (!capacity) return 0;
        uint32_t count = 0;
        for (int score = kScoreCount - 1; score >= 0; --score) {
            uint32_t root = roots_[score];
            if (Sum(root) < capacity) {
                capacity -= Sum(root);
                count += Count(root);
                continue;
            }
            while (root != kNone) {
                const auto &node = nodes_[root];
                if (Sum(node.left) >= capacity) {
                    root = node.left;
                    continue;
                }
                capacity -= Sum(node.left);
                count += Count(node.left);
                if (node.degree >= capacity) return count;
                capacity -= node.degree;
                ++count;
                root = node.right;
            }
        }
        return count;
    }

    template<class Visitor> void Visit(Visitor visitor) const {
        for (int score = kScoreCount - 1; score >= 0; --score)
            Walk(roots_[score], visitor);
    }
    uint64_t bytes() const { return nodes_.capacity() * sizeof(Node) + sizeof(roots_); }

private:
    // A fixed bijective integer hash gives reproducible priorities independent
    // of event order; the ID breaks the (theoretical) priority tie.
    static uint32_t Priority(uint32_t v) {
        v ^= v >> 16; v *= 0x7feb352dU;
        v ^= v >> 15; v *= 0x846ca68bU;
        return v ^ (v >> 16);
    }
    static bool Higher(uint32_t a, uint32_t b) {
        const uint32_t pa = Priority(a), pb = Priority(b);
        return pa < pb || (pa == pb && a < b);
    }
    uint64_t Sum(uint32_t v) const { return v == kNone ? 0 : nodes_[v].sum; }
    uint32_t Count(uint32_t v) const { return v == kNone ? 0 : nodes_[v].count; }
    void Pull(uint32_t v) {
        auto &node = nodes_[v];
        node.sum = Sum(node.left) + node.degree + Sum(node.right);
        node.count = Count(node.left) + 1 + Count(node.right);
    }
    void Recount(uint32_t v) {
        if (v == kNone) return;
        Recount(nodes_[v].left); Recount(nodes_[v].right); Pull(v);
    }
    void RefreshPath(uint32_t root, uint32_t v) {
        if (root != v) RefreshPath(v < root ? nodes_[root].left : nodes_[root].right, v);
        Pull(root);
    }
    uint32_t Merge(uint32_t left, uint32_t right) {
        if (left == kNone) return right;
        if (right == kNone) return left;
        if (Higher(left, right)) {
            nodes_[left].right = Merge(nodes_[left].right, right);
            Pull(left); return left;
        }
        nodes_[right].left = Merge(left, nodes_[right].left);
        Pull(right); return right;
    }
    uint32_t Erase(uint32_t root, uint32_t v) {
        if (root == v) return Merge(nodes_[root].left, nodes_[root].right);
        if (v < root) nodes_[root].left = Erase(nodes_[root].left, v);
        else nodes_[root].right = Erase(nodes_[root].right, v);
        Pull(root); return root;
    }
    void Split(uint32_t root, uint32_t v, uint32_t &left, uint32_t &right) {
        if (root == kNone) { left = right = kNone; return; }
        if (root < v) {
            left = root;
            Split(nodes_[root].right, v, nodes_[root].right, right);
        } else {
            right = root;
            Split(nodes_[root].left, v, left, nodes_[root].left);
        }
        Pull(root);
    }
    uint32_t Insert(uint32_t root, uint32_t v) {
        if (root == kNone) return v;
        if (Higher(v, root)) {
            Split(root, v, nodes_[v].left, nodes_[v].right);
            Pull(v); return v;
        }
        if (v < root) nodes_[root].left = Insert(nodes_[root].left, v);
        else nodes_[root].right = Insert(nodes_[root].right, v);
        Pull(root); return root;
    }
    template<class Visitor> void Walk(uint32_t v, Visitor &visitor) const {
        if (v == kNone) return;
        const auto &node = nodes_[v];
        Walk(node.left, visitor);
        visitor(v, node.score, node.degree);
        Walk(node.right, visitor);
    }
    std::vector<Node> nodes_;
    std::array<uint32_t, kScoreCount> roots_{};
};
} // namespace hotness
} // namespace sepgraph
#endif
