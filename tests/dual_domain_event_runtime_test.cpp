#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <thread>

#include <framework/dual_domain_event_runtime.h>

namespace {

using sepgraph::runtime::DualDomainEventRuntime;
using sepgraph::runtime::ExecutionDomain;
using sepgraph::runtime::SourceVersionGate;
using sepgraph::runtime::SpscEventChannel;

struct TestEvent {
    uint32_t epoch;
    uint32_t source;
    uint32_t version;
    uint32_t payload;
};

void Require(bool condition, const char *message) {
    if (!condition) {
        std::cerr << "dual_domain_event_runtime_test: " << message << '\n';
        std::abort();
    }
}

void TestBoundedFifo() {
    SpscEventChannel<TestEvent> channel(2);
    Require(channel.TryPush({1, 1, 1, 10}), "first push failed");
    Require(channel.TryPush({1, 2, 1, 20}), "second push failed");
    Require(!channel.TryPush({1, 3, 1, 30}), "full channel accepted event");
    TestEvent event{};
    Require(channel.TryPop(event) && event.source == 1, "FIFO first pop failed");
    Require(channel.TryPop(event) && event.source == 2, "FIFO second pop failed");
    Require(!channel.TryPop(event), "empty channel returned event");
}

void TestVersionGate() {
    SourceVersionGate gate(4);
    gate.BeginEpoch(1);
    Require(gate.Accept(1, 2, 1), "initial version rejected");
    Require(!gate.Accept(1, 2, 1), "duplicate version accepted");
    Require(!gate.Accept(1, 2, 0), "zero version accepted");
    Require(gate.Accept(1, 2, 3), "newer version rejected");
    Require(!gate.Accept(1, 2, 2), "stale version accepted");
    Require(!gate.Accept(2, 2, 1), "unpublished epoch accepted");
    gate.BeginEpoch(2);
    Require(gate.Accept(2, 2, 1), "new epoch version rejected");
    Require(!gate.Accept(1, 2, 4), "old epoch accepted");
    Require(!gate.Accept(2, 9, 1), "out-of-range source accepted");
}

void TestCreditAndStableQuiescence() {
    DualDomainEventRuntime<TestEvent> runtime(4);
    runtime.BeginEpoch(7);
    Require(!runtime.ObserveQuiescence(7), "single observation terminated epoch");
    Require(runtime.ObserveQuiescence(7), "second stable observation did not terminate");

    runtime.AddLocalWork(ExecutionDomain::CPU, 2);
    Require(!runtime.ObserveQuiescence(7), "local work ignored");
    runtime.CompleteLocalWork(ExecutionDomain::CPU);
    runtime.CompleteLocalWork(ExecutionDomain::CPU);
    Require(runtime.TryPublish(ExecutionDomain::CPU, {7, 1, 1, 9}),
            "event publish failed");
    Require(runtime.Snapshot().outstanding_events == 1, "event credit missing");
    TestEvent event{};
    Require(runtime.TryReceive(ExecutionDomain::GPU, event), "event receive failed");
    Require(!runtime.ObserveQuiescence(7), "in-flight event ignored");
    runtime.CompleteEvent(ExecutionDomain::GPU);
    Require(!runtime.ObserveQuiescence(7), "first post-work observation terminated");
    Require(runtime.ObserveQuiescence(7), "stable quiescence not detected");
}

void TestConcurrentBidirectionalProgress() {
    constexpr uint32_t kEvents = 50000;
    DualDomainEventRuntime<TestEvent> runtime(256);
    runtime.BeginEpoch(11);
    std::atomic<uint64_t> cpu_sum{0};
    std::atomic<uint64_t> gpu_sum{0};

    std::thread cpu([&]() {
        for (uint32_t i = 1; i <= kEvents; ++i) {
            while (!runtime.TryPublish(
                ExecutionDomain::CPU, {11, i, 1, i})) std::this_thread::yield();
            TestEvent incoming{};
            while (!runtime.TryReceive(ExecutionDomain::CPU, incoming)) {
                std::this_thread::yield();
            }
            cpu_sum.fetch_add(incoming.payload, std::memory_order_relaxed);
            runtime.CompleteEvent(ExecutionDomain::CPU);
        }
    });
    std::thread gpu([&]() {
        for (uint32_t i = 1; i <= kEvents; ++i) {
            TestEvent incoming{};
            while (!runtime.TryReceive(ExecutionDomain::GPU, incoming)) {
                std::this_thread::yield();
            }
            gpu_sum.fetch_add(incoming.payload, std::memory_order_relaxed);
            runtime.CompleteEvent(ExecutionDomain::GPU);
            while (!runtime.TryPublish(
                ExecutionDomain::GPU, {11, i, 1, i * 2})) std::this_thread::yield();
        }
    });
    cpu.join();
    gpu.join();

    const uint64_t sequence_sum =
        static_cast<uint64_t>(kEvents) * (kEvents + 1) / 2;
    Require(gpu_sum.load() == sequence_sum, "CPU-to-GPU event loss or reorder");
    Require(cpu_sum.load() == sequence_sum * 2, "GPU-to-CPU event loss or reorder");
    const auto snapshot = runtime.Snapshot();
    Require(snapshot.outstanding_events == 0, "event credit leaked");
    Require(snapshot.cpu_to_gpu_queued == 0 && snapshot.gpu_to_cpu_queued == 0,
            "channel did not drain");
    Require(runtime.PeakOutstandingEvents() > 0, "in-flight peak was not tracked");
    Require(!runtime.ObserveQuiescence(11), "first final observation terminated");
    Require(runtime.ObserveQuiescence(11), "final quiescence not detected");
}

void TestEpochDrainContract() {
    DualDomainEventRuntime<TestEvent> runtime(2);
    runtime.BeginEpoch(1);
    Require(runtime.TryPublish(ExecutionDomain::GPU, {1, 0, 1, 1}),
            "epoch event publish failed");
    bool rejected = false;
    try {
        runtime.BeginEpoch(2);
    } catch (const std::logic_error &) {
        rejected = true;
    }
    Require(rejected, "new epoch started before drain");
    TestEvent event{};
    Require(runtime.TryReceive(ExecutionDomain::CPU, event), "drain receive failed");
    runtime.CompleteEvent(ExecutionDomain::CPU);
    runtime.BeginEpoch(2);
}

} // namespace

int main() {
    TestBoundedFifo();
    TestVersionGate();
    TestCreditAndStableQuiescence();
    TestConcurrentBidirectionalProgress();
    TestEpochDrainContract();
    std::cout << "dual_domain_event_runtime_test: passed\n";
    return 0;
}
