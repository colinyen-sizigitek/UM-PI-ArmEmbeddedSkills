# Inference lifecycle and MX3 power

Product rule: **the MX3 is active only while inference is on.** Stop = release the accelerator
object (default). Start must reach the first metadata within **3 s**.

## 1. State machine (single owner thread)
```
            start cmd                 first result             stop cmd
  IDLE ─────────────────▶ STARTING ─────────────────▶ RUNNING ─────────────▶ STOPPING ──▶ IDLE
    ▲                        │ error/timeout              │ fault                   │ drain deadline
    │                        ▼                            ▼                         ▼   exceeded
    └───── reset/report ── FAULT ◀────────────────────────┴─────────────────────── (report)
```
- All control sources (base station, MAVLink, local config/API) become one `InferenceControl{start|stop}`
  event on a queue consumed by the owner thread; last command wins; every transition is reported
  (`starting`, `running`, `stopped`, `fault`).
- A `start` while STOPPING is queued and handled after IDLE; a `stop` while STARTING aborts
  start (destroy whatever was created).
- FAULT is left only by an explicit reset/start after the cause is handled (see `fault-handling.md`).

## 2. START sequence (target <= 3 s total, measure each step)
1. Resolve config: chip count -> DFP from manifest; clock from the frequency rule (<= 400 MHz).
2. Start camera CH2 capture + decode thread (CH1 forwarding never stops).
3. `Mx3Engine::start()`:
   a. construct `MxAcclMT(dfp, {device}, {true,true}, local_mode)` — DFP is downloaded to the chips here;
   b. `set_operating_frequency(device, FREQ_<clock>MHz)` — check the bool;
   c. `is_ready()`; check `get_dfp_num_chips()` matches config;
   d. `set_parallel_fmap_convert(n)`; `get_model_info(0)`; allocate buffer ring once.
4. Start producer and consumer threads; first `submit()`.
5. First `poll()` result -> first metadata sent -> state RUNNING, report `running` with
   `start_ms` breakdown (config, camera, construct, freq, alloc, first result).

Expected cost drivers: DFP download over PCIe (size of DFP / link bandwidth), driver
initialisation, camera start. Measure on TX8 with `std::chrono::steady_clock` around each step;
if construct + first result alone approaches 3 s, report it — options are a smaller DFP, keeping
the camera warm, or (only with product-owner approval) keeping the accelerator alive between
sessions at idle clock.

## 3. STOP sequence
1. State STOPPING; stop the producer (no new `submit()`), stop CH2 capture.
2. Consumer drains in-flight frames: `receive_output` with short timeouts until in-flight = 0 or
   the drain deadline (e.g. 500 ms) passes; publish or discard those results (policy: publish).
3. Join producer/consumer threads (with timeouts; a thread that does not exit = FAULT).
4. `Mx3Engine::stop()` -> `accl_.reset()`: the destructor closes the local/shared session.
   **Do not call `stop()` on `MxAccl`** — deprecated, does nothing.
5. Report `stopped` with `stop_ms`, frames dropped, frames abandoned.

For the auto-threaded `MxAccl` (prototype only): make the input callback return `false`
(non-blocking flag check), call `wait()`, then destroy the object.

## 4. Clock policy
- Clock = lowest PASS <= 400 MHz with table fps >= target x 1.5 (skill `um-pi-mx3-model-selection`).
- Set per session via `set_operating_frequency()` immediately after construction; do not edit
  `/etc/memryx/power.conf` or run `mx_set_powermode` (system change, needs approval; also changes
  other users' default).
- After a fault step-down (400 -> 300 MHz) keep the lower clock until the next manual start or a
  defined cool-down policy; report the degraded state.
- Never enable `autoclock_*` scheduler options in production (they change the clock behind the
  frequency rule).

## 5. Power facts
| State | Value | Source / status |
|---|---|---|
| Module max load | ~13 W | MemryX module spec |
| Module TDP low / typical / worst | 5.15 / 7.7 / 9.27 W | MemryX module spec |
| Chip Standby (DFP kept) | ~400 mW (per chip vs module: verify) | MemryX; **no public SW API to enter it** |
| Chip Hibernate (DFP reload, 50-100 ms exit) | ~200 mW (per chip vs module: verify) | MemryX; **no public SW API** |
| Running detector at 300 MHz (4 chips) | ~3.8-5.0 W module | reference matrix, NOT TX8 |
| Running detector at 400 MHz (4 chips) | ~4.6-6.5 W module | reference matrix, NOT TX8 |
| Idle after release on TX8 | unknown | **measure** (procedure below) |

- Matrix power is at full throughput. Our pipeline runs at 30 fps, so real MX3 power should be
  lower than the table — measure, do not assume.

## 6. Power measurement procedure
Goal: numbers for (a) board idle with MX3 never started since boot, (b) running at the chosen
clock, (c) after release, (d) after release + 60 s.
1. Prepare: fixed ambient, enclosure as flown, fan/heatsink as flown, no other workloads. Record
   `mx3_diag.sh` output.
2. Sources, best first:
   - External meter on the board/module supply (most trustworthy; only option for whole board).
   - Board hwmon sensors (INA-type) if TX8 exposes them (`/sys/class/hwmon/*/power*_input`, uW).
   - MX3 runtime `get_power()` (mW, needs a live accelerator object -> only during "running").
   - `acclBench --power` during a synthetic run (local mode: averaged).
3. Run `scripts/mx3_power_probe.sh` for each phase (60-120 s each, 1 s interval):
   ```bash
   ssh umpi 'bash mx3_power_probe.sh --phase idle --seconds 120 --out p_idle.csv'
   # start the application / or a synthetic workload via --run-cmd (needs --yes)
   ssh umpi 'bash mx3_power_probe.sh --phase running --seconds 120 --out p_run.csv'
   # stop inference in the application, then immediately:
   ssh umpi 'bash mx3_power_probe.sh --phase after_release --seconds 120 --out p_rel.csv'
   ```
4. Log in the application, while running, `get_power()` and `get_chip_temperatures()` at 1 Hz.
5. Report a table: phase, board W (meter), hwmon W, MX3 mW (runtime), max chip deg C, SoC deg C, clock.
6. Acceptance: after release, power should return to the idle baseline within a short time. If it
   does not, the chips may remain in an active state without a DFP — escalate (open item below).

## 7. Open item: standby / hibernate
- MX3 supports Standby (~400 mW, DFP kept) and Hibernate (~200 mW, 50-100 ms exit), but there is
  no public software API to enter them. Releasing `MxAccl` is the only documented control.
- Question for MemryX (https://community.memryx.com/): how does an application put the module in
  hibernate/standby after releasing the accelerator, and what is the module power after release?
- Optional hardware path: M.2 slot power switch via a carrier GPIO + PCIe remove/rescan. Only if
  the carrier supports it — ask the programmer/HW team; never toggle GPIOs blindly. After power-up
  the driver must re-enumerate (`echo 1 > /sys/bus/pci/rescan`, root) and start latency grows.
- Track in `docs/open-items.md`.
