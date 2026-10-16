# 待確認事項（Open Items）

這些問題在建立 skill 時無法從文件或網路確認。skill 內容遇到這些地方都標成「verify on TX8」或「ask the programmer」。確認後請更新 `docs/DESIGN.md`，再同步到相關的 skill。

| # | 項目 | 影響的 skill | 怎麼確認 |
|---|---|---|---|
| 1 | MX3 怎麼進入 standby 或 hibernate：官方沒有公開的軟體 API | mx3-runtime-integration | 到 MemryX 社群詢問（https://community.memryx.com/）；在板子上量測釋放 `MxAccl` 之後的功耗 |
| 2 | Cascade 100M 的 PCIe 實際連線寬度：MemryX 文件寫 x2，插槽是 x4 | mx3-runtime-integration, tx8-platform | 在板子上執行 `sudo lspci -vv`，看 `LnkSta` |
| 3 | MemryX C++ runtime 的 CMake target 或函式庫名稱：官方文件沒寫 | tx8-platform, mx3-runtime-integration | 在板子上執行 `dpkg -L memx-accl`，查看 `/usr/lib/.../cmake` |
| 4 | `set_operating_frequency` 的參數型別：兩份文件寫法不一致 | mx3-runtime-integration | 查板子上的 `/usr/include/memx/accl/MxAccl.h` |
| 5 | MX3 時脈參考表**不是在 TX8 上量的** | mx3-model-selection | 用 `mx3_stability_test.sh` 在 TX8 上重新量測候選模型 |
| 6 | 1–3 顆晶片配置的時脈和穩定性數據：參考表只有 4x1 | mx3-model-selection, mx3-runtime-integration | 用穩定性測試量測 |
| 7 | carrier board 能否用 GPIO 控制 M.2 插槽電源 | mx3-runtime-integration | 查 UM-PI 硬體設計 |
| 8 | 相機 CH1 和 CH2 是不是同一個 sensor、同一個 FOV，以及是一台相機出兩路，還是兩台 UVC 裝置 | tx8-vision-pipeline | 用 `v4l2-ctl --list-devices` 和 `--list-formats-ext` 查看，並詢問相機供應商 |
| 9 | Cortex-A53 的 revision，決定要不要加勘誤編譯旗標 | tx8-platform, tx8-cpp-performance | 查 `/proc/cpuinfo` 的 CPU revision |
| 10 | KleidiCV 在 A53 上的正確性和效能：官方沒有測試過 | tx8-cpp-performance, tx8-vision-pipeline | 和純量版本比對輸出，再做 benchmark |
| 11 | TX8 的工作溫度範圍、SoC 功耗：規格書沒寫 | tx8-platform | 向 Unimap 索取，並取得 UM-PI 使用者手冊 |
| 12 | MAVLink 要送到哪裡：UART 接飛控（PX4 還是 ArduPilot？），或 UDP 送地面站 | tx8-vision-pipeline | 每個專案開始時詢問開發者 |
| 13 | 商用產品能不能接受 AGPL/GPL 授權的模型 | mx3-model-selection | 由產品和法務決定 |
| 14 | **晶片數 1–4 可選，和 MemryX 教學有衝突**：教學說 4 晶片 M.2 只能直接跑編譯成 2 或 4 晶片的 DFP，1 晶片 DFP 會報錯，3 晶片沒有提到 | mx3-model-compile, mx3-runtime-integration | **產品決定（2026-10-08）：先保留 1–4 顆可選**。工程師在板子上實測 c1 和 c3 的 DFP，並詢問 MemryX；依實測結果決定最後支援哪些晶片數 |
| 15 | 1 晶片 DFP × N 的資料平行：`device_ids` 選的是整張模組，不是單顆晶片，單一模組上沒有文件化的做法 | mx3-runtime-integration | 詢問 MemryX |
| 16 | YOLOv10/11/26 的 extension 是不是自動啟用：release notes 說自動，編譯器頁面說要加 `--extensions Yolov10` | mx3-model-compile | 看實際的 `mx_nc --help` |
| 17 | `set_operating_frequency` 什麼時候呼叫：文件說要在 `connect_dfp` 之前，但建構子已經載入 DFP；MemryX 的 acclBench 是建構後立刻呼叫 | mx3-runtime-integration | 依板子上的標頭檔確認，並實測 |
