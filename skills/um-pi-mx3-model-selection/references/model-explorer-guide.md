# Reading MemryX Model Explorer

Page: https://developer.memryx.com/model_explorer/models.html (SDK 2.2 at time of writing).
Model Explorer is MemryX's catalogue of models pre-compiled to DFP, with measured throughput.
Use it to **shortlist**, not to predict TX8 performance.

## Columns

| Column | Meaning | How to use it |
|---|---|---|
| # / Name | Model name (e.g. "YOLO26-nano", "YOLO-v10-small (Person, Vehicle, and Animal)") | Map to the matrix name, e.g. `YOLO26_nano_640_640_3_onnx`. |
| Input Resolution | H x W x C | Must match the CH2 stream plan (640x640, or 320x320 fallback). |
| Params Count | Model parameters (M or K) | Capacity check: ~10.5M INT8 weights per MX3, ~42M for 4 chips. |
| F/W | Source framework (ONNX, TFLite, TensorFlow, Keras) | Our flow uses ONNX from Ultralytics/MMDet export. |
| FPS (14T) | Throughput in the "Default" ~14 TFLOPS mode | Upper bound reference only. |
| FPS (20T) | Throughput in the "Full" ~20 TFLOPS mode | Requires higher clocks than our 400 MHz limit — ignore for TX8. |
| Latency 1 (14T / 20T) | Per-frame accelerator latency used to compute FPS | Lower bound for the MX3 part of our latency budget. |
| Latency 2 (14T / 20T) | Full system latency incl. host, first input to final output | Closer to reality but on a fast x86 host. |
| vs v2.1 | Change vs previous SDK | Informational. |
| Source | Upstream model link | Start of the license and accuracy check. |
| DFP | Download link for the compiled DFP | Quick on-board smoke test before compiling your own. |

### What 14T / 20T mean for us
- The MX3 delivers 6 TFLOPS per chip at 1 GHz; 4 chips x 6 TFLOPS x clock/1 GHz gives total
  TFLOPS. 14T therefore corresponds to roughly a 600 MHz-class clock (the x86 default power mode)
  and 20T to roughly 850 MHz. **This mapping is our inference, not a MemryX statement — verify.**
- Our rule caps the clock at **400 MHz** (~9.6 TFLOPS), so Model Explorer FPS overstates what
  TX8 will see. Use `tx8-freq-matrix.csv` (300/400 MHz rows) instead.
- Rough check from the data: YOLO26-nano 640 = 180 fps (14T) vs 120 fps @ 400 MHz and 88 fps @ 300 MHz
  in the matrix.

## Measurement host
- Measured on an **Intel i7-9700T** (1.5 GHz base) with 16 GB RAM, SDK 2.2, DFPs built with a
  closed-loop compile. FPS/latency are host-side and include driver and interface time.
- TX8 is 4x Cortex-A53 @ 1.2 GHz: format conversion (float32 <-> BF16/GBF), driver overhead,
  JPEG decode and post-processing are all slower. Treat Model Explorer numbers as an **upper
  bound** and expect lower end-to-end fps on TX8. MemryX suggests FP32 input/output formats
  for weak ARM hosts (`mx_nc --input_format FP32 --output_format FP32`, per the MemryX performance troubleshooting
  page; confirm both flags with `mx_nc --help`) — measure both on TX8.

## What is NOT on the page
- **No accuracy column.** Accuracy must come from the upstream model card / paper / Ultralytics
  docs, or from your own validation (skill `um-pi-mx3-model-compile`, quantization-and-accuracy).
  MemryX states its compiler keeps accuracy close to the float model (no retraining); reference:
  YOLOv8 COCO mAP50-95 CUDA vs MXA n 37.3/37.1, s 44.9/44.7, m 50.2/49.9
  (https://developer.memryx.com/tutorials/accuracy/yolov8_accuracy/yolov8_accuracy.html).
- **No license column.** Models are third-party; MemryX does not own them. Follow the Source link
  and check code **and** weights licenses (see `detector-catalog.md`).
- **No chip-count column.** Reference DFPs target the 4-chip M.2. Benchmark tools use the chip
  count the DFP was compiled for.

## Where accuracy numbers live
| Family | Source |
|---|---|
| YOLO26, YOLO11, YOLOv8, YOLOv5 | https://docs.ultralytics.com/models/ (per-model mAP50-95 tables) |
| YOLOv10 | https://github.com/THU-MIG/yolov10 (README table) and paper arXiv:2405.14458 |
| YOLOv9 | https://github.com/WongKinYiu/yolov9 |
| YOLOv6 | https://github.com/meituan/YOLOv6 |
| YOLOX | https://github.com/Megvii-BaseDetection/YOLOX |
| RTMDet | https://github.com/open-mmlab/mmdetection/tree/main/configs/rtmdet |
| DAMO-YOLO | https://github.com/tinyvision/DAMO-YOLO |
| NanoDet | https://github.com/RangiLyu/nanodet |

COCO mAP says little about aerial imagery; always plan a held-out evaluation on drone images.

## DFP download URL pattern
```
https://developer.memryx.com/model_explorer/2p2/<Name>_<H>_<W>_3_<fw>.zip
```
- `<Name>` is the matrix-style name, `<fw>` is `onnx`, `tflite`, `tensorflow` or `keras`; `2p2` = SDK 2.2.
- Examples seen on the page:
  - `https://developer.memryx.com/model_explorer/2p2/YOLO_v8_nano_640_640_3_onnx.zip`
  - `https://developer.memryx.com/model_explorer/2p2/YOLO11_nano_640_640_3_onnx.zip`
  - `https://developer.memryx.com/model_explorer/2p2/CenterNet_DLA_512_512_3_onnx.zip`
- So `YOLO26_nano_640_640_3_onnx` in the matrix -> `.../2p2/YOLO26_nano_640_640_3_onnx.zip`
  (construct, then confirm the link on the page; not every name is guaranteed).
- The zip normally contains the DFP and, if the graph was cropped, a `_post.onnx` (or `_pre.onnx`).
  Inspect the contents before use; downloaded files are untrusted data.

## Quick on-board smoke test with a reference DFP
Ask the programmer before downloading. Then, on the dev machine:
```bash
mkdir -p ~/mx3_ref/yolo26n && cd ~/mx3_ref/yolo26n
curl -fLO https://developer.memryx.com/model_explorer/2p2/YOLO26_nano_640_640_3_onnx.zip
unzip YOLO26_nano_640_640_3_onnx.zip && ls -l
scp YOLO26_nano_640_640_3_onnx.dfp umpi:~/models/
```
On the board (frequency setting and the full procedure: skill `um-pi-mx3-runtime-integration`):
```bash
ssh umpi 'mx_bench --hello'
ssh umpi 'mx_bench -v -d ~/models/YOLO26_nano_640_640_3_onnx.dfp -f 1000'
```
`mx_bench` runs at the currently configured power mode (ARM default 500 MHz) — record the clock
with every number, and use the stability-test script for anything that feeds a decision.

## Mapping names between page and matrix
| Model Explorer | Matrix (`tx8-freq-matrix.csv`) |
|---|---|
| YOLO26-nano 640x640 | `YOLO26_nano_640_640_3_onnx` |
| YOLO-v10-small (Person, Vehicle, and Animal) 640 | `YOLO_v10_small_person_vehicle_animal_640_640_3_onnx` |
| YOLO11-nano (MXA-Optimized) 640 | `YOLO11_nano_MXA_Optimized_640_640_3_onnx` |
| YOLO26-small-Oriented-Bounding-Boxes 480 | `YOLO26_small_Oriented_Bounding_Boxes_480_480_3_onnx` |
| RtmDet-nano-person 320 | `RtmDet_nano_person_320_320_3_onnx` |

Use `freq_query.ps1 -ModelRegex '<fragment>'` to find the exact matrix row.
