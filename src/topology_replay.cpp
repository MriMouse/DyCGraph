#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <framework/topology_replay.h>

namespace {

struct Options {
    std::string graph;
    std::string updates;
    std::string batch_sizes;
    size_t max_batches = 0;
    bool dump_sources = false;
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
        } else if (argument == "--dump-sources") options.dump_sources = true;
        else throw std::runtime_error("unknown argument: " + argument);
    }
    if (options.graph.empty() || options.updates.empty() || options.batch_sizes.empty()) {
        throw std::runtime_error(
            "usage: topology_replay --graph FILE --updates FILE --batch-sizes FILE "
            "[--max-batches N] [--dump-sources]");
    }
    return options;
}

std::vector<sepgraph::topology::TopologyMutationBatch> ReadBatches(
    const Options &options) {
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

    std::vector<sepgraph::topology::TopologyMutationBatch> batches(expected.size());
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
        if (type == 'a') {
            if (current.additions.size() >= expected[batch].first) {
                throw std::runtime_error("too many additions in batch " + std::to_string(batch));
            }
            current.additions.push_back(
                {static_cast<index_t>(source), static_cast<index_t>(destination)});
        } else if (type == 'd') {
            if (current.deletions.size() >= expected[batch].second) {
                throw std::runtime_error("too many deletions in batch " + std::to_string(batch));
            }
            current.deletions.push_back(
                {static_cast<index_t>(source), static_cast<index_t>(destination)});
        } else {
            throw std::runtime_error("unknown update type in line: " + line);
        }
        if (current.additions.size() == expected[batch].first &&
            current.deletions.size() == expected[batch].second) {
            ++batch;
        }
    }
    if (batch != batches.size()) throw std::runtime_error("update file ended before selected batches");
    return batches;
}

uint64_t CombineDigest(uint64_t aggregate,
                       const sepgraph::topology::SourceTopologyDigest &digest) {
    aggregate ^= static_cast<uint64_t>(digest.source) + 0x9e3779b97f4a7c15ULL +
                 (aggregate << 6) + (aggregate >> 2);
    aggregate ^= digest.degree + (aggregate << 6) + (aggregate >> 2);
    aggregate ^= digest.multiset_hash + (aggregate << 6) + (aggregate >> 2);
    return aggregate;
}

int Run(const Options &options) {
    const auto batches = ReadBatches(options);
    std::unordered_set<index_t> touched;
    for (const auto &batch : batches) {
        for (const index_t source : batch.TouchedSources()) touched.insert(source);
    }

    std::unordered_map<index_t, std::vector<index_t>> adjacency;
    adjacency.reserve(touched.size());
    for (const index_t source : touched) adjacency.emplace(source, std::vector<index_t>{});

    std::ifstream graph_file(options.graph);
    if (!graph_file) throw std::runtime_error("cannot open graph file");
    uint64_t graph_edges = 0;
    uint64_t source = 0;
    uint64_t destination = 0;
    while (graph_file >> source >> destination) {
        if (source > UINT32_MAX || destination > UINT32_MAX) {
            throw std::runtime_error("graph vertex id exceeds index_t");
        }
        ++graph_edges;
        const auto source_it = adjacency.find(static_cast<index_t>(source));
        if (source_it != adjacency.end()) {
            source_it->second.push_back(static_cast<index_t>(destination));
        }
        std::string remainder;
        std::getline(graph_file, remainder);
    }

    sepgraph::topology::SparseTopologyReplayModel replay(std::move(adjacency), graph_edges);
    std::cout << "[TOPOLOGY-REPLAY-INIT] graph_edges=" << graph_edges
              << " selected_batches=" << batches.size()
              << " touched_sources=" << touched.size() << '\n';

    for (size_t batch_index = 0; batch_index < batches.size(); ++batch_index) {
        const auto &batch = batches[batch_index];
        const auto sources = batch.TouchedSources();
        std::unordered_map<index_t, sepgraph::topology::SourceTopologyDigest> before;
        before.reserve(sources.size());
        for (const index_t touched_source : sources) {
            before.emplace(touched_source, replay.Digest(touched_source));
        }

        uint64_t missing_deletes = 0;
        for (const auto &mutation : batch.deletions) {
            if (!replay.ApplyDelete(mutation.source, mutation.destination)) ++missing_deletes;
        }
        uint64_t invalid_additions = 0;
        for (const auto &mutation : batch.additions) {
            if (!replay.ApplyAdd(mutation.source, mutation.destination)) ++invalid_additions;
        }

        uint64_t changed_sources = 0;
        uint64_t aggregate_hash = 1469598103934665603ULL;
        for (const index_t touched_source : sources) {
            const auto after = replay.Digest(touched_source);
            if (!(before.at(touched_source) == after)) ++changed_sources;
            aggregate_hash = CombineDigest(aggregate_hash, after);
            if (options.dump_sources) {
                std::cout << "[TOPOLOGY-REPLAY-SOURCE] batch=" << batch_index
                          << " source=" << touched_source
                          << " before_degree=" << before.at(touched_source).degree
                          << " after_degree=" << after.degree
                          << " ordered_hash=" << after.ordered_hash
                          << " multiset_hash=" << after.multiset_hash << '\n';
            }
        }
        std::cout << "[TOPOLOGY-REPLAY-BATCH] batch=" << batch_index
                  << " additions=" << batch.additions.size()
                  << " deletions=" << batch.deletions.size()
                  << " touched_sources=" << sources.size()
                  << " changed_sources=" << changed_sources
                  << " missing_deletes=" << missing_deletes
                  << " invalid_additions=" << invalid_additions
                  << " graph_edges=" << replay.EdgeCount()
                  << " touched_multiset_hash=" << aggregate_hash << '\n';
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    try {
        return Run(ParseOptions(argc, argv));
    } catch (const std::exception &error) {
        std::cerr << "topology_replay: " << error.what() << '\n';
        return 1;
    }
}
