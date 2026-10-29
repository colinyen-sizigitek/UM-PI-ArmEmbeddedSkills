# 實機與編譯驗證 Checklist

這台檢視用的電腦沒有工具鏈，也連不到板子，所以 skill 裡的程式碼和腳本**尚未實際編譯或執行過**。請軟體工程師在自己的開發機和 UM-PI 上依序完成下面的項目，結果記在每項後面。

## A. 開發主機（Windows + WSL2）
- [ ] `powershell -File skills\um-pi-platform\scripts\host_env_check.ps1`：每一項都是 OK，或已經知道缺什麼
- [ ] 在 WSL 裡執行 `bash skills/um-pi-platform/scripts/host_env_check.sh`
- [ ] `python scripts/validate.py` 通過（Python 3.10 以上）
- [ ] `ssh umpi true` 用金鑰免密碼登入成功

## B. 板子事實
- [ ] `ssh umpi 'bash -s' < skills/um-pi-platform/scripts/board_probe.sh > board-report.md`
- [ ] 把下列結果回填到 `docs/open-items.md`：
  - PCIe 連線寬度（第 2 項）
  - MemryX 函式庫名稱（第 3 項）
  - CPU revision（第 9 項）
  - 相機裝置（第 8 項）
- [ ] `ssh umpi 'bash -s' < skills/um-pi-mx3-runtime-integration/scripts/mx3_diag.sh`

## C. 編譯驗證（在板上原生編譯，也可以用 WSL 交叉編譯）
- [ ] `skills/um-pi-cpp-performance/scripts/bench_template.cpp` 和 `membw.cpp`：用 `-Werror` 編譯沒有警告
- [ ] `skills/um-pi-vision-pipeline/assets/protocol.h`：寫一個小測試 include 進來，確認可以編譯
- [ ] `skills/um-pi-platform/assets/cmake/*`：用一個空專案跑 `cmake` configure，確認成功
- [ ] `skills/um-pi-mx3-runtime-integration/references/cpp-api-usage.md` 裡的 `Mx3Engine` 範例：依板子上實際的標頭檔修正後可以編譯
- [ ] bash 腳本都通過 `shellcheck`

## D. 效能與穩定性
- [ ] `membw` 量出 L1、L2、DRAM 的延遲和頻寬，回填到 `um-pi-cpp-performance/references/a53-microarch.md` 中標「verify on TX8」的地方
- [ ] `perf_a53.sh` 能正常讀到 A53 PMU 事件（`dmesg | grep -i pmu`）
- [ ] 候選模型在 300 和 400 MHz 下跑 `mx3_stability_test.sh`，結果追加到 `tx8-freq-matrix.csv`，`mpu_config` 欄註明是 TX8 實測
- [ ] 完整 pipeline 跑 `soak_test.sh` 10 分鐘，確認：
  - 30 fps 不掉幀
  - TX8 內部延遲 p99 ≤ 80 ms
  - 推論啟動延遲 ≤ 3 秒
- [ ] 用 `mx3_power_probe.sh` 量測閒置、推論中、釋放後三種狀態的功耗，回填到 `docs/open-items.md` 第 1 項

## E. 端到端
- [ ] Windows 上執行 `python skills/um-pi-basestation-viewer/scripts/fake_tx8_server.py`，再用 `viewer.py` 連上去，確認畫面和偵測框正常
- [ ] 實機：用 `viewer.py` 連 TX8，測試 start/stop，確認偵測框和畫面對齊
- [ ] MAVLink 模式：依專案選定的傳輸方式（UART 或 UDP），用 MAVProxy 或 QGroundControl 確認收得到自訂訊息

## F. Agent 評估
- [ ] 在 Claude Code、Codex、Antigravity 三個工具中，分別用 `evals/` 下的 prompt 測試，確認會觸發正確的 skill，回答也涵蓋「預期重點」
