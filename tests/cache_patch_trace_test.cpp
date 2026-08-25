#include <cstdio>
#include <fstream>
#include <string>

#include <framework/cache_patch_trace.h>

int main() {
    const std::string path = "/tmp/sepgraph_cache_patch_trace_test.bin";
    {
        std::ofstream output(path, std::ios::out | std::ios::binary | std::ios::trunc);
        const uint64_t magic = sepgraph::cache_patch::kTraceMagic;
        const uint32_t batch = 7;
        const uint64_t capacity = 100;
        const uint64_t count = 2;
        const sepgraph::cache_patch::CandidateRecord records[] = {{3, 40}, {9, 50}};
        output.write(reinterpret_cast<const char *>(&magic), sizeof(magic));
        output.write(reinterpret_cast<const char *>(&batch), sizeof(batch));
        output.write(reinterpret_cast<const char *>(&capacity), sizeof(capacity));
        output.write(reinterpret_cast<const char *>(&count), sizeof(count));
        for (const auto &record : records) {
            output.write(reinterpret_cast<const char *>(&record.vertex), sizeof(record.vertex));
            output.write(reinterpret_cast<const char *>(&record.degree), sizeof(record.degree));
        }
        const uint32_t second_batch = 8;
        const uint64_t unchanged_count = 0;
        output.write(reinterpret_cast<const char *>(&second_batch), sizeof(second_batch));
        output.write(reinterpret_cast<const char *>(&capacity), sizeof(capacity));
        output.write(reinterpret_cast<const char *>(&unchanged_count), sizeof(unchanged_count));
    }
    const auto batches = sepgraph::cache_patch::ReadCandidateTrace(path);
    std::remove(path.c_str());
    if (batches.size() != 2 || batches[0].batch != 7 ||
        batches[0].capacity_edges != 100 || batches[0].admitted.size() != 2 ||
        batches[0].admitted[0].vertex != 3 || batches[0].admitted[1].degree != 50 ||
        batches[1].batch != 8 || batches[1].admitted.size() != 2 ||
        batches[1].admitted[0].vertex != 3) {
        return 1;
    }
    return 0;
}
