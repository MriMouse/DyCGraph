// Hardware calibration only: never used in the graph algorithm.
#include <cuda_runtime.h>
#include <utils/communication_window.h>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#define CUDA_OK(call) do { if ((call) != cudaSuccess) { std::fprintf(stderr, "CUDA probe failed: %s\n", #call); std::exit(1); } } while (0)
__global__ void read_host(const volatile unsigned *data, unsigned *output, size_t n) {
    size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    unsigned sum = 0;
    for (size_t j = i; j < n; j += gridDim.x * blockDim.x) sum += data[j];
    output[i] = sum;
}
int main(int argc, char **argv) {
    if (argc != 2) return 1;
    const bool zc = !std::strcmp(argv[1], "zc");
    const bool h2d = !std::strcmp(argv[1], "h2d");
    if (!zc && !h2d && std::strcmp(argv[1], "d2h")) return 1;
    const size_t bytes = 128ULL * 1024 * 1024;
    unsigned *host, *device, *mapped;
    CUDA_OK(cudaSetDeviceFlags(cudaDeviceMapHost));
    CUDA_OK(cudaHostAlloc(&host, bytes, cudaHostAllocMapped));
    CUDA_OK(cudaMalloc(&device, bytes));
    std::memset(host, 1, bytes);
    CUDA_OK(cudaMemset(device, 1, bytes));
    CUDA_OK(cudaHostGetDevicePointer(&mapped, host, 0));
    CUDA_OK(cudaDeviceSynchronize());
    cgcomm::Window("begin");
    auto start = std::chrono::steady_clock::now();
    size_t iterations = 0;
    do {
        if (zc) {
            read_host<<<256,256>>>(mapped, device, bytes / sizeof(unsigned));
            CUDA_OK(cudaGetLastError());
            CUDA_OK(cudaDeviceSynchronize());
        } else if (h2d) {
            CUDA_OK(cudaMemcpy(device, host, bytes, cudaMemcpyHostToDevice));
        } else {
            CUDA_OK(cudaMemcpy(host, device, bytes, cudaMemcpyDeviceToHost));
        }
        ++iterations;
    } while (std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count() < 2.0);
    CUDA_OK(cudaDeviceSynchronize());
    cgcomm::Window("end");
    std::printf("[COMM-PROBE] mode=%s iterations=%zu requested_bytes=%zu\n", argv[1], iterations, bytes * iterations);
    CUDA_OK(cudaFree(device));
    CUDA_OK(cudaFreeHost(host));
}
