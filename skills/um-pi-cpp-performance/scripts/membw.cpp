// membw.cpp - memory bandwidth and latency probe for the TX8 (4x Cortex-A53, 32 KB L1D,
// 1 MB shared L2, DDR4-2400 32-bit). Use it to replace "verify on TX8" placeholders with
// measured numbers (L1/L2/DRAM latency, single- and multi-core bandwidth).
//
// Build (on the board):
//   g++ -std=c++17 -O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror -pthread \
//       membw.cpp -o membw
// Run:
//   ./membw                         bandwidth (1 and all threads) + latency sweep
//   ./membw --bw --threads 1,2,4    bandwidth only, for 1, 2 and 4 threads
//   ./membw --latency --max-mb 128  pointer-chase latency only, up to 128 MiB
//   ./membw --csv                   CSV output
//   ./membw --help
//
// Notes:
// - Bandwidth: per-thread private buffers (first-touched by the owning thread), threads pinned
//   to CPUs 0..N-1. read = NEON 128-bit loads, 4 accumulators; write = memset with a non-zero
//   byte (glibc may use DC ZVA for zero fills, which would not be a normal write);
//   copy = memcpy, reported as read+write traffic (2 x bytes copied), STREAM-style.
//   Results are decimal GB/s (1e9 bytes/s). Theoretical DDR4-2400 x 32-bit peak = 9.6 GB/s.
// - Latency: random cyclic pointer chase over 64-byte nodes; includes TLB misses for large
//   sizes (4 KB pages). Report sizes well inside L1 (<= 16 KiB), inside L2 (256-512 KiB) and
//   far beyond L2 (>= 32 MiB) as the TX8 L1/L2/DRAM numbers.
// - Run on an otherwise idle board; record governor and temperature. Stop the pipeline first.
// - Memory needed: up to threads x 2 x max-mb (copy test). Default max-mb = 64.

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include <pthread.h>
#include <sched.h>
#include <unistd.h>

#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>
#define MEMBW_NEON 1
#else
#define MEMBW_NEON 0
#endif

namespace {

double now_s() {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
  return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) * 1e-9;
}

template <typename T>
inline void do_not_optimize(const T& v) { asm volatile("" : : "r,m"(v) : "memory"); }

uint8_t* alloc64(size_t bytes) {
  const size_t b = (bytes + 63) / 64 * 64;
  void* p = std::aligned_alloc(64, b);
  if (!p) {
    std::fprintf(stderr, "error: allocation of %zu bytes failed\n", b);
    std::exit(1);
  }
  std::memset(p, 0x11, b);  // first touch by the calling thread
  return static_cast<uint8_t*>(p);
}

void pin(int cpu) {
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  const int rc = pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
  if (rc != 0) std::fprintf(stderr, "warning: cannot pin to cpu %d: %s\n", cpu, std::strerror(rc));
}

// bytes must be a multiple of 64
uint64_t read_kernel(const uint8_t* p, size_t bytes) {
#if MEMBW_NEON
  uint64x2_t a0 = vdupq_n_u64(0), a1 = a0, a2 = a0, a3 = a0;
  for (size_t i = 0; i < bytes; i += 64) {
    a0 = vaddq_u64(a0, vld1q_u64(reinterpret_cast<const uint64_t*>(p + i)));
    a1 = vaddq_u64(a1, vld1q_u64(reinterpret_cast<const uint64_t*>(p + i + 16)));
    a2 = vaddq_u64(a2, vld1q_u64(reinterpret_cast<const uint64_t*>(p + i + 32)));
    a3 = vaddq_u64(a3, vld1q_u64(reinterpret_cast<const uint64_t*>(p + i + 48)));
  }
  const uint64x2_t s = vaddq_u64(vaddq_u64(a0, a1), vaddq_u64(a2, a3));
  return vgetq_lane_u64(s, 0) + vgetq_lane_u64(s, 1);
#else
  uint64_t s0 = 0, s1 = 0, s2 = 0, s3 = 0;
  for (size_t i = 0; i < bytes; i += 64) {
    uint64_t w[8];
    std::memcpy(w, p + i, 64);
    s0 += w[0] + w[4]; s1 += w[1] + w[5]; s2 += w[2] + w[6]; s3 += w[3] + w[7];
  }
  return s0 + s1 + s2 + s3;
#endif
}

enum class Kind { Read, Write, Copy };
const char* kind_name(Kind k) { return k == Kind::Read ? "read" : (k == Kind::Write ? "write" : "copy"); }

struct BwResult { Kind kind; size_t bytes; int threads; double gbps; };

BwResult run_bw(Kind kind, size_t bytes, int threads, size_t target_bytes) {
  const size_t reps = std::max<size_t>(1, target_bytes / bytes);
  std::atomic<int> ready{0};
  std::atomic<bool> go{false};
  std::vector<double> end_t(static_cast<size_t>(threads), 0.0);
  std::vector<std::thread> pool;
  double start_t = 0.0;

  for (int t = 0; t < threads; ++t) {
    pool.emplace_back([&, t] {
      pin(t);
      uint8_t* a = alloc64(bytes);
      uint8_t* b = (kind == Kind::Copy) ? alloc64(bytes) : nullptr;
      uint64_t sink = read_kernel(a, bytes);  // warm-up pass
      ready.fetch_add(1, std::memory_order_acq_rel);
      while (!go.load(std::memory_order_acquire)) std::this_thread::yield();
      for (size_t r = 0; r < reps; ++r) {
        switch (kind) {
          case Kind::Read: sink += read_kernel(a, bytes); break;
          case Kind::Write: std::memset(a, static_cast<int>(0x5A + (r & 1)), bytes); break;
          case Kind::Copy: std::memcpy(b, a, bytes); break;
        }
        do_not_optimize(a[0]);
      }
      end_t[static_cast<size_t>(t)] = now_s();
      do_not_optimize(sink);
      std::free(a);
      std::free(b);
    });
  }
  while (ready.load(std::memory_order_acquire) < threads) std::this_thread::yield();
  start_t = now_s();
  go.store(true, std::memory_order_release);
  for (auto& th : pool) th.join();

  const double end = *std::max_element(end_t.begin(), end_t.end());
  const double traffic_per_rep = (kind == Kind::Copy) ? 2.0 * static_cast<double>(bytes)
                                                      : static_cast<double>(bytes);
  const double total = traffic_per_rep * static_cast<double>(reps) * threads;
  const double secs = end - start_t;
  return BwResult{kind, bytes, threads, secs > 0 ? total / secs / 1e9 : 0.0};
}

struct alignas(64) Node {
  Node* next;
  char pad[64 - sizeof(Node*)];
};

// Average load-to-use latency (ns) of a random pointer chase over `bytes`.
double chase_ns(size_t bytes, std::mt19937_64& rng) {
  const size_t n = std::max<size_t>(2, bytes / sizeof(Node));
  std::vector<Node> nodes(n);   // C++17 aligned new honors alignas(64); value-initialized
  std::vector<size_t> order(n);
  for (size_t i = 0; i < n; ++i) order[i] = i;
  // Sattolo's algorithm: a single cycle visiting every node
  for (size_t i = n - 1; i > 0; --i) {
    std::uniform_int_distribution<size_t> d(0, i - 1);
    std::swap(order[i], order[d(rng)]);
  }
  for (size_t i = 0; i < n; ++i) nodes[order[i]].next = &nodes[order[(i + 1) % n]];
  const size_t steps = std::max<size_t>(2000000, 4 * n);
  Node* p = &nodes[order[0]];
  for (size_t i = 0; i < n; ++i) p = p->next;  // warm-up: one full cycle
  const double t0 = now_s();
  for (size_t i = 0; i < steps; i += 4) {      // 4 dependent loads per iteration
    p = p->next; p = p->next; p = p->next; p = p->next;
  }
  const double t1 = now_s();
  do_not_optimize(p);
  return (t1 - t0) * 1e9 / static_cast<double>(steps);
}

std::vector<int> parse_threads(const std::string& s) {
  std::vector<int> v;
  size_t pos = 0;
  while (pos <= s.size()) {
    const size_t c = s.find(',', pos);
    const std::string tok = s.substr(pos, c == std::string::npos ? std::string::npos : c - pos);
    const int t = std::atoi(tok.c_str());
    if (t > 0) v.push_back(t);
    if (c == std::string::npos) break;
    pos = c + 1;
  }
  return v;
}

void usage() {
  std::printf(
      "usage: membw [--bw] [--latency] [--threads LIST] [--max-mb M] [--target-mb T] [--csv] [--help]\n"
      "  --bw          run bandwidth tests (read/write/copy)\n"
      "  --latency     run pointer-chase latency sweep (4 KiB .. max-mb)\n"
      "                (default: both)\n"
      "  --threads L   comma-separated thread counts for --bw (default: 1,<nproc>)\n"
      "  --max-mb M    largest buffer per thread in MiB (default 64)\n"
      "  --target-mb T bytes moved per thread per test in MiB (default 256)\n"
      "  --csv         CSV output\n");
}

}  // namespace

int main(int argc, char** argv) {
  bool do_bw = false, do_lat = false, csv = false;
  size_t max_mb = 64, target_mb = 256;
  const long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
  std::string threads_arg = "1," + std::to_string(ncpu > 0 ? ncpu : 1);

  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    auto val = [&](const char* name) -> std::string {
      if (i + 1 >= argc) { std::fprintf(stderr, "missing value for %s\n", name); std::exit(2); }
      return argv[++i];
    };
    if (a == "--help" || a == "-h") { usage(); return 0; }
    else if (a == "--bw") do_bw = true;
    else if (a == "--latency") do_lat = true;
    else if (a == "--csv") csv = true;
    else if (a == "--threads") threads_arg = val("--threads");
    else if (a == "--max-mb") max_mb = static_cast<size_t>(std::strtoull(val("--max-mb").c_str(), nullptr, 10));
    else if (a == "--target-mb") target_mb = static_cast<size_t>(std::strtoull(val("--target-mb").c_str(), nullptr, 10));
    else { std::fprintf(stderr, "unknown argument: %s\n", a.c_str()); usage(); return 2; }
  }
  if (!do_bw && !do_lat) do_bw = do_lat = true;
  if (max_mb == 0) max_mb = 1;
  if (target_mb == 0) target_mb = 1;
  const size_t max_bytes = max_mb << 20;
  const size_t target = target_mb << 20;

  if (!csv) std::printf("# membw: online CPUs=%ld neon=%d max=%zu MiB target=%zu MiB/thread/test\n",
                        ncpu, MEMBW_NEON, max_mb, target_mb);

  if (do_bw) {
    const size_t sizes[] = {16u << 10, 256u << 10, 768u << 10, 4u << 20, 64u << 20};
    const Kind kinds[] = {Kind::Read, Kind::Write, Kind::Copy};
    if (csv) std::printf("test,kind,bytes,threads,gbps\n");
    else std::printf("\n%-6s %12s %8s %10s\n", "kind", "bytes", "threads", "GB/s");
    for (int th : parse_threads(threads_arg)) {
      if (th > ncpu) std::fprintf(stderr, "note: %d threads > %ld online CPUs\n", th, ncpu);
      for (Kind k : kinds)
        for (size_t sz : sizes) {
          if (sz > max_bytes) continue;
          const BwResult r = run_bw(k, sz, th, target);
          if (csv) std::printf("bw,%s,%zu,%d,%.3f\n", kind_name(r.kind), r.bytes, r.threads, r.gbps);
          else std::printf("%-6s %12zu %8d %10.3f\n", kind_name(r.kind), r.bytes, r.threads, r.gbps);
        }
    }
  }

  if (do_lat) {
    std::mt19937_64 rng(12345);
    pin(0);
    if (csv) std::printf("test,bytes,ns_per_load\n");
    else std::printf("\n%12s %12s\n", "bytes", "ns/load");
    for (size_t sz = 4u << 10; sz <= max_bytes; sz *= 2) {
      const double ns = chase_ns(sz, rng);
      if (csv) std::printf("latency,%zu,%.2f\n", sz, ns);
      else std::printf("%12zu %12.2f\n", sz, ns);
    }
    if (!csv) std::printf("# cycles = ns x core GHz (check scaling_cur_freq); L1 <= 16 KiB, L2 ~ 256-512 KiB, DRAM >= 32 MiB\n");
  }
  return 0;
}
