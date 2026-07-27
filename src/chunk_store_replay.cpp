#include <algorithm>
#include <chrono>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <groute/graphs/source_local_chunk_store.h>

namespace {

using sepgraph::topology::SourceLocalChunkStore;
using sepgraph::topology::TopologyDescriptor;
using sepgraph::topology::TopologyMutationBatch;

struct Options {
    std::string graph;
    std::string updates;
    std::string batch_sizes;
    size_t max_batches = 0;
    uint64_t slab_edges = 1ULL << 24;
    bool pinned = true;
};

uint64_t ParseUnsigned(const std::string &value, const char *name) {
    size_t consumed = 0;
    const uint64_t parsed = std::stoull(value, &consumed);
    if (consumed != value.size()) throw std::runtime_error(std::string("invalid ") + name);
    return parsed;
}

Options ParseOptions(int argc, char **argv) {
    Options options;
    for (int i = 1; i < argc; ++i) {
        const std::string argument(argv[i]);
        auto read_value = [&](const char *name) -> std::string {
            if (++i >= argc) throw std::runtime_error(std::string("missing value for ") + name);
            return argv[i];
        };
        if (argument == "--graph") options.graph = read_value("--graph");
        else if (argument == "--updates") options.updates = read_value("--updates");
        else if (argument == "--batch-sizes") options.batch_sizes = read_value("--batch-sizes");
        else if (argument == "--max-batches") {
            options.max_batches = ParseUnsigned(read_value("--max-batches"), "--max-batches");
        } else if (argument == "--slab-edges") {
            options.slab_edges = ParseUnsigned(read_value("--slab-edges"), "--slab-edges");
        } else if (argument == "--pageable") {
            options.pinned = false;
        } else {
            throw std::runtime_error("unknown argument: " + argument);
        }
    }
    if (options.graph.empty() || options.updates.empty() || options.batch_sizes.empty()) {
        throw std::runtime_error(
            "usage: chunk_store_replay --graph FILE --updates FILE --batch-sizes FILE "
            "[--max-batches N] [--slab-edges N] [--pageable]");
    }
    if (options.slab_edges == 0) throw std::runtime_error("--slab-edges must be positive");
    return options;
}

std::vector<TopologyMutationBatch> ReadBatches(const Options &options) {
    std::ifstream sizes_file(options.batch_sizes);
    if (!sizes_file) throw std::runtime_error("cannot open batch-size file");
    std::vector<std::pair<uint64_t, uint64_t>> expected;
    uint64_t additions = 0;
    uint64_t deletions = 0;
    while (sizes_file >> additions >> deletions) {
        if (options.max_batches != 0 && expected.size() >= options.max_batches) break;
        expected.emplace_back(additions, deletions);
    }
    if (expected.empty()) throw std::runtime_error("batch-size file contains no selected batch");

    std::vector<TopologyMutationBatch> batches(expected.size());
    std::ifstream update_file(options.updates);
    if (!update_file) throw std::runtime_error("cannot open update file");
    size_t batch = 0;
    std::string line;
    while (batch < batches.size() && std::getline(update_file, line)) {
        std::istringstream input(line);
        char type = 0;
        uint64_t source = 0;
        uint64_t destination = 0;
        input >> type >> source >> destination;
        if (!input || source > UINT32_MAX || destination > UINT32_MAX) {
            throw std::runtime_error("invalid update line: " + line);
        }
        auto &current = batches[batch];
        if (type == 'a' && current.additions.size() < expected[batch].first) {
            current.additions.push_back(
                {static_cast<index_t>(source), static_cast<index_t>(destination)});
        } else if (type == 'd' && current.deletions.size() < expected[batch].second) {
            current.deletions.push_back(
                {static_cast<index_t>(source), static_cast<index_t>(destination)});
        } else {
            throw std::runtime_error("unexpected update in batch " + std::to_string(batch));
        }
        if (current.additions.size() == expected[batch].first &&
            current.deletions.size() == expected[batch].second) {
            ++batch;
        }
    }
    if (batch != batches.size()) throw std::runtime_error("update file ended before selected batches");
    return batches;
}

bool SameDescriptor(const TopologyDescriptor &left, const TopologyDescriptor &right) {
    return left.index == right.index && left.degree == right.degree &&
           left.slab_id == right.slab_id && left.version == right.version;
}

uint64_t RoundUp(uint64_t value, uint64_t alignment) {
    return ((value + alignment - 1) / alignment) * alignment;
}

int Run(const Options &options) {
    using Clock = std::chrono::steady_clock;
    const auto batches = ReadBatches(options);
    std::unordered_set<index_t> touched_set;
    for (const auto &batch : batches) {
        for (const index_t source : batch.TouchedSources()) touched_set.insert(source);
    }
    std::vector<index_t> all_touched(touched_set.begin(), touched_set.end());
    std::sort(all_touched.begin(), all_touched.end());

    std::unordered_map<index_t, std::vector<index_t>> adjacency;
    adjacency.reserve(all_touched.size());
    for (const index_t source : all_touched) adjacency.emplace(source, std::vector<index_t>{});

    const auto load_begin = Clock::now();
    std::ifstream graph_file(options.graph);
    if (!graph_file) throw std::runtime_error("cannot open graph file");
    uint64_t graph_edges = 0;
    uint64_t max_vertex = 0;
    uint64_t source = 0;
    uint64_t destination = 0;
    while (graph_file >> source >> destination) {
        if (source > UINT32_MAX || destination > UINT32_MAX) {
            throw std::runtime_error("graph vertex id exceeds index_t");
        }
        ++graph_edges;
        max_vertex = std::max(max_vertex, std::max(source, destination));
        const auto source_it = adjacency.find(static_cast<index_t>(source));
        if (source_it != adjacency.end()) {
            source_it->second.push_back(static_cast<index_t>(destination));
        }
        std::string remainder;
        std::getline(graph_file, remainder);
    }

    uint64_t arena_edges = 0;
    std::unordered_map<index_t, uint64_t> upper_degrees;
    std::unordered_map<index_t, uint64_t> upper_capacities;
    upper_degrees.reserve(all_touched.size());
    upper_capacities.reserve(all_touched.size());
    uint64_t materialized_edges = 0;
    for (const index_t touched_source : all_touched) {
        const uint64_t degree = adjacency.at(touched_source).size();
        const uint64_t capacity = SourceLocalChunkStore::RequiredChunkCapacity(degree);
        upper_degrees[touched_source] = degree;
        upper_capacities[touched_source] = capacity;
        arena_edges += capacity;
        materialized_edges += degree;
    }
    for (const auto &batch : batches) {
        std::unordered_map<index_t, uint64_t> additions_by_source;
        for (const auto &mutation : batch.additions) ++additions_by_source[mutation.source];
        for (const auto &entry : additions_by_source) {
            uint64_t &degree = upper_degrees[entry.first];
            uint64_t &capacity = upper_capacities[entry.first];
            degree += entry.second;
            const uint64_t required = SourceLocalChunkStore::RequiredChunkCapacity(degree);
            if (required > capacity) {
                arena_edges += required;
                capacity = required;
            }
        }
    }
    arena_edges = RoundUp(std::max<uint64_t>(arena_edges, 1), options.slab_edges);

    const index_t node_count = static_cast<index_t>(max_vertex + 1);
    SourceLocalChunkStore store(
        node_count,
        {arena_edges, options.slab_edges, 4, options.pinned});
    for (const index_t touched_source : all_touched) {
        store.LoadSource(touched_source, adjacency.at(touched_source));
    }
    store.FinalizeLoad(graph_edges);
    sepgraph::topology::SparseTopologyReplayModel oracle(
        std::move(adjacency), graph_edges);
    const double load_ms = std::chrono::duration<double, std::milli>(
        Clock::now() - load_begin).count();

    std::cout << "[CHUNK-STORE-INIT] graph_edges=" << graph_edges
              << " selected_batches=" << batches.size()
              << " materialized_sources=" << all_touched.size()
              << " materialized_edges=" << materialized_edges
              << " node_count=" << node_count
              << " slabs=" << store.SlabCount()
              << " pinned=" << (options.pinned ? 1 : 0)
              << " arena_reserved_bytes=" << arena_edges * sizeof(index_t)
              << " metadata_bytes=" << store.MetadataBytes()
              << " reserved_host_bytes="
              << arena_edges * sizeof(index_t) + store.MetadataBytes()
              << " descriptor_abi_bytes=" << sizeof(TopologyDescriptor)
              << " load_ms=" << load_ms << '\n';

    for (size_t batch_index = 0; batch_index < batches.size(); ++batch_index) {
        const auto &batch = batches[batch_index];
        const std::vector<index_t> sources = batch.TouchedSources();
        const std::unordered_set<index_t> batch_sources(sources.begin(), sources.end());
        std::unordered_map<index_t, TopologyDescriptor> descriptors_before;
        descriptors_before.reserve(all_touched.size());
        for (const index_t touched_source : all_touched) {
            descriptors_before.emplace(touched_source, store.Descriptor(touched_source));
        }

        const auto metrics = store.ApplyBatch(batch);
        uint64_t oracle_missing_deletes = 0;
        uint64_t oracle_invalid_additions = 0;
        for (const auto &mutation : batch.deletions) {
            if (!oracle.ApplyDelete(mutation.source, mutation.destination)) {
                ++oracle_missing_deletes;
            }
        }
        for (const auto &mutation : batch.additions) {
            if (!oracle.ApplyAdd(mutation.source, mutation.destination)) {
                ++oracle_invalid_additions;
            }
        }

        uint64_t isolation_violations = 0;
        for (const index_t touched_source : all_touched) {
            if (batch_sources.count(touched_source) == 0 &&
                !SameDescriptor(descriptors_before.at(touched_source),
                                store.Descriptor(touched_source))) {
                ++isolation_violations;
            }
        }
        uint64_t topology_mismatches = 0;
        for (const index_t touched_source : sources) {
            if (!(store.Digest(touched_source) == oracle.Digest(touched_source))) {
                ++topology_mismatches;
            }
        }
        const uint64_t published_epoch = store.Publish();
        const auto gc_begin = Clock::now();
        const uint64_t reclaimed = store.ReclaimThrough(published_epoch);
        const double gc_ms = std::chrono::duration<double, std::milli>(
            Clock::now() - gc_begin).count();
        const auto &arena = store.ArenaStats();
        const double materialized_amplification = materialized_edges == 0
            ? 0.0
            : static_cast<double>(arena.high_water_edges) /
                static_cast<double>(materialized_edges);

        std::cout << "[CHUNK-STORE-BATCH] batch=" << batch_index
                  << " epoch=" << published_epoch
                  << " additions=" << batch.additions.size()
                  << " deletions=" << batch.deletions.size()
                  << " touched_sources=" << metrics.touched_sources
                  << " changed_sources=" << metrics.changed_sources
                  << " missing_deletes=" << metrics.missing_deletes
                  << " invalid_additions=" << metrics.invalid_additions
                  << " topology_mismatches=" << topology_mismatches
                  << " isolation_violations=" << isolation_violations
                  << " graph_edges=" << store.EdgeCount()
                  << " oracle_edges=" << oracle.EdgeCount()
                  << " group_ms=" << metrics.group_ms
                  << " mutation_ms=" << metrics.mutation_ms
                  << " allocation_ms=" << metrics.allocation_ms
                  << " gc_ms=" << gc_ms
                  << " mutation_written_bytes=" << metrics.mutation_written_bytes
                  << " relocation_copied_bytes=" << metrics.relocation_copied_bytes
                  << " allocations=" << metrics.allocations
                  << " reused_blocks=" << metrics.reused_blocks
                  << " retired_blocks=" << metrics.retired_blocks
                  << " reclaimed_blocks=" << reclaimed
                  << " arena_high_water_bytes=" << arena.high_water_edges * sizeof(index_t)
                  << " arena_reserved_bytes=" << arena.capacity_edges * sizeof(index_t)
                  << " materialized_amplification=" << materialized_amplification
                  << '\n';

        if (metrics.missing_deletes != oracle_missing_deletes ||
            metrics.invalid_additions != oracle_invalid_additions ||
            topology_mismatches != 0 || isolation_violations != 0 ||
            store.EdgeCount() != oracle.EdgeCount()) {
            return 2;
        }
        materialized_edges = materialized_edges -
            (batch.deletions.size() - metrics.missing_deletes) +
            (batch.additions.size() - metrics.invalid_additions);
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    try {
        return Run(ParseOptions(argc, argv));
    } catch (const std::exception &error) {
        std::cerr << "chunk_store_replay: " << error.what() << '\n';
        return 1;
    }
}
