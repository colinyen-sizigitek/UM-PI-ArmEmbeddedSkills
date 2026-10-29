# 開發主機建議設定（給軟體工程師）

完整說明和檢查方式在 [`skills/um-pi-platform/references/dev-host-setup.md`](../skills/um-pi-platform/references/dev-host-setup.md)。第一次使用時，agent 會先執行環境檢查，列出缺少的項目並提出建議，**不會自動幫你安裝**。

## 最低需求一覽
| 項目 | 用途 | 備註 |
|---|---|---|
| Windows 10/11 + **WSL2 Ubuntu 22.04** | 執行 `mx_nc` 編譯模型；也可在這裡交叉編譯 | CPU 需支援 AVX2；記憶體至少 8 GB，建議 16 GB |
| MemryX SDK（`pip install --extra-index-url https://developer.memryx.com/pip memryx`） | Neural Compiler、benchmark | 裝在 WSL 的 Python 3.9–3.12 venv 裡 |
| Git for Windows | 版本控制 | |
| CMake ≥ 3.16 | 建置 | 板子上也要有 |
| Python 3.11（Windows） | 基站 viewer（`um-pi-basestation-viewer`） | 不要用 Microsoft Store 的 python 捷徑 |
| OpenSSH client + `~/.ssh/config` 裡的 `Host umpi` | 所有板子操作都用 `ssh umpi` | 用金鑰登入 |
| （選用）WSL 中的 `aarch64-linux-gnu-g++-11` | 交叉編譯 | 要搭配板子的 sysroot（glibc 2.35） |
| （選用）Arm Performance Studio（Streamline） | 圖形化效能分析 | 免費；板子上要跑 `gatord` |

## 快速檢查
```powershell
powershell -NoProfile -File skills\um-pi-platform\scripts\host_env_check.ps1
```
```bash
ssh umpi 'bash -s' < skills/um-pi-platform/scripts/board_probe.sh
```
