#ifndef SEPGRAPH_F1_REPLAY_STATE_H
#define SEPGRAPH_F1_REPLAY_STATE_H

#include <cstdint>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

#include <groute/graphs/common.h>

namespace sepgraph {
namespace f1_replay {

constexpr uint64_t kStateMagic = 0x4631525354415445ULL; // F1RSTATE
constexpr uint32_t kStateVersion = 1;

struct StateRecord {
    index_t vertex = 0;
    uint32_t value = 0;
    index_t parent = 0;
};

struct Batch {
    uint32_t batch = 0;
    std::vector<StateRecord> input_states;
    std::vector<StateRecord> final_affected_states;
};

inline void WriteHeader(std::ostream &output) {
    output.write(reinterpret_cast<const char *>(&kStateMagic), sizeof(kStateMagic));
    output.write(reinterpret_cast<const char *>(&kStateVersion), sizeof(kStateVersion));
}

inline void WriteBatch(std::ostream &output, uint32_t batch,
                       const std::vector<StateRecord> &input_states,
                       const std::vector<StateRecord> &final_affected_states) {
    const uint64_t input_count = input_states.size();
    const uint64_t final_count = final_affected_states.size();
    output.write(reinterpret_cast<const char *>(&batch), sizeof(batch));
    output.write(reinterpret_cast<const char *>(&input_count), sizeof(input_count));
    output.write(reinterpret_cast<const char *>(&final_count), sizeof(final_count));
    output.write(reinterpret_cast<const char *>(input_states.data()),
                 sizeof(StateRecord) * input_states.size());
    output.write(reinterpret_cast<const char *>(final_affected_states.data()),
                 sizeof(StateRecord) * final_affected_states.size());
    if (!output) throw std::runtime_error("failed to write F1 replay state capture");
}

inline std::vector<Batch> ReadTrace(const std::string &path) {
    std::ifstream input(path, std::ios::in | std::ios::binary);
    if (!input) throw std::runtime_error("cannot open F1 replay state capture: " + path);
    uint64_t magic = 0;
    uint32_t version = 0;
    input.read(reinterpret_cast<char *>(&magic), sizeof(magic));
    input.read(reinterpret_cast<char *>(&version), sizeof(version));
    if (!input || magic != kStateMagic || version != kStateVersion) {
        throw std::runtime_error("unsupported F1 replay state capture");
    }
    std::vector<Batch> batches;
    while (true) {
        Batch batch;
        uint64_t input_count = 0;
        uint64_t final_count = 0;
        input.read(reinterpret_cast<char *>(&batch.batch), sizeof(batch.batch));
        if (input.eof()) break;
        input.read(reinterpret_cast<char *>(&input_count), sizeof(input_count));
        input.read(reinterpret_cast<char *>(&final_count), sizeof(final_count));
        if (!input || input_count > std::numeric_limits<size_t>::max() ||
            final_count > std::numeric_limits<size_t>::max()) {
            throw std::runtime_error("invalid F1 replay state capture count");
        }
        batch.input_states.resize(static_cast<size_t>(input_count));
        batch.final_affected_states.resize(static_cast<size_t>(final_count));
        input.read(reinterpret_cast<char *>(batch.input_states.data()),
                   sizeof(StateRecord) * batch.input_states.size());
        input.read(reinterpret_cast<char *>(batch.final_affected_states.data()),
                   sizeof(StateRecord) * batch.final_affected_states.size());
        if (!input) throw std::runtime_error("truncated F1 replay state capture");
        batches.push_back(std::move(batch));
    }
    return batches;
}

} // namespace f1_replay
} // namespace sepgraph

#endif
