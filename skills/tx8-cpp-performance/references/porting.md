# Porting x86 SIMD (SSE/AVX) code to the TX8

Typical sources of x86 SIMD code in this project: third-party pre/post-processing snippets,
prototype code written on the Windows/WSL dev machine, older vision libraries. The TX8 is
Armv8.0 AArch64 with 128-bit NEON only.

## 1. Strategy

1. **Find it**: `grep -rnE '#include <(x86intrin|immintrin|emmintrin|xmmintrin|pmmintrin|tmmintrin|smmintrin|nmmintrin)\.h>|__m128|__m256|_mm_|_mm256_' src/`.
2. **Is it hot on the TX8?** Profile first (`profiling.md`). Cold code: replace with plain scalar
   C++ (GCC may auto-vectorize it) - simplest and most portable.
3. **Hot, SSE-only**: use a translation header to get it building, then measure:
   - sse2neon (MIT): single header mapping SSE..SSE4.2 intrinsics to NEON.
   - SIMDe (MIT): portable implementations of SSE/AVX/AVX2/AVX-512 and more; AVX code is
     emulated with two 128-bit NEON halves.
4. **Hot and still slow** after translation: rewrite the kernel natively with NEON intrinsics
   (`neon-intrinsics.md`), keeping the original scalar semantics as the reference.
5. Keep the x86 path only if it is still built for the dev machine (tests/simulation) and guard
   with `#if defined(__x86_64__) ... #elif defined(__aarch64__) ... #else scalar #endif`.

Both libraries are header-only; vendoring them into `third_party/` with their license file is a
dependency decision: tell the user (license MIT, version pinned) before adding.

```cpp
#if defined(__aarch64__)
#  include "sse2neon.h"        // vendored, version pinned
#else
#  include <emmintrin.h>
#endif
```
Build on the board with the project flags (`-O2 -mcpu=cortex-a53 ...`); do not add `-msse*`.

## 2. Pitfalls (semantic differences you must test)

| Area | x86 behavior | NEON/AArch64 behavior | What to do |
|---|---|---|---|
| Byte shuffle `_mm_shuffle_epi8` | index byte with high bit set -> 0; otherwise uses low 4 bits | `vqtbl1q_u8`: any index >= 16 -> 0 | indices 0x10..0x7F differ; translation headers mask, native code must mask explicitly (`vandq_u8(idx, 0x8F)`) |
| `_mm_movemask_epi8` / `_mm_movemask_ps` | 1 instruction | no direct equivalent; emulated with several ops | redesign: use `vmaxvq_u32(mask)` for "any", `vshrn_n_u16` nibble mask, or keep data in masks |
| `_mm_cvtps_epi32` | rounds with current MXCSR mode (default nearest-even); out of range -> 0x80000000 | `vcvtnq_s32_f32` nearest-even, **saturates** | test out-of-range and NaN inputs |
| `_mm_cvttps_epi32` | truncate | `vcvtq_s32_f32` truncate, saturates; NaN -> 0 | same |
| `_mm_min_ps` / `_mm_max_ps` with NaN | returns 2nd operand | `vminq_f32` returns NaN; `vminnmq_f32` returns the number | pick explicitly, test NaN |
| Reciprocal `_mm_rcp_ps` / `_mm_rsqrt_ps` | ~12-bit estimate | `vrecpeq_f32` ~8-bit estimate | add Newton steps (`vrecpsq_f32`) or use exact division |
| Denormals | code may set FTZ/DAZ via `_MM_SET_FLUSH_ZERO_MODE` | FPCR.FZ controls flush-to-zero; translation headers may not reproduce MXCSR calls | check results for tiny values; avoid relying on FTZ |
| Horizontal ops `_mm_hadd_ps` | 1 instruction (slow on x86 too) | `vpaddq_f32` / `vaddvq_f32` | fine |
| 256-bit AVX | native | two NEON ops per AVX op (SIMDe) | expect ~2x instruction count; rewrite hot kernels |
| `_mm_load_ps` alignment | faults if not 16 B aligned | NEON never faults on misalignment | do not rely on faults for detection |
| `_mm_stream_ps` (non-temporal) | bypasses cache | mapped to normal stores (or `stnp`) | no guaranteed benefit; measure |
| `_mm_prefetch` hints | T0/T1/T2/NTA | `prfm pldl1keep/pldl2keep/...` | re-tune the distance on the A53 |
| `_mm_pause` / `_mm_sfence` / `_mm_mfence` | x86 ordering helpers | `yield` / `dmb` | do not port fences 1:1; fix the synchronization with `std::atomic` (`memory-model.md`) |

Non-SIMD x86 assumptions that also break:
- **Memory ordering**: x86 TSO hides missing acquire/release. Any lock-free code must be reviewed
  (`memory-model.md`); run TSan tests.
- **`char` is unsigned on AArch64 Linux** (signed on x86). Code like `char c = buf[i]; if (c < 0)`
  silently changes behavior. Use `int8_t`/`uint8_t` explicitly; `-Wtype-limits`/`-Wsign-compare`
  catch some cases.
- Unaligned scalar access through casted pointers (`*(uint32_t*)(p + 1)`) works on AArch64 for
  normal memory but is undefined behavior in C++; use `std::memcpy` (compiles to a single load).
- `long double` is 128-bit IEEE quad on AArch64 Linux (software-emulated, very slow), 80-bit on
  x86. Never use it in hot paths.
- x86-specific `__builtin_ia32_*`, `rdtsc`, `cpuid`: replace with `clock_gettime` and
  `getauxval(AT_HWCAP)` (`HWCAP_ASIMD`, `HWCAP_AES`, ...) from `<sys/auxv.h>`.

## 3. Verifying a port

1. Keep (or write) a scalar reference function that encodes the intended semantics.
2. Unit tests with random inputs, edge values (0, 255, -0.0f, NaN, +/-Inf, max int, denormals),
   and all tail lengths (0, 1, W-1, W, W+1).
3. Compare: integer kernels bit-exact; float kernels with a documented tolerance (FMA vs separate
   multiply/add, different reduction order, reciprocal estimates).
4. If the x86 build is still available in WSL2, record golden outputs there and compare the TX8
   output to them (same inputs, same tolerance rules).
5. Run ASan/UBSan builds on the board.
6. Benchmark translated vs native vs scalar on the TX8 (`scripts/bench_template.hpp`); keep the
   simplest version that meets the target.

## 4. Libraries instead of porting

- JPEG decode / color conversion: libjpeg-turbo (has NEON paths for AArch64).
- Resize/color/filters: KleidiCV (Apache-2.0) has a NEON backend built for armv8-a but is **not
  officially tested on A53**: verify correctness and speed before adopting.
- OpenCV: debug/prototype only, not in production pre/post paths (project rule).

## Sources
- learn.arm.com "Porting architecture specific intrinsics" (sse2neon, SIMDe).
- sse2neon: https://github.com/DLTcollab/sse2neon ; SIMDe: https://github.com/simd-everywhere/simde
