---
name: mx3-model-compile
description: "Exports a trained model to ONNX (Ultralytics YOLOv10/YOLO26 NMS-free, fixed 640, batch 1), reduces classes, compiles DFPs per MX3 chip count with the MemryX Neural Compiler (mx_nc) on an x86 Linux/WSL2 machine, validates quantization accuracy against the float baseline, and produces versioned artifacts with a sha256 manifest for deployment to the TX8 board. Use when converting PyTorch/ONNX models to DFP, choosing mx_nc flags, autocrop or crop points, weight precision, checking accuracy loss, or packaging models for the board. 關鍵字: 模型編譯, mx_nc, DFP, ONNX 匯出, 類別裁減, 量化, 精度驗證, 晶片數, 模型部署"
license: Proprietary - internal use only
compatibility: "Claude Code, OpenAI Codex, Google Antigravity. Target: TX8 (4x Cortex-A53, Ubuntu 22.04) + MemryX Cascade 100M (4x MX3)."
metadata:
  version: "1.0.0"
  domain: "edge-ai-model-compilation"
  triggers: "mx_nc, neural compiler, compile DFP, ONNX export, autocrop, class reduction, quantization, accuracy drop, model manifest, 模型編譯, 編譯 DFP, ONNX 匯出, 類別裁減, 量化精度"
  role: "ML compilation engineer"
  scope: "x86 compile environment, ONNX export, class reduction, mx_nc flags, accuracy validation, artifacts"
  related-skills: "mx3-model-selection, mx3-runtime-integration, tx8-vision-pipeline"
---

# MX3 Model Compile

You are the compilation engineer who turns the model chosen in `mx3-model-selection` into DFP
files the TX8 runtime can load. Compilation runs **on the x86 dev machine (WSL2 Ubuntu 22.04 or
native Linux), never on the board**. You keep box decode inside the compiled graph, reduce the
class count, prove the accuracy loss is within budget, and ship artifacts with a manifest.

## When to use
- Exporting PyTorch (Ultralytics, MMDetection ...) models to ONNX for MX3.
- Running `mx_nc`: chip count, input shape, crop points, weight precision, effort.
- Reducing classes (retrain or head pruning) and validating accuracy after quantization.
- Naming, versioning, hashing and copying DFPs to the board.

## When NOT to use
- Choosing which model / resolution / clock -> skill `mx3-model-selection`.
- Loading the DFP in C++, setting the clock, faults, power -> skill `mx3-runtime-integration`.
- Host-side threshold / top-K / NMS kernels -> skill `tx8-vision-pipeline`.

## Core workflow
1. **Check the compile environment** (x86): `scripts/check_compile_env.sh` — `mx_nc --version`,
   Python 3.9-3.12 venv, AVX2, RAM >= 8 GB, disk. Advise; never install silently.
2. **Export ONNX** ([references/export-and-class-reduction.md](references/export-and-class-reduction.md)):
   fixed `imgsz=640` (or the size chosen), `batch=1`, `simplify=True`, static shapes; YOLOv10/YOLO26
   with the NMS-free one-to-one head. Record the float baseline mAP **before** compiling.
3. **Reduce classes** to 1-3: retrain/fine-tune (preferred) or prune head channels (fallback, must
   be re-validated).
4. **First compile with `--autocrop -vv`** to learn where MemryX would cut; inspect any
   `_pre.onnx`/`_post.onnx`. Target: box decode + sigmoid stay on MX3; crop only what MX3 cannot run
   (e.g. TopK/Gather of the end-to-end head) using `--outputs`.
   ([references/compiler-flags.md](references/compiler-flags.md))
5. **Compile per chip count** with `scripts/compile_all_chipcounts.sh` (default c=1..4; MemryX documents
   only 2/4-chip DFPs on the 4-chip M.2, so c1/c3 are marked unverified) -> `<name>_c1.dfp` ...
   `<name>_c4.dfp` plus logs, SHA256SUMS and `manifest.json`.
6. **Measure accuracy** of the compiled model vs the float baseline on a held-out drone set
   ([references/quantization-and-accuracy.md](references/quantization-and-accuracy.md)); budget
   <= 1 mAP point (or agreed recall). Tune with `--exp_auto_dp`, `-bt`, `-hpoc` only if needed.
7. **Inspect** each DFP (`dfp_inspect model_c4.dfp`): chip count, ports, shapes.
8. **Package and deploy** ([references/artifacts-and-manifest.md](references/artifacts-and-manifest.md)):
   versioned folder, `manifest.json` with sha256, `scp` to `umpi:~/models/<name>/<version>/`,
   re-hash on the board. Hand off to `mx3-runtime-integration` for the stability test.

## MUST DO
- Compile on x86 (AVX2, >= 8 GB RAM); the board is for running only.
- Pass `-is` as NHWC **without batch** (e.g. `-is "640,640,3"`), matching the exported model.
- Keep one compiled artifact per (model, classes, input, chip count, SDK version); record all in the manifest.
- Check the generated `_post.onnx`: if one exists, it must run on TX8 in C++ (ONNX Runtime aarch64
  via `connect_post_model`, verify availability) or be re-implemented in C++ — Python
  pre/post models are not available on ARM.
- Measure float vs compiled accuracy on the same held-out set with the same thresholds.
- Use the venv's `mx_nc`; log the full command line and `mx_nc --version` with every artifact.

## MUST NOT
- Never compile on the TX8 board (A53, 2-4 GB RAM) or install the SDK there for compiling.
- Never use dynamic ONNX shapes or batch > 1.
- Never ship a pruned/fine-tuned model without an accuracy number vs baseline.
- Never combine `--exp_auto_dp` with `-bt` (the compiler forbids it).
- Never overwrite a released DFP in place; bump the version.
- Never assume `-c 1` / `-c 3` DFPs run on the Cascade 100M until a board test passes.

## Reference guide
| Topic | Reference | Load when |
|---|---|---|
| Ultralytics/MMDet export, NMS-free head, class reduction, head pruning | [references/export-and-class-reduction.md](references/export-and-class-reduction.md) | Steps 2-3 |
| Verified `mx_nc` flags, autocrop vs crop points, chip counts | [references/compiler-flags.md](references/compiler-flags.md) | Steps 4-5 |
| Quantization knobs, simulator, accuracy validation procedure | [references/quantization-and-accuracy.md](references/quantization-and-accuracy.md) | Step 6 |
| Folder layout, naming, manifest schema, deployment copy | [references/artifacts-and-manifest.md](references/artifacts-and-manifest.md) | Steps 7-8 |

## Scripts
- `scripts/check_compile_env.sh` — read-only env report (WSL/Linux):
  `bash scripts/check_compile_env.sh [--venv ~/mx]`
- `scripts/compile_all_chipcounts.sh` — compile one ONNX for several chip counts, log, hash, manifest:
  `bash scripts/compile_all_chipcounts.sh -m yolo26n_3cls.onnx -s 640,640,3 -n yolo26n_3cls -v 1.0.0 --classes person,car,truck --chips "4 2" -- --autocrop`
  Everything after `--` is passed to `mx_nc` unchanged. `--help` prints all options.

## Output checklist
- `mx_nc --version`, Python version, host (WSL/Linux), command lines used.
- Export settings (opset, imgsz, head type), class list, normalization.
- Crop decision: which outputs MX3 produces, whether a `_post.onnx` exists and how TX8 runs it.
- Per chip count: DFP name, size, sha256, compile time, dfp_inspect summary, success/failure.
- Accuracy table: float vs compiled (mAP50-95, mAP50, recall at operating threshold) and the delta.
- Manifest path and the board path where artifacts were copied (hash verified on board).
