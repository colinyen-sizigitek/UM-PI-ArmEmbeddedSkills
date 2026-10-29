# CH2 JPEG decode with TurboJPEG

TX8 has no hardware JPEG decoder, so CH2 (640x640 MJPEG @30) is decoded on the Cortex-A53
with libjpeg-turbo (NEON-accelerated) through its TurboJPEG C API. CH1 is never decoded.

Sources:
- TurboJPEG API docs: https://libjpeg-turbo.org/Documentation/Documentation
  (2.1.x API reference and 3.x API reference are separate pages — read the one matching the
  installed header).
- Header on the board: `/usr/include/turbojpeg.h` — the authority for signatures.

## 1. Which version is installed

Ubuntu 22.04 ships libjpeg-turbo **2.1.2** (`libturbojpeg` runtime, `libturbojpeg0-dev`
headers, universe). Check on the board:

```
ssh umpi 'dpkg -l | grep -i turbojpeg'
ssh umpi 'dpkg -L libturbojpeg0-dev'                  # header, .so, pkg-config file
ssh umpi 'grep -n "tjDecompress2\|tj3Decompress8" /usr/include/turbojpeg.h'
```
If the dev package is missing, ask before installing it. Link with `-lturbojpeg` (or the
pkg-config file listed by `dpkg -L`).

## 2. TurboJPEG 2.1 API used here

| Function | Purpose |
|---|---|
| `tjhandle tjInitDecompress(void)` | create a decompressor (one per thread; handles are not shared) |
| `int tjDecompressHeader3(tjhandle, const unsigned char* jpegBuf, unsigned long jpegSize, int* width, int* height, int* jpegSubsamp, int* jpegColorspace)` | read size/subsampling without decoding |
| `int tjDecompress2(tjhandle, const unsigned char* jpegBuf, unsigned long jpegSize, unsigned char* dstBuf, int width, int pitch, int height, int pixelFormat, int flags)` | decode into caller buffer; `width/height` = desired (scaled) size, `pitch` = bytes per row (0 = width x pixel size) |
| `tjscalingfactor* tjGetScalingFactors(int* numScalingFactors)` | list supported `{num, denom}` scaling factors |
| `TJSCALED(dimension, scalingFactor)` | macro: scaled dimension (rounds up) |
| `char* tjGetErrorStr2(tjhandle)` / `int tjGetErrorCode(tjhandle)` | error text; `TJERR_WARNING` vs `TJERR_FATAL` |
| `int tjDestroy(tjhandle)` | free the handle |

Pixel formats: `TJPF_RGB`, `TJPF_BGR` (3 bytes per pixel, `tjPixelSize[pf]`). Decode directly
into the channel order the model expects (Ultralytics models expect RGB) — no swizzle pass.

Flags (bitwise OR):
- `TJFLAG_FASTDCT` — faster, less accurate integer IDCT. On libjpeg-turbo the default
  accurate IDCT is also SIMD-accelerated, so the gain is small; measure speed AND check
  detection output (score/box differences on a fixed frame set) before adopting.
- `TJFLAG_FASTUPSAMPLE` — nearest-neighbour chroma upsampling instead of smooth upsampling
  for 4:2:0/4:2:2 sources. Small speed gain, slight chroma edge artifacts; usually harmless
  for detection — verify like above.
- `TJFLAG_STOPONWARNING` — treat warnings (e.g. truncated data) as fatal. Recommended for CH2:
  a frame with corrupt data is better dropped than fed to the model.

## 3. Decode into a reused buffer

```cpp
#include <turbojpeg.h>

class Ch2Decoder {
 public:
  bool init(int out_w, int out_h) {           // 640x640, or 320x320 for the fallback
    h_ = tjInitDecompress();
    w_ = out_w; hgt_ = out_h;
    return h_ != nullptr;
  }
  ~Ch2Decoder() { if (h_) tjDestroy(h_); }

  // dst: pooled RGB buffer of w_*hgt_*3 bytes, 64-byte aligned, allocated at startup.
  // Returns false if the frame must be dropped.
  bool decode(const uint8_t* jpg, size_t n, uint8_t* dst) {
    int w = 0, h = 0, ss = 0, cs = 0;
    if (tjDecompressHeader3(h_, jpg, static_cast<unsigned long>(n), &w, &h, &ss, &cs) != 0) {
      last_error_ = tjGetErrorStr2(h_); return false;
    }
    if (!dims_ok(w, h)) { last_error_ = "unexpected JPEG size"; return false; }
    const int flags = TJFLAG_STOPONWARNING | cfg_flags_;   // cfg_flags_: FASTDCT/FASTUPSAMPLE if adopted
    if (tjDecompress2(h_, jpg, static_cast<unsigned long>(n), dst, w_, 0, hgt_, TJPF_RGB, flags) != 0) {
      last_error_ = tjGetErrorStr2(h_);
      return false;                           // with STOPONWARNING, warnings also land here
    }
    return true;
  }
 private:
  bool dims_ok(int w, int h) const;           // full size == w_ x hgt_, or scaled size fits exactly
  tjhandle h_ = nullptr;
  int w_ = 0, hgt_ = 0, cfg_flags_ = 0;
  const char* last_error_ = "";
};
```

Rules:
- One handle per decode thread, created at startup; no per-frame allocation (never use
  `tjAlloc` per frame).
- Decode straight from the V4L2 mmap pointer; re-queue the V4L2 buffer right after decode.
- The destination must not change size at runtime; reject unexpected input sizes
  (a camera mode change would otherwise overflow the buffer).
- Count failures by reason (header, decode, warning). N consecutive failures (e.g. 30) ->
  report FAULT Decode via the state machine; isolated failures -> drop and count.
- `last_error_` points into the handle; copy it if it must outlive the next call.

## 4. Scaled decode (320x320 fallback)

If the 640x640 model misses the targets (see `architecture.md` latency budget), the fallback
is a 320x320 model with a **1/2 scaled decode** of the same 640x640 CH2 stream — the IDCT
works on reduced blocks, so it is significantly cheaper than decoding full size and
resizing (verify the factor on TX8).

```cpp
int n = 0;
const tjscalingfactor* sf = tjGetScalingFactors(&n);
bool half_ok = false;
for (int i = 0; i < n; ++i)
  if (sf[i].num == 1 && sf[i].denom == 2) half_ok = true;
// Desired size: TJSCALED(640, {1,2}) == 320. Pass width=320, height=320 to tjDecompress2:
// TurboJPEG picks the largest scaling factor whose result fits in the desired size.
```

- Check that the scaled size is exactly 320x320 (`TJSCALED`), else the model input mismatches.
- With scaling, the reduced-size IDCT path is used; `TJFLAG_FASTDCT` may have little or no
  effect — measure instead of assuming.
- Alternatively, if the camera offers a native 320x320 MJPEG mode (`--list-formats-ext`),
  compare: native mode reduces USB bandwidth and decode further, but the FOV/crop may differ.

## 5. TurboJPEG 3 differences (if a newer libjpeg-turbo is ever used)

libjpeg-turbo 3.0 introduced a new stateful API (`tj3*`), keeping the 2.x functions as
deprecated wrappers. Do not mix styles in one code base. Main differences:

| 2.1 | 3.x |
|---|---|
| `tjInitDecompress()` | `tj3Init(TJINIT_DECOMPRESS)` |
| `tjDecompressHeader3(h, buf, size, &w, &h, &ss, &cs)` | `tj3DecompressHeader(h, buf, size)` then `tj3Get(h, TJPARAM_JPEGWIDTH)` etc. |
| flags argument (`TJFLAG_FASTDCT`, ...) | parameters: `tj3Set(h, TJPARAM_FASTDCT, 1)`, `TJPARAM_FASTUPSAMPLE`, `TJPARAM_STOPONWARNING` |
| scaling via desired width/height | `tj3SetScalingFactor(h, sf)` before decode |
| `tjDecompress2(h, buf, size, dst, w, pitch, h, pf, flags)` | `tj3Decompress8(h, buf, size, dst, pitch, pf)` |
| `unsigned long` sizes | `size_t` sizes |
| `tjDestroy`, `tjGetErrorStr2` | `tj3Destroy`, `tj3GetErrorStr` |

Ubuntu 22.04 has 2.1.x: write against the 2.1 API unless the programmer has deliberately
installed 3.x (then check the header and use `tj3*` consistently).

## 6. Measure ms/frame

Two measurements, both on TX8:
1. **Micro-benchmark**: capture 100 real CH2 frames to files (see `v4l2-uvc-capture.md` §5),
   decode each 20 times in a loop into the same buffer, record `CLOCK_MONOTONIC` per decode,
   report p50/p99/max. Run with the app's flags and with/without FASTDCT/FASTUPSAMPLE.
2. **In-pipeline**: the decode stage histogram from `latency-and-metrics.md` under the full
   load (CH1 streaming, MX3 running) — contention on the shared 1 MB L2 and DRAM makes
   this slower than the micro-benchmark.
Report both with the CPU frequency (`cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq`).
Expect single-digit to low-teens ms for 640x640 on one A53 core — verify on TX8.

## 7. Why not OpenCV

- Project rule: no OpenCV in production pre/post paths (DESIGN §3.3).
- `cv::imdecode` allocates a `cv::Mat` per call (unless carefully reusing), decodes to BGR
  only, hides flags like STOPONWARNING and gives no control over the IDCT/upsampling choice.
- It adds a large dependency (Ubuntu 22.04 OpenCV 4.5.4) to the drone image for something
  TurboJPEG does directly; it still ends up calling libjpeg(-turbo) underneath.
- OpenCV remains fine for debug tools on TX8 and for the Windows viewer.

## 8. Checklist
- [ ] Header checked; 2.1 vs 3.x API chosen consistently.
- [ ] One handle per thread, destination buffers preallocated, sizes validated per frame.
- [ ] `TJFLAG_STOPONWARNING` set; failures counted by reason.
- [ ] Decode p50/p99 measured standalone and in-pipeline; flags justified by numbers.
- [ ] Fallback 320x320 path tested (scaled size exact, model input matches).
