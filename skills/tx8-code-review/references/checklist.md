# TX8 review checklist

Items marked ⚠ are BLOCKERS. IDs are stable — cite them in findings (e.g. `MX-2`).

## GEN — general / rules
- ⚠ GEN-1 No hard-coded hardware facts that vary: RAM size (2 GB EVT / 4 GB MP), device paths,
  PCIe link width, CPU count. Detect at runtime or read from config.
- ⚠ GEN-2 No invented API signatures (MemryX, TurboJPEG, V4L2). Uncertain calls are marked and
  checked against installed headers.
- GEN-3 Every error path is handled and reported (log + status to base station where user-visible).
- GEN-4 Config values (MX3 count, clock, transport, thresholds, ports) come from config/CLI, not literals.
- GEN-5 No system changes (packages, sysctl, isolcpus, MX3 power mode) performed by app code or
  scripts without an explicit flag and printed warning.

## BLD — build
- BLD-1 Flags: `-O2 -mcpu=cortex-a53 -mno-outline-atomics -Wall -Wextra -Werror`; `-O3` only on
  listed hot files; no `-march` beyond armv8-a; no `+dotprod/+fp16/+sve`.
- BLD-2 `+crypto` only if AES/SHA is used; erratum flags justified by the CPU revision.
- BLD-3 No `-ffast-math` globally; if used on a file, the numerical impact is documented and tested.
- BLD-4 Cross-compiles use a sysroot matching Ubuntu 22.04 (glibc 2.35), or the build is native on the board.
- BLD-5 Sanitizer/debug builds exist for tests; release builds do not link sanitizers.

## RT — real-time and concurrency
- ⚠ RT-1 No heap allocation, `std::string` growth, `std::vector` resize or `new` in the per-frame path;
  buffers come from pre-allocated pools.
- ⚠ RT-2 Queues between stages are bounded with an explicit overflow policy (drop-oldest for video).
- ⚠ RT-3 Every blocking wait/send/receive has a timeout; timeouts are handled, not ignored.
- RT-4 No mutex held across I/O, logging, or MX3 calls; prefer SPSC rings with acquire/release.
- RT-5 Thread affinity/priority choices are documented and measured; SCHED_FIFO threads have a
  watchdog and cannot starve comms.
- RT-6 Timestamps use `CLOCK_MONOTONIC` (V4L2 buffer timestamp for capture); no wall clock for latency.
- RT-7 Shared counters/flags are `std::atomic` with the right memory order; per-thread hot data is
  `alignas(64)` to avoid false sharing.
- RT-8 Logging in hot paths is rate-limited and non-blocking.

## PERF — performance (A53)
- PERF-1 Any optimization ships with before/after measurements (median, p99, fps, CPU %) on TX8.
- PERF-2 NEON uses Armv8.0 intrinsics only, handles tails, and has a scalar reference unit test.
- PERF-3 Inner loops are branch-free where data-dependent (thresholding, clamping).
- PERF-4 Memory layout supports streaming: 64 B aligned rows, SoA where vectorized, passes fused to
  avoid re-reading 1+ MB frames (L2 is 1 MB).
- PERF-5 No redundant copies of frame data; CH1 MJPEG bytes are forwarded by reference.
- PERF-6 Float conversion for MX3 input is done once, directly into the MX3 input buffer.

## VIS — vision pipeline
- ⚠ VIS-1 No video re-encode on TX8; CH1 is forwarded verbatim.
- ⚠ VIS-2 No OpenCV in production pre/post paths (debug only behind a flag).
- VIS-3 CH2 capture runs only while inference is RUNNING; STREAMOFF and buffers released on stop.
- VIS-4 Corrupt/partial MJPEG frames are detected and dropped (decode error ≠ crash).
- VIS-5 USB disconnect / device loss is recovered with back-off and reported.
- VIS-6 Detection coordinates are mapped to CH1 coordinates; the FOV-alignment assumption is documented.

## MX — MemryX MX3
- ⚠ MX-1 Clock ≤ 400 MHz, chosen by the frequency rule (lowest PASS with fps ≥ target × 1.5);
  never MemryX's ARM default; set right after the accelerator object is constructed and before
  any input is sent (order per installed header; see `mx3-runtime-integration`).
- ⚠ MX-2 MX3 object created only on inference start and released on stop (no idle accelerator).
- ⚠ MX-3 No blocking, allocation or I/O inside MX3 input/output callbacks.
- MX-4 DFP matches the configured chip count (or data-parallel 1-chip DFP is explicit).
- MX-5 Start latency (command → first metadata) is measured and ≤ 3 s.
- MX-6 Faults handled: timeout → step down 400→300 MHz and reconnect; temperature anomaly reported;
  chip reports 255 °C → FAULT state, reboot required, reported to base station.
- MX-7 Deprecated `stop()` is not relied on; shutdown = stop feeding, wait, destroy.
- MX-8 Monitoring calls (power, temperature) run at low rate off the hot path.
- MX-9 The model's normalization/input layout match the DFP manifest.

## OUT — transport
- OUT-1 WebSocket wire format matches `tx8-vision-pipeline/assets/protocol.h` (little-endian header
  `type|flags|reserved|frame_id|ts_us|len`).
- OUT-2 Send back-pressure drops old video before metadata; capture is never blocked by the network.
- ⚠ OUT-3 MAVLink destination (UART to FC vs UDP to GCS) was chosen by the programmer and is configurable.
- OUT-4 MAVLink messages respect the 255 B payload limit; no video over MAVLink.
- OUT-5 Inference control: last command wins, idempotent, state changes reported.

## PY — Python (x86 tools, prototypes, viewer)
- PY-1 Python is not used in TX8 production paths.
- PY-2 Viewer: asyncio loop never blocked by decode/display; reconnect with back-off.
- PY-3 Viewer matches metadata to frames by frame_id; unmatched metadata dropped.
- PY-4 Type hints, argparse, no hard-coded IPs; requirements pinned in `requirements.txt`.

## MDL — models and compile artifacts
- MDL-1 DFPs were compiled on x86/WSL; artifacts carry a manifest (model, classes, input shape,
  normalization, chip count, SDK version, sha256).
- ⚠ MDL-2 Model licence was confirmed with the programmer (AGPL/GPL risk flagged for commercial use).
- MDL-3 Accuracy after compile was compared to the float baseline on a held-out set.
