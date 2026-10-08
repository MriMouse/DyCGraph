// In sepgraph::kernel. Rebuild the deletion frontier by a full V scan each
// round (origin-style work discovery); keep current dependency predicates.
static __global__ void AblationScanReset(index_t n, const bool *reset,
        uint8_t *processed, groute::dev::Queue<index_t> frontier) {
    for (index_t v = blockIdx.x * blockDim.x + threadIdx.x; v < n;
         v += blockDim.x * gridDim.x) {
        if (reset[v] && !processed[v]) { processed[v] = 1; frontier.append(v); }
    }
}
