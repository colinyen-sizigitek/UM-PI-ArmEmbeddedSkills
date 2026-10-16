# Evals: mx3-model-selection / mx3-model-compile / mx3-runtime-integration

## S1 — Model selection (mx3-model-selection)
Prompt: "我們要在無人機上偵測人和車，幫我選一個 MX3 上的模型。"
Expected:
- Asks the requirement questions first: task, classes, object size/altitude, fps/latency, chip count/power, accuracy, **commercial vs internal licence**.
- Proposes NMS-free and class-reduced candidates (e.g. YOLOv10n-PVA, YOLO26n) at 640.
- Applies the frequency rule: ≤ 400 MHz, lowest PASS clock with fps ≥ 30 × 1.5 → 300 MHz for the nano models.
- States that the table is MemryX reference data and must be verified on TX8; flags the AGPL licence.
Red flags: ⚠ recommends 500 MHz or the MemryX ARM default; ⚠ skips the licence question; quotes the x86 Model Explorer FPS as TX8 performance.

## S2 — Frequency rule edge case (mx3-model-selection)
Prompt: "YOLO26 small 640 可以跑 30fps 嗎？"
Expected: at 400 MHz the table shows 31 fps < 45 → not recommended; suggests YOLOv10s-PVA at 400 MHz or a nano model; does not raise the clock above 400 MHz.

## C1 — Compile (mx3-model-compile)
Prompt: "幫我把自己訓練的 YOLOv10n（2 類）編譯成 MX3 的 DFP，要支援 1~4 顆晶片。"
Expected: compile on x86/WSL (not on the board); ONNX export with batch=1 and a fixed imgsz; one DFP per chip count (`-c 1..4`); decode kept in the graph; accuracy check against the float model; a manifest with sha256/SDK version/classes/normalization.
Red flags: ⚠ runs `mx_nc` on the TX8 board; uses the Python post model on ARM.

## R1 — Runtime (mx3-runtime-integration)
Prompt: "Write the C++ class that starts MX3 inference when requested and shuts it down when not needed."
Expected: creates MxAccl only on start; `set_operating_frequency` right after construction and before any input, with a clock ≤ 400 MHz taken from the rule; timeouts; no blocking in callbacks; destroys/releases on stop; measures start latency (≤ 3 s); handles faults (step down 400→300 MHz, 255 °C → FAULT, reboot needed); tells the reader to check the installed header for uncertain signatures.
Red flags: ⚠ invents API signatures without caveat; ⚠ keeps MX3 running while idle; relies on the deprecated `stop()`.

## R2 — Diagnostics (mx3-runtime-integration)
Prompt: "MX3 好像只跑出一半的效能，怎麼查？"
Expected: `lspci -vv` LnkSta (x2 vs x4, Gen3), the configured clock, temperature/throttling, shared vs local mode and the scheduler limits, host-side CPU bottleneck (float conversion), `mx_bench` baseline.
