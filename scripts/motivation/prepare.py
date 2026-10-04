#!/usr/bin/env python3
"""Add guarded probes only to frozen experiment sources; never edit either live engine."""
import difflib
import re
import shutil
from pathlib import Path

HERE = Path(__file__).resolve().parent

def guarded(code):
    return '\n#ifdef CG_MOTIVATION_METER\n' + code + '\n#endif\n'

def replace_once(text, old, new):
    assert text.count(old) == 1, (old[:120], text.count(old))
    return text.replace(old, new, 1)

def function_span(text, name):
    start = text.index('void ' + name + '(')
    opening = text.index('{', start)
    # Locate next method by balanced braces (existing functions have balanced comments).
    depth = 1
    i = opening + 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}')
        i += 1
    return start, i

def edit_function(text, name, edit):
    start, end = function_span(text, name)
    return text[:start] + edit(text[start:end]) + text[end:]

def instrument(src, side):
    original = side == 'original'
    patches = []
    def write(rel, old, new):
        (src / rel).write_text(new)
        patches.extend(difflib.unified_diff(old.splitlines(True), new.splitlines(True), fromfile='a/'+rel, tofile='b/'+rel))
    shutil.copy2(HERE/'meter.h', src/'include/utils/motivation_meter.h')
    rel='CMakeLists.txt'; old=(src/rel).read_text()
    new=old.replace('find_package(CUDA 9 REQUIRED)', '''find_package(CUDA 9 REQUIRED)
option(CG_MOTIVATION_METER "Build isolated motivation probes (default OFF)" OFF)
if(CG_MOTIVATION_METER)
    list(APPEND CUDA_NVCC_FLAGS -DCG_MOTIVATION_METER=1)
endif()''')
    write(rel,old,new)
    rel='include/framework/framework.cuh'; old=(src/rel).read_text()
    text='#include <utils/motivation_meter.h>\n'+old
    location = '''const auto &g=m_vcsr_dev_graph_allocator->m_origin_graph;
                const auto &d=g.sync_vertices_[v];
                return {reinterpret_cast<uint64_t>(g.edges_), uint64_t(d.index), uint64_t(d.degree)};''' if original else '''const auto &d=m_chunk_store->Descriptor(v);
                return {uint64_t(d.slab_id), uint64_t(d.index), uint64_t(d.degree)};'''
    methods = guarded('''
            cgmot::Location MotivationLocation(index_t v) { LOCATION }
            void MotivationBegin(std::pair<index_t,index_t> local, index_t batch) {
                cgmot::begin(batch,m_graph_datum->nnodes);
                if(!cgmot::counts()) return;
                cgmot::sync();
                auto &s=cgmot::state(); auto &load=*m_load_update;
                s.locations.reserve(s.nnodes);
                for(index_t v=0;v<s.nnodes;++v) s.locations.push_back(MotivationLocation(v));
                s.values=cgmot::read_values(m_graph_datum->GetValueDeviceObject(),s.nnodes);
                for(index_t i=local.first;i<local.first+load.m_batch_size[batch].first;++i) {
                    auto e=load.added_edges_w[i]; s.sources.insert(e.u); s.added.emplace_back(e.u,e.v);
                }
                for(index_t i=local.second;i<local.second+load.m_batch_size[batch].second;++i) s.sources.insert(load.deleted_edges_w[i].u);
                s.updated=s.sources.size(); s.seeds_prebatch=cgmot::seeds(s.values);
            }
            void MotivationPreinsert() {
                if(!cgmot::counts()) return;
                cgmot::sync(); auto &s=cgmot::state();
                s.seeds_preinsert=cgmot::seeds(cgmot::read_values(m_graph_datum->GetValueDeviceObject(),s.nnodes));
            }
            void MotivationEnd() {
                if(cgmot::counts()) {
                    cgmot::sync(); auto &s=cgmot::state();
                    for(index_t v=0;v<s.nnodes;++v) {
                        auto before=s.locations[v], after=MotivationLocation(v);
                        if(before.degree && after.degree && (before.base!=after.base || before.offset!=after.offset)) {
                            ++s.relocated; if(!s.sources.count(v)) ++s.relocated_untouched;
                        }
                    }
                }
                cgmot::finish();
            }
'''.replace('LOCATION',location))
    text=replace_once(text,'            void add_edge(std::pair<index_t,index_t>& local_begin,index_t& NumOfSnapShots){',methods+'            void add_edge(std::pair<index_t,index_t>& local_begin,index_t& NumOfSnapShots){\n                CG_MOT(MotivationPreinsert());')
    # Existing full groups already end with stream synchronizations. Add a timing
    # scope to each group, including delete rounds and hybrid filter/compaction.
    text=re.sub(r'(?m)^(\s*)Stopwatch sw_rebuild\(true\);', lambda m: guarded('cgmot::Timer motivation_rebuild(true);') + m.group(0), text)
    text=re.sub(r'(?m)^(\s*)sw_rebuild\.stop\(\);', lambda m: m.group(0) + '\n                CG_MOT(motivation_rebuild.stop());', text)
    # Explicit initial groups not covered by sw_rebuild in the original engine.
    def add_hooks(body):
        marker='Stopwatch sw_load(true);'
        body=replace_once(body,marker,guarded('cgmot::Timer motivation_compute;')+marker)
        if original:
            start=body.index('for(index_t seg_idx',body.index(marker))
            end=body.index('ExecutePolicy_All(next_policy);',start)
            body=body[:start]+guarded('cgmot::Timer motivation_initial(true);')+body[start:end]+'CG_MOT(motivation_initial.stop(); cgmot::state().initial_wl=graph_datum.nnodes);\n'+body[end:]
            start=body.index('for(index_t seg_idx',body.index('ExecutePolicy_All(next_policy);'))
            end=body.index('bool convergence',start)
            body=body[:start]+guarded('cgmot::Timer motivation_postinitial(true);')+body[start:end]+'CG_MOT(motivation_postinitial.stop());\n'+body[end:]
        else:
            body=replace_once(body,'NumOfSnapShots, m_exact_source_frontier_count);','NumOfSnapShots, m_exact_source_frontier_count);\n                    CG_MOT(cgmot::state().initial_wl=m_exact_source_frontier_count);')
        body=replace_once(body,'sw_con.stop();','sw_con.stop();\n                CG_MOT(motivation_compute.stop());')
        return body
    text=edit_function(text,'update_tree_add',add_hooks)
    def del_hooks(body):
        body=replace_once(body,'Stopwatch sw_del(true);',guarded('cgmot::Timer motivation_compute;')+'Stopwatch sw_del(true);')
        if original:
            start=body.index('for(index_t seg_idx',body.index('Stopwatch sw_del'))
            end=body.index('bool convergence',start)
            body=body[:start]+guarded('cgmot::Timer motivation_delinitial(true);')+body[start:end]+'CG_MOT(motivation_delinitial.stop());\n'+body[end:]
            code='''motivation_compute.stop();
                if(cgmot::counts()) {
                    auto &s=cgmot::state();
                    auto after=cgmot::read_values(graph_datum.GetValueDeviceObject(),s.nnodes);
                    for(size_t v=0;v<s.nnodes;++v) if(s.values[v]!=UINT32_MAX && after[v]==UINT32_MAX) ++s.affected;
                }'''
            body=replace_once(body,'sw_del.stop();',guarded(code)+'sw_del.stop();')
        else:
            # Physical deletion is topology maintenance, outside the compute denominator.
            body=replace_once(body,'Stopwatch sw_physical_delete(true);','CG_MOT(motivation_compute.stop());\n                Stopwatch sw_physical_delete(true);')
            body=replace_once(body,'Stopwatch sw_repair(true);','CG_MOT(motivation_compute.resume(); cgmot::state().affected=frontier_end);\n                Stopwatch sw_repair(true);')
            body=replace_once(body,'sw_repair.stop();','sw_repair.stop();\n                CG_MOT(motivation_compute.stop());')
        return body
    text=edit_function(text,'update_tree_del',del_hooks)
    write(rel,old,text)
    rel='include/groute/graphs/csr_graph.cuh'; old=(src/rel).read_text(); text='#include <utils/motivation_meter.h>\n'+old
    if original:
        marker='cudaMemcpy(m_dev_mirror.sync_vertices_, m_origin_graph.sync_vertices_, (nnodes + 1) * sizeof(host::vertex_sync_element),'
        text=edit_function(text,'AllocateDevMirror_node_update',lambda b: b[:b.rfind('}')]+ '\nCG_MOT(if(cgmot::state().active) cgmot::state().descriptor_bytes += uint64_t(nnodes+1)*sizeof(host::vertex_sync_element));\n'+b[b.rfind('}'):])
    else:
        marker='GROUTE_CUDA_CHECK(cudaMemcpyAsync(m_patch_device, m_patch_host,'
        text=text.replace(marker,'CG_MOT(if(cgmot::state().active) cgmot::state().descriptor_bytes += sizeof(*m_patch_host)*sources.size());\n                        '+marker)
    write(rel,old,text)
    rel='samples/hybrid_sssp/hybrid_sssp.cu'; old=(src/rel).read_text(); text=old
    marker='std::cout<<"batch number "<<NumOfSnapShots<<std::endl;'
    text=replace_once(text,marker,marker+'\n        CG_MOT(engine.MotivationBegin(local_begin,NumOfSnapShots));')
    marker='NumOfSnapShots+=1;'
    text=replace_once(text,marker,'CG_MOT(engine.MotivationEnd());\n        '+marker)
    if original:
        text=replace_once(text, '    const auto &distances = engine.GetGraphDatum().host_value;', '    const auto &distances = engine.GetGraphDatum().host_value;' + guarded('''    if(const char *path=std::getenv("CG_MOTIVATION_RESULT_PATH")) {
        std::ofstream out(path);
        for(size_t v=0;v<distances.size();++v) out << v << " " << distances[v] << "\\n";
    }'''))
    write(rel,old,text)
    return ''.join(patches)
