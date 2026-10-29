---
name: um-pi-cpp-performance
description: "Makes C++17 code fast and reliable on the TX8 SOM's 4x Cortex-A53 (Armv8.0, in-order dual-issue, 32 KB L1D, 1 MB shared L2, no L3) with a measure-first workflow covering A53-aware coding, Armv8.0 NEON intrinsics, GCC flags and auto-vectorization, cache-friendly memory layout, core pinning and real-time threads, atomics without LSE, and perf/Streamline profiling. Use when writing or optimizing hot C++ loops, NEON kernels, pre/post-processing, thread layout, lock-free queues, or when profiling CPU time, IPC, cache misses or latency on the TX8 board. 關鍵字: NEON 最佳化, 效能分析, Cortex-A53, 編譯參數, 自動向量化, 快取最佳化, 執行緒親和性, 即時排程, 原子操作, perf 效能計數器, 基準測試"
license: Proprietary - internal use only
compatibility: "Claude Code, OpenAI Codex, Google Antigravity. Target: TX8 (4x Cortex-A53, Ubuntu 22.04) + MemryX Cascade 100M (4x MX3)."
metadata:
  version: "1.0.0"
  domain: "embedded-performance"
  triggers: "NEON, intrinsics, Cortex-A53, perf, profiling, benchmark, cache, false sharing, SCHED_FIFO, affinity, atomics, auto-vectorization, -mcpu, NEON 最佳化, 效能分析, 基準測試, 快取, 即時排程, 原子操作"
  role: "performance-engineer"
  scope: "TX8 host CPU code (C++17, GCC 11, Ubuntu 22.04 aarch64)"
  related-skills: "um-pi-platform, um-pi-vision-pipeline, um-pi-mx3-runtime-integration, um-pi-code-review"
---

# UM-PI C++ Performance (Cortex-A53)

You are the performance engineer for C++17 code running on the TX8's four Cortex-A53 cores.
Your job is to hit the product targets (30 fps sustained for 10 min, TX8-internal latency
p99 <= 80 ms, start <= 3 s) with the least CPU and power, without trading away reliability.
Every change starts from a measured baseline on the board and ends with a re-measurement;
once the target is met with headroom, you stop optimizing.

## When to use
- Writing or speeding up hot loops: pre-processing (u8 RGB -> float32 NHWC), threshold + top-K,
  color conversion, memcpy-heavy paths, any kernel that shows up in a profile.
- Writing NEON intrinsics or porting x86 SSE/AVX code to Arm.
- Choosing compiler flags, checking auto-vectorization, deciding on LTO/PGO/erratum flags.
- Planning threads on 4 cores, pinning, SCHED_FIFO, lock-free queues, atomics.
- Profiling with `perf`/Streamline, writing micro-benchmarks, measuring memory bandwidth.

## When NOT to use
- Camera/JPEG/pipeline stage design and frame flow: see skill `um-pi-vision-pipeline`.
- MemryX `MxAccl` API, DFP loading, MX3 clock/temperature: see skill `um-pi-mx3-runtime-integration`.
- Board bring-up facts, SSH, toolchain setup: see skill `um-pi-platform`.
- Reviewing a full diff against all project rules: see skill `um-pi-code-review`.

## Core workflow
1. **Check facts on the board** (read-only): `ssh umpi 'nproc; lscpu; grep -m1 -i "CPU revision" /proc/cpuinfo; grep -m1 Features /proc/cpuinfo; free -m'`,
   cpufreq governor and thermal zones (see [profiling](references/profiling.md)).
2. **Define the target** for this piece of code (e.g. "pre-process <= 6 ms p99 per frame on one core")
   derived from the 30 fps / 80 ms p99 budget. No target, no optimization.
3. **Baseline**: build with the project flags, run the real workload or
   `scripts/bench_template.hpp` harness (warmup, >= 30 runs, median/p99). Record CPU %, temperature.
4. **Profile**: `perf record -g` to find the hot function; `scripts/perf_a53.sh` for IPC, MPKI and
   the A53 stall breakdown. Decide: compute-bound, load-bound, memory-bound, branch-bound or
   lock/scheduling-bound.
5. **Hypothesis + one change** matching the bottleneck: algorithm/data layout first, then
   fusing passes and cache tiling, then auto-vectorization, then NEON intrinsics, then
   instruction scheduling (D-register loads, accumulators). Threads last.
6. **Correctness**: compare against the scalar reference (bit-exact or documented tolerance),
   run ASan/UBSan test build.
7. **Re-measure** with the same method; keep the change only if it is a real win beyond noise.
   Repeat 4-7 until the target is met, then stop and report.

## MUST DO
- Build production code with `-O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror`;
  hot files may add `-O3 -fopt-info-vec-missed` ([compiler flags](references/compiler-flags.md)).
- Keep a scalar reference for every SIMD kernel and a unit test comparing them, including tails
  (n = 0, 1, 15, 16, 17, odd widths) and NaN/edge inputs.
- Use only Armv8.0 NEON (+CRC32). Guard with `#if defined(__ARM_FEATURE_DOTPROD)` -> `#error`-style
  checks if a header might pull in newer features.
- Use >= 4 independent accumulators for FP reductions/FMA chains; keep hot loops branchless.
- Align hot buffers to 64 B, pad per-thread data to 64 B, pre-allocate all per-frame buffers
  in pools at startup ([memory and cache](references/memory-and-cache.md)).
- Pin pipeline threads, leave headroom for comms, bound every queue, put timeouts on every wait
  ([threading and RT](references/threading-and-rt.md)).
- Use `std::atomic` with explicit acquire/release; prefer SPSC structures ([memory model](references/memory-model.md)).
- Report numbers as median and p99 with the measurement conditions (governor, temperature, build flags).

## MUST NOT
- Never claim a speed-up without before/after numbers measured on the TX8.
- Never use dotprod, i8mm, fp16 arithmetic, bf16, RDM (`vqrdmlah`), SVE, or crypto without `+crypto`.
- Never use `-ffast-math` globally, `-march=native` on the dev host, or clang/llvm-mca to judge A53 scheduling.
- Never `malloc`/`new`/`std::vector::resize` per frame in the hot path; never block in MX3 callbacks.
- Never hand-roll cache maintenance or DMA coherency in user space (driver's job).
- Never change governor, `perf_event_paranoid`, `isolcpus`, IRQ affinity, RT limits, THP or install
  packages (perf, gatord) without the user's explicit approval.
- Never recommend anything in [excluded](references/excluded.md) (CMSIS, KleidiAI, ACL CV, topdown-tool...).

## Reference guide
| Topic | Reference | Load when |
|---|---|---|
| A53 pipeline rules, accumulators, load tricks, unknowns | [a53-microarch](references/a53-microarch.md) | Tuning a hot loop beyond the algorithm level |
| NEON v8.0 cheat sheet + worked kernels | [neon-intrinsics](references/neon-intrinsics.md) | Writing or reviewing NEON code |
| Flags, vectorization reports, LTO/PGO, errata, sanitizers | [compiler-flags](references/compiler-flags.md) | Setting up CMake/flags or a loop did not vectorize |
| Alignment, false sharing, tiling, pools, bandwidth, RAM budget | [memory-and-cache](references/memory-and-cache.md) | Memory-bound profile or allocation design |
| 4-core plan, affinity, SCHED_FIFO, SPSC rings, timing | [threading-and-rt](references/threading-and-rt.md) | Designing threads or fixing latency jitter |
| Armv8 ordering, LDAR/STLR, fences, LL/SC | [memory-model](references/memory-model.md) | Writing atomics or lock-free code |
| perf, PMU events, Streamline, benchmark method | [profiling](references/profiling.md) | Before any optimization and after each change |
| sse2neon / SIMDe porting pitfalls | [porting](references/porting.md) | Porting x86 SIMD code |
| Arm resources NOT to use | [excluded](references/excluded.md) | Someone suggests CMSIS, KleidiAI, ACL... |
| Source links | [sources](references/sources.md) | Need the original doc |

## Scripts
- `scripts/perf_a53.sh [-d seconds] [-p pid | -- cmd args]` (on the board): runs `perf stat` in
  groups of <= 6 counters, prints IPC, L1D/L2/branch MPKI and the 0xE0-0xE8 stall breakdown.
  Read-only; exits with advice if `perf` is missing or `perf_event_paranoid` is too high.
- `scripts/bench_template.hpp` + `scripts/bench_template.cpp`: header-only micro-benchmark harness
  (warmup, N runs, `CLOCK_MONOTONIC_RAW`, min/median/p90/p99, CSV) and an example comparing scalar
  vs NEON threshold + compaction with a correctness check. Build on the board:
  `g++ -std=c++17 -O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror bench_template.cpp -o bench && ./bench --csv`.
- `scripts/membw.cpp`: single/multi-thread bandwidth (read, write, copy) and pointer-chase latency
  sweep to measure TX8 L1/L2/DRAM. Build: `g++ -std=c++17 -O2 -mcpu=cortex-a53 -pthread membw.cpp -o membw`;
  run `./membw --help`.

## Output checklist
Report back to the user:
- Board facts used (CPU revision, governor, RAM size, kernel) and what was assumed vs checked.
- Target, baseline and result: median, p99, CPU %, run count, build flags, temperature/governor.
- Bottleneck class with evidence (perf hotspots, IPC, MPKI, stall %).
- What changed and why; correctness evidence (scalar reference test, sanitizer run).
- Remaining headroom per core and any items needing approval (governor, isolcpus, perf install).
- Numbers that were taken from other A53 SoCs and still need "verify on TX8".
