// Read-only full scan of OK's initial snapshot: orientation and weak components.
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <cstdint>
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    FILE* f = fopen(argv[1], "r");
    if (!f) return 2;
    setvbuf(f, nullptr, _IOFBF, 8 << 20);
    std::vector<uint32_t> p(3072442);
    std::vector<unsigned char> used(p.size(), 0), rank(p.size(), 0);
    for (uint32_t i = 0; i < p.size(); ++i) p[i] = i;
    auto root = [&](uint32_t u) { while (u != p[u]) { p[u] = p[p[u]]; u = p[u]; } return u; };
    char* line = nullptr;
    size_t cap = 0;
    uint64_t edges = 0, descending = 0, ascending = 0, self = 0;
    while (getline(&line, &cap, f) > 0) {
        char* end;
        auto u = strtoul(line, &end, 10);
        auto v = strtoul(end, &end, 10);
        if (u >= p.size() || v >= p.size()) return 3;
        ++edges;
        descending += u > v;
        ascending += u < v;
        self += u == v;
        used[u] = used[v] = 1;
        auto a = root(u), b = root(v);
        if (a != b) {
            if (rank[a] < rank[b]) p[a] = b;
            else { p[b] = a; if (rank[a] == rank[b]) ++rank[a]; }
        }
    }
    uint64_t vertices = 0, components = 0;
    for (uint32_t i = 0; i < p.size(); ++i) if (used[i]) { ++vertices; components += root(i) == i; }
    printf("{\"edges\":%llu,\"descending\":%llu,\"ascending\":%llu,\"self\":%llu,\"endpoint_vertices\":%llu,\"weak_components\":%llu}\n",
           (unsigned long long)edges, (unsigned long long)descending, (unsigned long long)ascending,
           (unsigned long long)self, (unsigned long long)vertices, (unsigned long long)components);
    free(line);
    fclose(f);
}
