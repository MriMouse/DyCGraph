#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include <cuda_runtime.h>

__global__ void SyntheticExactEdges(const uint32_t *src, uint32_t *dst,
                                    uint64_t count) {
    for (uint64_t i = blockIdx.x * blockDim.x + threadIdx.x; i < count;
         i += static_cast<uint64_t>(blockDim.x) * gridDim.x) {
        atomicMin(dst + (src[i] & ((1U << 20) - 1)), src[i] + 1);
    }
}

int main(int argc, char **argv) {
    const uint64_t count = argc > 1 ? std::strtoull(argv[1], nullptr, 10)
                                    : 1ULL << 24;
    std::vector<uint32_t> source(count);
    std::vector<uint32_t> destination(1U << 20, ~0U);
    for (uint64_t i = 0; i < count; ++i) source[i] = (i * 2654435761U) & ((1U << 20) - 1);

    volatile uint64_t checksum = 0;
    const auto cpu_begin = std::chrono::steady_clock::now();
    for (uint64_t i = 0; i < count; ++i) checksum += source[i] + 1;
    const double cpu_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - cpu_begin).count();

    uint32_t *device_source = nullptr, *device_destination = nullptr;
    cudaMalloc(&device_source, count * sizeof(uint32_t));
    cudaMalloc(&device_destination, destination.size() * sizeof(uint32_t));
    cudaMemcpy(device_source, source.data(), count * sizeof(uint32_t), cudaMemcpyHostToDevice);
    cudaMemset(device_destination, 0xff, destination.size() * sizeof(uint32_t));
    cudaEvent_t begin, end;
    cudaEventCreate(&begin); cudaEventCreate(&end);
    cudaEventRecord(begin);
    SyntheticExactEdges<<<256, 256>>>(device_source, device_destination, count);
    cudaEventRecord(end); cudaEventSynchronize(end);
    float gpu_ms = 0.0f; cudaEventElapsedTime(&gpu_ms, begin, end);

    const uint64_t event_count = count / 8;
    const auto event_begin = std::chrono::steady_clock::now();
    for (uint64_t i = 0; i < event_count; ++i) {
        destination[i & (destination.size() - 1)] = source[i] + 1;
    }
    const double event_ms = std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - event_begin).count();
    std::printf("metric\tvalue\n");
    std::printf("cpu_edges_per_ms\t%.6f\n", count / cpu_ms);
    std::printf("gpu_edges_per_ms\t%.6f\n", count / gpu_ms);
    std::printf("boundary_events_per_ms\t%.6f\n", event_count / event_ms);
    std::printf("placement_ns_per_edge\t%.6f\n", cpu_ms * 1.0e6 / count);
    std::fprintf(stderr, "checksum=%llu cpu_ms=%.3f gpu_ms=%.3f event_ms=%.3f\n",
        static_cast<unsigned long long>(checksum), cpu_ms, gpu_ms, event_ms);
    cudaFree(device_source); cudaFree(device_destination);
    return 0;
}
