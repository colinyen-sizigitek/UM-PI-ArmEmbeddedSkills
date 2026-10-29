# TX8 + MemryX MX3 Agent Skills Suite

這套 Skills 專為 **UM-PI 無人機 AI 平台**（TX8 SOM 4核 Cortex-A53 + MemryX 4核 MX3 加速卡）設計，讓 **Google Antigravity (Gemini)**、**Claude Code**、**OpenAI Codex** 能直接在專案中產出高可靠、高效能、不當機的嵌入式 C++17 與 AI 推論程式碼。

---

## 快速導覽與各 AI 模型調用方法

本專案支援自動觸發（依自然語言語意）與手動指定（斜線指令或技能名稱）。

| 模型 / 工具 | 設定目錄 / 支援機制 | 手動調用方式 | 自然語言範例 |
| :--- | :--- | :--- | :--- |
| **Google Antigravity / Gemini** | `~/.gemini/config/plugins/arm-embedded-skills` 或專案 `.agents/skills` | 於對話指定 `um-pi-platform`、`um-pi-cpp-performance` 等 | 「幫我檢查這台電腦環境，並用 `um-pi-platform` 連接 TX8 板子」 |
| **Claude Code** | 專案目錄 `.claude/skills/<skill-name>` | `/um-pi-platform`<br>`/um-pi-mx3-model-selection` | 「/um-pi-code-review 幫我審查目前的 PR 是否有即時性阻塞問題」 |
| **OpenAI Codex** | 專案目錄 `.agents/skills/<skill-name>` | `$um-pi-platform` 或 `/skills` | 「請依照 um-pi-vision-pipeline 設計 UVC MJPEG 雙通道管線」 |

---

## 八大專業 Skills 一覽

| Skill 名稱 | 職責與使用時機 | 包含腳本與工具 |
| :--- | :--- | :--- |
| [`um-pi-platform`](skills/um-pi-platform/SKILL.md) | 板端環境探測、開箱檢查、WSL2/Win 開發環境健檢、CMake 交叉編譯與 Systemd 部署 | `board_probe.sh`<br>`host_env_check.ps1`<br>`deploy.sh` |
| [`um-pi-cpp-performance`](skills/um-pi-cpp-performance/SKILL.md) | Cortex-A53 微架構最佳化、Armv8.0 NEON Intrinsics、Cache 對齊、執行緒綁核與 perf PMU 計數器 | `bench_template.cpp`<br>`perf_a53.sh`<br>`membw.cpp` |
| [`um-pi-vision-pipeline`](skills/um-pi-vision-pipeline/SKILL.md) | 雙通道 UVC MJPEG 擷取（CH1 直轉、CH2 TurboJPEG 解碼）、推論啟停狀態機、WebSocket / MAVLink | `soak_test.sh`<br>`assets/protocol.h` |
| [`um-pi-mx3-model-selection`](skills/um-pi-mx3-model-selection/SKILL.md) | 7大需求訪談、模型選型（YOLOv10 / YOLO26）、頻率矩陣查詢（$\le 400\text{ MHz}$ 鐵則） | `freq_query.ps1`<br>`freq_query.py` |
| [`um-pi-mx3-model-compile`](skills/um-pi-mx3-model-compile/SKILL.md) | x86 Linux / WSL2 模型導出為 ONNX、類別裁減、`mx_nc` 編譯各晶片數 DFP 與 SHA256 清單 | `compile_all_chipcounts.sh`<br>`check_compile_env.sh` |
| [`um-pi-mx3-runtime-integration`](skills/um-pi-mx3-runtime-integration/SKILL.md) | C++ `MxAcclMT` 執行期整合、無鎖定 SPSC 環形緩衝區、溫度/功耗監控、400→300MHz 降頻容錯 | `mx3_diag.sh`<br>`mx3_stability_test.sh` |
| [`um-pi-basestation-viewer`](skills/um-pi-basestation-viewer/SKILL.md) | Windows 地面站 Python 接收端（時間同步、框幀對齊、延遲估計）與無硬體測試伺服器 | `viewer.py`<br>`fake_tx8_server.py` |
| [`um-pi-code-review`](skills/um-pi-code-review/SKILL.md) | 合併與飛行前嚴格審查（BLOCKER > MAJOR > MINOR > NIT），提供具體程式碼修復方案 | `checklist.md`<br>`anti-patterns.md` |

---

## 一鍵安裝至本地專案

本專案提供 PowerShell (Windows) 與 Bash (Linux/macOS) 安裝腳本，可自動將技能複製到指定位置並建立常駐規則：

### 1. 安裝至特定專案（建議方式，適合 Git 版本控制）
```powershell
# 在 Windows PowerShell 執行（替換 C:\path\to\your\project 為您的專案路徑）：
powershell -NoProfile -ExecutionPolicy Bypass -File install\install.ps1 -Target all -Scope project -ProjectPath "C:\path\to\your\project"
```
* **效果**：會在您的專案底下建立 `.agents/skills`（供 Antigravity、Codex 讀取）、`.claude/skills`（供 Claude 讀取），並將 `shared/AGENTS.tx8.md` 合併至專案的 `AGENTS.md`。

### 2. 全域安裝至個人環境（所有專案通用）
```powershell
# 針對 Google Antigravity 全域安裝 Plugin 套件：
powershell -NoProfile -ExecutionPolicy Bypass -File install\install.ps1 -Target antigravity -Scope user
```
* **效果**：會自動安裝至 `~/.gemini/config/plugins/arm-embedded-skills`，隨附完整 Plugin 清單與常駐 Rules。

---

## 完整使用範例 (Examples)

### 範例一：使用 Google Antigravity / Gemini 檢查硬體環境
* **對話輸入**：
  > 「請使用 `um-pi-platform` 技能，檢查我的 Windows 開發機環境，並透過 `ssh umpi` 探測 TX8 板子的硬體狀態。」
* **AI 行為**：自動調用 `skills/um-pi-platform/scripts/host_env_check.ps1` 檢查主機，並透過 SSH 執行 `board_probe.sh`，回傳 CPU revision、RAM 容量 (2GB/4GB) 與 PCIe 通道狀態報告。

### 範例二：使用 Claude Code 選定適合空拍的偵測模型
* **對話輸入**：
  > `/um-pi-mx3-model-selection 我要在無人機上做空拍人員與車輛偵測，目標 30 FPS，請幫我選型並查詢安全時脈。`
* **AI 行為**：執行需求訪談，調用 `freq_query.ps1` 查詢 `tx8-freq-matrix.csv`，挑選 NMS-free 且時脈 $\le 400\text{ MHz}$（且頻率滿足 FPS $\ge 45$）的模型，給出推薦配置與風險評估。

### 範例三：使用 OpenAI Codex 撰寫高效 NEON 前處理
* **對話輸入**：
  > 「請依照 `um-pi-cpp-performance` 規則，幫我寫一個從 640x640 RGB uint8 轉成 float32 NHWC 正規化 (x/255) 的 Armv8.0 NEON 函式，要求預取並消除分支。」
* **AI 行為**：依照規範撰寫使用 `vld1q_u8`、`__builtin_prefetch`、獨立累加鏈與純 Armv8.0 指令的 C++17 程式碼，並附帶對應的 Scalar 精度比對測試單元。

---

## 核心設計守則 (Non-Negotiable Rules)
1. **事實優先 (Facts First)**：板端硬體規格、核心版本、API 簽章一律先以實機或標頭檔探測為準，絕不盲目臆測。
2. **可靠性 > 效能 > 功耗 > 大小**：達到 30 FPS / 80ms p99 延遲目標即停止過度最佳化，不浪費無人機電池。
3. **MX3 時脈 $\le 400\text{ MHz}$**：嚴禁使用 MemryX 預設的 500 MHz，防止晶片過熱或 255°C PCIe 鎖死。
4. **絕不在 TX8 上重編碼影像**：CH1 1080p MJPEG 原封不動直轉地面站，偵測框以 Metadata 傳送。
5. **熱路徑零動態配置**：影格推論路徑中嚴禁 `malloc` / `new` / `std::vector::resize`，全面採用預先配置的固定環形緩衝池。
