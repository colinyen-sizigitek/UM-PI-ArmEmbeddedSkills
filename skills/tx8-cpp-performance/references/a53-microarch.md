# Cortex-A53 micro-architecture: actionable coding rules

Arm does not publish a Software Optimization Guide for the Cortex-A53. The rules below combine
the A53 TRM (DDI0500J), the Cortex-A55 SOG (EPM128372, used as an upper bound only) and community
micro-benchmarks (destevez.net 2025 on a Kria KV260, Chips and Cheese 2023, Tencent ncnn wiki,
S922X measurements). Every cycle number here was measured on *another* A53 SoC: **verify on TX8**
with `scripts/bench_template.hpp` and `scripts/perf_a53.sh` before relying on it.

TX8 facts (from the datasheet): 4x A53 up to 1.2 GHz, 32 KB L1I (2-way) + 32 KB L1D (4-way) per
core, 1 MB shared 16-way L2, no L3, 64 B lines, Armv8.0-A (no LSE, no dotprod, no fp16 arith).

## 1. The machine in one paragraph

8-stage, in-order, partially dual-issue, no register renaming. If an instruction's input is not
ready, *everything behind it waits*. There are two integer ALUs, one multiply/divide path, one
load/store unit with a single address-generation unit (AGU), and two 64-bit FP/NEON pipes. A
128-bit (Q-form, e.g. `fadd v0.4s`) NEON instruction occupies both NEON pipes for its issue cycle.
The L1D load data path is 64 bits wide, the store path 128 bits. Throughput therefore depends on
*instruction order* far more than on an out-of-order core: the compiler's scheduling and your
choice of independent operations matter.

| Property | Value (source) | Status |
|---|---|---|
| FADD / FMUL / FMLA result latency | ~4 cycles (destevez, ncnn) | verify on TX8 |
| Integer ADD latency | 1 cycle (forwarded) | verify on TX8 |
| `ldr q` / `ld1 {v.4s}` issue cost | 2 cycles per Q register, no dual-issue | verify on TX8 |
| `ldr d` / `ldr x` | 1 cycle; `ldr x` dual-issues with NEON math | verify on TX8 |
| `str q` | 1 cycle | verify on TX8 |
| Load + store in the same cycle | not possible (one AGU) | verify on TX8 |
| L1D hit latency | 3 cycles; +1 when crossing 8 B (scalar) / 16 B (NEON) | verify on TX8 |
| Outstanding L1D misses | ~3 | verify on TX8 |
| L2 hit latency | ~17 cycles (S922X) | verify on TX8 with `membw --latency` |
| DRAM latency | > 100 ns | verify on TX8 |
| Taken branch bubble | ~3 cycles (no BTB in the classic sense) | verify on TX8 |
| Branch mispredict | ~7 cycles | verify on TX8 |

## 2. Rule: break dependency chains (>= 4 accumulators)

With a 4-cycle FMLA latency and one Q-FMLA issued per cycle, a single accumulator runs at 1/4 of
peak. Use at least four independent accumulators and combine them once at the end.

```cpp
#include <arm_neon.h>
#include <cstddef>

// Sum of squares, 4 independent chains (16 floats per iteration).
float sum_sq(const float* __restrict__ x, size_t n) {
  float32x4_t a0 = vdupq_n_f32(0.f), a1 = a0, a2 = a0, a3 = a0;
  size_t i = 0;
  for (; i + 16 <= n; i += 16) {
    float32x4_t v0 = vld1q_f32(x + i);
    float32x4_t v1 = vld1q_f32(x + i + 4);
    float32x4_t v2 = vld1q_f32(x + i + 8);
    float32x4_t v3 = vld1q_f32(x + i + 12);
    a0 = vfmaq_f32(a0, v0, v0);
    a1 = vfmaq_f32(a1, v1, v1);
    a2 = vfmaq_f32(a2, v2, v2);
    a3 = vfmaq_f32(a3, v3, v3);
  }
  float s = vaddvq_f32(vaddq_f32(vaddq_f32(a0, a1), vaddq_f32(a2, a3)));
  for (; i < n; ++i) s += x[i] * x[i];  // tail
  return s;
}
```

Note: the result differs in the last bits from a sequential scalar sum (different association).
Test against the scalar reference with a relative tolerance, not `==`.

The same rule applies to scalar code: `s0 += a[i]; s1 += a[i+1]; ...` beats one `s += a[i]`.
GCC will not reassociate float sums for you without `-fassociative-math`; do it by hand.

## 3. Rule: interleave loads with math, not "load all, then compute"

An in-order core cannot run ahead. Load data for the *next* step while computing the current one
(software pipelining). In intrinsics, write the loop so loads for iteration i+1 are issued before
the math of iteration i, and let GCC (`-mcpu=cortex-a53` scheduling) place them. Then *check the
assembly* (`objdump -d --no-show-raw-insn obj.o | less` or `g++ -S`) and measure.

```cpp
// Pipelined y = a*x + b over n floats (n multiple of 8, n >= 8 for brevity).
void axpb(const float* __restrict__ x, float* __restrict__ y, size_t n, float a, float b) {
  const float32x4_t va = vdupq_n_f32(a), vb = vdupq_n_f32(b);
  float32x4_t c0 = vld1q_f32(x), c1 = vld1q_f32(x + 4);
  size_t i = 0;
  for (; i + 16 <= n; i += 8) {
    float32x4_t n0 = vld1q_f32(x + i + 8);      // next iteration's data
    float32x4_t n1 = vld1q_f32(x + i + 12);
    vst1q_f32(y + i,     vfmaq_f32(vb, c0, va));  // current iteration's math
    vst1q_f32(y + i + 4, vfmaq_f32(vb, c1, va));
    c0 = n0; c1 = n1;
  }
  vst1q_f32(y + i,     vfmaq_f32(vb, c0, va));
  vst1q_f32(y + i + 4, vfmaq_f32(vb, c1, va));
  for (i += 8; i < n; ++i) y[i] = a * x[i] + b;   // never runs when n % 8 == 0
}
```

## 4. Rule: Q vs D registers and the 64-bit load path

Because the load path is 64-bit and a Q-form NEON op blocks both pipes, kernels that are
*load-limited* (few operations per loaded byte, e.g. scale+offset, format conversion) can run
faster when 128-bit loads are split. The published technique (ncnn wiki, destevez):

- Load the low half with `ldr d<n>` (uses the NEON side, 1 cycle).
- Load the high half into a general register with `ldr x<m>`; this dual-issues with NEON math.
- Insert it with `ins v<n>.d[1], x<m>`; this dual-issues with the next `ldr d`.
- Alternatively operate on 64-bit vectors (`float32x2_t`, `.2s`) so math and `ldr d` pair.

Guidance for this project:
1. Default to plain Q-form intrinsics (`vld1q`, `vfmaq`). They are correct, readable, and GCC does
   a reasonable job.
2. Only when `perf` shows a kernel is in the top of the profile **and** `LD_DEP_STALL (0xE7)` or
   `SIMD_DEP_STALL (0xE6)` dominate, try the D-load/`ins` pattern in a small inline-asm or `.S`
   kernel. Keep the intrinsics version as the reference and fallback.
3. Compute-heavy kernels (many FMLA per load) gain little; the ncnn rule of thumb is one vector
   load every three FMLA.

You cannot force `ldr d + ldr x + ins` from intrinsics reliably; GCC may merge them. Inspect the
assembly; if you need the exact sequence, write it in assembly and benchmark it.

## 5. Rule: one memory operation per cycle

With one AGU, a load and a store cannot issue together, and `ld1 {v0-v3}` costs ~8 cycles of load
slots. Consequences:
- Avoid read-modify-write passes over the same buffer when one fused pass is possible.
- Prefer computing in registers (e.g. combine conversions) over storing intermediates.
- `vld3q_u8` (RGB deinterleave) is load-slot heavy; it is still usually the best option for
  interleaved pixels, but count it: 48 bytes = 6 x 64-bit beats.
- Post-increment addressing (`[x0], #16`) is free; GCC does this for simple loops.

## 6. Rule: branchless hot loops

The predictor is simple and mispredicts cost ~7 cycles. Turn data-dependent branches into
arithmetic or masks.

Scalar threshold/compaction (writes every element, advances only on hits):
```cpp
size_t compact_scalar(const float* s, size_t n, float t, uint32_t* out /* capacity >= n */) {
  size_t k = 0;
  for (size_t i = 0; i < n; ++i) {
    out[k] = static_cast<uint32_t>(i);
    k += (s[i] > t);          // compiles to cmp + cset + add, no branch
  }
  return k;
}
```

NEON select instead of `if`:
```cpp
// y = (x > t) ? x : 0  for 4 lanes
float32x4_t clamp_below(float32x4_t x, float32x4_t t) {
  uint32x4_t m = vcgtq_f32(x, t);
  return vbslq_f32(m, x, vdupq_n_f32(0.f));
}
```

A branch that is almost always taken the same way (e.g. "any hit in these 16 scores?" when hits
are rare) is cheap and is fine; see `neon-intrinsics.md` threshold example.

## 7. Rule: loop overhead and the taken-branch bubble

Each taken backward branch costs a bubble. Unroll small loops 2-4x (GCC: `-funroll-loops` per file
or `#pragma GCC unroll 4`) so the bubble is amortized, but watch L1I (32 KB) and code size.
Prefer counted loops (`for (size_t i = 0; i + 16 <= n; i += 16)`) that GCC can analyze.

## 8. Rule: alignment and boundary crossings

Loads that cross a 16 B boundary (NEON) or 8 B boundary (scalar) cost an extra cycle; loads that
cross a 64 B cache line can touch two lines. Allocate image rows and tensors 64 B aligned and keep
row strides multiples of 64 B where the format allows (640 * 3 = 1920 B = 30 lines: good;
640 * 4 * 3 = 7680 B: good). See `memory-and-cache.md`.

## 9. Rule: prefetch only after measuring

The A53 has a hardware stride prefetcher that handles simple sequential streams. For streams it
does not catch (several interleaved streams, large strides, pointer-ish access) add
`__builtin_prefetch(p + 256, 0, 3)` (emits `prfm pldl1keep`), 128-256 B ahead, once per cache line.
Measure with `L1D_CACHE_REFILL (0x03)` and `PREFETCH_LINEFILL (0xC2)`; remove it if it does not
help. Never prefetch past the end of a buffer into unmapped memory in a way that faults (prefetch
instructions do not fault, but your pointer arithmetic must not overflow).

## 10. Rule: integer division and other slow ops

- Integer divide is iterative (many cycles); replace `x / w` in pixel loops by precomputed
  reciprocal multiply or row/column counters.
- `float` divide and `sqrt` are slow on NEON (`vdivq_f32`, `vsqrtq_f32`); multiply by a
  precomputed reciprocal (e.g. `1/255`, `1/std`) instead.
- Avoid `double` in hot loops; FP64 NEON gives 2 lanes per Q register.
- Avoid moving data between general and NEON registers inside the loop (`vgetq_lane` into an
  integer that controls addressing serializes the pipeline); do it once per block.

## 11. Rule: let the compiler schedule for the right core

`-mcpu=cortex-a53` selects GCC's A53 pipeline description (scheduling + tuning). LLVM's A53 model
is known to mis-predict (it treats `ldr q` as single-cycle and misses D-form pairing), so clang
output and `llvm-mca` timelines are not a guide for this core. Use GCC 11 and measure.

## 12. What is unknown (verify on TX8, do not invent)

- Exact core revision (rNpM) -> erratum flag choice. Read `/proc/cpuinfo` ("CPU variant",
  "CPU revision").
- L2 latency and DRAM latency/bandwidth on the UM21A646 memory controller (`scripts/membw.cpp`).
- Whether the L2 is clocked at core speed, and the DRAM controller's behavior with 4 active
  streams.
- Hardware prefetcher aggressiveness/configuration (IMPLEMENTATION DEFINED registers, not
  user-accessible).
- Real sustained clock under thermal load (no SoC power/thermal data in the spec; see
  `profiling.md` for how to check throttling).
- Whether PMU interrupts are wired so that `perf record` sampling works (check
  `dmesg | grep -i pmu`).

## Checklist before declaring a kernel "done"

- [ ] Scalar reference exists and matches (tolerance documented).
- [ ] >= 4 independent accumulators for FP chains.
- [ ] No data-dependent unpredictable branch in the inner loop.
- [ ] No division, no `double`, no GPR<->NEON traffic per element.
- [ ] Buffers 64 B aligned; tail handled and tested.
- [ ] Assembly inspected for the inner loop; `perf_a53.sh` IPC and stall % recorded.
- [ ] Before/after timing on TX8 (median, p99).
