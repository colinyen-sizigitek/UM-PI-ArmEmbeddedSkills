#!/usr/bin/env python3
"""TX8 base-station viewer (reference implementation, Windows/Linux desktop).

Connects to the TX8 vision pipeline WebSocket (protocol v1, see references/protocol.md;
source of truth: um-pi-vision-pipeline assets/protocol.h), shows the CH1 MJPEG stream with
detection overlays matched by frame_id / timestamp (never on the wrong frame), sends
START/STOP, and shows TX8 status, fps and an *estimated* end-to-end latency.

Usage:
  python viewer.py --url ws://<tx8-ip>:8081/ws [--start] [--record DIR] [--no-display]
  python viewer.py --help

Keys (display mode): s = START inference, x = STOP inference, q or Esc = quit.
Test without hardware:  python fake_tx8_server.py   then   python viewer.py
Requirements: Python 3.11+, websockets>=13, opencv-python, numpy (see requirements.txt).
"""
from __future__ import annotations

import argparse
import asyncio
import collections
import json
import logging
import math
import queue
import random
import statistics
import struct
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed, InvalidHandshake, InvalidURI

LOG = logging.getLogger("viewer")

# --------------------------------------------------------------------------------------
# Protocol v1 (mirror of um-pi-vision-pipeline assets/protocol.h - keep in sync)
# --------------------------------------------------------------------------------------
PROTOCOL_VERSION = 1
HEADER = struct.Struct("<BBHIQI")          # type, flags, reserved, frame_id, ts_us, len
DET_COUNT = struct.Struct("<H")
DET_ITEM = struct.Struct("<Hfffff")         # class_id, score, x1, y1, x2, y2
STATUS = struct.Struct("<BBBBHH8fII")       # 48 bytes
CONTROL = struct.Struct("<B3xIQ")           # cmd, seq, t1_us
CONTROL_ACK = struct.Struct("<BBHIQQQ")     # cmd, result, reserved, seq, t1, t2, t3
MAX_PAYLOAD = 4 * 1024 * 1024
MAX_WS_MESSAGE = 8 * 1024 * 1024

T_JPEG_CH1 = 0x01
T_DETECTIONS = 0x02
T_STATUS = 0x03
T_DETECTIONS_JSON = 0x04
T_CONTROL = 0x10
T_CONTROL_ACK = 0x11

FLAG_AFTER_DROP = 0x01      # JPEG_CH1
FLAG_PAIRED = 0x01          # DETECTIONS
FLAG_TRUNCATED = 0x02       # DETECTIONS

CMD_START, CMD_STOP, CMD_PING, CMD_GET_STATUS = 1, 2, 3, 4
CMD_NAMES = {CMD_START: "START", CMD_STOP: "STOP", CMD_PING: "PING", CMD_GET_STATUS: "GET_STATUS"}
ACK_NAMES = {0: "OK", 1: "REJECTED", 2: "INVALID"}
STATE_NAMES = {0: "IDLE", 1: "STARTING", 2: "RUNNING", 3: "STOPPING", 4: "FAULT"}
STATE_RUNNING = 2
FAULT_NAMES = {0: "", 1: "camera CH1", 2: "camera CH2", 3: "MX3 open", 4: "MX3 timeout",
               5: "MX3 thermal", 6: "decode", 7: "start timeout", 8: "internal"}

BACKOFF_MIN_S = 0.5
BACKOFF_MAX_S = 5.0
WINDOW = "TX8 viewer"


def now_us() -> int:
    """Local monotonic clock in microseconds (QueryPerformanceCounter on Windows)."""
    return time.perf_counter_ns() // 1000


@dataclass(slots=True)
class Detection:
    class_id: int
    score: float
    x1: float
    y1: float
    x2: float
    y2: float


@dataclass(slots=True)
class DetResult:
    frame_id: int
    ts_us: int
    flags: int
    dets: list[Detection]
    t_rx_us: int

    @property
    def paired(self) -> bool:
        return bool(self.flags & FLAG_PAIRED)


@dataclass(slots=True)
class Frame:
    frame_id: int
    ts_us: int
    flags: int
    jpeg: memoryview
    t_rx_us: int


@dataclass(slots=True)
class Status:
    state: int = 0
    fault: int = 0
    mx3_chips: int = 0
    proto_version: int = 0
    mx3_clock_mhz: int = 0
    fps_ch1: float = math.nan
    fps_infer: float = math.nan
    lat_p50_ms: float = math.nan
    lat_p99_ms: float = math.nan
    cpu_pct: float = math.nan
    soc_temp_c: float = math.nan
    mx3_temp_c: float = math.nan
    mx3_power_mw: float = math.nan
    dropped_ch1: int = 0
    dropped_ch2: int = 0


def parse_header(msg: bytes) -> tuple[int, int, int, int, memoryview] | None:
    if len(msg) < HEADER.size:
        return None
    mtype, flags, _reserved, frame_id, ts_us, length = HEADER.unpack_from(msg, 0)
    if length > MAX_PAYLOAD or length != len(msg) - HEADER.size:
        return None
    return mtype, flags, frame_id, ts_us, memoryview(msg)[HEADER.size:]


def parse_detections(payload: memoryview) -> list[Detection] | None:
    if len(payload) < DET_COUNT.size:
        return None
    (count,) = DET_COUNT.unpack_from(payload, 0)
    if len(payload) != DET_COUNT.size + DET_ITEM.size * count:
        return None
    if count == 0:
        return []
    return [Detection(*item) for item in DET_ITEM.iter_unpack(payload[DET_COUNT.size:])]


def parse_detections_json(payload: memoryview) -> tuple[int, bool, list[Detection]] | None:
    try:
        obj = json.loads(bytes(payload).decode("utf-8"))
        dets = [Detection(int(d["cls"]), float(d["score"]), *(float(v) for v in d["box"]))
                for d in obj.get("dets", [])]
        return int(obj.get("frame_id", 0)), bool(obj.get("paired", False)), dets
    except (ValueError, KeyError, TypeError):
        return None


def parse_status(payload: memoryview) -> Status | None:
    if len(payload) < STATUS.size:
        return None
    v = STATUS.unpack_from(payload, 0)
    return Status(state=v[0], fault=v[1], mx3_chips=v[2], proto_version=v[3], mx3_clock_mhz=v[4],
                  fps_ch1=v[6], fps_infer=v[7], lat_p50_ms=v[8], lat_p99_ms=v[9], cpu_pct=v[10],
                  soc_temp_c=v[11], mx3_temp_c=v[12], mx3_power_mw=v[13],
                  dropped_ch1=v[14], dropped_ch2=v[15])


def build_control(cmd: int, seq: int, t1_us: int) -> bytes:
    payload = CONTROL.pack(cmd, seq, t1_us)
    return HEADER.pack(T_CONTROL, 0, 0, 0, t1_us, len(payload)) + payload


# --------------------------------------------------------------------------------------
# Clock offset (NTP-style, min-RTT filter) - see references/sync-and-latency.md
# --------------------------------------------------------------------------------------
class ClockSync:
    def __init__(self, window: int = 16) -> None:
        self._samples: collections.deque[tuple[int, int]] = collections.deque(maxlen=window)
        self._lock = threading.Lock()

    def add(self, t1: int, t2: int, t3: int, t4: int) -> None:
        rtt = (t4 - t1) - (t3 - t2)
        if rtt < 0:
            return
        offset = ((t2 - t1) + (t3 - t4)) // 2          # TX8 clock - local clock
        with self._lock:
            self._samples.append((rtt, offset))

    def best(self) -> tuple[int, int] | None:
        """Return (offset_us, rtt_us) of the minimum-RTT sample, or None."""
        with self._lock:
            if not self._samples:
                return None
            rtt, offset = min(self._samples)
        return offset, rtt

    def reset(self) -> None:
        with self._lock:
            self._samples.clear()


# --------------------------------------------------------------------------------------
# Raw message recorder (replayable): file = b"TX8REC1\n" + records <Q t_rx_us><I len><msg>
# --------------------------------------------------------------------------------------
class Recorder:
    REC = struct.Struct("<QI")

    def __init__(self, directory: Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / f"tx8_session_{time.strftime('%Y%m%d_%H%M%S')}.bin"
        self._q: queue.Queue[tuple[int, bytes] | None] = queue.Queue(maxsize=512)
        self.dropped = 0
        self._thread = threading.Thread(target=self._run, name="recorder", daemon=True)
        self._thread.start()
        LOG.info("recording raw messages to %s", self.path)

    def put(self, t_rx_us: int, msg: bytes) -> None:
        try:
            self._q.put_nowait((t_rx_us, msg))
        except queue.Full:
            self.dropped += 1

    def _run(self) -> None:
        with open(self.path, "wb") as f:
            f.write(b"TX8REC1\n")
            while True:
                item = self._q.get()
                if item is None:
                    break
                t_rx, msg = item
                f.write(self.REC.pack(t_rx, len(msg)))
                f.write(msg)

    def close(self) -> None:
        try:
            self._q.put(None, timeout=2.0)
        except queue.Full:
            LOG.warning("recorder queue full at shutdown; last messages lost")
        self._thread.join(timeout=5.0)


# --------------------------------------------------------------------------------------
# Network client: asyncio loop in its own thread; hands data to the UI via bounded queues
# --------------------------------------------------------------------------------------
class NetClient:
    def __init__(self, url: str, clock: ClockSync, recorder: Recorder | None) -> None:
        self.url = url
        self.clock = clock
        self.recorder = recorder
        self.jpeg_q: queue.Queue[Frame] = queue.Queue(maxsize=8)
        self.meta_q: queue.Queue[tuple[Any, ...]] = queue.Queue(maxsize=256)
        self.rx_jpeg_dropped = 0
        self.meta_dropped = 0
        self.bad_messages = 0
        self.fatal_error: str | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._stop: asyncio.Event | None = None
        self._out: asyncio.Queue[int] | None = None
        self._ready = threading.Event()
        self._seq = 0
        self._thread = threading.Thread(target=self._thread_main, name="net", daemon=True)

    # ---- called from the UI thread ----
    def start(self) -> None:
        self._thread.start()
        if not self._ready.wait(timeout=5.0):
            raise RuntimeError("network thread did not start")

    def stop(self) -> None:
        loop, stop = self._loop, self._stop
        if loop is not None and stop is not None and not loop.is_closed():
            try:
                loop.call_soon_threadsafe(stop.set)
            except RuntimeError:
                pass                                   # loop already closed
        self._thread.join(timeout=5.0)

    def send_control(self, cmd: int) -> None:
        loop = self._loop
        if loop is None or loop.is_closed():
            return
        try:
            loop.call_soon_threadsafe(self._enqueue_out, cmd)
        except RuntimeError:
            pass

    # ---- network thread ----
    def _thread_main(self) -> None:
        try:
            asyncio.run(self._main())
        except Exception as exc:  # noqa: BLE001 - report any crash to the UI
            LOG.exception("network thread crashed")
            self.fatal_error = f"network thread crashed: {exc}"

    def _enqueue_out(self, cmd: int) -> None:
        if self._out is None:
            return
        try:
            self._out.put_nowait(cmd)
        except asyncio.QueueFull:
            LOG.warning("control queue full; %s dropped", CMD_NAMES.get(cmd, cmd))

    def _post_meta(self, item: tuple[Any, ...]) -> None:
        if not _put_drop_oldest(self.meta_q, item):
            self.meta_dropped += 1

    async def _main(self) -> None:
        self._loop = asyncio.get_running_loop()
        self._stop = asyncio.Event()
        self._out = asyncio.Queue(maxsize=32)
        self._ready.set()
        delay = BACKOFF_MIN_S
        while not self._stop.is_set():
            connected = False
            try:
                LOG.info("connecting to %s", self.url)
                async with connect(self.url, max_size=MAX_WS_MESSAGE, compression=None,
                                   open_timeout=5, ping_interval=5, ping_timeout=5,
                                   close_timeout=2) as ws:
                    connected = True
                    delay = BACKOFF_MIN_S
                    self.clock.reset()
                    LOG.info("connected")
                    self._post_meta(("connected",))
                    await self._session(ws)
            except InvalidURI as exc:
                self.fatal_error = f"invalid URL: {exc}"
                return
            except (OSError, InvalidHandshake, TimeoutError, ConnectionClosed) as exc:
                LOG.warning("connection problem: %s", exc)
            if connected:
                self._post_meta(("disconnected",))
            if self._stop.is_set():
                break
            wait_s = delay * random.uniform(0.8, 1.2)
            delay = min(delay * 2.0, BACKOFF_MAX_S)
            LOG.info("reconnecting in %.1f s", wait_s)
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=wait_s)
            except TimeoutError:
                pass

    async def _session(self, ws: ClientConnection) -> None:
        assert self._stop is not None
        tasks = [
            asyncio.create_task(self._reader(ws)),
            asyncio.create_task(self._writer(ws)),
            asyncio.create_task(self._pinger()),
            asyncio.create_task(self._stop.wait()),
        ]
        try:
            done, _pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for t in done:
                if not t.cancelled() and t.exception() is not None:
                    raise t.exception()  # type: ignore[misc]
        finally:
            for t in tasks:
                t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    async def _pinger(self) -> None:
        self._enqueue_out(CMD_GET_STATUS)
        while True:
            self._enqueue_out(CMD_PING)
            await asyncio.sleep(1.0)

    async def _writer(self, ws: ClientConnection) -> None:
        assert self._out is not None
        while True:
            cmd = await self._out.get()
            self._seq = (self._seq + 1) & 0xFFFFFFFF
            await ws.send(build_control(cmd, self._seq, now_us()))   # t1 stamped at send
            if cmd not in (CMD_PING, CMD_GET_STATUS):
                LOG.info("sent %s (seq %d)", CMD_NAMES.get(cmd, cmd), self._seq)

    async def _reader(self, ws: ClientConnection) -> None:
        async for msg in ws:
            t_rx = now_us()
            if isinstance(msg, str):
                self.bad_messages += 1
                continue
            if self.recorder is not None:
                self.recorder.put(t_rx, msg)
            self._dispatch(msg, t_rx)

    def _dispatch(self, msg: bytes, t_rx: int) -> None:
        parsed = parse_header(msg)
        if parsed is None:
            self.bad_messages += 1
            return
        mtype, flags, frame_id, ts_us, payload = parsed
        if mtype == T_JPEG_CH1:
            if not _put_drop_oldest(self.jpeg_q, Frame(frame_id, ts_us, flags, payload, t_rx)):
                self.rx_jpeg_dropped += 1
        elif mtype == T_DETECTIONS:
            dets = parse_detections(payload)
            if dets is None:
                self.bad_messages += 1
                return
            self._post_meta(("det", DetResult(frame_id, ts_us, flags, dets, t_rx)))
        elif mtype == T_DETECTIONS_JSON:
            res = parse_detections_json(payload)
            if res is None:
                self.bad_messages += 1
                return
            fid, paired, dets = res
            fl = (flags | FLAG_PAIRED) if paired else (flags & ~FLAG_PAIRED)
            self._post_meta(("det", DetResult(fid, ts_us, fl, dets, t_rx)))
        elif mtype == T_STATUS:
            st = parse_status(payload)
            if st is None:
                self.bad_messages += 1
                return
            self._post_meta(("status", st))
        elif mtype == T_CONTROL_ACK:
            if len(payload) != CONTROL_ACK.size:
                self.bad_messages += 1
                return
            cmd, result, _r, seq, t1, t2, t3 = CONTROL_ACK.unpack_from(payload, 0)
            if cmd == CMD_PING:
                self.clock.add(t1, t2, t3, t_rx)
            elif cmd != CMD_GET_STATUS:
                self._post_meta(("ack", cmd, result, seq))
        # unknown types are ignored (forward compatibility)


def _put_drop_oldest(q: queue.Queue[Any], item: Any) -> bool:
    """Non-blocking put; if full, discard the oldest item. Returns False if something was dropped."""
    try:
        q.put_nowait(item)
        return True
    except queue.Full:
        pass
    try:
        q.get_nowait()
    except queue.Empty:
        pass
    try:
        q.put_nowait(item)
    except queue.Full:
        pass
    return False


# --------------------------------------------------------------------------------------
# Frame <-> detection matching - see references/sync-and-latency.md §2
# --------------------------------------------------------------------------------------
class Matcher:
    def __init__(self, window_ms: float, tolerance_us: int, max_frames: int = 64) -> None:
        self.window_us = int(window_ms * 1000)
        self.tol_us = tolerance_us
        self.max_frames = max_frames
        self.frames: collections.OrderedDict[int, Frame] = collections.OrderedDict()
        self.paired: dict[int, DetResult] = {}
        self.unpaired: collections.deque[DetResult] = collections.deque(maxlen=64)
        self.last_shown_id = -1
        self.last_shown_ts = -1
        self.matched = 0
        self.unmatched = 0
        self.skipped = 0
        self.late = 0

    def reset(self) -> None:
        self.frames.clear()
        self.paired.clear()
        self.unpaired.clear()
        self.last_shown_id = -1
        self.last_shown_ts = -1

    def add_frame(self, f: Frame) -> None:
        if f.frame_id <= self.last_shown_id:
            self.skipped += 1                       # out of order or duplicate
            return
        self.frames[f.frame_id] = f
        self.frames.move_to_end(f.frame_id)
        while len(self.frames) > self.max_frames:
            self.frames.popitem(last=False)
            self.skipped += 1

    def add_result(self, r: DetResult) -> None:
        if r.paired:
            if r.frame_id <= self.last_shown_id:
                self.late += 1
                return
            self.paired[r.frame_id] = r
            while len(self.paired) > 2 * self.max_frames:
                del self.paired[min(self.paired)]
                self.late += 1
        else:
            if self.last_shown_ts >= 0 and r.ts_us < self.last_shown_ts - self.tol_us:
                self.late += 1
                return
            self.unpaired.append(r)

    def _result_for(self, f: Frame) -> DetResult | None:
        r = self.paired.get(f.frame_id)
        if r is not None:
            return r
        best: DetResult | None = None
        best_dt = self.tol_us + 1
        for u in self.unpaired:
            dt = abs(u.ts_us - f.ts_us)
            if dt <= self.tol_us and dt < best_dt:
                best, best_dt = u, dt
        return best

    def pop_ready(self, now: int, running: bool) -> tuple[Frame, DetResult | None] | None:
        """Newest frame that is ready (has its result, window expired, or not running).
        Older waiting frames are skipped so the display never goes backward."""
        chosen: Frame | None = None
        chosen_res: DetResult | None = None
        for f in reversed(self.frames.values()):
            res = self._result_for(f) if running else None
            if not running or res is not None or now - f.t_rx_us >= self.window_us:
                chosen, chosen_res = f, res
                break
        if chosen is None:
            return None
        while self.frames:
            fid, _f = self.frames.popitem(last=False)
            if fid == chosen.frame_id:
                break
            self.skipped += 1
        self.last_shown_id = chosen.frame_id
        self.last_shown_ts = chosen.ts_us
        for k in [k for k in self.paired if k <= chosen.frame_id]:
            del self.paired[k]
        keep = [u for u in self.unpaired
                if u is not chosen_res and u.ts_us >= chosen.ts_us - self.tol_us]
        self.unpaired = collections.deque(keep, maxlen=64)
        if running:
            if chosen_res is not None:
                self.matched += 1
            else:
                self.unmatched += 1
        return chosen, chosen_res


class RateCounter:
    """Events per second over a sliding 1 s window."""

    def __init__(self) -> None:
        self._t: collections.deque[int] = collections.deque()

    def tick(self, t_us: int) -> None:
        self._t.append(t_us)

    def rate(self, now: int) -> float:
        while self._t and now - self._t[0] > 1_000_000:
            self._t.popleft()
        return float(len(self._t))


def _fmt(v: float, spec: str = ".1f") -> str:
    return "n/a" if v is None or (isinstance(v, float) and math.isnan(v)) else format(v, spec)


PALETTE = [(0, 255, 0), (0, 165, 255), (255, 0, 255), (255, 255, 0), (0, 0, 255), (255, 128, 0)]


# --------------------------------------------------------------------------------------
# UI / main thread
# --------------------------------------------------------------------------------------
class ViewerApp:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.display = not args.no_display
        self.class_names = [c.strip() for c in args.classes.split(",")] if args.classes else []
        self.clock = ClockSync()
        self.recorder = Recorder(Path(args.record)) if args.record else None
        self.net = NetClient(args.url, self.clock, self.recorder)
        self.matcher = Matcher(args.match_window_ms, int(args.tolerance_ms * 1000))
        self.status = Status()
        self.connected = False
        self.ever_connected = False
        self.last_event = "connecting..."
        self.rx_rate = RateCounter()
        self.show_rate = RateCounter()
        self.det_rate = RateCounter()
        self.e2e_ms: collections.deque[float] = collections.deque(maxlen=90)
        self.decode_errors = 0
        self.ch1_gaps = 0
        self.last_rx_id = -1
        self.last_show_us = 0
        self.last_print_us = 0
        self.last_placeholder_us = 0
        self.quit = False

    # ---- event handling ----
    def _drain(self) -> None:
        while True:
            try:
                item = self.net.meta_q.get_nowait()
            except queue.Empty:
                break
            kind = item[0]
            if kind == "det":
                res: DetResult = item[1]
                self.det_rate.tick(res.t_rx_us)
                self.matcher.add_result(res)
            elif kind == "status":
                self.status = item[1]
                if self.status.proto_version not in (0, PROTOCOL_VERSION):
                    self.last_event = f"protocol version mismatch: TX8 v{self.status.proto_version}"
            elif kind == "ack":
                _k, cmd, result, seq = item
                self.last_event = f"{CMD_NAMES.get(cmd, cmd)} -> {ACK_NAMES.get(result, result)} (seq {seq})"
                LOG.info(self.last_event)
            elif kind == "connected":
                self.connected = True
                self.matcher.reset()
                self.last_rx_id = -1
                self.last_event = "connected"
                if self.args.start and not self.ever_connected:
                    self.net.send_control(CMD_START)
                self.ever_connected = True
            elif kind == "disconnected":
                self.connected = False
                self.status = Status()
                self.last_event = "disconnected - reconnecting"
        while True:
            try:
                f = self.net.jpeg_q.get_nowait()
            except queue.Empty:
                break
            self.rx_rate.tick(f.t_rx_us)
            if self.last_rx_id >= 0 and f.frame_id > self.last_rx_id + 1:
                self.ch1_gaps += f.frame_id - self.last_rx_id - 1
            self.last_rx_id = f.frame_id
            self.matcher.add_frame(f)

    def _handle_key(self, key: int) -> None:
        if key in (ord("q"), 27):
            self.quit = True
        elif key == ord("s"):
            self.net.send_control(CMD_START)
            self.last_event = "START requested"
        elif key == ord("x"):
            self.net.send_control(CMD_STOP)
            self.last_event = "STOP requested"

    # ---- rendering ----
    def _e2e_estimate(self, ts_us: int, now: int) -> tuple[float, float] | None:
        best = self.clock.best()
        if best is None:
            return None
        offset, rtt = best
        return (now - (ts_us - offset)) / 1000.0, rtt / 2000.0

    def _hud_lines(self, now: int) -> list[str]:
        s = self.status
        state = STATE_NAMES.get(s.state, str(s.state)) if self.connected else "OFFLINE"
        fault = f" fault={FAULT_NAMES.get(s.fault, s.fault)}" if s.fault else ""
        best = self.clock.best()
        e2e = statistics.median(self.e2e_ms) if self.e2e_ms else math.nan
        err = best[1] / 2000.0 if best else math.nan
        rtt = best[1] / 1000.0 if best else math.nan
        m = self.matcher
        return [
            f"TX8 {state}{fault}  MX3 chips {s.mx3_chips} @ {s.mx3_clock_mhz} MHz  proto v{s.proto_version}",
            f"rx {self.rx_rate.rate(now):.0f} fps  shown {self.show_rate.rate(now):.0f}  "
            f"det {self.det_rate.rate(now):.0f} | TX8 ch1 {_fmt(s.fps_ch1)} infer {_fmt(s.fps_infer)}",
            f"TX8 latency p50/p99 {_fmt(s.lat_p50_ms)}/{_fmt(s.lat_p99_ms)} ms   "
            f"e2e ~{_fmt(e2e, '.0f')} ms (+/-{_fmt(err)}) est.  rtt {_fmt(rtt)} ms",
            f"CPU {_fmt(s.cpu_pct, '.0f')}%  SoC {_fmt(s.soc_temp_c)} C  MX3 {_fmt(s.mx3_temp_c)} C  "
            f"{_fmt(s.mx3_power_mw, '.0f')} mW  TX8 drops {s.dropped_ch1}/{s.dropped_ch2}",
            f"matched {m.matched} nobox {m.unmatched} skipped {m.skipped} late {m.late} "
            f"gaps {self.ch1_gaps} rxdrop {self.net.rx_jpeg_dropped} jpegerr {self.decode_errors} "
            f"window {self.args.match_window_ms:.0f} ms",
            f"[s] start  [x] stop  [q] quit   {self.last_event}",
        ]

    def _draw_hud(self, img: np.ndarray, now: int) -> None:
        scale = max(0.5, img.shape[1] / 2400.0)
        lines = self._hud_lines(now)
        line_h = int(32 * scale) + 6
        cv2.rectangle(img, (0, 0), (img.shape[1], line_h * len(lines) + 10), (0, 0, 0), -1)
        for i, text in enumerate(lines):
            cv2.putText(img, text, (10, line_h * (i + 1)), cv2.FONT_HERSHEY_SIMPLEX, scale,
                        (255, 255, 255), max(1, int(2 * scale)), cv2.LINE_AA)

    def _draw_dets(self, img: np.ndarray, res: DetResult) -> None:
        h, w = img.shape[:2]
        thick = max(2, w // 640)
        for d in res.dets:
            color = PALETTE[d.class_id % len(PALETTE)]
            p1 = (int(round(d.x1 * w)), int(round(d.y1 * h)))
            p2 = (int(round(d.x2 * w)), int(round(d.y2 * h)))
            cv2.rectangle(img, p1, p2, color, thick)
            name = self.class_names[d.class_id] if d.class_id < len(self.class_names) else str(d.class_id)
            cv2.putText(img, f"{name} {d.score:.2f}", (p1[0], max(15, p1[1] - 6)),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.4 * thick, color, thick, cv2.LINE_AA)

    def _show(self, frame: Frame, res: DetResult | None) -> None:
        now = now_us()
        self.show_rate.tick(now)
        est = self._e2e_estimate(frame.ts_us, now)
        if est is not None:
            self.e2e_ms.append(est[0])
        self.last_show_us = now
        if not self.display:
            return
        img = cv2.imdecode(np.frombuffer(frame.jpeg, dtype=np.uint8), cv2.IMREAD_COLOR)
        if img is None:
            self.decode_errors += 1
            return
        if res is not None:
            self._draw_dets(img, res)
        self._draw_hud(img, now)
        cv2.imshow(WINDOW, img)

    def _placeholder(self, now: int) -> None:
        img = np.zeros((720, 1280, 3), dtype=np.uint8)
        cv2.putText(img, f"waiting for video from {self.args.url}", (40, 400),
                    cv2.FONT_HERSHEY_SIMPLEX, 1.0, (200, 200, 200), 2, cv2.LINE_AA)
        self._draw_hud(img, now)
        cv2.imshow(WINDOW, img)

    def _print_stats(self, now: int) -> None:
        LOG.info(" | ".join(self._hud_lines(now)[:5]))

    # ---- main loop ----
    def run(self) -> int:
        if self.display:
            cv2.namedWindow(WINDOW, cv2.WINDOW_NORMAL)
            cv2.resizeWindow(WINDOW, 1280, 720)
        self.net.start()
        shown_any = False
        try:
            while not self.quit:
                self._drain()
                now = now_us()
                ready = self.matcher.pop_ready(now, self.connected and self.status.state == STATE_RUNNING)
                if ready is not None:
                    self._show(*ready)
                    shown_any = True
                print_every = 10_000_000 if self.display else 1_000_000
                if now - self.last_print_us >= print_every:
                    self.last_print_us = now
                    self._print_stats(now)
                if self.net.fatal_error:
                    LOG.error(self.net.fatal_error)
                    return 2
                if self.display:
                    stale = not shown_any or now - self.last_show_us > 1_000_000
                    if stale and now - self.last_placeholder_us > 500_000:
                        self.last_placeholder_us = now
                        self._placeholder(now)
                    self._handle_key(cv2.waitKey(5) & 0xFF)
                    try:
                        if cv2.getWindowProperty(WINDOW, cv2.WND_PROP_VISIBLE) < 1:
                            self.quit = True
                    except cv2.error:
                        self.quit = True
                else:
                    time.sleep(0.005)
        except KeyboardInterrupt:
            pass
        finally:
            self.net.stop()
            if self.recorder is not None:
                self.recorder.close()
                if self.recorder.dropped:
                    LOG.warning("recorder dropped %d messages", self.recorder.dropped)
            if self.display:
                cv2.destroyAllWindows()
        return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="TX8 base-station viewer (WebSocket protocol v1)")
    ap.add_argument("--url", default="ws://127.0.0.1:8081/ws",
                    help="TX8 endpoint, e.g. ws://<tx8-ip>:8081/ws (default: local fake server)")
    ap.add_argument("--start", action="store_true", help="send START after the first connection")
    ap.add_argument("--record", metavar="DIR", help="record all received messages to DIR (raw, replayable)")
    ap.add_argument("--no-display", action="store_true", help="no window; print stats every second")
    ap.add_argument("--match-window-ms", type=float, default=150.0,
                    help="max time a frame waits for its detections while RUNNING (default 150)")
    ap.add_argument("--tolerance-ms", type=float, default=17.0,
                    help="timestamp tolerance for unpaired detections (default 17 = half frame @30fps)")
    ap.add_argument("--classes", default="", help="comma-separated class names, e.g. person,vehicle,animal")
    ap.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    return ViewerApp(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
