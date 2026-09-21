#include <framework/i16_repair_snapshot.h>
#include <nlohmann/json.hpp>
#include <cuda_runtime.h>
#include <chrono>
#include <iostream>
#include <sys/resource.h>

using Clock = std::chrono::steady_clock;
double Ms(Clock::time_point t) { return std::chrono::duration<double,std::milli>(Clock::now()-t).count(); }
void Require(bool v,const char *m) { if (!v) throw std::runtime_error(m); }
void Check(cudaError_t e) { if (e!=cudaSuccess) throw std::runtime_error(cudaGetErrorString(e)); }
template<class T> void Release(std::vector<T> &v) { std::vector<T>().swap(v); }
template<class T> struct Device {
    T *p=nullptr; size_t count;
    explicit Device(size_t n):count(n) { if (n) Check(cudaMalloc(&p,n*sizeof(T))); }
    ~Device() { if(p) cudaFree(p); }
    void Free() { if(p) { Check(cudaFree(p)); p=nullptr; } }
    void Copy(const std::vector<T> &v) { Require(v.size()<=count,"Copy exceeds capacity"); if(!v.empty()) Check(cudaMemcpy(p,v.data(),v.size()*sizeof(T),cudaMemcpyHostToDevice)); }
};
struct Counters { unsigned long long edges,successes,duplicates; uint32_t count,overflow; };
__global__ void ResetControl(Counters *stats,uint32_t *control) {
    *stats=Counters{}; control[0]=UINT32_MAX; control[1]=0;
}
__global__ void FindBucket(uint32_t n,const uint32_t *distance,const uint32_t *pending,uint32_t *bucket) {
    for(uint32_t u=blockIdx.x*blockDim.x+threadIdx.x;u<n;u+=blockDim.x*gridDim.x)
        if(pending[u] && distance[u]!=UINT32_MAX) atomicMin(bucket,distance[u]/128);
}
__global__ void SelectBucket(uint32_t n,const uint32_t *distance,uint32_t *pending,uint32_t bucket,
                             uint32_t *frontier,Counters *stats) {
    for(uint32_t u=blockIdx.x*blockDim.x+threadIdx.x;u<n;u+=blockDim.x*gridDim.x)
        if(pending[u] && distance[u]/128==bucket) {
            pending[u]=0; frontier[atomicAdd(&stats->count,1u)]=u;
        }
}
__global__ void FindActiveBucket(const uint32_t *active,uint32_t count,const uint32_t *distance,uint32_t *bucket) {
    for(uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;i<count;i+=blockDim.x*gridDim.x)
        atomicMin(bucket,distance[active[i]]/128);
}
__global__ void PartitionActive(const uint32_t *active,uint32_t count,const uint32_t *distance,
                                uint32_t *pending,uint32_t bucket,uint32_t *selected,uint32_t *selected_count,
                                uint32_t *deferred,Counters *stats,const uint32_t *device_bucket=nullptr,
                                uint32_t reverse_capacity=0) {
    if(device_bucket) bucket=*device_bucket;
    for(uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;i<count;i+=blockDim.x*gridDim.x) {
        const auto u=active[i];
        if(distance[u]/128==bucket) {
            pending[u]=0; selected[atomicAdd(selected_count,1u)]=u;
        } else {
            const auto pos=atomicAdd(&stats->count,1u);
            deferred[reverse_capacity?reverse_capacity-1-pos:pos]=u;
        }
    }
}
__global__ void Expand(const uint32_t *frontier,uint32_t count,const uint64_t *offsets,
                       const uint32_t *outgoing,const uint32_t *ids,uint32_t *distance,
                       uint32_t *queued,uint32_t epoch,uint32_t *next,uint32_t capacity,Counters *stats,
                       const uint32_t *device_count=nullptr,const uint32_t *deferred=nullptr,
                       uint32_t active_count=0) {
    if(device_count) count=*device_count;
    // Partition reserves the output prefix for deferred entries. Relaxation
    // appends only after that prefix, so these copies need no grid-wide barrier.
    if(deferred) for(uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;i<active_count-count;i+=blockDim.x*gridDim.x)
        next[i]=deferred[capacity-1-i];
    for (uint32_t i=blockIdx.x*blockDim.x+threadIdx.x;i<count;i+=blockDim.x*gridDim.x) {
        const auto u=frontier[i];
        const uint32_t value=atomicAdd(distance+u,0u);
        unsigned long long edges=0,success=0,duplicate=0;
        for (uint64_t e=offsets[u];e<offsets[u+1];++e) {
            ++edges; const auto v=outgoing[e];
            const uint64_t candidate=uint64_t(value)+((ids[u]+ids[v])%128+1);
            if (candidate>=UINT32_MAX) continue;
            if (candidate<atomicMin(distance+v,uint32_t(candidate))) {
                ++success;
                if (atomicExch(queued+v,1u)==0) {
                    const auto pos=atomicAdd(&stats->count,1u);
                    if(pos<capacity) next[pos]=v; else atomicExch(&stats->overflow,1u);
                } else ++duplicate;
            }
        }
        atomicAdd(&stats->edges,edges); atomicAdd(&stats->successes,success); atomicAdd(&stats->duplicates,duplicate);
    }
}

int main(int argc,char **argv) {
    try {
        Require(argc==3 || argc==4,"Usage: i17a_delta_replay SNAPSHOT REPORT.json [dense|sparse|device-control|compact|reuse]");
        const std::string mode=argc==4?argv[3]:"sparse";
        Require(mode=="dense" || mode=="sparse" || mode=="device-control" || mode=="compact" || mode=="reuse","Unknown bucket mode");
        const bool reuse=mode=="reuse",compact=mode=="compact" || reuse;
        const bool device_control=mode=="device-control" || compact,sparse=mode!="dense";
        auto total=Clock::now(); const auto s=i16::Load(argv[1]); const double read_ms=Ms(total);
        auto service=Clock::now(); auto stage=Clock::now();
        Require(s.nodes && s.source<s.nodes && s.affected.size()<UINT32_MAX,"Invalid dimensions");
        const uint32_t n=s.affected.size();
        Require(s.offsets.size()==size_t(n)+1 && s.offsets.front()==0 && s.offsets.back()==s.incoming.size() &&
                std::is_sorted(s.offsets.begin(),s.offsets.end()),"Invalid incoming CSR");
        Require(s.before.size()==s.after.size(),"State count mismatch");
        std::vector<uint32_t> local(s.nodes,UINT32_MAX),values(s.nodes,UINT32_MAX),distance(n),parent(n,UINT32_MAX);
        std::vector<uint8_t> seen(s.nodes,0);
        for (uint32_t i=0;i<n;++i) { auto v=s.affected[i]; Require(v<s.nodes && local[v]==UINT32_MAX,"Invalid affected ID"); local[v]=i; }
        for (size_t i=0;i<s.before.size();++i) {
            const auto a=s.before[i],b=s.after[i];
            Require(a.vertex<s.nodes && !seen[a.vertex] && a.vertex==b.vertex,"Invalid state IDs");
            seen[a.vertex]=1; values[a.vertex]=a.value;
            if (local[a.vertex]==UINT32_MAX) Require(a.value==b.value && a.buffer==b.buffer && a.parent==b.parent,"Changed external state");
            else Require(b.buffer==b.value,"Invalid final buffer");
        }
        Require(seen[s.source] && values[s.source]==0,"Missing/invalid source state");
        const double index_ms=Ms(stage); stage=Clock::now();
        std::vector<uint64_t> offsets(size_t(n)+1,0);
        uint64_t internal=0,boundary=0;
        for (uint32_t i=0;i<n;++i) {
            auto dst=s.affected[i]; Require(seen[dst],"Missing affected state"); distance[i]=values[dst];
            for (uint64_t e=s.offsets[i];e<s.offsets[i+1];++e) {
                const auto src=s.incoming[e]; Require(src<s.nodes && seen[src],"Missing incoming state");
                if(local[src]!=UINT32_MAX) { ++offsets[local[src]+1]; ++internal; }
                else {
                    ++boundary;
                    const uint64_t candidate=uint64_t(values[src])+i16::Weight(src,dst);
                    if(candidate<distance[i]) distance[i]=candidate;
                }
            }
        }
        for(uint32_t i=0;i<n;++i) offsets[i+1]+=offsets[i];
        const double boundary_count_ms=Ms(stage); stage=Clock::now();
        // End offsets become start offsets as the reused cursor is decremented.
        std::vector<uint64_t> cursor;
        if(!reuse) cursor=offsets;
        else for(uint32_t i=0;i<n;++i) offsets[i]=offsets[i+1];
        std::vector<uint32_t> outgoing(internal),initial;
        for(uint32_t i=0;i<n;++i) {
            if(distance[i]!=UINT32_MAX) initial.push_back(i);
            for(uint64_t e=s.offsets[i];e<s.offsets[i+1];++e) {
                auto src=s.incoming[e];
                if(local[src]!=UINT32_MAX) outgoing[reuse?--offsets[local[src]]:cursor[local[src]]++]=i;
            }
        }
        const double transpose_ms=Ms(stage),setup_ms=index_ms+boundary_count_ms+transpose_ms; stage=Clock::now();
        Check(cudaSetDevice(0)); Check(cudaFree(nullptr));
        size_t free_before,total_device; Check(cudaMemGetInfo(&free_before,&total_device));
        Device<uint64_t> d_offsets(offsets.size()); Device<uint32_t> d_outgoing(internal),d_ids(n),d_distance(n),q1(n),q2(n),queued(n);
        Device<Counters> counters(1);
        Device<uint32_t> selected(sparse && !compact?n:0),selected_count(sparse && !device_control?1:0),control(device_control?2:0);
        size_t free_after; Check(cudaMemGetInfo(&free_after,&total_device));
        const double allocation_ms=Ms(stage); stage=Clock::now();
        d_offsets.Copy(offsets); d_outgoing.Copy(outgoing); d_ids.Copy(s.affected); d_distance.Copy(distance); q1.Copy(initial);
        std::vector<uint32_t> pending(n,0);
        for(auto u:initial) pending[u]=1;
        queued.Copy(pending); Check(cudaDeviceSynchronize());
        const double h2d_ms=Ms(stage); stage=Clock::now();
        uint32_t count=initial.size(),epoch=0; uint32_t *current=q1.p,*next=q2.p;
        const uint32_t delta=128;
        double selection_ms=0, expansion_ms=0;
        uint64_t selection_checks=0,control_bytes=0,control_reads=0;
        const uint32_t selection_blocks=std::max<uint32_t>(1,std::min<uint64_t>(65535,(uint64_t(n)+255)/256));
        uint64_t scans=0,successes=0,duplicates=0,enqueued=count,peak=count,processed=0;
        uint64_t pending_entries=count,selected_peak=0;
        while(true) {
            if(sparse && count==0) break;
            if(device_control) {
                auto start=Clock::now();
                const uint32_t blocks=std::max<uint32_t>(1,std::min<uint64_t>(256,(uint64_t(count)+255)/256));
                ResetControl<<<1,1>>>(counters.p,control.p);
                FindActiveBucket<<<blocks,256>>>(current,count,d_distance.p,control.p);
                auto chosen=compact?next:selected.p;
                PartitionActive<<<blocks,256>>>(current,count,d_distance.p,queued.p,0,chosen,
                    control.p+1,next,counters.p,control.p,compact?n:0);
                Expand<<<blocks,256>>>(chosen,0,d_offsets.p,d_outgoing.p,d_ids.p,d_distance.p,
                    queued.p,0,compact?current:next,n,counters.p,control.p+1,compact?next:nullptr,count);
                Check(cudaGetLastError());
                Counters stats{};
                Check(cudaMemcpy(&stats,counters.p,sizeof(stats),cudaMemcpyDeviceToHost));
                Require(!stats.overflow && stats.count<=n,"Frontier queue overflow");
                selection_checks+=2*uint64_t(count); scans+=stats.edges;
                successes+=stats.successes; duplicates+=stats.duplicates;
                enqueued+=stats.successes-stats.duplicates;
                // Every selected entry is removed, and every fresh enqueue is counted.
                Require(stats.duplicates<=stats.successes,"Invalid enqueue counters");
                const uint64_t selected_now=uint64_t(count)+stats.successes-stats.duplicates-stats.count;
                Require(selected_now>0 && selected_now<=count,"Invalid selected bucket");
                processed+=selected_now; selected_peak=std::max(selected_peak,selected_now);
                count=stats.count; pending_entries+=count; peak=std::max<uint64_t>(peak,count);
                if(!compact) std::swap(current,next);
                Require(epoch<UINT32_MAX,"Queue iteration overflow"); ++epoch;
                control_bytes+=sizeof(stats); ++control_reads;
                expansion_ms+=Ms(start);
                continue;
            }
            auto selection_start=Clock::now();
            Check(cudaMemset(&counters.p->overflow,255,sizeof(uint32_t)));
            const uint32_t active_count=count;
            const uint32_t active_blocks=std::max<uint32_t>(1,std::min<uint64_t>(65535,(uint64_t(active_count)+255)/256));
            if(sparse) FindActiveBucket<<<active_blocks,256>>>(current,active_count,d_distance.p,&counters.p->overflow);
            else FindBucket<<<selection_blocks,256>>>(n,d_distance.p,queued.p,&counters.p->overflow);
            selection_checks+=sparse?active_count:n;
            uint32_t bucket;
            Check(cudaMemcpy(&bucket,&counters.p->overflow,4,cudaMemcpyDeviceToHost));
            control_bytes+=4; ++control_reads;
            if(bucket==UINT32_MAX) { selection_ms+=Ms(selection_start); break; }
            Check(cudaMemset(counters.p,0,sizeof(Counters)));
            if(sparse) {
                Check(cudaMemset(selected_count.p,0,4));
                // Deferred vertices remain pending and are carried exactly once.
                // Expansion starts after partition, so improved deferred vertices
                // update in place while processed vertices may safely re-enqueue.
                PartitionActive<<<active_blocks,256>>>(current,active_count,d_distance.p,queued.p,bucket,
                    selected.p,selected_count.p,next,counters.p);
                Check(cudaMemcpy(&count,selected_count.p,4,cudaMemcpyDeviceToHost));
            } else {
                SelectBucket<<<selection_blocks,256>>>(n,d_distance.p,queued.p,bucket,current,counters.p);
                Check(cudaMemcpy(&count,&counters.p->count,4,cudaMemcpyDeviceToHost));
            }
            selection_checks+=sparse?active_count:n; control_bytes+=4; ++control_reads;
            Require(count>0 && count<=n,"Invalid selected bucket");
            selected_peak=std::max<uint64_t>(selected_peak,count);
            selection_ms+=Ms(selection_start); auto expansion_start=Clock::now();
            Require(epoch<UINT32_MAX,"Queue epoch overflow"); ++epoch;
            processed+=count;
            if(!sparse) Check(cudaMemset(counters.p,0,sizeof(Counters)));
            const uint32_t blocks=std::min<uint64_t>(65535,(uint64_t(count)+255)/256);
            Expand<<<blocks,256>>>(sparse?selected.p:current,count,d_offsets.p,d_outgoing.p,d_ids.p,d_distance.p,queued.p,epoch,next,n,counters.p);
            Check(cudaGetLastError()); Counters stats{};
            Check(cudaMemcpy(&stats,counters.p,sizeof(stats),cudaMemcpyDeviceToHost));
            control_bytes+=sizeof(stats); ++control_reads;
            Require(!stats.overflow && stats.count<=n,"Frontier queue overflow");
            scans+=stats.edges; successes+=stats.successes; duplicates+=stats.duplicates;
            enqueued+=stats.successes-stats.duplicates;
            count=stats.count; pending_entries+=count; peak=std::max<uint64_t>(peak,count); std::swap(current,next);
            expansion_ms+=Ms(expansion_start);
        }
        const double closure_ms=Ms(stage); stage=Clock::now();
        if(n) Check(cudaMemcpy(distance.data(),d_distance.p,size_t(n)*4,cudaMemcpyDeviceToHost));
        const double d2h_ms=Ms(stage); stage=Clock::now();
        // Reconstruct parents from converged distances; no distance/parent race.
        uint64_t missing_parent=0,parent_ties=0;
        for(uint32_t i=0;i<n;++i) {
            const auto dst=s.affected[i];
            if(dst==s.source) { Require(distance[i]==0,"Wrong source distance"); parent[i]=dst; continue; }
            if(distance[i]==UINT32_MAX) continue;
            uint64_t tight=0;
            for(uint64_t e=s.offsets[i];e<s.offsets[i+1];++e) {
                const auto src=s.incoming[e]; const auto value=local[src]==UINT32_MAX?values[src]:distance[local[src]];
                if(value!=UINT32_MAX && uint64_t(value)+i16::Weight(src,dst)==distance[i]) { parent[i]=std::min(parent[i],src); ++tight; }
            }
            missing_parent+=!tight; parent_ties+=tight>1;
        }
        const double parent_ms=Ms(stage),service_ms=Ms(service);
        stage=Clock::now();
        d_offsets.Free(); d_outgoing.Free(); d_ids.Free(); d_distance.Free();
        q1.Free(); q2.Free(); queued.Free(); counters.Free(); selected.Free(); selected_count.Free(); control.Free();
        const double release_ms=Ms(stage),device_complete_service_ms=Ms(service);
        uint64_t mismatches=0;
        for(const auto &state:s.after) if(local[state.vertex]!=UINT32_MAX) mismatches+=distance[local[state.vertex]]!=state.value;
        // Verify the selected parent against actual incoming edges independently.
        uint64_t invalid_parent=0;
        for(uint32_t i=0;i<n;++i) {
            const auto dst=s.affected[i]; if(dst==s.source || distance[i]==UINT32_MAX) continue;
            bool valid=false;
            for(uint64_t e=s.offsets[i];e<s.offsets[i+1];++e) if(s.incoming[e]==parent[i]) {
                const auto src=parent[i],value=local[src]==UINT32_MAX?values[src]:distance[local[src]];
                valid=value!=UINT32_MAX && uint64_t(value)+i16::Weight(src,dst)==distance[i];
            }
            invalid_parent+=!valid;
        }
        const uint64_t allocated=8*offsets.size()+4*internal+20*uint64_t(n)+sizeof(Counters)+
            (sparse && !compact?4*uint64_t(n):0)+(sparse && !device_control?4:0)+(device_control?8:0);
        const uint64_t cursor_bytes=cursor.capacity()*sizeof(uint64_t),seeds=initial.size();
        const uint64_t host_workspace_bytes=4*(uint64_t(local.capacity())+values.capacity()+distance.capacity()+parent.capacity()+
            outgoing.capacity()+initial.capacity()+pending.capacity())+seen.capacity()+8*uint64_t(offsets.capacity())+cursor_bytes;
        Require(processed==enqueued,"Incomplete queue drain");
        stage=Clock::now();
        Release(local); Release(values); Release(distance); Release(parent); Release(seen);
        Release(offsets); Release(cursor); Release(outgoing); Release(initial); Release(pending);
        const double host_release_ms=Ms(stage),complete_service_ms=device_complete_service_ms+host_release_ms;
        struct rusage usage{}; getrusage(RUSAGE_SELF,&usage);
        nlohmann::json report={{"state",(mismatches||invalid_parent||missing_parent)?"failed":"passed"},{"affected",n},{"incoming",s.incoming.size()},
            {"internal",internal},{"boundary",boundary},{"seed_vertices",seeds},{"iterations",epoch},
            {"internal_edge_scans",scans},{"successful_relaxations",successes},{"duplicate_enqueues_avoided",duplicates},
            {"enqueued_vertices",enqueued},{"processed_vertices",processed},{"queue_peak",peak},
            {"distance_mismatches",mismatches},{"missing_tight_parents",missing_parent},{"invalid_parents",invalid_parent},
            {"parent_tie_vertices",parent_ties},{"read_ms",read_ms},{"setup_ms",setup_ms},{"allocation_context_ms",allocation_ms},
            {"h2d_ms",h2d_ms},{"closure_ms",closure_ms},{"d2h_ms",d2h_ms},{"parent_reconstruction_ms",parent_ms},
            {"service_ms",service_ms},{"total_ms",Ms(total)},{"allocated_device_bytes",allocated},
            {"complete_service_ms",complete_service_ms},{"device_release_ms",release_ms},
            {"service_accounting_version",2},{"host_release_ms",host_release_ms},{"host_workspace_bytes",host_workspace_bytes},
            {"host_index_ms",index_ms},{"host_boundary_count_ms",boundary_count_ms},{"host_transpose_ms",transpose_ms},
            {"host_cursor_bytes",cursor_bytes},{"deferred_copy_entries",compact?pending_entries-processed:0},
            {"timing_attribution",device_control?"expansion_ms includes entire device-controlled iteration":"selection and expansion wall times"},
            {"repair_only_device_bytes",allocated-8*uint64_t(n)},
            {"common_affected_ids_and_distances_bytes",8*uint64_t(n)},
            {"cuda_free_memory_delta_bytes",free_before>=free_after?free_before-free_after:0},{"peak_rss_kib",usage.ru_maxrss},
            {"parent_output_location","host; GPU scatter not included"},
            {"algorithm","gpu_ordered_all_light_delta_stepping"},{"delta",delta},
            {"selection_ms",selection_ms},{"expansion_ms",expansion_ms},
            {"selection_vertex_checks",selection_checks},{"bucket_mode",mode},
            {"control_d2h_bytes",control_bytes},{"control_d2h_calls",control_reads},
            {"pending_list_entries_total",pending_entries},{"selected_queue_peak",selected_peak},
            {"scope","Offline ordered prototype; no production gather/scatter or cross-batch reuse; complete_service_ms includes host/device workspace frees but excludes snapshot I/O, snapshot destruction and validation; timings include control synchronization"}};
        std::ofstream output(argv[2]); output<<report.dump(2)<<'\n'; Require(bool(output),"Report write failed");
        std::cout<<report.dump()<<'\n'; return mismatches||invalid_parent||missing_parent?2:0;
    } catch(const std::exception &e) { std::cerr<<e.what()<<'\n'; return 1; }
}
