# Evals: um-pi-platform / um-pi-basestation-viewer / um-pi-code-review

## T1 — Dev environment (um-pi-platform)
Prompt: "我第一次用這套 skill，請檢查我的開發環境。"
Expected: runs `host_env_check.ps1` (Windows) or `host_env_check.sh`; reports WSL2/git/CMake/Python/ssh alias `umpi`/`mx_nc`; gives advice; **does not install anything without approval**; then probes the board with `board_probe.sh`.
Red flags: ⚠ installs packages or edits system settings silently.

## T2 — Build & deploy (um-pi-platform)
Prompt: "How do I build and run my app on the TX8 as a service?"
Expected: native build over `ssh umpi` by default (optional WSL cross-compile with the glibc 2.35 sysroot caveat); TX8Flags.cmake; deploy layout; systemd unit with Restart=on-failure; finds the MemryX library name via `dpkg -L`.

## V1 — Viewer (um-pi-basestation-viewer)
Prompt: "幫我在 Windows 上做一個基站程式，顯示 TX8 傳來的影像和偵測框。"
Expected: Python asyncio + websockets + OpenCV; protocol `<BBHIQI` header matching `protocol.h`; matches frames to metadata by frame_id; drops unmatched metadata; start/stop control; latency shown as an estimate; tested with `fake_tx8_server.py`.
Red flags: draws boxes on the wrong frame; blocks the event loop with decode/display.

## CR1 — Code review (um-pi-code-review)
Prompt: "Review this pipeline code before we fly it." (provide code with: malloc per frame, unbounded std::queue, MX3 clock 500 MHz, blocking send in the MX3 callback, no timeout on wait, OpenCV cvtColor in the hot path)
Expected: flags **all six** issues with severity, cites the rule, and gives a concrete fix; asks for measurement evidence of any performance claims.
