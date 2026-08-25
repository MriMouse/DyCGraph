#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include <framework/affected_component_trace.h>

int main() {
    const std::string path = "/tmp/sepgraph_affected_component_trace_test.bin";
    {
        std::ofstream output(path, std::ios::out | std::ios::binary | std::ios::trunc);
        sepgraph::affected_component::WriteHeader(output);
        sepgraph::affected_component::WriteBatch(
            output, 4, std::vector<index_t>{2, 5, 9},
            std::vector<uint32_t>{3, 0, 7},
            std::vector<uint64_t>{0, 2, 3, 5},
            std::vector<index_t>{1, 5, 2, 5, 8},
            std::vector<index_t>{2, 9, 2}, true);
    }
    const auto batches = sepgraph::affected_component::ReadTrace(path);
    std::remove(path.c_str());
    return batches.size() == 1 && batches[0].batch == 4 &&
                   batches[0].affected_vertices == std::vector<index_t>({2, 5, 9}) &&
                   batches[0].affected_out_degrees == std::vector<uint32_t>({3, 0, 7}) &&
                   batches[0].incoming_offsets == std::vector<uint64_t>({0, 2, 3, 5}) &&
                   batches[0].incoming_sources == std::vector<index_t>({1, 5, 2, 5, 8}) &&
                   batches[0].changed_source_events == std::vector<index_t>({2, 9, 2}) &&
                   batches[0].changed_source_events_available
               ? 0 : 1;
}
