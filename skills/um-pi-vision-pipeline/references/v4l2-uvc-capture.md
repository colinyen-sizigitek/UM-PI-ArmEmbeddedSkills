# V4L2 / UVC MJPEG capture

How to capture CH1 (1920x1080 MJPEG @30) and CH2 (640x640 MJPEG @30) from a USB UVC camera
on TX8 (Linux 5.15, `uvcvideo` driver) with mmap streaming, correct timestamps, corruption
checks, clean stop of CH2 and recovery from USB disconnects.

Primary source: Linux kernel V4L2 userspace API (5.15):
https://www.kernel.org/doc/html/v5.15/userspace-api/media/v4l/v4l2.html
(streaming I/O: `mmap.html`, buffers: `buffer.html`, `vidioc-reqbufs.html`, `vidioc-qbuf.html`).
Headers on the board: `/usr/include/linux/videodev2.h`.

## 1. Discover the camera on the board

```
ssh umpi 'v4l2-ctl --list-devices'
ssh umpi 'for d in /dev/video*; do echo "== $d"; v4l2-ctl -d $d --all | head -20; done'
ssh umpi 'v4l2-ctl -d /dev/video0 --list-formats-ext'
ssh umpi 'ls -l /dev/v4l/by-id/ /dev/v4l/by-path/'
ssh umpi 'lsusb -t'          # negotiated speed per device: 5000M = USB 3, 480M = USB 2
```
(`v4l2-ctl` is in package `v4l-utils`; if missing, ask before installing.)

Decide from the output:
- **Two capture nodes** (composite UVC device with two video functions, or two cameras):
  open each node separately — this is the normal case for simultaneous 1080p + 640x640.
- **One capture node** listing both sizes: a single V4L2 capture node streams one format
  at a time. Simultaneous CH1 + CH2 is then impossible from that node — tell the programmer;
  do not "solve" it by decoding and scaling CH1 on TX8 without agreement (CPU cost).
- Ignore nodes whose caps show only `Metadata Capture` (uvcvideo creates one per function).
- Open devices by stable path (`/dev/v4l/by-id/...-video-index0`), not `/dev/videoN`, which
  can renumber after a reconnect. Make the paths configurable.
- Confirm with the programmer that CH1 and CH2 see the same sensor/FOV (box mapping depends
  on it, see `preprocess-postprocess.md`).

## 2. Open and configure

```cpp
#include <linux/videodev2.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <fcntl.h>
#include <poll.h>
#include <cerrno>

static int xioctl(int fd, unsigned long req, void* arg) {
  int r;
  do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
  return r;
}

int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);

v4l2_capability cap{};
xioctl(fd, VIDIOC_QUERYCAP, &cap);
// require (cap.device_caps & V4L2_CAP_VIDEO_CAPTURE) && (cap.device_caps & V4L2_CAP_STREAMING)

v4l2_format fmt{};
fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
fmt.fmt.pix.width = 1920;              // CH2: 640
fmt.fmt.pix.height = 1080;             // CH2: 640
fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_MJPEG;
fmt.fmt.pix.field = V4L2_FIELD_NONE;
xioctl(fd, VIDIOC_S_FMT, &fmt);
// The driver may adjust: ALWAYS re-check fmt.fmt.pix.{width,height,pixelformat} after S_FMT
// and fail loudly if they differ from what was requested.

v4l2_streamparm parm{};
parm.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
parm.parm.capture.timeperframe.numerator = 1;
parm.parm.capture.timeperframe.denominator = 30;
xioctl(fd, VIDIOC_S_PARM, &parm);
// Re-check parm.parm.capture.timeperframe after the call (driver picks the nearest interval).
```

Frame rate traps:
- Many UVC cameras lower the frame rate in low light when auto-exposure priority is on.
  List controls with `v4l2-ctl -d <dev> -l` and look for `exposure_dynamic_framerate` /
  `exposure_auto_priority` (names vary). Setting it is a camera setting, not a system
  setting — still confirm with the programmer, then set it at startup via `VIDIOC_S_CTRL`.
- Measure the real rate from timestamps (`latency-and-metrics.md`), never trust S_PARM.

## 3. mmap buffers and streaming

```cpp
v4l2_requestbuffers req{};
req.count = 8;                         // CH1: 8, CH2: 4 (starting point)
req.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
req.memory = V4L2_MEMORY_MMAP;
xioctl(fd, VIDIOC_REQBUFS, &req);      // driver may return fewer: use req.count

for (unsigned i = 0; i < req.count; ++i) {
  v4l2_buffer b{};
  b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  b.memory = V4L2_MEMORY_MMAP;
  b.index = i;
  xioctl(fd, VIDIOC_QUERYBUF, &b);
  void* p = mmap(nullptr, b.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, b.m.offset);
  // store {p, b.length}; check p != MAP_FAILED
  xioctl(fd, VIDIOC_QBUF, &b);
}
int type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
xioctl(fd, VIDIOC_STREAMON, &type);
```

Capture loop (one thread per channel):

```cpp
pollfd pfd{fd, POLLIN, 0};
for (;;) {
  int pr = poll(&pfd, 1, 200);                 // timeout: detect a silent camera
  if (pr == 0) { ++stats.poll_timeouts; if (stalled_too_long()) report_stall(); continue; }
  if (pr < 0) { if (errno == EINTR) continue; handle_fatal(errno); break; }
  if (pfd.revents & (POLLERR | POLLHUP)) { handle_disconnect(); break; }

  v4l2_buffer b{};
  b.type = V4L2_BUF_TYPE_VIDEO_CAPTURE;
  b.memory = V4L2_MEMORY_MMAP;
  if (xioctl(fd, VIDIOC_DQBUF, &b) < 0) {
    if (errno == EAGAIN) continue;
    if (errno == ENODEV || errno == EIO) { handle_disconnect(); break; }
    handle_fatal(errno); break;
  }
  requeue_returned_buffers();                  // indices handed back by the consumer
  if ((b.flags & V4L2_BUF_FLAG_ERROR) || !jpeg_looks_complete(buf[b.index].p, b.bytesused)) {
    ++stats.corrupt; xioctl(fd, VIDIOC_QBUF, &b); continue;
  }
  const uint64_t ts_us = uint64_t(b.timestamp.tv_sec) * 1000000u + uint64_t(b.timestamp.tv_usec);
  push_or_drop_oldest(FrameRef{b.index, buf[b.index].p, b.bytesused, ts_us, b.sequence});
}
```

- `b.sequence` gaps reveal frames dropped by the driver; count them separately from our drops.
- Only the capture thread calls QBUF/DQBUF on its fd; consumers return indices through an
  SPSC return queue (see `architecture.md` §3).

## 4. Timestamps

- Check `b.flags & V4L2_BUF_FLAG_TIMESTAMP_MASK` equals `V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC`
  once at startup; if not, log an error and fall back to `clock_gettime(CLOCK_MONOTONIC)` at
  DQBUF (and mark the measurements as "DQBUF-based").
- `b.flags & V4L2_BUF_FLAG_TSTAMP_SRC_MASK`: uvcvideo reports start-of-exposure/start-of-frame
  (`V4L2_BUF_FLAG_TSTAMP_SRC_SOE`), so the capture-to-DQBUF interval contains the USB
  transfer time of the frame. Verify the flag on TX8 and document it.
- The uvcvideo `clock` module parameter selects the clock (default monotonic). Read
  `/sys/module/uvcvideo/parameters/clock` — do not change it.
- This timestamp is the `ts_us` of the protocol and the start of every latency measurement.
  Use `CLOCK_MONOTONIC` everywhere else in the app for comparisons.

## 5. Corrupt / truncated MJPEG

UVC MJPEG frames can be truncated (USB errors, iso packet loss) without the error flag.
Cheap structural check before forwarding or decoding:

```cpp
inline bool jpeg_looks_complete(const uint8_t* p, size_t n) {
  if (n < 4 || p[0] != 0xFF || p[1] != 0xD8) return false;     // SOI
  // Some cameras pad after EOI: search the last bytes backwards for FF D9.
  const size_t lim = n > 64 ? n - 64 : 0;
  for (size_t i = n - 1; i > lim; --i)
    if (p[i] == 0xD9 && p[i - 1] == 0xFF) return true;          // EOI
  return false;
}
```

- For CH1 this is the only check (no decode on TX8). Forward only frames that pass.
- If the frame passes but a real EOI is missing, the base station decoder will complain —
  the viewer must tolerate a failed `imdecode` (skill `um-pi-basestation-viewer`).
- Some UVC cameras send MJPEG without Huffman tables (DHT). Test with one captured CH2 frame
  through `tjDecompress2`; if decoding fails with a Huffman error, insert the standard DHT
  tables (ITU-T T.81 Annex K) before SOS. Verify on TX8 with the real camera.
- For debugging, dump a frame: `v4l2-ctl -d <dev> --set-fmt-video=width=640,height=640,pixelformat=MJPG --stream-mmap --stream-count=1 --stream-to=/tmp/f.jpg`.

## 6. USB bandwidth

- `lsusb -t` shows each camera's speed. TX8 has USB 3.2 Gen1 x1 and USB 2.0 x2 (see skill
  `um-pi-platform`); verify which port the camera uses on the carrier.
- UVC streaming is usually isochronous: the driver reserves bandwidth at STREAMON based on the
  camera's advertised max payload, not the actual JPEG size. Two streams on a USB 2.0
  link can fail with `ENOSPC` on STREAMON even if the real MJPEG bitrate is small.
  - Mitigation: start CH1 first (always on), CH2 second; on `ENOSPC` report FAULT CameraCh2
    with a clear message ("USB bandwidth reservation failed"), and suggest a USB 3 port or a
    camera alt-setting/quality change to the programmer.
- Rough MJPEG bitrates (camera- and scene-dependent, measure `bytesused`): 1080p30 several
  MB/s, 640x640@30 around 1-3 MB/s. Log average and max `bytesused` per channel.
- USB autosuspend can stall cameras after idle; check
  `cat /sys/module/usbcore/parameters/autosuspend`. Changing it is a system setting:
  propose, do not apply.

## 7. Stopping CH2 when inference turns off

Order (executed by the control state machine in STOPPING, see `inference-control.md`):
1. Stop the CH2 capture thread loop (atomic flag; the 200 ms poll timeout bounds the wait).
2. Wait (with timeout, e.g. 300 ms) until T3 has returned every CH2 buffer index it holds.
3. `VIDIOC_STREAMOFF` — this also removes all buffers from the driver queues.
4. `munmap` every buffer, then `VIDIOC_REQBUFS` with `count = 0` to free driver memory.
5. Either `close(fd)` (simplest, frees USB bandwidth reservation) or keep the fd open to save
   start time. Measure the start latency both ways; keep the fd open only if it matters.

Never munmap while another thread may read the buffer — that is a use-after-free that
crashes far from the cause.

## 8. Disconnect and reconnect

- Signs: `ENODEV` from DQBUF/QBUF, `POLLERR`/`POLLHUP`, `EIO`.
- Reaction: stop the channel thread, munmap, close, report STATUS (CH1 -> fault flag but the
  pipeline keeps running for control/status; CH2 while RUNNING -> state FAULT).
- Reopen loop: try the stable by-id path with backoff 200 ms -> 400 ms -> ... -> 2 s cap.
  After open, redo S_FMT/S_PARM/REQBUFS/STREAMON and re-verify the format.
  (libudev monitoring is optional; polling the path is simpler and enough.)
- CH1 reconnect is automatic. CH2 reconnect after FAULT follows the control policy
  (automatic retry while the last command is still `start`).
- Count reconnects; a camera that reconnects repeatedly indicates power or cable problems —
  report it, do not hide it.

## 9. Checklist
- [ ] Formats verified after S_FMT / S_PARM; real fps measured from timestamps.
- [ ] Timestamp flags checked at startup and logged.
- [ ] SOI/EOI check on every frame; corrupt and driver-sequence gaps counted.
- [ ] Every poll has a timeout; ENODEV handled; reconnect with backoff.
- [ ] CH2 STREAMOFF + munmap + REQBUFS(0) after all buffers returned.
- [ ] No system settings changed without approval.
