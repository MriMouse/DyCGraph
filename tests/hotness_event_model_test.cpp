#ifdef NDEBUG
#undef NDEBUG
#endif
#include <algorithm>
#include <array>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <map>
#include <numeric>
#include <random>
#include <set>
#include <vector>

namespace {
using Updates = std::map<uint32_t, uint32_t>;

struct Events {
    Updates increments;
    Updates reachable;
    Updates degrees;
};

struct Snapshot {
    std::vector<uint32_t> scores;
    std::vector<uint32_t> order;
    std::vector<uint32_t> desired;

    bool operator==(const Snapshot &other) const {
        return scores == other.scores && order == other.order && desired == other.desired;
    }
};

Snapshot FullSort(const std::vector<uint32_t> &scores,
                  const std::vector<uint32_t> &degrees, uint64_t capacity) {
    Snapshot result{scores, std::vector<uint32_t>(scores.size()), {}};
    std::iota(result.order.begin(), result.order.end(), 0);
    std::stable_sort(result.order.begin(), result.order.end(),
        [&](uint32_t a, uint32_t b) { return scores[a] > scores[b]; });
    uint64_t edges = 0;
    for (uint32_t vertex : result.order) {
        edges += degrees[vertex];
        // CacheCandidateCount excludes the first vertex reaching capacity.
        if (edges >= capacity) break;
        result.desired.push_back(vertex);
    }
    return result;
}

// Dense four-byte window oracle, matching score-before-reset ordering.
class DenseOracle {
public:
    explicit DenseOracle(const std::vector<uint32_t> &degrees)
        : windows_(degrees.size()), reachable_(degrees.size(), 1), degrees_(degrees) {}

    Snapshot Sample(const Events &events, uint64_t capacity) {
        for (const auto &entry : events.increments)
            windows_.at(entry.first)[0] = static_cast<uint8_t>(
                windows_.at(entry.first)[0] + entry.second);
        for (const auto &entry : events.reachable) reachable_.at(entry.first) = entry.second;
        for (const auto &entry : events.degrees) degrees_.at(entry.first) = entry.second;
        std::vector<uint32_t> scores(windows_.size());
        for (size_t v = 0; v < windows_.size(); ++v) {
            const auto &h = windows_[v];
            scores[v] = reachable_[v] ? h[0] + h[1] + h[2] + h[3] : 0;
        }
        const auto result = FullSort(scores, degrees_, capacity);
        for (auto &h : windows_) h = {{0, h[0], h[1], h[2]}};
        return result;
    }

private:
    std::vector<std::array<uint8_t, 4>> windows_;
    std::vector<uint32_t> reachable_, degrees_;
};

// Event sufficiency model only; full output/sorting below is not a runtime index.
class EventReplay {
public:
    explicit EventReplay(const std::vector<uint32_t> &degrees)
        : sums_(degrees.size()), scores_(degrees.size()),
          reachable_(degrees.size(), 1), degrees_(degrees) {}

    Snapshot Sample(const Events &events, uint64_t capacity) {
        dirty.clear();
        auto &expired = windows_[sample_++ % windows_.size()];
        for (const auto &entry : expired) {
            sums_.at(entry.first) -= entry.second;
            dirty.insert(entry.first);
        }
        expired.clear();
        for (const auto &entry : events.increments) {
            const uint8_t count = static_cast<uint8_t>(entry.second);
            if (count != 0) expired.emplace(entry.first, count);
            sums_.at(entry.first) += count;
            // An event that wraps to zero is still an observed counter write.
            dirty.insert(entry.first);
        }
        for (const auto &entry : events.reachable) {
            reachable_.at(entry.first) = entry.second;
            dirty.insert(entry.first);
        }
        for (const auto &entry : events.degrees) {
            degrees_.at(entry.first) = entry.second;
            dirty.insert(entry.first);
        }
        for (uint32_t vertex : dirty)
            scores_[vertex] = reachable_[vertex] ? sums_[vertex] : 0;
        return FullSort(scores_, degrees_, capacity);
    }

    std::set<uint32_t> dirty;

private:
    size_t sample_ = 0;
    std::array<std::map<uint32_t, uint8_t>, 4> windows_;
    std::vector<uint32_t> sums_, scores_, reachable_, degrees_;
};

void DirectedCases() {
    DenseOracle oracle({0, 3, 2, 1, 0});
    EventReplay replay({0, 3, 2, 1, 0});
    auto sample = [&](const Events &events, uint64_t capacity) {
        auto expected = oracle.Sample(events, capacity);
        assert(replay.Sample(events, capacity) == expected);
        return expected;
    };
    auto initial = sample({{{1, 255}, {2, 256}, {3, 257}}, {}, {}}, 7);
    assert(initial.scores == (std::vector<uint32_t>{0, 255, 0, 1, 0}));
    assert(initial.order == (std::vector<uint32_t>{1, 3, 0, 2, 4}));
    assert(replay.dirty.count(2) == 1);
    // Masking does not erase history; unmasking needs no new expansion.
    assert(sample({{}, {{1, 0}}, {}}, 7).scores[1] == 0);
    assert(sample({{}, {{1, 1}}, {}}, 7).scores[1] == 255);
    // Degree-only changes affect the prefix without changing score or rank.
    auto changed = sample({{}, {}, {{1, 7}}}, 7);
    assert(changed.order == initial.order && changed.desired.empty());
    assert(replay.dirty == (std::set<uint32_t>{1}));
    // Initial sample (-1) expires at sample 4 (batch 3), even with no writes.
    auto expired = sample({}, 8);
    assert(expired.scores == (std::vector<uint32_t>(5, 0)));
    assert(replay.dirty == (std::set<uint32_t>{1, 3}));
    assert(expired.order == (std::vector<uint32_t>{0, 1, 2, 3, 4}));
    assert(expired.desired == (std::vector<uint32_t>{0, 1}));

    DenseOracle max_oracle({1});
    EventReplay max_replay({1});
    for (uint32_t i = 1; i <= 4; ++i) {
        const Events events{{{0, 255}}, {}, {}};
        auto expected = max_oracle.Sample(events, 2);
        assert(max_replay.Sample(events, 2) == expected);
        assert(expected.scores[0] == i * 255);
    }
    assert(max_replay.Sample({}, 2) == max_oracle.Sample({}, 2));

    const std::vector<uint32_t> zero_scores(4, 0), degrees{0, 2, 0, 3};
    assert(FullSort(zero_scores, degrees, 0).desired.empty());
    assert(FullSort(zero_scores, degrees, 2).desired == (std::vector<uint32_t>{0}));
    assert(FullSort(zero_scores, degrees, 3).desired == (std::vector<uint32_t>{0, 1, 2}));
    assert(FullSort(zero_scores, degrees, 5).desired == (std::vector<uint32_t>{0, 1, 2}));
    assert(FullSort(zero_scores, degrees, 6).desired.size() == 4);
    assert(FullSort({}, {}, 1).desired.empty());
    assert(FullSort({0}, {0}, 1).desired == (std::vector<uint32_t>{0}));
}

void RandomHistories() {
    std::mt19937 rng(15092026);
    for (unsigned trial = 0; trial < 64; ++trial) {
        std::vector<uint32_t> degrees(31);
        for (auto &degree : degrees) degree = rng() % 20;
        DenseOracle oracle(degrees);
        EventReplay replay(degrees);
        for (unsigned batch = 0; batch < 40; ++batch) {
            Events events;
            for (uint32_t v = 0; v < degrees.size(); ++v) {
                if (batch == 0 || rng() % 11 == 0) events.increments[v] = rng() % 1025;
                if (rng() % 13 == 0) events.reachable[v] = rng() % 2;
                if (rng() % 17 == 0) events.degrees[v] = rng() % 20;
            }
            const uint64_t capacity = rng() % 401;
            assert(replay.Sample(events, capacity) == oracle.Sample(events, capacity));
        }
    }
}
} // namespace

int main() {
    DirectedCases();
    RandomHistories();
    std::cout << "I15 event contract: directed cases and 2560 snapshots passed\n";
}
