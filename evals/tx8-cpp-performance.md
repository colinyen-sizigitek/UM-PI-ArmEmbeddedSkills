# Evals: um-pi-cpp-performance

## P1 — NEON threshold
Prompt: "這段 YOLO 輸出過濾在 TX8 上太慢，幫我用 NEON 改寫：for (i...) if (score[i] > th) out[n++] = i;"
Expected:
- Asks for or creates a baseline measurement first (bench harness, median/p99).
- Branchless NEON (`vcgtq_f32` + mask/compaction), scalar tail, scalar reference test.
- Uses only Armv8.0 intrinsics; mentions ≥2–4 independent chains / interleaving loads.
- Re-measures and reports the speed-up on TX8.
Red flags: ⚠ uses dotprod/fp16/SVE intrinsics; claims a speed-up without measuring; uses `-ffast-math` globally.

## P2 — Compiler flags
Prompt: "TX8 專案的 CMake 編譯旗標應該怎麼設？"
Expected: `-O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror`; `-O3` only on hot files; `+crypto` only when needed; erratum flags decided after checking the CPU revision; GCC preferred over clang for A53 scheduling.
Red flags: `-march=armv8.2-a`, `+dotprod`, `-mcpu=native` when cross-compiling.

## P3 — Profiling
Prompt: "How do I find out why my preprocessing thread uses 90% of a core on TX8?"
Expected: `perf stat` with cycles/instructions/L1D/L2 refill + A53 stall events 0xE0–0xE8 (`perf_a53.sh`); `perf record -g`/annotate; checks the cpufreq governor and thermal state; memory layout / cache-tiling hypotheses (a 640×640×3 frame > 1 MB L2).
Red flags: recommends topdown-tool or llvm-mca for A53; recommends Arm Performance Libraries / KleidiAI.

## P4 — Threading
Prompt: "設計 4 核心的執行緒配置，讓擷取、解碼、推論、傳送不互相干擾。"
Expected: core plan presented as a starting point to measure; affinity; bounded SPSC queues with drop-oldest; no blocking or allocation in the hot path; headroom left for comms; SCHED_FIFO caveats and a watchdog; changing isolcpus requires approval.
