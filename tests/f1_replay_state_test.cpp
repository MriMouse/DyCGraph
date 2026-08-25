#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include <framework/f1_replay_state.h>

int main() {
    const std::string path = "/tmp/sepgraph_f1_replay_state_test.bin";
    {
        std::ofstream output(path, std::ios::out | std::ios::binary | std::ios::trunc);
        sepgraph::f1_replay::WriteHeader(output);
        sepgraph::f1_replay::WriteBatch(output, 3,
            {{2, 17, 1}, {9, 42, 5}}, {{2, 7, 1}});
    }
    const auto batches = sepgraph::f1_replay::ReadTrace(path);
    std::remove(path.c_str());
    return batches.size() == 1 && batches[0].batch == 3 &&
                   batches[0].input_states.size() == 2 &&
                   batches[0].input_states[0].vertex == 2 &&
                   batches[0].input_states[0].value == 17 &&
                   batches[0].input_states[0].parent == 1 &&
                   batches[0].input_states[1].vertex == 9 &&
                   batches[0].input_states[1].value == 42 &&
                   batches[0].input_states[1].parent == 5 &&
                   batches[0].final_affected_states.size() == 1 &&
                   batches[0].final_affected_states[0].vertex == 2 &&
                   batches[0].final_affected_states[0].value == 7 &&
                   batches[0].final_affected_states[0].parent == 1
               ? 0 : 1;
}
