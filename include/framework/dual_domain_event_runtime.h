#ifndef SEPGRAPH_DUAL_DOMAIN_EVENT_RUNTIME_H
#define SEPGRAPH_DUAL_DOMAIN_EVENT_RUNTIME_H

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <type_traits>
#include <unordered_map>
#include <utility>
#include <vector>

namespace sepgraph {
namespace runtime {

enum class ExecutionDomain : uint8_t {
    CPU = 0,
    GPU = 1
};

inline constexpr size_t DomainIndex(ExecutionDomain domain) {
    return static_cast<size_t>(domain);
}

template <typename T>
class SpscEventChannel {
    static_assert(std::is_trivially_copyable<T>::value,
                  "boundary events must be trivially copyable");

public:
    explicit SpscEventChannel(size_t capacity)
        : slots_(capacity + 1), ring_size_(capacity + 1) {
        if (capacity == 0) {
            throw std::invalid_argument("event channel capacity must be positive");
        }
    }

    bool TryPush(const T &event) {
        const size_t tail = tail_.load(std::memory_order_relaxed);
        const size_t next = Increment(tail);
        if (next == head_.load(std::memory_order_acquire)) return false;
        slots_[tail] = event;
        tail_.store(next, std::memory_order_release);
        return true;
    }

    bool TryPop(T &event) {
        const size_t head = head_.load(std::memory_order_relaxed);
        if (head == tail_.load(std::memory_order_acquire)) return false;
        event = slots_[head];
        head_.store(Increment(head), std::memory_order_release);
        return true;
    }

    bool Empty() const {
        return head_.load(std::memory_order_acquire) ==
               tail_.load(std::memory_order_acquire);
    }

    size_t Capacity() const { return ring_size_ - 1; }

    size_t Size() const {
        const size_t head = head_.load(std::memory_order_acquire);
        const size_t tail = tail_.load(std::memory_order_acquire);
        return tail >= head ? tail - head : ring_size_ - head + tail;
    }

private:
    size_t Increment(size_t position) const {
        ++position;
        return position == ring_size_ ? 0 : position;
    }

    std::vector<T> slots_;
    const size_t ring_size_;
    alignas(64) std::atomic<size_t> head_{0};
    alignas(64) std::atomic<size_t> tail_{0};
};

class SourceVersionGate {
public:
    explicit SourceVersionGate(size_t source_count)
        : source_count_(source_count) {}

    void BeginEpoch(uint32_t epoch) {
        if (epoch == 0 || epoch <= current_epoch_) {
            throw std::logic_error("version gate epoch must increase");
        }
        current_epoch_ = epoch;
        versions_.clear();
    }

    bool Accept(uint32_t epoch, uint32_t source, uint32_t version) {
        if (source >= source_count_ || epoch != current_epoch_ || version == 0) {
            return false;
        }
        const auto inserted = versions_.emplace(source, version);
        if (inserted.second) {
            return true;
        }
        if (version <= inserted.first->second) return false;
        inserted.first->second = version;
        return true;
    }

private:
    size_t source_count_;
    std::unordered_map<uint32_t, uint32_t> versions_;
    uint32_t current_epoch_ = 0;
};

struct EventRuntimeSnapshot {
    uint32_t epoch = 0;
    uint64_t local_work = 0;
    uint64_t outstanding_events = 0;
    uint64_t sequence = 0;
    size_t cpu_to_gpu_queued = 0;
    size_t gpu_to_cpu_queued = 0;
};

template <typename Event>
class DualDomainEventRuntime {
public:
    explicit DualDomainEventRuntime(size_t channel_capacity)
        : cpu_to_gpu_(channel_capacity), gpu_to_cpu_(channel_capacity) {}

    void BeginEpoch(uint32_t epoch) {
        if (epoch == 0 || !ChannelsEmpty() ||
            TotalOutstandingEvents() != 0 ||
            TotalLocalWork() != 0) {
            throw std::logic_error("cannot begin event epoch with outstanding work");
        }
        epoch_.store(epoch, std::memory_order_release);
        peak_outstanding_events_.store(0, std::memory_order_release);
        stable_observations_ = 0;
        last_observed_sequence_ = sequence_.load(std::memory_order_acquire);
        sequence_.fetch_add(1, std::memory_order_acq_rel);
    }

    bool TryPublish(ExecutionDomain source, const Event &event) {
        SpscEventChannel<Event> &channel = source == ExecutionDomain::CPU
            ? cpu_to_gpu_ : gpu_to_cpu_;
        std::atomic<uint64_t> &credit =
            outstanding_events_[DomainIndex(source)];
        credit.fetch_add(1, std::memory_order_acq_rel);
        if (!channel.TryPush(event)) {
            credit.fetch_sub(1, std::memory_order_acq_rel);
            return false;
        }
        sequence_.fetch_add(1, std::memory_order_acq_rel);
        UpdatePeakOutstanding();
        return true;
    }

    bool TryReceive(ExecutionDomain target, Event &event) {
        SpscEventChannel<Event> &channel = target == ExecutionDomain::CPU
            ? gpu_to_cpu_ : cpu_to_gpu_;
        return channel.TryPop(event);
    }

    void CompleteEvent(ExecutionDomain target) {
        const ExecutionDomain source = target == ExecutionDomain::CPU
            ? ExecutionDomain::GPU : ExecutionDomain::CPU;
        DecrementChecked(outstanding_events_[DomainIndex(source)],
                         "event credit underflow");
        sequence_.fetch_add(1, std::memory_order_acq_rel);
    }

    void AddLocalWork(ExecutionDomain domain, uint64_t count = 1) {
        if (count == 0) return;
        local_work_[DomainIndex(domain)].fetch_add(count, std::memory_order_acq_rel);
        sequence_.fetch_add(1, std::memory_order_acq_rel);
    }

    void CompleteLocalWork(ExecutionDomain domain, uint64_t count = 1) {
        if (count == 0) return;
        DecrementChecked(local_work_[DomainIndex(domain)],
                         "local work credit underflow", count);
        sequence_.fetch_add(1, std::memory_order_acq_rel);
    }

    bool ObserveQuiescence(uint32_t epoch) {
        const EventRuntimeSnapshot snapshot = Snapshot();
        if (snapshot.epoch != epoch || snapshot.local_work != 0 ||
            snapshot.outstanding_events != 0 ||
            snapshot.cpu_to_gpu_queued != 0 || snapshot.gpu_to_cpu_queued != 0) {
            stable_observations_ = 0;
            last_observed_sequence_ = snapshot.sequence;
            return false;
        }
        if (snapshot.sequence != last_observed_sequence_) {
            stable_observations_ = 1;
            last_observed_sequence_ = snapshot.sequence;
            return false;
        }
        ++stable_observations_;
        return stable_observations_ >= 2;
    }

    EventRuntimeSnapshot Snapshot() const {
        EventRuntimeSnapshot snapshot;
        snapshot.epoch = epoch_.load(std::memory_order_acquire);
        snapshot.local_work = TotalLocalWork();
        snapshot.outstanding_events = TotalOutstandingEvents();
        snapshot.sequence = sequence_.load(std::memory_order_acquire);
        snapshot.cpu_to_gpu_queued = cpu_to_gpu_.Size();
        snapshot.gpu_to_cpu_queued = gpu_to_cpu_.Size();
        return snapshot;
    }

    uint64_t PeakOutstandingEvents() const {
        return peak_outstanding_events_.load(std::memory_order_acquire);
    }

private:
    static void DecrementChecked(std::atomic<uint64_t> &counter,
                                 const char *message,
                                 uint64_t count = 1) {
        uint64_t observed = counter.load(std::memory_order_acquire);
        while (true) {
            if (observed < count) throw std::logic_error(message);
            if (counter.compare_exchange_weak(
                    observed, observed - count,
                    std::memory_order_acq_rel, std::memory_order_acquire)) {
                return;
            }
        }
    }

    bool ChannelsEmpty() const {
        return cpu_to_gpu_.Empty() && gpu_to_cpu_.Empty();
    }

    uint64_t TotalLocalWork() const {
        return local_work_[0].load(std::memory_order_acquire) +
               local_work_[1].load(std::memory_order_acquire);
    }

    uint64_t TotalOutstandingEvents() const {
        return outstanding_events_[0].load(std::memory_order_acquire) +
               outstanding_events_[1].load(std::memory_order_acquire);
    }

    void UpdatePeakOutstanding() {
        const uint64_t current =
            TotalOutstandingEvents();
        uint64_t peak = peak_outstanding_events_.load(std::memory_order_relaxed);
        while (current > peak &&
               !peak_outstanding_events_.compare_exchange_weak(
                   peak, current, std::memory_order_relaxed)) {}
    }

    SpscEventChannel<Event> cpu_to_gpu_;
    SpscEventChannel<Event> gpu_to_cpu_;
    std::array<std::atomic<uint64_t>, 2> local_work_{{0, 0}};
    std::array<std::atomic<uint64_t>, 2> outstanding_events_{{0, 0}};
    std::atomic<uint64_t> peak_outstanding_events_{0};
    std::atomic<uint64_t> sequence_{0};
    std::atomic<uint32_t> epoch_{0};
    uint64_t last_observed_sequence_ = 0;
    uint32_t stable_observations_ = 0;
};

} // namespace runtime
} // namespace sepgraph

#endif // SEPGRAPH_DUAL_DOMAIN_EVENT_RUNTIME_H
