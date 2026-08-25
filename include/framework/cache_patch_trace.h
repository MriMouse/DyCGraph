#ifndef SEPGRAPH_CACHE_PATCH_TRACE_H
#define SEPGRAPH_CACHE_PATCH_TRACE_H

#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <groute/graphs/common.h>

namespace sepgraph {
namespace cache_patch {

constexpr uint64_t kTraceMagic = 0x4631434143484531ULL;

struct CandidateRecord {
    index_t vertex = 0;
    uint32_t degree = 0;

    bool operator==(const CandidateRecord &other) const {
        return vertex == other.vertex && degree == other.degree;
    }
};

struct CandidateBatch {
    uint32_t batch = 0;
    uint64_t capacity_edges = 0;
    std::vector<CandidateRecord> admitted;
};

inline std::vector<CandidateBatch> ReadCandidateTrace(const std::string &path) {
    std::ifstream input(path, std::ios::in | std::ios::binary);
    if (!input) throw std::runtime_error("cannot open cache candidate trace: " + path);
    uint64_t magic = 0;
    input.read(reinterpret_cast<char *>(&magic), sizeof(magic));
    if (!input || magic != kTraceMagic) throw std::runtime_error("invalid cache candidate trace magic");
    std::vector<CandidateBatch> batches;
    std::vector<CandidateRecord> previous;
    while (true) {
        CandidateBatch batch;
        uint64_t count = 0;
        input.read(reinterpret_cast<char *>(&batch.batch), sizeof(batch.batch));
        if (input.eof()) break;
        input.read(reinterpret_cast<char *>(&batch.capacity_edges), sizeof(batch.capacity_edges));
        input.read(reinterpret_cast<char *>(&count), sizeof(count));
        if (!input) throw std::runtime_error("truncated cache candidate trace header");
        batch.admitted.resize(count);
        for (auto &record : batch.admitted) {
            input.read(reinterpret_cast<char *>(&record.vertex), sizeof(record.vertex));
            input.read(reinterpret_cast<char *>(&record.degree), sizeof(record.degree));
            if (!input) throw std::runtime_error("truncated cache candidate trace records");
        }
        if (count == 0 && !batches.empty()) batch.admitted = previous;
        previous = batch.admitted;
        batches.push_back(std::move(batch));
    }
    return batches;
}

} // namespace cache_patch
} // namespace sepgraph

#endif // SEPGRAPH_CACHE_PATCH_TRACE_H
