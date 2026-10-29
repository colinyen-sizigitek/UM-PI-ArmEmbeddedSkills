# MX3 fault handling

Priority is reliability: detect quickly, degrade predictably, always report. Every wait has a
timeout; every error path ends in a reported state.

## 1. Fault sources and detection
| Fault | Detection | Threshold (starting point, tune on TX8) |
|---|---|---|
| Construction / DFP load failure | `MxAcclMT` constructor throws `std::runtime_error` | immediate |
| Clock not applied | `set_operating_frequency()` returns false | immediate |
| Device not ready | `is_ready()` false | immediate |
| Chip-count mismatch | `get_dfp_num_chips()` != configured | immediate |
| Input stall | `send_input(..., timeout)` returns false | 3 consecutive, or > 1 s cumulative in 5 s |
| Output stall (hang) | `receive_output(..., timeout)` false while frames in flight | 2 consecutive at 200 ms |
| Throughput collapse | measured fps < target for 5 s while input is available | fps < 0.8 x target |
| Over-temperature | `get_chip_temperatures()` max | >= 95 deg C warn, >= 100 deg C anomaly (MemryX throttles above 100) |
| Temperature anomaly | jump > 15 deg C within 2 s, or reading <= -40 / NaN | anomaly |
| Chip lock-up | any chip reports **255 deg C** | immediate FAULT, reboot required |
| Thread did not exit | join timeout during STOP | FAULT |
| Exception from runtime call | try/catch around the producer/consumer loop bodies | immediate |

Temperature and power are read at <= 1 Hz (consumer thread), never per frame.
All thresholds are proposals — record them in config and validate with the stability test.

## 2. Recovery policy (product rule)
```
anomaly (timeout / temperature / throughput)  at clock 400 MHz:
    report "fault: <cause>, stepping down to 300 MHz"
    STOP (drain with deadline) -> destroy accelerator
    START again with clock 300 MHz (same DFP) -> report "running (degraded 300 MHz)"
anomaly at 300 MHz (lowest permitted step for this model):
    STOP -> FAULT -> report "fault: <cause>" ; stay in FAULT until operator/base-station reset
255 deg C on any chip:
    STOP (do not attempt more I/O than the drain deadline) -> FAULT "mx3_locked_reboot_required"
    do NOT retry; the PCIe bus is only cleared by a reboot. Rebooting is an operator decision
    (drone safety) unless the product owner defines an automatic policy.
construction / ready failure at START:
    one retry after 500 ms; second failure -> FAULT with the exception text
```
- "One frequency level" = the next lower row in the frequency matrix (400 -> 300). Do not go
  below the lowest clock that the model was validated at; if 300 MHz does not meet 30 fps for this
  model, the degraded mode misses the target — report that explicitly ("degraded, below target").
- Limit retries: at most one step-down per session; at most N (e.g. 3) automatic restarts per
  hour, then FAULT. Prevents restart loops that heat the module.
- Recreating the accelerator costs start time (see lifecycle) — the base station must show
  "restarting" so the operator knows detections paused.

## 3. Reporting
Every fault report to the base station (WebSocket or MAVLink, see skill `um-pi-vision-pipeline`):
```json
{ "type": "mx3_state", "state": "fault", "cause": "recv_timeout",
  "detail": "2 consecutive receive_output timeouts (200 ms), in_flight=3",
  "clock_mhz": 400, "next_clock_mhz": 300, "max_chip_temp_c": 92.5,
  "chips": 4, "dfp": "yolo26n-pvc3-640x640_c4.dfp", "ts_us": 1728380000000000 }
```
Also log locally (rate-limited) with the last N monitor samples (temperature, power, fps,
in-flight) to help post-flight analysis.

## 4. Implementation notes
- Fault detection runs in the consumer thread (it sees receive timeouts and does monitoring);
  it **posts an event** to the owner/state-machine thread — it never tears the engine down itself.
- The owner thread performs STOP/START; producer and consumer threads exit on a stop flag checked
  at least every timeout period.
- Make timeouts configurable and derived from measurements: `recv_timeout_ms` > p99.9 MX3
  in-to-out latency x 3, but small enough to keep detection < 1 s.
- Count and expose: sends, receives, send timeouts, receive timeouts, drops (Busy), restarts,
  step-downs. These counters are the evidence in the stability report.
- Use `std::chrono::steady_clock` only (never wall clock) for timeouts and latency.

## 5. Testing the fault paths
| Test | How | Expected |
|---|---|---|
| Receive timeout | set `recv_timeout_ms=1` in a debug build | step-down path, report, recovery |
| Construction failure | point config at a missing/corrupt DFP | one retry, then FAULT with message |
| Chip-count mismatch | load a `_c2` DFP with chips=4 | immediate FAULT, no crash |
| Over-temperature | debug hook that injects a temperature sample of 101 / 255 | step-down / FAULT reboot-required |
| Stop under load | stop at 30 fps with 3 frames in flight | drain < deadline, `stopped`, no leak |
| Start/stop soak | 200 start/stop cycles | no FD/memory growth (`/proc/<pid>/status`, `ls /proc/<pid>/fd`), start <= 3 s each |
| Thermal soak | stability test 10+ min at the chosen clock in the enclosure | no anomaly, temp plateau < 95 deg C |

Never trigger a real 255 deg C lock-up deliberately (it needs a reboot and may stress hardware);
use injection.

## 6. What is not handled in software
- PCIe link errors / device disappearance: detect via constructor/ready failures and `dmesg`;
  recovery requires reboot or (if available) M.2 power cycling — hardware decision, ask.
- Firmware hangs that do not surface as timeouts are unknown territory — collect diag reports
  (`scripts/mx3_diag.sh`) and escalate to MemryX.
