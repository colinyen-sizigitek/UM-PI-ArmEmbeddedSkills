---
name: tx8-vision-pipeline
description: "Designs and implements the TX8 real-time drone vision pipeline in C++17: dual USB UVC MJPEG capture (CH1 1080p30 forwarded untouched, CH2 640x640 decoded with TurboJPEG for MX3), inference on/off state machine, host threshold/top-K, WebSocket or MAVLink metadata output, timestamps, latency accounting, back-pressure and error handling. Use when building or changing camera capture, JPEG decode, pre/post-processing glue, inference start/stop control, the detection/video output protocol, or latency/soak measurement on TX8. 關鍵字: 影像管線, 即時偵測, UVC 擷取, MJPEG 解碼, 推論開關, 狀態機, WebSocket 傳輸, MAVLink 輸出, 延遲量測, 丟幀, 背壓"
license: Proprietary - internal use only
compatibility: "Claude Code, OpenAI Codex, Google Antigravity. Target: TX8 (4x Cortex-A53, Ubuntu 22.04) + MemryX Cascade 100M (4x MX3)."
metadata:
  version: "1.0.0"
  domain: "embedded-vision"
  triggers: "vision pipeline, V4L2, UVC, MJPEG, TurboJPEG, libjpeg-turbo, inference control, WebSocket, MAVLink, latency, p99, soak test, frame drop, 影像管線, 推論開關, 延遲, 丟幀, 串流"
  role: "pipeline-architect"
  scope: "TX8 application code: capture, decode, pre/post glue, control, output, metrics"
  related-skills: "tx8-platform, tx8-cpp-performance, mx3-runtime-integration, mx3-model-selection, mx3-model-compile, basestation-viewer, tx8-code-review"
---

# TX8 Vision Pipeline

You are the architect and implementer of the TX8 drone vision pipeline: two MJPEG channels from
a USB UVC camera, CH1 (1080p30) forwarded verbatim to the base station, CH2 (640x640 @30)
decoded on the CPU and fed to the MemryX MX3 accelerator, detections sent as metadata over
WebSocket or MAVLink. You own threads, queues, buffer ownership, the inference on/off state
machine, the wire protocol and latency accounting. Reliability first, then performance, then
power. Targets: 30 fps sustained 10 min, TX8-internal p99 latency <= 80 ms (CH2 capture
timestamp -> metadata sent), start latency <= 3 s (start command -> first metadata).

## When to use
- Writing or changing V4L2 capture, TurboJPEG decode, u8 -> float32 preprocessing, output parsing.
- Implementing inference start/stop (WebSocket CONTROL, MAVLink COMMAND_LONG, local CLI/socket).
- Defining or extending the WebSocket protocol (`assets/protocol.h`) or a MAVLink dialect.
- Adding timestamps, latency histograms, soak tests, frame-drop or back-pressure policy.

## When NOT to use
- NEON kernel tuning, perf counters, compiler flags -> skill `tx8-cpp-performance`.
- `MxAccl` lifecycle, clock setting, callbacks, temperature/power API -> skill `mx3-runtime-integration`.
- Choosing a model, chip count or MX3 frequency -> skill `mx3-model-selection`.
- Compiling ONNX to DFP, cropping pre/post graphs -> skill `mx3-model-compile`.
- Windows receiver / display / overlay -> skill `basestation-viewer`.
- Board facts (kernel, USB topology, thermal zones) -> skill `tx8-platform`.

## Core workflow
1. **Check facts on the board** before writing code:
   `ssh umpi 'v4l2-ctl --list-devices; for d in /dev/video*; do v4l2-ctl -d $d --list-formats-ext; done'`,
   `ssh umpi 'lsusb -t'` (USB 3 vs 2 per camera), `ssh umpi 'dpkg -l | grep -E "turbojpeg|boost|websocket"'`.
   Confirm whether CH1 and CH2 are two `/dev/video*` nodes or one, and whether both share one
   sensor/FOV (ask the programmer if unclear; it decides box mapping).
2. Ask the programmer what is not decidable from the board: output transport (WebSocket or
   MAVLink; for MAVLink the destination UART-to-FC vs UDP-to-GCS), WebSocket library choice,
   CH2-in-CH1 crop geometry, model output layout (from the compiled DFP).
3. Lay out stages, threads and bounded queues per `references/architecture.md`. Write down
   buffer ownership for every queue before coding.
4. Implement capture (`references/v4l2-uvc-capture.md`), decode (`references/jpeg-decode.md`),
   pre/post glue (`references/preprocess-postprocess.md`), control state machine
   (`references/inference-control.md`), output (`references/output-websocket.md` or
   `references/output-mavlink.md`). Use `assets/protocol.h` verbatim for the WebSocket format.
5. Instrument every stage with CLOCK_MONOTONIC timestamps and fixed-bucket histograms
   (`references/latency-and-metrics.md`) from the first working version.
6. **Measure baseline** on TX8: per-stage p50/p99, fps, drops, CPU per core, temperatures,
   start latency. Then run `scripts/soak_test.sh` for 10 min.
7. Only if a target is missed: profile and optimize the worst stage (hand NEON work to
   `tx8-cpp-performance`), re-measure, compare. Fallback: 320x320 model + TurboJPEG 1/2 decode.
8. Once targets are met with margin, reduce power: lower MX3 clock (<= 400 MHz rule from
   `mx3-model-selection`), fewer worker threads; re-run the soak test.

## MUST DO
- Forward CH1 MJPEG bytes verbatim (no decode, no re-encode); validate SOI/EOI only.
- Use the V4L2 buffer timestamp (CLOCK_MONOTONIC) as the frame timestamp; carry it end to end.
- Bounded SPSC queues with drop-oldest; count every drop per stage and report it in STATUS.
- Preallocate all frame buffers (V4L2 mmap, RGB pool, float pool, send pool) at startup.
- One `InferenceControl{start|stop}` event type for all sources; one state machine; last command wins.
- Stop CH2 capture (STREAMOFF + release buffers) and release the MX3 object when inference is off.
- Timeouts on every wait (poll, queue pop, MX3 output, start sequence); every error -> STATUS/log.
- Send boxes normalized to CH1 coordinates; document the CH2 -> CH1 mapping used.
- Keep `assets/protocol.h` as the single source of truth; bump `kProtocolVersion` on any change
  and tell the programmer to update skill `basestation-viewer` in the same change.
- Report numbers measured on TX8 with the command used; label estimates as estimates.

## MUST NOT
- Never block a capture thread on network, decode or MX3; never block inside MX3 callbacks.
- No unbounded queues, no per-frame `new`/`malloc`/`std::vector` growth, no per-frame thread creation.
- No OpenCV in the production capture/decode/pre/post path (debug tools only).
- Do not send video over MAVLink. Do not send JSON detections in production (debug flag only).
- Do not pick the MAVLink destination, WebSocket library or model license silently.
- Do not invent V4L2/TurboJPEG/MemryX/MAVLink signatures; check `/usr/include/...` or official docs.
- Do not change system settings (USB autosuspend, CPU governor, isolcpus, mxa_manager.conf)
  without explicit approval; propose the change and the reason.

## Reference guide
| Topic | Reference | Load when |
|---|---|---|
| Stages, threads, cores, ownership, latency budget | [architecture.md](references/architecture.md) | Designing or reviewing the pipeline |
| V4L2 mmap streaming, UVC formats, USB bandwidth, reconnect | [v4l2-uvc-capture.md](references/v4l2-uvc-capture.md) | Writing capture code |
| TurboJPEG 2.1 decode, flags, scaled decode, TJ3 diffs | [jpeg-decode.md](references/jpeg-decode.md) | Decoding CH2 |
| u8 -> float NHWC, output parsing, threshold/top-K, box mapping | [preprocess-postprocess.md](references/preprocess-postprocess.md) | MX3 input/output glue |
| Start/stop sources, state machine, timeouts | [inference-control.md](references/inference-control.md) | On/off control |
| WebSocket binary protocol, library options, back-pressure | [output-websocket.md](references/output-websocket.md) | WebSocket output |
| Custom MAVLink dialect, mavgen, transport, COMMAND_LONG | [output-mavlink.md](references/output-mavlink.md) | MAVLink output |
| Per-stage timestamps, histograms, soak test, reporting | [latency-and-metrics.md](references/latency-and-metrics.md) | Measuring or reporting |

## Scripts
- `scripts/soak_test.sh` — runs on the board; launches the app command, samples per-core CPU,
  SoC temperature, MX3 temperature (`/sys/memx0/temperature` if present) and app RSS into CSV.
  ```
  scp scripts/soak_test.sh umpi:/tmp/
  ssh umpi 'bash /tmp/soak_test.sh -m 10 -i 1 -o /tmp/soak.csv -- ./vision_app --config app.json'
  ```
  `bash soak_test.sh --help` for options. It only writes the CSV and the app log.
- Asset `assets/protocol.h` (not a script) — C++17 header with the WebSocket wire protocol (header, DETECTIONS,
  STATUS, CONTROL, CONTROL_ACK) and endian-safe encode/decode helpers. Copy into the project.

## Output checklist
Report back to the programmer:
- Device/format facts found on the board (video nodes, formats, USB speed, library versions).
- Thread/core plan, queue depths and drop policy actually implemented.
- Per-stage p50/p99 latency, end-to-end TX8-internal p99, fps CH1/CH2, drop counts.
- Start latency (median and max over >= 10 start/stop cycles).
- Soak test summary: duration, CPU per core, SoC/MX3 temperature max, RSS growth.
- Open questions asked or still pending (transport destination, FOV alignment, library, license).
- Any deviation from the targets and the next optimization step proposed.
