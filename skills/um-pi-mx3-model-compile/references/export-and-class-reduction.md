# Export to ONNX and class reduction

All steps run on the x86 dev machine (WSL2 Ubuntu 22.04 or Linux) in a Python venv that has
the training framework (e.g. `ultralytics`) — this can be a different venv from the MemryX SDK
venv to avoid dependency clashes. Pin the framework version and record it in the manifest.

## 1. Rules for an MX3-friendly ONNX
- **Static shapes**: fixed `imgsz` (640x640 default; 320x320 fallback), `batch=1`, `dynamic=False`.
- **Simplified graph**: `simplify=True` (Ultralytics uses onnxslim) — removes shape arithmetic
  that the compiler would otherwise have to crop.
- **Opset**: start with the framework default. If `mx_nc` reports an unsupported operator, check
  the MemryX supported-operators list in the docs and re-export with another opset; do not guess.
- **Head**: NMS-free one-to-one head for YOLOv10 / YOLO26. Never embed NMS (`nms=True`) — NMS
  is not something we want on MX3 or in a `_post.onnx`.
- **Preprocessing outside the graph**: Ultralytics models expect RGB, values scaled to [0,1]
  (divide by 255), no mean/std, letterboxed with pad value 114. TX8 feeds float32 NHWC.
  Record this in the manifest (`normalization`).

## 2. Ultralytics export (YOLO26 / YOLOv10 / YOLO11 / YOLOv8)
Verified export arguments (https://docs.ultralytics.com/modes/export/): `format`, `imgsz`,
`batch` (default 1), `simplify` (default True), `opset`, `dynamic` (default False), `nms`.
- `nms=None` (default): raw one-to-many predictions, shape `(1, 4+nc, 8400)` at 640; needs NMS.
- `nms=False`: selects the NMS-free one-to-one head **where the model has one** (YOLO26, YOLOv10);
  output `(1, max_det, 6)` = `[x1, y1, x2, y2, score, class]`, `max_det=300` by default.
- There is no separate `end2end` argument in the current docs; end-to-end is controlled by `nms`.

```bash
# training venv (example names)
. ~/venvs/ultra/bin/activate
python - <<'EOF'
from ultralytics import YOLO
m = YOLO("runs/detect/drone3/weights/best.pt")          # fine-tuned 3-class YOLO26n
m.export(format="onnx", imgsz=640, batch=1, simplify=True, dynamic=False, nms=False)
EOF
ls -l runs/detect/drone3/weights/best.onnx
```
CLI equivalent: `yolo export model=best.pt format=onnx imgsz=640 batch=1 simplify=True nms=False`.

Check the result before compiling:
```bash
python - <<'EOF'
import onnx
m = onnx.load("best.onnx")
for t in list(m.graph.input) + list(m.graph.output):
    print(t.name, [d.dim_value or d.dim_param for d in t.type.tensor_type.shape.dim])
EOF
```
Expect input `images [1, 3, 640, 640]` and, with `nms=False`, output `[1, 300, 6]`. Open it in
Netron (https://netron.app) and locate: the per-scale box/class convs, the decode
(grid add, stride multiply), the class **sigmoid**, and the TopK/Gather selection at the end.

### Where to cut (design decision)
- MX3 should produce decoded boxes + sigmoid scores (all anchors), i.e. cut **after** the sigmoid
  and box decode but **before** TopK/Gather. The TX8 host then does threshold + top-K (NEON,
  branchless) over `8400 x (4 + nc)` values — tiny for nc <= 3.
- Let `mx_nc --autocrop -vv` show where MemryX would cut; if it cuts earlier (moving decode to a
  `_post.onnx`), set explicit `--outputs` at the decode/sigmoid tensors instead (see
  `compiler-flags.md`) and confirm the compiled outputs.
- If MemryX's own YOLO26 tutorial flow is used instead (`--autocrop` with a `_post.onnx` output of
  300x6), the post model must run on TX8 in C++ via `connect_post_model` (needs ONNX Runtime on
  aarch64 — verify on the board) or be re-implemented. Python post models are not available on ARM.

## 3. Other frameworks
- **MMDetection (RTMDet)**: export with MMDeploy to ONNX, static 640x640, **without** the NMS
  plugin (deploy config "onnxruntime static" style without `post_processing`), then crop at the
  score/box tensors. Verify the exported output names in Netron.
- **YOLOX**: `tools/export_onnx.py` in the YOLOX repo; use the `--decode_in_inference` option if
  you want the decode inside the graph (check the flag name in your YOLOX version).
- **TFLite/Keras**: accepted directly by `mx_nc`; same crop rules.

## 4. Class reduction (target 1-3 classes)
Why: smaller class head = fewer output channels to transfer and threshold on the A53, fewer false
classes, and (for the one-to-one head) TopK is no longer filled with irrelevant classes.

### 4.1 Preferred: retrain / fine-tune on the reduced set
```yaml
# drone3.yaml
path: /data/drone3
train: images/train
val: images/val
test: images/test        # held-out set used ONLY for the final accuracy report
names: {0: person, 1: car, 2: truck}
```
```bash
yolo detect train model=yolo26n.pt data=drone3.yaml imgsz=640 epochs=150 batch=32 \
     name=drone3 seed=0 deterministic=True
yolo detect val model=runs/detect/drone3/weights/best.pt data=drone3.yaml split=test \
     imgsz=640 batch=1 rect=False      # float baseline -> record in manifest
```
- Start from COCO-pretrained weights; include altitude/lighting variety; keep a test split that is
  never used for model selection.
- For YOLOv10 / YOLO26 validate with the same head you will export (`nms=False` / end-to-end).

### 4.2 Fallback: prune class channels from the head
Use only when there is no dataset to fine-tune. Idea: in decoupled YOLO heads (v8/11/26, v10)
each scale has a class branch ending in a 1x1 conv with `nc` output channels; scores are
**independent sigmoids**, so deleting the channels of unwanted classes does not change the
scores of the kept classes. For one-to-one heads (YOLOv10/YOLO26) prune both class branches.
Anchor-based heads (YOLOv5/v7) interleave `(5 + nc)` channels per anchor — slice per anchor.

Do it in PyTorch before export (ONNX surgery also requires fixing every downstream
Reshape/Split/Concat constant that encodes `4 + nc`, which is fragile).

```python
# SKETCH - verify attribute names against your ultralytics version (Detect head: cv2 = box
# branch, cv3 = class branch, optional one2one_cv3 for end-to-end heads, reg_max).
import torch.nn as nn
from ultralytics import YOLO

KEEP = [0, 2, 7]                      # COCO ids: person, car, truck (order = new ids 0,1,2)
model = YOLO("yolo26n.pt")
head = model.model.model[-1]

def prune(branches):
    for seq in branches:
        old = seq[-1]                 # final nn.Conv2d with nc output channels
        assert isinstance(old, nn.Conv2d) and old.out_channels == head.nc
        new = nn.Conv2d(old.in_channels, len(KEEP), 1, bias=True)
        new.weight.data = old.weight.data[KEEP].clone()
        new.bias.data = old.bias.data[KEEP].clone()
        seq[-1] = new

prune(head.cv3)
if hasattr(head, "one2one_cv3"):
    prune(head.one2one_cv3)
head.nc = len(KEEP)
head.no = head.nc + head.reg_max * 4
model.model.nc = len(KEEP)
model.model.names = {i: model.model.names[k] for i, k in enumerate(KEEP)}
model.export(format="onnx", imgsz=640, batch=1, simplify=True, nms=False)
```
Mandatory validation after pruning:
1. Run the float pruned ONNX (onnxruntime on x86) and the original model on the same images;
   scores of kept classes must match to ~1e-5 and boxes must be identical before thresholding.
2. Evaluate mAP on the held-out set restricted to the kept classes; compare with the original
   model evaluated on the same classes. Any difference beyond noise means the pruning is wrong.
3. Only then compile and run the quantized accuracy check (`quantization-and-accuracy.md`).

Pruning keeps the COCO-trained features: accuracy on aerial views is still unknown until measured.

## 5. Checklist before `mx_nc`
- [ ] ONNX input `[1,3,H,W]` static; output names noted.
- [ ] Float baseline mAP on the held-out test split recorded (same thresholds you will use).
- [ ] Class list and order recorded; normalization recorded.
- [ ] Crop point chosen (decode + sigmoid on MX3) and tensor names noted.
- [ ] Framework, version, export arguments recorded for the manifest.
