// bench_template.hpp - minimal header-only micro-benchmark harness for the TX8 (Cortex-A53).
//
// Usage (see bench_template.cpp for a full example):
//   #include "bench_template.hpp"
//   bench::Options opt;            // warmup, iterations, inner repetitions
//   auto r = bench::run("kernel_neon", opt, [&] { kernel(in, out, n); bench::do_not_optimize(out[0]); });
//   bench::print_human(r);  or  bench::print_csv_header(); bench::print_csv(r);
//
// Method: `warmup` untimed calls, then `iters` samples; each sample times `inner_reps` calls with
// CLOCK_MONOTONIC_RAW and stores the per-call time. Reports min / median / p90 / p99 / mean in
// microseconds (nearest-rank percentiles). Pin the thread (bench::pin_to_cpu) and record the
// cpufreq governor and temperature with every result (see references/profiling.md).
//
// Build (on the board):
//   g++ -std=c++17 -O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror \
//       bench_template.cpp -o bench
#pragma once

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <string>
#include <utility>
#include <vector>

#if defined(__linux__)
#include <pthread.h>
#include <sched.h>
#endif

namespace bench {

// Monotonic, not NTP-slewed clock in nanoseconds.
inline uint64_t now_ns() noexcept {
  timespec ts{};
  clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
  return static_cast<uint64_t>(ts.tv_sec) * 1000000000ull + static_cast<uint64_t>(ts.tv_nsec);
}

// Prevent the compiler from optimizing away a computed value (GCC/Clang inline asm barrier).
template <typename T>
inline void do_not_optimize(const T& value) noexcept {
  asm volatile("" : : "r,m"(value) : "memory");
}

// Force all pending writes to memory to be considered observable.
inline void clobber_memory() noexcept { asm volatile("" : : : "memory"); }

// Pin the calling thread to one CPU. Returns 0 on success, errno-style code otherwise.
inline int pin_to_cpu(int cpu) noexcept {
#if defined(__linux__)
  cpu_set_t set;
  CPU_ZERO(&set);
  CPU_SET(cpu, &set);
  return pthread_setaffinity_np(pthread_self(), sizeof(set), &set);
#else
  (void)cpu;
  return ENOSYS;
#endif
}

struct Options {
  int warmup = 5;          // untimed calls before measuring
  int iters = 50;          // number of samples (>= 30 recommended)
  int inner_reps = 1;      // calls per sample (raise for kernels shorter than ~20 us)
  double items = 0.0;      // items processed per call (for throughput); 0 = not reported
};

struct Result {
  std::string name;
  int samples = 0;
  double min_us = 0, median_us = 0, p90_us = 0, p99_us = 0, mean_us = 0;
  double items = 0;        // copied from Options
};

// Nearest-rank percentile on a sorted vector, p in [0, 100].
inline double percentile_sorted(const std::vector<double>& v, double p) {
  if (v.empty()) return 0.0;
  const double rank = std::ceil(p / 100.0 * static_cast<double>(v.size()));
  size_t idx = rank < 1.0 ? 0 : static_cast<size_t>(rank) - 1;
  if (idx >= v.size()) idx = v.size() - 1;
  return v[idx];
}

inline Result summarize(std::string name, std::vector<double> t_us, double items) {
  Result r;
  r.name = std::move(name);
  r.items = items;
  r.samples = static_cast<int>(t_us.size());
  if (t_us.empty()) return r;
  std::sort(t_us.begin(), t_us.end());
  double sum = 0;
  for (double x : t_us) sum += x;
  r.min_us = t_us.front();
  r.median_us = percentile_sorted(t_us, 50.0);
  r.p90_us = percentile_sorted(t_us, 90.0);
  r.p99_us = percentile_sorted(t_us, 99.0);
  r.mean_us = sum / static_cast<double>(t_us.size());
  return r;
}

template <typename F>
Result run(const std::string& name, const Options& opt, F&& fn) {
  const int reps = opt.inner_reps < 1 ? 1 : opt.inner_reps;
  for (int i = 0; i < opt.warmup; ++i) fn();
  std::vector<double> t_us;
  t_us.reserve(static_cast<size_t>(opt.iters > 0 ? opt.iters : 0));
  for (int i = 0; i < opt.iters; ++i) {
    const uint64_t t0 = now_ns();
    for (int k = 0; k < reps; ++k) fn();
    clobber_memory();
    const uint64_t t1 = now_ns();
    t_us.push_back(static_cast<double>(t1 - t0) / 1000.0 / reps);
  }
  return summarize(name, std::move(t_us), opt.items);
}

inline void print_csv_header(std::FILE* f = stdout) {
  std::fprintf(f, "name,samples,min_us,median_us,p90_us,p99_us,mean_us,items_per_us_median\n");
}

inline void print_csv(const Result& r, std::FILE* f = stdout) {
  const double thr = (r.items > 0 && r.median_us > 0) ? r.items / r.median_us : 0.0;
  std::fprintf(f, "%s,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n", r.name.c_str(), r.samples, r.min_us,
               r.median_us, r.p90_us, r.p99_us, r.mean_us, thr);
}

inline void print_human(const Result& r, std::FILE* f = stdout) {
  std::fprintf(f, "%-28s n=%-4d min %9.3f  med %9.3f  p90 %9.3f  p99 %9.3f  mean %9.3f us", r.name.c_str(),
               r.samples, r.min_us, r.median_us, r.p90_us, r.p99_us, r.mean_us);
  if (r.items > 0 && r.median_us > 0) std::fprintf(f, "  (%.1f items/us)", r.items / r.median_us);
  std::fprintf(f, "\n");
}

// Speed-up of b relative to a, by median.
inline double speedup(const Result& a, const Result& b) {
  return (b.median_us > 0) ? a.median_us / b.median_us : 0.0;
}

}  // namespace bench
