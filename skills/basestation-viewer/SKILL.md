---
name: basestation-viewer
description: "Builds and maintains the Windows base-station / dev-test receiver in Python 3.11+ (asyncio, websockets, OpenCV, numpy) for the TX8 vision pipeline: connects to the TX8 WebSocket, shows CH1 1080p MJPEG with detection overlays matched by frame_id/timestamp, sends inference START/STOP, shows status, fps and estimated end-to-end latency, records sessions, and includes a fake TX8 server for hardware-free tests. Use when writing or debugging the PC-side viewer, overlay sync, clock-offset/latency estimation, or protocol tests against TX8. 關鍵字: 地面站, 基地台顯示, 影像接收, 偵測框疊加, 時間同步, 延遲估計, WebSocket 用戶端, 模擬伺服器, 錄影"
license: Proprietary - internal use only
compatibility: "Claude Code, OpenAI Codex, Google Antigravity. Target: TX8 (4x Cortex-A53, Ubuntu 22.04) + MemryX Cascade 100M (4x MX3)."
metadata:
  version: "1.0.0"
  domain: "base-station"
  triggers: "base station, viewer, ground station, overlay, websocket client, clock offset, end-to-end latency, fake server, OpenCV display, 地面站, 基地台, 疊加, 時間同步, 延遲估計"
  role: "desktop-python-developer"
  scope: "Windows/desktop Python receiver and test server for the TX8 WebSocket protocol"
  related-skills: "tx8-vision-pipeline, tx8-platform, tx8-code-review"
---

# Base-Station Viewer

You build the PC side of the UM-PI drone vision link: a Python 3.11+ desktop application
(Windows first) that receives CH1 MJPEG video and detection metadata from TX8 over one
WebSocket, draws boxes only on the frame they belong to, controls inference start/stop, and
reports status, frame rates and an honest latency estimate. This is not TX8 code: normal
desktop Python quality applies (type hints, asyncio, bounded queues, no blocking in the event
loop), but the wire protocol is a hard contract owned by skill `tx8-vision-pipeline`.

## When to use
- Writing, extending or debugging the viewer (`scripts/viewer.py`) or a derived GUI.
- Testing the TX8 WebSocket server, or testing the viewer without hardware
  (`scripts/fake_tx8_server.py`).
- Frame/metadata matching, clock-offset and end-to-end latency estimation, session recording.

## When NOT to use
- Anything running on TX8 (capture, decode, MX3, the WebSocket server) -> skill `tx8-vision-pipeline`.
- Changing the wire protocol itself -> change `assets/protocol.h` in `tx8-vision-pipeline` first,
  then mirror it here (`references/protocol.md`, both scripts).
- MAVLink reception: not covered by this viewer; see `tx8-vision-pipeline` references on MAVLink.
- Board facts / SSH setup -> skill `tx8-platform`.

## Core workflow
1. Check the environment on the dev machine (advise, do not install silently):
   `python --version` (>= 3.11), `pip show websockets opencv-python numpy`. If missing, propose
   `python -m venv .venv` + `pip install -r scripts/requirements.txt` and ask before running it.
2. Confirm the protocol version: compare `references/protocol.md` with the current
   `assets/protocol.h` from skill `tx8-vision-pipeline`. If they differ, sync first.
3. Test without hardware: `python scripts/fake_tx8_server.py` then `python scripts/viewer.py`;
   exercise start/stop (`s`/`x`), drops (`--drop-rate 0.05`), unpaired results (`--unpaired`),
   faults (`--fault-after-s 20`), reconnect (restart the server).
4. Connect to the board: `python scripts/viewer.py --url ws://<tx8-ip>:8081/ws`. Ask the
   programmer for the TX8 IP/port if unknown; do not scan the network.
5. **Measure**: let it run >= 10 min alongside the TX8 soak test; note rx/shown/det fps,
   matched vs no-box frames, late results, rtt, e2e estimate, TX8 p50/p99 from STATUS.
6. Tune `--match-window-ms` from the measured TX8 p99 + network jitter; re-measure.
7. For new features, keep the network thread / UI thread split and bounded queues; re-run the
   fake-server tests after every change.

## MUST DO
- Treat `assets/protocol.h` (skill `tx8-vision-pipeline`) as the source of truth; keep
  `references/protocol.md` and both scripts in sync with it; check `proto_version` in STATUS.
- Validate every message (`len` vs size, payload sizes); ignore unknown types; count bad messages.
- Draw detections only on their matching frame (PAIRED `frame_id`, else timestamp within
  tolerance); otherwise show the frame without boxes and count it.
- Run the asyncio network loop in its own thread; decode and display in the UI thread
  (OpenCV HighGUI calls stay in one thread); bounded queues with drop-oldest between them.
- Label end-to-end latency as an estimate with its error bound (+/- rtt/2).
- Reconnect automatically with exponential backoff and jitter; reset sync state on reconnect.
- Use `time.perf_counter_ns()` for local timing on Windows.

## MUST NOT
- Never block the event loop (no `cv2.imdecode`, file I/O or `time.sleep` in coroutines).
- Never draw the latest boxes on a newer frame "to look smooth".
- No unbounded queues or unbounded dictionaries keyed by frame id.
- Do not compute latency with `time.time()` or by comparing TX8 and PC clocks directly.
- Do not change the protocol only on the viewer side.
- Do not install packages, open firewall ports or change network settings without asking.

## Reference guide
| Topic | Reference | Load when |
|---|---|---|
| Wire protocol mirror, `struct` formats, message types | [protocol.md](references/protocol.md) | Parsing/sending messages, protocol sync |
| Frame/metadata matching, clock offset, latency display, drops | [sync-and-latency.md](references/sync-and-latency.md) | Overlay correctness, latency numbers |

## Scripts
Install once (ask first): `python -m pip install -r scripts/requirements.txt`.
- `scripts/viewer.py` — reference viewer.
  ```
  python scripts/viewer.py --url ws://<tx8-ip>:8081/ws            # display; keys s / x / q
  python scripts/viewer.py --url ws://<tx8-ip>:8081/ws --start     # send START on first connect
  python scripts/viewer.py --no-display --record rec/              # headless stats + raw recording
  python scripts/viewer.py --help
  ```
  Default URL `ws://127.0.0.1:8081/ws` targets the local fake server. Port 8081 matches the
  UM-PI reference app. Other options: `--match-window-ms`, `--tolerance-ms`, `--classes`.
- `scripts/fake_tx8_server.py` — synthetic TX8 (moving boxes, START/STOP state machine,
  STATUS, CONTROL_ACK with t2/t3, clock offset +7000 s so offset estimation is visible).
  ```
  python scripts/fake_tx8_server.py [--host 0.0.0.0] [--autostart] [--drop-rate 0.05]
                                    [--unpaired] [--json] [--fault-after-s 20]
  ```
- `scripts/requirements.txt` — websockets>=13, opencv-python, numpy.

## Output checklist
Report back to the programmer:
- Python and package versions used; protocol version seen in STATUS.
- Test matrix run against the fake server (start/stop, drops, unpaired, JSON, fault, reconnect)
  with pass/fail.
- On real hardware: rx/shown/det fps, matched vs no-box ratio, late results, rtt, e2e estimate
  (with error bound), TX8 p50/p99 from STATUS, session duration.
- Chosen `--match-window-ms` and why.
- Any protocol mismatch found and the sync change made (both skills).
- Open questions (TX8 IP/port, authentication of control commands, recording policy).
