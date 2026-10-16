# Threading, core affinity and real-time scheduling on 4x Cortex-A53

Goal: 30 fps sustained with TX8-internal latency p99 <= 80 ms, without starving the OS, the
network/MAVLink path or the MemryX runtime. With only four in-order cores, scheduling mistakes
show up directly as latency spikes. Reliability beats throughput: bounded queues, timeouts,
drop policy, watchdog.

## 1. Starting-point core plan (measure, then adjust)

| Core | Role (initial proposal) | Scheduling |
|---|---|---|
| 0 | OS, IRQ-heavy work, comms (WebSocket/MAVLink), CH1 MJPEG forward, control state machine | SCHED_OTHER |
| 1 | CH2 capture (UVC) + JPEG decode + fused normalize | SCHED_FIFO (e.g. prio 50) or SCHED_OTHER |
| 2 | post-processing (threshold + top-K), metadata packing | SCHED_FIFO (e.g. prio 45) or SCHED_OTHER |
| 3 | spare / MemryX runtime threads | inherit / SCHED_OTHER |

This is a hypothesis, not a rule. Measure per-core utilization (`mpstat -P ALL 1` if sysstat is
installed, else `top` then `1`, or `/proc/stat` deltas) and per-thread placement
(`ps -L -o tid,psr,cls,rtprio,pcpu,comm -p <pid>`). Keep **>= 30 % headroom on core 0** for comms
and the kernel, and avoid any core sitting at 100 % in steady state (no margin for jitter).

Find where IRQs land (read-only): `cat /proc/interrupts` (look for xhci/USB, the PCIe/memx
driver, ethernet). Placing a busy RT thread on the core that services the USB IRQ can delay
camera data; place capture next to or on that core deliberately, after measuring.

MemryX runtime threads: the runtime creates its own worker threads (count configurable, see skill
`mx3-runtime-integration`). Linux threads inherit the CPU affinity mask and scheduling policy of
the thread that creates them. Construct the accelerator object from a thread whose mask is what
you want the runtime to use (e.g. cores {2,3}), then verify with `ps -L`. Do not assume the
runtime's internal thread names or counts; observe them.

## 2. Setting affinity

```cpp
#include <pthread.h>
#include <sched.h>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <initializer_list>

// Returns 0 on success, an errno value otherwise (report it; do not ignore).
inline int pin_current_thread(std::initializer_list<int> cpus) {
  cpu_set_t set;
  CPU_ZERO(&set);
  for (int c : cpus) CPU_SET(c, &set);
  return pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
}
```
Check `sched_getcpu()` in logs at thread start. Pinning to a single core removes migration
jitter but also removes the scheduler's ability to rescue an overloaded core: pin pipeline
stages, leave housekeeping threads unpinned (or pinned to core 0).

## 3. SCHED_FIFO: when and how

```cpp
inline int set_fifo(int prio /* 1..99 */) {
  sched_param sp{};
  sp.sched_priority = prio;
  return pthread_setschedparam(pthread_self(), SCHED_FIFO, &sp);   // EPERM without privilege
}
```
Caveats (all important on 4 cores):
- Needs `CAP_SYS_NICE` or an `RLIMIT_RTPRIO` > 0 (`ulimit -r`). Granting it (limits.d, systemd
  `LimitRTPRIO=`/`AmbientCapabilities=`) is a system change: **ask the user first**. If `EPERM`,
  log and run as SCHED_OTHER (degraded but working).
- A SCHED_FIFO thread that spins or loops without blocking starves all SCHED_OTHER threads on its
  core (including kworkers on that core). The kernel's RT throttling
  (`/proc/sys/kernel/sched_rt_runtime_us`, default 950000 of 1000000) leaves 5 % to others but
  causes a 50 ms stall of the RT thread when it triggers: treat it as a safety net, not a design.
  Do not change it.
- RT threads must block on something with a timeout every frame (condition variable, eventfd,
  `poll` on the V4L2 fd) and never busy-wait.
- Priority inversion: an RT thread that takes a `std::mutex` held by a SCHED_OTHER thread can
  wait indefinitely. Prefer lock-free SPSC handoff; if you need a mutex between RT and non-RT
  threads, use a `pthread_mutex` with `PTHREAD_PRIO_INHERIT`.
- Keep priorities below the kernel's threaded IRQ handlers (which default to FIFO 50 on many
  kernels; check `ps -eLo rtprio,comm | sort -n | tail`) unless you know you want to preempt
  them. Start with 10-40 for application threads and measure.
- **Watchdog**: a separate monitor thread (on a different core, or at a higher priority) checks
  per-stage heartbeat counters (`std::atomic<uint64_t>` frame counters, each on its own cache
  line) every 100-500 ms. If a stage has not advanced within its deadline, it reports a fault to
  the control state machine (`FAULT` state) instead of silently hanging.

Start with everything SCHED_OTHER + affinity; add SCHED_FIFO only if p99 latency measurements
show scheduling jitter (e.g. long tails correlated with comms bursts).

## 4. cpufreq governor and thermal state (check, do not change)

```bash
ssh umpi 'for c in /sys/devices/system/cpu/cpu[0-3]; do echo "$c $(cat $c/cpufreq/scaling_governor 2>/dev/null) $(cat $c/cpufreq/scaling_cur_freq 2>/dev/null)"; done'
ssh umpi 'cat /sys/devices/system/cpu/cpufreq/policy0/scaling_available_frequencies 2>/dev/null; cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null'
```
- The cpufreq interface may not exist on the TX8 BSP; say so if missing (verify on board).
- An `ondemand`/`schedutil` governor adds latency when a bursty stage wakes on a low clock.
  Switching to `performance` costs power: it requires user approval and a before/after
  measurement of latency and power. Never change it silently.
- Always record the governor and temperature with every benchmark.

## 5. Lock-free SPSC ring buffer (bounded)

One producer thread, one consumer thread, fixed capacity, no allocation after construction.

```cpp
#include <atomic>
#include <cstddef>
#include <type_traits>

template <typename T, size_t N>
class SpscRing {
  static_assert(N >= 2 && (N & (N - 1)) == 0, "N must be a power of two");
  static_assert(std::is_trivially_copyable<T>::value, "keep slots trivially copyable (indices/pointers)");
 public:
  bool try_push(const T& v) noexcept {                     // producer only
    const size_t h = head_.load(std::memory_order_relaxed);
    if (h - tail_.load(std::memory_order_acquire) == N) return false;   // full
    slots_[h & (N - 1)] = v;
    head_.store(h + 1, std::memory_order_release);         // publish slot contents
    return true;
  }
  bool try_pop(T& out) noexcept {                          // consumer only
    const size_t t = tail_.load(std::memory_order_relaxed);
    if (head_.load(std::memory_order_acquire) == t) return false;       // empty
    out = slots_[t & (N - 1)];
    tail_.store(t + 1, std::memory_order_release);         // free the slot
    return true;
  }
  size_t size_approx() const noexcept {
    return head_.load(std::memory_order_acquire) - tail_.load(std::memory_order_acquire);
  }
 private:
  alignas(64) std::atomic<size_t> head_{0};   // written by producer
  alignas(64) std::atomic<size_t> tail_{0};   // written by consumer
  alignas(64) T slots_[N];
};
```
Why it is correct: the producer writes the slot, then `head_` with release; the consumer reads
`head_` with acquire, so it sees the slot contents. Symmetrically for `tail_` (the producer must
not overwrite a slot until the consumer has finished reading it). `size_t` wrap-around is fine
because only differences are used. On the A53, release/acquire compile to `stlr`/`ldar`; no LSE
needed (see `memory-model.md`).

Waiting: the consumer must not spin. Pair the ring with a blocking primitive with a timeout,
e.g. an `eventfd` the producer writes after a successful push, a POSIX semaphore
(`sem_timedwait` with `CLOCK_REALTIME`, or `sem_clockwait` with `CLOCK_MONOTONIC` in glibc 2.30+),
or a `std::condition_variable::wait_for` (needs a mutex; acceptable at frame rate).

## 6. Real-time drop policy: "latest frame wins"

For video, a late frame is worse than a dropped frame. Use drop-oldest semantics:
- Between capture and inference: a **triple buffer / latest-value mailbox**. The producer always
  publishes; if the consumer has not taken the previous frame, it is replaced (dropped) and the
  producer reuses that buffer.

```cpp
#include <atomic>
#include <cstdint>

// Holds three slot indices (e.g. into a buffer pool). Producer: write into write_index(),
// then publish(). Consumer: if (acquire_latest()) use read_index().
class LatestMailbox {
 public:
  uint8_t write_index() const noexcept { return back_; }
  // Returns true if an unconsumed frame was overwritten (count it as a drop).
  bool publish() noexcept {
    const uint8_t old = mid_.exchange(static_cast<uint8_t>(back_ | kFresh), std::memory_order_acq_rel);
    back_ = old & kIdx;
    return (old & kFresh) != 0;
  }
  bool acquire_latest() noexcept {
    if ((mid_.load(std::memory_order_relaxed) & kFresh) == 0) return false;
    const uint8_t old = mid_.exchange(front_, std::memory_order_acq_rel);
    front_ = old & kIdx;
    return true;
  }
  uint8_t read_index() const noexcept { return front_; }
 private:
  static constexpr uint8_t kIdx = 0x3, kFresh = 0x4;
  alignas(64) std::atomic<uint8_t> mid_{1};
  alignas(64) uint8_t back_ = 0;    // producer-owned
  alignas(64) uint8_t front_ = 2;   // consumer-owned
};
```
- For metadata to comms (must not be lost silently but must not block inference): bounded SPSC
  ring; on `try_push` failure increment a drop counter and report it in telemetry.
- Every queue is bounded; every drop is counted and reported; never "grow the queue".

## 7. No blocking in callbacks

MX3 input/output callbacks run on runtime threads (skill `mx3-runtime-integration`). Inside them:
no `malloc`, no file/socket I/O, no logging that can block, no locks shared with slow threads, no
waits without a short timeout. Copy or hand off a buffer index through a lock-free queue and
return. The input callback must return promptly even when no frame is ready (check the API docs
for the exact end-of-stream semantics; do not guess).

## 8. Timing and latency measurement

- Timestamps across the pipeline: `clock_gettime(CLOCK_MONOTONIC, ...)` (or
  `std::chrono::steady_clock`, which maps to it on glibc). It is vDSO-backed (no syscall).
- Micro-benchmarks: `CLOCK_MONOTONIC_RAW` (not slewed by NTP), see `scripts/bench_template.hpp`.
- Wall-clock time (`CLOCK_REALTIME`) only for logs sent to the base station, never for durations.
- Stamp the capture time as early as possible (V4L2 buffer timestamp if it is monotonic: check
  `V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC` in the buffer flags) and carry it with the frame; compute
  latency = metadata-sent time - capture time; record histograms (p50/p99/max) per minute.

## 9. Atomics on the A53 (no LSE)

- `std::atomic` RMW ops (`fetch_add`, `exchange`, `compare_exchange`) compile to LL/SC loops
  (`ldaxr`/`stlxr`). Uncontended they are cheap; contended across cores they can retry many
  times. Avoid shared hot counters: per-thread counters (one cache line each), aggregated by the
  reader.
- Build with `-mno-outline-atomics` (inline LL/SC, no helper calls).
- Use `compare_exchange_weak` in loops (spurious failure is possible with LL/SC).
- `static_assert(std::atomic<T>::is_always_lock_free)` for every atomic type you use in RT
  paths; 16-byte atomics are not lock-free here (they go through libatomic).

## 10. isolcpus, nohz_full, IRQ affinity (require approval)

Options that reduce jitter further, all **system configuration changes**:
- Kernel command line `isolcpus=`/`nohz_full=`/`irqaffinity=` (bootloader change, reboot).
- Writing `/proc/irq/<n>/smp_affinity_list` (root; lost at reboot unless scripted).
- cgroup v2 cpusets via systemd (`AllowedCPUs=`) for other services.
Propose these only with measured evidence (latency histogram showing interference), explain the
trade-off (a fully isolated core is wasted when idle, and with 4 cores that is 25 % of the CPU),
and wait for explicit approval.

## 11. Checklist
- [ ] Core plan written down with measured per-core load and >= 30 % headroom on the comms core.
- [ ] All pipeline threads pinned as planned; runtime threads' placement verified with `ps -L`.
- [ ] Every queue bounded; drop policy defined; drops counted and reported.
- [ ] No busy-wait; every wait has a timeout; watchdog reports stalled stages.
- [ ] SCHED_FIFO only with approval and measurement; fallback to SCHED_OTHER on EPERM.
- [ ] Governor and temperature recorded with latency results.
