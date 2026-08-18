#ifndef SEPGRAPH_OWNER_COST_PLANNER_H
#define SEPGRAPH_OWNER_COST_PLANNER_H

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace sepgraph { namespace runtime {

struct OwnerPlanCalibration {
    double cpu_edges_per_ms = 1.0;
    double gpu_edges_per_ms = 1.0;
    double boundary_events_per_ms = 1.0;
    double placement_ns_per_edge = 0.0;
};

struct OwnerPlanCandidate {
    std::string name;
    std::vector<uint8_t> cpu_segments;
    uint64_t exact_cpu_edges = 0;
    uint64_t exact_gpu_edges = 0;
    uint64_t boundary_events = 0;
    uint64_t affected_prepare_edges = 0;
    uint64_t topology_delta_records = 0;
    uint64_t host_resident_edges = 0;
    uint64_t migration_bytes = 0;
    bool memory_eligible = true;
};

struct OwnerPlanCost {
    double cpu_ms = 0.0;
    double gpu_ms = 0.0;
    double event_ms = 0.0;
    double dependency_ms = 0.0;
    double topology_ms = 0.0;
    double placement_ms = 0.0;
    double migration_ms = 0.0;
    double total_ms = std::numeric_limits<double>::infinity();
};

struct OwnerPlanDecision {
    size_t candidate = 0;
    OwnerPlanCost cost;
};

class OwnerCostPlanner {
public:
    explicit OwnerCostPlanner(OwnerPlanCalibration calibration)
        : calibration_(calibration) {
        if (calibration_.cpu_edges_per_ms <= 0.0 ||
            calibration_.gpu_edges_per_ms <= 0.0 ||
            calibration_.boundary_events_per_ms <= 0.0) {
            throw std::invalid_argument("planner calibration rates must be positive");
        }
    }

    OwnerPlanCost Evaluate(const OwnerPlanCandidate &candidate) const {
        OwnerPlanCost cost;
        if (!candidate.memory_eligible) return cost;
        cost.cpu_ms = candidate.exact_cpu_edges / calibration_.cpu_edges_per_ms;
        cost.gpu_ms = candidate.exact_gpu_edges / calibration_.gpu_edges_per_ms;
        cost.event_ms = candidate.boundary_events /
            calibration_.boundary_events_per_ms;
        cost.dependency_ms = candidate.affected_prepare_edges /
            calibration_.cpu_edges_per_ms;
        cost.topology_ms = candidate.topology_delta_records /
            calibration_.cpu_edges_per_ms;
        cost.placement_ms = candidate.host_resident_edges *
            calibration_.placement_ns_per_edge / 1.0e6;
        cost.migration_ms = candidate.migration_bytes /
            (calibration_.boundary_events_per_ms * sizeof(uint32_t));
        cost.total_ms = std::max(cost.cpu_ms, cost.gpu_ms) + cost.event_ms +
            cost.dependency_ms + cost.topology_ms + cost.placement_ms +
            cost.migration_ms;
        return cost;
    }

    OwnerPlanDecision Choose(const std::vector<OwnerPlanCandidate> &candidates) const {
        if (candidates.empty()) throw std::invalid_argument("no owner candidates");
        OwnerPlanDecision best;
        best.cost = Evaluate(candidates[0]);
        for (size_t i = 1; i < candidates.size(); ++i) {
            const OwnerPlanCost cost = Evaluate(candidates[i]);
            if (cost.total_ms < best.cost.total_ms) {
                best = {i, cost};
            }
        }
        if (!std::isfinite(best.cost.total_ms)) {
            throw std::runtime_error("no memory-eligible owner plan");
        }
        return best;
    }

private:
    OwnerPlanCalibration calibration_;
};

}} // namespace sepgraph::runtime
#endif
