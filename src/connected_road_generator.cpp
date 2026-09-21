#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <numeric>
#include <random>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include <nlohmann/json.hpp>

namespace fs = std::filesystem;
using Json = nlohmann::json;
constexpr uint32_t kNone = UINT32_MAX;
struct Edge { uint32_t u, v; };
struct Arc { uint32_t to, edge; };
struct Component { uint32_t begin, end; };

class TextWriter {
public:
    explicit TextWriter(const fs::path &path) : output_(path, std::ios::binary) {
        if (!output_) throw std::runtime_error("Cannot create " + path.string());
        buffer_.reserve(4 << 20);
    }
    void EdgeLine(uint32_t u, uint32_t v, char operation = 0) {
        if (operation) { buffer_ += operation; buffer_ += ' '; }
        Number(u); buffer_ += ' '; Number(v);
        if (operation) buffer_ += " 1";
        buffer_ += '\n';
        if (buffer_.size() >= (4 << 20)) Flush();
    }
    void Close() {
        Flush(); output_.close();
        if (!output_) throw std::runtime_error("Cannot finish output");
    }
private:
    void Number(uint32_t value) {
        char digits[16];
        auto result = std::to_chars(digits, digits + sizeof(digits), value);
        buffer_.append(digits, result.ptr);
    }
    void Flush() {
        output_.write(buffer_.data(), buffer_.size()); buffer_.clear();
        if (!output_) throw std::runtime_error("Cannot write output");
    }
    std::ofstream output_;
    std::string buffer_;
};

uint64_t Uniform(std::mt19937_64 &rng, uint64_t size) {
    if (!size) throw std::runtime_error("Empty random pool");
    // Rejection sampling makes RNG results independent of standard-library
    // uniform_int_distribution and avoids modulo bias.
    const uint64_t threshold = -size % size;
    uint64_t value;
    do { value = rng(); } while (value < threshold);
    return value % size;
}
template<class T> void ShufflePrefix(std::vector<T> &values, size_t count,
                                    std::mt19937_64 &rng) {
    if (count > values.size()) throw std::runtime_error("Insufficient exchange pool");
    for (size_t i = 0; i < count; ++i)
        std::swap(values[i], values[i + Uniform(rng, values.size() - i)]);
}

std::vector<Edge> Load(const fs::path &path, uint32_t &vertices, Json &metadata) {
    std::ifstream input(path);
    std::string line;
    if (!std::getline(input, line) || line != "%%MatrixMarket matrix coordinate pattern symmetric")
        throw std::runtime_error("Expected pattern symmetric Matrix Market input");
    do {
        if (!std::getline(input, line)) throw std::runtime_error("Missing Matrix Market size");
    } while (line.empty() || line[0] == '%');
    uint64_t rows, columns, declared;
    std::istringstream dimensions(line);
    if (!(dimensions >> rows >> columns >> declared) || rows != columns || rows >= UINT32_MAX ||
        declared >= UINT32_MAX) throw std::runtime_error("Unsupported Matrix Market dimensions");
    vertices = rows;
    std::vector<Edge> edges;
    edges.reserve(declared);
    uint64_t u, v, records = 0, loops = 0;
    while (input >> u >> v) {
        if (!u || !v || u > rows || v > rows) throw std::runtime_error("Invalid vertex ID");
        ++records;
        if (u == v) { ++loops; continue; }
        edges.push_back({uint32_t(std::min(u, v)), uint32_t(std::max(u, v))});
    }
    if (!input.eof() || records != declared) throw std::runtime_error("Matrix record mismatch");
    std::sort(edges.begin(), edges.end(), [](Edge a, Edge b) {
        return a.u < b.u || (a.u == b.u && a.v < b.v);
    });
    const auto old_size = edges.size();
    edges.erase(std::unique(edges.begin(), edges.end(), [](Edge a, Edge b) {
        return a.u == b.u && a.v == b.v;
    }), edges.end());
    metadata = {{"matrix_vertices", vertices}, {"stored_records", records},
                {"self_loops_removed", loops}, {"duplicate_pairs_removed", old_size - edges.size()},
                {"unique_undirected_edges", edges.size()}};
    std::cout << "Loaded vertices=" << vertices << " unique_edges=" << edges.size() << std::endl;
    return edges;
}

struct Forest {
    std::vector<uint32_t> order, rank, parent_edge;
    std::vector<uint64_t> edge_prefix;
    std::vector<uint32_t> tree_prefix;
    uint32_t largest_size = 0, source = 0, components = 0;
};

Forest BuildForest(uint32_t vertices, const std::vector<Edge> &edges) {
    Forest forest;
    std::vector<uint64_t> offsets(size_t(vertices) + 2, 0);
    for (auto edge : edges) { ++offsets[edge.u + 1]; ++offsets[edge.v + 1]; }
    std::partial_sum(offsets.begin(), offsets.end(), offsets.begin());
    auto cursor = offsets;
    std::vector<Arc> arcs(2 * edges.size());
    for (uint32_t id = 0; id < edges.size(); ++id) {
        const auto edge = edges[id];
        arcs[cursor[edge.u]++] = {edge.v, id};
        arcs[cursor[edge.v]++] = {edge.u, id};
    }
    cursor.clear(); cursor.shrink_to_fit();
    std::vector<uint8_t> seen(size_t(vertices) + 1, 0);
    forest.parent_edge.assign(size_t(vertices) + 1, kNone);
    std::vector<Component> components;
    forest.order.reserve(vertices);
    for (uint32_t root = 1; root <= vertices; ++root) {
        if (seen[root] || offsets[root] == offsets[root + 1]) continue;
        const uint32_t begin = forest.order.size();
        forest.order.push_back(root); seen[root] = 1;
        for (size_t index = begin; index < forest.order.size(); ++index) {
            const uint32_t vertex = forest.order[index];
            for (auto offset = offsets[vertex]; offset < offsets[vertex + 1]; ++offset) {
                const auto arc = arcs[offset];
                if (seen[arc.to]) continue;
                seen[arc.to] = 1;
                forest.parent_edge[arc.to] = arc.edge;
                forest.order.push_back(arc.to);
            }
        }
        components.push_back({begin, uint32_t(forest.order.size())});
    }
    if (components.empty()) throw std::runtime_error("Graph has no nontrivial component");
    std::sort(components.begin(), components.end(), [&](Component a, Component b) {
        return a.end - a.begin > b.end - b.begin ||
               (a.end - a.begin == b.end - b.begin && forest.order[a.begin] < forest.order[b.begin]);
    });
    forest.source = forest.order[components[0].begin];
    forest.largest_size = components[0].end - components[0].begin;
    forest.components = components.size();
    std::vector<uint32_t> sorted_order;
    sorted_order.reserve(forest.order.size());
    for (auto component : components)
        sorted_order.insert(sorted_order.end(), forest.order.begin() + component.begin,
                            forest.order.begin() + component.end);
    forest.order.swap(sorted_order);
    forest.rank.assign(size_t(vertices) + 1, kNone);
    for (uint32_t index = 0; index < forest.order.size(); ++index) forest.rank[forest.order[index]] = index;
    forest.edge_prefix.assign(forest.order.size() + 1, 0);
    for (auto edge : edges) ++forest.edge_prefix[std::max(forest.rank[edge.u], forest.rank[edge.v]) + 1];
    std::partial_sum(forest.edge_prefix.begin(), forest.edge_prefix.end(), forest.edge_prefix.begin());
    forest.tree_prefix.assign(forest.order.size() + 1, 0);
    for (size_t i = 0; i < forest.order.size(); ++i)
        forest.tree_prefix[i + 1] = forest.tree_prefix[i] + (forest.parent_edge[forest.order[i]] != kNone);
    std::cout << "BFS forest active_vertices=" << forest.order.size()
              << " largest_component=" << forest.largest_size << " source=" << forest.source << std::endl;
    return forest;
}

void SaveJson(const fs::path &path, const Json &value) {
    std::ofstream output(path);
    output << value.dump(2) << '\n';
    if (!output) throw std::runtime_error("Cannot write metadata");
}

void Generate(const fs::path &directory, const std::string &name, uint32_t percent,
              const std::vector<uint32_t> &scales, uint32_t batches, uint64_t seed,
              const std::vector<Edge> &edges, const Forest &forest, Json &metadata) {
    const uint64_t base_count = edges.size() * uint64_t(percent) / 100;
    int64_t best_margin = -1;
    uint32_t core_size = 0;
    // Along BFS prefixes, available insertions increase and removable base
    // edges decrease. Maximize the smaller pool, without tuning per dataset.
    for (uint32_t k = 1; k < forest.edge_prefix.size(); ++k) {
        const int64_t margin = std::min(int64_t(base_count) - forest.tree_prefix[k],
                                      int64_t(forest.edge_prefix[k]) - int64_t(base_count));
        if (margin >= 0 && margin >= best_margin) { best_margin = margin; core_size = k; }
    }
    const uint32_t required = *std::max_element(scales.begin(), scales.end()) / 4;
    if (best_margin < required)
        throw std::runtime_error(std::to_string(percent) + "p supports at most " +
            std::to_string(std::max<int64_t>(0, best_margin) * 4) + " directed updates/batch");
    const uint64_t tree_count = forest.tree_prefix[core_size];
    std::vector<uint8_t> protected_edge(edges.size(), 0), base(edges.size(), 0);
    std::vector<uint32_t> optional;
    for (uint32_t id = 0; id < edges.size(); ++id) {
        const auto edge = edges[id];
        if (forest.rank[edge.u] < core_size && forest.rank[edge.v] < core_size)
            optional.push_back(id);
    }
    const uint64_t base_seed = seed + uint64_t(percent) * 1000003;
    std::mt19937_64 rng(base_seed);
    ShufflePrefix(optional, optional.size(), rng);
    // Random-order Kruskal protects connectivity without freezing the source's
    // BFS shortest paths. This is not a uniform spanning-tree sampler.
    std::vector<uint32_t> parent(core_size), sizes(core_size, 1);
    std::iota(parent.begin(), parent.end(), 0);
    auto find = [&](uint32_t vertex) {
        while (parent[vertex] != vertex) {
            parent[vertex] = parent[parent[vertex]];
            vertex = parent[vertex];
        }
        return vertex;
    };
    size_t remaining = 0;
    uint64_t selected_tree_edges = 0;
    for (const auto id : optional) {
        const auto edge = edges[id];
        auto u = find(forest.rank[edge.u]), v = find(forest.rank[edge.v]);
        if (u != v) {
            if (sizes[u] < sizes[v]) std::swap(u, v);
            parent[v] = u; sizes[u] += sizes[v];
            protected_edge[id] = 1; base[id] = 1;
            ++selected_tree_edges;
        } else optional[remaining++] = id;
    }
    if (selected_tree_edges != tree_count) throw std::runtime_error("Core forest mismatch");
    optional.resize(remaining);
    parent.clear(); parent.shrink_to_fit(); sizes.clear(); sizes.shrink_to_fit();
    ShufflePrefix(optional, optional.size(), rng);
    const size_t present_count = base_count - tree_count;
    for (size_t i = 0; i < present_count; ++i) base[optional[i]] = 1;
    const auto ratio_dir = directory / (std::to_string(percent) + "p");
    fs::create_directories(ratio_dir);
    const std::string stem = name + "_" + std::to_string(percent) + "p_";
    const auto base_file = ratio_dir / ("input_" + stem + std::to_string(scales[0] / 1000) + "k.txt");
    std::ofstream backbone(ratio_dir / "backbone.bin", std::ios::binary);
    for (uint32_t id = 0; id < edges.size(); ++id) if (protected_edge[id]) {
        backbone.write(reinterpret_cast<const char *>(&edges[id].u), sizeof(uint32_t));
        backbone.write(reinterpret_cast<const char *>(&edges[id].v), sizeof(uint32_t));
    }
    backbone.close();
    if (!backbone) throw std::runtime_error("Cannot write backbone certificate");
    TextWriter writer(base_file);
    for (uint32_t id = 0; id < edges.size(); ++id) if (base[id]) {
        writer.EdgeLine(edges[id].u, edges[id].v);
        writer.EdgeLine(edges[id].v, edges[id].u);
    }
    writer.Close();
    Json ratio = {{"base_percent", percent}, {"base_seed", base_seed},
        {"base_undirected_edges", base_count}, {"base_directed_edges", 2 * base_count},
        {"core_vertices", core_size}, {"source_node", forest.source},
        {"source_reachable_vertices", std::min(core_size, forest.largest_size)},
        {"core_components", core_size - tree_count}, {"protected_tree_edges", tree_count},
        {"eligible_core_edges", forest.edge_prefix[core_size]},
        {"initial_removable_edges", present_count}, {"initial_absent_edges", optional.size() - present_count},
        {"balanced_pool_capacity", best_margin}, {"configs", Json::array()}};
    for (uint32_t scale : scales) {
        const std::string suffix = std::to_string(scale / 1000) + "k";
        const auto input_file = ratio_dir / ("input_" + stem + suffix + ".txt");
        if (input_file != base_file) fs::create_hard_link(base_file, input_file);
        std::vector<uint32_t> present(optional.begin(), optional.begin() + present_count);
        std::vector<uint32_t> absent(optional.begin() + present_count, optional.end());
        std::vector<uint8_t> state = base;
        const uint64_t update_seed = base_seed + uint64_t(scale) * 1000033;
        std::mt19937_64 update_rng(update_seed);
        const auto update_file = ratio_dir / ("update_" + stem + suffix + ".txt");
        const auto sizes_file = ratio_dir / ("stream_size_" + stem + suffix + ".txt");
        TextWriter output(update_file);
        std::ofstream size_output(sizes_file);
        const uint32_t swaps = scale / 4;
        struct Record { uint32_t u, v; char op; };
        std::vector<Record> records;
        records.reserve(scale);
        Json batch_stats = Json::array();
        for (uint32_t batch = 0; batch < batches; ++batch) {
            ShufflePrefix(present, swaps, update_rng);
            ShufflePrefix(absent, swaps, update_rng);
            records.clear();
            uint32_t reachable_deletes = 0, reachable_adds = 0;
            uint64_t deletion_hash = 14695981039346656037ULL;
            for (uint32_t i = 0; i < swaps; ++i) {
                const auto del = present[i], add = absent[i];
                if (!state[del] || state[add] || protected_edge[del])
                    throw std::runtime_error("Invalid edge-pool transition");
                state[del] = 0; state[add] = 1;
                const auto d = edges[del], a = edges[add];
                records.push_back({d.u, d.v, 'd'}); records.push_back({d.v, d.u, 'd'});
                records.push_back({a.u, a.v, 'a'}); records.push_back({a.v, a.u, 'a'});
                reachable_deletes += forest.rank[d.u] < forest.largest_size;
                reachable_adds += forest.rank[a.u] < forest.largest_size;
                deletion_hash = (deletion_hash ^ del) * 1099511628211ULL;
                std::swap(present[i], absent[i]);
            }
            ShufflePrefix(records, records.size(), update_rng);
            for (const auto &record : records) output.EdgeLine(record.u, record.v, record.op);
            size_output << scale / 2 << ' ' << scale / 2 << '\n';
            batch_stats.push_back({{"batch", batch}, {"undirected_deletes", swaps},
                {"undirected_adds", swaps}, {"source_reachable_delete_pairs", reachable_deletes},
                {"source_reachable_add_pairs", reachable_adds}, {"delete_edge_id_hash", deletion_hash},
                {"invalid_deletes", 0}, {"duplicate_adds", 0}, {"protected_deletes", 0}});
        }
        output.Close(); size_output.close();
        if (!size_output) throw std::runtime_error("Cannot write batch sizes");
        ratio["configs"].push_back({{"batch_size_directed_records", scale}, {"update_seed", update_seed},
            {"input_file", input_file.filename().string()}, {"update_file", update_file.filename().string()},
            {"stream_size_file", sizes_file.filename().string()}, {"batches", batch_stats}});
        std::cout << name << ' ' << percent << "p " << suffix << " generated core=" << core_size
                  << " reachable=" << std::min(core_size, forest.largest_size)
                  << " pool_min=" << best_margin << std::endl;
    }
    SaveJson(ratio_dir / "metadata.json", ratio);
    metadata["ratios"].push_back(ratio);
}

std::vector<uint32_t> List(const std::string &text) {
    std::vector<uint32_t> result;
    std::istringstream input(text);
    std::string token;
    while (std::getline(input, token, ',')) result.push_back(std::stoul(token));
    if (result.empty()) throw std::runtime_error("Empty configuration list");
    auto sorted = result;
    std::sort(sorted.begin(), sorted.end());
    if (std::adjacent_find(sorted.begin(), sorted.end()) != sorted.end())
        throw std::runtime_error("Duplicate configuration");
    return result;
}

int main(int argc, char **argv) {
    try {
        if (argc != 9) throw std::runtime_error(
            "Usage: connected_road_generator SOURCE OUTPUT NAME PERCENTS SCALES BATCHES SEED VERSION");
        const fs::path source = fs::absolute(argv[1]), directory = fs::absolute(argv[2]);
        const std::string name = argv[3];
        if (name.empty() || name.find_first_not_of("abcdefghijklmnopqrstuvwxyz0123456789_") != std::string::npos)
            throw std::runtime_error("Invalid dataset name");
        const auto percents = List(argv[4]), scales = List(argv[5]);
        const uint32_t batches = std::stoul(argv[6]);
        const uint64_t seed = std::stoull(argv[7]);
        if (!batches) throw std::runtime_error("Batch count must be positive");
        for (auto percent : percents) if (!percent || percent >= 100) throw std::runtime_error("Invalid percent");
        for (auto scale : scales) if (!scale || scale % 4 || scale % 1000) throw std::runtime_error("Scales must be multiples of 1000 and 4");
        if (fs::exists(directory) && !fs::is_empty(directory)) throw std::runtime_error("Output must be new/empty");
        fs::create_directories(directory);
        Json metadata;
        uint32_t vertices;
        const auto edges = Load(source, vertices, metadata);
        const auto forest = BuildForest(vertices, edges);
        metadata["source_file"] = source.string();
        metadata["generator_version"] = argv[8];
        metadata["dataset"] = name;
        metadata["seed"] = seed;
        metadata["batches"] = batches;
        metadata["nontrivial_original_components"] = forest.components;
        metadata["source_node"] = forest.source;
        metadata["largest_original_component_vertices"] = forest.largest_size;
        metadata["ratios"] = Json::array();
        metadata["semantics"] = "Percent of original unique undirected edges; each pair expanded both ways; original 1-based IDs retained. Random-order Kruskal forest protected from deletion (not a uniform spanning tree). Final-state pool exchange with recurrence across batches, no within-batch cancellation. Largest components first; BFS prefix maximizes min(removable,absent) pools. Same initial graph across scales.";
        for (auto percent : percents) Generate(directory, name, percent, scales, batches, seed, edges, forest, metadata);
        SaveJson(directory / "metadata.json", metadata);
        std::cout << "COMPLETE " << directory << std::endl;
    } catch (const std::exception &error) {
        std::cerr << error.what() << std::endl;
        return 1;
    }
}
