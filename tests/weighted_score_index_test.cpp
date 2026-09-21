#ifdef NDEBUG
#undef NDEBUG
#endif
#include <algorithm>
#include <cassert>
#include <numeric>
#include <random>
#include <framework/weighted_score_index.h>

using namespace sepgraph::hotness;

void Check(const WeightedScoreIndex &index, const std::vector<uint32_t> &scores,
           const std::vector<uint32_t> &degrees, uint64_t capacity) {
    std::vector<uint32_t> expected(scores.size()), actual;
    std::iota(expected.begin(), expected.end(), 0);
    std::stable_sort(expected.begin(), expected.end(),
        [&](uint32_t a, uint32_t b) { return scores[a] > scores[b]; });
    index.Visit([&](uint32_t v, uint32_t score, uint32_t degree) {
        assert(score == scores.at(v) && degree == degrees.at(v));
        actual.push_back(v);
    });
    assert(actual == expected);
    uint64_t sum = 0;
    uint32_t admitted = 0;
    for (uint32_t v : expected) {
        sum += degrees[v];
        if (sum >= capacity) break;
        ++admitted;
    }
    assert(index.CandidateCount(capacity) == admitted);
}

int main() {
    WeightedScoreIndex index;
    index.Initialize({}, {});
    Check(index, {}, {}, 0); Check(index, {}, {}, 1);
    std::vector<uint32_t> scores{0, 0, 0, 0}, degrees{0, 2, 0, 3};
    index.Initialize(scores, degrees);
    for (uint64_t capacity = 0; capacity < 8; ++capacity) Check(index, scores, degrees, capacity);
    // Moving a vertex between empty/nonempty groups, including both extremes.
    for (uint32_t score : {1020, 1, 0}) {
        scores[2] = score;
        index.Apply({2, score, degrees[2]});
        for (uint64_t capacity = 0; capacity < 8; ++capacity) Check(index, scores, degrees, capacity);
    }
    degrees = {UINT32_MAX, 0, UINT32_MAX, 0};
    index.Initialize(scores, degrees);
    Check(index, scores, degrees, uint64_t{UINT32_MAX} + 1);
    Check(index, scores, degrees, uint64_t{UINT32_MAX} * 2);
    Check(index, scores, degrees, uint64_t{UINT32_MAX} * 2 + 1);
    for (const Change change : {Change{4, 0, 0}, Change{0, 1021, 0}}) {
        bool rejected = false;
        try { index.Apply(change); } catch (const std::invalid_argument &) { rejected = true; }
        assert(rejected);
    }
    std::mt19937 random(15);
    for (unsigned trial = 0; trial < 32; ++trial) {
        scores.assign(257, 0); degrees.resize(257);
        for (auto &degree : degrees) degree = random() % 8;
        index.Initialize(scores, degrees);
        for (unsigned round = 0; round < 200; ++round) {
            for (unsigned i = 0; i < 13; ++i) {
                const uint32_t v = random() % scores.size();
                scores[v] = random() % 3 == 0 ? random() % kScoreCount : 0;
                degrees[v] = random() % 8;
                index.Apply({v, scores[v], degrees[v]});
            }
            Check(index, scores, degrees, random() % 1200);
        }
    }
}
