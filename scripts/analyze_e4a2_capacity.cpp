#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include <unordered_map>
#include <vector>

class Scanner {
public:
    explicit Scanner(const char *path) : file_(std::fopen(path, "rb")) {
        if (!file_) throw std::runtime_error("cannot open input");
    }
    ~Scanner() { std::fclose(file_); }
    bool NextUint(uint64_t &value) {
        int c;
        do { c = std::fgetc(file_); } while (c != EOF && (c < '0' || c > '9'));
        if (c == EOF) return false;
        value = 0;
        do {
            value = value * 10 + static_cast<unsigned>(c - '0');
            c = std::fgetc(file_);
        } while (c >= '0' && c <= '9');
        return true;
    }
    bool NextMutation(char &operation, uint64_t &source, uint64_t &destination) {
        int c;
        do { c = std::fgetc(file_); } while (c != EOF && c != 'a' && c != 'd');
        if (c == EOF) return false;
        operation = static_cast<char>(c);
        return NextUint(source) && NextUint(destination);
    }
private:
    FILE *file_;
};

static void EnsureVertex(std::vector<uint32_t> &values, uint64_t vertex) {
    if (vertex > UINT32_MAX) throw std::overflow_error("vertex exceeds uint32");
    if (vertex >= values.size()) values.resize(vertex + 1, 0);
}

static uint64_t Grow(uint64_t old_capacity, uint64_t required) {
    if (required <= old_capacity) return old_capacity;
    if (old_capacity == 0) return required;
    uint64_t capacity = std::max(required, (old_capacity * 5 + 3) / 4);
    return (capacity + 7) / 8 * 8;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        std::fprintf(stderr, "usage: %s GRAPH UPDATE STREAM_SIZE\n", argv[0]);
        return 2;
    }
    std::vector<uint32_t> degree, capacity;
    uint64_t source, destination, edges = 0;
    {
        Scanner graph(argv[1]);
        while (graph.NextUint(source)) {
            if (!graph.NextUint(destination)) throw std::runtime_error("truncated graph");
            EnsureVertex(degree, std::max(source, destination));
            if (degree[destination] == UINT32_MAX) throw std::overflow_error("degree");
            ++degree[destination];
            ++edges;
        }
    }
    capacity = degree;
    uint64_t logical = edges, live = edges, arena_high_water = edges;
    std::unordered_map<uint32_t, uint64_t> reusable;
    Scanner updates(argv[2]);
    Scanner sizes(argv[3]);
    std::printf("batch\tvertices\tlogical_edges\tlive_capacity_edges\t"
                "live_amplification\tarena_high_water_edges\tprojected_bytes\t"
                "cow_allocations\treused_allocations\tmissing_deletes\n");
    for (uint64_t batch = 0;; ++batch) {
        uint64_t deletion_count, addition_count;
        if (!sizes.NextUint(deletion_count)) break;
        if (!sizes.NextUint(addition_count)) throw std::runtime_error("truncated size file");
        std::unordered_map<uint32_t, std::pair<uint32_t, uint32_t>> delta;
        delta.reserve(deletion_count + addition_count);
        for (uint64_t i = 0; i < deletion_count + addition_count; ++i) {
            char operation;
            if (!updates.NextMutation(operation, source, destination))
                throw std::runtime_error("truncated update file");
            EnsureVertex(degree, std::max(source, destination));
            if (capacity.size() < degree.size()) capacity.resize(degree.size(), 0);
            auto &counts = delta[static_cast<uint32_t>(destination)];
            if (operation == 'd') ++counts.first; else ++counts.second;
        }
        uint64_t allocations = 0, reused_count = 0, missing = 0;
        std::vector<uint32_t> retired;
        for (const auto &entry : delta) {
            const uint32_t vertex = entry.first;
            const uint32_t removed = std::min(degree[vertex], entry.second.first);
            missing += entry.second.first - removed;
            const uint64_t required = static_cast<uint64_t>(degree[vertex]) - removed +
                                      entry.second.second;
            const uint64_t next_capacity = Grow(capacity[vertex], required);
            logical = logical - degree[vertex] + required;
            degree[vertex] = static_cast<uint32_t>(required);
            if (next_capacity > capacity[vertex]) {
                ++allocations;
                auto found = reusable.find(static_cast<uint32_t>(next_capacity));
                if (found != reusable.end() && found->second != 0) {
                    --found->second;
                    ++reused_count;
                } else arena_high_water += next_capacity;
                if (capacity[vertex] != 0) retired.push_back(capacity[vertex]);
                live += next_capacity - capacity[vertex];
                capacity[vertex] = static_cast<uint32_t>(next_capacity);
            }
        }
        for (uint32_t block : retired) ++reusable[block];
        const uint64_t descriptor_bytes = capacity.size() * 24ULL;
        const uint64_t projected_bytes = arena_high_water * 4ULL + descriptor_bytes;
        std::printf("%llu\t%zu\t%llu\t%llu\t%.6f\t%llu\t%llu\t%llu\t%llu\t%llu\n",
            static_cast<unsigned long long>(batch), capacity.size(),
            static_cast<unsigned long long>(logical),
            static_cast<unsigned long long>(live),
            logical ? static_cast<double>(live) / logical : 1.0,
            static_cast<unsigned long long>(arena_high_water),
            static_cast<unsigned long long>(projected_bytes),
            static_cast<unsigned long long>(allocations),
            static_cast<unsigned long long>(reused_count),
            static_cast<unsigned long long>(missing));
    }
    return 0;
}
