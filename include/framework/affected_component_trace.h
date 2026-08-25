#ifndef SEPGRAPH_AFFECTED_COMPONENT_TRACE_H
#define SEPGRAPH_AFFECTED_COMPONENT_TRACE_H

#include <cstdint>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

#include <groute/graphs/common.h>

namespace sepgraph {
namespace affected_component {

constexpr uint64_t kTraceMagic = 0x4631434f4d503031ULL; // F1COMP01
constexpr uint32_t kTraceVersion = 2;

struct Batch {
    uint32_t batch = 0;
    std::vector<index_t> affected_vertices;
    std::vector<uint32_t> affected_out_degrees;
    std::vector<uint64_t> incoming_offsets;
    std::vector<index_t> incoming_sources;
    // One record per observed closure update. Repeated sources encode later versions.
    std::vector<index_t> changed_source_events;
    bool changed_source_events_available = false;
};

inline void WriteHeader(std::ostream &output) {
    output.write(reinterpret_cast<const char *>(&kTraceMagic), sizeof(kTraceMagic));
    output.write(reinterpret_cast<const char *>(&kTraceVersion), sizeof(kTraceVersion));
}

inline void WriteBatch(std::ostream &output, uint32_t batch,
                       const std::vector<index_t> &vertices,
                       const std::vector<uint32_t> &out_degrees,
                       const std::vector<uint64_t> &offsets,
                       const std::vector<index_t> &sources,
                       const std::vector<index_t> &changed_source_events = {},
                       bool changed_source_events_available = false) {
    if (out_degrees.size() != vertices.size() || offsets.size() != vertices.size() + 1 ||
        offsets.front() != 0 ||
        offsets.back() != sources.size()) {
        throw std::runtime_error("invalid affected-component CSR");
    }
    const uint64_t vertex_count = vertices.size();
    const uint64_t incoming_count = sources.size();
    const uint64_t changed_event_count = changed_source_events.size();
    const uint8_t changed_events_available = changed_source_events_available ? 1 : 0;
    output.write(reinterpret_cast<const char *>(&batch), sizeof(batch));
    output.write(reinterpret_cast<const char *>(&vertex_count), sizeof(vertex_count));
    output.write(reinterpret_cast<const char *>(&incoming_count), sizeof(incoming_count));
    output.write(reinterpret_cast<const char *>(&changed_event_count),
                 sizeof(changed_event_count));
    output.write(reinterpret_cast<const char *>(&changed_events_available),
                 sizeof(changed_events_available));
    output.write(reinterpret_cast<const char *>(vertices.data()),
                 sizeof(index_t) * vertices.size());
    output.write(reinterpret_cast<const char *>(out_degrees.data()),
                 sizeof(uint32_t) * out_degrees.size());
    output.write(reinterpret_cast<const char *>(offsets.data()),
                 sizeof(uint64_t) * offsets.size());
    output.write(reinterpret_cast<const char *>(sources.data()),
                 sizeof(index_t) * sources.size());
    output.write(reinterpret_cast<const char *>(changed_source_events.data()),
                 sizeof(index_t) * changed_source_events.size());
    if (!output) throw std::runtime_error("failed to write affected-component trace");
}

inline std::vector<Batch> ReadTrace(const std::string &path) {
    std::ifstream input(path, std::ios::in | std::ios::binary);
    if (!input) throw std::runtime_error("cannot open affected-component trace: " + path);
    uint64_t magic = 0;
    uint32_t version = 0;
    input.read(reinterpret_cast<char *>(&magic), sizeof(magic));
    input.read(reinterpret_cast<char *>(&version), sizeof(version));
    if (!input || magic != kTraceMagic || version != kTraceVersion) {
        throw std::runtime_error("unsupported affected-component trace");
    }
    std::vector<Batch> batches;
    while (true) {
        Batch batch;
        uint64_t vertex_count = 0;
        uint64_t incoming_count = 0;
        uint64_t changed_event_count = 0;
        uint8_t changed_events_available = 0;
        input.read(reinterpret_cast<char *>(&batch.batch), sizeof(batch.batch));
        if (input.eof()) break;
        input.read(reinterpret_cast<char *>(&vertex_count), sizeof(vertex_count));
        input.read(reinterpret_cast<char *>(&incoming_count), sizeof(incoming_count));
        input.read(reinterpret_cast<char *>(&changed_event_count), sizeof(changed_event_count));
        input.read(reinterpret_cast<char *>(&changed_events_available),
                   sizeof(changed_events_available));
        if (!input || vertex_count > std::numeric_limits<size_t>::max() - 1 ||
            incoming_count > std::numeric_limits<size_t>::max() ||
            changed_event_count > std::numeric_limits<size_t>::max()) {
            throw std::runtime_error("invalid affected-component trace counts");
        }
        batch.affected_vertices.resize(static_cast<size_t>(vertex_count));
        batch.affected_out_degrees.resize(static_cast<size_t>(vertex_count));
        batch.incoming_offsets.resize(static_cast<size_t>(vertex_count) + 1);
        batch.incoming_sources.resize(static_cast<size_t>(incoming_count));
        batch.changed_source_events.resize(static_cast<size_t>(changed_event_count));
        batch.changed_source_events_available = changed_events_available != 0;
        input.read(reinterpret_cast<char *>(batch.affected_vertices.data()),
                   sizeof(index_t) * batch.affected_vertices.size());
        input.read(reinterpret_cast<char *>(batch.affected_out_degrees.data()),
                   sizeof(uint32_t) * batch.affected_out_degrees.size());
        input.read(reinterpret_cast<char *>(batch.incoming_offsets.data()),
                   sizeof(uint64_t) * batch.incoming_offsets.size());
        input.read(reinterpret_cast<char *>(batch.incoming_sources.data()),
                   sizeof(index_t) * batch.incoming_sources.size());
        input.read(reinterpret_cast<char *>(batch.changed_source_events.data()),
                   sizeof(index_t) * batch.changed_source_events.size());
        if (!input || batch.incoming_offsets.empty() || batch.incoming_offsets.front() != 0 ||
            batch.incoming_offsets.back() != incoming_count) {
            throw std::runtime_error("truncated or invalid affected-component trace batch");
        }
        batches.push_back(std::move(batch));
    }
    return batches;
}

} // namespace affected_component
} // namespace sepgraph

#endif
