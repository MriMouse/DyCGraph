#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <sstream>
#include <framework/hotness_candidate_trace.h>

using namespace sepgraph::hotness;

int main(int argc, char **argv) {
    assert(argc == 2);
    {
        TraceWriter trace;
        trace.Sample(argv[1], -1, 3, {0, 1, 2, 3}, {0, 0, 0, 0}, {0, 2, 0, 3});
        trace.CheckCount(3);
        trace.Sample(argv[1], 0, 3, {3, 0, 1, 2}, {1020, 0, 0, 0}, {3, 0, 2, 0});
        trace.CheckCount(0);
        trace.Sample(argv[1], 1, 3, {3, 0, 1, 2}, {1020, 0, 0, 0}, {2, 0, 2, 0});
        trace.CheckCount(2);
        trace.Sample(argv[1], 2, 5, {0, 1, 2, 3}, {0, 0, 0, 0}, {0, 2, 0, 2});
        trace.CheckCount(4);
        trace.Sample(argv[1], 3, 0, {0, 1, 2, 3}, {0, 0, 0, 0}, {0, 2, 0, 2});
        trace.CheckCount(0);
        bool rejected = false;
        try { trace.CheckCount(1); } catch (const std::runtime_error &) { rejected = true; }
        assert(rejected);
    }
    std::ifstream input(argv[1], std::ios::binary);
    assert(Read<uint64_t>(input) == kTraceMagic);
    assert(Read<uint32_t>(input) == 4);
    const uint32_t changed[] = {4, 1, 1, 1, 0};
    for (int32_t batch = -1; batch < 4; ++batch) {
        assert(Read<int32_t>(input) == batch);
        Read<uint64_t>(input); Read<uint32_t>(input);
        Read<uint64_t>(input); Read<uint64_t>(input);
        const uint32_t count = Read<uint32_t>(input);
        assert(count == changed[batch + 1]);
        for (uint32_t i = 0; i < count; ++i) Read<Change>(input);
    }
    assert(input.peek() == EOF);
    std::istringstream truncated("abc");
    bool rejected = false;
    try { Read<uint64_t>(truncated); } catch (const std::runtime_error &) { rejected = true; }
    assert(rejected);
}
