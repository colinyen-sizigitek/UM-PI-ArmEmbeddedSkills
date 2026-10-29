# Sources

Summarize these in your own words; link them instead of copying text. Numbers measured on other
A53 SoCs (KV260, S922X, Raspberry Pi) must be marked "verify on TX8".

## Arm documentation (developer.arm.com)
- Cortex-A53 MPCore Processor Technical Reference Manual, DDI0500 (latest issue J):
  https://developer.arm.com/documentation/ddi0500/latest/
  - Advanced SIMD and FP section: https://developer.arm.com/documentation/ddi0500/j/Functional-Description/About-the-Cortex-A53-processor-functions/Advanced-SIMD-and-floating-point-Extension
  - PMU events chapter (event numbers 0x00-0x30 generic, 0xC0-0xE8 A53-specific).
- Cortex-A53 Software Developer Errata Notice (SDEN): search "Cortex-A53 errata" on
  https://developer.arm.com/documentation/ (erratum 835769, 843419 affected revisions).
- Cortex-A55 Software Optimization Guide, EPM128372 (upper-bound reference only; the A55 is
  stronger than the A53): https://developer.arm.com/documentation/epm128372/latest/
- Optimizing C code with Neon intrinsics, doc 102467:
  https://developer.arm.com/documentation/102467/latest/
- Neon Programmer Guide for Armv8-A: Coding for Neon, doc 102159:
  https://developer.arm.com/documentation/102159/latest/
- Learn the architecture - Memory Systems, Ordering, and Barriers, doc 102336:
  https://developer.arm.com/documentation/102336/latest/
- Arm Intrinsics search (filter: Neon, A64; avoid dotprod/i8mm/fp16/bf16/rdm):
  https://developer.arm.com/architectures/instruction-sets/intrinsics/
- Arm Streamline user guide, doc 101816:
  https://developer.arm.com/documentation/101816/latest/

## learn.arm.com
- Perf install guide: https://learn.arm.com/install-guides/perf/
- Streamline install guide: https://learn.arm.com/install-guides/streamline/
- Arm Performance Studio install guide: https://learn.arm.com/install-guides/ams/
- Autovectorization (restrict, conditionals, limits):
  https://learn.arm.com/learning-paths/cross-platform/loop-reflowing/
- Porting architecture-specific intrinsics (sse2neon, SIMDe):
  https://learn.arm.com/learning-paths/cross-platform/intrinsics/
- Linux perf on Raspberry Pi (A53-class board walkthrough):
  https://learn.arm.com/learning-paths/embedded-and-microcontrollers/rpi/perf/
- Other topics referenced by DESIGN section 4 (AoS -> SoA layout, memory latency, PMU access,
  cross-compiler guide): search https://learn.arm.com/ for the topic name.

## Community measurements
- Daniel Estevez, "Coding NEON kernels for the Cortex-A53" (2025, Kria KV260):
  https://destevez.net/2025/02/coding-neon-kernels-for-the-cortex-a53/
- Chips and Cheese, "ARM's Cortex A53: Tiny But Important" (2023):
  https://chipsandcheese.com/p/arms-cortex-a53-tiny-but-important
- Tencent ncnn, "arm a53 a55 dual issue":
  https://github.com/Tencent/ncnn/wiki/arm-a53-a55-dual-issue
  (also https://ncnn.readthedocs.io/en/latest/developer-guide/arm-a53-a55-dual-issue.html)
- Sonos tech blog, "Assembly still matters: Cortex-A53 vs M1":
  https://tech-blog.sonos.com/posts/assembly-still-matters-cortex-a53-vs-m1/

## Linux / tools
- Kernel perf PMU event JSON for the A53:
  https://github.com/torvalds/linux/tree/master/tools/perf/pmu-events/arch/arm64/arm/cortex-a53
  (use the tree matching the board's 5.15 kernel: `.../tree/v5.15/tools/perf/pmu-events/arch/arm64/arm/cortex-a53`)
- GCC AArch64 options (`-mcpu`, `-moutline-atomics`, `-mfix-cortex-a53-*`):
  https://gcc.gnu.org/onlinedocs/gcc-11.4.0/gcc/AArch64-Options.html
- GCC optimization options (`-fopt-info`, `-ffast-math`, `-fprofile-use`):
  https://gcc.gnu.org/onlinedocs/gcc-11.4.0/gcc/Optimize-Options.html
- GCC developer options (`-fopt-info` details):
  https://gcc.gnu.org/onlinedocs/gcc-11.4.0/gcc/Developer-Options.html

## Which source for which question

| Question | Best source | Caveat |
|---|---|---|
| Cache sizes, PMU event numbers, load/store path widths | A53 TRM DDI0500J | TRM does not give instruction timings |
| Instruction latency/throughput, dual-issue pairs | destevez.net, ncnn wiki, Chips and Cheese | measured on other A53 SoCs: verify on TX8 |
| Upper bound / general in-order tuning advice | A55 SOG EPM128372 | A55 is stronger; do not copy its numbers |
| Which intrinsic exists and needs which feature | Arm Intrinsics search | filter A64 + Neon; check required feature |
| Writing NEON kernels (deinterleave, tails) | docs 102467, 102159 | |
| Acquire/release, barriers | doc 102336 | |
| Auto-vectorization patterns | learn.arm.com loop-reflowing path | examples may use clang; our compiler is GCC 11 |
| perf events available on this kernel | kernel `pmu-events` JSON for v5.15 | the board's BSP kernel may differ: check `perf list` |
| GCC flag semantics | gcc.gnu.org docs for GCC 11 | newer GCC docs may describe flags GCC 11 lacks |

## Reading rules for agents

- Summarize in your own words and link the source; do not paste long passages.
- When a number comes from a community article, keep the "verify on TX8" marker and, where
  possible, give the command (`scripts/membw.cpp`, `scripts/bench_template.hpp`,
  `scripts/perf_a53.sh`) that would verify it.
- Prefer the documentation version matching our tools (GCC 11, Linux 5.15, Ubuntu 22.04).
- If a link is dead, search developer.arm.com / learn.arm.com for the document number or title;
  do not substitute a document for a different core without saying so.

## Libraries
- KleidiCV (Apache-2.0; verify on A53 before adopting): https://gitlab.arm.com/kleidi/kleidicv
- libjpeg-turbo: https://libjpeg-turbo.org/ (TurboJPEG API docs in the package)
- sse2neon (MIT): https://github.com/DLTcollab/sse2neon
- SIMDe (MIT): https://github.com/simd-everywhere/simde
