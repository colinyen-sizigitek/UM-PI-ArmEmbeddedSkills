# Pre-processing and post-processing glue

What the host CPU does around the MX3: turn the decoded CH2 RGB u8 image into the float32
NHWC tensor the DFP expects, and turn the DFP output into a short list of detections in CH1
coordinates. Box decode, sigmoid and (for NMS-free models) the one-to-one selection stay inside
the compiled graph (DESIGN §3.2). Host work = normalize/convert + threshold + top-K + mapping.

Related skills: `um-pi-mx3-runtime-integration` (FeatureMap API, callbacks, MxAcclMT),
`um-pi-mx3-model-compile` (what ends up inside the DFP vs `_pre/_post.onnx`), `um-pi-mx3-model-selection`
(model and classes), `um-pi-cpp-performance` (NEON kernels and their measurement).

## 1. First: find out what the DFP really expects and produces

Never assume shapes, layouts or normalization from the model's name. Gather facts:
1. From the compile step (skill `um-pi-mx3-model-compile`): the `mx_nc` command line and log,
   whether `--autocrop` produced `*_pre.onnx` / `*_post.onnx`, and the input shape `-is`.
2. On the board, print the DFP's input/output feature-map shapes at startup using the
   runtime's model-info API (check `/usr/include/memx/accl/MxAccl.h` and the docs of
   `um-pi-mx3-runtime-integration` for the exact call — do not guess its name).
3. Ask the programmer for the training pipeline's preprocessing (RGB or BGR, scale, mean/std)
   if it is not obvious from the export script.

Write the findings into the code as constants with a comment naming the source, and fail at
startup if the runtime-reported shapes differ.

Questions to answer before coding:
| Question | Typical answer (verify!) |
|---|---|
| Input layout | float32 NHWC 1x640x640x3 (MX3 host interface is float32 NHWC) |
| Channel order | RGB for Ultralytics models; BGR for some others (e.g. YOLOX conventions) |
| Normalization | Ultralytics: `x / 255`, no mean/std. Others: mean/std per channel, or raw 0..255 |
| Normalization inside the graph? | Sometimes (`_pre.onnx` or a Div/Mul node at the input). Then the host feeds 0..255 floats |
| Output | end2end NMS-free: one tensor like [1, 300, 6]; raw head: several tensors |
| Box format | end2end Ultralytics: x1, y1, x2, y2 in input pixels (0..640), score, class — verify |

If `--autocrop` cut the box decode into `_post.onnx`, the host would have to run it — that
contradicts the design. Go back to `um-pi-mx3-model-compile` and keep the decode in the DFP (or
use the MemryX YOLO C++ post helpers https://developer.memryx.com/runtime/mxprepost.html
only after measuring their cost on TX8).

## 2. u8 RGB -> float32 NHWC

CH2 is already 640x640, so there is **no resize and no letterbox** — just a per-element
affine conversion: `out[i] = in[i] * scale[c] + bias[c]`.
- Ultralytics: `scale = 1/255`, `bias = 0` for all channels.
- mean/std models: `scale[c] = 1/(255*std[c])`, `bias[c] = -mean[c]/std[c]` (mean/std in 0..1 units).
- Normalization inside the graph: `scale = 1`, `bias = 0`.

Baseline NEON kernel for the uniform-scale case (correct, not tuned; tuning and A53 pipe
scheduling belong to skill `um-pi-cpp-performance`):

```cpp
#include <arm_neon.h>
#include <cstddef>
#include <cstdint>

// n = number of bytes (640*640*3), multiple of 16 for our sizes; tail handled anyway.
// Software-pipelined with L1D prefetch 256 B ahead to hide DDR4 latency on in-order Cortex-A53.
void u8_to_f32_scaled(const uint8_t* __restrict in, float* __restrict out, size_t n, float s) {
  const float32x4_t vs = vdupq_n_f32(s);
  size_t i = 0;
  for (; i + 16 <= n; i += 16) {
    __builtin_prefetch(in + i + 256, 0, 3);
    const uint8x16_t b = vld1q_u8(in + i);
    const uint16x8_t lo = vmovl_u8(vget_low_u8(b));
    const uint16x8_t hi = vmovl_u8(vget_high_u8(b));
    const float32x4_t f0 = vcvtq_f32_u32(vmovl_u16(vget_low_u16(lo)));
    const float32x4_t f1 = vcvtq_f32_u32(vmovl_u16(vget_high_u16(lo)));
    const float32x4_t f2 = vcvtq_f32_u32(vmovl_u16(vget_low_u16(hi)));
    const float32x4_t f3 = vcvtq_f32_u32(vmovl_u16(vget_high_u16(hi)));
    vst1q_f32(out + i + 0,  vmulq_f32(f0, vs));
    vst1q_f32(out + i + 4,  vmulq_f32(f1, vs));
    vst1q_f32(out + i + 8,  vmulq_f32(f2, vs));
    vst1q_f32(out + i + 12, vmulq_f32(f3, vs));
  }
  for (; i < n; ++i) out[i] = static_cast<float>(in[i]) * s;
}
```

- Per-channel mean/std: deinterleave with `vld3q_u8` (Arm doc 102467 example), apply per
  channel, re-interleave with `vst3q_f32` — or precompute a 256-entry LUT per channel
  (3 KB, fits L1) and measure which is faster on A53.
- The output is 4.9 MB per frame: it does not fit in the 1 MB L2. It is a streaming write;
  **write directly into the `Mx3Engine` ring buffer slot** (`s.in[0]`) rather than an intermediate
  float pool to eliminate a redundant 4.9 MB `memcpy` per frame (saves ~147 MB/s DRAM traffic at 30 fps).

## 3. Writing into the MX3 FeatureMap

Two patterns — choose together with skill `um-pi-mx3-runtime-integration`:
- **Auto-threaded `MxAccl::connect_stream`**: in the input callback, take the next float
  buffer from Q3 (bounded wait, checking the stop flag; returning `false` ends the stream —
  that is how STOPPING ends it), call `fmap->set_data(buf)` and return the buffer to the pool
  once `set_data` has copied it (verify the copy semantics in the installed header).
- **Manual `MxAcclMT` (recommended)**: `send_input(...)` / `receive_output(...)` with explicit timeouts from
  our own threads. Easier to reason about timeouts and FAULT; check exact signatures in the
  header before use.

Either way: no heap allocation, no logging I/O and no unbounded waits inside callbacks.
Carry `frame_id` and the CH2 `ts_us` alongside each input (FIFO order: the k-th output
belongs to the k-th input of that stream — verify ordering guarantees in the runtime docs).

## 4. Output parsing for NMS-free end2end heads

YOLOv10 and YOLO26 one-to-one heads exported end-to-end give a fixed number of candidate rows
(often 300) of 6 floats. Typical row: `x1, y1, x2, y2, score, class` — **confirm the field
order and coordinate units by dumping one output for a known image** and drawing it on the
base station (or in a Python prototype on the dev machine).

Do not assume the rows are sorted by score even if the exporter uses top-k; the branchless
compaction below works either way.

```cpp
struct Cand { float x1, y1, x2, y2, score; uint16_t cls; };

// rows: N x 6 floats. Keeps at most `cap` candidates with score >= thr.
// `out` must hold cap + 1 elements: out[cap] is a scratch slot that absorbs writes once
// the array is full, so kept candidates are never overwritten.
// Branchless: always write, advance the cursor by the comparison result.
size_t threshold_compact(const float* rows, size_t n, float thr, Cand* out, size_t cap) {
  size_t k = 0;
  for (size_t i = 0; i < n; ++i) {
    const float* r = rows + 6 * i;
    const float sc = r[4];
    const size_t keep = static_cast<size_t>(sc >= thr) & static_cast<size_t>(k < cap);
    Cand& c = out[k < cap ? k : cap];                 // compiles to csel; scratch slot absorbs overflow
    // Sanitize NaN/inverted coordinates branchlessly before writing
    const float x1 = r[0] < r[2] ? r[0] : r[2];
    const float x2 = r[0] < r[2] ? r[2] : r[0];
    const float y1 = r[1] < r[3] ? r[1] : r[3];
    const float y2 = r[1] < r[3] ? r[3] : r[1];
    c = Cand{x1, y1, x2, y2, sc, static_cast<uint16_t>(r[5] >= 0.f ? r[5] : 0.f)};
    k += keep;
  }
  return k;
}
```

Then top-K (K from config, e.g. 50): if `k <= K` done; otherwise partial selection
(`std::nth_element` on at most 300 elements, no allocation — `out` is a preallocated array).
If the rows are verified sorted, top-K is simply the first K above threshold. Set
`kDetFlagTruncated` in the DETECTIONS header when candidates were cut.

- NaN scores compare false -> dropped, which is the safe behaviour; count them (model or
  data problem).
- Class reduction (1-3 classes, DESIGN §3.2): the class id is the reduced model's index; map
  to names through a config table, never hard-coded strings in the hot path. Filter unwanted
  classes with a 64-bit mask test (branchless) if the model has extra classes.
- For raw (non-end2end) heads with 8400 anchors, use the 16-anchor NEON fast-skip kernel in
  `um-pi-cpp-performance/references/neon-intrinsics.md` §6 (`vmaxvq_u32` early-out).

## 5. Coordinates: CH2 model space -> CH1 normalized

The protocol sends boxes normalized to 0..1 in **CH1 image coordinates** (see
`output-websocket.md`). Steps:
1. Model space -> CH2 normalized: `u = x / 640`, `v = y / 640` (or whatever the verified
   output unit is; some heads already output 0..1).
2. CH2 normalized -> CH1 normalized through a configured rectangle `ch2_in_ch1 = {x0, y0, w, h}`
   (normalized CH1 units): `X = x0 + u * w`, `Y = y0 + v * h`. Clamp to 0..1.

The rectangle depends on how the camera produces the 640x640 stream — **verify, ask the
programmer**:
| Camera behaviour | Rectangle |
|---|---|
| Center crop of a 1080x1080 region of the same sensor | `{420/1920, 0, 1080/1920, 1}` |
| Full FOV squeezed anisotropically to 1:1 | `{0, 0, 1, 1}` |
| Different sensor or lens | no fixed mapping — needs calibration; ask before proceeding |

Verification procedure: point the camera at a target with sharp corners, run detection or
mark the corners manually in a saved CH2 frame and the matching CH1 frame, compute the
rectangle, and record the result in the config with the date and camera serial.

Temporal caveat: CH1 and CH2 are independent streams; their frames are not captured at the
same instant. The sender pairs each CH2 result with the CH1 frame whose timestamp is closest
(within half a frame period, ~16.7 ms at 30 fps). Fast motion therefore shows up to
~half-frame misalignment — document it, do not try to hide it with interpolation on TX8.

## 6. Measurement
- Histograms for "preprocess" and "postprocess" stages (`latency-and-metrics.md`).
- A golden test: 20 saved CH2 frames -> preprocess -> compare float buffer against a Python
  reference (max abs diff < 1e-6 for x/255); output parsing against a recorded DFP output dump.
- Run the golden test on TX8 after every change of flags, kernels or model.
