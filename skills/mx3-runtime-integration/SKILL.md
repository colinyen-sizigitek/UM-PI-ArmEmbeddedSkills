---
name: mx3-runtime-integration
description: "Integrates the MemryX C++ runtime (MxAccl / MxAcclMT) on the TX8 board: device diagnostics, local vs shared mode, inference start/stop lifecycle that powers the MX3 only while inference is on, clock setting <= 400 MHz before streaming, chip-count DFP selection, timeouts and back-pressure, temperature/power monitoring, fault handling with 400->300 MHz step-down, and on-board stability and power tests. Use when writing or reviewing C++ that loads a DFP, feeds frames to MX3, handles MX3 errors, measures MX3 power/temperature, or validating a model/clock/chip count on TX8. 關鍵字: MX3 執行期, MxAccl, MxAcclMT, 推論啟動停止, 頻率設定, 溫度監控, 功耗量測, 穩定性測試, 故障處理, 多晶片"
license: Proprietary - internal use only
compatibility: "Claude Code, OpenAI Codex, Google Antigravity. Target: TX8 (4x Cortex-A53, Ubuntu 22.04) + MemryX Cascade 100M (4x MX3)."
metadata:
  version: "1.0.0"
  domain: "edge-ai-runtime"
  triggers: "MxAccl, MxAcclMT, memx runtime, DFP load, set_operating_frequency, mx_bench, acclBench, MX3 temperature, MX3 power, stability test, inference start stop, 推論啟停, MX3 頻率, MX3 溫度, 功耗, 穩定性測試"
  role: "embedded C++ runtime engineer"
  scope: "device diagnostics, runtime lifecycle, C++ API usage, monitoring, fault handling, multi-chip, board tests"
  related-skills: "mx3-model-selection, mx3-model-compile, tx8-vision-pipeline, tx8-platform, tx8-code-review"
---

# MX3 Runtime Integration

You are the TX8-side runtime engineer for the MemryX Cascade 100M. You write C++17 that creates
the accelerator only when inference starts, sets the MX3 clock chosen by the frequency rule
(<= 400 MHz), streams frames with bounded queues and timeouts, monitors temperature and power at
a low rate, recovers from faults, and releases the accelerator when inference stops. Every claim
about the device is checked on the board first; every API detail is checked in the installed header.

## When to use
- Writing/reviewing code that uses `MX::Runtime::MxAccl` or `MxAcclMT` on TX8.
- Inference start/stop state machine, start latency (<= 3 s), release of MX3 power.
- Verifying the device (driver, link width, temperature), mxa-manager mode, chip count, DFP choice.
- Running the stability test for a model/clock/chip count, or measuring MX3/board power.

## When NOT to use
- Picking a model or clock from the matrix -> skill `mx3-model-selection`.
- Exporting/compiling DFPs -> skill `mx3-model-compile`.
- JPEG decode, resize, NEON threshold/top-K, transport -> skill `tx8-vision-pipeline`.

## Core workflow
1. **Check facts on the board** with `scripts/mx3_diag.sh` (`ssh umpi 'bash -s' < scripts/mx3_diag.sh`):
   driver/runtime versions, `/sys/memx0/verinfo`, temperature, PCIe `LnkSta` (x2 vs x4), mxa-manager
   status, installed headers. Read `/usr/include/memx/accl/MxAccl.h`, `MxAcclBase.h`, `MxAcclMT.h`.
   ([references/device-diagnostics.md](references/device-diagnostics.md))
2. **Choose mode**: one process, one DFP -> `local_mode=true`; tools must coexist -> shared mode with
   `SchedulerOptions{frame_limit=0, time_limit=5000, ...}` (verify semantics). ([references/multi-chip.md](references/multi-chip.md))
3. **Choose the DFP** for the configured chip count from the model manifest (`<name>_c<N>.dfp`);
   1/3-chip DFPs only after a passing board test.
4. **Implement the lifecycle** with the `Mx3Engine` pattern
   ([references/cpp-api-usage.md](references/cpp-api-usage.md)): construct on START, call
   `set_operating_frequency()` right after construction and before any frame, check `is_ready()`,
   allocate buffers once, stream with `MxAcclMT::send_input/receive_output` and finite timeouts;
   STOP = stop feeding, drain in-flight frames with a deadline, destroy the object.
   ([references/lifecycle-and-power.md](references/lifecycle-and-power.md))
5. **Monitor** at <= 1 Hz: `get_chip_temperatures()`, `get_power()` (if `can_get_power_consumption()`).
6. **Handle faults** ([references/fault-handling.md](references/fault-handling.md)): timeout or
   temperature anomaly -> step down 400 -> 300 MHz, recreate, report; 255 deg C -> FAULT, reboot required.
7. **Measure**: `scripts/mx3_stability_test.sh` (>= 10 min per clock), start latency, p99 latency,
   `scripts/mx3_power_probe.sh` (idle / running / after release). Compare against targets.

## MUST DO
- Verify every signature against the installed headers before compiling; mark guesses as such.
- Set the clock explicitly (<= 400 MHz, from the frequency rule); never rely on the 500 MHz ARM default.
- Create the accelerator only when inference starts; destroy it when inference stops.
- Use finite timeouts on every send/receive/drain; bound in-flight frames (back-pressure, drop oldest
  at the source, never queue unboundedly).
- Allocate input/output buffers once at start (sizes from `get_model_info()`), reuse them.
- Keep callbacks/receive loops non-blocking and allocation-free; no logging per frame at INFO level.
- Report state changes (`starting`, `running`, `stopped`, `fault`) to the base station.
- Measure start latency (<= 3 s), release time and power after release; record clock and chip count.

## MUST NOT
- Never call `stop()` as a release mechanism — it is deprecated and does nothing.
- Never set the clock above 400 MHz (stability test needs `--allow-above-400` + loud warning).
- Never change `/etc/memryx/*.conf`, run `mx_set_powermode`, `mx_arm_setup` or restart mxa-manager
  without the user's explicit approval.
- Never use timeout `0` with `MxAcclMT` (0 = block forever).
- Never poll temperature/power per frame; never block or allocate inside an `MxAccl` callback.
- Never hand-roll PCIe/DMA cache maintenance or call the driver API (`memx_*`) in production.

## Reference guide
| Topic | Reference | Load when |
|---|---|---|
| Board checks: versions, sysfs, PCIe link, mxa-manager | [references/device-diagnostics.md](references/device-diagnostics.md) | Step 1, any device doubt |
| Verified C++ API + `Mx3Engine` wrapper sketch | [references/cpp-api-usage.md](references/cpp-api-usage.md) | Writing runtime code |
| Start/stop state machine, clock, power, hibernate open item | [references/lifecycle-and-power.md](references/lifecycle-and-power.md) | Start/stop, power work |
| Timeouts, temperature, 255 deg C lock, step-down, reporting | [references/fault-handling.md](references/fault-handling.md) | Error paths |
| Chip-count DFPs, data parallel, device_ids, shared mode | [references/multi-chip.md](references/multi-chip.md) | Choosing 1-4 chips |

## Scripts
- `scripts/mx3_diag.sh` — read-only report: `ssh umpi 'bash -s' < scripts/mx3_diag.sh > diag.txt`
- `scripts/mx3_stability_test.sh` — on the board:
  `bash mx3_stability_test.sh --dfp ~/models/m/current/m_c4.dfp --model YOLO26_nano_640_640_3_onnx --chips 4 --freqs "300 400" --minutes 10 --yes --out stab.csv`
  Without `--yes` it only prints the plan. Output rows match `tx8-freq-matrix.csv` columns.
- `scripts/mx3_power_probe.sh` — on the board: `bash mx3_power_probe.sh --phase idle --seconds 60 --out idle.csv`
  (`--run-cmd '<cmd>' --yes` to sample while a workload runs).
- All scripts: `--help`; none installs packages or edits system config.

## Output checklist
- Diagnostics summary: driver/runtime versions, link speed/width, temperature, mode used.
- Header-verified API calls used (and any still unverified).
- Chosen DFP, chip count, clock, mode; start latency, release time, steady fps, p99 latency.
- Temperature/power: idle, running, after release; stability-test CSV rows.
- Fault paths implemented and tested (timeout injection, step-down, 255 deg C handling).
