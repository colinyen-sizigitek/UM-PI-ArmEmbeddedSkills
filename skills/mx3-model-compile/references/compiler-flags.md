# MemryX Neural Compiler (`mx_nc`) — verified flags

Source: https://developer.memryx.com/tools/neural_compiler.html (SDK 2.2), the "Test with fewer
chips" tutorial, the YOLO26 tutorials and the performance troubleshooting page, checked
2026-10-08. Always confirm against the installed version: `mx_nc --help` and `mx_nc --version`.
Flags not listed here: do not use them without reading `mx_nc --help` first.

## Flag table

| Flag | Meaning | Default | Our usage |
|---|---|---|---|
| `-m, --model` | Model file(s); framework from extension (`.onnx`, `.tflite`, `.pb`, `.h5`/`.keras`) | required | One ONNX per DFP. |
| `-g, --chip_gen` | Target chip generation | `mx3` | Leave default. |
| `-c, --num_chips` | Number of chips to target; `0` = minimum number that fits | `4` | 4 (default) and 2; 1/3 see below. |
| `-rc` | Restrict compile to the resources of N chips while targeting `-c` chips | — | Performance **estimation only**; unused chips stay powered. Not for deployment. |
| `-is, --input_shapes` | Input shape, **NHWC without batch**, one string per model; `"auto"` allowed | inferred | `-is "640,640,3"` (even for NCHW ONNX). |
| `--autocrop` | Automatically crop pre/post-processing layers (experimental) | off | First pass, to learn the crop. |
| `--inputs` / `--outputs` | Input / output layer names; multi-model separated by `\|` | — | Explicit crop at decode/sigmoid tensors. |
| `--model_in_out` | JSON file defining in/out layers for sub-graph extraction | — | Alternative to `--inputs/--outputs`. |
| `-e, --effort` | `lazy`, `normal`, `hard` | `normal` | `hard` for release builds (slower compile). |
| `--target_fps` | Target FPS for the cores optimizer | `inf` | Leave default; we control fps with the clock. |
| `-bt, --weight_bits_table` | JSON of per-layer weight precision (4/8/16) | 8-bit weights | Only when accuracy needs it. |
| `--exp_auto_dp` | Auto-select 16-bit weights for sensitive layers | off | First accuracy knob. **Not with `-bt`.** |
| `-hpoc` | High-precision output channels (list of ints) | — | Score/box channels if they lose precision. |
| `-hpoc_file` | JSON per-output channel list for HPOC | — | Multi-output models. |
| `--input_format` | Host->chip packing: `FP32`, `BF16`, `GBFloat80`, `RGB888` | `BF16` | Try `FP32` on TX8 (weak ARM host); measure. |
| `--output_format` | Chip->host packing (named on the performance troubleshooting page, not in the flag table) | BF16/GBFloat80 | Try `FP32` on TX8; confirm with `mx_nc --help`. |
| `--extensions` | Space-separated `.nce` extension files; built-in `Yolov10` for YOLOv10/YOLO11 per the compiler page | — | See "YOLO extensions" below. |
| `--allow_unsigned_extensions` | Allow unsigned extensions | off | Never in release builds. |
| `--models_share_ifmap` | Several models share one input stream (same shape) | off | Not used (single model). |
| `--sim_dfp` | Embed simulator configuration in the DFP (bigger file) | off | Only for a separate simulator build. |
| `--dfp_fname` | Output DFP file name | `<model>.dfp` | `<name>_c<N>.dfp`. |
| `-so`, `-so_aux` | Show optimizer progress (incl. aux cores) | off | Interactive use only. |
| `-v`, `-vv` | Verbosity; `-vv` prints autocrop decisions | — | `-vv` in scripted builds (logged). |
| `--version` | Print version | — | Logged in the manifest. |

## Chip count (important)
- Default target is 4 chips (`-c 4`); `-c 0` lets the compiler pick the minimum.
- MemryX's "Test with fewer chips" tutorial states that on the 4-chip M.2, compiling for any chip
  count **other than 2 or 4** leads to a runtime error such as "Input DFP was compiled for a 1-chip
  solution but you have a 4-chip solution attached". `mx_set_powermode` also only distinguishes
  4-chip and 2-chip operating modes.
- Therefore: build **c4 and c2** by default. Build c1/c3 only on request and mark them
  `"verified_on_board": false` until a board run succeeds. DESIGN asks for 1-4 selectable chip
  counts — this conflict is an open item (ask MemryX: https://community.memryx.com/).
- Data-parallel "1-chip DFP x N" (DESIGN option) depends on 1-chip DFPs running on this module;
  see skill `mx3-runtime-integration` (multi-chip) — currently unverified.
- Benchmarks and the simulator use the chip count the DFP was compiled for.

## Autocrop vs explicit crop
```bash
# Pass 1: let MemryX show its crop (log it)
mx_nc -vv -m best.onnx -is "640,640,3" -c 4 --autocrop --dfp_fname probe_c4.dfp 2>&1 | tee probe.log
ls *_pre.onnx *_post.onnx 2>/dev/null
```
- Output naming in the MemryX YOLO26 tutorial: `<model>.dfp` and `<model>_post.onnx`
  (e.g. `YOLO26_nano_640_640_3_onnx_post.onnx`). A `_pre.onnx` appears if input-side layers were cropped.
- Open `_post.onnx` in Netron. If it contains only TopK/Gather/Concat of the end-to-end head:
  replace it with our C++ threshold + top-K and compile with explicit outputs instead:
```bash
# Pass 2: explicit crop after decode + sigmoid (tensor names from Netron; examples only)
mx_nc -vv -m best.onnx -is "640,640,3" -c 4 \
      --outputs "/model.23/Mul_2_output_0,/model.23/Sigmoid_output_0" \
      --dfp_fname yolo26n_3cls_c4.dfp
```
- If the `_post.onnx` contains decode math (Mul/Add with grid constants, Sigmoid), MX3 could not
  run it or autocrop chose conservatively: try the explicit crop; if `mx_nc` rejects it, keep the
  post model and implement it in C++ on TX8 (NEON) — or run it with ONNX Runtime via
  `connect_post_model` after verifying ONNX Runtime is available for aarch64 on the board.
- Record the final output tensor names, shapes and order in the manifest; the C++ side depends on them.

## YOLO extensions
- DESIGN notes that YOLOv10/11/26 compiler extensions are auto-enabled in SDK 2.2; the compiler
  page describes a built-in `Yolov10` extension "for Yolo10 and Yolo11" passed with `--extensions`.
  These two statements disagree — check `mx_nc --help` and the 2.2 release notes. If the compile
  log (-vv) does not mention the extension and the head fails to map, try `--extensions Yolov10`.

## Typical commands
```bash
. ~/mx/bin/activate
mx_nc --version
# 4 chips, release effort, FP32 host formats for the A53 host (measure vs default)
mx_nc -vv -m best.onnx -is "640,640,3" -c 4 -e hard --input_format FP32 \
      --dfp_fname yolo26n_3cls_c4.dfp
# 2 chips
mx_nc -vv -m best.onnx -is "640,640,3" -c 2 -e hard --dfp_fname yolo26n_3cls_c2.dfp
# accuracy knob
mx_nc -vv -m best.onnx -is "640,640,3" -c 4 --exp_auto_dp --dfp_fname yolo26n_3cls_c4_dp.dfp
# inspect
dfp_inspect yolo26n_3cls_c4.dfp
```
Use `scripts/compile_all_chipcounts.sh` to do the loop, logging and hashing consistently.

## Capacity and failures
- Weights: 10.5 MB per MX3 (~10.5M INT8 / ~21M INT4 params); feature maps 5 MB per chip; no DRAM.
- A model under the parameter limit can still fail on node count or feature-map memory (FAQ).
  Options: fewer chips -> more chips (`-c 4`), lower input resolution, INT4 for large layers via
  `-bt` (accuracy check required), or a smaller model.
- Compile time grows with `-e hard` and chip count; keep logs (`tee`) for every attempt.

## DFP inspection
- CLI: `dfp_inspect <file.dfp>` prints compiler version, compile date, target chip count, chip
  generation, simulator/hardware config sizes, model file names and active ports.
- Python (SDK venv): `from memryx import Dfp; d = Dfp("x.dfp"); d.num_chips, d.input_shapes,
  d.output_shapes, d.version, d.models` (properties per https://developer.memryx.com/api/dfp.html;
  the import path is not shown on that page — confirm with `python -c "import memryx; print(dir(memryx))"`).
