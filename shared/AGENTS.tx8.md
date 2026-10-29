# TX8 + MemryX MX3 project rules (always on)

<!-- tx8-skills:begin — managed by ArmEmbeddedSkills/install; edit the source in shared/AGENTS.tx8.md -->

These rules apply to every task in this repository. Detailed procedures live in the TX8 skills
(`um-pi-platform`, `um-pi-cpp-performance`, `um-pi-vision-pipeline`, `um-pi-mx3-model-selection`,
`um-pi-mx3-model-compile`, `um-pi-mx3-runtime-integration`, `um-pi-basestation-viewer`, `um-pi-code-review`).
Load the matching skill before doing non-trivial work in its area.

## Platform (UM-PI drone AI platform)
- **TX8 SOM** = Unimap UM21A646 ("TX5" die): **4x Cortex-A53 @1.2 GHz**, Armv8.0-A AArch64,
  NEON + CRC32 (crypto needs `+crypto`). **No LSE, dotprod, i8mm, fp16 arithmetic, bf16, SVE, SME.**
- L1 32 KB I + 32 KB D per core, **shared L2 1 MB, no L3**, cache line 64 B.
- DDR4: **2 GB (EVT) / 4 GB (MP)** — detect at runtime, never hard-code.
- **No NPU, no HW video/JPEG codec, no ISP, no MIPI CSI.** Cameras are USB UVC (MJPEG).
- **MemryX Cascade 100M** (4x MX3) on M.2 M-key, PCIe Gen3 (verify link width with `lspci -vv`).
  Each MX3: 10.5 MB on-chip weights, BF16 activations, INT8/INT4 weights, no DRAM.
- OS: **Ubuntu 22.04, Linux 5.15, GCC 11, glibc 2.35**. MemryX driver/runtime already installed.
- Board access from the dev machine: **`ssh umpi`** (key auth only).

## Non-negotiable rules
1. **Facts first.** If a fact about the board, kernel, library version, API signature or link speed
   is not in these rules, check it on the board (`ssh umpi ...`) or in the installed headers.
   Never guess hardware facts or API signatures.
2. **Priority: reliability > performance > power > size.** When the target is met, stop spending
   power (lower MX3 clock, fewer threads).
3. **Measure → optimize → re-measure.** No optimization claim without before/after numbers on TX8.
4. **Targets:** 30 fps sustained 10 min; TX8-internal latency (capture → metadata sent) p99 ≤ 80 ms;
   inference start (command → first metadata) ≤ 3 s. CPU, temperature, power: monitor and report.
5. **MX3 clock ≤ 400 MHz.** Choose the lowest PASS frequency from
   `um-pi-mx3-model-selection/references/tx8-freq-matrix.csv` whose fps ≥ target × 1.5. Never use
   MemryX's ARM default (500 MHz). Untested model/chip-count → run the stability test first.
6. **MX3 is active only while inference is on.** Stop → release the accelerator object and stop
   camera channel 2. Channel 1 (1080p MJPEG) keeps streaming to the base station untouched.
7. **Never re-encode video on TX8.** Forward MJPEG bytes verbatim; send detections as metadata.
8. Post-processing on TX8 is threshold + top-K only (NEON, branchless). Box decode stays in the
   compiled model; prefer NMS-free models (YOLOv10, YOLO26) with 1–3 classes.
9. Production code: **C++17**, `-O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror`.
   Python only for x86 model tools, prototypes/tests, and the Windows base-station viewer.
10. No OpenCV in production pre/post paths (libjpeg-turbo + own NEON; KleidiCV only after A53 verification).
11. No unbounded queues, no allocation in the per-frame hot path, no blocking calls inside MX3
    callbacks; every wait has a timeout; every error path is reported.
12. Do not install system packages, change kernel/MX3 power settings, or modify the board's
    system configuration without the user's explicit approval.
13. Ask the programmer — do not decide silently — for: MAVLink destination (UART to FC vs UDP to
    GCS), model license acceptability (AGPL/GPL vs commercial), M.2 power-switch hardware.

<!-- tx8-skills:end -->
