# Armv8 memory model and C++ atomics on the TX8

Primary source: Arm "Learn the architecture - Memory Systems, Ordering, and Barriers"
(doc 102336). This file summarizes what matters for C++17 code on the Cortex-A53 (Armv8.0-A:
**no LSE atomics, no RCpc `LDAPR`**).

## 1. The one thing to remember

Arm is **weakly ordered**. Unlike x86 (TSO), plain loads and stores to different addresses can be
observed by another core in a different order than the program wrote them, and the compiler may
reorder them too. Any data shared between threads must be published and consumed through
`std::atomic` operations (or a mutex) with the right memory order. `volatile` is **not** a
synchronization mechanism (it neither orders other accesses nor makes RMW atomic).

Code that "worked on x86" with a plain `bool ready` flag or a `volatile` index is a latent bug on
the TX8.

## 2. How C++ orders map to A64 instructions (GCC, Armv8.0, `-mno-outline-atomics`)

| C++ operation | A64 code (typical) | Cost note |
|---|---|---|
| `load(relaxed)` | `ldr` | plain load |
| `load(acquire)` | `ldar` | later accesses cannot move before it |
| `load(seq_cst)` | `ldar` | same instruction as acquire on AArch64 |
| `store(relaxed)` | `str` | plain store |
| `store(release)` | `stlr` | earlier accesses cannot move after it |
| `store(seq_cst)` | `stlr` | `stlr` + later `ldar` are ordered by the architecture |
| `fetch_add(relaxed)` | `ldxr` / `add` / `stxr` / `cbnz` loop | LL/SC, retries under contention |
| `fetch_add(acq_rel / seq_cst)` | `ldaxr` / `add` / `stlxr` loop | LL/SC with acquire/release |
| `exchange`, `compare_exchange_*` | `ldaxr` / `stlxr` loop (CAS has a compare + branch) | |
| `atomic_thread_fence(acquire)` | `dmb ishld` | |
| `atomic_thread_fence(release / acq_rel / seq_cst)` | `dmb ish` | full barrier in the inner-shareable domain |
| `atomic_signal_fence(any)` | nothing (compiler barrier only) | |

Notes:
- `LDAPR` (Armv8.3 RCpc, weaker and cheaper acquire) does **not** exist on the A53; GCC uses
  `LDAR` for acquire. Do not pass `-march=armv8.3-a` or newer.
- With LSE (Armv8.1) these RMWs would be single instructions (`ldadd`, `cas`, `swp`). The A53 has
  no LSE: they are always loops. With the default outline-atomics they become calls to libgcc
  helpers; `-mno-outline-atomics` inlines the loop (project rule).
- Verify the actual code: `objdump -d --no-show-raw-insn app | grep -E 'ldaxr|stlxr|ldar|stlr|dmb'`.

## 3. Cost model on the A53 (verify on TX8)

- `ldar`/`stlr` are cheap when uncontended but prevent the in-order core from overlapping memory
  operations around them; a `dmb ish` waits for outstanding memory accesses (can be tens to
  hundreds of cycles if a store miss to DRAM is pending).
- `seq_cst` RMW = LL/SC loop with acquire+release semantics. Under contention from several cores
  on one cache line, each retry moves the line between cores through the shared L2/snoop control:
  cost grows quickly. Do not put a shared `fetch_add` counter in a per-pixel or per-element loop.
- Default `std::atomic` operations are `seq_cst`. On AArch64 seq_cst loads/stores map to the same
  instructions as acquire/release, so the difference is small, but `seq_cst` fences are full
  `dmb ish`. Write explicit orders in performance-relevant code so intent is visible to reviewers.

## 4. Patterns

### Publish data (message passing)
```cpp
struct Frame { const float* data; uint64_t id; int64_t ts_us; };
Frame slot;                        // plain data
std::atomic<bool> ready{false};

// producer
slot = Frame{buf, id, ts};
ready.store(true, std::memory_order_release);

// consumer
if (ready.load(std::memory_order_acquire)) {
  use(slot);                       // guaranteed to see the producer's writes to slot
}
```
For repeated use, use the SPSC ring or the latest-value mailbox from `threading-and-rt.md`.

### Statistics counters (no ordering needed)
```cpp
struct alignas(64) Counter { std::atomic<uint64_t> v{0}; };
Counter frames_done[4];            // one per thread, one cache line each
frames_done[me].v.fetch_add(1, std::memory_order_relaxed);   // or load+store by the single writer:
// frames_done[me].v.store(frames_done[me].v.load(std::memory_order_relaxed) + 1, std::memory_order_relaxed);
```
If a counter has a single writer, the load+store form avoids the LL/SC loop entirely.

### Stop flag
```cpp
std::atomic<bool> stop{false};
// controller: stop.store(true, std::memory_order_release);
// worker loop: while (!stop.load(std::memory_order_acquire)) { ... wait with timeout ... }
```
A worker blocked in a wait must also be woken (notify / eventfd write) or it only notices the flag
after its timeout.

### Fences
Use `std::atomic_thread_fence` only when several relaxed operations need to be ordered together
(e.g. a seqlock). Prefer acquire/release on the operation itself; it is clearer and often cheaper.

Seqlock reader/writer for a small struct read by many, written by one (e.g. latest telemetry):
```cpp
#include <atomic>
#include <cstdint>
#include <cstring>

struct Telemetry { float temp_c; float power_w; uint64_t frames; };

class SeqlockTelemetry {
 public:
  void write(const Telemetry& t) noexcept {               // single writer
    const uint32_t s = seq_.load(std::memory_order_relaxed);
    seq_.store(s + 1, std::memory_order_relaxed);          // odd: write in progress
    std::atomic_thread_fence(std::memory_order_release);   // dmb ish
    std::memcpy(&data_, &t, sizeof t);
    seq_.store(s + 2, std::memory_order_release);
  }
  bool try_read(Telemetry& out) const noexcept {
    const uint32_t s1 = seq_.load(std::memory_order_acquire);
    if (s1 & 1u) return false;
    std::memcpy(&out, &data_, sizeof out);
    std::atomic_thread_fence(std::memory_order_acquire);   // dmb ishld
    return seq_.load(std::memory_order_relaxed) == s1;
  }
 private:
  std::atomic<uint32_t> seq_{0};
  Telemetry data_{};
};
```
Strictly, the racy `memcpy` of `data_` is a data race in the C++ model; this pattern is widely
used and works with GCC on AArch64, but TSan will flag it. For TSan-clean code, store the fields
as relaxed atomics. Keep seqlocks for non-critical telemetry only; for frame data use the SPSC
ring.

## 5. Things that are not lock-free or not portable here

- 16-byte `std::atomic<T>` (e.g. a pointer + tag pair): not lock-free on Armv8.0 with GCC (goes
  through libatomic, may use a lock). Use index + generation packed in 64 bits instead.
- `std::atomic<float>` RMW (`fetch_add` is C++20 anyway): emulate with a CAS loop on the bit
  pattern only if really needed; usually use per-thread accumulation.
- Add `static_assert(std::atomic<T>::is_always_lock_free, "...")` for every atomic type used on RT
  paths.

## 6. Cache maintenance and DMA: never in user space

- MX3 data travels over PCIe via DMA managed by the MemryX kernel driver and runtime. Buffer
  coherency (cache clean/invalidate, bounce buffers, DMA mapping) is the **driver's** job.
- Do not use `dc civac`/`dc cvac`/`ic ivau` inline assembly, `__builtin___clear_cache` or barriers
  as a "fix" for corrupted inference input/output. If data looks stale or corrupted, it is a bug in
  how buffers are handed to the runtime (lifetime, ownership, using a buffer after returning it);
  read the runtime documentation and report to MemryX if it persists.
- `__builtin___clear_cache` is legitimate only for JIT/self-modifying code (not in this project).
- Memory-mapped device registers (e.g. via `/dev/mem` or UIO) are out of scope for this skill and
  require approval (see skill `tx8-platform`).

## 7. Review checklist for concurrent code

- [ ] Every shared variable is `std::atomic` or protected by a mutex; no `volatile` used for sync.
- [ ] Every release store has a matching acquire load on the consumer side.
- [ ] Memory orders are explicit in hot paths; `seq_cst` only where reasoning needs a total order.
- [ ] No contended RMW in inner loops; counters are per-thread and cache-line aligned.
- [ ] `compare_exchange_weak` used in loops; strong only for one-shot checks.
- [ ] `is_always_lock_free` asserted for RT-path atomics; no 16-byte atomics.
- [ ] No user-space cache maintenance for DMA buffers.
- [ ] TSan test build run on the threading logic (where TSan works; see `compiler-flags.md`).
