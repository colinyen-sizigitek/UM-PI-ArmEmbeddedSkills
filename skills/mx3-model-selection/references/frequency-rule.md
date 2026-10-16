# MX3 frequency rule (product-owner decision)

Source of truth: `docs/DESIGN.md` section 2.4. This file explains how to apply it, with worked
examples, and how to keep the data current.

## Why a rule
- MX3 runs 200-1000 MHz in 25 MHz steps. MemryX's default power mode is **500 MHz on ARM hosts**
  (600 MHz on x86). Higher clock = more fps, more power, more heat, and on some models failures
  (rows with `NG`). On a drone, reliability > performance > power, so the product owner capped
  the clock at **400 MHz** and asks for the **lowest** clock that meets the target with margin.
- The C++ runtime exposes the clock as `MX::Types::MxFrequencyOption` (`FREQ_200MHz` ...
  `FREQ_1000MHz`, plus `FREQ_USE_CONF` = use the system power configuration). Setting it is
  covered in skill `mx3-runtime-integration`.

## The rule
1. Consider only rows of the model in `tx8-freq-matrix.csv` with `freq_mhz <= 400` **and**
   `status == PASS`. The table has 300, 400, 450 and 500 MHz rows; so in practice the candidates
   are **300 and 400 MHz**.
2. Pick the **lowest** of those where `fps >= target_fps x 1.5` (safety factor 1.5).
3. No row qualifies -> the model is **"not recommended"** for this target (choose a smaller model
   or a lower input resolution — do not raise the clock).
4. Model, input size, or chip count (1-3 chips) **not in the table** -> run the on-board stability
   test first (skill `mx3-runtime-integration`, `scripts/mx3_stability_test.sh`), append its rows
   to the CSV, then apply steps 1-3.
5. First deployment on TX8 must verify the choice: the table is MemryX reference data (4 chips),
   not a TX8 measurement.
6. At runtime: temperature anomaly or inference timeout -> step down one level (400 -> 300 MHz),
   reconnect, report to the base station (skill `mx3-runtime-integration`, fault handling).

Why 1.5: the table fps is accelerator-bound throughput on a MemryX host with random input. TX8
adds JPEG decode, float conversion, host post-processing and a weaker CPU; MX3 throughput also
drops with temperature. 1.5x leaves room for that and for p99 latency.

## Data columns
`model,freq_mhz,status,fps,cpu,power_mw,voltage_mv,temp_c,mpu_config,note`
- `fps`: max throughput. `power_mw`: module power. `voltage_mv`: chip core voltage at that clock.
  `temp_c`: chip temperature during the run. `cpu`: unit unspecified by the source — do not use.
- `mpu_config`: `4x1` = 4 chips. Empty for NG rows.
- 300 MHz `NG` rows with note "No 300 MHz disabled-model record" = status unknown -> treat as NG.
- Lines starting with `#` are comments; both scripts skip them.

## Worked examples (target 30 fps -> need fps >= 45)

| Model | 300 MHz | 400 MHz | Result | Reasoning |
|---|---|---|---|---|
| YOLO26_nano_640 | PASS 88.0 | PASS 120.2 | **300 MHz** | 88.0 >= 45 at the lowest clock. |
| YOLO_v10_small_person_vehicle_animal_640 | PASS 42.5 | PASS 58.1 | **400 MHz** | 42.5 < 45, 58.1 >= 45. |
| YOLO_v10_small_640 | PASS 37.4 | PASS 51.0 | **400 MHz** | Same pattern. |
| YOLO26_small_640 | PASS 22.8 | PASS 31.4 | **not recommended** | 31.4 < 45 even at 400 MHz (450 MHz gives 35.4 — still fails, and is forbidden). |
| YOLOX_small_640 | PASS 128.6 | **NG** | **300 MHz** | 300 qualifies; note 400 is NG -> never step **up** blindly. |
| YOLO_v8_small_Oriented_Bounding_Boxes_1024 | PASS 37.6 | NG | **not recommended** | 37.6 < 45 and 400 is NG. |

Other targets:
- 15 fps (need 22.5): YOLO26_small_640 -> 300 MHz (22.8 >= 22.5, very thin; verify on TX8).
- 60 fps (need 90): YOLO26_nano_640 -> 400 MHz (120.2); YOLO_v10_nano_PVA_640 -> 300 MHz (113.6).

Reproduce with:
```powershell
powershell -NoProfile -File scripts/freq_query.ps1 -ModelRegex 'YOLO26_(nano|small)_640' -TargetFps 30
powershell -NoProfile -File scripts/freq_query.ps1 -ModelRegex 'YOLO26_small_640' -TargetFps 15
```
```bash
python3 scripts/freq_query.py --model-regex 'YOLO_v10_small.*640' --target-fps 30
```

## Chip count
- All matrix rows are **4 chips**. A DFP compiled for fewer chips runs a different mapping with
  lower throughput; the table does not apply.
- For 1, 2 or 3 chips: compile (skill `mx3-model-compile`), then run the stability test at 300 and
  400 MHz on TX8 with that DFP and append the rows (with `mpu_config` set to e.g. `2x1`).
- MemryX documents that on the 4-chip M.2 only DFPs compiled for 2 or 4 chips run directly; a
  1-chip DFP fails with a chip-count mismatch error in their tutorial. Treat 1/3-chip DFPs as
  unverified on Cascade 100M until the stability test passes.

## Updating the CSV when new data arrives
1. Never edit rows by hand in place; append new measurement rows with the same columns, and put a
   `note` such as `TX8 stability test 2026-10-20, 10 min, board SN xxx, SDK 2.2.x`.
2. If a TX8 row and a MemryX row exist for the same model/clock/config, **the TX8 row wins**.
   The scripts use the first PASS row per (model, freq) that meets the target; keep TX8 rows
   distinct by `mpu_config` or by renaming the model with a suffix (e.g. `..._tx8`) until a
   proper "source" column is added (open item for the CSV owner).
3. Add a `#` comment line at the top describing the new source.
4. Regenerate the summary: `powershell -NoProfile -File scripts/gen_detection_summary.ps1`.
5. Re-run `freq_query` for the current product model and update any recommendation that changed.

## Stability test requirement (summary)
Required when: the model/input/chip count is missing from the table; a different DFP (your own
compile, other class count) replaces a reference DFP; or the first deployment on a new board.
Minimum: >= 10 min per clock at 300 and 400 MHz, temperature sampled every few seconds, PASS if
no error, no timeout, no 255 deg C reading, and fps stable. The script and its CSV output format
are in skill `mx3-runtime-integration` (`scripts/mx3_stability_test.sh`). It refuses clocks above
400 MHz unless `--allow-above-400` is given with a loud warning, and asks for `--yes` before it
changes the MX3 clock.
