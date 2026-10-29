# Frame/metadata sync and latency estimation

The base station receives two independent message streams over one WebSocket: CH1 JPEG
frames and DETECTIONS computed from CH2. Detections always arrive **after** the CH1 frame they
belong to (they need decode + MX3 + post on TX8). This file defines how the viewer pairs them,
how it estimates the TX8 <-> PC clock offset, and how it presents latency.

Golden rule: **never draw detections on the wrong frame.** If no matching result arrives in
time, show the frame without boxes (and count it), never with stale boxes.

## 1. What TX8 sends (recap)

- JPEG_CH1: `frame_id` = CH1 counter, `ts_us` = CH1 capture time (TX8 clock).
- DETECTIONS: `ts_us` = CH2 capture time. If flag PAIRED is set, `frame_id` is the CH1 frame
  TX8 paired it with (closest capture time, within half a frame period). Otherwise only the
  timestamp is usable.
- An empty detection list is a valid result ("nothing found"), different from "no result".

## 2. Matching algorithm

Data structures (all bounded):
- `frames`: ordered dict `frame_id -> FrameEntry(ts_us, jpeg_bytes, t_rx_local)`, max 64
  entries (~2 s at 30 fps). Oldest evicted first.
- `results`: dict `frame_id -> DetResult` for PAIRED results, plus a small deque of unpaired
  results keyed by `ts_us` (max 64).

Display policy per frame (in arrival order):
1. If inference is not RUNNING (from STATUS), display frames immediately without boxes.
2. If RUNNING, hold each frame up to `match_window_ms` (default 150 ms, measured on the local
   clock from its arrival) waiting for its result:
   - PAIRED result with the same `frame_id` -> draw it.
   - Otherwise an unpaired result whose `|ts_det - ts_frame| <= tolerance_us` (default
     17 000 us, half a frame period at 30 fps) -> draw it.
   - Window expired -> display without boxes, count `unmatched_frames`.
3. When a newer frame becomes ready, any older frames still waiting are skipped (count as
   `skipped_frames`) — display never goes backward and never lags behind more than the window.
4. A result that arrives for a frame already displayed or evicted is dropped (count
   `late_results`). It is never drawn on a later frame.

Why a hold window instead of "draw the latest boxes on the latest frame": the drone moves;
boxes from a frame 2-3 frames earlier are visibly misplaced and would mislead the operator.
The window adds display latency equal to the TX8 inference latency (~p99 80 ms) — this is the
honest cost of correct overlays. Make the window configurable and show it in the HUD.

Tuning:
- `match_window_ms` slightly above TX8 p99 latency + network jitter. Too small -> many frames
  without boxes; too large -> sluggish video.
- When TX8 reports inference fps < CH1 fps (e.g. dropped CH2 frames), some CH1 frames have
  no result by design — that is expected, not an error. Show both rates.

## 3. Clock offset estimation (NTP-style)

TX8 timestamps use its `CLOCK_MONOTONIC`; the PC has its own clock. Using a PING control
message and its CONTROL_ACK:

```
t1 = PC time when PING sent          (in CONTROL payload, echoed back)
t2 = TX8 time when PING received     (in CONTROL_ACK)
t3 = TX8 time when ACK sent          (in CONTROL_ACK)
t4 = PC time when ACK received

rtt    = (t4 - t1) - (t3 - t2)
offset = ((t2 - t1) + (t3 - t4)) / 2        # TX8_clock - PC_clock
```

- Send a PING every 1 s. Keep the last 16 samples; use the offset of the sample with the
  **smallest rtt** (least queuing, so the symmetric-delay assumption is closest to true).
- Error bound of one sample: +/- rtt/2. Display it.
- Both clocks drift slowly (ppm); the sliding window tracks it. After a reconnect, clear the
  samples (TX8 may have rebooted: its monotonic clock restarts).
- On Windows use `time.perf_counter_ns()` (QueryPerformanceCounter-based, high resolution).
  Avoid `time.time()` (wall clock can jump) and, before Python 3.13, `time.monotonic()`
  (coarse ~15.6 ms resolution on Windows).
- Large JPEG transfers share the TCP connection with PINGs, so PING samples taken right behind
  a big frame show inflated rtt — the min-rtt filter handles this.

## 4. Latency figures to show

| Figure | Formula | Label |
|---|---|---|
| TX8-internal p50/p99 | from STATUS `lat_p50_ms/lat_p99_ms` | measured on TX8 |
| Video end-to-end | `t_display_pc - (ts_frame_us - offset)` | **estimate** (+/- rtt/2) |
| Detection end-to-end | `t_det_rx_pc - (ts_det_us - offset)` | **estimate** |
| Network rtt | min rtt of the window | measured |

`t_display_pc` = PC time just after `cv2.imshow` was called for that frame (actual photon
time on the monitor is later: display refresh, compositor — not measurable in software).
Show the estimates with a `~` prefix and the error bound, e.g. `e2e ~182 ms (+/-3)`.

## 5. Handling drops and gaps

- CH1 `frame_id` gaps: count `ch1_gaps` (frames lost on TX8 or in transit; TCP does not lose
  messages, so gaps are TX8-side drops, also signalled by flag AFTER_DROP).
- JPEG decode failure (`cv2.imdecode` returns `None`): count, skip the frame, keep going.
- After reconnect: clear `frames`, `results`, clock samples and fps counters; frame ids restart
  or jump — do not treat that as a gap storm.
- Memory: all buffers bounded; the receive queue between network thread and display thread is
  bounded and drops the oldest JPEG when full (never block the network loop).

## 6. FPS computation

- Count displayed frames, received CH1 frames and received DETECTIONS over a 1 s sliding window
  (deque of local timestamps). Show `rx fps`, `display fps`, `det fps`.
- Compare with TX8 STATUS fps: rx lower than TX8 sent -> network or viewer bottleneck.

## 7. Recording (optional)

- Record raw messages, not rendered frames: append each received message to a file with
  a small framing (`<Q t_rx_ns><I len><bytes>`), so a session can be replayed bit-exactly
  through the same matching code. Optionally also save JPEGs as files named by `frame_id`.
- Write from a dedicated thread with a bounded queue; drop (and count) if the disk is slow.
