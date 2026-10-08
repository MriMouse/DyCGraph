#!/usr/bin/env python3
"""Materialize isolated compile-time ablations; never compiles or runs a GPU job."""
import argparse, hashlib, itertools, json, shutil
from pathlib import Path
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEFAULT_BASE = ROOT / 'paper/evaluation/raw/sssp_bfs_20260927/current_src'

def replace(text, old, new, count=1):
    actual = text.count(old)
    if actual != count:
        raise RuntimeError(f'Patch anchor expected {count}, found {actual}: {old[:100]!r}')
    return text.replace(old, new)

def span(text, start, end, new):
    a = text.index(start); b = text.index(end, a)
    return text[:a] + new + text[b:]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def transform(src, storage, worklist, view):
    fw = src/'include/framework/framework.cuh'
    csr = src/'include/groute/graphs/csr_graph.cuh'
    f, c = fw.read_text(), csr.read_text()
    if not storage:
        c = replace(c, '#include <groute/graphs/source_local_chunk_store.h>',
            '#define SourceLocalChunkStore UnusedChunkBackend\n#include <groute/graphs/source_local_chunk_store.h>\n#undef SourceLocalChunkStore')
        c = replace(c, '        namespace single\n',
            '    }\n}\n#include <ablation/pma_store.h>\nnamespace groute { namespace graphs {\n        namespace single\n')
        start = '        uint64_t chunk_required_edges = 0;'
        end = '        if constexpr (AppImplDeviceObject::kComponentLabels)'
        f = span(f, start, end, '''        m_chunk_store.reset(new topology::SourceLocalChunkStore(vcsr_graph));
        m_vcsr_dev_graph_allocator = std::unique_ptr<groute::graphs::single::PMAGraphAllocator>(
            new groute::graphs::single::PMAGraphAllocator(vcsr_graph,seg_nedges_csr_max));
        m_vcsr_dev_graph_allocator->BindChunkStore(*m_chunk_store);
        LOG("[ABLATION-PMA] authoritative=legacy_pma relocation_tracking=full_descriptor_scan\\n");

''')
        f = replace(f, 'max_patch_records, FLAGS_check);',
            'm_vcsr_dev_graph_allocator->HostObject().nnodes, FLAGS_check);')
        # Original resize has an unsigned decrement-loop bug and no backing
        # allocation bound check. Fail closed outside reserved capacity.
        c = replace(c, '                    elem_capacity *= 2;', '''                    if (elem_capacity > elem_capacity_max / 2)
                        throw std::runtime_error("ablation PMA reserved capacity exhausted");
                    elem_capacity *= 2;''')
        c = replace(c, 'for(index_t curr_vertex = nnodes - 1; curr_vertex >= 0; curr_vertex--) {',
                         'for(index_t curr_vertex = nnodes; curr_vertex-- > 0;) {')
        c = replace(c, '                        if(ii == end_vertex) ii -= 1;',
            (HERE/'pma_rebalance_fallback.inc').read_text().rstrip())
    if not worklist:
        driver = src/'include/framework/variants/driver.cuh'
        d = replace(driver.read_text(), '    namespace kernel {',
            '    namespace kernel {\n' + (HERE/'dense_invalidation.cuh').read_text())
        driver.write_text(d)
        start = '                while (!AppImplDeviceObject::kComponentLabels && frontier_begin < frontier_end) {'
        end = '                sw_invalidation.stop();'
        f = span(f, start, end, '''                thrust::device_vector<uint8_t> processed(graph_datum.nnodes, 0);
                auto &dense_frontier = graph_datum.m_wl_array_in_seg[FLAGS_SEGMENT];
                while (true) {
                    dense_frontier.ResetAsync(stream_s.cuda_stream);
                    KernelSizing(grid_dims, block_dims, graph_datum.nnodes);
                    kernel::AblationScanReset<<<grid_dims, block_dims, 0, stream_s.cuda_stream>>>(
                        graph_datum.nnodes, graph_datum.m_node_reset_datum,
                        thrust::raw_pointer_cast(processed.data()), dense_frontier.DeviceObject());
                    stream_s.Sync();
                    const uint32_t count = dense_frontier.GetCount(stream_s);
                    if (count == 0) break;
                    RunSyncPushDDB_del(app_inst, true, vcsr_graph, graph_datum,
                        dense_frontier.GetDeviceDataPtr(), count,
                        m_device_affected_vertices.DeviceObject(), m_engine_options, stream_s);
                    stream_s.Sync();
                    ++invalidation_rounds;
                    if (invalidation_rounds > graph_datum.nnodes)
                        throw std::runtime_error("ablation dense invalidation did not converge");
                }
                frontier_end = m_device_affected_vertices.GetCount(stream_s);
                dense_frontier.ResetAsync(stream_s.cuda_stream);
                stream_s.Sync();
                LOG("[ABLATION-WORKLIST] deletion=full_vertex_scan rounds=%u insertion=all_vertices\\n", invalidation_rounds);
''')
        # Without an insertion epoch the retained segment executor takes its
        # original all-vertex seed and global RebuildArrayWorklist path.
        f = replace(f, '                m_running_info.current_round = 0;\n                Stopwatch sw_con(true);',
                         '                m_running_info.current_round = 0;\n                m_insertion_convergence_round = 0;\n                Stopwatch sw_con(true);')
        for algo in ('sssp','bfs'):
            app = src/f'samples/hybrid_{algo}/hybrid_{algo}.cu'
            a = replace(app.read_text(), 'static constexpr bool kSupportsGpuDeletionRepair = true;',
                        'static constexpr bool kSupportsGpuDeletionRepair = false;')
            # Origin repairs deletions as part of the global final-topology
            # convergence. Its intermediate deletion state is not a fixed point.
            pos = a.index('        engine.del_edge(local_begin,NumOfSnapShots);')
            prefix, suffix = a[:pos], a[pos:]
            suffix = suffix.replace('if (FLAGS_check) {', 'if (false && FLAGS_check) {', 1)
            app.write_text(prefix + suffix)
    if not view:
        # Preserve current topology encoding, replace sparse H2D/scatter with
        # origin's full (V+1) compatible descriptor mirror copy.
        c = replace(c, '                void PublishSparse(const std::vector<index_t> &sources,',
            '                std::vector<host::vertex_sync_element> m_ablation_full_descriptors;\n\n                void PublishSparse(const std::vector<index_t> &sources,')
        needle = '''                    if (m_publication_count != 0) {
                        GROUTE_CUDA_CHECK(cudaMemcpyAsync(m_patch_device, m_patch_host,'''
        full = '''                    m_ablation_full_descriptors.resize(m_origin_graph.nnodes + 1);
                    for (index_t s = 0; s < m_origin_graph.nnodes; ++s) {
                        const auto &d = m_chunk_store->Descriptor(s);
                        m_ablation_full_descriptors[s] = {
                            d.slab_id == sepgraph::topology::SourceLocalChunkStore::kInvalidSlab ? 0 :
                            (static_cast<uint64_t>(d.slab_id) << 32) | static_cast<uint32_t>(d.index), d.degree};
                    }
                    m_ablation_full_descriptors.back() = {0, 0};
                    GROUTE_CUDA_CHECK(cudaMemcpyAsync(m_dev_mirror.sync_vertices_,
                        m_ablation_full_descriptors.data(), m_ablation_full_descriptors.size() * sizeof(host::vertex_sync_element),
                        cudaMemcpyHostToDevice, stream));
                    std::printf("[ABLATION-VIEW] descriptor_records=%zu descriptor_bytes=%zu cache_patch=0\\n",
                        m_ablation_full_descriptors.size(), m_ablation_full_descriptors.size() * sizeof(host::vertex_sync_element));
                    if (m_publication_count != 0 && audit) {
                        GROUTE_CUDA_CHECK(cudaMemcpyAsync(m_patch_device, m_patch_host,'''
        c = replace(c, needle, full)
        c = span(c, '                        ScatterTopologyPatch<<<(m_publication_count + 255)',
                    '                        if (audit) {', '')
        for name, edges in [('read_del','del_edges_d'), ('read_add','added_edges_d')]:
            begin = f.index('            void '+name+'(')
            end = f.index('\n            }', begin)
            method = f[begin:end]
            marker = '                if (size == 0) {\n                    return;\n                }'
            method = replace(method, marker, marker + '''
                dim3 grid_dims, block_dims;
                KernelSizing(grid_dims, block_dims, size);
                kernel::reset_pr_del_edges<<<grid_dims, block_dims, 0, m_stream->cuda_stream>>>(
                    *m_app_inst, m_vcsr_dev_graph_allocator->DeviceObject(),
                    this->''' + edges + ''', this->work_size_d);
                m_stream->Sync();''')
            f = f[:begin]+method+f[end:]
        f = span(f, '                if (admitted != 0 && m_cache_refresh_gate.published()) {',
            '                LOG("[F1-CACHE-GATE]', '''                const bool missing_desired = true;
                const bool refresh = true;
                if (admitted != 0) {
                    KernelSizing(grid_dims, block_dims, work_source.get_size());
                    kernel::mark_cache_candidates<<<grid_dims, block_dims, 0, stream_s.cuda_stream>>>(
                        vcsr_graph, work_source, graph_datum.d_id.Current());
                    stream_s.Sync();
                }
                search_rebuild.stop();
''')
        f = replace(f, '                return m_cache_refresh_gate.refresh_required();', '                return true;')
        # Reverse maintenance belongs to W and remains incremental.
    fw.write_text(f); csr.write_text(c)
    extra = src/'include/ablation'; extra.mkdir(exist_ok=True)
    shutil.copy2(HERE/'pma_store.h', extra/'pma_store.h')
    for algo in ('sssp','bfs'):
        main = src/f'samples/hybrid_{algo}/main.cu'
        t = main.read_text()
        t = replace(t, 'int main(int argc, char **argv) {',
            'int main(int argc, char **argv) {\n' +
            f'    fprintf(stderr, "[ABLATION-CONFIG] storage={storage} worklist={worklist} view={view}\\n");')
        main.write_text(t)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--base', type=Path, default=DEFAULT_BASE)
    p.add_argument('--out', type=Path, default=ROOT/'build/ablation_20261004')
    p.add_argument('--storage', choices=['0','1'])
    p.add_argument('--worklist', choices=['0','1'])
    p.add_argument('--view', choices=['0','1'])
    p.add_argument('--variants', nargs='+', default=['111','011','101','110'], choices=[''.join(v) for v in itertools.product('01', repeat=3)])
    args=p.parse_args(); base=args.base.resolve(); out=args.out.resolve()
    switches = [args.storage, args.worklist, args.view]
    if any(v is not None for v in switches):
        if not all(v is not None for v in switches): p.error('supply all three --storage --worklist --view switches')
        args.variants = [''.join(switches)]
    if out == base or base in out.parents: raise SystemExit('Output must be outside the frozen base')
    # Refuse overwrites: a prepared/built experiment is immutable.
    if out.exists(): raise SystemExit(f'Output exists; choose a new --out: {out}')
    out.mkdir(parents=True)
    source_files={str(x.relative_to(base)):digest(x) for folder in ('include','src','samples') for x in sorted((base/folder).rglob('*')) if x.is_file()}
    for v in args.variants:
        dst=out/v/'src'; dst.mkdir(parents=True)
        for folder in ('include','src','samples','deps','tests'):
            if (base/folder).exists(): shutil.copytree(base/folder,dst/folder)
        shutil.copy2(base/'CMakeLists.txt',dst/'CMakeLists.txt')
        transform(dst,*map(int,v))
        if v[0] == '0':
            shutil.copy2(HERE/'pma_bridge_test.cu', dst/'samples/pma_bridge_test.cu')
            with (dst/'CMakeLists.txt').open('a') as cmake:
                cmake.write('\ncuda_add_executable(ablation_pma_bridge_test samples/pma_bridge_test.cu)\ntarget_link_libraries(ablation_pma_bridge_test ${EXTRA_LIBS})\n')
        (out/v/'source_manifest.json').write_text(json.dumps({str(x.relative_to(dst)):digest(x) for folder in ('include','src','samples') for x in sorted((dst/folder).rglob('*')) if x.is_file()},indent=2)+'\n')
    (out/'manifest.json').write_text(json.dumps(dict(base=str(base),variants=args.variants,switch_order=['storage','worklist','view'],base_sha256=source_files,prepared_only=True),indent=2)+'\n')
    print(out)
if __name__=='__main__': main()
