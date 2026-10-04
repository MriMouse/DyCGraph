// Count source edge records and distinct endpoint IDs without sorting edges.
// Reuse the workload generator's text / packed uint64 parsing conventions.
#define main paper_generator_main
#include "../../../scripts/paper_data_stream.cpp"
#undef main

int main(int argc, char** argv) {
  try {
    if (argc != 3) throw std::runtime_error("usage: count_graph PATH MODE");
    Reader reader(argv[1], argv[2]);
    std::vector<uint64_t> present;
    uint64_t edges = 0, loops = 0;
    uint32_t minimum = UINT32_MAX, maximum = 0;
    Edge edge;
    while (reader.next(edge)) {
      ++edges;
      loops += edge.u == edge.v;
      for (uint32_t id : {edge.u, edge.v}) {
        minimum = std::min(minimum, id);
        maximum = std::max(maximum, id);
        size_t word = size_t(id) >> 6;
        if (word >= present.size()) present.resize(word + 1);
        present[word] |= uint64_t(1) << (id & 63);
      }
    }
    if (ferror(reader.f)) throw std::runtime_error("source read failed");
    uint64_t vertices = 0;
    for (uint64_t word : present) vertices += __builtin_popcountll(word);
    std::cout << "{\"edge_records\":" << edges
              << ",\"distinct_endpoint_vertices\":" << vertices
              << ",\"min_id\":" << minimum << ",\"max_id\":" << maximum
              << ",\"self_loop_records\":" << loops << "}\n";
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
