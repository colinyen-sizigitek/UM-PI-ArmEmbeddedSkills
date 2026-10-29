# Arm resources and tools NOT to use or recommend for the TX8

Many Arm learning resources target microcontrollers, Neoverse servers or newer cores. Recommending
them wastes engineering time or produces code that cannot run on the Cortex-A53. If a user or
another document suggests one of these, explain the reason below and point to the alternative.

## 1. Excluded list (one-line reasons)

| Excluded item | Why it does not apply to the TX8 | Use instead |
|---|---|---|
| CMSIS (Core, RTOS) | Cortex-M/R microcontroller framework; TX8 runs Linux on Cortex-A53 | Linux/POSIX APIs, C++17 |
| CMSIS-DSP | Optimized for Cortex-M (Helium/DSP ext.); not a tuned A53 Linux library | own NEON kernels (`neon-intrinsics.md`) |
| CMSIS-NN | Cortex-M neural-network kernels; inference runs on the MX3 | MemryX runtime (skill `um-pi-mx3-runtime-integration`) |
| Keil MDK / uVision | Microcontroller IDE/toolchain | GCC 11 on the board or WSL2 cross |
| Ethos-U NPU and the Vela compiler | Arm micro-NPU not present on the UM21A646 | MX3 + `mx_nc` (skill `um-pi-mx3-model-compile`) |
| Corstone reference systems / FVP models | Virtual platforms for other Arm subsystems; no TX8 model; not representative of A53 timing | real measurements on the board |
| Zephyr on MPS boards | RTOS on FPGA prototyping boards; TX8 runs Ubuntu | Ubuntu 22.04 on the TX8 |
| SVE / SVE2 / SME learning paths and intrinsics | The A53 has no SVE/SME (Armv8.0 only) | NEON (AdvSIMD) |
| KleidiAI | CPU ML micro-kernels needing dotprod/i8mm/SME; inference is on the MX3 anyway | MemryX runtime |
| Arm Compute Library (ACL) | Computer-vision functions were removed in v21.05; remaining ML operators are irrelevant (MX3 does inference) | libjpeg-turbo, own NEON, optionally KleidiCV after A53 verification |
| Arm Performance Libraries (ArmPL) | BLAS/LAPACK/FFT tuned for Neoverse/server cores, not for an in-order A53 pipeline | own kernels; scalar libm |
| topdown-tool | Topdown methodology for Neoverse PMUs; does not support A53 events | manual stall breakdown from 0xE0-0xE8 (`profiling.md`, `scripts/perf_a53.sh`) |
| Streamline CLI tools | Neoverse-only server profiling CLI | Streamline GUI (Performance Studio) + `gatord`, or `perf` |
| llvm-mca for Cortex-A53 | LLVM's A53 scheduling model is inaccurate (single-cycle 128-bit loads, no D-pairing) | micro-benchmarks + `perf` on the TX8; GCC `-mcpu=cortex-a53` |
| developer.arm.com/ai portal content (CPU inference guides) | About running ML inference on Arm CPUs; our inference is on the MX3 | MemryX SDK docs |
| dotprod / i8mm / fp16-arith / bf16 / RDM intrinsics | Not implemented on the A53 (illegal instruction) | `neon-intrinsics.md` section 2 |

## 2. Also not applicable

- `-march=armv8.2-a` or newer, `-mcpu=cortex-a55/a76/neoverse-*`: generates instructions the
  A53 cannot execute (or tunes for the wrong pipeline).
- Arm GNU Toolchain 15.x targeting the board without a matching sysroot/glibc 2.35 (ABI/glibc
  mismatch); use Ubuntu 22.04 GCC 11 (see skill `um-pi-platform`).
- OpenCV in production pre/post paths (project rule; prototypes only).
- Arm SPE (Statistical Profiling Extension) based tooling, including `perf c2c` workflows that
  rely on SPE: SPE is an Armv8.2 feature, not present on the A53.
- Guides that assume LSE atomics (`ldadd`, `cas`, `swp`) or `LDAPR`: the A53 uses LL/SC loops
  and `LDAR` (`memory-model.md`).
- 64 KB page-size kernel learning paths: changing the kernel page size is a BSP decision, not an
  application optimization; out of scope (and needs approval).

## 3. Borderline items (allowed only with conditions)

| Item | Condition |
|---|---|
| KleidiCV | Apache-2.0, NEON backend builds for armv8-a, but not officially tested on A53: run its tests on the board and benchmark against libjpeg-turbo / own kernels before adopting |
| Arm Cortex-A55 Software Optimization Guide | Use only as an upper-bound reference; the A55 dual-issues cases the A53 cannot (64-bit vector load with FMLA, etc.) |
| clang / clang-tidy / clang-format | Formatting and static analysis yes; production codegen no, unless a measured comparison on the TX8 shows a gain |
| sse2neon / SIMDe | Porting aid; measure and rewrite hot kernels natively (`porting.md`) |
| Streamline GUI + gatord | Allowed; copying/running `gatord` on the board needs user approval |
| Arm Performance Studio other tools (Mali GPU analyzers) | GPU is Vivante, not Mali; only Streamline's CPU features apply |

## 4. How to respond when one of these is suggested

1. Name the item and give the one-line reason from the table (A53 is Armv8.0, Linux, in-order;
   inference runs on the MX3).
2. Offer the alternative from the "Use instead" column.
3. If the person insists (e.g. a library claims Armv8-A support), require evidence measured on
   the TX8: correctness test against a scalar reference plus a before/after benchmark.
4. Never add a dependency silently; dependency and license decisions go to the user.

## 5. Quick self-check for any new Arm resource

Before recommending a new Arm article, library or tool, check:
- Does it target Cortex-A (application profile) running Linux? If it targets Cortex-M/R or
  bare-metal/RTOS, exclude.
- Does it require an architecture feature beyond Armv8.0-A + CRC32 (+crypto only if enabled)?
  Look for dotprod, i8mm, fp16, bf16, SVE, SME, LSE, RCpc, SPE, MTE, PAC/BTI. If yes, exclude or
  find the Armv8.0 fallback path.
- Is it tuned for Neoverse/server or big out-of-order cores? Then treat its performance claims as
  not transferable; measure on the TX8.
- Is it about CPU-side ML inference? Our inference runs on the MX3; only pre/post-processing
  runs on the A53.

## 6. Example replies

- "Use CMSIS-DSP for the normalization": CMSIS-DSP targets Cortex-M; on the A53 under Linux we
  write a NEON kernel with a scalar reference (`neon-intrinsics.md` section 4) and measure it.
- "Run topdown-tool to find the bottleneck": topdown-tool has no A53 support; run
  `scripts/perf_a53.sh` and read the 0xE0-0xE8 stall breakdown instead.
- "Use `vdotq_u32` for the u8 math": dotprod is Armv8.2 and traps on the A53; use
  `vmull_u8`/`vmlal_u8` widening multiplies.
- "Check the schedule with llvm-mca": its A53 model is wrong; time the loop on the board.
