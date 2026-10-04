#include <framework/repair_topology_storage.cuh>
#include <iostream>

using sepgraph::runtime::RepairTopologyStorage;
void Require(bool ok) { if (!ok) throw std::runtime_error("storage regression failed"); }
void Check(cudaError_t status) {
    if (status != cudaSuccess) throw std::runtime_error(cudaGetErrorString(status));
}
__global__ void Read(const uint64_t *offsets, const uint32_t *sources,
                     uint32_t rows, unsigned long long *result) {
    for (uint32_t i = threadIdx.x; i < rows; i += blockDim.x)
        for (uint64_t e = offsets[i]; e < offsets[i + 1]; ++e)
            atomicAdd(result, static_cast<unsigned long long>(sources[e]));
}
int main() {
    RepairTopologyStorage storage;
    unsigned long long *result = nullptr;
    Check(cudaMalloc(&result, sizeof(*result)));
    // Device -> mixed -> fully mapped -> growth -> empty -> device, including
    // vector reallocations between leases and reuse of retained allocations.
    for (size_t budget : {size_t(1<<20), size_t(4096), size_t(0), size_t(2048), size_t(1<<20)}) {
        for (size_t rows : {size_t(8), size_t(512), size_t(0), size_t(1024)}) {
            std::vector<uint64_t> offsets(rows + 1);
            std::vector<uint32_t> sources(rows * 33);
            for (size_t i=0; i<=rows; ++i) offsets[i]=i*33;
            unsigned long long expected=0;
            for (size_t i=0; i<sources.size(); ++i) expected += sources[i]=i%197;
            RepairTopologyStorage::Lease lease{storage};
            storage.Bind(offsets, sources, budget);
            storage.Upload(offsets, sources);
            Require(storage.DeviceBytes() <= budget);
            Require(storage.TransferBytes()+storage.MappedBytes()==offsets.size()*8+sources.size()*4);
            if (!budget) Require(storage.TransferBytes()==0);
            Check(cudaMemset(result,0,sizeof(*result)));
            Read<<<1,256>>>(storage.Offsets(),storage.Sources(),rows,result);
            unsigned long long actual=0;
            Check(cudaMemcpy(&actual,result,sizeof(actual),cudaMemcpyDeviceToHost));
            Require(actual==expected);
        }
    }
    // Unregister even when control leaves through an exception.
    std::vector<uint64_t> offsets{0,1}; std::vector<uint32_t> sources{19};
    try {
        RepairTopologyStorage::Lease lease{storage};
        storage.Bind(offsets,sources,0);
        throw 1;
    } catch (int) {}
    {
        RepairTopologyStorage::Lease lease{storage};
        storage.Bind(offsets,sources,0);
    }
    Check(cudaFree(result));
    std::cout << "repair topology storage passed\n";
}
