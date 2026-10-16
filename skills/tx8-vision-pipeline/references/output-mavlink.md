# MAVLink output (metadata + inference control)

When the user selects MAVLink as the output transport, detections and pipeline status go out
as custom MAVLink 2 messages, and inference start/stop can come from the flight controller
or GCS as `COMMAND_LONG`. **Video is never sent over MAVLink**: CH1 MJPEG keeps flowing over
the WebSocket channel (`output-websocket.md`), aligned with metadata by `time_usec`/`frame_id`
from the same TX8 clock.

Sources: https://mavlink.io/en/guide/define_xml_element.html (dialect XML rules),
https://mavlink.io/en/getting_started/generate_libraries.html (mavgen),
https://mavlink.io/en/guide/message_signing.html (signing),
https://mavlink.io/en/guide/routing.html (routing).

## 1. Ask first: destination

**The destination must be asked of the programmer — never decide it silently.**
| Option | Path | Consequences |
|---|---|---|
| UART to flight controller | TX8 UART -> FC (PX4 / ArduPilot) -> telemetry radio -> GCS | FC must be configured to run MAVLink 2 on that serial port and to forward/route custom messages; radio bandwidth is small (see §5). Commands from the GCS arrive routed by the FC. |
| UDP to ground station | TX8 IP link -> GCS (`udpout`/`udpin`, ask the port) | No FC configuration; bandwidth is the IP link's; FC is not involved in control unless it also speaks to TX8. |
| Both | separate links, same messages | needs a small router (e.g. a MAVLink router service) — ask before adding one |

Also ask: system id / component id to use (typically component `MAV_COMP_ID_ONBOARD_COMPUTER`
= 191, system id = the vehicle's), serial device and baud rate (check on the board:
`ssh umpi 'ls -l /dev/ttyS* /dev/ttyAMA* /dev/ttyUSB* 2>/dev/null'`), whether signing is required.
FC-side configuration (PX4 `MAV_x_*` parameters, ArduPilot `SERIALn_PROTOCOL/BAUD`) is done by
the flight-control owner; verify parameter names in the firmware docs for the deployed version.

## 2. Custom dialect XML

Rules (from the MAVLink XML guide): payload <= 255 bytes, 1-64 fields, MAVLink 2 message ids
are 24-bit; for a private dialect any unused id range is allowed — pick a block that does not
collide with any dialect you include (grep the included XML files for `id="`). Field names are
lowercase with underscores. Prefix names to avoid clashes with upstream messages.

`umpi.xml` (placed next to `common.xml` in `message_definitions/v1.0/`):

```xml
<?xml version="1.0"?>
<mavlink>
  <include>common.xml</include>
  <enums>
    <enum name="UMPI_VISION_STATE">
      <entry value="0" name="UMPI_VISION_STATE_IDLE"/>
      <entry value="1" name="UMPI_VISION_STATE_STARTING"/>
      <entry value="2" name="UMPI_VISION_STATE_RUNNING"/>
      <entry value="3" name="UMPI_VISION_STATE_STOPPING"/>
      <entry value="4" name="UMPI_VISION_STATE_FAULT"/>
    </enum>
  </enums>
  <messages>
    <message id="52000" name="UMPI_OBJECT_DETECTION">
      <description>Detections for one inferred CH2 frame (or one part of it).</description>
      <field type="uint64_t" name="time_usec" units="us">CH2 capture time, TX8 CLOCK_MONOTONIC.</field>
      <field type="uint32_t" name="frame_id">Paired CH1 frame id (WebSocket JPEG_CH1), 0 if unpaired.</field>
      <field type="uint8_t" name="count">Valid entries in the arrays (0..10).</field>
      <field type="uint8_t" name="flags">bit0 paired, bit1 truncated by top-K, bit2 more parts follow.</field>
      <field type="uint8_t" name="part">Part index when a frame needs more than one message.</field>
      <field type="uint8_t[10]" name="class_id">Class index (reduced model classes).</field>
      <field type="float[10]" name="score">Confidence 0..1.</field>
      <field type="float[10]" name="x1">Left, normalized 0..1 in CH1 coordinates.</field>
      <field type="float[10]" name="y1">Top, normalized 0..1.</field>
      <field type="float[10]" name="x2">Right, normalized 0..1.</field>
      <field type="float[10]" name="y2">Bottom, normalized 0..1.</field>
    </message>
    <message id="52001" name="UMPI_VISION_STATUS">
      <description>Pipeline state, sent on change and at 1 Hz.</description>
      <field type="uint64_t" name="time_usec" units="us">TX8 CLOCK_MONOTONIC.</field>
      <field type="uint8_t" name="state" enum="UMPI_VISION_STATE">Pipeline state.</field>
      <field type="uint8_t" name="fault">Fault code (same values as protocol.h FaultCode).</field>
      <field type="float" name="fps_infer" units="Hz">Inference rate.</field>
      <field type="float" name="lat_p99_ms" units="ms">TX8-internal latency p99.</field>
      <field type="float" name="mx3_temp_c" units="degC">Max MX3 chip temperature, NaN if unknown.</field>
      <field type="uint32_t" name="dropped">Cumulative dropped CH2 frames.</field>
    </message>
  </messages>
</mavlink>
```

Payload size check for `UMPI_OBJECT_DETECTION`: 8 + 4 + 3 + 10 + 5 x 40 = 225 bytes <= 255.
Options when more than 10 detections are needed:
- Several messages per frame (`part`, `flags.bit2`) — receiver reassembles by `time_usec`.
- Quantize: boxes as `uint16_t` (0..65535 = 0..1), score as `uint8_t` -> 20 detections fit
  (8 + 4 + 3 + 20 + 20 + 4 x 40 = 215 B).
- One message per detection (simple, but 12-byte header + 2-byte CRC overhead each).
With 1-3 classes and top-K <= 10, one message per frame is the normal case.
MAVLink 2 truncates trailing zero bytes of the payload on the wire, so unused array slots at
the end cost little — but field reordering by size means arrays are not necessarily last;
do not rely on truncation for bandwidth estimates.

## 3. Generate the C library and use it from C++

On the dev machine (Python; pymavlink provides mavgen):
```
python3 -m pymavlink.tools.mavgen --lang=C --wire-protocol=2.0 \
    --output=generated/include/mavlink/v2.0 message_definitions/v1.0/umpi.xml
```
- Commit the generated headers (header-only C library) or regenerate in CI; record the
  pymavlink version used.
- Include from C++ as a **system include** (`-isystem generated/include/mavlink/v2.0`) so its
  packed-struct code does not break `-Wall -Wextra -Werror`; wrap use in one translation unit.
- Generated function names follow `mavlink_msg_<name>_pack(...)`, `_encode(...)`,
  `_decode(...)`; plus `mavlink_msg_to_send_buffer()` and `mavlink_parse_char()` for parsing.
  Read the generated header for the exact parameter list — it depends on field order.

```cpp
// sketch, after checking the generated umpi/mavlink.h
mavlink_message_t msg;
mavlink_msg_umpi_object_detection_pack(sysid, compid, &msg, ts_us, frame_id, count, flags,
                                       part, cls, score, x1, y1, x2, y2);
uint8_t buf[MAVLINK_MAX_PACKET_LEN];
const uint16_t n = mavlink_msg_to_send_buffer(buf, &msg);
link.write_nonblocking(buf, n);     // UART or UDP; drop on EAGAIN, count it
```

Also send `HEARTBEAT` at 1 Hz (type `MAV_TYPE_ONBOARD_CONTROLLER`, autopilot
`MAV_AUTOPILOT_INVALID`) so routers and GCSs discover the component.

## 4. Inference control via COMMAND_LONG

- Use a command id from the user range (`MAV_CMD_USER_1` = 31010 ... `MAV_CMD_USER_5` = 31014 in
  common.xml) or define a private command in the dialect's `MAV_CMD` enum — ask which the
  system integrator prefers (another component may already use USER_1).
- `param1`: 1 = start, 0 = stop. Other params reserved (0).
- Accept only when `target_system`/`target_component` match TX8 (or 0 = broadcast, if agreed).
- Reply `COMMAND_ACK` with `MAV_RESULT_ACCEPTED` immediately after posting
  `InferenceControl` (`inference-control.md`); `MAV_RESULT_DENIED` if rejected,
  `MAV_RESULT_UNSUPPORTED` for unknown params. The real state follows in `UMPI_VISION_STATUS`.
- Senders retransmit COMMAND_LONG if no ack arrives; handling must be idempotent (it is: last
  command wins and repeated `start` is a no-op).

## 5. Rates and bandwidth

| Message | UDP to GCS | UART via FC + radio |
|---|---|---|
| UMPI_OBJECT_DETECTION | every inferred frame (30 Hz) | rate-limited, e.g. 5 Hz or only on change; ask the budget |
| UMPI_VISION_STATUS | 1 Hz + on change | 1 Hz + on change |
| HEARTBEAT | 1 Hz | 1 Hz |

Arithmetic: one detection message is ~225 B payload + 12 B header + 2 B CRC (+13 B with
signing) ~ 240 B. At 30 Hz that is ~7.2 KB/s — more than a typical 57600-baud telemetry radio
(~5.7 KB/s) can carry alongside the autopilot's own traffic. Over UART to the FC, check the
link baud rate and the radio budget with the flight-control owner.

## 6. Signing (optional)

MAVLink 2 message signing authenticates packets with a shared secret key. Enable only if the
integrator requires it; key provisioning and storage on TX8 are security decisions to ask
about (never hard-code a key in source). Signing adds 13 bytes per packet.

## 7. Video alignment

The base station receives JPEG_CH1 over WebSocket (with `frame_id`, `ts_us`) and detections
over MAVLink (with `frame_id`, `time_usec`). Both use the TX8 `CLOCK_MONOTONIC` time base, so
the receiver joins them exactly like DETECTIONS over WebSocket. Note: skill
`basestation-viewer` currently reads only the WebSocket protocol — a MAVLink-fed viewer needs
an extra receiver (e.g. pymavlink with the same generated dialect); plan it with the programmer.

## 8. Checklist
- [ ] Destination (UART-to-FC vs UDP-to-GCS), ids, port/baud, signing: asked and recorded.
- [ ] Dialect ids checked for collisions; payload <= 255 B verified by mavgen.
- [ ] Generated headers included as system headers; build clean with `-Werror`.
- [ ] Non-blocking writes; drops counted; HEARTBEAT at 1 Hz.
- [ ] COMMAND_LONG start/stop acked and idempotent; rates fit the link budget.
