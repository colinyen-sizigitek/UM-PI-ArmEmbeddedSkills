// protocol.h - TX8 <-> base-station WebSocket wire protocol, version 1.
//
// SINGLE SOURCE OF TRUTH for the protocol shared by:
//   - skill `um-pi-vision-pipeline` (C++17 sender on TX8)
//   - skill `um-pi-basestation-viewer` (Python receiver, references/protocol.md mirrors this file)
// Any change here MUST bump kProtocolVersion and be mirrored in the viewer.
//
// Transport: one WebSocket connection, ws://<tx8-ip>:8081/ws, binary frames only,
// permessage-deflate disabled. Every WebSocket binary message is exactly:
//
//   [20-byte header][payload of `len` bytes]
//
// All multi-byte fields are LITTLE-ENDIAN. Floats are IEEE-754 binary32.
// Encoding uses explicit byte shifts + memcpy, never struct casts: the in-memory
// C++ struct layout (padding, alignment) is NOT the wire layout.
//
// Header (Python struct '<BBHIQI', 20 bytes):
//   off size field
//   0   1    type      MsgType
//   1   1    flags     bit set, meaning depends on type (see k*Flag constants)
//   2   2    reserved  must be 0 on send, ignored on receive
//   4   4    frame_id  CH1 frame counter (JPEG_CH1), paired CH1 id (DETECTIONS), else 0
//   8   8    ts_us     microseconds, TX8 CLOCK_MONOTONIC (see per-type meaning)
//   16  4    len       payload length in bytes (== message size - 20)
//
// Self-contained: depends only on the C++17 standard library.
#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace tx8 {
namespace proto {

static_assert(std::numeric_limits<float>::is_iec559 && sizeof(float) == 4,
              "protocol requires IEEE-754 binary32 float");

inline constexpr std::uint8_t kProtocolVersion = 1;
inline constexpr std::uint16_t kDefaultPort = 8081;
inline constexpr const char* kDefaultPath = "/ws";

inline constexpr std::size_t kHeaderSize = 20;
// Upper bound for any payload. A 1080p MJPEG frame is typically far below this;
// frames above the limit are dropped by the sender and counted.
inline constexpr std::uint32_t kMaxPayload = 4u * 1024u * 1024u;

enum class MsgType : std::uint8_t {
  JpegCh1 = 0x01,         // TX8 -> BS: CH1 MJPEG frame bytes, verbatim from V4L2
  Detections = 0x02,      // TX8 -> BS: binary detection list
  Status = 0x03,          // TX8 -> BS: StatusPayload, on change and at 1 Hz
  DetectionsJson = 0x04,  // TX8 -> BS: UTF-8 JSON detections (debug mode only)
  Control = 0x10,         // BS -> TX8: ControlPayload
  ControlAck = 0x11,      // TX8 -> BS: ControlAckPayload (also the PING reply)
};

// ts_us meaning per type:
//   JpegCh1        V4L2 buffer timestamp of the CH1 frame (CLOCK_MONOTONIC)
//   Detections(*)  V4L2 buffer timestamp of the CH2 frame that was inferred
//   Status         time the status was produced
//   Control        sender clock, informational (TX8 does not trust it)
//   ControlAck     t3 = TX8 send time (same as payload t3_us)

// Flags for Detections / DetectionsJson
inline constexpr std::uint8_t kDetFlagPaired = 0x01;     // frame_id names a CH1 frame
inline constexpr std::uint8_t kDetFlagTruncated = 0x02;  // more candidates than top-K
// Flags for JpegCh1
inline constexpr std::uint8_t kJpegFlagAfterDrop = 0x01;  // >=1 CH1 frame dropped before this

struct Header {
  MsgType type = MsgType::Status;
  std::uint8_t flags = 0;
  std::uint32_t frame_id = 0;
  std::uint64_t ts_us = 0;
  std::uint32_t len = 0;
};

// ---------------------------------------------------------------------------
// Little-endian primitives (endian-safe on any host).
// ---------------------------------------------------------------------------
inline void put_u8(std::uint8_t* p, std::uint8_t v) { p[0] = v; }
inline void put_u16(std::uint8_t* p, std::uint16_t v) {
  p[0] = static_cast<std::uint8_t>(v);
  p[1] = static_cast<std::uint8_t>(v >> 8);
}
inline void put_u32(std::uint8_t* p, std::uint32_t v) {
  for (int i = 0; i < 4; ++i) p[i] = static_cast<std::uint8_t>(v >> (8 * i));
}
inline void put_u64(std::uint8_t* p, std::uint64_t v) {
  for (int i = 0; i < 8; ++i) p[i] = static_cast<std::uint8_t>(v >> (8 * i));
}
inline void put_f32(std::uint8_t* p, float f) {
  std::uint32_t u;
  std::memcpy(&u, &f, sizeof u);
  put_u32(p, u);
}
inline std::uint16_t get_u16(const std::uint8_t* p) {
  return static_cast<std::uint16_t>(p[0] | (p[1] << 8));
}
inline std::uint32_t get_u32(const std::uint8_t* p) {
  std::uint32_t v = 0;
  for (int i = 0; i < 4; ++i) v |= static_cast<std::uint32_t>(p[i]) << (8 * i);
  return v;
}
inline std::uint64_t get_u64(const std::uint8_t* p) {
  std::uint64_t v = 0;
  for (int i = 0; i < 8; ++i) v |= static_cast<std::uint64_t>(p[i]) << (8 * i);
  return v;
}
inline float get_f32(const std::uint8_t* p) {
  const std::uint32_t u = get_u32(p);
  float f;
  std::memcpy(&f, &u, sizeof f);
  return f;
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------
inline void encode_header(std::uint8_t out[kHeaderSize], const Header& h) {
  put_u8(out + 0, static_cast<std::uint8_t>(h.type));
  put_u8(out + 1, h.flags);
  put_u16(out + 2, 0);
  put_u32(out + 4, h.frame_id);
  put_u64(out + 8, h.ts_us);
  put_u32(out + 16, h.len);
}

// `msg_size` is the full WebSocket message size. Returns false if the message is
// shorter than a header, `len` disagrees with the message size, or len > kMaxPayload.
// Unknown types are NOT rejected here; callers must ignore types they do not know.
inline bool decode_header(const std::uint8_t* msg, std::size_t msg_size, Header& h) {
  if (msg == nullptr || msg_size < kHeaderSize) return false;
  h.type = static_cast<MsgType>(msg[0]);
  h.flags = msg[1];
  h.frame_id = get_u32(msg + 4);
  h.ts_us = get_u64(msg + 8);
  h.len = get_u32(msg + 16);
  return h.len <= kMaxPayload && static_cast<std::size_t>(h.len) == msg_size - kHeaderSize;
}

// ---------------------------------------------------------------------------
// DETECTIONS payload (Python: '<H' then count x '<Hfffff', 22 bytes each)
//   u16 count
//   count x { u16 class_id; f32 score; f32 x1; f32 y1; f32 x2; f32 y2; }
// Box coordinates are normalized 0..1 in CH1 image coordinates (x right, y down),
// x1<=x2, y1<=y2. Score is 0..1.
// ---------------------------------------------------------------------------
struct Detection {
  std::uint16_t class_id = 0;
  float score = 0.f;
  float x1 = 0.f, y1 = 0.f, x2 = 0.f, y2 = 0.f;
};

inline constexpr std::size_t kDetectionWireSize = 22;
inline constexpr std::uint16_t kMaxDetections = 300;  // matches typical end2end heads

inline constexpr std::size_t detections_payload_size(std::uint16_t count) {
  return 2u + kDetectionWireSize * count;
}

// Returns bytes written, or 0 if `cap` is too small or count > kMaxDetections.
inline std::size_t encode_detections(std::uint8_t* out, std::size_t cap,
                                     const Detection* dets, std::uint16_t count) {
  const std::size_t need = detections_payload_size(count);
  if (out == nullptr || count > kMaxDetections || cap < need) return 0;
  put_u16(out, count);
  std::uint8_t* p = out + 2;
  for (std::uint16_t i = 0; i < count; ++i, p += kDetectionWireSize) {
    put_u16(p + 0, dets[i].class_id);
    put_f32(p + 2, dets[i].score);
    put_f32(p + 6, dets[i].x1);
    put_f32(p + 10, dets[i].y1);
    put_f32(p + 14, dets[i].x2);
    put_f32(p + 18, dets[i].y2);
  }
  return need;
}

// Decodes up to `max_out` detections. Returns false on malformed payload
// (size mismatch or count > max_out).
inline bool decode_detections(const std::uint8_t* payload, std::size_t len, Detection* out,
                              std::uint16_t max_out, std::uint16_t& count) {
  count = 0;
  if (payload == nullptr || len < 2) return false;
  const std::uint16_t n = get_u16(payload);
  if (n > max_out || len != detections_payload_size(n)) return false;
  const std::uint8_t* p = payload + 2;
  for (std::uint16_t i = 0; i < n; ++i, p += kDetectionWireSize) {
    out[i].class_id = get_u16(p + 0);
    out[i].score = get_f32(p + 2);
    out[i].x1 = get_f32(p + 6);
    out[i].y1 = get_f32(p + 10);
    out[i].x2 = get_f32(p + 14);
    out[i].y2 = get_f32(p + 18);
  }
  count = n;
  return true;
}

// ---------------------------------------------------------------------------
// STATUS payload (Python struct '<BBBBHH8fII', 48 bytes). Unknown floats = NaN.
// ---------------------------------------------------------------------------
enum class PipelineState : std::uint8_t {
  Idle = 0,
  Starting = 1,
  Running = 2,
  Stopping = 3,
  Fault = 4,
};

enum class FaultCode : std::uint8_t {
  None = 0,
  CameraCh1 = 1,
  CameraCh2 = 2,
  Mx3Open = 3,
  Mx3Timeout = 4,
  Mx3Thermal = 5,
  Decode = 6,
  StartTimeout = 7,
  Internal = 8,
};

struct StatusPayload {
  PipelineState state = PipelineState::Idle;
  FaultCode fault = FaultCode::None;
  std::uint8_t mx3_chips = 0;               // chips configured at startup (1..4)
  std::uint8_t proto_version = kProtocolVersion;
  std::uint16_t mx3_clock_mhz = 0;          // 0 = MX3 released / unknown
  std::uint16_t reserved = 0;
  float fps_ch1 = 0.f;        // CH1 frames sent per second
  float fps_infer = 0.f;      // DETECTIONS sent per second
  float lat_p50_ms = 0.f;     // TX8-internal capture -> metadata sent, last window
  float lat_p99_ms = 0.f;
  float cpu_pct = 0.f;        // total CPU, 0..400 (4 cores)
  float soc_temp_c = 0.f;
  float mx3_temp_c = 0.f;     // max over chips
  float mx3_power_mw = 0.f;
  std::uint32_t dropped_ch1 = 0;  // cumulative since process start
  std::uint32_t dropped_ch2 = 0;
};

inline constexpr std::size_t kStatusWireSize = 48;

inline void encode_status(std::uint8_t out[kStatusWireSize], const StatusPayload& s) {
  put_u8(out + 0, static_cast<std::uint8_t>(s.state));
  put_u8(out + 1, static_cast<std::uint8_t>(s.fault));
  put_u8(out + 2, s.mx3_chips);
  put_u8(out + 3, s.proto_version);
  put_u16(out + 4, s.mx3_clock_mhz);
  put_u16(out + 6, 0);
  const float f[8] = {s.fps_ch1,    s.fps_infer,  s.lat_p50_ms, s.lat_p99_ms,
                      s.cpu_pct,    s.soc_temp_c, s.mx3_temp_c, s.mx3_power_mw};
  for (int i = 0; i < 8; ++i) put_f32(out + 8 + 4 * i, f[i]);
  put_u32(out + 40, s.dropped_ch1);
  put_u32(out + 44, s.dropped_ch2);
}

inline bool decode_status(const std::uint8_t* p, std::size_t len, StatusPayload& s) {
  if (p == nullptr || len < kStatusWireSize) return false;  // longer = future extension
  s.state = static_cast<PipelineState>(p[0]);
  s.fault = static_cast<FaultCode>(p[1]);
  s.mx3_chips = p[2];
  s.proto_version = p[3];
  s.mx3_clock_mhz = get_u16(p + 4);
  s.fps_ch1 = get_f32(p + 8);
  s.fps_infer = get_f32(p + 12);
  s.lat_p50_ms = get_f32(p + 16);
  s.lat_p99_ms = get_f32(p + 20);
  s.cpu_pct = get_f32(p + 24);
  s.soc_temp_c = get_f32(p + 28);
  s.mx3_temp_c = get_f32(p + 32);
  s.mx3_power_mw = get_f32(p + 36);
  s.dropped_ch1 = get_u32(p + 40);
  s.dropped_ch2 = get_u32(p + 44);
  return true;
}

// ---------------------------------------------------------------------------
// CONTROL payload, base station -> TX8 (Python struct '<B3xIQ', 16 bytes)
// ---------------------------------------------------------------------------
enum class ControlCmd : std::uint8_t {
  Start = 1,      // InferenceControl{start}
  Stop = 2,       // InferenceControl{stop}
  Ping = 3,       // clock-offset probe; TX8 answers with ControlAck immediately
  GetStatus = 4,  // TX8 answers with ControlAck + one Status message
};

struct ControlPayload {
  ControlCmd cmd = ControlCmd::Ping;
  std::uint32_t seq = 0;    // chosen by the base station, echoed in the ack
  std::uint64_t t1_us = 0;  // base-station clock at send (opaque to TX8, echoed)
};

inline constexpr std::size_t kControlWireSize = 16;

inline void encode_control(std::uint8_t out[kControlWireSize], const ControlPayload& c) {
  put_u8(out + 0, static_cast<std::uint8_t>(c.cmd));
  out[1] = out[2] = out[3] = 0;
  put_u32(out + 4, c.seq);
  put_u64(out + 8, c.t1_us);
}

inline bool decode_control(const std::uint8_t* p, std::size_t len, ControlPayload& c) {
  if (p == nullptr || len != kControlWireSize) return false;
  const std::uint8_t cmd = p[0];
  if (cmd < 1 || cmd > 4) return false;
  c.cmd = static_cast<ControlCmd>(cmd);
  c.seq = get_u32(p + 4);
  c.t1_us = get_u64(p + 8);
  return true;
}

// ---------------------------------------------------------------------------
// CONTROL_ACK payload, TX8 -> base station (Python struct '<BBHIQQQ', 32 bytes)
// NTP-style: t1 = BS send (echoed), t2 = TX8 receive, t3 = TX8 send (both TX8
// CLOCK_MONOTONIC us). The BS records t4 on receipt.
// For Start/Stop, result Ok means "accepted"; the resulting state arrives via Status.
// ---------------------------------------------------------------------------
enum class AckResult : std::uint8_t {
  Ok = 0,
  Rejected = 1,  // e.g. FAULT not cleared
  Invalid = 2,   // malformed control message
};

struct ControlAckPayload {
  ControlCmd cmd = ControlCmd::Ping;
  AckResult result = AckResult::Ok;
  std::uint32_t seq = 0;
  std::uint64_t t1_us = 0;
  std::uint64_t t2_us = 0;
  std::uint64_t t3_us = 0;
};

inline constexpr std::size_t kControlAckWireSize = 32;

inline void encode_control_ack(std::uint8_t out[kControlAckWireSize],
                               const ControlAckPayload& a) {
  put_u8(out + 0, static_cast<std::uint8_t>(a.cmd));
  put_u8(out + 1, static_cast<std::uint8_t>(a.result));
  put_u16(out + 2, 0);
  put_u32(out + 4, a.seq);
  put_u64(out + 8, a.t1_us);
  put_u64(out + 16, a.t2_us);
  put_u64(out + 24, a.t3_us);
}

inline bool decode_control_ack(const std::uint8_t* p, std::size_t len, ControlAckPayload& a) {
  if (p == nullptr || len != kControlAckWireSize) return false;
  a.cmd = static_cast<ControlCmd>(p[0]);
  a.result = static_cast<AckResult>(p[1]);
  a.seq = get_u32(p + 4);
  a.t1_us = get_u64(p + 8);
  a.t2_us = get_u64(p + 16);
  a.t3_us = get_u64(p + 24);
  return true;
}

// ---------------------------------------------------------------------------
// Convenience: build a complete message into `out` (header + payload copy).
// For JpegCh1 prefer a gather write (header buffer + V4L2 buffer) to avoid the copy.
// Returns total bytes written or 0 on overflow.
// ---------------------------------------------------------------------------
inline std::size_t build_message(std::uint8_t* out, std::size_t cap, Header h,
                                 const std::uint8_t* payload, std::uint32_t len) {
  if (out == nullptr || len > kMaxPayload || cap < kHeaderSize + len) return 0;
  h.len = len;
  encode_header(out, h);
  if (len != 0) std::memcpy(out + kHeaderSize, payload, len);
  return kHeaderSize + len;
}

}  // namespace proto
}  // namespace tx8
