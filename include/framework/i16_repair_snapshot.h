#pragma once
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace i16 {
constexpr uint64_t magic = 0x4931365354415445ULL;
struct State { uint32_t vertex, value, buffer, parent; };
struct Snapshot {
    uint32_t batch = 0, source = 0, nodes = 0;
    std::vector<uint32_t> affected, incoming;
    std::vector<uint64_t> offsets;
    std::vector<State> before, after;
};
template<class T> void Write(std::ostream &out, const T &v) {
    out.write(reinterpret_cast<const char *>(&v), sizeof(v));
    if (!out) throw std::runtime_error("Snapshot write failed");
}
template<class T> void WriteVector(std::ostream &out, const std::vector<T> &v) {
    Write(out, uint64_t(v.size()));
    out.write(reinterpret_cast<const char *>(v.data()), v.size() * sizeof(T));
    if (!out) throw std::runtime_error("Snapshot vector write failed");
}
template<class T> void Read(std::istream &in, T &v) {
    in.read(reinterpret_cast<char *>(&v), sizeof(v));
    if (!in) throw std::runtime_error("Truncated snapshot");
}
template<class T> void ReadVector(std::istream &in, std::vector<T> &v) {
    uint64_t count; Read(in, count);
    const auto begin = in.tellg(); in.seekg(0, std::ios::end);
    const auto end = in.tellg(); in.seekg(begin);
    if (end < begin || count > uint64_t(end - begin) / sizeof(T))
        throw std::runtime_error("Invalid snapshot count");
    v.resize(count);
    in.read(reinterpret_cast<char *>(v.data()), v.size() * sizeof(T));
    if (!in) throw std::runtime_error("Truncated snapshot vector");
}
inline Snapshot Load(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    uint64_t m; uint32_t version, infinity, weight_rule;
    Read(in, m); Read(in, version); Read(in, infinity); Read(in, weight_rule);
    if (m != magic || version != 1 || infinity != UINT32_MAX || weight_rule != 1)
        throw std::runtime_error("Unsupported snapshot contract");
    Snapshot s; Read(in, s.batch); Read(in, s.source); Read(in, s.nodes);
    ReadVector(in, s.affected); ReadVector(in, s.offsets); ReadVector(in, s.incoming);
    ReadVector(in, s.before); ReadVector(in, s.after);
    if (in.peek() != EOF) throw std::runtime_error("Trailing snapshot bytes");
    return s;
}
inline uint32_t Weight(uint32_t u, uint32_t v) { return (u + v) % 128 + 1; }
}
