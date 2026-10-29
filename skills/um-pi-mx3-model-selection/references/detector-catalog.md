# Detector catalog for MX3 (TX8 drone platform)

All fps / mW numbers below are **MemryX reference data** from `tx8-freq-matrix.csv`
(4 MX3 chips, config 4x1), **not measured on TX8**. Params are from Model Explorer (SDK 2.2).
Licenses are the upstream code licenses as known at writing — **always verify upstream** (code
and pretrained weights can differ). Rule column: lowest PASS clock <= 400 MHz with
fps >= 30 x 1.5 = 45 (see `frequency-rule.md`). Numbers were extracted with
`scripts/freq_query.ps1` / `scripts/gen_detection_summary.ps1`; re-run them after a CSV update.

## Families

| Family | NMS-free | License (verify) | Typical use / notes |
|---|---|---|---|
| YOLO26 (Ultralytics) | **Yes** (one-to-one head; export `nms=False` -> `1x300x6`) | AGPL-3.0 / Enterprise | First choice when license is acceptable. DFL removed, simple head. OBB/seg/pose variants. |
| YOLOv10 (THU-MIG) | **Yes** (one-to-one head) | AGPL-3.0 | First choice; PVA (person/vehicle/animal) class-reduced variants in the matrix. |
| YOLO11 (Ultralytics) | No (NMS on host) | AGPL-3.0 / Enterprise | Good accuracy; "MXA-Optimized" variants are faster on MX3. Host NMS costs CPU. |
| YOLOv9 | No | GPL-3.0 | PVA and `relu` variants; relu variants are faster at 320. |
| YOLOv8 (Ultralytics) | No | AGPL-3.0 / Enterprise | Mature, MemryX accuracy reference model. OBB at 1024 only. |
| YOLOv7 | No | GPL-3.0 (verify) | MXA-Optimized variants; anchor-based. |
| YOLOv6 (Meituan) | No | GPL-3.0 | PVA variants; high fps, higher module power. |
| YOLOv5 (Ultralytics) | No | AGPL-3.0 | Legacy; anchor-based. |
| YOLOX (Megvii) | No | **Apache-2.0** | Permissive option at 640 (small) / 416 (nano/tiny). |
| RTMDet (OpenMMLab) | No | **Apache-2.0** | `RtmDet_nano_person_320` is a 1-class person model; tiny at 640. |
| DAMO-YOLO (Alibaba) | No | **Apache-2.0** | tiny/small at 640 pass at 300 MHz but draw 5-7.6 W. |
| NanoDet | No | **Apache-2.0** | 416 input, very light. |
| YOLO-NAS (Deci) | No | Weights under a restrictive Deci license (verify) | small passes at 300 MHz. |
| SSD / SSDlite-MobileNet | No | Apache-2.0 (TF models; verify) | Low accuracy on small objects. |
| CenterNet | NMS-free-ish (peak extraction) | MIT/Apache (verify per repo) | DLA 512 passes at 300 MHz. |
| EfficientDet-Lite | No | Apache-2.0 | Only Lite1 384 in the matrix; clock-insensitive (memory bound?). |

Non-NMS-free models need NMS on TX8. With 1-3 classes and a top-K cap (e.g. K = 100) a
branch-light NMS is a few ms on one A53 core — measure it (skill `um-pi-vision-pipeline`).

## 640x640 (primary CH2 input)

| model (matrix name) | params | 300 MHz fps / mW | 400 MHz fps / mW | rule @ 30 fps | NMS-free | license |
|---|---|---|---|---|---|---|
| YOLO26_nano_640 | 2.3 M | 88.0 / 3829 | 120.2 / 4588 | **300 MHz** | yes | AGPL |
| YOLO_v10_nano_person_vehicle_animal_640 | 2.2 M | 113.6 / 4006 | 155.0 / 4984 | **300 MHz** | yes | AGPL |
| YOLO_v10_nano_640 | 2.2 M | 110.6 / 4053 | 150.4 / 5032 | **300 MHz** | yes | AGPL |
| YOLO11_nano_MXA_Optimized_640 | 3.9 M | 156.5 / 4981 | 214.5 / 6452 | **300 MHz** | no | AGPL |
| YOLO_v8_nano_640 (onnx) | 3.0 M | 151.8 / 4264 | 221.5 / 5831 | **300 MHz** | no | AGPL |
| YOLO_v10_small_person_vehicle_animal_640 | 6.9 M | 42.5 / 3596 | 58.1 / 4660 | **400 MHz** | yes | AGPL |
| YOLO_v10_small_640 | 6.9 M | 37.4 / 3507 | 51.0 / 4449 | **400 MHz** | yes | AGPL |
| YOLO26_small_640 | 9.1 M | 22.8 / 2899 | 31.4 / 3655 | not recommended | yes | AGPL |
| YOLO11_small_MXA_Optimized_640 | 14.1 M | 42.6 / 4108 | 58.4 / 5734 | 400 MHz | no | AGPL |
| YOLO11_small_640 | 9.0 M | 31.3 / 3243 | 42.8 / 4132 | not recommended | no | AGPL |
| YOLO_v9_tiny_person_vehicle_animal_640 | 1.8 M | 87.2 / 3793 | 119.1 / 4752 | 300 MHz | no | GPL |
| YOLO_v9_small_640 | 6.9 M | 52.6 / 4358 | 73.4 / 5862 | 300 MHz | no | GPL |
| YOLO_v6_nano_person_vehicle_animal_640 | 4.0 M | 162.6 / 4545 | 217.8 / 5923 | 300 MHz | no | GPL |
| YOLOX_small_640 | 8.5 M | 128.6 / 5919 | NG | 300 MHz (400 NG!) | no | Apache |
| YOLOX_small_ti_lite_640 | 8.5 M | 118.1 / 5545 | 161.3 / 7790 | 300 MHz | no | Apache |
| RtmDet_tiny_640 | 5.3 M | 61.7 / 3568 | 84.4 / 4580 | 300 MHz | no | Apache |
| DAMO_YOLO_tiny_640 | 8.1 M | 164.3 / 5643 | 215.3 / 7646 | 300 MHz | no | Apache |
| YOLO26_nano_Oriented_Bounding_Boxes_640 (OBB) | 2.3 M | 77.0 / 3643 | 106.0 / 4532 | 300 MHz | yes | AGPL |

The first eight rows are the product-owner examples from DESIGN section 2.4 (values to one decimal
from the CSV).

Observations:
- `nano` models pass at **300 MHz** with ~2-3.5x margin over 45 fps; `small` NMS-free models
  need **400 MHz** with only ~1.13-1.29x margin over 45 fps (1.7-1.9x over 30 fps).
- Fault step-down 400 -> 300 MHz: YOLOv10-small PVA falls to 42.5 fps and YOLOv10-small to
  37.4 fps — still above 30 fps in the table but without the 1.5x safety factor, so TX8 may miss
  30 fps after a step-down. Report this degraded mode to the base station.
- `YOLOX_small_640` is PASS at 300 MHz but **NG at 400 MHz** in the table: an example of why only
  PASS rows count and why the stability test is required.
- Power at 300 MHz for nano detectors: ~3.8-5.0 W module; at 400 MHz: ~4.6-6.5 W.

## 480x480 (intermediate)

| model | 300 MHz fps / mW | 400 MHz fps / mW | rule @ 30 fps |
|---|---|---|---|
| YOLO26_nano_480 | 201.4 / 3991 | 272.1 / 4971 | 300 MHz |
| YOLO26_small_480 | 89.7 / 3800 | 122.3 / 4980 | 300 MHz |
| YOLO26_medium_480 | 26.5 / 3371 | 36.7 / 4424 | not recommended |
| YOLO26_small_Oriented_Bounding_Boxes_480 | 79.4 / 3610 | 108.4 / 4734 | 300 MHz |
| YOLO_v10_nano_480 | 292.8 / 4613 | 380.1 / 5702 | 300 MHz |
| YOLO_v10_small_480 | 131.8 / 4564 | 178.6 / 5916 | 300 MHz |
| YOLO_v10_medium_480 | 29.8 / 3287 | 40.5 / 4263 | not recommended |
| YOLO11_nano_480 | 269.1 / 4391 | 371.6 / 5519 | 300 MHz |
| YOLO11_small_480 | 119.9 / 4277 | 162.7 / 5743 | 300 MHz |

480 is attractive when **small** accuracy is needed at 300 MHz (YOLO26 small 480 = 89.7 fps at
300 MHz). It needs a CH2 stream at 480x480 or a host resize from 640 (CPU cost; measure). Not in
DESIGN's default pipeline — raise it as an option, do not adopt silently.

## 320x320 (fallback: TurboJPEG 1/2 scaled decode)

| model | 300 MHz fps / mW | 400 MHz fps / mW | rule @ 30 fps |
|---|---|---|---|
| YOLO26_nano_320 | 628.0 / 4360 | 735.2 / 5072 | 300 MHz |
| YOLO26_small_320 | 223.4 / 3809 | 302.2 / 5117 | 300 MHz |
| YOLO26_medium_320 | 98.2 / 3898 | 134.4 / 5500 | 300 MHz |
| YOLO_v10_nano_person_vehicle_animal_320 | 645.5 / 4391 | 826.3 / 5265 | 300 MHz |
| YOLO_v10_small_person_vehicle_animal_320 | 308.7 / 4306 | 416.0 / 5704 | 300 MHz |
| YOLO_v10_medium_person_vehicle_animal_320 | 102.3 / 3814 | 139.4 / 5141 | 300 MHz |
| YOLO11_nano_320 | 624.3 / 4316 | 808.4 / 5245 | 300 MHz |
| RtmDet_nano_person_320 | 572.9 / 3481 | 682.6 / 3993 | 300 MHz |
| YOLO_v9_tiny_relu_person_vehicle_animal_320 | 487.7 / 4250 | 659.6 / 5278 | 300 MHz |

At 320 the MX3 is far from the bottleneck: the host (decode, conversion, post) dominates. The
fps above are irrelevant beyond ~45; choose by accuracy on small objects (object pixels halve).
Note module power at 300 MHz is **not** lower for tiny models (they run at very high fps): when
the pipeline is capped at 30 fps the real power will be lower — measure on TX8.

## Capacity check
- Weight memory: 10.5 MB per MX3 -> ~10.5M INT8 params (~21M INT4); 4 chips ~42M INT8.
- All models above are <= 14.1M params: fit on 2 or 4 chips at INT8. On **1 chip** only models
  <= ~10.5M INT8 params can fit (nano and most small variants), and feature-map memory (5 MB per
  chip) or node count can still make compilation fail — `mx_nc` is the authority.
- More params usually means lower fps at a given clock; capacity is rarely the binding constraint
  for drone detectors — throughput at <= 400 MHz is.

## Default recommendation pattern
1. Licence acceptable (AGPL ok or enterprise licence): **YOLOv10-nano PVA 640** if classes fit
   person/vehicle/animal, else **YOLO26-nano 640** fine-tuned on 1-3 classes, at **300 MHz**.
2. Needs more accuracy: YOLOv10-small (PVA) 640 at 400 MHz (thin margin) or YOLO26-small 480 at 300 MHz.
3. Permissive licence required: RTMDet-tiny 640 or YOLOX-small-ti-lite 640 at 300 MHz (host NMS).
4. Fallback when TX8 misses targets at 640: same family at 320.
