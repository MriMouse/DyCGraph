#include <utils/communication_meter.h>
#include <cuda_runtime_api.h>
#include <stdexcept>

static cudaError_t result = cudaSuccess;
extern "C" cudaError_t __real_cudaMemcpy(void *, const void *, size_t, cudaMemcpyKind) { return result; }
extern "C" cudaError_t __real_cudaMemcpyAsync(void *, const void *, size_t, cudaMemcpyKind, cudaStream_t) { return result; }
extern "C" cudaError_t __wrap_cudaMemcpy(void *, const void *, size_t, cudaMemcpyKind);
extern "C" cudaError_t __wrap_cudaMemcpyAsync(void *, const void *, size_t, cudaMemcpyKind, cudaStream_t);
static void require(bool ok) { if (!ok) throw std::runtime_error("communication accounting mismatch"); }
int main(int argc, char **) {
    setenv("CG_COMM_METER", argc > 1 ? "0" : "1", 1);
    cgcomm::Stage(1);
    {
        cgcomm::Scope outer(cgcomm::Category::Topology);
        __wrap_cudaMemcpy(nullptr, nullptr, 123, cudaMemcpyHostToDevice);
        {
            cgcomm::Scope inner(cgcomm::Category::State);
            __wrap_cudaMemcpyAsync(nullptr, nullptr, 45, cudaMemcpyDeviceToHost, nullptr);
        }
        __wrap_cudaMemcpy(nullptr, nullptr, 7, cudaMemcpyDeviceToDevice);
        result = cudaErrorInvalidValue;
        require(__wrap_cudaMemcpy(nullptr, nullptr, 999, cudaMemcpyHostToDevice) == result);
    }
    require(cgcomm::CurrentCategory() == cgcomm::Category::Other);
    auto &c = cgcomm::Counters();
    require(c[1][1][0].bytes == (argc > 1 ? 0 : 123));
    require(c[1][1][0].calls == (argc > 1 ? 0 : 1));
    require(c[1][3][1].bytes == (argc > 1 ? 0 : 45));
    require(c[1][1][2].bytes == (argc > 1 ? 0 : 7));
    cgcomm::Flush(0, "unused");
    require(c[1][1][0].bytes == 0 && c[1][1][0].calls == 0);
}
