#include <algorithm>
#include <cstdint>
#include <iostream>
#include <queue>
#include <numeric>
#include <stdexcept>
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <vector>

#include <framework/affected_component_trace.h>

namespace {

struct DisjointSet {
    explicit DisjointSet(size_t count) : parent(count), size(count, 1) {
        std::iota(parent.begin(), parent.end(), 0);
    }
    size_t Find(size_t value) {
        while (parent[value] != value) {
            parent[value] = parent[parent[value]];
            value = parent[value];
        }
        return value;
    }
    void Unite(size_t left, size_t right) {
        left = Find(left);
        right = Find(right);
        if (left == right) return;
        if (size[left] < size[right]) std::swap(left, right);
        parent[right] = left;
        size[left] += size[right];
    }
    std::vector<size_t> parent;
    std::vector<uint64_t> size;
};

struct Component {
    uint64_t vertices = 0;
    uint64_t terminal_vertices = 0;
    uint64_t outgoing_work = 0;
    uint64_t incoming = 0;
    uint64_t internal = 0;
};

struct PropagationComponent {
    uint64_t vertices = 0;
    uint64_t outgoing_work = 0;
    uint64_t incoming = 0;
    uint64_t internal = 0;
};

struct DirectedStats {
    uint64_t components = 0;
    uint64_t largest_vertices = 0;
    std::vector<uint32_t> component;
    std::vector<uint64_t> component_vertices;
};

DirectedStats ComputeScc(const sepgraph::affected_component::Batch &batch,
                         const std::unordered_map<index_t, size_t> &local,
                         bool exclude_sinks) {
    const size_t count = batch.affected_vertices.size();
    std::vector<std::vector<uint32_t>> forward(count), reverse(count);
    for (size_t dst = 0; dst < count; ++dst) {
        if (exclude_sinks && batch.affected_out_degrees[dst] == 0) continue;
        for (uint64_t edge = batch.incoming_offsets[dst];
             edge < batch.incoming_offsets[dst + 1]; ++edge) {
            const auto found = local.find(batch.incoming_sources[edge]);
            if (found == local.end() ||
                (exclude_sinks && batch.affected_out_degrees[found->second] == 0)) {
                continue;
            }
            forward[found->second].push_back(static_cast<uint32_t>(dst));
            reverse[dst].push_back(static_cast<uint32_t>(found->second));
        }
    }
    std::vector<uint8_t> visited(count, 0);
    std::vector<uint32_t> order;
    order.reserve(count);
    for (uint32_t root = 0; root < count; ++root) {
        if (visited[root] || (exclude_sinks && batch.affected_out_degrees[root] == 0)) {
            continue;
        }
        std::vector<std::pair<uint32_t, size_t>> stack{{root, 0}};
        visited[root] = 1;
        while (!stack.empty()) {
            auto &frame = stack.back();
            if (frame.second < forward[frame.first].size()) {
                const uint32_t next = forward[frame.first][frame.second++];
                if (!visited[next]) {
                    visited[next] = 1;
                    stack.emplace_back(next, 0);
                }
            } else {
                order.push_back(frame.first);
                stack.pop_back();
            }
        }
    }
    std::fill(visited.begin(), visited.end(), 0);
    DirectedStats stats;
    stats.component.assign(count, std::numeric_limits<uint32_t>::max());
    for (auto it = order.rbegin(); it != order.rend(); ++it) {
        if (visited[*it]) continue;
        uint64_t component_vertices = 0;
        std::vector<uint32_t> stack{*it};
        visited[*it] = 1;
        while (!stack.empty()) {
            const uint32_t vertex = stack.back();
            stack.pop_back();
            ++component_vertices;
            stats.component[vertex] = static_cast<uint32_t>(stats.components);
            for (const uint32_t next : reverse[vertex]) {
                if (!visited[next]) {
                    visited[next] = 1;
                    stack.push_back(next);
                }
            }
        }
        ++stats.components;
        stats.component_vertices.push_back(component_vertices);
        stats.largest_vertices = std::max(stats.largest_vertices, component_vertices);
    }
    return stats;
}

struct SubDagCandidate {
    uint64_t vertices = 0;
    uint64_t scc = 0;
    uint64_t sinks = 0;
    uint64_t incoming = 0;
    uint64_t internal = 0;
    uint64_t snapshot_boundary_edges = 0;
    uint64_t snapshot_boundary_sources = 0;
    uint64_t changed_boundary_sources = 0;
    uint64_t changed_boundary_events = 0;
    uint64_t outgoing_work = 0;
    uint64_t service_work = 0;
    uint64_t successor_cut_edges = 0;
    uint64_t successor_cut_sources = 0;
    uint64_t successor_cut_destinations = 0;
    uint64_t independent_gpu_vertices = 0;
    uint64_t independent_gpu_incoming = 0;
    uint64_t independent_gpu_outgoing = 0;
    uint64_t independent_gpu_service_work = 0;
    uint64_t dependent_gpu_vertices = 0;
    uint64_t dependent_gpu_incoming = 0;
    uint64_t dependent_gpu_outgoing = 0;
    uint64_t dependent_gpu_service_work = 0;
    uint64_t cpu_critical_path_depth = 0;
    uint64_t cpu_critical_path_service_work = 0;
    uint64_t independent_gpu_critical_path_depth = 0;
    uint64_t independent_gpu_critical_path_service_work = 0;
    uint64_t dependent_gpu_critical_path_depth = 0;
    uint64_t dependent_gpu_critical_path_service_work = 0;
    uint64_t critical_path_depth = 0;
    uint64_t critical_path_service_work = 0;
};

struct SubDagAudit {
    uint64_t candidate_count = 0;
    std::vector<SubDagCandidate> top;
};

bool BetterCandidate(const SubDagCandidate &left, const SubDagCandidate &right) {
    if (left.outgoing_work != right.outgoing_work) {
        return left.outgoing_work > right.outgoing_work;
    }
    return left.internal > right.internal;
}

struct CriticalPath {
    uint64_t depth = 0;
    uint64_t service_work = 0;
};

CriticalPath ComputeCriticalPath(const std::vector<uint32_t> &nodes,
                                 const std::vector<std::vector<uint32_t>> &successors,
                                 const std::vector<uint8_t> &included,
                                 const std::vector<uint64_t> &service_work) {
    std::vector<uint64_t> indegree(successors.size(), 0);
    for (const uint32_t source : nodes) {
        if (!included[source]) continue;
        for (const uint32_t destination : successors[source]) {
            if (included[destination]) ++indegree[destination];
        }
    }
    std::priority_queue<uint32_t, std::vector<uint32_t>, std::greater<uint32_t>> ready;
    for (const uint32_t node : nodes) {
        if (included[node] && indegree[node] == 0) ready.push(node);
    }
    std::vector<uint64_t> work(successors.size(), 0), depth(successors.size(), 0);
    CriticalPath result;
    while (!ready.empty()) {
        const uint32_t node = ready.top();
        ready.pop();
        if (depth[node] == 0) {
            depth[node] = 1;
            work[node] = service_work[node];
        }
        if (work[node] > result.service_work ||
            (work[node] == result.service_work && depth[node] > result.depth)) {
            result = {depth[node], work[node]};
        }
        for (const uint32_t destination : successors[node]) {
            if (!included[destination]) continue;
            const uint64_t candidate_work = work[node] + service_work[destination];
            const uint64_t candidate_depth = depth[node] + 1;
            if (candidate_work > work[destination] ||
                (candidate_work == work[destination] &&
                 candidate_depth > depth[destination])) {
                work[destination] = candidate_work;
                depth[destination] = candidate_depth;
            }
            if (--indegree[destination] == 0) ready.push(destination);
        }
    }
    return result;
}

SubDagAudit ComputeClosedSubDags(
        const sepgraph::affected_component::Batch &batch,
        const std::unordered_map<index_t, size_t> &local,
        const DirectedStats &scc) {
    const size_t scc_count = static_cast<size_t>(scc.components);
    std::vector<std::vector<uint32_t>> successors(scc_count);
    std::vector<uint64_t> indegree(scc_count, 0), scc_work(scc_count, 0);
    std::vector<uint64_t> scc_incoming(scc_count, 0), scc_vertices(scc_count, 0);
    std::vector<std::vector<size_t>> scc_vertex_indices(scc_count);
    std::vector<std::vector<size_t>> forward_vertices(batch.affected_vertices.size());
    std::vector<size_t> weak_root(scc_count);
    std::iota(weak_root.begin(), weak_root.end(), 0);
    auto find_root = [&](size_t value) {
        while (weak_root[value] != value) {
            weak_root[value] = weak_root[weak_root[value]];
            value = weak_root[value];
        }
        return value;
    };
    auto unite = [&](size_t left, size_t right) {
        left = find_root(left);
        right = find_root(right);
        if (left != right) weak_root[right] = left;
    };
    std::unordered_set<uint64_t> dag_edges;
    dag_edges.reserve(batch.incoming_sources.size());
    for (size_t vertex = 0; vertex < batch.affected_vertices.size(); ++vertex) {
        const uint32_t component = scc.component[vertex];
        scc_work[component] += batch.affected_out_degrees[vertex];
        scc_incoming[component] +=
            batch.incoming_offsets[vertex + 1] - batch.incoming_offsets[vertex];
        ++scc_vertices[component];
        scc_vertex_indices[component].push_back(vertex);
        for (uint64_t edge = batch.incoming_offsets[vertex];
             edge < batch.incoming_offsets[vertex + 1]; ++edge) {
            const auto found = local.find(batch.incoming_sources[edge]);
            if (found == local.end()) continue;
            const uint32_t source_scc = scc.component[found->second];
            const uint32_t destination_scc = scc.component[vertex];
            forward_vertices[found->second].push_back(vertex);
            unite(source_scc, destination_scc);
            if (source_scc == destination_scc) continue;
            const uint64_t key = (static_cast<uint64_t>(source_scc) << 32) | destination_scc;
            if (dag_edges.insert(key).second) {
                successors[source_scc].push_back(destination_scc);
                ++indegree[destination_scc];
            }
        }
    }
    std::vector<uint64_t> scc_service_work(scc_count, 0);
    for (size_t id = 0; id < scc_count; ++id) {
        // A complete repair service performs incoming reduce, one commit per vertex,
        // and non-sink expansion. Sink commits remain represented by scc_vertices.
        scc_service_work[id] = scc_incoming[id] + scc_vertices[id] + scc_work[id];
    }
    uint64_t total_vertices = 0, total_incoming = 0, total_outgoing = 0,
             total_service_work = 0;
    for (size_t id = 0; id < scc_count; ++id) {
        total_vertices += scc_vertices[id];
        total_incoming += scc_incoming[id];
        total_outgoing += scc_work[id];
        total_service_work += scc_service_work[id];
    }
    std::vector<uint32_t> all_scc(scc_count);
    std::iota(all_scc.begin(), all_scc.end(), 0);

    std::unordered_map<size_t, std::vector<uint32_t>> weak_components;
    for (uint32_t id = 0; id < scc_count; ++id) weak_components[find_root(id)].push_back(id);
    std::unordered_map<size_t, std::vector<size_t>> weak_vertices;
    for (size_t vertex = 0; vertex < batch.affected_vertices.size(); ++vertex) {
        weak_vertices[find_root(scc.component[vertex])].push_back(vertex);
    }
    SubDagAudit audit;
    for (const auto &entry : weak_components) {
        const auto &members = entry.second;
        const auto &vertices = weak_vertices.at(entry.first);
        uint64_t total_work = 0;
        std::vector<uint8_t> belongs(scc_count, 0);
        std::vector<uint64_t> remaining_indegree(scc_count, 0);
        std::priority_queue<uint32_t, std::vector<uint32_t>, std::greater<uint32_t>> ready;
        for (const uint32_t id : members) {
            belongs[id] = 1;
            remaining_indegree[id] = indegree[id];
            total_work += scc_work[id];
            if (indegree[id] == 0) ready.push(id);
        }
        std::vector<uint32_t> order;
        while (!ready.empty()) {
            const uint32_t id = ready.top();
            ready.pop();
            order.push_back(id);
            for (const uint32_t next : successors[id]) {
                if (belongs[next] && --remaining_indegree[next] == 0) ready.push(next);
            }
        }
        if (order.size() != members.size()) throw std::runtime_error("invalid condensation DAG");

        const uint64_t targets[] = {(total_work + 3) / 4, (total_work + 1) / 2,
                                    (total_work * 3 + 3) / 4, total_work};
        std::vector<uint8_t> selected(scc_count, 0);
        uint64_t selected_work = 0;
        size_t target_index = 0;
        for (size_t position = 0; position < order.size(); ++position) {
            selected[order[position]] = 1;
            selected_work += scc_work[order[position]];
            while (target_index < 4 &&
                   ((target_index < 3 && selected_work >= targets[target_index]) ||
                    (target_index == 3 && position + 1 == order.size()))) {
                SubDagCandidate candidate;
                candidate.scc = position + 1;
                std::unordered_set<index_t> boundary_sources;
                for (const size_t vertex : vertices) {
                    if (!selected[scc.component[vertex]]) continue;
                    ++candidate.vertices;
                    candidate.sinks += batch.affected_out_degrees[vertex] == 0;
                    candidate.outgoing_work += batch.affected_out_degrees[vertex];
                    candidate.service_work +=
                        (batch.incoming_offsets[vertex + 1] - batch.incoming_offsets[vertex]) +
                        1 + batch.affected_out_degrees[vertex];
                    for (uint64_t edge = batch.incoming_offsets[vertex];
                         edge < batch.incoming_offsets[vertex + 1]; ++edge) {
                        ++candidate.incoming;
                        const index_t source = batch.incoming_sources[edge];
                        const auto found = local.find(source);
                        if (found != local.end() && selected[scc.component[found->second]]) {
                            ++candidate.internal;
                        } else {
                            ++candidate.snapshot_boundary_edges;
                            boundary_sources.insert(source);
                        }
                    }
                }
                candidate.snapshot_boundary_sources = boundary_sources.size();
                // The report retains the globally strongest eight candidates by the
                // established work ranking. Only those need the expensive successor
                // reachability and critical-path audit.
                ++audit.candidate_count;
                if (audit.top.size() == 8 &&
                    !BetterCandidate(candidate, audit.top.back())) {
                    ++target_index;
                    continue;
                }

                std::unordered_set<index_t> changed_boundary_sources;
                for (const index_t source : batch.changed_source_events) {
                    if (boundary_sources.count(source) == 0) continue;
                    ++candidate.changed_boundary_events;
                    changed_boundary_sources.insert(source);
                }
                candidate.changed_boundary_sources = changed_boundary_sources.size();

                uint64_t selected_vertices = 0, selected_incoming = 0,
                         selected_outgoing = 0, selected_service_work = 0;
                for (const uint32_t id : members) {
                    if (!selected[id]) continue;
                    selected_vertices += scc_vertices[id];
                    selected_incoming += scc_incoming[id];
                    selected_outgoing += scc_work[id];
                    selected_service_work += scc_service_work[id];
                }
                std::vector<uint8_t> dependent(scc_count, 0);
                std::queue<uint32_t> reachable;
                for (const uint32_t id : members) {
                    if (selected[id]) reachable.push(id);
                }
                while (!reachable.empty()) {
                    const uint32_t source = reachable.front();
                    reachable.pop();
                    for (const uint32_t destination : successors[source]) {
                        if (!selected[destination] && !dependent[destination]) {
                            dependent[destination] = 1;
                            reachable.push(destination);
                        }
                    }
                }
                uint64_t dependent_vertices = 0, dependent_incoming = 0,
                         dependent_outgoing = 0, dependent_service_work = 0;
                for (const uint32_t id : members) {
                    if (!dependent[id]) continue;
                    dependent_vertices += scc_vertices[id];
                    dependent_incoming += scc_incoming[id];
                    dependent_outgoing += scc_work[id];
                    dependent_service_work += scc_service_work[id];
                }
                std::unordered_set<index_t> successor_sources, successor_destinations;
                for (const uint32_t source_scc : members) {
                    if (!selected[source_scc]) continue;
                    for (const size_t source : scc_vertex_indices[source_scc]) {
                        for (const size_t destination : forward_vertices[source]) {
                            if (!selected[scc.component[destination]]) {
                                ++candidate.successor_cut_edges;
                                successor_sources.insert(batch.affected_vertices[source]);
                                successor_destinations.insert(batch.affected_vertices[destination]);
                            }
                        }
                    }
                }
                candidate.successor_cut_sources = successor_sources.size();
                candidate.successor_cut_destinations = successor_destinations.size();
                candidate.dependent_gpu_vertices = dependent_vertices;
                candidate.dependent_gpu_incoming = dependent_incoming;
                candidate.dependent_gpu_outgoing = dependent_outgoing;
                candidate.dependent_gpu_service_work = dependent_service_work;
                candidate.independent_gpu_vertices =
                    total_vertices - selected_vertices - dependent_vertices;
                candidate.independent_gpu_incoming =
                    total_incoming - selected_incoming - dependent_incoming;
                candidate.independent_gpu_outgoing =
                    total_outgoing - selected_outgoing - dependent_outgoing;
                candidate.independent_gpu_service_work =
                    total_service_work - selected_service_work - dependent_service_work;
                std::vector<uint8_t> independent(scc_count, 0);
                for (uint32_t id = 0; id < scc_count; ++id) {
                    if (!selected[id] && !dependent[id]) independent[id] = 1;
                }
                candidate.cpu_critical_path_depth =
                    ComputeCriticalPath(members, successors, selected, scc_service_work).depth;
                candidate.cpu_critical_path_service_work =
                    ComputeCriticalPath(members, successors, selected, scc_service_work).service_work;
                const CriticalPath independent_path =
                    ComputeCriticalPath(all_scc, successors, independent, scc_service_work);
                candidate.independent_gpu_critical_path_depth = independent_path.depth;
                candidate.independent_gpu_critical_path_service_work = independent_path.service_work;
                const CriticalPath dependent_path =
                    ComputeCriticalPath(members, successors, dependent, scc_service_work);
                candidate.dependent_gpu_critical_path_depth = dependent_path.depth;
                candidate.dependent_gpu_critical_path_service_work = dependent_path.service_work;
                const CriticalPath full_path =
                    ComputeCriticalPath(members, successors, belongs, scc_service_work);
                candidate.critical_path_depth = full_path.depth;
                candidate.critical_path_service_work = full_path.service_work;
                audit.top.push_back(candidate);
                std::sort(audit.top.begin(), audit.top.end(), BetterCandidate);
                if (audit.top.size() > 8) audit.top.pop_back();
                ++target_index;
            }
        }
    }
    return audit;
}

void Analyze(const sepgraph::affected_component::Batch &batch) {
    const size_t count = batch.affected_vertices.size();
    std::unordered_map<index_t, size_t> local;
    local.reserve(count * 2 + 1);
    for (size_t i = 0; i < count; ++i) local.emplace(batch.affected_vertices[i], i);
    DisjointSet sets(count);
    DisjointSet propagation_sets(count);
    std::unordered_set<index_t> boundary_sources;
    for (size_t dst = 0; dst < count; ++dst) {
        for (uint64_t edge = batch.incoming_offsets[dst];
             edge < batch.incoming_offsets[dst + 1]; ++edge) {
            const auto found = local.find(batch.incoming_sources[edge]);
            if (found != local.end()) {
                sets.Unite(dst, found->second);
                if (batch.affected_out_degrees[dst] != 0 &&
                    batch.affected_out_degrees[found->second] != 0) {
                    propagation_sets.Unite(dst, found->second);
                }
            } else {
                boundary_sources.insert(batch.incoming_sources[edge]);
            }
        }
    }
    const DirectedStats state_scc = ComputeScc(batch, local, false);
    const DirectedStats propagation_scc = ComputeScc(batch, local, true);
    const SubDagAudit sub_dags =
        ComputeClosedSubDags(batch, local, state_scc);
    std::unordered_map<size_t, Component> components;
    components.reserve(count + 1);
    for (size_t dst = 0; dst < count; ++dst) {
        auto &component = components[sets.Find(dst)];
        ++component.vertices;
        component.terminal_vertices += batch.affected_out_degrees[dst] == 0;
        component.outgoing_work += batch.affected_out_degrees[dst];
        component.incoming += batch.incoming_offsets[dst + 1] - batch.incoming_offsets[dst];
        for (uint64_t edge = batch.incoming_offsets[dst];
             edge < batch.incoming_offsets[dst + 1]; ++edge) {
            if (local.find(batch.incoming_sources[edge]) != local.end()) ++component.internal;
        }
    }
    std::vector<Component> ranked;
    ranked.reserve(components.size());
    for (const auto &entry : components) ranked.push_back(entry.second);
    std::sort(ranked.begin(), ranked.end(), [](const Component &a, const Component &b) {
        return a.incoming > b.incoming;
    });
    uint64_t internal = 0;
    uint64_t terminal = 0;
    uint64_t outgoing_work = 0;
    std::unordered_map<size_t, PropagationComponent> propagation_components;
    for (size_t vertex = 0; vertex < count; ++vertex) {
        if (batch.affected_out_degrees[vertex] == 0) continue;
        auto &component = propagation_components[propagation_sets.Find(vertex)];
        ++component.vertices;
        component.outgoing_work += batch.affected_out_degrees[vertex];
        component.incoming +=
            batch.incoming_offsets[vertex + 1] - batch.incoming_offsets[vertex];
        for (uint64_t edge = batch.incoming_offsets[vertex];
             edge < batch.incoming_offsets[vertex + 1]; ++edge) {
            const auto found = local.find(batch.incoming_sources[edge]);
            if (found != local.end() &&
                batch.affected_out_degrees[found->second] != 0 &&
                propagation_sets.Find(found->second) == propagation_sets.Find(vertex)) {
                ++component.internal;
            }
        }
    }
    std::vector<PropagationComponent> propagation_ranked;
    propagation_ranked.reserve(propagation_components.size());
    for (const auto &entry : propagation_components) {
        propagation_ranked.push_back(entry.second);
    }
    std::sort(propagation_ranked.begin(), propagation_ranked.end(),
              [](const PropagationComponent &a, const PropagationComponent &b) {
                  return a.outgoing_work > b.outgoing_work;
              });
    for (const auto &component : ranked) {
        internal += component.internal;
        terminal += component.terminal_vertices;
        outgoing_work += component.outgoing_work;
    }
    std::cout << "[F1-COMPONENT] batch=" << batch.batch
              << " affected_vertices=" << count
              << " incoming_edges=" << batch.incoming_sources.size()
              << " internal_edges=" << internal
              << " boundary_incoming_edges=" << batch.incoming_sources.size() - internal
              << " unique_boundary_sources=" << boundary_sources.size()
              << " sink_vertices=" << terminal
              << " partition_excluded_sinks=" << terminal
              << " propagation_vertices=" << count - terminal
              << " outgoing_work=" << outgoing_work
              << " state_components=" << ranked.size()
              << " state_scc=" << state_scc.components
              << " largest_state_scc_vertices=" << state_scc.largest_vertices
              << " propagation_components=" << propagation_ranked.size()
              << " propagation_scc=" << propagation_scc.components
              << " largest_propagation_scc_vertices="
              << propagation_scc.largest_vertices
              << " largest_propagation_vertices="
              << (propagation_ranked.empty() ? 0 : propagation_ranked.front().vertices)
              << " largest_propagation_outgoing="
              << (propagation_ranked.empty() ? 0 : propagation_ranked.front().outgoing_work)
              << " closed_subdag_candidates=" << sub_dags.candidate_count
              << " changed_source_events=" << batch.changed_source_events.size()
              << " unique_changed_sources="
              << std::unordered_set<index_t>(batch.changed_source_events.begin(),
                                             batch.changed_source_events.end()).size()
              << " changed_boundary_sources_available="
              << (batch.changed_source_events_available ? 1 : 0);
    const size_t reported = std::min<size_t>(ranked.size(), 8);
    for (size_t i = 0; i < reported; ++i) {
        std::cout << " c" << i << "_vertices=" << ranked[i].vertices
                  << " c" << i << "_incoming=" << ranked[i].incoming
                  << " c" << i << "_internal=" << ranked[i].internal
                  << " c" << i << "_boundary=" << ranked[i].incoming - ranked[i].internal
                  << " c" << i << "_terminal=" << ranked[i].terminal_vertices
                  << " c" << i << "_outgoing=" << ranked[i].outgoing_work;
    }
    const size_t propagation_reported = std::min<size_t>(propagation_ranked.size(), 8);
    for (size_t i = 0; i < propagation_reported; ++i) {
        const auto &component = propagation_ranked[i];
        std::cout << " p" << i << "_vertices=" << component.vertices
                  << " p" << i << "_incoming=" << component.incoming
                  << " p" << i << "_internal=" << component.internal
                  << " p" << i << "_boundary="
                  << component.incoming - component.internal
                  << " p" << i << "_outgoing=" << component.outgoing_work;
    }
    const size_t sub_dag_reported = sub_dags.top.size();
    for (size_t i = 0; i < sub_dag_reported; ++i) {
        const auto &candidate = sub_dags.top[i];
        std::cout << " d" << i << "_vertices=" << candidate.vertices
                  << " d" << i << "_scc=" << candidate.scc
                  << " d" << i << "_sinks=" << candidate.sinks
                  << " d" << i << "_incoming=" << candidate.incoming
                  << " d" << i << "_internal=" << candidate.internal
                  << " d" << i << "_snapshot_boundary_edges="
                  << candidate.snapshot_boundary_edges
                  << " d" << i << "_snapshot_boundary_sources="
                  << candidate.snapshot_boundary_sources
                  << " d" << i << "_changed_boundary_sources="
                  << candidate.changed_boundary_sources
                  << " d" << i << "_changed_boundary_events="
                  << candidate.changed_boundary_events
                  << " d" << i << "_outgoing=" << candidate.outgoing_work
                  << " d" << i << "_service_work=" << candidate.service_work
                  << " d" << i << "_successor_cut_edges=" << candidate.successor_cut_edges
                  << " d" << i << "_successor_cut_sources=" << candidate.successor_cut_sources
                  << " d" << i << "_successor_cut_destinations="
                  << candidate.successor_cut_destinations
                  << " d" << i << "_independent_gpu_vertices="
                  << candidate.independent_gpu_vertices
                  << " d" << i << "_independent_gpu_incoming="
                  << candidate.independent_gpu_incoming
                  << " d" << i << "_independent_gpu_outgoing="
                  << candidate.independent_gpu_outgoing
                  << " d" << i << "_independent_gpu_service_work="
                  << candidate.independent_gpu_service_work
                  << " d" << i << "_dependent_gpu_vertices=" << candidate.dependent_gpu_vertices
                  << " d" << i << "_dependent_gpu_incoming="
                  << candidate.dependent_gpu_incoming
                  << " d" << i << "_dependent_gpu_outgoing="
                  << candidate.dependent_gpu_outgoing
                  << " d" << i << "_dependent_gpu_service_work="
                  << candidate.dependent_gpu_service_work
                  << " d" << i << "_cpu_critical_path_depth="
                  << candidate.cpu_critical_path_depth
                  << " d" << i << "_cpu_critical_path_service_work="
                  << candidate.cpu_critical_path_service_work
                  << " d" << i << "_independent_gpu_critical_path_depth="
                  << candidate.independent_gpu_critical_path_depth
                  << " d" << i << "_independent_gpu_critical_path_service_work="
                  << candidate.independent_gpu_critical_path_service_work
                  << " d" << i << "_dependent_gpu_critical_path_depth="
                  << candidate.dependent_gpu_critical_path_depth
                  << " d" << i << "_dependent_gpu_critical_path_service_work="
                  << candidate.dependent_gpu_critical_path_service_work
                  << " d" << i << "_critical_path_depth=" << candidate.critical_path_depth
                  << " d" << i << "_critical_path_service_work="
                  << candidate.critical_path_service_work;
    }
    std::cout << '\n';
}

} // namespace

int main(int argc, char **argv) {
    try {
        if (argc == 2 && std::string(argv[1]) == "--self-test") {
            sepgraph::affected_component::Batch batch;
            batch.batch = 7;
            batch.affected_vertices = {1, 2, 3, 4};
            batch.affected_out_degrees = {2, 1, 0, 3};
            batch.incoming_offsets = {0, 2, 5, 6, 7};
            batch.incoming_sources = {9, 9, 1, 8, 8, 2, 10};
            batch.changed_source_events = {1, 1, 4, 9};
            batch.changed_source_events_available = true;
            Analyze(batch);
            return 0;
        }
        if (argc != 2) {
            throw std::runtime_error("usage: affected_component_analyzer TRACE|--self-test");
        }
        for (const auto &batch : sepgraph::affected_component::ReadTrace(argv[1])) Analyze(batch);
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "affected_component_analyzer: " << error.what() << '\n';
        return 1;
    }
}
