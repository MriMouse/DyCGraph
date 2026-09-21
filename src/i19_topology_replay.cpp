// CPU-only production mutation/reverse preparation replay. No CUDA context.
#include <algorithm>
#include <chrono>
#include <framework/dynamic_reverse_index.h>
#include <fstream>
#include <groute/graphs/source_local_chunk_store.h>
#include <iostream>
#include <nlohmann/json.hpp>
#include <sys/resource.h>
#include <unordered_map>
#include <unordered_set>
#include <utils/i19_edge_reader.h>
using namespace sepgraph::topology;
using sepgraph::runtime::DynamicReverseIndex;
using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
double elapsed(Clock::time_point t) {
  return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}
struct Graph {
  index_t nnodes;
  std::unordered_map<index_t, std::vector<index_t>> edges;
  struct View {
    const Graph *g;
    uint64_t Degree(index_t s) const {
      auto it = g->edges.find(s);
      return it == g->edges.end() ? 0 : it->second.size();
    }
    index_t EdgeAt(index_t s, uint64_t i) const { return g->edges.at(s)[i]; }
  };
  View adjacency_view() const { return {this}; }
};
struct Input {
  std::string path;
  json manifest;
  std::vector<TopologyMutationBatch> batches;
};
int main(int argc, char **argv) {
  try {
    if (argc < 2)
      throw std::runtime_error(
          "usage: i19_topology_replay READY_JSON [READY_JSON ...] (same base)");
    std::vector<Input> inputs;
    Graph graph{};
    std::unordered_set<index_t> touched;
    std::string base;
    uint64_t expected_edges = 0;
    for (int arg = 1; arg < argc; ++arg) {
      Input in;
      in.path = argv[arg];
      std::ifstream f(in.path);
      f >> in.manifest;
      auto &m = in.manifest;
      if (m.at("status") != "ready")
        throw std::runtime_error("not ready");
      std::string b = m.at("base").at("path");
      if (!base.empty() && base != b)
        throw std::runtime_error("mixed bases");
      if (!base.empty() &&
          (graph.nnodes != m.at("nodes").get<index_t>() ||
           expected_edges != m.at("base_edges").get<uint64_t>()))
        throw std::runtime_error("inconsistent shared-base metadata");
      base = b;
      graph.nnodes = m.at("nodes");
      expected_edges = m.at("base_edges");
      std::ifstream sizes(m.at("sizes").at("path").get<std::string>()),
          updates(m.at("updates").at("path").get<std::string>());
      uint64_t adds, dels;
      while (sizes >> adds >> dels) {
        TopologyMutationBatch batch;
        for (uint64_t i = 0; i < adds + dels; ++i) {
          char op;
          uint64_t s, d, w;
          if (!(updates >> op >> s >> d >> w) || s >= graph.nnodes ||
              d >= graph.nnodes || w != 1)
            throw std::runtime_error("bad update");
          if (op == 'a')
            batch.additions.push_back({index_t(s), index_t(d)});
          else if (op == 'd')
            batch.deletions.push_back({index_t(s), index_t(d)});
          else
            throw std::runtime_error("bad op");
          touched.insert(s);
        }
        if (batch.additions.size() != adds || batch.deletions.size() != dels)
          throw std::runtime_error("asymmetric size mismatch");
        in.batches.push_back(std::move(batch));
      }
      if (!sizes.eof())
        throw std::runtime_error("malformed batch sizes");
      std::string extra;
      if (updates >> extra)
        throw std::runtime_error("extra update");
      if (in.batches.size() != m.at("batches").get<size_t>())
        throw std::runtime_error("batch count");
      inputs.push_back(std::move(in));
    }
    auto load = Clock::now();
    for (auto s : touched)
      graph.edges.emplace(s, std::vector<index_t>{});
    uint64_t edges = 0;
    uint32_t s, d;
    Reader r(base.c_str());
    while (r.edge(s, d)) {
      if (s >= graph.nnodes || d >= graph.nnodes)
        throw std::runtime_error("base range");
      ++edges;
      auto it = graph.edges.find(s);
      if (it != graph.edges.end())
        it->second.push_back(d);
    }
    if (edges != expected_edges)
      throw std::runtime_error("base count");
    uint64_t materialized = 0, capacity = 0;
    for (const auto &entry : graph.edges) {
      materialized += entry.second.size();
      capacity +=
          SourceLocalChunkStore::RequiredChunkCapacity(entry.second.size());
    }
    std::cout
        << json({{"type", "init"},
                 {"load_ms", elapsed(load)},
                 {"base_edges", edges},
                 {"materialized_edges", materialized},
                 {"materialized_sources", touched.size()},
                 {"scope",
                  "union touched-source forward; reverse base restricted to "
                  "these sources; exact overlay preparation, not SSSP"}})
        << std::endl;
    for (const auto &in : inputs) {
      // Conservative capacity for every possible growth allocation, reclaimed
      // each batch.
      uint64_t reserve = capacity;
      std::unordered_map<index_t, uint64_t> degrees, caps;
      for (const auto &e : graph.edges) {
        degrees[e.first] = e.second.size();
        caps[e.first] =
            SourceLocalChunkStore::RequiredChunkCapacity(e.second.size());
      }
      for (const auto &b : in.batches) {
        std::unordered_map<index_t, uint64_t> adds;
        for (auto e : b.additions)
          ++adds[e.source];
        for (auto e : adds) {
          auto n = SourceLocalChunkStore::RequiredChunkCapacity(
              degrees[e.first] += e.second);
          if (n > caps[e.first]) {
            reserve += n;
            caps[e.first] = n;
          }
        }
      }
      constexpr uint64_t slab = 1 << 24;
      reserve = ((std::max<uint64_t>(reserve, 1) + slab - 1) / slab) * slab;
      SourceLocalChunkStore store(graph.nnodes, {reserve, slab, 4, false, 20});
      for (const auto &e : graph.edges)
        store.LoadSource(e.first, e.second);
      store.FinalizeLoad(edges);
      DynamicReverseIndex reverse;
      reverse.Build(graph, 20, 64);
      auto oracle = graph.edges;
      uint64_t oracle_edges = edges;
      std::unordered_map<index_t, std::unordered_map<index_t, uint64_t>>
          reverse_oracle;
      for (const auto &batch : in.batches) {
        for (auto e : batch.deletions)
          reverse_oracle[e.destination];
        for (auto e : batch.additions)
          reverse_oracle[e.destination];
      }
      for (const auto &row : graph.edges)
        for (auto dst : row.second) {
          auto it = reverse_oracle.find(dst);
          if (it != reverse_oracle.end())
            ++it->second[row.first];
        }
      for (size_t b = 0; b < in.batches.size(); ++b) {
        auto begin = Clock::now();
        GroupedUpdateBatch grouped(in.batches[b]);
        double group_ms = elapsed(begin);
        json phases = json::array();
        double service = group_ms;
        uint64_t descriptor_bytes = 0;
        for (auto phase : {UpdatePhase::Delete, UpdatePhase::Add}) {
          auto t = Clock::now();
          auto m = store.ApplyGroupedPhase(grouped, phase, reverse);
          double ms = elapsed(t);
          service += ms;
          auto rm = reverse.LastPrepareMetrics();
          descriptor_bytes +=
              store.ChangedSources().size() * sizeof(TopologyDescriptor);
          // Independent ordered adjacency oracle; outside mutation timing.
          const auto &requests = phase == UpdatePhase::Delete
                                     ? in.batches[b].deletions
                                     : in.batches[b].additions;
          for (auto e : requests) {
            auto &row = oracle.at(e.source);
            if (phase == UpdatePhase::Delete) {
              auto it = std::find(row.begin(), row.end(), e.destination);
              if (it == row.end())
                throw std::runtime_error("invalid deletion");
              row.erase(it);
              --oracle_edges;
            } else {
              row.push_back(e.destination);
              ++oracle_edges;
            }
          }
          for (size_t i = 0; i < grouped.PhaseSize(phase); ++i) {
            auto src = grouped.sources[grouped.SourceIndex(i, phase)];
            if (store.Neighbors(src) != oracle.at(src))
              throw std::runtime_error("forward oracle mismatch");
          }
          if (m.missing_deletes || m.invalid_additions ||
              store.EdgeCount() != oracle_edges)
            throw std::runtime_error("mutation validity mismatch");
          std::unordered_set<index_t> checked_destinations;
          for (auto e : requests) {
            auto &counts = reverse_oracle.at(e.destination);
            if (phase == UpdatePhase::Delete) {
              auto it = counts.find(e.source);
              if (it == counts.end() || !it->second)
                throw std::runtime_error("reverse oracle deletion");
              if (!--it->second)
                counts.erase(it);
            } else
              ++counts[e.source];
            checked_destinations.insert(e.destination);
          }
          for (auto dst : checked_destinations) {
            std::vector<index_t> expected, actual;
            for (auto c : reverse_oracle.at(dst))
              if (c.second)
                expected.push_back(c.first);
            std::sort(expected.begin(), expected.end());
            reverse.ForEachIncoming(
                dst, [&](index_t src) { actual.push_back(src); });
            if (actual != expected)
              throw std::runtime_error("reverse oracle mismatch");
          }
          phases.push_back(
              {{"phase", phase == UpdatePhase::Delete ? "delete" : "add"},
               {"wall_ms", ms},
               {"prepare_ms", m.prepare_ms},
               {"preflight_ms", m.preflight_ms},
               {"apply_ms", m.apply_ms},
               {"reverse_prepare_ms", m.reverse_prepare_ms},
               {"source_work", m.source_work},
               {"deletion_match_reads", m.deletion_match_reads},
               {"deletion_position_bytes", m.deletion_position_bytes},
               {"mutation_edge_reads", m.mutation_edge_reads},
               {"mutation_written_bytes", m.mutation_written_bytes},
               {"relocation_bytes", m.relocation_copied_bytes},
               {"effective_records", m.effective_records},
               {"source_plan_duplicate_bytes", m.source_plan_duplicate_bytes},
               {"source_plan_index_bytes", m.source_plan_index_bytes},
               {"effective_bytes",
                m.effective_records * sizeof(EffectiveEdgeDelta)},
               {"reverse_copy_bytes",
                rm.input_copy_bytes},
               {"reverse_old_records_read", rm.old_records_read},
               {"reverse_output_records", rm.output_records},
               {"reverse_overlay_records", rm.overlay_records},
               {"reverse_merge_ms", rm.merge_ms}});
        }
        auto t = Clock::now();
        auto epoch = store.Publish();
        auto reclaimed = store.ReclaimThrough(epoch);
        double pub = elapsed(t);
        service += pub;
        rusage usage{};
        getrusage(RUSAGE_SELF, &usage);
        std::cout << json({{"type", "batch"},
                           {"manifest", in.path},
                           {"batch", b},
                           {"B", in.batches[b].deletions.size() +
                                     in.batches[b].additions.size()},
                           {"U", in.batches[b].deletions.size() +
                                     in.batches[b].additions.size()},
                           {"S", grouped.sources.size()},
                           {"group_ms", group_ms},
                           {"cpu_service_ms", service},
                           {"publication_reclaim_ms", pub},
                           {"descriptor_payload_bytes", descriptor_bytes},
                           {"reclaimed_blocks", reclaimed},
                           {"retired_capacity_edges",
                            store.ArenaStats().retired_capacity_edges},
                           {"arena_high_water_edges",
                            store.ArenaStats().high_water_edges},
                           {"graph_edges", store.EdgeCount()},
                           {"rss_peak_kb", usage.ru_maxrss},
                           {"phases", phases},
                           {"forward_oracle", "passed"},
                           {"reverse_oracle", "passed"}})
                  << std::endl;
      }
    }
    return 0;
  } catch (const std::exception &e) {
    std::cerr << e.what() << std::endl;
    return 1;
  }
}
