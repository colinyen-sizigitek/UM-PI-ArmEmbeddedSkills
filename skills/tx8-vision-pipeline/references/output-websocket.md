# WebSocket output (video + metadata + control)

One WebSocket connection between TX8 (server) and the base station (client) carries CH1
MJPEG frames verbatim, detection metadata, status, and control commands. The format is
defined in `assets/protocol.h` — **that header is the contract** shared with skill
`basestation-viewer` (whose `references/protocol.md` mirrors it). Change it only together
with the viewer and bump `kProtocolVersion`.

Default endpoint: `ws://<tx8-ip>:8081/ws` (port 8081 matches the UM-PI reference app; make it
configurable).

## 1. Framing

- WebSocket **binary** messages only; one protocol message per WebSocket message.
- permessage-deflate **disabled** (JPEG does not compress; it only costs CPU and latency).
- Every message: 20-byte header + payload. Little-endian. Python `struct` format `'<BBHIQI'`.

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | `type` | message type (below) |
| 1 | 1 | `flags` | per type |
| 2 | 2 | `reserved` | 0 on send, ignored on receive |
| 4 | 4 | `frame_id` | CH1 frame counter (JPEG_CH1), paired CH1 id (DETECTIONS), else 0 |
| 8 | 8 | `ts_us` | microseconds, TX8 `CLOCK_MONOTONIC` |
| 16 | 4 | `len` | payload bytes; must equal message size - 20 |

Encode with byte shifts/memcpy (helpers in `protocol.h`). A C++ struct with these members has
`sizeof == 24` because of `uint64_t` alignment — never `memcpy` a struct onto the wire.

## 2. Message types

| Type | Name | Dir | Payload | `ts_us` |
|---|---|---|---|---|
| 0x01 | JPEG_CH1 | TX8 -> BS | MJPEG bytes exactly as dequeued from V4L2 | CH1 V4L2 timestamp |
| 0x02 | DETECTIONS | TX8 -> BS | binary list (below) | CH2 V4L2 timestamp of the inferred frame |
| 0x03 | STATUS | TX8 -> BS | 48 B `StatusPayload` (`'<BBBBHH8fII'`) | time produced |
| 0x04 | DETECTIONS_JSON | TX8 -> BS | UTF-8 JSON, debug mode only | as DETECTIONS |
| 0x10 | CONTROL | BS -> TX8 | 16 B (`'<B3xIQ'`): cmd, seq, t1_us | BS clock (informational) |
| 0x11 | CONTROL_ACK | TX8 -> BS | 32 B (`'<BBHIQQQ'`): cmd, result, seq, t1, t2, t3 | t3 |

Receivers ignore unknown types (forward compatibility) and drop messages whose `len` does not
match. STATUS payloads longer than 48 B are allowed in future versions (read the first 48 B).

Flags:
- JPEG_CH1 `0x01 AFTER_DROP`: at least one CH1 frame was dropped on TX8 before this one.
- DETECTIONS `0x01 PAIRED`: `frame_id` names the CH1 frame paired with this result.
  Without it, the viewer matches by timestamp only.
- DETECTIONS `0x02 TRUNCATED`: more candidates passed the threshold than top-K allowed.

### DETECTIONS payload
```
u16 count
count x { u16 class_id; f32 score; f32 x1; f32 y1; f32 x2; f32 y2; }    // 22 bytes each
```
Python: `'<H'` then `'<Hfffff'` per detection. Boxes normalized 0..1 in **CH1** image
coordinates (mapping from CH2 in `preprocess-postprocess.md` §5). An empty list (`count = 0`)
is still sent for every inferred frame — it tells the viewer "no objects", which differs
from "no result".

### Pairing CH2 results with CH1 frames (sender side)
The sender keeps a ring of the last 16 `(ch1_frame_id, ch1_ts_us)`. For each DETECTIONS
message it picks the CH1 frame with the closest timestamp to the CH2 timestamp; if
`|dt| <= 17 ms` (half a frame period at 30 fps) it sets `frame_id` and `PAIRED`, otherwise
`frame_id = 0` without the flag. `ts_us` always stays the CH2 timestamp.

### STATUS
State (`Idle/Starting/Running/Stopping/Fault`), fault code, MX3 chips and clock, fps CH1 and
inference, TX8-internal latency p50/p99, CPU %, SoC and MX3 temperature, MX3 power, cumulative
drop counters. Unknown floats are NaN. Sent on every state change and at 1 Hz.

### CONTROL / CONTROL_ACK
Commands: 1 START, 2 STOP, 3 PING, 4 GET_STATUS. TX8 answers each with CONTROL_ACK carrying
`t1` (echoed BS time), `t2` (TX8 receive), `t3` (TX8 send) — NTP-style so the viewer can
estimate the clock offset and RTT. START/STOP are posted as `InferenceControl` events
(`inference-control.md`); `Ok` means accepted.

### DETECTIONS_JSON (debug only, enabled by a config flag)
```json
{"frame_id": 1234, "paired": true, "ts_us": 81234567890, "dets":
  [{"cls": 0, "score": 0.87, "box": [0.41, 0.22, 0.47, 0.39]}]}
```
Never enabled in flight builds by default; building JSON per frame costs CPU and allocations.

## 3. Connection policy

- Exactly one client. A new connection **replaces** the old one (the old socket is closed):
  after a radio drop the base station reconnects while the old TCP connection may still look
  alive on TX8.
- On connect: send one STATUS immediately. CH1 streaming to the client starts right away.
- On disconnect: return every queued V4L2 buffer, clear queues, keep capturing CH1 (frames are
  dropped at the sender). Inference state does **not** change on disconnect (product decision —
  confirm with the programmer whether loss of link should stop inference).
- Set `TCP_NODELAY`. Keep the socket send buffer moderate (do not inflate `SO_SNDBUF`): a huge
  kernel buffer hides congestion and adds latency. Inspect with `ss -tmi` on the board.
- WebSocket keepalive ping (library feature) every 2-5 s with a timeout, so a dead link is
  detected in seconds.

## 4. Back-pressure (never block capture)

Sender (T4) has three bounded queues, served in priority order:
1. control replies + STATUS (depth 8)
2. DETECTIONS (depth 8, drop-oldest)
3. JPEG_CH1 references (depth 4, drop-oldest; each holds a V4L2 buffer)

Only one WebSocket write is in flight at a time. While the write is pending, producers keep
pushing; full queues drop their oldest element (JPEG first by construction since it is the
largest and least valuable when stale). Additionally drop any queued JPEG older than 100 ms
(age = now - ts_us) — sending stale video wastes the link. Count drops and report them in
STATUS (`dropped_ch1`).

Capture threads only do non-blocking pushes. The sender never calls into capture code except
through the buffer-return SPSC queue.

## 5. Clock and timestamps

- `ts_us` = TX8 `CLOCK_MONOTONIC` in microseconds, taken from the V4L2 buffer timestamp for
  frames. It is not wall-clock time and is unrelated to the base-station clock.
- The viewer estimates `offset = tx8_clock - bs_clock` from PING/CONTROL_ACK
  (`((t2 - t1) + (t3 - t4)) / 2`, taking the minimum-RTT sample) and shows end-to-end latency
  as an **estimate**. TX8 never adjusts its clock for this.
- TX8-internal latency (target p99 <= 80 ms) is measured on TX8 only:
  `t_send_done - ts_us(CH2)`.

## 6. Server library options (C++ on Ubuntu 22.04 / aarch64)

| Library | Ubuntu 22.04 apt package | License | Notes |
|---|---|---|---|
| Boost.Beast (Boost 1.74) | `libboost-dev` (header-only part) | BSL-1.0 | Asio-based, async, gather writes of `[header][jpeg]` without copying; server frames are unmasked. Heavier compile times. |
| websocketpp 0.8.2 | `libwebsocketpp-dev` (universe) | BSD-3-Clause | Header-only on top of Asio; development largely stalled — check upstream activity. |
| libwebsockets 4.0.20 | `libwebsockets-dev` (universe) | MIT | C API, own event loop; writes need `LWS_PRE` bytes of headroom before the payload, which usually forces one copy of each JPEG. |
| uWebSockets | not in jammy apt — vendor/build from source | Apache-2.0 | Very fast; vendoring and aarch64 build must be verified. |

Recommendation: **Boost.Beast** (already in the Ubuntu archive, permissive license, gather
writes, mature). **Confirm with the programmer** before adding the dependency; check what is
installed: `ssh umpi 'dpkg -l | grep -E "libboost|websocket"'` (do not install without approval).
Check Beast signatures in `/usr/include/boost/beast/websocket/stream.hpp` for the installed
version.

Beast shape (verify against the installed headers):
```cpp
// one ws::stream<beast::tcp_stream> per client; io_context runs on T4
ws.binary(true);
std::array<boost::asio::const_buffer, 2> bufs{
    boost::asio::buffer(hdr, tx8::proto::kHeaderSize),
    boost::asio::buffer(frame.ptr, frame.bytesused)};       // V4L2 mmap bytes, no copy
ws.async_write(bufs, [this, frame](boost::system::error_code ec, std::size_t) {
  return_buffer_to_capture(frame);                           // SPSC return queue
  if (ec) on_client_error(ec); else write_next();
});
```

## 7. Test without hardware

The viewer skill ships `fake_tx8_server.py`, which speaks this protocol. Use it to test the
viewer, and use the viewer against the real TX8 to test this server. A protocol unit test on
TX8 should encode every message type with `protocol.h` and compare against byte arrays
produced by Python `struct.pack` with the formats above.
