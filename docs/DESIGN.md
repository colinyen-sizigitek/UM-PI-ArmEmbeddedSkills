# TX8 / MX3 Agent Skill Suite — Design Specification

Status: confirmed by product owner 2026-10-08. This file is the single source of truth for
every skill in `skills/`. When a skill and this file disagree, this file wins; fix the skill.

---

## 1. Goal

A suite of Agent Skills that makes Claude Code, OpenAI Codex and Google Antigravity write
**optimal, reliable code** for the **UM-PI drone AI platform**: TX8 SOM + MemryX Cascade 100M
M.2 module. TX8 offloads all AI inference to the MX3 chips.

Audience: software engineers on their own dev machines (Windows host + SSH to the board).
Skills are internal-only (license: `Proprietary - internal use only`).

---

## 2. Platform facts (verified from `Spec/` and vendor docs)

### 2.1 TX8 SOM
- "TX8" is the SOM/board name. SoC = **Unimap UM21A646** (datasheet UM2xA646-DS Rev.3,
  2025-05-13; die codename "Unimap-TX5"). TX5 == TX8 for our purposes. Vendor: Unimap Technology (TW), UMC 28nm.
- CPU: **4x Arm Cortex-A53**, up to 1200 MHz (600 MHz low-speed mode). Boots AArch64.
  Armv8.0-A: NEON (AdvSIMD) + CRC32; Crypto extension present in HW but **GCC 11
  `-mcpu=cortex-a53` does not enable it** (`+crypto` needed). **No LSE atomics, no dotprod,
  no i8mm, no fp16 arithmetic, no bf16, no SVE/SVE2/SME, no RCpc (LDAPR)**.
- Caches: L1 I 32 KB (2-way VIPT) + L1 D 32 KB (4-way PIPT) per core; shared **L2 1 MB**
  (16-way); **no L3**; cache line **64 B**.
- GIC-400; CoreSight with 16 KB ETB.
- GPU: Vivante 3D (not used for vision; no compute plan).
- **No NPU, no hardware video/JPEG codec, no ISP, no MIPI CSI** → cameras are USB UVC;
  JPEG decode is CPU (libjpeg-turbo NEON).
- Security: Soteria engine (AES/RSA/HMAC/TRNG, OTP, eFuse), secure boot before CA53 release.
- DRAM: DDR4-2400 32-bit. **EVT boards 2 GB; MP (mass production) 4 GB** → always detect at runtime.
- Storage: 8 GB eMMC + microSD. Boot from SPI NOR/NAND, eMMC, SD.
- **PCIe Gen3 x4**, 1 controller (Synopsys DWC), acts as RC; M.2 M-key slot on carrier.
- Other peripherals (not a skill focus; mention only): USB 3.2 Gen1 x1, USB 2.0 x2, GbE x2,
  CAN FD x3, UART x4, I2C x4, SPI x4, ADC/DAC, LVDS x2, motor-control blocks, 2x DMA (8 ch).
- OS: **Ubuntu 22.04, Linux 5.15**, toolchain GCC 11, glibc 2.35. MemryX driver
  (`memx-drivers`) + runtime (`memx-accl`) **already installed and verified** on the SOM.
- Docs missing from `Spec/`: UM-PI user manual, BSP/toolchain details, operating temperature,
  SoC power. Skills must say "verify on board" for these, never invent values.

### 2.2 MemryX Cascade 100M (M.2 2280 M-key)
- 4x MX3 chips, chained (one logical device). MemryX lists 24-25 TFLOPS total.
- MemryX M.2 datasheet says PCIe Gen3 **x2** while the slot is x4 → verify negotiated link with
  `sudo lspci -vv` (`LnkSta`). Do not assume.
- Per MX3: 6 TFLOPS @1 GHz, freq 200–1000 MHz in 25 MHz steps; **10.5 MB weight memory**
  (~10.5M INT8 params / ~21M INT4), 5 MB feature-map memory, **no external DRAM** → model must
  fit on-chip: total ~42M INT8 params across 4 chips.
- Data types: activations Group-BF16; weights INT8/INT4 (INT16 via SW). Host feeds float32 NHWC.
- Power: module max load ~13 W, TDP 5.15/7.7/9.27 W (low/typical/worst). Chip states: Standby
  (~400 mW, DFP kept), Hibernate (~200 mW, DFP reload, 50–100 ms exit) — **no public software API
  to enter standby/hibernate**. Temp −40..+85 °C module; chip throttles >100 °C; a chip reporting
  255 °C is locked → reboot required.
- Docs: https://developer.memryx.com/ (SDK 2.2).

### 2.3 MemryX SDK essentials
- **Neural Compiler** `mx_nc` (x86_64 Linux/WSL with AVX2, or ARM64 Linux; ≥8 GB RAM advised →
  **compile on the x86 dev machine, not on the board**). Inputs: ONNX, TFLite, TF (.pb), Keras;
  PyTorch → export ONNX first. Output `.dfp`; with `--autocrop` also `*_pre.onnx/_post.onnx`.
  Key flags: `-m` model(s), `-c` chip count (default 4), `-is` NHWC input shape, `--autocrop`,
  `--inputs/--outputs` crop points, `-bt` per-layer weight bits 4/8/16, `--exp_auto_dp`
  (auto 16-bit for sensitive layers), `-hpoc` high-precision output channels, `-e` effort
  (lazy/normal/hard), `--models_share_ifmap`, `--sim_dfp`. YOLOv10/11/26 extensions auto-enabled in 2.2.
  Install: `pip install --extra-index-url https://developer.memryx.com/pip memryx` (Py 3.9–3.12).
- **Simulator is not available on ARM**; Python `set_preprocessing_model/set_postprocessing_model`
  **not available on ARM**.
- **C++ runtime** `#include "memx/accl/MxAccl.h"`, namespace `MX::Runtime`:
  - `MxAccl(dfp_path, std::vector<int> device_ids={0}, use_model_shape={true,true}, local_mode=false, ...)`;
    also constructor from in-memory DFP buffer.
  - Auto-threaded: `connect_stream(in_cb, out_cb, stream_id, model_id=0)`; callbacks
    `bool(std::vector<const MX::Types::FeatureMap*>, int stream_id)`; input cb returns false → stream ends;
    `FeatureMap::set_data(float*)` / `get_data(float*)`; `start()`, `wait()`; `stop()` is deprecated (no-op).
  - Manual threading `MxAcclMT`: `send_input(std::vector<float*>, model_id, stream_id, timeout_ms)`,
    `receive_output(...)`.
  - Others: `connect_pre_model/connect_post_model`, `set_num_workers`, `set_parallel_fmap_convert`,
    `set_operating_frequency(...)` (docs say "before `connect_dfp()`", but the public constructor
    already connects the DFP; MemryX's own acclBench calls it **right after construction, before
    any streaming** — follow that order and verify against the installed header; the parameter is an
    enum whose values equal MHz in the GitHub runtime), `get_power()` (mW), `can_get_power_consumption()`,
    `get_chip_temperatures()`, `get_max_temperature()`, `SchedulerOptions` (incl. `autoclock_*`),
    `ClientOptions`.
  - YOLO pre/post C++ helpers: https://developer.memryx.com/runtime/mxprepost.html
  - Examples: https://github.com/memryx/MemryX_eXamples ; CMake target name is **not documented** →
    inspect installed package (`dpkg -L memx-accl`) before writing `find_package`/link lines.
- **Python**: `AsyncAccl(dfp, ...)` with `connect_input/connect_output/wait/stop`; `MultiStreamAsyncAccl`;
  `SyncAccl` (not recommended). Python is **prototype/test only** on TX8.
- **Driver API** `memx_open/memx_download_model/memx_set_stream_enable/memx_stream_ifmap/ofmap/memx_close`
  (advanced; use only for diagnostics or when MemryX instructs).
- **mxa-manager** systemd service: shared mode (default) vs `local_mode=true` (exclusive). Conf
  `/etc/memryx/mxa_manager.conf`. Scheduler `frame_limit` (default 20), `time_limit` (default 250 ms);
  single-DFP apps: `frame_limit=0, time_limit=5000`. Only one DFP active on HW at a time.
- Diagnostics: `apt policy memx-drivers`, `cat /sys/memx0/verinfo`, `cat /sys/memx0/temperature`,
  `mx_bench`, `sudo mx_set_powermode` (interactive). ARM default freq is 500 MHz — **override it**.
- Benchmark: `mx_bench` (host-side incl. driver/interface time).
- Model Explorer: https://developer.memryx.com/model_explorer/models.html — per model: input res,
  params, framework, FPS (14T/20T), latency, DFP download. **No accuracy, no license, no chip count**.
  Measured on Intel i7-9700T host → treat as upper bound; TX8 host is slower.
- Accuracy reference (YOLOv8 COCO mAP50-95 CUDA vs MXA): n 37.3/37.1, s 44.9/44.7, m 50.2/49.9.
- Ultralytics export: `model.export(format='onnx', simplify=True, batch=1)`; then
  `mx_nc -v --autocrop -m model.onnx`.

### 2.4 MX3 frequency reference matrix (MemryX reference table, NOT measured on TX8)
File: `skills/mx3-model-selection/references/tx8-freq-matrix.csv` (generated from the
product owner's `model_inference_results_by_frequency.xlsx`). 579 models x {300,400,450,500} MHz,
config 4x1 (4 chips). PASS counts: 300→569, 400→562, 450→533, 500→424. Columns: model, freq_mhz,
status, fps, cpu, power_mw, voltage_mv, temp_c, note. The CPU column unit is unspecified.

**Product-owner rule: MX3 clock ≤ 400 MHz.** Selection rule:
1. Only frequencies that are in the table **and ≤ 400 MHz** with status PASS for that model.
2. Pick the **lowest** such frequency where `table_fps ≥ target_fps × 1.5` (safety factor 1.5).
3. If none qualifies → model "not recommended" for this target.
4. Model or chip-count (1–3 chips) not in table → must run the on-board stability test first.
5. First deployment on TX8 must verify (table is a reference, not TX8 data).
6. At runtime: temperature anomaly or inference timeout → step down one frequency level
   (400→300), reconnect, report to base station.

Detection examples at 640x640 (fps / module mW): 
| model | 300 MHz | 400 MHz | rule result (30 fps x1.5=45) |
|---|---|---|---|
| YOLO26 nano 640 | 88 / 3829 | 120 / 4588 | 300 MHz |
| YOLOv10 nano PVA 640 | 114 / 4006 | 155 / 4984 | 300 MHz |
| YOLOv10 nano 640 | 111 / 4053 | 150 / 5032 | 300 MHz |
| YOLO11 nano MXA-Opt 640 | 157 / 4981 | 215 / 6452 | 300 MHz |
| YOLOv8 nano 640 | 152 / 4264 | 222 / 5831 | 300 MHz |
| YOLOv10 small PVA 640 | 43 / 3596 | 58 / 4660 | 400 MHz |
| YOLOv10 small 640 | 37 / 3507 | 51 / 4449 | 400 MHz |
| YOLO26 small 640 | 23 / 2899 | 31 / 3655 | not recommended |
(PVA = person/vehicle/animal class-reduced variant.)

### 2.5 Licenses of common detectors (flag, don't exclude)
AGPL-3.0: Ultralytics YOLOv5/v8/11/26, YOLOv10 (THU). GPL-3.0: YOLOv9, YOLOv6.
Apache-2.0: YOLOX, DAMO-YOLO, RTMDet (MMDetection), NanoDet. Always verify the upstream license.
NMS-free: YOLOv10, YOLO26.

---

## 3. Product decisions

### 3.1 Priorities and targets
- Priority: **reliability > performance > power > size**. Once the target is met, stop spending
  power (lower MX3 clock, fewer threads).
- Workflow: **measure → optimize → re-measure**. No optimization without a baseline number.
- Hard targets: **30 fps sustained 10 min; TX8-internal latency p99 ≤ 80 ms** (capture timestamp →
  metadata sent); **start latency ≤ 3 s** (start command → first metadata).
- Monitor only (no hard limit): CPU %, SoC/MX3 temperature, MX3 power, end-to-end latency estimate.

### 3.2 Pipeline (drone)
- Camera (USB UVC) outputs **MJPEG** on two channels:
  - **CH1 1080p30 MJPEG → forwarded to base station untouched** (no decode, no re-encode).
  - **CH2 640x640 30fps MJPEG → decode (libjpeg-turbo/TurboJPEG) → MX3 model input 640x640**.
    Fallback if targets missed: 320x320 model with TurboJPEG 1/2 scaled decode.
- Post-processing load reduction (all adopted):
  1. Class reduction to 1–3 classes (retrain/fine-tune, or at minimum prune unused class channels
     from the ONNX head before compiling).
  2. NMS-free models (YOLOv10 / YOLO26 one-to-one head).
  3. Push compute to MX3: keep sigmoid/box decode inside the compiled graph; host only does
     confidence threshold + top-K (NEON, branchless).
  4. Send **metadata only** (boxes, class, score, frame_id, timestamp); base station renders.
- Inference on/off: sources = base station command, flight controller (MAVLink), local
  config/API → all mapped to one internal `InferenceControl{start|stop}` event handled by a single
  state machine (`IDLE → STARTING → RUNNING → STOPPING → IDLE`, plus `FAULT`). Conflicts: last
  command wins; state changes are reported to the base station (`starting`, `running`, `stopped`, `fault`).
- **MX3 only active while inference is on.** Stop = release `MxAccl` (default). Optional: M.2 slot
  power switch via carrier GPIO + PCIe remove/rescan (only if HW supports; ask). Open item: ask
  MemryX community how to enter hibernate (https://community.memryx.com/).
- When inference is off: CH1 keeps streaming; **CH2 capture stops**.
- MX3 count selectable 1–4 at startup (config file / CLI), no hot switch. Default: load the DFP
  pre-compiled for that chip count (`mx_nc -c N`); also support data-parallel 1-chip DFP x N.
  **Caveat (found during implementation):** MemryX's "test with fewer chips" tutorial says a 4-chip
  M.2 runs DFPs compiled for 2 or 4 chips, and a 1-chip DFP errors; `device_ids` selects whole modules,
  not chips. So 1- and 3-chip configs and 1-chip data-parallel are **unverified** — see
  `docs/open-items.md` #14–15. **Product owner decision (2026-10-08): keep 1–4 selectable for now;
  engineers verify 1- and 3-chip DFPs on the board before the support list is final.** Until then,
  skills present 2 and 4 chips as verified-by-docs and 1 and 3 as "unverified — test first".
- Output transport selectable by user: **WebSocket** or **MAVLink**.
  - WebSocket: one connection; binary messages with header `type | frame_id | ts_us | len` then
    payload; JPEG bytes forwarded verbatim; metadata as binary or JSON message type.
  - MAVLink: custom dialect XML (e.g. `OBJECT_DETECTION` message) + mavgen. **Destination
    (UART to flight controller vs UDP to ground station) must be asked of the programmer.**
    Video is not sent over MAVLink; it stays on the WebSocket/HTTP channel aligned by timestamp.
- Base station = Windows PC (also the dev host for WebSocket tests).

### 3.3 Languages and build
- Production code on TX8: **C++17** (GCC 11). C only where an API demands it.
- Python: x86 model tools (`mx_nc`), board prototypes/tests, Windows base-station viewer.
- Flags (global): `-O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror`; hot files
  `-O3 -fopt-info-vec-missed`; `+crypto` only if AES/SHA needed; Cortex-A53 erratum flags
  (`-mfix-cortex-a53-835769`, `-mfix-cortex-a53-843419`) decided after checking CPU revision
  (`/proc/cpuinfo` "CPU revision"/MIDR).
- clang-format + clang-tidy defaults; ASan/UBSan builds for tests (not on release).
- Build: default **native build on the board over SSH** (no ABI mismatch); optional cross-compile
  in WSL2 Ubuntu 22.04 with `aarch64-linux-gnu-g++` (GCC 11, matching glibc 2.35). Do **not** use
  Arm GNU Toolchain 15.x for the target unless sysroot/glibc matches.
- Do not depend on OpenCV for production pre/post. Use libjpeg-turbo (TurboJPEG API), own NEON
  kernels, optionally KleidiCV (Apache-2.0; NEON backend built for armv8-a; **not officially tested
  on A53 → verify correctness and speed before adopting**). OpenCV allowed for debug/prototype.
  Ubuntu 22.04 OpenCV is 4.5.4 (no KleidiCV HAL; HAL default-on only from 4.13).
- Board access: always via SSH alias **`umpi`** (`~/.ssh/config` Host umpi). Key auth, never passwords.

### 3.4 Dev environment
- Engineers have their own dev machines (Windows). The skills **check and advise** the dev env
  (WSL2 Ubuntu 22.04, git, CMake ≥3.16, Python 3.11, `mx_nc`, ssh alias, optional cross g++),
  never silently install system software.

---

## 4. Arm resources (what the skills use)

Include (summarize in own words, link originals):
- Cortex-A53 TRM DDI0500 (latest DDI0500J). No public A53 Software Optimization Guide → use
  Cortex-A55 SOG EPM128372 as an upper-bound reference + community measurements
  (Chips and Cheese A53 article; destevez.net "Coding NEON kernels for the Cortex-A53" 2025;
  Tencent ncnn A53/A55 dual-issue notes).
- A53 micro-architecture rules (mark "verify on TX8" where measured elsewhere):
  - 8-stage in-order, dual-issue; no register renaming.
  - Two 64-bit FP/ASIMD pipes: a **128-bit (Q) NEON op occupies both** → cannot dual-issue with
    another NEON/FP op; 64-bit (D) ops can pair with `ldr d`/`ins`.
  - FADD/FMUL/FMLA latency ~4 cycles → ≥4 independent accumulator chains.
  - **One AGU**: one load or store per cycle; L1D read path 64-bit → `ldr q`/`ld1` costs 2 cycles
    per register; `str q` 1 cycle. Trick: `ldr d` + `ldr x` + `ins v.d[1]` interleaved with math.
  - L1D hit 3 cycles; crossing 8 B (scalar) / 16 B (NEON) boundary +1 cycle; max 3 outstanding
    L1D misses; L2 ~17 cycles (measured S922X); DRAM >100 ns.
  - No BTB; taken branch ~3 cycles bubble; mispredict ~7 cycles → branchless hot loops (`vbsl`, masks).
  - HW stride prefetcher + `prfm pldl1keep` / `__builtin_prefetch` 128–256 B ahead fills free slots.
  - **LLVM's A53 scheduling model is inaccurate**; prefer GCC with `-mcpu=cortex-a53`; do not trust
    llvm-mca for A53; inspect hot-loop assembly.
- NEON: Arm Intrinsics search https://developer.arm.com/architectures/instruction-sets/intrinsics/
  (filter Neon + A64, avoid dotprod/i8mm/fp16-arith/bf16/rdm); "Optimizing C code with Neon
  intrinsics" doc 102467 (RGB deinterleave `vld3q_u8` example); "Neon Programmer Guide for Armv8-A:
  Coding for Neon" doc 102159.
- learn.arm.com: autovectorization (`restrict`, loop tails), AoS→SoA data layout, memory latency,
  perf install guide, PMU access, cross-compiler guide, intrinsics porting (sse2neon, SIMDe).
- Memory model: "Learn the architecture – Memory Systems, Ordering, and Barriers" doc 102336;
  `std::atomic` acquire/release → LDAR/STLR; no LSE → LL/SC loops; `-mno-outline-atomics`.
  Align hot buffers to 64 B; avoid false sharing (`alignas(64)` per-thread counters).
  DMA coherency for PCIe buffers belongs to the kernel driver; never hand-roll cache maintenance
  in user space.
- Profiling: Linux `perf` (A53 PMU JSON in kernel `tools/perf/pmu-events/arch/arm64/arm/cortex-a53`).
  Generic events: CPU_CYCLES 0x11, INST_RETIRED 0x08, L1D_CACHE 0x04, L1D_CACHE_REFILL 0x03,
  L2D_CACHE 0x16, L2D_CACHE_REFILL 0x17, BR_MIS_PRED 0x10, MEM_ACCESS 0x13, L1D_TLB_REFILL 0x05.
  A53 stall events: 0xE0 OTHER_IQ_DEP_STALL, 0xE1 IC_DEP_STALL, 0xE2 IUTLB_DEP_STALL,
  0xE3 DECODE_DEP_STALL, 0xE4 OTHER_INTERLOCK_STALL, 0xE5 AGU_DEP_STALL, 0xE6 SIMD_DEP_STALL,
  0xE7 LD_DEP_STALL, 0xE8 ST_DEP_STALL; 0xC7 STALL_SB_FULL; 0xC0/0xC1 EXT_MEM_REQ(_NC);
  0xC2 PREFETCH_LINEFILL; 0xC9 BR_COND; 0xCC BR_COND_MISPRED. Check counters: `dmesg | grep -i pmu`.
  `perf_event_paranoid` ≤ 2 (or run with sudo). Topdown-tool does not support A53 → build a manual
  stall breakdown from 0xE0–0xE8.
- Arm Streamline (Arm Performance Studio, free) works for A53 Linux user space via `gatord` on the
  target, GUI on Windows host.
- Exclude (explain in `excluded.md`): CMSIS(-NN/-DSP), Keil, Ethos-U/Vela, Corstone/FVP, Zephyr
  MPS boards, SVE/SME learning paths, KleidiAI (needs dotprod/i8mm/SME; inference is on MX3),
  Arm Compute Library (CV functions removed in 21.05; ML ops only), Arm Performance Libraries
  (Neoverse-targeted), topdown-tool & Streamline CLI (Neoverse-only), llvm-mca for A53,
  developer.arm.com/ai portal content (CPU inference; not our case).

---

## 5. Repository layout

```
ArmEmbeddedSkills/
  README.md                      # 繁體中文 overview + install + usage
  docs/DESIGN.md                 # this file
  docs/dev-env-setup.md          # recommended engineer workstation setup
  docs/hw-validation-checklist.md
  docs/open-items.md             # unresolved questions (hibernate API, PCIe x2/x4, CMake target...)
  shared/AGENTS.tx8.md           # always-on rules, ≤ 24 KB, merged into target project's AGENTS.md
  skills/<name>/SKILL.md (+ references/, scripts/, assets/)
  install/install.ps1, install/install.sh
  scripts/validate.py, scripts/validate.ps1
  evals/README.md + evals/*.md   # eval prompts + expected key points (grouped by skill area)
```

Skills (8): `tx8-platform`, `tx8-cpp-performance`, `tx8-vision-pipeline`, `mx3-model-selection`,
`mx3-model-compile`, `mx3-runtime-integration`, `basestation-viewer`, `tx8-code-review`.

---

## 6. SKILL.md conventions (all skills MUST follow)

- Agent Skills open standard (https://agentskills.io/specification). Frontmatter fields ONLY:
  `name`, `description`, `license`, `compatibility`, `metadata`. Nothing tool-specific
  (no `allowed-tools`, `paths`, `model`, ...).
- `name`: lowercase a-z0-9 and `-`, ≤64 chars, **equals folder name**.
- `description`: ≤1024 chars, form "<What it does>. Use when <triggers>." Then append Chinese
  trigger keywords, e.g. `關鍵字: NEON 最佳化, 效能分析, ...`. Single line, double-quoted.
- `license: Proprietary - internal use only`
- `compatibility: "Claude Code, OpenAI Codex, Google Antigravity. Target: TX8 (4x Cortex-A53, Ubuntu 22.04) + MemryX Cascade 100M (4x MX3)."`
- `metadata:` keys (string values, quote version): `version: "1.0.0"`, `domain`, `triggers`
  (comma-separated English+Chinese), `role`, `scope`, `related-skills` (comma-separated).
- Body (English), **80–150 lines**, in this order:
  1. `# <Title>` + one-paragraph role statement.
  2. `## When to use` / `## When NOT to use` (point to sibling skill).
  3. `## Core workflow` — numbered steps; starts with "check facts on the board" when relevant;
     always includes a measure step.
  4. `## MUST DO` and `## MUST NOT` bullet lists.
  5. `## Reference guide` — table `| Topic | Reference | Load when |` with relative links
     `references/xxx.md` (one level deep).
  6. `## Scripts` (if any) — how to run each.
  7. `## Output checklist` — what the agent must report back.
- References: one topic per file, 80–400 lines, English, concrete code where useful, link original
  sources, never copy copyrighted text verbatim. Mark unverified numbers "verify on TX8".
- Scripts: POSIX `bash` (board side, `set -euo pipefail`), Python 3.10+ (stdlib unless stated),
  PowerShell 5.1 compatible for Windows host. Each script has a `--help`/usage header. Scripts never
  install system packages or change system settings without an explicit flag and a printed warning.
- Cross-skill references: name the sibling skill (e.g. "see skill `mx3-runtime-integration`"),
  don't link into another skill's folder.
- Commands that touch the board are written as `ssh umpi '<cmd>'` or "on the board:" blocks.
- Never invent API signatures: when unsure, instruct to check the installed header
  (`/usr/include/memx/...`) or the official page, and say so.
