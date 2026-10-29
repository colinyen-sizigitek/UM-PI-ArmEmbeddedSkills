# Multi-chip operation on the Cascade 100M

The module has 4 chained MX3 chips that appear as **one device** (`/dev/memx0`, group 0,
"Number of chips: 4" in `--hello`). Chip count is selectable at application start (config/CLI,
1-4), no hot switch.

## 1. Option A (default): DFP compiled for N chips
- Compile once per chip count (`mx_nc -c N`, skill `um-pi-mx3-model-compile`) -> `<name>_c<N>.dfp`.
- At start, pick `dfps[chip_count == N]` from the manifest; construct `MxAcclMT(dfp, {0}, ...)`.
- Check `get_dfp_num_chips()` == N after construction.
- **Constraint (MemryX tutorial "Test with fewer chips")**: on the 4-chip M.2 only DFPs compiled
  for **2 or 4** chips run directly; a 1-chip DFP failed with "Input DFP was compiled for a 1-chip
  solution but you have a 4-chip solution attached". `mx_set_powermode` also only has 4-chip and
  2-chip modes. => 1 and 3 chips are **unverified** on our module. Open item for MemryX.
- `mx_nc -rc K` restricts the compile to K chips' resources while targeting `-c` chips: useful to
  **estimate** fewer-chip performance; unused chips stay powered — not a power saving.
- Fewer chips != proportionally less power: the reference matrix has 4-chip data only; measure.

## 2. Option B: data-parallel (1-chip DFP x N)
- Idea: compile a 1-chip DFP and run N copies, each on its own chip, feeding frames round-robin.
- Status: **not available as a documented feature** for chips inside one Cascade module.
  `device_ids_to_use` selects **devices** (whole modules / groups: `{0}`, `{0,1}`, `{-1}` = all),
  not chips inside a module. MemryX shared mode also states only one DFP is active on the hardware
  at a time per device.
- On a system with several separate MXA modules, data parallel = one accelerator per device id
  (local mode per device, or one object with several `device_ids`).
- For our single module: treat option B as unsupported until MemryX confirms how (ask on
  https://community.memryx.com/). Do not implement speculative per-chip addressing.

## 3. Choosing the chip count
| Situation | Choice |
|---|---|
| Default production | 4 chips (matrix data exists; best fps per clock) |
| Power budget tight, model fits 2 chips | try 2 chips at the rule clock; stability test + power probe; keep if targets met |
| 1 or 3 chips requested | compile, then board test; expect a chip-count mismatch error per MemryX docs |
| Model does not fit in N chips | compile fails (weights 10.5 MB/chip, feature maps 5 MB/chip) -> more chips or smaller model |

Every chip count other than the matrix's 4-chip config requires the stability test before the
frequency rule can be applied (append rows with `mpu_config` = `2x1`, ...).

## 4. Local vs shared mode
| | Local mode (`local_mode=true`) | Shared mode (default) |
|---|---|---|
| Who talks to the device | the application directly | `mxa-manager` service brokers access |
| Processes / DFPs | exactly one accelerator object, one DFP, no other process | many processes / DFPs |
| Overhead | lowest (better on weak hosts like 4x A53) | IPC + scheduler overhead |
| Tools in parallel (acclBench, diag via runtime) | conflict | allowed (time-sliced) |
| Power reading | `get_power()` via device manager | manager's average (`get_avg_power` in Python is shared-mode only) |

Recommendation for TX8 production (single app, single DFP): **local mode**; measure start time
and fps in both modes once and keep the numbers. Use shared mode during development when tools
must run alongside, or if MemryX support requires it.

Shared-mode scheduler for a single-DFP application (DESIGN): `frame_limit = 0`,
`time_limit = 5000` ms, passed in `SchedulerOptions` at construction (fields in order:
`frame_limit, time_limit, ifmap_queue_size, ofmap_queue_size, autoclock_enabled,
autoclock_power_limit_mw, autoclock_check_fps_saturation, autoclock_sample_interval_ms,
autoclock_num_samples`). Defaults are 20 frames / 250 ms, tuned for several DFPs sharing the
hardware. The exact meaning of `frame_limit = 0` is not documented on the API page — verify
with MemryX docs or a measurement (fps and latency with 0 vs 20).

`mxa-manager` system configuration (`/etc/memryx/mxa_manager.conf`: `LISTEN_ADDRESS`,
`BASE_PORT`) is not changed by the application; changes need the user's approval.

## 5. Multiple models
Not in the current product scope. If needed later: compile both models into one DFP (multi-model
`mx_nc -m a.onnx b.onnx`, optionally `--models_share_ifmap`) rather than two DFPs — only one DFP
is active on the hardware at a time, and switching DFPs costs reload time.

## 6. Measuring a chip-count trade-off (procedure)
1. Compile `_c4` and `_c2` DFPs from the same ONNX (skill `um-pi-mx3-model-compile`); same flags.
2. On the board, run the stability test for each DFP at the rule clock(s):
   ```bash
   bash mx3_stability_test.sh --dfp ~/models/m/current/m_c4.dfp --model M --chips 4 --freqs "300 400" --minutes 10 --yes --out stab.csv
   bash mx3_stability_test.sh --dfp ~/models/m/current/m_c2.dfp --model M --chips 2 --freqs "300 400" --minutes 10 --yes --out stab.csv
   ```
3. Apply the frequency rule to the new rows (`mpu_config` 4x1 vs 2x1) with `freq_query`.
4. Run the real pipeline at 30 fps with each option; record end-to-end fps, p99 latency, module
   power (`get_power()`), max chip temperature and board power (`mx3_power_probe.sh`).
5. Choose the option that meets all targets with the lowest power; record the decision and data.

## 7. Checklist
- [ ] `--hello` shows 4 chips; diag report stored.
- [ ] DFP chip count matches config (`get_dfp_num_chips()`), from the manifest.
- [ ] Mode chosen (local/shared) and measured.
- [ ] Stability test rows exist for this chip count and clock.
- [ ] Power measured per chip count if a reduced count is proposed for power reasons.
