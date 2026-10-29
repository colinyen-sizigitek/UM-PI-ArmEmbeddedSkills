# Memory layout, caches and allocation on the TX8

TX8 memory hierarchy (datasheet): per core 32 KB L1D (4-way, PIPT) + 32 KB L1I; one **1 MB L2
shared by all 4 cores** (16-way); **no L3**; 64 B lines; DDR4-2400 on a 32-bit bus; 2 GB (EVT) or
4 GB (MP) RAM. Latency/bandwidth numbers below are theoretical or from other A53 SoCs:
**measure on TX8** with `scripts/membw.cpp`.

## 1. Sizes that matter for our workload

| Buffer | Size | vs cache |
|---|---|---|
| 640 x 640 x 3 u8 (decoded RGB) | 1,228,800 B = 1.17 MiB | > L2 (1 MiB) |
| 640 x 640 x 3 float32 (MX3 input, NHWC) | 4,915,200 B = 4.69 MiB | ~4.7x L2 |
| 320 x 320 x 3 float32 (fallback model) | 1,228,800 B = 1.17 MiB | > L2 |
| one 640 RGB u8 row | 1,920 B (30 lines) | trivial |
| one 640 RGB float row | 7,680 B (120 lines) | trivial |
| 16-row strip u8 + float | 30 KB + 120 KB | u8 strip fits L1D, float strip fits L2 |
| 1080p MJPEG frame (CH1, forwarded) | ~100-400 KB (content dependent) | do not touch (forward verbatim) |
| YOLO output, e.g. 8400 x (4+C) float | ~170 KB for C = 1 | fits L2 |

Consequence: any "full-frame pass" (decode whole frame -> convert whole frame -> copy whole
frame) streams through DRAM every pass, and the L2 is also shared with the other three cores
(capture, comms, MX3 runtime threads). Design for **one pass over each pixel** where possible.

## 2. Fuse passes, stream by rows

Pattern: decode -> convert -> write directly into the buffer that is handed to the MX3 runtime.

- TurboJPEG's one-shot API (`tj3Decompress8` / `tjDecompress2`) decodes the whole frame into a
  1.2 MB RGB buffer, then a separate pass converts it to float: two DRAM round trips.
- The libjpeg API (`jpeg_read_scanlines`, also provided by libjpeg-turbo with its NEON paths)
  returns a few rows at a time (typically the MCU height, 8 or 16 rows). Convert each strip to
  float immediately while it is in L1/L2, writing into the final input tensor. The u8 frame
  never needs to exist as a whole.
- If you must keep a full u8 frame (e.g. for debug), still convert in strips of ~16 rows right
  after they are produced.
- Measure both: the decode itself usually dominates; the fused version mainly saves DRAM traffic
  and L2 pollution for the other cores. Pipeline-level design (which thread decodes, how many
  buffers): see skill `um-pi-vision-pipeline`.

Generic L2-aware tiling rule: choose a working set per thread of <= ~256 KB (a quarter of the
shared L2) so 4 cores do not evict each other; for L1-resident loops keep the hot set <= ~16 KB
(half of L1D) to leave room for stack, tables and the other stream.

## 3. Alignment and false sharing

- Allocate frame buffers and tensors with 64 B alignment:
  `void* p = std::aligned_alloc(64, round_up(bytes, 64));` (size must be a multiple of the
  alignment for `aligned_alloc`), or `posix_memalign(&p, 64, bytes)`.
- Row strides: keep them multiples of 64 B when you control the layout. 1920 B and 7680 B are.
- Avoid power-of-two strides that are multiples of 4 KB across many rows accessed together
  (cache set conflicts in a 4-way L1D: 32 KB / 4 ways = 8 KB per way). If a column-wise pass is
  unavoidable, pad the stride by 64 B.
- False sharing: two threads writing different variables in the same 64 B line force the line to
  bounce between cores (through the L2/snoop logic). Put per-thread counters, queue head/tail
  indices and flags in separate lines:

```cpp
struct alignas(64) PerThreadStats {
  std::atomic<uint64_t> frames{0};
  std::atomic<uint64_t> drops{0};
  // padded to 64 B by alignas
};
static_assert(sizeof(PerThreadStats) == 64, "one cache line per thread");
PerThreadStats g_stats[4];
```
`std::hardware_destructive_interference_size` exists in C++17 but GCC 11 warns when it is used in
headers (ABI stability); hard-code 64 for the TX8.

## 4. No per-frame allocation: buffer pools

At startup, after reading the config (resolution, MX3 chip count) and detecting RAM:
1. Allocate a fixed pool of N frame buffers per type (e.g. 3-4 float input tensors, 3-4 output
   buffers, metadata slots), 64 B aligned.
2. Touch every page once (`std::memset` or write a pattern) so page faults happen at startup,
   not in the first frames (this also helps the 3 s start-latency target only if done before
   "start"; do it at process init).
3. Pass buffers between stages by index or pointer through bounded queues
   (`threading-and-rt.md`). Ownership is explicit: exactly one stage owns a buffer at a time.
4. If the pool is empty, apply the drop policy (drop the oldest frame) and count it; never
   allocate a new buffer.

```cpp
#include <cstdlib>
#include <cstring>
#include <memory>

struct FreeDeleter { void operator()(void* p) const noexcept { std::free(p); } };
using AlignedBuf = std::unique_ptr<float[], FreeDeleter>;

inline AlignedBuf make_aligned_floats(size_t count) {
  const size_t bytes = ((count * sizeof(float) + 63) / 64) * 64;
  void* p = std::aligned_alloc(64, bytes);
  if (!p) return AlignedBuf{};          // caller must check and report
  std::memset(p, 0, bytes);            // pre-fault pages now
  return AlignedBuf(static_cast<float*>(p));
}
```
Also avoid in the hot path: `std::vector::push_back` beyond reserved capacity, `std::string`
building, `std::function` with heap captures, `shared_ptr` copies (atomic refcount traffic),
`iostream`. Pre-reserve vectors at startup and `clear()` them per frame (keeps capacity).

## 5. Prefetch distance

- Sequential streams are handled by the hardware prefetcher; first measure
  `L1D_CACHE_REFILL (0x03)` per kilo-instruction and `PREFETCH_LINEFILL (0xC2)` with
  `scripts/perf_a53.sh`.
- If refills remain high in a streaming loop, add `__builtin_prefetch(ptr + D)` once per 64 B line
  with D = 128-256 B ahead in L1 terms. For DRAM-bound streams, a larger distance (e.g. 512 B-1 KB)
  may be needed: latency (> 100 ns ~ 120+ cycles at 1.2 GHz) x bytes consumed per cycle. Tune
  by measurement; keep at most a few outstanding (the A53 tracks ~3 L1D misses).
- Prefetch hints do not fault, but keep the pointer arithmetic in bounds (UB otherwise).

## 6. DRAM bandwidth (theoretical vs measured)

- Theoretical peak: DDR4-2400 = 2400 MT/s x 4 B (32-bit bus) = **9.6 GB/s** total for the SoC,
  shared by all CPU cores, USB, PCIe (MX3 traffic), GbE and the GPU.
- A single A53 core typically achieves a fraction of that (in-order core, few outstanding
  misses); several cores together get closer. Expect real numbers well below 9.6 GB/s:
  **verify on TX8** with `./membw --bw` (single and 4 threads) and record them in the project.
- Our steady-state demand is small: e.g. 30 fps x (1.2 MB u8 write + 1.2 MB read + 4.9 MB float
  write + MX3 DMA read 4.9 MB) ~ 370 MB/s. Bandwidth is rarely the bottleneck at 640x640x30;
  latency (cache misses in the hot loop) and compute are. Measure before assuming either way.

## 7. TLB and huge pages

- A53 main TLB is about 512 entries with 4 KB pages, i.e. ~2 MB coverage (TRM; verify revision).
  A 4.9 MB tensor exceeds it, but sequential access misses the TLB only once per 4 KB page,
  which is cheap. Check `L1D_TLB_REFILL (0x05)` before doing anything.
- Transparent Huge Pages: check (read-only) `cat /sys/kernel/mm/transparent_hugepage/enabled`.
  If it is `madvise`, you may call `madvise(p, bytes, MADV_HUGEPAGE)` on large, 2 MB aligned pool
  buffers (allocate with `aligned_alloc(2 << 20, ...)`). Only if measurement shows TLB refills
  matter. Changing the system THP setting is a system configuration change: ask first.
- Explicit hugetlbfs pages require root configuration (`vm.nr_hugepages`): ask first; usually not
  worth it here.

## 8. RAM budget (2 GB EVT / 4 GB MP)

Detect at runtime; never hard-code:
```cpp
#include <unistd.h>
inline uint64_t phys_ram_bytes() {
  const long pages = sysconf(_SC_PHYS_PAGES), psz = sysconf(_SC_PAGESIZE);
  return (pages > 0 && psz > 0) ? uint64_t(pages) * uint64_t(psz) : 0;
}
// Also read MemAvailable from /proc/meminfo before sizing optional caches.
```

Starting budget for the 2 GB board (fill in measured values, `ps -o rss`, `/proc/<pid>/status`):

| Consumer | Budget idea | How to measure |
|---|---|---|
| Kernel + Ubuntu services | measure (`free -m` at idle) | `free -m`, `smem` if present |
| MemryX runtime / mxa-manager | measure | `VmRSS` of the processes |
| Input tensor pool (4 x 4.9 MB) | ~20 MB | static |
| Decode strips / u8 frames | < 10 MB | static |
| MJPEG CH1 forward ring (e.g. 8 x 512 KB) | ~4 MB | static |
| Output + metadata pools | < 2 MB | static |
| Logs, stack (8 MB default per thread virtual, RSS small) | small | `VmRSS` |
| Safety margin | >= 25 % of RAM free | `MemAvailable` |

Rules: fixed pools sized from config at startup; refuse to start (and report) if
`MemAvailable` is below the requirement; no unbounded caches. The 4 GB MP board must not get a
different code path, only possibly larger optional buffers.

## 9. mlock for real-time threads

Page faults in an RT thread cause latency spikes (ms-level if swapped or file-backed).
- After allocating pools and pre-faulting them: `mlock(ptr, bytes)` on the pools, or
  `mlockall(MCL_CURRENT)` once at the end of initialization.
- Avoid `MCL_FUTURE` unless you understand it: every later allocation (including thread stacks,
  libraries loaded by the MemryX runtime) becomes locked and can fail with `ENOMEM`/`EAGAIN`
  when `RLIMIT_MEMLOCK` is reached.
- Locking needs `CAP_IPC_LOCK` or a sufficient `RLIMIT_MEMLOCK` (`ulimit -l`, read-only check).
  Raising the limit (e.g. `/etc/security/limits.d/`, systemd `LimitMEMLOCK=`) is a system change:
  ask first. If `mlock` fails, log it and continue (degraded), do not abort silently.
- Check swap: `swapon --show`; with swap disabled, anonymous memory cannot be swapped anyway,
  but file-backed code pages can still be evicted.

## 10. Checklist

- [ ] No per-frame `malloc/new`; pools allocated, pre-faulted (and optionally locked) at init.
- [ ] Hot buffers 64 B aligned; per-thread mutable data on separate lines.
- [ ] Each pixel touched in as few passes as possible (fused decode -> normalize).
- [ ] Working set per core sized for the shared 1 MB L2.
- [ ] RAM detected at runtime; budget and margin documented with measured values.
- [ ] Bandwidth/latency numbers measured on TX8 (`membw`), not copied from other boards.
