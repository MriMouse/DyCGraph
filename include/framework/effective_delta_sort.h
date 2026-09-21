#ifndef SEPGRAPH_EFFECTIVE_DELTA_SORT_H
#define SEPGRAPH_EFFECTIVE_DELTA_SORT_H

#include <array>
#include <utils/fixed_worker_pool.h>
#include <framework/effective_update_batch.h>

namespace sepgraph {
namespace topology {

inline void SortEffectiveDeltas(std::vector<EffectiveEdgeDelta> &records,
                                concurrency::FixedWorkerPool *workers = nullptr) {
    const auto less = [](const EffectiveEdgeDelta &a, const EffectiveEdgeDelta &b) {
        return a.destination < b.destination ||
            (a.destination == b.destination && a.source < b.source);
    };
    // Comparison sorting avoids a scratch allocation for small update lists.
    if (records.size() < 4096) {
        std::sort(records.begin(), records.end(), less);
        return;
    }
    std::vector<EffectiveEdgeDelta> scratch(records.size());
    // Forward effective records are already source-ordered. Stable destination
    // passes preserve that minor-key order; arbitrary callers still sort both.
    const bool source_sorted = std::is_sorted(records.begin(), records.end(),
        [](const EffectiveEdgeDelta &a, const EffectiveEdgeDelta &b) {
            return a.source < b.source;
        });
    // Logical contiguous partitions preserve stability regardless of which
    // persistent worker executes them. Small lists retain the serial path.
    const size_t partitions = workers && records.size() >= 65536
        ? workers->WorkerCount() : 0;
    std::vector<std::array<size_t, 256>> histograms(partitions);
    for (unsigned pass = source_sorted ? 4 : 0; pass < 8; ++pass) {
        std::array<size_t, 256> offsets{};
        const auto digit = [pass](const EffectiveEdgeDelta &record) {
            const uint32_t key = pass < 4 ? record.source : record.destination;
            return (key >> ((pass % 4) * 8)) & 255U;
        };
        if (partitions > 1) {
            workers->Run(partitions, [&](size_t part) {
                auto &counts = histograms[part];
                counts.fill(0);
                for (size_t i = records.size() * part / partitions;
                     i < records.size() * (part + 1) / partitions; ++i)
                    ++counts[digit(records[i])];
            }, 1);
            size_t offset = 0;
            for (size_t bucket = 0; bucket < 256; ++bucket)
                for (size_t part = 0; part < partitions; ++part) {
                    const size_t count = histograms[part][bucket];
                    histograms[part][bucket] = offset;
                    offset += count;
                }
            workers->Run(partitions, [&](size_t part) {
                auto &positions = histograms[part];
                for (size_t i = records.size() * part / partitions;
                     i < records.size() * (part + 1) / partitions; ++i)
                    scratch[positions[digit(records[i])]++] = records[i];
            }, 1);
            records.swap(scratch);
            continue;
        }
        for (const auto &record : records) ++offsets[digit(record)];
        size_t total = 0;
        for (auto &offset : offsets) {
            const size_t count = offset;
            offset = total;
            total += count;
        }
        for (const auto &record : records) scratch[offsets[digit(record)]++] = record;
        records.swap(scratch);
    }
}

} // namespace topology
} // namespace sepgraph
#endif
