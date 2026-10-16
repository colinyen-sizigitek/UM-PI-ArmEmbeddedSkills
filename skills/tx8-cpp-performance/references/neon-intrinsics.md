# NEON intrinsics for Armv8.0 (TX8 Cortex-A53)

All code: C++17, `#include <arm_neon.h>`, built with `g++ -std=c++17 -O2 -mcpu=cortex-a53`.
Look up any intrinsic in the Arm Intrinsics search
(https://developer.arm.com/architectures/instruction-sets/intrinsics/, filter "Neon" + "A64")
and check its "Architectures"/required-feature field: only base Armv8.0 AdvSIMD is allowed.

Before writing intrinsics, check that GCC cannot already auto-vectorize the scalar loop
(`-O3 -fopt-info-vec-missed`, see `compiler-flags.md`) and that a library (libjpeg-turbo for
decode/color conversion) does not already do it with NEON.

## 1. Cheat sheet by task

### Load / store
| Intrinsic | Does | Notes |
|---|---|---|
| `vld1q_u8/f32(p)` | load 16 B into one Q register | no alignment requirement; aligned is faster |
| `vld1_u8(p)` | load 8 B into a D register | 64-bit load path friendly |
| `vld3q_u8(p)` | load 48 B RGBRGB... -> 3 planes of 16 | deinterleave (doc 102467 example) |
| `vld2q_u8(p)` | load 32 B, split even/odd bytes | YUYV, UV pairs (NV12 chroma) |
| `vst1q_u8/f32(p, v)` | store 16 B | |
| `vst3q_f32(p, x3)` | interleave 3 x 4 floats -> 12 floats | RGB float NHWC output |
| `vst3_u8(p, x3)` | interleave 3 x 8 bytes | RGB u8 output |
| `vdupq_n_f32(x)` | broadcast scalar | hoist out of loops |
| `vgetq_lane_u32(v, i)` / `vsetq_lane` | lane access (i constant) | avoid per element in hot loops |

### Widen / narrow
| Intrinsic | Does |
|---|---|
| `vmovl_u8(d)` / `vmovl_high_u8(q)` | u8 -> u16 (low half / high half) |
| `vmovl_u16(d)` / `vmovl_high_u16(q)` | u16 -> u32 |
| `vmovn_u32(q)` | u32 -> u16, truncating |
| `vqmovn_u32(q)` / `vqmovn_u16(q)` | unsigned saturating narrow |
| `vqmovun_s16(q)` | s16 -> u8 saturating (clamps to 0..255) |
| `vrshrn_n_u16(q, n)` | rounding shift right then narrow (fixed point) |
| `vmull_u8(a, b)` / `vmlal_u8(acc, a, b)` | u8 x u8 -> u16 multiply (accumulate) |

### Arithmetic
| Intrinsic | Does | Notes |
|---|---|---|
| `vaddq_f32`, `vsubq_f32`, `vmulq_f32` | element-wise | ~4-cycle latency |
| `vmulq_n_f32(v, s)` | multiply by scalar | |
| `vmlaq_f32(a, b, c)` | a + b*c, separate rounding | |
| `vfmaq_f32(a, b, c)` | a + b*c fused (single rounding) | preferred; results differ from scalar `a+b*c` in last bit |
| `vfmaq_n_f32(a, b, s)` | a + b*s fused | |
| `vqaddq_u8`, `vqsubq_u8` | saturating add/sub | |
| `vabdq_u8` | absolute difference | |
| `vmaxq_f32`, `vminq_f32` | max/min (NaN propagates) | `vmaxnmq_f32` returns the number if one is NaN |
| `vrecpeq_f32` + `vrecpsq_f32` | reciprocal estimate + Newton step | instead of `vdivq_f32` when accuracy allows |

### Compare / select / bit ops
| Intrinsic | Does |
|---|---|
| `vcgtq_f32(a, b)`, `vcgeq`, `vcltq`, `vceqq` | lane mask: all ones if true (NaN -> false) |
| `vbslq_f32(mask, a, b)` | bitwise select: mask ? a : b |
| `vandq_u32`, `vorrq_u32`, `veorq_u32`, `vbicq_u32` | bit ops |
| `vtstq_u32(a, b)` | (a & b) != 0 mask |
| `vshrn_n_u16(q, 4)` | compress a 16-byte mask to 64 bits (one nibble per byte) |

### Conversion
| Intrinsic | Does |
|---|---|
| `vcvtq_f32_u32`, `vcvtq_f32_s32` | int -> float |
| `vcvtq_u32_f32`, `vcvtq_s32_f32` | float -> int, truncate toward zero, saturating (negative -> 0 for u32) |
| `vcvtnq_u32_f32`, `vcvtnq_s32_f32` | float -> int, round to nearest, ties to even |
| `vcvtaq_s32_f32` | round to nearest, ties away from zero |
| `vcvt_f32_f16`, `vcvt_f16_f32` | fp16 <-> fp32 *conversion* (allowed: base Armv8.0) |

### Reductions (A64 only)
| Intrinsic | Does | Pitfall |
|---|---|---|
| `vaddvq_f32` | sum of 4 lanes | order differs from scalar sum |
| `vmaxvq_f32`, `vminvq_f32` | max/min across lanes | |
| `vmaxvq_u32(mask)` | "any lane true" test for compare masks | cheap early-out |
| `vaddvq_u8` | sum of 16 bytes into **uint8_t** | wraps; use `vaddlvq_u8` (u16 result) |
| `vaddlvq_u16` | widening sum of 8 x u16 into u32 | |

### Table lookup / permute
| Intrinsic | Does |
|---|---|
| `vqtbl1q_u8(table, idx)` | byte shuffle; index >= 16 gives 0 |
| `vqtbl2q_u8`..`vqtbl4q_u8` | 32..64-byte tables |
| `vextq_u8(a, b, n)` | sliding window across two vectors |
| `vzip1q`, `vuzp1q`, `vtrn1q` (and `2` forms) | interleave / deinterleave / transpose |
| `vrev64q_u8` | reverse within 64-bit lanes |

## 2. Intrinsics to AVOID on the A53 (will not run or not compile)

| Intrinsic family | Needs | Why not |
|---|---|---|
| `vdotq_u32`, `vdotq_s32`, `vdotq_lane_*` | Armv8.2 DotProd | A53 has no dotprod (SIGILL) |
| `vmmlaq_s32`, `vusdotq_s32` | Armv8.6 I8MM | not on A53 |
| `vaddq_f16`, `vmulq_f16`, `vfmaq_f16`, any `*_f16` arithmetic | Armv8.2 FP16 | conversion only on A53 |
| `vbfdotq_f32`, `vbfmmlaq_f32`, `vcvt_bf16_f32`, `bfloat16x8_t` | BF16 | not on A53 |
| `vqrdmlahq_s16`, `vqrdmlshq_s16` | Armv8.1 RDM | use `vqrdmulhq_s16` + `vqaddq_s16` |
| `vcaddq_*`, `vcmlaq_*` | Armv8.3 complex | not on A53 |
| `vrnd32xq_f32`, `vrnd64*` | Armv8.5 | use `vrndnq_f32` (8.0) |
| `vaeseq_u8`, `vsha256hq_u32`, `vmull_p64` | Crypto | HW has it, but needs `-mcpu=cortex-a53+crypto` and a runtime check of `/proc/cpuinfo` `aes`/`sha2`; only if AES/SHA are needed |
| SVE `<arm_sve.h>` | SVE | not on A53 |

Compile-time guard (put in a project header that every NEON file includes):
```cpp
#if !defined(__ARM_NEON) || !defined(__aarch64__)
#error "TX8 NEON code requires AArch64 NEON"
#endif
#if defined(__ARM_FEATURE_DOTPROD) || defined(__ARM_FEATURE_MATMUL_INT8) || \
    defined(__ARM_FEATURE_FP16_VECTOR_ARITHMETIC) || defined(__ARM_FEATURE_BF16) || \
    defined(__ARM_FEATURE_SVE)
#error "Built for a newer Arm CPU than Cortex-A53; use -mcpu=cortex-a53"
#endif
```

## 3. Tail handling

Choose one per kernel and test n = 0, 1, width-1, width, width+1:
1. **Scalar tail** (default): vector loop `for (; i + W <= n; i += W)`, then scalar loop. Simple,
   always correct.
2. **Overlapping last vector**: if n >= W and the operation is idempotent per element (pure
   map from input to a *different* output buffer), process `[n-W, n)` once more. Do not use for
   in-place or accumulate operations.
3. **Padded buffers**: allocate rounded up to a multiple of W (and 64 B), zero the pad, document
   it in the buffer type. Best for internal buffers you own; never read past the end of buffers
   you do not own (e.g. MX3 output or TurboJPEG buffers) unless their size is guaranteed.

## 4. Worked example: u8 RGB (HWC) -> float32 normalized NHWC

Typical MX3 input: float32 NHWC, `out = (x / 255 - mean[c]) / std[c]` or just `x / 255`
(the exact normalization comes from the model: check the `_pre.onnx` produced by `mx_nc
--autocrop` or the training config, see skill `mx3-model-compile`). Fold it into one FMA per
element: `out = x * scale[c] + bias[c]` with `scale = 1/(255*std)`, `bias = -mean/std`.
Output stays interleaved (NHWC), so we deinterleave with `vld3q_u8` and re-interleave with
`vst3q_f32`; the buffer passed to the MX3 `FeatureMap` (see skill `mx3-runtime-integration`)
must match the model's input shape exactly.

```cpp
#include <arm_neon.h>
#include <cstddef>
#include <cstdint>

struct Norm3 { float scale[3]; float bias[3]; };   // out = x*scale + bias

inline Norm3 make_norm(const float mean[3], const float stdv[3]) {
  Norm3 n{};
  for (int c = 0; c < 3; ++c) { n.scale[c] = 1.0f / (255.0f * stdv[c]); n.bias[c] = -mean[c] / stdv[c]; }
  return n;
}

// Scalar reference (plain a*b+c; GCC may or may not contract it to FMA depending on
// -ffp-contract), so compare against the NEON version with a tolerance, not ==.
void rgb_u8_to_f32_ref(const uint8_t* src, float* dst, size_t npix, const Norm3& nm) {
  for (size_t i = 0; i < npix; ++i)
    for (int c = 0; c < 3; ++c)
      dst[3 * i + c] = static_cast<float>(src[3 * i + c]) * nm.scale[c] + nm.bias[c];
}

void rgb_u8_to_f32_neon(const uint8_t* __restrict__ src, float* __restrict__ dst,
                        size_t npix, const Norm3& nm) {
  const float32x4_t s0 = vdupq_n_f32(nm.scale[0]), b0 = vdupq_n_f32(nm.bias[0]);
  const float32x4_t s1 = vdupq_n_f32(nm.scale[1]), b1 = vdupq_n_f32(nm.bias[1]);
  const float32x4_t s2 = vdupq_n_f32(nm.scale[2]), b2 = vdupq_n_f32(nm.bias[2]);
  size_t i = 0;
  for (; i + 16 <= npix; i += 16) {
    const uint8x16x3_t px = vld3q_u8(src + 3 * i);       // R, G, B planes of 16 pixels
    float32x4_t f[3][4];
    for (int c = 0; c < 3; ++c) {                        // fully unrolled by GCC (constant trip)
      const uint16x8_t lo = vmovl_u8(vget_low_u8(px.val[c]));
      const uint16x8_t hi = vmovl_high_u8(px.val[c]);
      f[c][0] = vcvtq_f32_u32(vmovl_u16(vget_low_u16(lo)));
      f[c][1] = vcvtq_f32_u32(vmovl_high_u16(lo));
      f[c][2] = vcvtq_f32_u32(vmovl_u16(vget_low_u16(hi)));
      f[c][3] = vcvtq_f32_u32(vmovl_high_u16(hi));
    }
    for (int k = 0; k < 4; ++k) {
      float32x4x3_t o;
      o.val[0] = vfmaq_f32(b0, f[0][k], s0);
      o.val[1] = vfmaq_f32(b1, f[1][k], s1);
      o.val[2] = vfmaq_f32(b2, f[2][k], s2);
      vst3q_f32(dst + 3 * (i + 4 * k), o);               // 4 pixels x 3 channels
    }
  }
  for (; i < npix; ++i)                                   // scalar tail
    for (int c = 0; c < 3; ++c)
      dst[3 * i + c] = static_cast<float>(src[3 * i + c]) * nm.scale[c] + nm.bias[c];
}
```

Test: max abs difference vs reference <= 1e-6 * max(1, |ref|) (FMA single rounding vs two
roundings). Sizes 640x640 (409600 px), 1, 15, 16, 17.

Alternative to measure: a 3 x 256-entry float LUT (3 KB, fits L1) with a scalar loop. Output is
4x larger than input (4.9 MB float), so this pass is store-bound: **fuse** it with decode
(convert each decoded strip while hot), see `memory-and-cache.md` and skill `tx8-vision-pipeline`.

## 5. Worked example: color conversions

Prefer letting TurboJPEG decode straight to RGB (`TJPF_RGB`): its color conversion is already
NEON-optimized. Write your own only for raw UVC formats or fused pipelines.

### YUV 4:4:4 planar (full-range BT.601 / JFIF) -> RGB u8, fixed point Q6
Coefficients x64: 1.402 -> 90, 0.344 -> 22, 0.714 -> 46, 1.772 -> 113 (error < 1 LSB; use
Q14 with `vmull_s16` if you need bit-exact libjpeg results). All intermediates fit int16.

```cpp
static inline uint8_t clamp_u8(int v) { return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v)); }

void yuv444_to_rgb_ref(const uint8_t* Y, const uint8_t* U, const uint8_t* V, uint8_t* rgb, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    const int y = Y[i], du = U[i] - 128, dv = V[i] - 128;
    // >> of a negative int is arithmetic on GCC/AArch64 (implementation-defined in C++17)
    rgb[3 * i + 0] = clamp_u8(y + ((90 * dv + 32) >> 6));
    rgb[3 * i + 1] = clamp_u8(y - ((22 * du + 46 * dv + 32) >> 6));
    rgb[3 * i + 2] = clamp_u8(y + ((113 * du + 32) >> 6));
  }
}

void yuv444_to_rgb_neon(const uint8_t* __restrict__ Y, const uint8_t* __restrict__ U,
                        const uint8_t* __restrict__ V, uint8_t* __restrict__ rgb, size_t n) {
  const int16x8_t k128 = vdupq_n_s16(128);
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    const int16x8_t y  = vreinterpretq_s16_u16(vmovl_u8(vld1_u8(Y + i)));
    const int16x8_t du = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vld1_u8(U + i))), k128);
    const int16x8_t dv = vsubq_s16(vreinterpretq_s16_u16(vmovl_u8(vld1_u8(V + i))), k128);
    const int16x8_t r = vaddq_s16(y, vrshrq_n_s16(vmulq_n_s16(dv, 90), 6));
    const int16x8_t g = vsubq_s16(y, vrshrq_n_s16(vmlaq_n_s16(vmulq_n_s16(du, 22), dv, 46), 6));
    const int16x8_t b = vaddq_s16(y, vrshrq_n_s16(vmulq_n_s16(du, 113), 6));
    uint8x8x3_t o;
    o.val[0] = vqmovun_s16(r);   // saturate to 0..255
    o.val[1] = vqmovun_s16(g);
    o.val[2] = vqmovun_s16(b);
    vst3_u8(rgb + 3 * i, o);
  }
  yuv444_to_rgb_ref(Y + i, U + i, V + i, rgb + 3 * i, n - i);   // tail
}
```
`vrshrq_n_s16(x, 6)` computes `(x + 32) >> 6` (arithmetic), identical to the reference, so the
NEON and scalar outputs must match **bit-exactly**. For 4:2:0 / 4:2:2, load 4 chroma bytes per 8
luma pixels and duplicate with `vzip1_u8(c, c)`; for YUYV use `vld2q_u8` (Y = even bytes) then
`vuzp` on the odd bytes for U/V.

### RGB u8 -> luma (Y) u8, Q8 (77 + 150 + 29 = 256)
```cpp
void rgb_to_y_neon(const uint8_t* __restrict__ rgb, uint8_t* __restrict__ y, size_t n) {
  size_t i = 0;
  for (; i + 8 <= n; i += 8) {
    const uint8x8x3_t p = vld3_u8(rgb + 3 * i);
    uint16x8_t acc = vmull_u8(p.val[0], vdup_n_u8(77));
    acc = vmlal_u8(acc, p.val[1], vdup_n_u8(150));   // 150 fits in u8
    acc = vmlal_u8(acc, p.val[2], vdup_n_u8(29));    // max 256*255 = 65280 fits u16
    vst1_u8(y + i, vrshrn_n_u16(acc, 8));            // (acc + 128) >> 8
  }
  for (; i < n; ++i)
    y[i] = static_cast<uint8_t>((77 * rgb[3 * i] + 150 * rgb[3 * i + 1] + 29 * rgb[3 * i + 2] + 128) >> 8);
}
```

## 6. Worked example: score threshold + compaction (branchless)

Host post-processing is threshold + top-K only (box decode stays in the model). Scores are a
float array per anchor (or a per-anchor max over 1-3 class planes: `vmaxq_f32` across planes
first). Check the real output layout of your DFP (`[N][4+C]` vs `[C][N]`) before writing this.

```cpp
#include <arm_neon.h>
#include <cstddef>
#include <cstdint>

// Reference: out must have capacity >= n. NaN scores never pass (comparison is false).
size_t threshold_compact_ref(const float* s, size_t n, float t, uint32_t* out) {
  size_t k = 0;
  for (size_t i = 0; i < n; ++i) { out[k] = static_cast<uint32_t>(i); k += (s[i] > t); }
  return k;
}

// Variant A: sparse hits (typical: a few dozen of 8400 anchors). 16 scores per step; the
// "any hit?" branch is almost always not-taken, so it predicts well.
size_t threshold_compact_neon(const float* __restrict__ s, size_t n, float t,
                              uint32_t* __restrict__ out) {
  const float32x4_t vt = vdupq_n_f32(t);
  size_t k = 0, i = 0;
  for (; i + 16 <= n; i += 16) {
    const uint32x4_t m0 = vcgtq_f32(vld1q_f32(s + i), vt);
    const uint32x4_t m1 = vcgtq_f32(vld1q_f32(s + i + 4), vt);
    const uint32x4_t m2 = vcgtq_f32(vld1q_f32(s + i + 8), vt);
    const uint32x4_t m3 = vcgtq_f32(vld1q_f32(s + i + 12), vt);
    const uint32x4_t any = vorrq_u32(vorrq_u32(m0, m1), vorrq_u32(m2, m3));
    if (vmaxvq_u32(any) == 0) continue;               // common case: no hit in 16
    for (size_t j = i; j < i + 16; ++j) {             // rare: branchless scalar compaction
      out[k] = static_cast<uint32_t>(j);
      k += (s[j] > t);
    }
  }
  for (; i < n; ++i) { out[k] = static_cast<uint32_t>(i); k += (s[i] > t); }
  return k;
}
```

Variant B (dense hits, e.g. low thresholds during tuning): fully vectorized left-packing with a
16-entry shuffle table. Needs `out` capacity >= n + 3 (it always stores 4 lanes).

```cpp
struct CompactLut { uint8_t t[16][16]; };
constexpr CompactLut make_compact_lut() {
  CompactLut l{};
  for (int m = 0; m < 16; ++m) {
    int k = 0;
    for (int lane = 0; lane < 4; ++lane)
      if (m & (1 << lane)) {
        for (int b = 0; b < 4; ++b) l.t[m][4 * k + b] = static_cast<uint8_t>(4 * lane + b);
        ++k;
      }
    for (; k < 4; ++k)
      for (int b = 0; b < 4; ++b) l.t[m][4 * k + b] = 0xFF;   // index >= 16 -> byte 0
  }
  return l;
}
alignas(64) static constexpr CompactLut kCompactLut = make_compact_lut();

size_t threshold_compact_dense(const float* __restrict__ s, size_t n, float t,
                               uint32_t* __restrict__ out /* capacity >= n + 3 */) {
  static const uint32_t kBitsArr[4] = {1, 2, 4, 8};
  static const uint32_t kIotaArr[4] = {0, 1, 2, 3};
  const uint32x4_t kBits = vld1q_u32(kBitsArr);
  const uint32x4_t kIota = vld1q_u32(kIotaArr);
  const float32x4_t vt = vdupq_n_f32(t);
  size_t k = 0, i = 0;
  for (; i + 4 <= n; i += 4) {
    const uint32x4_t m = vcgtq_f32(vld1q_f32(s + i), vt);
    const uint32_t bits = vaddvq_u32(vandq_u32(m, kBits));          // 0..15
    const uint32x4_t idx = vaddq_u32(vdupq_n_u32(static_cast<uint32_t>(i)), kIota);
    const uint8x16_t shuf = vld1q_u8(kCompactLut.t[bits]);
    const uint32x4_t packed = vreinterpretq_u32_u8(vqtbl1q_u8(vreinterpretq_u8_u32(idx), shuf));
    vst1q_u32(out + k, packed);
    k += static_cast<size_t>(__builtin_popcount(bits));
  }
  for (; i < n; ++i) { out[k] = static_cast<uint32_t>(i); k += (s[i] > t); }
  return k;
}
```
Variant B has a GPR<->NEON round trip per 4 scores (`bits`), so it is slower than A when hits
are rare. Benchmark both with realistic score distributions (`scripts/bench_template.cpp` does
A vs scalar).

## 7. Top-K partial selection

After compaction the candidate count m is small (tens to a few hundred), so no SIMD is needed.
Use `std::partial_sort` (or `std::nth_element` + sort of the first K) on a pre-allocated scratch
array; both are in-place and do not allocate. Make the order deterministic (ties by index).

```cpp
#include <algorithm>

struct Cand { float score; uint32_t idx; };

// idx: compacted indices (m entries). scratch capacity >= m. Returns k = min(K, m) best,
// sorted by score descending, ties by lower index.
size_t top_k(const float* scores, const uint32_t* idx, size_t m, size_t K, Cand* scratch) {
  for (size_t j = 0; j < m; ++j) scratch[j] = Cand{scores[idx[j]], idx[j]};
  const auto better = [](const Cand& a, const Cand& b) {
    return a.score > b.score || (a.score == b.score && a.idx < b.idx);
  };
  const size_t k = std::min(K, m);
  std::partial_sort(scratch, scratch + k, scratch + m, better);
  return k;
}
```
Strategy notes:
- Cap m: if m exceeds a sanity bound (e.g. 10x K), the threshold is wrong or the model output is
  garbage; report it instead of silently sorting thousands of entries.
- For NMS-free heads (YOLOv10/YOLO26 one-to-one) the model already emits a fixed top set (e.g.
  300 rows); then only threshold + copy is needed.
- K <= 16 and m large: a small insertion-sorted array is faster than `partial_sort`; measure.

## 8. Testing pattern for every kernel

```cpp
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

bool test_rgb_norm(size_t npix) {
  std::mt19937 rng(1234);
  std::vector<uint8_t> src(npix * 3);
  for (auto& b : src) b = static_cast<uint8_t>(rng() & 0xFF);
  std::vector<float> a(npix * 3), b(npix * 3);
  const float mean[3] = {0.485f, 0.456f, 0.406f}, stdv[3] = {0.229f, 0.224f, 0.225f};
  const Norm3 nm = make_norm(mean, stdv);
  rgb_u8_to_f32_ref(src.data(), a.data(), npix, nm);
  rgb_u8_to_f32_neon(src.data(), b.data(), npix, nm);
  for (size_t i = 0; i < a.size(); ++i)
    if (std::fabs(a[i] - b[i]) > 1e-5f * std::fmax(1.0f, std::fabs(a[i]))) {
      std::printf("mismatch at %zu: %g vs %g\n", i, a[i], b[i]);
      return false;
    }
  return true;
}
// Call for npix in {0, 1, 15, 16, 17, 640*640}. mean/std above are test data only.
```
Sources: Arm docs 102467 (RGB deinterleave with `vld3q_u8`) and 102159; links in `sources.md`.
