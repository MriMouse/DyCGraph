#include <framework/cache_refresh_gate.h>

int main() {
    sepgraph::cache_patch::RefreshGate gate;
    if (!gate.Observe(10, true)) return 1;
    gate.Publish();
    if (gate.Observe(10, false)) return 2;
    if (!gate.Observe(11, false)) return 3;
    gate.Publish();
    if (!gate.Observe(11, true)) return 4;
    return 0;
}
