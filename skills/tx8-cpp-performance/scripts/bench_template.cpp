// bench_template.cpp - example: scalar vs NEON score threshold + compaction on the TX8.
//
// Build (on the board, project flags):
//   g++ -std=c++17 -O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror \
//       bench_template.cpp -o bench
// Run:
//   ./bench                       human-readable output
//   ./bench --csv                 CSV (append to your results file)
//   ./bench --n 8400 --hit 0.01 --iters 100 --reps 64 --cpu 2
//   ./bench --help
//
// What it shows: the measure-first workflow on a real post-processing kernel. It first checks
// correctness of the NEON kernel against the scalar reference (edge sizes, NaN, all-hit,
// no-hit), then benchmarks both with a realistic sparse score distribution.
// It also builds on x86 (scalar only) for a quick syntax check in WSL2.

#include "bench_template.hpp"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <random>
#include <string>
#include <vector>

#if defined(__aarch64__) && defined(__ARM_NEON)
#include <arm_neon.h>
#define HAVE_NEON 1
#else
#define HAVE_NEON 0
#endif

// ---- kernels -----------------------------------------------------------------------------

// Scalar reference: out capacity >= n. Branchless: always writes, advances on hit.
// NaN never passes (comparison is false).
static size_t threshold_compact_ref(const float* s, size_t n, float t, uint32_t* out) {
  size_t k = 0;
  for (size_t i = 0; i < n; ++i) {
    out[k] = static_cast<uint32_t>(i);
    k += (s[i] > t) ? 1u : 0u;
  }
  return k;
}

#if HAVE_NEON
// NEON: 16 scores per step, cheap "any hit?" test; rare hits handled by branchless scalar code.
static size_t threshold_compact_neon(const float* __restrict__ s, size_t n, float t,
                                     uint32_t* __restrict__ out) {
  const float32x4_t vt = vdupq_n_f32(t);
  size_t k = 0, i = 0;
  for (; i + 16 <= n; i += 16) {
    const uint32x4_t m0 = vcgtq_f32(vld1q_f32(s + i), vt);
    const uint32x4_t m1 = vcgtq_f32(vld1q_f32(s + i + 4), vt);
    const uint32x4_t m2 = vcgtq_f32(vld1q_f32(s + i + 8), vt);
    const uint32x4_t m3 = vcgtq_f32(vld1q_f32(s + i + 12), vt);
    const uint32x4_t any = vorrq_u32(vorrq_u32(m0, m1), vorrq_u32(m2, m3));
    if (vmaxvq_u32(any) == 0) continue;
    for (size_t j = i; j < i + 16; ++j) {
      out[k] = static_cast<uint32_t>(j);
      k += (s[j] > t) ? 1u : 0u;
    }
  }
  for (; i < n; ++i) {
    out[k] = static_cast<uint32_t>(i);
    k += (s[i] > t) ? 1u : 0u;
  }
  return k;
}
#endif

using KernelFn = size_t (*)(const float*, size_t, float, uint32_t*);

// ---- correctness ---------------------------------------------------------------------------

static bool check_case(KernelFn fn, const std::vector<float>& s, float t, const char* what) {
  std::vector<uint32_t> a(s.size() + 1), b(s.size() + 1);
  const size_t ka = threshold_compact_ref(s.data(), s.size(), t, a.data());
  const size_t kb = fn(s.data(), s.size(), t, b.data());
  if (ka != kb) {
    std::fprintf(stderr, "FAIL [%s] n=%zu: count ref=%zu test=%zu\n", what, s.size(), ka, kb);
    return false;
  }
  for (size_t i = 0; i < ka; ++i)
    if (a[i] != b[i]) {
      std::fprintf(stderr, "FAIL [%s] n=%zu: index %zu ref=%u test=%u\n", what, s.size(), i, a[i], b[i]);
      return false;
    }
  return true;
}

static bool self_test(KernelFn fn) {
  std::mt19937 rng(42);
  std::uniform_real_distribution<float> u(0.0f, 1.0f);
  bool ok = true;
  const size_t sizes[] = {0, 1, 3, 4, 15, 16, 17, 31, 32, 33, 8400};
  for (size_t n : sizes) {
    std::vector<float> s(n);
    for (auto& x : s) x = u(rng);
    ok &= check_case(fn, s, 0.5f, "random");
    ok &= check_case(fn, s, 2.0f, "no-hit");
    ok &= check_case(fn, s, -1.0f, "all-hit");
    if (n > 0) {
      s[n / 2] = std::numeric_limits<float>::quiet_NaN();
      s[0] = std::numeric_limits<float>::infinity();
      ok &= check_case(fn, s, 0.5f, "nan+inf");
    }
  }
  return ok;
}

// ---- main --------------------------------------------------------------------------------

static void usage() {
  std::printf(
      "usage: bench [--csv] [--n N] [--hit FRACTION] [--thr T] [--iters N] [--warmup N]\n"
      "             [--reps N] [--cpu K] [--help]\n"
      "  --n       number of scores per call (default 8400 = YOLO 640x640 anchors)\n"
      "  --hit     fraction of scores above the threshold (default 0.01)\n"
      "  --thr     threshold (default 0.5)\n"
      "  --iters   timed samples (default 100, >= 30 recommended)\n"
      "  --warmup  untimed warmup calls (default 10)\n"
      "  --reps    calls per sample (default 64)\n"
      "  --cpu     pin to this CPU (default: not pinned)\n"
      "  --csv     print CSV instead of human-readable lines\n");
}

int main(int argc, char** argv) {
  size_t n = 8400;
  double hit = 0.01;
  float thr = 0.5f;
  bool csv = false;
  int cpu = -1;
  bench::Options opt;
  opt.iters = 100;
  opt.warmup = 10;
  opt.inner_reps = 64;

  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    auto next = [&](const char* name) -> const char* {
      if (i + 1 >= argc) { std::fprintf(stderr, "missing value for %s\n", name); std::exit(2); }
      return argv[++i];
    };
    if (a == "--help" || a == "-h") { usage(); return 0; }
    else if (a == "--csv") csv = true;
    else if (a == "--n") n = static_cast<size_t>(std::strtoull(next("--n"), nullptr, 10));
    else if (a == "--hit") hit = std::strtod(next("--hit"), nullptr);
    else if (a == "--thr") thr = std::strtof(next("--thr"), nullptr);
    else if (a == "--iters") opt.iters = std::atoi(next("--iters"));
    else if (a == "--warmup") opt.warmup = std::atoi(next("--warmup"));
    else if (a == "--reps") opt.inner_reps = std::atoi(next("--reps"));
    else if (a == "--cpu") cpu = std::atoi(next("--cpu"));
    else { std::fprintf(stderr, "unknown argument: %s\n", a.c_str()); usage(); return 2; }
  }
  if (cpu >= 0) {
    const int rc = bench::pin_to_cpu(cpu);
    if (rc != 0) std::fprintf(stderr, "warning: pin_to_cpu(%d) failed: %s\n", cpu, std::strerror(rc));
  }

  // 1. correctness first
#if HAVE_NEON
  if (!self_test(threshold_compact_neon)) { std::fprintf(stderr, "self-test FAILED\n"); return 1; }
#endif
  if (!self_test(threshold_compact_ref)) { std::fprintf(stderr, "self-test FAILED (ref)\n"); return 1; }

  // 2. realistic input: most scores well below threshold, a fraction above
  std::mt19937 rng(7);
  std::uniform_real_distribution<float> low(0.0f, thr * 0.6f), high(thr + 0.01f, 1.0f);
  std::bernoulli_distribution is_hit(hit < 0 ? 0.0 : (hit > 1 ? 1.0 : hit));
  std::vector<float> scores(n);
  for (auto& x : scores) x = is_hit(rng) ? high(rng) : low(rng);
  std::vector<uint32_t> out(n + 4);
  opt.items = static_cast<double>(n);

  size_t sink = 0;
  const bench::Result r_ref = bench::run("threshold_compact_ref", opt, [&] {
    sink += threshold_compact_ref(scores.data(), n, thr, out.data());
    bench::do_not_optimize(out[0]);
  });
#if HAVE_NEON
  const bench::Result r_neon = bench::run("threshold_compact_neon", opt, [&] {
    sink += threshold_compact_neon(scores.data(), n, thr, out.data());
    bench::do_not_optimize(out[0]);
  });
#endif
  bench::do_not_optimize(sink);

  if (csv) {
    bench::print_csv_header();
    bench::print_csv(r_ref);
#if HAVE_NEON
    bench::print_csv(r_neon);
#endif
  } else {
    std::printf("# n=%zu hit=%.4f thr=%.3f iters=%d reps=%d cpu=%d\n", n, hit, static_cast<double>(thr),
                opt.iters, opt.inner_reps, cpu);
    bench::print_human(r_ref);
#if HAVE_NEON
    bench::print_human(r_neon);
    std::printf("# speed-up (median): %.2fx\n", bench::speedup(r_ref, r_neon));
#else
    std::printf("# NEON not available in this build (not AArch64): scalar only\n");
#endif
    std::printf("# record governor/temperature: cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor\n");
  }
  return 0;
}
