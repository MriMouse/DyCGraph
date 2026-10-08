#pragma once
// Included after host::PMAGraph is defined. The old PMA remains authoritative;
// no chunk copy of adjacency is allocated. This bridge only supplies the
// descriptor/epoch/effective-delta interface needed by the retained components.
namespace sepgraph { namespace topology {
class SourceLocalChunkStore {
    groute::graphs::host::PMAGraph &graph_;
    std::vector<TopologyDescriptor> descriptors_;
    std::vector<index_t> changed_;
    concurrency::FixedWorkerPool workers_{1};
    uint64_t published_ = 0, pending_ = 0, edges_ = 0;
    bool pending_batch_ = false;
public:
    static constexpr uint32_t kInvalidSlab = UINT32_MAX;
    // Multiple mapped aliases of the same contiguous PMA allocation preserve
    // the existing high32=slab/low32=offset GPU descriptor ABI, including rows
    // crossing an alias boundary. No adjacency is copied into chunks.
    explicit SourceLocalChunkStore(groute::graphs::host::PMAGraph &graph)
        : graph_(graph), descriptors_(graph.nnodes), edges_(graph.nedges) {
        for (index_t s = 0; s < graph.nnodes; ++s)
            descriptors_[s] = {static_cast<uint32_t>(graph.sync_vertices_[s].index), graph.sync_vertices_[s].degree,
                static_cast<uint32_t>(graph.sync_vertices_[s].index >> 32), 0};
    }
    concurrency::FixedWorkerPool &MutationWorkers() { return workers_; }
    const std::vector<index_t> &ChangedSources() const { return changed_; }
    const TopologyDescriptor &Descriptor(index_t s) const { return descriptors_.at(s); }
    uint64_t EdgeCount() const { return edges_; }
    uint64_t PublishedEpoch() const { return published_; }
    uint64_t PendingEpoch() const { return pending_; }
    bool IsPublished() const { return !pending_batch_; }
    uint64_t ReclaimThrough(uint64_t) { return 0; }
    uint64_t Publish() {
        if (!pending_batch_) throw std::logic_error("PMA publish without pending epoch");
        pending_batch_ = false; return published_ = pending_;
    }
    size_t SlabCount() const { return (graph_.elem_capacity_max + (1ULL << 32) - 1) >> 32; }
    const index_t *SlabData(uint32_t slab) const {
        if (slab >= SlabCount()) throw std::out_of_range("PMA slab");
        return graph_.edges_ + (static_cast<uint64_t>(slab) << 32);
    }
    uint64_t MetadataBytes() const { return descriptors_.size() * sizeof(TopologyDescriptor); }
    std::vector<index_t> Neighbors(index_t s) const {
        const auto &d = Descriptor(s);
        return {SlabData(d.slab_id) + d.index, SlabData(d.slab_id) + d.index + d.degree};
    }
    SourceTopologyDigest Digest(index_t s) const { return DigestSource(s, Neighbors(s)); }
    uint64_t OrderedHash(index_t s) const {
        const auto &d = Descriptor(s);
        uint64_t h = 1469598103934665603ULL;
        for (uint64_t i = 0; i < d.degree; ++i) { h ^= SlabData(d.slab_id)[d.index+i]; h *= 1099511628211ULL; }
        h ^= d.degree; return h * 1099511628211ULL;
    }
    template<class Observer>
    ChunkStoreBatchMetrics ApplyGroupedPhase(const GroupedUpdateBatch &batch, UpdatePhase phase, Observer &observer) {
        const auto begin = std::chrono::steady_clock::now();
        if (phase == UpdatePhase::Delete) {
            if (pending_batch_) throw std::logic_error("PMA uncommitted epoch");
            pending_ = published_ + 1; pending_batch_ = true;
        } else if (phase != UpdatePhase::Add || !pending_batch_) {
            throw std::logic_error("PMA phase order");
        }
        if (pending_ > UINT32_MAX) throw std::overflow_error("PMA epoch overflow");
        ChunkStoreBatchMetrics metrics; metrics.epoch = pending_; metrics.worker_count = 1;
        std::vector<EffectiveEdgeDelta> effective;
        std::vector<uint8_t> touched(graph_.nnodes, 0);
        // Plan successful occurrences before mutation, preserving reverse's
        // Prepare-before-forward / nonthrowing-Commit contract.
        for (size_t j = 0; j < batch.PhaseSize(phase); ++j) {
            const size_t i = batch.SourceIndex(j, phase);
            const index_t s = batch.sources[i];
            if (s >= graph_.nnodes) throw std::out_of_range("PMA update source");
            const auto view = batch.View(i, phase);
            if (phase == UpdatePhase::Delete) {
                auto row = Neighbors(s);
                for (const auto dst : view.deletions) {
                    ++metrics.update_count;
                    const auto it = std::find(row.begin(), row.end(), dst);
                    if (it == row.end()) { ++metrics.missing_deletes; continue; }
                    row.erase(it); effective.push_back({s, dst, -1});
                }
            } else {
                for (const auto dst : view.additions) {
                    if (dst >= graph_.nnodes) throw std::out_of_range("PMA update destination");
                    ++metrics.update_count; effective.push_back({s, dst, 1});
                }
            }
        }
        observer.Prepare(effective);
        for (const auto &e : effective) {
            if (e.count < 0) {
                if (!graph_.del_edge(e.source, e.destination, 1))
                    throw std::logic_error("PMA planned deletion missing");
                // Legacy del_edge does not decrement density counters. Keep
                // them consistent to avoid a spurious resize across batches.
                for (index_t j = graph_.get_segment_id(e.source); j; j /= 2)
                    --graph_.segment_edges_actual[j];
                --edges_;
            } else {
                graph_.nedges = edges_ + 1;
                graph_.insert(e.source, e.destination, 1); ++edges_;
            }
            graph_.nedges = edges_;
            touched[e.source] = 1;
        }
        observer.Commit();
        changed_.clear();
        // Relocation is NOT bounded by requested sources in a PMA. Compare
        // every descriptor, include moved neighbors, charge this scan to P0.
        for (index_t s = 0; s < graph_.nnodes; ++s) {
            auto &d = descriptors_[s]; const auto &p = graph_.sync_vertices_[s];
            if (touched[s] || ((static_cast<uint64_t>(d.slab_id) << 32) | d.index) != p.index || d.degree != p.degree) {
                d = {static_cast<uint32_t>(p.index), p.degree, static_cast<uint32_t>(p.index >> 32), static_cast<uint32_t>(pending_)};
                changed_.push_back(s);
            }
        }
        metrics.effective_records = effective.size(); metrics.changed_sources = changed_.size();
        metrics.touched_sources = batch.PhaseSize(phase);
        metrics.mutation_ms = std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-begin).count();
        return metrics;
    }
};
}}
