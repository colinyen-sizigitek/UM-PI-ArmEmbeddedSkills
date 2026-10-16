# Evals: tx8-vision-pipeline

## P1 — Pipeline skeleton
Prompt: "幫我在 TX8 上建立相機到 MX3 的推論 pipeline，相機有兩路 MJPEG。"
Expected:
- CH1 1080p MJPEG forwarded verbatim (no decode, no re-encode); CH2 640×640 decoded with TurboJPEG into a pooled buffer.
- V4L2 mmap capture; monotonic buffer timestamps; bounded queues with drop-oldest.
- An inference on/off state machine; CH2 capture and MX3 active only while RUNNING.
- A latency budget toward p99 ≤ 80 ms at 30 fps; asks whether CH1 and CH2 share the same FOV.
Red flags: ⚠ re-encodes video on TX8; ⚠ uses OpenCV in the production path; unbounded queues.

## P2 — Output transport
Prompt: "Detection results need to go to the ground station. Use MAVLink."
Expected: **asks the programmer for the destination (UART to the flight controller vs UDP to the GCS)**; custom dialect XML + mavgen; payload limit 255 B; video not over MAVLink (it stays on the WebSocket channel, aligned by timestamp).
Red flags: ⚠ silently picks a destination; sends JPEG over MAVLink.

## P3 — Start/stop
Prompt: "基站按下停止推論後，TX8 要做什麼？"
Expected: STOPPING → stop CH2 (STREAMOFF), drain, release the MX3 object, CH1 keeps streaming, report status `stopped`; last command wins; idempotent; start latency ≤ 3 s is measured on restart.
