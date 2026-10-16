# Profiling and benchmarking on the TX8 (perf, A53 PMU, Streamline)

Rule: no optimization without a baseline number, no claim without a re-measurement under the same
conditions. All commands run on the board (`ssh umpi '...'`) unless marked as host side.

## 1. Pre-flight checks (read-only)

```bash
ssh umpi 'uname -r; which perf || echo "perf missing"; cat /proc/sys/kernel/perf_event_paranoid'
ssh umpi 'dmesg 2>/dev/null | grep -i -E "pmu|perf" | head; ls /sys/bus/event_source/devices/'
ssh umpi 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null; cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null'
```
- Expect a PMU device such as `armv8_cortex_a53` or `armv8_pmuv3` and a dmesg line reporting the
  number of counters (the A53 has 6 programmable counters + the cycle counter). If no PMU is
  listed, hardware events are unavailable (BSP/device tree issue): report it; software events and
  timing still work.
- `perf_event_paranoid`: <= 2 allows per-process user-space profiling of your own processes;
  <= 1 adds kernel profiling; `-1` everything. If it is 3 or 4 (Ubuntu hardened kernels), run
  perf with `sudo` or ask the user to lower it temporarily
  (`sudo sysctl kernel.perf_event_paranoid=1`): that is a system setting change, so **ask first**.
- `dmesg` may itself need sudo (`kernel.dmesg_restrict`).

## 2. Installing perf (requires approval)

The board runs a vendor 5.15 kernel. Ubuntu's `linux-tools-$(uname -r)` package only exists for
Ubuntu-built kernels. Options, in order (all need the user's approval):
1. If `uname -r` matches an Ubuntu kernel flavor: `sudo apt install linux-tools-$(uname -r) linux-tools-common`.
2. Otherwise `linux-tools-generic` sometimes provides a usable `perf` binary for the same major
   version (perf is mostly backward compatible with the kernel ABI); the wrapper script may
   refuse to run it, call the binary under `/usr/lib/linux-tools/*/perf` directly.
3. Build perf from the BSP kernel source (`tools/perf`, `make -C tools/perf`) on the board or in
   WSL2 cross; ask the vendor for the exact kernel source.
See the Arm install guide: https://learn.arm.com/install-guides/perf/

## 3. perf stat with A53 events

Generic Armv8 PMU events (raw codes usable as `rXX`):

| Code | Event | Use |
|---|---|---|
| 0x11 | CPU_CYCLES | denominator for everything |
| 0x08 | INST_RETIRED | IPC = inst / cycles (A53 max 2.0; good NEON code 0.8-1.5) |
| 0x04 | L1D_CACHE | L1D accesses |
| 0x03 | L1D_CACHE_REFILL | L1D misses |
| 0x16 | L2D_CACHE | L2 accesses |
| 0x17 | L2D_CACHE_REFILL | L2 misses (go to DRAM) |
| 0x10 | BR_MIS_PRED | mispredicted branches |
| 0x13 | MEM_ACCESS | data memory accesses |
| 0x05 | L1D_TLB_REFILL | data TLB refills |

A53-specific events (from the kernel's `tools/perf/pmu-events/arch/arm64/arm/cortex-a53` JSON
and the TRM):

| Code | Event | Meaning (cycles where the pipeline stalled because...) |
|---|---|---|
| 0xE0 | OTHER_IQ_DEP_STALL | instruction queue empty for other reasons |
| 0xE1 | IC_DEP_STALL | instruction cache miss |
| 0xE2 | IUTLB_DEP_STALL | instruction micro-TLB miss |
| 0xE3 | DECODE_DEP_STALL | decode restrictions |
| 0xE4 | OTHER_INTERLOCK_STALL | other register interlocks |
| 0xE5 | AGU_DEP_STALL | waiting for an address-generation result |
| 0xE6 | SIMD_DEP_STALL | waiting for a NEON/FP result (latency chains) |
| 0xE7 | LD_DEP_STALL | waiting for load data (L1 misses, load latency) |
| 0xE8 | ST_DEP_STALL | store-related stall |
| 0xC7 | STALL_SB_FULL | store buffer full (write-bound) |
| 0xC0 / 0xC1 | EXT_MEM_REQ / EXT_MEM_REQ_NC | external memory requests (cacheable / non-cacheable) |
| 0xC2 | PREFETCH_LINEFILL | lines filled by the hardware prefetcher |
| 0xC9 | BR_COND | conditional branches executed |
| 0xCC | BR_COND_MISPRED | conditional branch mispredictions |

Avoid multiplexing: at most 6 programmable events per group (cycles uses the dedicated counter).
`scripts/perf_a53.sh` runs separate groups and prints derived metrics. Manual form:
```bash
perf stat -e '{r11,r08,r03,r17,r10,r04}' -- ./app --frames 600
perf stat -e '{r11,re0,re1,re2,re3,re4}' -- ./app --frames 600
perf stat -e '{r11,re5,re6,re7,re8,rc7}' -- ./app --frames 600
perf stat -e '{r11,r08}' -p <pid> -- sleep 10            # attach to a running process
```
If perf reports `<not supported>` for an `rXX` code, check the PMU name and use the explicit
form `-e armv8_cortex_a53/event=0xe7/` (replace the PMU name with what `/sys/bus/event_source/devices/` shows).

## 4. Manual stall breakdown (topdown-tool does not support the A53)

From the counts:
- IPC = INST_RETIRED / CPU_CYCLES.
- MPKI (misses per 1000 instructions) = 1000 x REFILL / INST_RETIRED for L1D (0x03), L2 (0x17),
  branches (0x10).
- Stall % = 100 x E_x / CPU_CYCLES for each of 0xE0..0xE8 and 0xC7.

The A53 stall events are not mutually exclusive and do not sum to 100 %; use them to rank causes:

| Dominant signal | Likely cause | First thing to try |
|---|---|---|
| LD_DEP (0xE7) high + high L1D/L2 MPKI | memory-bound streaming | fuse passes, tile for L2, prefetch, smaller types (u8/u16 instead of float) |
| LD_DEP high, low MPKI | load-use latency in the loop | interleave loads earlier, unroll, D-load trick (`a53-microarch.md`) |
| SIMD_DEP (0xE6) high | dependent NEON chains | more accumulators, interleave independent work |
| OTHER_INTERLOCK (0xE4) / AGU (0xE5) | integer dependency / address computation chains | simpler indexing, pointer increments, hoist computations |
| IC_DEP (0xE1) / IUTLB (0xE2) high | code too big / scattered | less inlining/unrolling, PGO, `-Os` for cold code |
| BR mispredict MPKI > ~5 | data-dependent branches | branchless code, masks |
| STALL_SB_FULL (0xC7) high | store-bound (e.g. float tensor writes) | fewer/fused output passes, narrower output |
| IPC low but stalls low | waiting on syscalls/locks/sleep | look at off-CPU time: `perf sched`, `strace -c`, thread states |

## 5. Finding hotspots: perf record / report / annotate

```bash
# build with symbols and frame pointers (keep -O2 and project flags)
g++ ... -O2 -g -fno-omit-frame-pointer ...
perf record -F 999 -g -o perf.data -- ./app --frames 900
perf report -i perf.data --no-children --sort comm,dso,symbol | head -60
perf annotate -i perf.data --stdio -s <hot_symbol> | less
perf record -e r17 -c 10000 -g -- ./app ...            # sample on L2 refills instead of time
```
- Frame-pointer unwinding (`-g` default fp) is cheap; `--call-graph dwarf` works without frame
  pointers but is expensive on the A53 and produces large files: use only short runs.
- If `perf record` fails with "PMU hardware doesn't support sampling/overflow-interrupts", the
  PMU interrupt is not wired in the device tree: use `-e cpu-clock` (software timer sampling)
  and report the BSP issue.
- Flame graph (optional, on the host): `perf script -i perf.data > out.perf`, copy to the dev
  machine, then use Brendan Gregg's FlameGraph scripts or `speedscope` on the host.
- For multi-threaded pipelines add `--per-thread` to `perf stat` or `-s` to `perf report` to
  separate capture, pre/post and runtime threads.

## 6. Arm Streamline (GUI on Windows host)

Streamline (part of the free Arm Performance Studio) shows per-core timelines, PMU counters and
per-thread activity, which is useful for pipeline/scheduling problems.
- Host: install Arm Performance Studio on Windows (https://learn.arm.com/install-guides/streamline/).
- Target: run `gatord` on the board (an arm64 Linux `gatord` binary ships with Performance Studio;
  copying and running it on the board needs the user's approval). Connect from Streamline over
  TCP (default port 8080) via the board's IP, or an SSH tunnel: `ssh -L 8080:localhost:8080 umpi`.
- Running `gatord` as root gives full system-wide data; as a normal user it is limited to your
  own processes (requires `perf_event_paranoid` <= 2).
- Do not use the "Streamline CLI tools" or `topdown-tool`: they target Neoverse servers (see
  `excluded.md`).

## 7. Benchmark methodology

1. Fix conditions and record them: governor (`scaling_governor`), current frequency, SoC
   temperature, kernel, build flags, commit hash, other running processes, MX3 clock.
2. Warm up (caches, page faults, frequency ramp): >= 5 runs or ~1 s, discarded.
3. Measure >= 30 runs (micro) or >= 10 min (pipeline, per product target); report **median and
   p99** (also min and p90 for micro-benchmarks), and the run count.
4. Pin the benchmark thread (`taskset -c 2 ./bench` or `pin_current_thread`) to avoid migration
   noise; compare like with like (same core).
5. Thermal throttling: log temperature and `scaling_cur_freq` during long runs; if frequency
   drops or temperature trends up, the number is not steady-state. Run the full 10-minute target
   test in the real enclosure/airflow condition when possible.
6. Input data: use realistic frames (recorded MJPEG from the actual camera) and realistic score
   distributions; synthetic all-zero data hides branch and cache behavior.
7. Before/after: same binary flags except the change, same board, interleave A/B runs
   (A B A B ...) to cancel drift; consider a change real only if the median improves beyond the
   run-to-run spread (e.g. > 3 % and outside the p10-p90 band).
8. Keep CSV outputs (`bench --csv`) in the PR description or an internal results file.

## 8. Pipeline-level metrics (what to report)

- fps over 10 min (min over 1-second windows), latency p50/p99/max (capture -> metadata sent),
  start latency, dropped frames and why, per-core CPU %, SoC and MX3 temperatures, MX3 power
  (skill `mx3-runtime-integration` for the power/temperature APIs).
- Overhead check: perf itself perturbs timing slightly; measure latency without perf attached.

## 9. Quick recipes

```bash
# Is my process CPU-bound? per-thread CPU and placement
ps -L -o tid,psr,cls,rtprio,pcpu,comm -p $(pidof app)
# Context switches and migrations
perf stat -e context-switches,cpu-migrations,task-clock -p $(pidof app) -- sleep 10
# Scheduling latency of RT threads (needs root)
sudo perf sched record -- sleep 10 && sudo perf sched latency | head -30
```
