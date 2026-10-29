# Requirements interview (model selection)

Run this interview before recommending any model. Ask the questions in order, one block at a
time, and accept "use the default" as an answer — but write the default down explicitly so the
programmer sees what was assumed. The output is a **constraint list** used in every later step.

## The 7 questions

### Q1. Task type
> What must the model output: boxes (detect), rotated boxes (aerial OBB), masks (segment),
> keypoints (pose), a label per image (classify), depth, or tracks (detect + tracker)?

| Answer | Constraint | Notes |
|---|---|---|
| detect | `--task detect` | Default for the drone. Prefer YOLOv10 / YOLO26 (NMS-free). |
| rotated objects from above (vehicles, ships, roofs) | `--task obb` | YOLO26 OBB variants exist at 320/480/640. OBB still needs angle-aware post-processing on host; check the head. |
| segment | `--task segment` | Masks are heavy on host post-processing (mask protos x coefficients). Ask if boxes are enough. |
| pose | `--task pose` | Keypoint decode on host; YOLO26/YOLO11 pose variants. |
| classify | `--task classify` | Name heuristic only catches `_CLS_`; search by `--model-regex` too. |
| depth | `--task depth` | Few entries; verify per model. |
| track | `--task detect` + host tracker | Tracker (e.g. ByteTrack/SORT) runs on TX8 CPU; budget it with skill `um-pi-vision-pipeline`. |

### Q2. Classes and dataset
> Which classes, how many (1-3 is the target), and do you have labelled images from the drone
> camera at the real altitude? How many images per class?

- 1-3 classes: plan **retrain / fine-tune** on the reduced class set (skill `um-pi-mx3-model-compile`).
- Classes are person / vehicle / animal: the **PVA variants** (YOLO_v10 / v9 / v6 `person_vehicle_animal`)
  are already class-reduced reference points in the matrix; their fps tells you what a 3-class head costs.
- No dataset: COCO-pretrained model + head channel pruning is the fallback; accuracy on aerial
  views is then **unknown** and must be measured (COCO is mostly ground-level imagery).
- Rough guidance (verify on your data): a few hundred labelled instances per class for fine-tuning
  a pretrained detector; thousands for robust aerial performance across altitudes and lighting.

### Q3. Object size
> Flight altitude range? Camera horizontal FOV? Smallest object of interest (metres)? What is
> its size in pixels in the 640x640 frame?

Pixel size estimate (pinhole, nadir view):
```
ground_width_m  = 2 * altitude_m * tan(HFOV / 2)
object_px       = object_m / ground_width_m * 640
```
Example: altitude 60 m, HFOV 80 deg -> ground width ~ 100.7 m; a 0.5 m wide person -> ~3.2 px
(too small for any 640 detector); a 4.5 m car -> ~29 px (fine).

| Smallest object in 640x640 | Guidance |
|---|---|
| >= 32 px | 640 or even 320 input works; prefer the smaller/faster model. |
| 16-32 px | Keep **640**; prefer models with a stride-8 head (all YOLO P3 heads). Do not drop to 320. |
| 8-16 px | 640 is marginal; ask to lower altitude or narrow the FOV. Consider a model trained at 640 on aerial data (e.g. VisDrone-style); verify recall. |
| < 8 px | Not detectable reliably at 640. Options: change optics/altitude. **Tiling (SAHI-style) is not supported on the TX8 budget** (N tiles x inference + host merging at 30 fps on 4x A53 exceeds the budget) — only consider it after a measurement proves otherwise. |

- 320 input (TurboJPEG 1/2 scaled decode) is the documented fallback when 640 misses the targets;
  it halves the object pixel size — re-run this table at 320 before agreeing.
- 1080p CH1 is forwarded untouched; the model only sees the 640x640 CH2 stream.
- Aerial rotated objects: OBB variants (YOLO26 OBB 320/480/640, YOLOv8/YOLO11 OBB at 1024).
  1024-input OBB models are far below 45 fps in the matrix — not an option at 30 fps.

### Q4. Performance target
> Required sustained fps (default **30 fps for 10 min**) and latency (default **TX8-internal
> p99 <= 80 ms**, capture timestamp -> metadata sent)? Start latency (default **<= 3 s**)?

- The frequency rule uses `target_fps x 1.5`; at 30 fps the matrix fps must be >= 45.
- Latency budget split (starting point, verify): decode + resize 10-15 ms, MX3 in-to-out 15-35 ms,
  host post 2-5 ms, transport 1-5 ms. A model whose MX3 latency alone approaches 50 ms is a risk
  even if its throughput passes.

### Q5. Chip count and power
> How many MX3 chips may the application use (1-4)? Is there a power budget for the module (W)?

- The matrix is **4-chip data only** (config 4x1). For 1-3 chips there is no reference: the model
  must pass the on-board stability test first (skill `um-pi-mx3-runtime-integration`).
- MemryX documents that on the 4-chip M.2 only DFPs compiled for **2 or 4 chips** run directly
  (see skill `um-pi-mx3-model-compile`); treat 1 and 3 chips as unverified until tested on TX8.
- Module power in the matrix is at the given clock (typical 3-6 W at 300-400 MHz for detectors).
  Module TDP 5.15 / 7.7 / 9.27 W (low/typical/worst); max load ~13 W.

### Q6. Accuracy
> Minimum acceptable mAP (or recall at a fixed precision)? Which is worse for the mission:
> a **missed object** or a **false alarm**?

- Miss is worse (search and rescue, safety): bias toward the larger model / 640 input, lower
  confidence threshold, accept more false alarms; require recall measurement.
- False alarm is worse (autonomous action): higher threshold, consider 2-frame confirmation in
  the tracker; precision measurement.
- MemryX quantization loss reference (YOLOv8 COCO mAP50-95, CUDA vs MXA): n 37.3/37.1,
  s 44.9/44.7, m 50.2/49.9. Budget ~0.5-1 point; measure your own model.

### Q7. License
> Is this a commercial product shipped to customers, or internal/R&D only?

| License | Models (verify upstream) | Implication |
|---|---|---|
| AGPL-3.0 | Ultralytics YOLOv5/v8/11/26, YOLOv10 (THU) | Network use / distribution triggers source disclosure, or buy an Ultralytics Enterprise license. |
| GPL-3.0 | YOLOv9, YOLOv6 | Distribution triggers source disclosure. |
| Apache-2.0 | YOLOX, DAMO-YOLO, RTMDet (MMDetection), NanoDet | Permissive; keep NOTICE. |

Never exclude a model silently: show it with the flag and let the programmer (and their legal
contact) decide. Pretrained **weights** may carry a different license than the code; check both.

## Constraint list template

```
Task:            detect (NMS-free preferred)
Classes:         person, vehicle (2) — dataset: 3,000 aerial images, 60-120 m
Smallest object: person 0.5 m @ 60 m, HFOV 80 deg -> ~3 px @ 640  => NOT feasible; agree on <= 30 m
Target:          30 fps sustained 10 min, p99 <= 80 ms, start <= 3 s  => matrix fps >= 45
Chips / power:   4 chips, module <= 6 W
Accuracy:        recall >= 0.85 @ precision 0.7; miss worse than false alarm
License:         commercial -> AGPL/GPL need legal sign-off or enterprise license
Assumed defaults: (list every default the programmer did not answer)
```

## Red flags to raise immediately
- Objects < 8 px at the planned altitude.
- 80-class COCO model with no plan for class reduction.
- Commercial product + AGPL model with no license decision.
- Chip count 1 or 3 with no stability-test plan.
- Accuracy requirement given without any held-out dataset to measure it.
