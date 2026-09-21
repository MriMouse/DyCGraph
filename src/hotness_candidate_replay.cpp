#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <vector>
#include <framework/weighted_score_index.h>

using namespace sepgraph::hotness;
using Clock = std::chrono::steady_clock;
double Milliseconds(Clock::time_point start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

int main(int argc, char **argv) {
    try {
        if (argc != 2) throw std::runtime_error("Usage: hotness_candidate_replay TRACE");
        std::ifstream input(argv[1], std::ios::binary);
        if (Read<uint64_t>(input) != kTraceMagic) throw std::runtime_error("Invalid I15 trace magic");
        const uint32_t n = Read<uint32_t>(input);
        WeightedScoreIndex index;
        int32_t next_batch = -1;
        double total_update_ms = 0, total_query_ms = 0, total_output_ms = 0;
        std::cout << std::fixed << std::setprecision(3);
        while (input.peek() != EOF) {
            const int32_t batch = Read<int32_t>(input);
            if (batch != next_batch++) throw std::runtime_error("Nonconsecutive I15 sample");
            const uint64_t capacity = Read<uint64_t>(input);
            const uint32_t expected_count = Read<uint32_t>(input);
            const uint64_t expected_order = Read<uint64_t>(input);
            const uint64_t expected_desired = Read<uint64_t>(input);
            const uint32_t count = Read<uint32_t>(input);
            if (count > n || expected_count > n || (batch == -1 && count != n))
                throw std::runtime_error("Invalid I15 record count");
            std::vector<Change> changes(count);
            input.read(reinterpret_cast<char *>(changes.data()), count * sizeof(Change));
            if (!input) throw std::runtime_error("Truncated I15 changes");
            std::vector<bool> seen(n, false);
            for (const auto &change : changes) {
                if (change.vertex >= n || change.score >= kScoreCount || seen[change.vertex])
                    throw std::runtime_error("Invalid or duplicate I15 change");
                seen[change.vertex] = true;
            }
            auto start = Clock::now();
            if (batch == -1) {
                std::vector<uint32_t> scores(n), degrees(n);
                for (const auto &change : changes) {
                    scores[change.vertex] = change.score;
                    degrees[change.vertex] = change.degree;
                }
                index.Initialize(scores, degrees);
            } else {
                for (const auto &change : changes) index.Apply(change);
            }
            const double update_ms = Milliseconds(start);
            start = Clock::now();
            const uint32_t admitted = index.CandidateCount(capacity);
            const double query_ms = Milliseconds(start);
            start = Clock::now();
            uint32_t visited = 0, zero_desired = 0;
            uint64_t order_hash = kHashSeed, desired_hash = kHashSeed, desired_edges = 0;
            index.Visit([&](uint32_t v, uint32_t score, uint32_t degree) {
                order_hash = HashRecord(order_hash, v, score, degree);
                if (visited++ < admitted) {
                    desired_hash = HashRecord(desired_hash, v, score, degree);
                    desired_edges += degree;
                    zero_desired += score == 0;
                }
            });
            const double output_ms = Milliseconds(start);
            if (visited != n || admitted != expected_count ||
                order_hash != expected_order || desired_hash != expected_desired)
                throw std::runtime_error("I15 index/oracle mismatch at batch " + std::to_string(batch));
            if (batch >= 0) {
                total_update_ms += update_ms;
                total_query_ms += query_ms;
                total_output_ms += output_ms;
            }
            std::cout << "[I15-INDEX] batch=" << batch << " vertices=" << n
                << " changes=" << count << " desired=" << admitted
                << " zero_desired=" << zero_desired << " desired_edges=" << desired_edges
                << " update_ms=" << update_ms << " query_ms=" << query_ms
                << " full_oracle_visit_ms=" << output_ms << " index_bytes=" << index.bytes()
                << " mismatches=0\n" << std::flush;
        }
        if (next_batch <= 0) throw std::runtime_error("I15 trace has no update samples");
        std::cout << "[I15-INDEX-TOTAL] batches=" << next_batch
            << " update_ms=" << total_update_ms << " query_ms=" << total_query_ms
            << " full_oracle_visit_ms=" << total_output_ms << " mismatches=0\n";
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
