# Compiler flags, auto-vectorization and build variants (GCC 11, TX8)

Toolchain on the board: Ubuntu 22.04 GCC 11 + glibc 2.35. Default build is native on the board
(`ssh umpi`); optional cross build in WSL2 Ubuntu 22.04 with `aarch64-linux-gnu-g++` (GCC 11).
Do not target the board with a newer Arm GNU Toolchain unless sysroot/glibc match (see skill
`tx8-platform`).

## 1. Project flags (from DESIGN 3.3)

| Flag | Where | Why |
|---|---|---|
| `-std=c++17` | all | project language level |
| `-O2` | all | good default; `-O3` only where measured to help |
| `-mcpu=cortex-a53` | all | selects Armv8-A + CRC and the A53 scheduling/tuning model. Do not use `-march=native` on a dev PC; on the board it would also work but hides the intent |
| `-mno-outline-atomics` | all | see section 7 |
| `-Wall -Wextra -Werror` | all | warnings are bugs; fix, do not silence globally |
| `-O3 -fopt-info-vec-missed` | hot files only | more aggressive vectorization/unrolling + report of loops that failed to vectorize |
| `+crypto` (`-mcpu=cortex-a53+crypto`) | only files that use AES/SHA intrinsics | GCC 11 `-mcpu=cortex-a53` does not enable it; also check `/proc/cpuinfo` Features for `aes sha1 sha2 pmull` at runtime |
| `-mfix-cortex-a53-835769`, `-mfix-cortex-a53-843419` | all, if needed | see section 8 |

CMake sketch (per-file hot flags):
```cmake
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
add_compile_options(-mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
set(CMAKE_CXX_FLAGS_RELEASE "-O2")      # override CMake's default -O3 -DNDEBUG if desired
set_source_files_properties(src/preproc_neon.cpp src/postproc.cpp
  PROPERTIES COMPILE_OPTIONS "-O3;-fopt-info-vec-missed")
```
Keep `-DNDEBUG` decisions explicit: asserts that guard invariants in non-hot code are cheap and
improve reliability; consider keeping them.

Verify what the compiler actually enables:
```bash
g++ -mcpu=cortex-a53 -E -dM - </dev/null | grep -E '__ARM_(NEON|FEATURE_(CRC32|CRYPTO|AES|SHA2|DOTPROD|ATOMICS|FP16))'
g++ -Q --help=target -mcpu=cortex-a53 | grep -E 'outline-atomics|fix-cortex'
```
Expected: `__ARM_NEON` and `__ARM_FEATURE_CRC32` present; no DOTPROD/ATOMICS/FP16.

## 2. Reading vectorization reports

```bash
g++ -std=c++17 -O3 -mcpu=cortex-a53 -fopt-info-vec-missed=vec-missed.txt -c kernel.cpp
g++ -std=c++17 -O3 -mcpu=cortex-a53 -fopt-info-vec-optimized -c kernel.cpp   # what did vectorize
```
`-fopt-info-vec-missed` is very noisy (it reports every loop, including cold ones). Grep for your
file and line: `grep 'kernel.cpp:42' vec-missed.txt`. Common messages and fixes:

| Message (paraphrased) | Cause | Fix |
|---|---|---|
| "possible alias" / "versioning for alias required" | pointers may overlap | `__restrict__` on parameters; GCC may version the loop at runtime otherwise |
| "reduction ... not supported" for float `+=` | FP reassociation not allowed | use explicit NEON accumulators, or per-file `-fassociative-math -fno-signed-zeros -fno-trapping-math` (document why) |
| "control flow in loop" | `if` inside loop | rewrite as `x = cond ? a : b` (if-conversion), or masks |
| "number of iterations cannot be computed" | `while` with complex exit, iterator types | counted `for (size_t i = 0; i < n; ++i)` |
| "not vectorized: complicated access pattern" | strided/gather access, AoS | change layout to SoA, or use `vld3q`/`vld2q` intrinsics |
| "function call" | call to non-inlined function | make it `inline`/`static` in the same TU, or LTO |

Then confirm in assembly: `objdump -d --no-show-raw-insn kernel.o | less` and look for `v`
registers in the loop body (`fmla v0.4s`, `ld1`, `ldr q`).

## 3. `__restrict__`, alignment, loop tails

- `__restrict__` (GCC spelling in C++) promises that the pointed-to memory is not accessed through
  another pointer in that scope. Violating it is undefined behavior; only use it when the API
  contract guarantees non-overlap (e.g. `src` and `dst` frames from a pool).
- Alignment hint: `const float* a = static_cast<const float*>(__builtin_assume_aligned(p, 64));`
  removes alignment peeling. Only if the allocation guarantees it (pool with `aligned_alloc(64,
  ...)`); a wrong hint is undefined behavior. NEON loads do not fault on misalignment, so the gain
  is small; use it mainly to simplify generated code.
- Loop tails: GCC generates an epilogue for the remainder. If the buffer length is always a
  multiple of 16 (e.g. 640 * 3 = 1920), tell the compiler: `n &= ~size_t(15);` before the loop
  or iterate in blocks of 16; handle the true remainder explicitly.
- `#pragma GCC ivdep` asserts no loop-carried dependencies; `#pragma GCC unroll N` controls
  unrolling. Use sparingly and measure.

## 4. Floating point flags: why not `-ffast-math` globally

`-ffast-math` turns on `-ffinite-math-only`, `-fno-signed-zeros`, `-fassociative-math`,
`-freciprocal-math`, `-fno-math-errno`, `-fno-trapping-math` and more. Risks for this project:
- `-ffinite-math-only` lets GCC assume no NaN/Inf: `std::isnan(score)` may be folded to false,
  and comparisons used to reject garbage scores from a faulty inference can silently change.
  Reliability first: we need NaN detection on MX3 outputs.
- Reassociation changes results run to run between builds, which breaks golden-output tests.
- It also links `crtfastmath.o` on some targets, changing FP state (flush-to-zero) for the whole
  process, including libraries.

Allowed: per-file, documented, with tests: e.g. `-fno-math-errno` (lets `sqrtf` inline) or the
reassociation trio on one reduction file. Prefer explicit NEON code over flags.

FMA contraction: GCC's `-ffp-contract` default differs between ISO (`-std=c++17`) and GNU modes
and between versions; scalar `a*b+c` may or may not become `fmadd`. Never compare SIMD vs scalar
results with `==` for float kernels; use a tolerance, or set `-ffp-contract=off` on the reference
file when you need bit-exactness of the reference itself.

## 5. LTO

`-flto=auto` (compile and link) enables cross-TU inlining (useful when small helpers live in
other files). Costs: longer builds, more memory at link (watch the 2 GB EVT board when building
natively), new warnings appear at link time (with `-Werror` they fail the build), and debugging
is harder. Use for release builds only after measuring a gain. Keep `-mcpu=cortex-a53` and other
codegen flags on the link line too, since LTO code generation happens at link time.

## 6. PGO (optional, measured on the board)

```bash
# 1. instrumented build (on the board)
g++ -std=c++17 -O2 -mcpu=cortex-a53 -mno-outline-atomics -fprofile-generate -fprofile-update=atomic ... -o app
# 2. run a representative workload (real camera stream / recorded MJPEG, >= 1 minute)
./app --replay test.mjpeg
# 3. optimized build using the *.gcda files
g++ -std=c++17 -O2 -mcpu=cortex-a53 -mno-outline-atomics -fprofile-use -fprofile-correction ... -o app
```
Notes: `-fprofile-update=atomic` for multi-threaded programs (instrumentation is slower with it).
Profile data must match the sources; stale profiles produce warnings that `-Werror` turns into
errors (`-Wno-error=coverage-mismatch` / `-Wno-error=missing-profile` only for PGO builds).
Expected gains are mostly branch layout and inlining; NEON kernels gain little. Only adopt if
before/after timing shows a gain beyond noise.

## 7. `-mno-outline-atomics`

Since GCC 10, AArch64 GCC can compile atomics as calls to libgcc helpers (`__aarch64_cas4_acq`,
`__aarch64_ldadd4_relax`, ...) that check at run time whether the CPU has LSE atomics and use
them if present, else LL/SC (`ldaxr`/`stlxr`) loops. Ubuntu enables this by default. The TX8's
A53 never has LSE, so the helpers add a function call plus a feature check to every atomic
operation, and they hide the atomics from the A53 instruction scheduler. With
`-mno-outline-atomics` GCC inlines the LL/SC loop directly. Check with
`objdump -d app | grep -c __aarch64_` (should be 0 for our code; system libraries may still
contain them, that is fine).

## 8. Cortex-A53 erratum flags: decision procedure

Two documented A53 errata have compiler/linker workarounds:
- 835769: a 64-bit multiply-accumulate following a load/store can produce a wrong result.
  `-mfix-cortex-a53-835769` inserts a `nop` where the sequence could occur.
- 843419: `adrp`-based address computation at certain page offsets can produce a wrong address.
  `-mfix-cortex-a53-843419` makes GCC pass `--fix-cortex-a53-843419` to the linker, which
  patches affected sequences.

Procedure (do not guess the revision):
1. On the board: `grep -E 'CPU (implementer|part|variant|revision)' /proc/cpuinfo | sort -u`.
   Expect implementer 0x41, part 0xd03 (Cortex-A53). Revision = r(variant)p(revision).
2. Check the Arm Cortex-A53 Software Developer Errata Notice (SDEN) on developer.arm.com for
   which revisions are affected by 835769 and 843419.
3. Check whether the distro compiler already enables them by default:
   `gcc -v 2>&1 | tr ' ' '\n' | grep -i fix-cortex` and `g++ -Q --help=target | grep fix-cortex`.
4. If affected **or unknown**: enable both flags for all code (cost is tiny: occasional `nop`
   and linker veneers). If not affected and confirmed: leave them off. Record the decision and
   evidence in the build docs.
5. The kernel has its own handling (`dmesg | grep -i errat` shows enabled workarounds); this is
   independent of user-space flags.

## 9. Why GCC and not clang for this core

GCC's `-mcpu=cortex-a53` uses a dedicated A53 pipeline description. LLVM's A53 scheduling model is
known to be inaccurate (e.g. it treats 128-bit loads as single-cycle and does not model the
D-register dual-issue cases), and community benchmarks show clang/Rust NEON loops running far
from the core's limits. Therefore: production build with GCC 11; do not use `llvm-mca` timelines
to reason about A53 performance; use clang only for clang-format/clang-tidy. If someone proposes
clang, require a measured comparison on the TX8.

## 10. Sanitizer and debug builds (tests only, never release)

```bash
# ASan + UBSan
g++ -std=c++17 -O1 -g -fno-omit-frame-pointer -mcpu=cortex-a53 \
    -fsanitize=address,undefined -fno-sanitize-recover=undefined test.cpp -o test_asan
# TSan for threading code (separate build; cannot combine with ASan)
g++ -std=c++17 -O1 -g -mcpu=cortex-a53 -fsanitize=thread test.cpp -o test_tsan -pthread
```
- ASan needs extra memory (roughly 2-3x); on the 2 GB EVT board run reduced workloads.
- TSan on AArch64 depends on the kernel's virtual address size; if it aborts with a VMA error,
  run TSan builds in WSL2/x86 with the same code (portable parts) and note it.
- UBSan catches misaligned scalar access through cast pointers, signed overflow and shifts:
  common bugs in pixel code.
- `-D_GLIBCXX_ASSERTIONS` in debug/test builds checks `std::vector` bounds cheaply.
- For profiling builds add `-g -fno-omit-frame-pointer` (keeps `perf record -g` call stacks
  usable); the cost is usually small, measure if hot.

## 11. Inspecting generated code

```bash
g++ -std=c++17 -O2 -mcpu=cortex-a53 -S -fverbose-asm -o - kernel.cpp | less
objdump -d --no-show-raw-insn -C build/kernel.o | less
perf annotate --stdio -s kernel_symbol      # hot instructions with sample counts
```
Look for: unexpected function calls in loops (`bl`), `__aarch64_*` helpers, scalar FP inside
a supposedly vector loop, `sdiv`/`udiv`, and long chains of dependent `fmla` on one register.
