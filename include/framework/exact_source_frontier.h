#ifndef SEPGRAPH_EXACT_SOURCE_FRONTIER_H
#define SEPGRAPH_EXACT_SOURCE_FRONTIER_H

#include <algorithm>
#include <cstdint>
#include <stdexcept>
#include <unordered_map>
#include <vector>

#include <groute/graphs/common.h>

namespace sepgraph { namespace runtime {

struct ExactSourceEvent {
    index_t source = 0;
    uint32_t epoch = 0;
    uint32_t version = 0;
};

struct ExactSourceFrontierMetrics {
    uint64_t offered_events = 0;
    uint64_t accepted_events = 0;
    uint64_t stale_or_duplicate_events = 0;
    uint64_t coalesced_events = 0;
    uint64_t unique_sources = 0;
    uint64_t logical_edges = 0;
};

class ExactSourceFrontier {
public:
    explicit ExactSourceFrontier(index_t node_count)
        : node_count_(node_count) {}

    void BeginEpoch(uint32_t epoch) {
        if (epoch == 0 || epoch <= epoch_)
            throw std::logic_error("exact-source epoch must increase");
        epoch_ = epoch;
        latest_versions_.clear();
        metrics_ = {};
    }

    bool Offer(const ExactSourceEvent &event) {
        if (event.source >= node_count_)
            throw std::out_of_range("exact-source event source");
        if (event.epoch != epoch_ || event.version == 0)
            throw std::invalid_argument("exact-source event epoch/version");
        ++metrics_.offered_events;
        auto inserted = latest_versions_.emplace(event.source, event.version);
        if (inserted.second) {
            ++metrics_.accepted_events;
            return true;
        }
        if (event.version <= inserted.first->second) {
            ++metrics_.stale_or_duplicate_events;
            return false;
        }
        inserted.first->second = event.version;
        ++metrics_.accepted_events;
        ++metrics_.coalesced_events;
        return true;
    }

    template <typename DegreeReader>
    std::vector<index_t> Seal(DegreeReader degree) {
        if (epoch_ == 0) throw std::logic_error("exact-source epoch not started");
        std::vector<index_t> sources;
        sources.reserve(latest_versions_.size());
        for (const auto &entry : latest_versions_) sources.push_back(entry.first);
        std::sort(sources.begin(), sources.end());
        metrics_.unique_sources = sources.size();
        metrics_.logical_edges = 0;
        for (const index_t source : sources) metrics_.logical_edges += degree(source);
        return sources;
    }

    uint32_t Epoch() const { return epoch_; }
    const ExactSourceFrontierMetrics &Metrics() const { return metrics_; }

private:
    index_t node_count_ = 0;
    uint32_t epoch_ = 0;
    std::unordered_map<index_t, uint32_t> latest_versions_;
    ExactSourceFrontierMetrics metrics_;
};

} }
#endif
