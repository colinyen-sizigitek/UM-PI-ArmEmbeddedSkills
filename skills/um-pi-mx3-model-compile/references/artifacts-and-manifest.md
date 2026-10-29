# Artifacts, naming, manifest and deployment

Goal: anyone (or the runtime) can tell exactly which model, classes, preprocessing, chip count
and SDK produced a DFP, and verify the bytes on the board.

## Naming
```
<family>-<size>-<classes-tag>-<HxW>   e.g.  yolo26n-pvc3-640x640
DFP per chip count:  <name>_c<N>.dfp       e.g.  yolo26n-pvc3-640x640_c4.dfp
Version:             semver, bump on ANY change (weights, export args, mx_nc flags, SDK)
```
- `classes-tag`: short tag for the class set (`p1` = person only, `pvc3` = person/vehicle/cyclist).
- Never reuse a version number for different bytes; never overwrite a released folder.

## Folder layout (dev machine, under version control or artifact storage)
```
models/
  yolo26n-pvc3-640x640/
    1.0.0/
      manifest.json
      yolo26n-pvc3-640x640_c4.dfp
      yolo26n-pvc3-640x640_c2.dfp
      yolo26n-pvc3-640x640_c4_post.onnx      # only if a post model exists (see compiler-flags.md)
      SHA256SUMS                              # sha256sum format, all deployable files
      logs/compile_c4.log  logs/compile_c2.log  logs/env.txt
      source/best.onnx.sha256                 # hash of the exported ONNX (ONNX itself optional)
      eval/accuracy.json                      # baseline vs compiled metrics
```
Large binaries belong in artifact storage (Git LFS or a file server), not plain git.

## Manifest (`manifest.json`)
`scripts/compile_all_chipcounts.sh` writes the compile-related fields; fill `accuracy` and
`frequency` after validation. Example:
```json
{
  "schema_version": "1.0",
  "name": "yolo26n-pvc3-640x640",
  "version": "1.0.0",
  "created_utc": "2026-10-08T09:12:44Z",
  "created_by": "colin",
  "model": {
    "family": "YOLO26",
    "variant": "nano",
    "task": "detect",
    "head": "one-to-one (NMS-free), cropped after decode+sigmoid",
    "framework": "ultralytics",
    "framework_version": "8.3.x",
    "source_weights": "runs/detect/drone3/weights/best.pt",
    "onnx_file": "best.onnx",
    "onnx_sha256": "<64 hex>",
    "export_args": "format=onnx imgsz=640 batch=1 simplify=True dynamic=False nms=False",
    "license": "AGPL-3.0 (decision: enterprise license, ticket #123)"
  },
  "classes": ["person", "vehicle", "cyclist"],
  "input": {
    "shape_nhwc": [640, 640, 3],
    "dtype": "float32",
    "color_order": "RGB",
    "normalization": { "scale": 0.00392156862745098, "mean": [0, 0, 0], "std": [1, 1, 1] },
    "resize": "letterbox",
    "pad_value": 114
  },
  "outputs": [
    { "name": "boxes",  "shape": [8400, 4], "meaning": "x1,y1,x2,y2 in input pixels" },
    { "name": "scores", "shape": [8400, 3], "meaning": "sigmoid class scores" }
  ],
  "host_post": { "type": "threshold_topk", "post_onnx": null, "conf_threshold": 0.35, "top_k": 100 },
  "compiler": {
    "mx_nc_version": "<output of mx_nc --version>",
    "sdk": "2.2",
    "python": "3.11.9",
    "host": "WSL2 Ubuntu 22.04, x86_64, AVX2",
    "extra_args": "-e hard --input_format FP32"
  },
  "dfps": [
    { "chip_count": 4, "file": "yolo26n-pvc3-640x640_c4.dfp", "sha256": "<64 hex>",
      "size_bytes": 12345678, "compile_seconds": 512, "status": "ok", "verified_on_board": false },
    { "chip_count": 2, "file": "yolo26n-pvc3-640x640_c2.dfp", "sha256": "<64 hex>",
      "size_bytes": 12000000, "compile_seconds": 430, "status": "ok", "verified_on_board": false }
  ],
  "frequency": { "recommended_mhz": 300, "source": "tx8-freq-matrix.csv YOLO26_nano_640 (4 chips) + TX8 stability test pending" },
  "accuracy": {
    "dataset": "drone3-test v2 (sha256 of file list: <hex>)",
    "images": 1200,
    "metric_tool": "ultralytics val 8.3.x",
    "baseline_onnx": { "map50_95": 0.512, "map50": 0.781, "recall_at_op": 0.86 },
    "mx3":           { "map50_95": 0.505, "map50": 0.776, "recall_at_op": 0.85 },
    "budget": "<= 1.0 mAP point",
    "passed": true
  }
}
```
Notes:
- `outputs` must match the compiled DFP (check `dfp_inspect` and the runtime `get_model_info()`),
  including order; the C++ post-processing reads this.
- `verified_on_board` flips to `true` only after the TX8 stability test (skill
  `um-pi-mx3-runtime-integration`) passes for that chip count.

## Minimal JSON Schema (for CI validation)
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "required": ["schema_version", "name", "version", "model", "classes", "input", "compiler", "dfps"],
  "properties": {
    "name":    { "type": "string", "pattern": "^[a-z0-9][a-z0-9.-]*$" },
    "version": { "type": "string", "pattern": "^\\d+\\.\\d+\\.\\d+$" },
    "classes": { "type": "array", "items": { "type": "string" }, "minItems": 1 },
    "input": {
      "type": "object", "required": ["shape_nhwc", "dtype", "normalization"],
      "properties": { "shape_nhwc": { "type": "array", "items": { "type": "integer" }, "minItems": 3, "maxItems": 3 } }
    },
    "dfps": {
      "type": "array", "minItems": 1,
      "items": {
        "type": "object", "required": ["chip_count", "file", "sha256", "status"],
        "properties": {
          "chip_count": { "type": "integer", "minimum": 1, "maximum": 4 },
          "sha256": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
          "status": { "enum": ["ok", "failed"] }
        }
      }
    }
  }
}
```

## Deployment copy to the board
From the dev machine (WSL2 or Linux), using the `umpi` SSH alias:
```bash
NAME=yolo26n-pvc3-640x640; VER=1.0.0; SRC=models/$NAME/$VER
ssh umpi "mkdir -p ~/models/$NAME/$VER"
scp $SRC/*.dfp $SRC/manifest.json $SRC/SHA256SUMS umpi:~/models/$NAME/$VER/
# copy the _post.onnx too if the manifest references one
ssh umpi "cd ~/models/$NAME/$VER && sha256sum -c SHA256SUMS"
# atomically switch the 'current' pointer the application reads
ssh umpi "ln -sfn ~/models/$NAME/$VER ~/models/$NAME/current.tmp && mv -T ~/models/$NAME/current.tmp ~/models/$NAME/current"
```
- `SHA256SUMS` must list only files that are copied (or use `--ignore-missing`, GNU coreutils).
- The application should read `manifest.json`, pick `dfps[chip_count == configured]`, and verify
  its sha256 at start-up (cheap: hashing ~10 MB on an A53 takes well under a second — measure, it
  counts toward the 3 s start budget; alternatively verify once at install time).
- Keep the previous version on the board for rollback; remove old versions only on request.

## Release checklist
- [ ] Manifest complete, validates against the schema.
- [ ] `SHA256SUMS` verified on the board.
- [ ] Accuracy block filled and within budget.
- [ ] Stability test at the chosen clock passed for each chip count marked verified.
- [ ] License decision recorded.
