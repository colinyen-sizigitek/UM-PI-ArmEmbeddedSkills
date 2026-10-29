# Quantization and accuracy validation

## What the compiler does to precision
- Weights: **INT8 by default**; per-layer INT4 or INT16 possible (`-bt`), INT16 implemented in SW.
- Activations: Group-BF16 (shared-exponent bfloat) on chip.
- Host <-> chip transfer: `--input_format` (`FP32`, `BF16` default, `GBFloat80`, `RGB888`) and the
  output format; the host always hands float32 NHWC to the runtime, the runtime converts.
- No calibration dataset and no retraining are required (post-training, data-free). MemryX's
  reference: YOLOv8 COCO mAP50-95 CUDA vs MXA — n 37.3/37.1, s 44.9/44.7, m 50.2/49.9
  (https://developer.memryx.com/tutorials/accuracy/yolov8_accuracy/yolov8_accuracy.html).
  Your fine-tuned / pruned model can behave differently: **measure**.

## Budget (default; agree with the programmer)
| Metric (held-out drone test split, same thresholds) | Max drop vs float |
|---|---|
| mAP50-95 | <= 1.0 point |
| mAP50 | <= 1.0 point |
| Recall at the operating confidence threshold | <= 2 points (tighter if "miss is worse") |
| Precision at the operating threshold | <= 2 points (tighter if "false alarm is worse") |

## Knobs (in the order to try)
1. **Input/output format**: compare default (BF16) and `FP32` — FP32 costs more PCIe bandwidth but
   avoids host conversion work and BF16 rounding of inputs. Pick by accuracy and TX8 fps.
2. **`--exp_auto_dp`**: compiler finds weight-sensitive layers and makes them 16-bit. Cheap to
   try; costs weight memory (check capacity) and maybe fps. Cannot be combined with `-bt`.
3. **`-hpoc` / `-hpoc_file`**: raise precision of specific **output channels** — typically box
   coordinate and class-score channels of the final head. Example (from the compiler docs format):
   `-hpoc "0 1 2 3"` for the first four output channels; multi-output JSON:
   ```json
   { "0": { "output_box": [0, 1, 2, 3], "output_cls": [0, 1, 2] } }
   ```
   (output names from Netron / the compile log; model index "0" for a single model).
   MemryX has a YOLOv7 HPOC tutorial: https://developer.memryx.com/tutorials/advanced/hpoc_yolov7.html
4. **`-bt wbits.json`**: manual per-layer precision, e.g. keep the head at 16-bit:
   ```json
   { "__DEFAULT__": 8, "/model.23/cv3.0/cv3.0.2/Conv": 16 }
   ```
   Layer names must match the model; multi-model files use `"0": {...}` keys. INT4 (`4`) for big
   backbone layers only to fit capacity, never without an accuracy check.
5. If the drop is still too large: different model (e.g. MXA-Optimized variant), larger model,
   or quantization-friendly retraining (e.g. ReLU variants such as YOLOv9 `relu` models).

Change one knob at a time; keep each DFP and its accuracy row in the manifest history.

## Validation paths
### A. x86 without MX3 hardware: simulator (sanity check, small subset)
- Simulator is bit-accurate / approximately timed, slow, and **x86 only** (not on ARM).
- Compile a separate DFP with `--sim_dfp` (embeds the simulator configuration; larger file):
  `mx_nc -m best.onnx -is "640,640,3" -c 4 --sim_dfp --dfp_fname best_c4_sim.dfp`
- CLI smoke test: `mx_sim -v -d best_c4_sim.dfp -f 4` (random input; >= 4 frames for an fps estimate).
- Python API (SDK venv): `Simulator(dfp=..., verbose=0)`, `infer(inputs, model_idx=0)`
  (https://developer.memryx.com/api/simulator.html). Use 50-200 images to compare raw outputs:
```python
# SKETCH: compare float ONNX vs simulated MX3 raw outputs on the cropped graph outputs.
import numpy as np, onnxruntime as ort
from memryx import Simulator          # import as in the MemryX simulator tutorial

sess = ort.InferenceSession("best_cropped.onnx", providers=["CPUExecutionProvider"])
sim = Simulator(dfp="best_c4_sim.dfp", verbose=0)

def prep(img_rgb_640):                 # HWC uint8 RGB, letterboxed 640x640
    return (img_rgb_640.astype(np.float32) / 255.0)

for img in images:                      # your loader
    x = prep(img)
    ref = sess.run(None, {sess.get_inputs()[0].name: x.transpose(2, 0, 1)[None]})
    out = sim.infer(inputs=x[None])     # NHWC; check expected input layout/shape in the docs
    for r, o in zip(ref, out):
        o = np.asarray(o).reshape(r.shape) if o.size == r.size else o
        cos = float(np.dot(r.ravel(), np.ravel(o)) / (np.linalg.norm(r) * np.linalg.norm(o) + 1e-12))
        print(r.shape, "max|d|", float(np.max(np.abs(r - o))), "cos", cos)
```
  Expect cosine similarity > 0.999 on score/box tensors; investigate anything lower. Output
  layouts (NHWC vs NCHW, `use_model_shape`) differ between ONNX Runtime and MemryX — reshape
  carefully and verify on one image by hand before trusting statistics.
- The simulator is too slow for a full mAP run; use path B for the number that goes in the manifest.

### B. MX3 hardware: full held-out evaluation (the number that counts)
- Option B1: x86 machine with an MX3 M.2 (MemryX accuracy tutorial runs on hardware with the
  Python API and ONNX Runtime for the cropped post model).
- Option B2: on TX8 itself with a Python test harness (allowed for tests; production is C++):
  `AsyncAccl` from the `memryx` runtime package, our own NumPy threshold/top-K. Python
  `set_postprocessing_model` is **not available on ARM** — so the DFP must already end at the
  decode/sigmoid outputs, or the harness must re-implement the post step.
- Same images, same letterbox, same thresholds, same top-K as the float evaluation.
- Compute mAP with the same tool for both (Ultralytics `val`, or pycocotools on exported JSON).

## Procedure
1. Float baseline: evaluate the exported **ONNX** (not only the `.pt`) with ONNX Runtime on x86 on
   the held-out split -> `baseline` row. This catches export/pruning bugs separately from quantization.
2. Compile default DFP -> simulator raw-output check (A) -> hardware mAP (B) -> `mx3` row.
3. Delta within budget -> done. Else apply knobs in order, one per iteration, re-measure.
4. Record in the manifest `accuracy` block: dataset id + hash, image count, metric values for
   baseline and compiled, thresholds, tool + version, date.
5. Keep the evaluation script and its config in the repo next to the manifest.

## Pitfalls
- Comparing against the `.pt` with different preprocessing (letterbox vs resize, RGB vs BGR).
- COCO mAP used as the acceptance metric for an aerial use case.
- Thresholds tuned on the test split (leakage).
- Evaluating a `_post.onnx` path on x86 but shipping a different C++ post on TX8 — validate the
  C++ post separately against the ONNX post on recorded outputs (skill `um-pi-vision-pipeline`).
