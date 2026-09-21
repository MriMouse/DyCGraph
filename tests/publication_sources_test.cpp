#include <framework/publication_sources.h>
#include <random>
#include <stdexcept>

int main() {
    std::mt19937 rng(20260916);
    std::vector<unsigned> scratch;
    for (unsigned n = 0; n < 200; ++n) {
        for (unsigned split = 0; split <= n; ++split) {
            std::vector<unsigned> input(n);
            for (auto& x : input) x = rng() % 37;
            auto expected = input;
            std::sort(expected.begin(), expected.end());
            expected.erase(std::unique(expected.begin(), expected.end()), expected.end());
            std::sort(input.begin(), input.begin() + split);
            std::sort(input.begin() + split, input.end());
            sepgraph::topology::MergePublicationSources(input, split, scratch);
            if (input != expected) throw std::runtime_error("publication union mismatch");
        }
    }
}
