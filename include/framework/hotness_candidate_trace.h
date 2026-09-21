#ifndef SEPGRAPH_HOTNESS_CANDIDATE_TRACE_H
#define SEPGRAPH_HOTNESS_CANDIDATE_TRACE_H

#include <cstdint>
#include <istream>
#include <fstream>
#include <string>
#include <vector>
#include <ostream>
#include <stdexcept>
#include <type_traits>

namespace sepgraph {
namespace hotness {
constexpr uint64_t kTraceMagic = 0x49313543414e4431ULL;
constexpr uint64_t kHashSeed = 14695981039346656037ULL;
constexpr uint32_t kScoreCount = 1021;
struct Change { uint32_t vertex, score, degree; };
static_assert(sizeof(Change) == 12, "Trace record must have no padding");

inline uint64_t HashRecord(uint64_t hash, uint32_t vertex, uint32_t score,
                           uint32_t degree) {
    for (uint32_t value : {vertex, score, degree}) {
        hash ^= value;
        hash *= 1099511628211ULL;
    }
    return hash;
}

template<class T> void Write(std::ostream &out, const T &value) {
    static_assert(std::is_trivially_copyable<T>::value, "binary field");
    out.write(reinterpret_cast<const char *>(&value), sizeof(value));
    if (!out) throw std::runtime_error("Cannot write I15 trace");
}
template<class T> T Read(std::istream &in) {
    T value;
    in.read(reinterpret_cast<char *>(&value), sizeof(value));
    if (!in) throw std::runtime_error("Truncated I15 trace");
    return value;
}

// Diagnostic snapshot differencing, not GPU event capture. The sorted device
// output supplies independent order/prefix oracles for an offline index.
class TraceWriter {
public:
    void Sample(const std::string &path, int32_t batch, uint64_t capacity,
                const std::vector<uint32_t> &ids,
                const std::vector<uint32_t> &scores,
                const std::vector<uint32_t> &degrees) {
        const uint32_t n = ids.size();
        if (ids.size() != scores.size() || ids.size() != degrees.size())
            throw std::runtime_error("I15 snapshot shape mismatch");
        const bool initial = !output_.is_open();
        if (initial) {
            if (batch != -1) throw std::runtime_error("I15 trace must start at initialization");
            output_.open(path, std::ios::binary | std::ios::trunc);
            Write(output_, kTraceMagic); Write(output_, n);
            previous_scores_.assign(n, UINT32_MAX);
            previous_degrees_.assign(n, 0);
        }
        if (batch != next_batch_++ || n != previous_scores_.size())
            throw std::runtime_error("I15 trace sample sequence mismatch");
        uint64_t order_hash = kHashSeed, desired_hash = kHashSeed, edges = 0;
        uint32_t desired = 0;
        bool within_capacity = capacity != 0;
        std::vector<Change> changes;
        if (initial) changes.reserve(n);
        for (uint32_t rank = 0; rank < n; ++rank) {
            const uint32_t id = ids[rank], score = scores[rank], degree = degrees[rank];
            if (id >= n || score >= kScoreCount || (rank &&
                (score > scores[rank - 1] ||
                 (score == scores[rank - 1] && id <= ids[rank - 1]))))
                throw std::runtime_error("I15 invalid production ordering");
            order_hash = HashRecord(order_hash, id, score, degree);
            edges += degree;
            within_capacity = within_capacity && edges < capacity;
            if (within_capacity) {
                ++desired;
                desired_hash = HashRecord(desired_hash, id, score, degree);
            }
            if (previous_scores_[id] != score || previous_degrees_[id] != degree)
                changes.push_back({id, score, degree});
            previous_scores_[id] = score;
            previous_degrees_[id] = degree;
        }
        // Production's 32-bit prefix scan has no established overflow contract.
        if (edges > UINT32_MAX) throw std::runtime_error("I15 trace exceeds production prefix domain");
        Write(output_, batch); Write(output_, capacity); Write(output_, desired);
        Write(output_, order_hash); Write(output_, desired_hash);
        Write(output_, static_cast<uint32_t>(changes.size()));
        output_.write(reinterpret_cast<const char *>(changes.data()), changes.size() * sizeof(Change));
        output_.flush();
        if (!output_) throw std::runtime_error("Cannot flush I15 trace");
        expected_count_ = desired;
    }
    void CheckCount(uint32_t actual) const {
        if (output_.is_open() && actual != expected_count_)
            throw std::runtime_error("I15 production candidate prefix mismatch");
    }
private:
    int32_t next_batch_ = -1;
    uint32_t expected_count_ = 0;
    std::ofstream output_;
    std::vector<uint32_t> previous_scores_, previous_degrees_;
};
} // namespace hotness
} // namespace sepgraph
#endif
