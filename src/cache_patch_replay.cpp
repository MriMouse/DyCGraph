#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

#include <framework/cache_patch_trace.h>

namespace {

using Record = sepgraph::cache_patch::CandidateRecord;
using Clock = std::chrono::steady_clock;

double Milliseconds(Clock::time_point begin, Clock::time_point end) {
    return std::chrono::duration<double, std::milli>(end - begin).count();
}

bool ByVertex(const Record &left, const Record &right) {
    return left.vertex < right.vertex;
}

int Run(const std::string &path) {
    std::ifstream input(path, std::ios::in | std::ios::binary);
    if (!input) throw std::runtime_error("cannot open trace: " + path);
    uint64_t magic = 0;
    input.read(reinterpret_cast<char *>(&magic), sizeof(magic));
    if (!input || magic != sepgraph::cache_patch::kTraceMagic) {
        throw std::runtime_error("invalid trace magic");
    }
    std::vector<Record> previous;
    while (true) {
        const auto read_begin = Clock::now();
        uint32_t batch = 0;
        uint64_t capacity = 0;
        uint64_t count = 0;
        input.read(reinterpret_cast<char *>(&batch), sizeof(batch));
        if (input.eof()) break;
        input.read(reinterpret_cast<char *>(&capacity), sizeof(capacity));
        input.read(reinterpret_cast<char *>(&count), sizeof(count));
        if (!input) throw std::runtime_error("truncated trace header");
        std::vector<Record> current(count);
        for (auto &record : current) {
            input.read(reinterpret_cast<char *>(&record.vertex), sizeof(record.vertex));
            input.read(reinterpret_cast<char *>(&record.degree), sizeof(record.degree));
        }
        if (!input) throw std::runtime_error("truncated trace records");
        const auto read_end = Clock::now();
        if (count == 0 && !previous.empty()) {
            const auto now = Clock::now();
            std::cout << "[F1-CACHE-PATCH] batch=" << batch
                      << " capacity_edges=" << capacity
                      << " resident_vertices=" << previous.size()
                      << " admitted=0 evicted=0 degree_changed=0 patch_records=0"
                      << " patch_edges=0 patch_bytes=0"
                      << " trace_read_ms=" << Milliseconds(read_begin, read_end)
                      << " sort_ms=0 diff_ms=" << Milliseconds(now, Clock::now()) << '\n';
            continue;
        }
        const auto sort_begin = Clock::now();
        std::sort(current.begin(), current.end(), ByVertex);
        const auto sort_end = Clock::now();
        uint64_t admitted = 0;
        uint64_t evicted = 0;
        uint64_t degree_changed = 0;
        uint64_t patch_edges = 0;
        const auto diff_begin = Clock::now();
        size_t old_index = 0;
        size_t new_index = 0;
        while (old_index < previous.size() || new_index < current.size()) {
            if (old_index == previous.size() ||
                (new_index < current.size() &&
                 current[new_index].vertex < previous[old_index].vertex)) {
                ++admitted;
                patch_edges += current[new_index].degree;
                ++new_index;
            } else if (new_index == current.size() ||
                       previous[old_index].vertex < current[new_index].vertex) {
                ++evicted;
                ++old_index;
            } else {
                if (previous[old_index].degree != current[new_index].degree) {
                    ++degree_changed;
                    patch_edges += current[new_index].degree;
                }
                ++old_index;
                ++new_index;
            }
        }
        const auto diff_end = Clock::now();
        const uint64_t patch_records = admitted + evicted + degree_changed;
        const uint64_t patch_bytes =
            patch_records * (sizeof(index_t) + sizeof(uint32_t) + sizeof(uint64_t)) +
            patch_edges * sizeof(index_t);
        std::cout << "[F1-CACHE-PATCH] batch=" << batch
                  << " capacity_edges=" << capacity
                  << " resident_vertices=" << current.size()
                  << " admitted=" << admitted
                  << " evicted=" << evicted
                  << " degree_changed=" << degree_changed
                  << " patch_records=" << patch_records
                  << " patch_edges=" << patch_edges
                  << " patch_bytes=" << patch_bytes
                  << " trace_read_ms=" << Milliseconds(read_begin, read_end)
                  << " sort_ms=" << Milliseconds(sort_begin, sort_end)
                  << " diff_ms=" << Milliseconds(diff_begin, diff_end) << '\n';
        previous.swap(current);
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: cache_patch_replay TRACE");
        return Run(argv[1]);
    } catch (const std::exception &error) {
        std::cerr << "cache_patch_replay: " << error.what() << '\n';
        return 1;
    }
}
