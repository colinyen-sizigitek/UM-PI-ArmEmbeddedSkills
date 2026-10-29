#!/usr/bin/env python3
"""Fake TX8 server: emits synthetic CH1 JPEG frames, detections and status using the TX8
WebSocket protocol v1 (references/protocol.md; source of truth: um-pi-vision-pipeline
assets/protocol.h), so the viewer can be tested without hardware.

Behaviour (simplified model of the real pipeline):
  - "camera" produces frames at --fps; JPEG_CH1 sent only while a client is connected
  - START -> STARTING (--start-delay-ms) -> RUNNING; STOP -> STOPPING (200 ms) -> IDLE;
    last command wins; optional fault injection (--fault-after-s) with auto-retry
  - DETECTIONS = ground-truth boxes of the moving objects, sent --infer-latency-ms after the
    frame, PAIRED with the CH1 frame_id (or unpaired with --unpaired, JSON with --json)
  - STATUS at 1 Hz and on state change; CONTROL_ACK with t2/t3 for clock-offset estimation
  - the fake TX8 clock has a large constant offset to the PC clock, printed at startup,
    so the viewer's offset estimate can be checked
  - one client at a time: a new connection replaces the old one

Usage:
  python fake_tx8_server.py [--host 127.0.0.1] [--port 8081] [--autostart] [--drop-rate 0.05]
  python fake_tx8_server.py --help
Then: python viewer.py --url ws://127.0.0.1:8081/ws
Requirements: Python 3.11+, websockets>=13, opencv-python, numpy (see requirements.txt).
"""
from __future__ import annotations

import argparse
import asyncio
import collections
import json
import logging
import math
import random
import struct
import time
from dataclasses import dataclass
from typing import Callable, Union

import cv2
import numpy as np
from websockets.asyncio.server import ServerConnection, serve
from websockets.exceptions import ConnectionClosed

LOG = logging.getLogger("fake_tx8")

# ---- protocol v1 (mirror of assets/protocol.h - keep in sync) ----
PROTOCOL_VERSION = 1
HEADER = struct.Struct("<BBHIQI")
DET_COUNT = struct.Struct("<H")
DET_ITEM = struct.Struct("<Hfffff")
STATUS = struct.Struct("<BBBBHH8fII")
CONTROL = struct.Struct("<B3xIQ")
CONTROL_ACK = struct.Struct("<BBHIQQQ")
T_JPEG_CH1, T_DETECTIONS, T_STATUS, T_DETECTIONS_JSON = 0x01, 0x02, 0x03, 0x04
T_CONTROL, T_CONTROL_ACK = 0x10, 0x11
FLAG_AFTER_DROP = 0x01
FLAG_PAIRED = 0x01
CMD_START, CMD_STOP, CMD_PING, CMD_GET_STATUS = 1, 2, 3, 4
ACK_OK, ACK_REJECTED, ACK_INVALID = 0, 1, 2
IDLE, STARTING, RUNNING, STOPPING, FAULT = 0, 1, 2, 3, 4
STATE_NAMES = {IDLE: "IDLE", STARTING: "STARTING", RUNNING: "RUNNING", STOPPING: "STOPPING", FAULT: "FAULT"}
FAULT_MX3_TIMEOUT = 4

# Emulated TX8 CLOCK_MONOTONIC: PC perf counter + constant offset (viewer should estimate it).
TX8_CLOCK_OFFSET_US = 7_000_000_000


def tx8_now_us() -> int:
    return time.perf_counter_ns() // 1000 + TX8_CLOCK_OFFSET_US


def build(mtype: int, payload: bytes, frame_id: int = 0, ts_us: int = 0, flags: int = 0) -> bytes:
    return HEADER.pack(mtype, flags, 0, frame_id & 0xFFFFFFFF, ts_us, len(payload)) + payload


Item = Union[bytes, Callable[[], bytes]]      # callables are built at send time (fresh t3)


class Client:
    """One connected base station; two bounded send queues, control/metadata first."""

    def __init__(self, ws: ServerConnection) -> None:
        self.ws = ws
        self.hi: collections.deque[Item] = collections.deque(maxlen=64)   # acks, status, detections
        self.lo: collections.deque[Item] = collections.deque(maxlen=4)    # JPEG frames
        self.dropped_jpeg = 0
        self._wake = asyncio.Event()

    def push(self, item: Item, video: bool = False) -> None:
        q = self.lo if video else self.hi
        if len(q) == q.maxlen and video:
            self.dropped_jpeg += 1                  # deque drops the oldest automatically
        q.append(item)
        self._wake.set()

    async def sender(self) -> None:
        while True:
            if not self.hi and not self.lo:
                self._wake.clear()
                await self._wake.wait()
                continue
            item = self.hi.popleft() if self.hi else self.lo.popleft()
            await self.ws.send(item() if callable(item) else item)


@dataclass
class MovingObject:
    class_id: int
    w: float           # normalized size
    h: float
    fx: float          # Lissajous frequencies (Hz)
    fy: float
    phase: float

    def box(self, t: float) -> tuple[float, float, float, float]:
        cx = 0.5 + 0.35 * math.sin(2 * math.pi * self.fx * t + self.phase)
        cy = 0.55 + 0.3 * math.sin(2 * math.pi * self.fy * t)
        return (max(0.0, cx - self.w / 2), max(0.0, cy - self.h / 2),
                min(1.0, cx + self.w / 2), min(1.0, cy + self.h / 2))


class FakeTx8:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.state = IDLE
        self.fault = 0
        self.desired_start = bool(args.autostart)
        self.client: Client | None = None
        self.frame_id = 0
        self.after_drop = False
        self.dropped_ch1 = 0
        self.dropped_ch2 = 0
        self.running_since = 0.0
        self.sent_ch1: collections.deque[float] = collections.deque()
        self.sent_det: collections.deque[float] = collections.deque()
        self.lat_us: collections.deque[int] = collections.deque(maxlen=300)
        self.wake = asyncio.Event()
        if self.desired_start:
            self.wake.set()
        self.objects = [
            MovingObject(0, 0.06, 0.18, 0.11, 0.07, 0.0),
            MovingObject(1, 0.16, 0.10, 0.05, 0.09, 1.0),
            MovingObject(2, 0.08, 0.08, 0.13, 0.05, 2.0),
        ]
        self.background = self._make_background(args.width, args.height)

    # ---------------------------------------------------------------- helpers
    @staticmethod
    def _make_background(w: int, h: int) -> np.ndarray:
        x = np.linspace(0, 255, w, dtype=np.float32)
        y = np.linspace(0, 255, h, dtype=np.float32)
        img = np.zeros((h, w, 3), dtype=np.uint8)
        img[..., 0] = (y[:, None] * 0.6).astype(np.uint8)
        img[..., 1] = (x[None, :] * 0.4).astype(np.uint8)
        img[..., 2] = 60
        for gx in range(0, w, max(1, w // 16)):
            cv2.line(img, (gx, 0), (gx, h - 1), (90, 90, 90), 1)
        for gy in range(0, h, max(1, h // 9)):
            cv2.line(img, (0, gy), (w - 1, gy), (90, 90, 90), 1)
        return img

    def _render(self, boxes: list[tuple[int, tuple[float, float, float, float]]],
                frame_id: int, ts_us: int) -> bytes:
        img = self.background.copy()
        h, w = img.shape[:2]
        colors = [(40, 200, 40), (40, 120, 230), (200, 60, 200)]
        for cls, (x1, y1, x2, y2) in boxes:
            cv2.rectangle(img, (int(x1 * w), int(y1 * h)), (int(x2 * w), int(y2 * h)),
                          colors[cls % len(colors)], -1)
        cv2.putText(img, f"FAKE TX8 frame {frame_id} ts {ts_us}", (30, h - 40),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.2, (255, 255, 255), 2, cv2.LINE_AA)
        ok, jpg = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, self.args.quality])
        if not ok:
            raise RuntimeError("cv2.imencode failed")
        return jpg.tobytes()

    @staticmethod
    def _rate(dq: collections.deque[float], now: float) -> float:
        while dq and now - dq[0] > 1.0:
            dq.popleft()
        return float(len(dq))

    def status_bytes(self) -> bytes:
        now = time.perf_counter()
        lat = sorted(self.lat_us)
        p50 = lat[len(lat) // 2] / 1000.0 if lat else math.nan
        p99 = lat[min(len(lat) - 1, int(len(lat) * 0.99))] / 1000.0 if lat else math.nan
        active = self.state in (STARTING, RUNNING)
        payload = STATUS.pack(
            self.state, self.fault, 4, PROTOCOL_VERSION, 300 if active else 0, 0,
            self._rate(self.sent_ch1, now), self._rate(self.sent_det, now), p50, p99,
            (140.0 if self.state == RUNNING else 40.0) + random.uniform(-5, 5),
            55.0 + random.uniform(-1, 1),
            61.0 + random.uniform(-1, 1) if active else math.nan,
            3900.0 if self.state == RUNNING else math.nan,
            self.dropped_ch1, self.dropped_ch2)
        return build(T_STATUS, payload, 0, tx8_now_us())

    def set_state(self, s: int, fault: int = 0) -> None:
        LOG.info("state %s -> %s%s", STATE_NAMES[self.state], STATE_NAMES[s],
                 f" (fault {fault})" if fault else "")
        self.state = s
        self.fault = fault
        if s == RUNNING:
            self.running_since = time.perf_counter()
            self.lat_us.clear()
        if self.client is not None:
            self.client.push(self.status_bytes())

    # ---------------------------------------------------------------- loops
    async def control_loop(self) -> None:
        """State machine; last command wins (desired_start is overwritten by each command)."""
        while True:
            await self.wake.wait()
            self.wake.clear()
            while True:
                if self.desired_start and self.state in (IDLE, FAULT):
                    if self.state == FAULT:
                        await asyncio.sleep(2.0)            # retry backoff
                        if not self.desired_start:
                            self.set_state(IDLE)
                            continue
                    self.set_state(STARTING)
                    await asyncio.sleep(self.args.start_delay_ms / 1000.0)
                    if self.desired_start:
                        self.set_state(RUNNING)
                    else:
                        self.set_state(STOPPING)
                        await asyncio.sleep(0.2)
                        self.set_state(IDLE)
                elif not self.desired_start and self.state in (RUNNING, FAULT):
                    if self.state == RUNNING:
                        self.set_state(STOPPING)
                        await asyncio.sleep(0.2)
                    self.set_state(IDLE)
                else:
                    break

    async def status_loop(self) -> None:
        while True:
            await asyncio.sleep(1.0)
            if self.client is not None:
                self.client.push(self.status_bytes())

    async def camera_loop(self) -> None:
        loop = asyncio.get_running_loop()
        period = 1.0 / self.args.fps
        next_t = time.perf_counter()
        while True:
            next_t += period
            delay = next_t - time.perf_counter()
            if delay > 0:
                await asyncio.sleep(delay)
            else:
                next_t = time.perf_counter()              # fell behind: resync, no burst
            ts = tx8_now_us()
            self.frame_id = (self.frame_id + 1) & 0xFFFFFFFF
            fid = self.frame_id
            t = time.perf_counter()
            boxes = [(o.class_id, o.box(t)) for o in self.objects]

            if (self.state == RUNNING and self.args.fault_after_s > 0
                    and t - self.running_since > self.args.fault_after_s):
                self.set_state(FAULT, FAULT_MX3_TIMEOUT)
                self.wake.set()                          # control loop retries while desired

            client = self.client
            if client is None:
                continue
            if random.random() < self.args.drop_rate:
                self.dropped_ch1 += 1
                self.after_drop = True
            else:
                jpg = await asyncio.to_thread(self._render, boxes, fid, ts)
                flags = FLAG_AFTER_DROP if self.after_drop else 0
                self.after_drop = False
                client.push(build(T_JPEG_CH1, jpg, fid, ts, flags), video=True)
                self.sent_ch1.append(time.perf_counter())
            if self.state == RUNNING:
                if random.random() < self.args.drop_rate:
                    self.dropped_ch2 += 1
                    continue
                ch2_ts = ts + random.randint(-3000, 3000)    # CH2 is a separate stream
                lat_s = self.args.infer_latency_ms / 1000.0 * random.uniform(0.8, 1.3)
                loop.call_later(lat_s, self._emit_detections, fid, ch2_ts, boxes)

    def _emit_detections(self, fid: int, ch2_ts: int,
                         boxes: list[tuple[int, tuple[float, float, float, float]]]) -> None:
        client = self.client
        if client is None or self.state != RUNNING:
            return
        dets = [(cls, round(random.uniform(0.55, 0.98), 3), *b) for cls, b in boxes]
        paired = not self.args.unpaired
        frame_id = fid if paired else 0
        flags = FLAG_PAIRED if paired else 0
        if self.args.json:
            obj = {"frame_id": frame_id, "paired": paired, "ts_us": ch2_ts,
                   "dets": [{"cls": d[0], "score": d[1], "box": list(d[2:])} for d in dets]}
            msg = build(T_DETECTIONS_JSON, json.dumps(obj).encode("utf-8"), frame_id, ch2_ts, flags)
        else:
            payload = DET_COUNT.pack(len(dets)) + b"".join(DET_ITEM.pack(*d) for d in dets)
            msg = build(T_DETECTIONS, payload, frame_id, ch2_ts, flags)
        client.push(msg)
        self.lat_us.append(tx8_now_us() - ch2_ts)
        self.sent_det.append(time.perf_counter())

    # ---------------------------------------------------------------- connection
    def _ack(self, cmd: int, result: int, seq: int, t1: int, t2: int) -> Callable[[], bytes]:
        def build_now() -> bytes:
            t3 = tx8_now_us()                            # stamped right before sending
            payload = CONTROL_ACK.pack(cmd, result, 0, seq, t1, t2, t3)
            return build(T_CONTROL_ACK, payload, 0, t3)
        return build_now

    def on_message(self, client: Client, msg: bytes, t2: int) -> None:
        if len(msg) < HEADER.size:
            return
        mtype, _flags, _res, _fid, _ts, length = HEADER.unpack_from(msg, 0)
        if mtype != T_CONTROL:
            return                                       # ignore unknown types
        if length != len(msg) - HEADER.size or length != CONTROL.size:
            client.push(self._ack(0, ACK_INVALID, 0, 0, t2))
            return
        cmd, seq, t1 = CONTROL.unpack_from(msg, HEADER.size)
        if cmd == CMD_START:
            self.desired_start = True
            self.wake.set()
        elif cmd == CMD_STOP:
            self.desired_start = False
            self.wake.set()
        elif cmd not in (CMD_PING, CMD_GET_STATUS):
            client.push(self._ack(cmd, ACK_INVALID, seq, t1, t2))
            return
        if cmd != CMD_PING:
            LOG.info("control %d seq %d", cmd, seq)
        client.push(self._ack(cmd, ACK_OK, seq, t1, t2))
        if cmd == CMD_GET_STATUS:
            client.push(self.status_bytes())

    async def handler(self, ws: ServerConnection) -> None:
        request = getattr(ws, "request", None)
        path = getattr(request, "path", self.args.path)
        if path != self.args.path:
            LOG.warning("rejecting connection to path %r", path)
            await ws.close(1008, "unknown path")
            return
        client = Client(ws)
        old, self.client = self.client, client
        if old is not None:
            LOG.info("new client replaces the previous one")
            await old.ws.close(1000, "replaced by new client")
        LOG.info("client connected from %s", ws.remote_address)
        client.push(self.status_bytes())
        sender = asyncio.create_task(client.sender())
        try:
            async for msg in ws:
                t2 = tx8_now_us()
                if isinstance(msg, bytes):
                    self.on_message(client, msg, t2)
        except ConnectionClosed:
            pass
        finally:
            sender.cancel()
            await asyncio.gather(sender, return_exceptions=True)
            if self.client is client:
                self.client = None
            LOG.info("client disconnected (jpeg dropped on send: %d)", client.dropped_jpeg)


async def amain(args: argparse.Namespace) -> None:
    tx8 = FakeTx8(args)
    async with serve(tx8.handler, args.host, args.port, compression=None, max_size=2 ** 16,
                     ping_interval=5, ping_timeout=5):
        LOG.info("fake TX8 on ws://%s:%d%s  (TX8 clock offset vs PC: %+d us)",
                 args.host, args.port, args.path, TX8_CLOCK_OFFSET_US)
        await asyncio.gather(tx8.camera_loop(), tx8.status_loop(), tx8.control_loop())


def main() -> int:
    ap = argparse.ArgumentParser(description="Fake TX8 WebSocket server (protocol v1) for viewer tests")
    ap.add_argument("--host", default="127.0.0.1", help="bind address (0.0.0.0 for LAN tests)")
    ap.add_argument("--port", type=int, default=8081)
    ap.add_argument("--path", default="/ws")
    ap.add_argument("--fps", type=float, default=30.0)
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--quality", type=int, default=80, help="JPEG quality 1..100")
    ap.add_argument("--infer-latency-ms", type=float, default=45.0, help="simulated TX8-internal latency")
    ap.add_argument("--start-delay-ms", type=float, default=1500.0, help="simulated start latency")
    ap.add_argument("--drop-rate", type=float, default=0.0, help="probability to drop a CH1 / CH2 frame")
    ap.add_argument("--unpaired", action="store_true", help="send detections without the PAIRED flag")
    ap.add_argument("--json", action="store_true", help="send DETECTIONS_JSON (debug format)")
    ap.add_argument("--autostart", action="store_true", help="start inference without a START command")
    ap.add_argument("--fault-after-s", type=float, default=0.0,
                    help="inject an MX3-timeout FAULT after N s of RUNNING (0 = off)")
    args = ap.parse_args()
    if args.fps <= 0 or not 1 <= args.quality <= 100 or not 0.0 <= args.drop_rate < 1.0:
        ap.error("invalid --fps, --quality or --drop-rate")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        asyncio.run(amain(args))
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
