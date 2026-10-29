# TX8 WebSocket wire protocol (Python mirror)

**Source of truth:** `assets/protocol.h` in skill `um-pi-vision-pipeline` (C++17 header). This
file mirrors it for Python. If the two ever disagree, `protocol.h` wins — fix this file and
`scripts/viewer.py` / `scripts/fake_tx8_server.py` in the same change, and check the version
number. Protocol version described here: **1**.

## 1. Transport

- WebSocket, TX8 is the server, base station is the client: `ws://<tx8-ip>:8081/ws`
  (port 8081 matches the UM-PI reference app; configurable on both sides).
- Binary messages only; one protocol message per WebSocket message.
- permessage-deflate off (`compression=None` in the `websockets` library).
- Exactly one client: a new connection replaces the previous one on TX8.
- Messages can be large (1080p MJPEG). The `websockets` default `max_size` is 1 MiB — set it
  to at least 8 MiB on the client.

## 2. Header (20 bytes, little-endian)

```python
import struct
HEADER = struct.Struct("<BBHIQI")      # type, flags, reserved, frame_id, ts_us, len
assert HEADER.size == 20
```

| Offset | Size | Field | Meaning |
|---|---|---|---|
| 0 | 1 | `type` | message type |
| 1 | 1 | `flags` | per type |
| 2 | 2 | `reserved` | 0 on send; ignore on receive |
| 4 | 4 | `frame_id` | CH1 frame counter (JPEG_CH1); paired CH1 id (DETECTIONS, if PAIRED); else 0 |
| 8 | 8 | `ts_us` | microseconds on the **TX8** `CLOCK_MONOTONIC` clock |
| 16 | 4 | `len` | payload length; must equal `len(message) - 20` |

Validation: drop a message if it is shorter than 20 bytes, if `len != len(msg) - 20`, or if
`len > 4 MiB` (`kMaxPayload`). Ignore unknown `type` values (forward compatibility).

## 3. Message types

| Type | Name | Direction | Payload | `ts_us` |
|---|---|---|---|---|
| 0x01 | JPEG_CH1 | TX8 -> BS | MJPEG bytes, verbatim from the camera | CH1 capture time |
| 0x02 | DETECTIONS | TX8 -> BS | binary detections | CH2 capture time of the inferred frame |
| 0x03 | STATUS | TX8 -> BS | 48 bytes | time produced |
| 0x04 | DETECTIONS_JSON | TX8 -> BS | UTF-8 JSON (debug mode only) | as DETECTIONS |
| 0x10 | CONTROL | BS -> TX8 | 16 bytes | BS clock (informational) |
| 0x11 | CONTROL_ACK | TX8 -> BS | 32 bytes | t3 (TX8 send time) |

Flags:
| Type | Bit | Name | Meaning |
|---|---|---|---|
| JPEG_CH1 | 0x01 | AFTER_DROP | TX8 dropped >= 1 CH1 frame before this one |
| DETECTIONS(_JSON) | 0x01 | PAIRED | `frame_id` names the CH1 frame these results belong to |
| DETECTIONS(_JSON) | 0x02 | TRUNCATED | more candidates than top-K; list was cut |

## 4. Payloads

### DETECTIONS
```python
DET_COUNT = struct.Struct("<H")        # count
DET_ITEM = struct.Struct("<Hfffff")    # class_id, score, x1, y1, x2, y2  (22 bytes)
# payload size must be 2 + 22 * count
```
- Boxes are normalized 0..1 in **CH1** image coordinates (multiply by the decoded CH1 frame
  width/height). `x1 <= x2`, `y1 <= y2`.
- `count == 0` means "inferred, nothing found" — still a valid result for that frame.

### STATUS (48 bytes)
```python
STATUS = struct.Struct("<BBBBHH8fII")
# state, fault, mx3_chips, proto_version, mx3_clock_mhz, reserved,
# fps_ch1, fps_infer, lat_p50_ms, lat_p99_ms, cpu_pct, soc_temp_c, mx3_temp_c, mx3_power_mw,
# dropped_ch1, dropped_ch2
```
- `state`: 0 IDLE, 1 STARTING, 2 RUNNING, 3 STOPPING, 4 FAULT.
- `fault`: 0 none, 1 camera CH1, 2 camera CH2, 3 MX3 open, 4 MX3 timeout, 5 MX3 thermal,
  6 decode, 7 start timeout, 8 internal.
- `cpu_pct` is total over 4 cores (0..400). Unknown floats are NaN.
- `lat_p50_ms/lat_p99_ms`: TX8-internal latency (CH2 capture -> metadata sent).
- Payloads longer than 48 bytes may appear in later versions: parse the first 48.

### CONTROL (16 bytes, base station -> TX8)
```python
CONTROL = struct.Struct("<B3xIQ")      # cmd, (3 pad bytes), seq, t1_us
```
- `cmd`: 1 START, 2 STOP, 3 PING, 4 GET_STATUS.
- `seq`: chosen by the base station, echoed in the ack.
- `t1_us`: base-station clock at send time (opaque to TX8, echoed back).
- Header for CONTROL: `type=0x10`, `flags=0`, `frame_id=0`, `ts_us=t1_us`, `len=16`.

### CONTROL_ACK (32 bytes, TX8 -> base station)
```python
CONTROL_ACK = struct.Struct("<BBHIQQQ")  # cmd, result, reserved, seq, t1_us, t2_us, t3_us
```
- `result`: 0 OK (accepted), 1 REJECTED, 2 INVALID.
- `t2_us` = TX8 receive time, `t3_us` = TX8 send time (TX8 clock). The base station stamps
  `t4` on receipt. Clock offset/RTT math: `sync-and-latency.md`.
- For START/STOP, OK means accepted; the actual state change arrives in STATUS.

### DETECTIONS_JSON (debug)
```json
{"frame_id": 1234, "paired": true, "ts_us": 81234567890,
 "dets": [{"cls": 0, "score": 0.87, "box": [0.41, 0.22, 0.47, 0.39]}]}
```

## 5. Python helpers (as used in `scripts/viewer.py`)

```python
def parse(msg: bytes):
    if len(msg) < HEADER.size:
        return None
    mtype, flags, _res, frame_id, ts_us, length = HEADER.unpack_from(msg, 0)
    if length != len(msg) - HEADER.size or length > MAX_PAYLOAD:
        return None
    return mtype, flags, frame_id, ts_us, memoryview(msg)[HEADER.size:]

def build(mtype: int, payload: bytes, frame_id: int = 0, ts_us: int = 0, flags: int = 0) -> bytes:
    return HEADER.pack(mtype, flags, 0, frame_id, ts_us, len(payload)) + payload
```

## 6. Keeping in sync

- When `protocol.h` changes: update the tables above, the `struct` formats, the viewer, the fake
  server, and bump the version number in both places.
- A cross-check test: encode each message in C++ with `protocol.h` on TX8 (or in WSL), dump the
  bytes, and compare against `struct.pack` output from this file's formats.
