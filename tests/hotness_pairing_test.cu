#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <algorithm>
#include <numeric>
#include <vector>
#include <framework/variants/driver.cuh>

struct Vertex { uint8_t hotness[4]; };
struct Graph { Vertex *vertices_; };

int main() {
    constexpr unsigned n = 6;
    Vertex *vertices;
    uint32_t *buffers;
    cub::DoubleBuffer<uint32_t> scores, ids;
    assert(cudaMallocManaged(&vertices, n * sizeof(Vertex)) == cudaSuccess);
    assert(cudaMallocManaged(&buffers, n * sizeof(uint32_t)) == cudaSuccess);
    for (int i = 0; i < 2; ++i) {
        assert(cudaMallocManaged(&scores.d_buffers[i], n * sizeof(uint32_t)) == cudaSuccess);
        assert(cudaMallocManaged(&ids.d_buffers[i], n * sizeof(uint32_t)) == cudaSuccess);
    }
    for (unsigned i = 0; i < n; ++i) {
        ids.Current()[i] = n - i - 1;
        buffers[i] = i == 3 ? UINT32_MAX : 0;
    }
    void *temporary = nullptr;
    size_t bytes = 0;
    assert(cub::DeviceRadixSort::SortPairsDescending(temporary, bytes, scores, ids, n) == cudaSuccess);
    assert(cudaMalloc(&temporary, bytes) == cudaSuccess);
    for (unsigned round = 0; round < 8; ++round) {
        std::vector<uint32_t> expected_scores(n), expected_ids(n);
        std::iota(expected_ids.begin(), expected_ids.end(), 0);
        for (unsigned i = 0; i < n; ++i) {
            vertices[i] = {{static_cast<uint8_t>((i + round) % 3), 0, 0, 0}};
            if (i == 4) vertices[i] = {{255, 255, 255, 255}};
            expected_scores[i] = buffers[i] == UINT32_MAX ? 0 :
                vertices[i].hotness[0] + vertices[i].hotness[1] +
                vertices[i].hotness[2] + vertices[i].hotness[3];
        }
        sepgraph::kernel::comp_hotness_sssp<<<1, 32>>>(0, Graph{vertices},
            groute::dev::WorkSourceRange<index_t>(0, n), buffers, scores, ids.Current());
        assert(cudaDeviceSynchronize() == cudaSuccess);
        for (unsigned i = 0; i < n; ++i) {
            assert(ids.Current()[i] == i);
            assert(scores.Current()[i] == expected_scores[i]);
        }
        std::stable_sort(expected_ids.begin(), expected_ids.end(),
            [&](uint32_t a, uint32_t b) { return expected_scores[a] > expected_scores[b]; });
        assert(cub::DeviceRadixSort::SortPairsDescending(temporary, bytes, scores, ids, n) == cudaSuccess);
        assert(cudaDeviceSynchronize() == cudaSuccess);
        for (unsigned i = 0; i < n; ++i) {
            assert(ids.Current()[i] == expected_ids[i]);
            assert(scores.Current()[i] == expected_scores[expected_ids[i]]);
        }
    }
    assert(cudaFree(temporary) == cudaSuccess);
    for (int i = 0; i < 2; ++i) {
        assert(cudaFree(scores.d_buffers[i]) == cudaSuccess);
        assert(cudaFree(ids.d_buffers[i]) == cudaSuccess);
    }
    assert(cudaFree(vertices) == cudaSuccess);
    assert(cudaFree(buffers) == cudaSuccess);
}
