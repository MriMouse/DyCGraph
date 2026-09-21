// Streaming candidate audit. Base must be an occurrence subsequence of source.
#include "../include/utils/i19_edge_reader.h"
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <queue>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>
uint64_t hash64(uint64_t z) {
  z += 0x9e3779b97f4a7c15ULL;
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  return z ^ (z >> 31);
}
uint64_t pairkey(uint32_t a, uint32_t b) { return (uint64_t(a) << 32) | b; }
struct Candidate {
  uint64_t rank, occ, pair;
  bool operator<(const Candidate &b) const {
    return rank != b.rank ? rank < b.rank : occ < b.occ;
  }
};
using Heap = std::priority_queue<Candidate>;
void take(Heap &q, size_t k, Candidate c) {
  if (q.size() < k)
    q.push(c);
  else if (c < q.top()) {
    q.pop();
    q.push(c);
  }
}
std::vector<Candidate> sorted(Heap &q) {
  std::vector<Candidate> v;
  while (!q.empty()) {
    v.push_back(q.top());
    q.pop();
  }
  std::sort(v.begin(), v.end());
  return v;
}
int main(int argc, char **argv) {
  try {
    if (argc != 7)
      throw std::runtime_error(
          "usage: pool SOURCE BASE OUT_PREFIX dense|identity COUNT SEED");
    const bool dense = std::string(argv[4]) == "dense";
    size_t count = std::stoull(argv[5]);
    uint64_t seed = std::stoull(argv[6]);
    if (!count)
      throw std::runtime_error("zero count");
    std::vector<uint32_t> mapping;
    uint64_t source_edges = 0;
    uint32_t nodes = 0, a, b;
    if (dense) {
      std::vector<bool> present;
      Reader r(argv[1]);
      while (r.edge(a, b)) {
        auto m = std::max(a, b);
        if (m == UINT32_MAX)
          throw std::runtime_error("universe overflow");
        if (present.size() <= m)
          present.resize(size_t(m) + 1);
        present[a] = present[b] = true;
        ++source_edges;
      }
      mapping.resize(present.size(), UINT32_MAX);
      for (size_t i = 0; i < present.size(); ++i)
        if (present[i])
          mapping[i] = nodes++;
      std::ofstream map(std::string(argv[3]) + ".mapping.u32",
                        std::ios::binary);
      map.write(reinterpret_cast<char *>(mapping.data()), mapping.size() * 4);
      if (!map)
        throw std::runtime_error("map write failed");
      std::cerr << "mapping nodes=" << nodes << " edges=" << source_edges
                << std::endl;
    }
    Heap ins, del;
    uint64_t seen = 0, base_edges = 0;
    uint32_t x, y;
    Reader base(argv[2]);
    bool has = base.edge(x, y);
    {
      Reader r(argv[1]);
      while (r.edge(a, b)) {
        if (dense) {
          a = mapping.at(a);
          b = mapping.at(b);
        } else {
          if (std::max(a, b) == UINT32_MAX)
            throw std::runtime_error("universe overflow");
          nodes = std::max(nodes, std::max(a, b) + 1);
        }
        uint64_t p = pairkey(a, b);
        bool in_base = has && a == x && b == y;
        if (in_base) {
          ++base_edges;
          take(del, count, {hash64(seen ^ seed), seen, p});
          has = base.edge(x, y);
        } else
          take(ins, count * 2, {hash64(seen ^ seed), seen, p});
        if (++seen % 100000000 == 0)
          std::cerr << "source_scan=" << seen << std::endl;
      }
    }
    if (has)
      throw std::runtime_error(
          "base not a source subsequence (mapping/cohort mismatch)");
    if (dense && seen != source_edges)
      throw std::runtime_error("source changed");
    source_edges = seen;
    auto dv = sorted(del), iv = sorted(ins);
    if (dv.size() != count)
      throw std::runtime_error("deletion pool insufficient");
    std::unordered_map<uint64_t, uint64_t> multiplicity;
    for (auto c : dv)
      multiplicity.emplace(c.pair, 0);
    for (auto c : iv)
      multiplicity.emplace(c.pair, 0);
    std::vector<uint64_t> degree(nodes);
    uint64_t verified = 0;
    {
      Reader r(argv[2]);
      while (r.edge(a, b)) {
        if (a >= nodes || b >= nodes)
          throw std::runtime_error("base ID");
        ++degree[a];
        ++verified;
        auto it = multiplicity.find(pairkey(a, b));
        if (it != multiplicity.end())
          ++it->second;
      }
    }
    if (verified != base_edges)
      throw std::runtime_error("base changed");
    std::unordered_set<uint64_t> used;
    std::vector<Candidate> valid;
    size_t overlaps = 0, duplicates = 0;
    for (auto c : iv) {
      if (multiplicity.at(c.pair)) {
        ++overlaps;
        continue;
      }
      if (!used.insert(c.pair).second) {
        ++duplicates;
        continue;
      }
      if (valid.size() < count)
        valid.push_back(c);
    }
    if (valid.size() != count)
      throw std::runtime_error(
          "legal insertion pool insufficient; no fallback permitted");
    auto write = [&](const char *suffix, const std::vector<Candidate> &v) {
      std::ofstream out(std::string(argv[3]) + suffix);
      for (auto c : v)
        out << (c.pair >> 32) << ' ' << uint32_t(c.pair) << ' ' << c.occ << ' '
            << multiplicity.at(c.pair) << ' ' << degree[c.pair >> 32] << '\n';
      if (!out)
        throw std::runtime_error("pool write failed");
    };
    write(".delete.tsv", dv);
    write(".insert.tsv", valid);
    std::ofstream deg(std::string(argv[3]) + ".degrees.u64", std::ios::binary);
    deg.write(reinterpret_cast<char *>(degree.data()), degree.size() * 8);
    if (!deg)
      throw std::runtime_error("degree write failed");
    std::ofstream meta(std::string(argv[3]) + ".json");
    meta << "{\"nodes\":" << nodes << ",\"source_edges\":" << source_edges
         << ",\"base_edges\":" << base_edges << ",\"candidate_count\":" << count
         << ",\"insert_base_overlap_rejected\":" << overlaps
         << ",\"insert_duplicate_pair_rejected\":" << duplicates << "}\n";
    if (!meta)
      throw std::runtime_error("metadata write failed");
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << std::endl;
    return 1;
  }
}
