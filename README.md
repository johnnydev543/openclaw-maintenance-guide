# OpenClaw NAS 維護指引

[English version](README.en.md)

本指引採用安全優先的架構：Gateway 原生執行於 NAS 的專用低權限使用者；所有 agent 的 shell 與工具命令，都在 rootless Docker sandbox 內執行。

```text
Reverse proxy
  → host-native OpenClaw Gateway（專用非 root 使用者）
  → rootless Docker sandbox
  → agent 的工具與 shell 命令
```

Gateway 保有模型、LINE、GitHub OAuth 等憑證；它們不可寫入 image、workspace，也不可掛載到 sandbox。

## 基本原則

- Gateway 使用專用 `openclaw` Linux 使用者執行，且不授予 sudo。
- rootless Docker 只由 `openclaw` 用於 sandbox 生命週期管理。
- sandbox 預設採用唯讀 root filesystem、`capDrop: ALL`、無網路。
- agent 所需的系統套件預先放進自訂 sandbox image；不要在 agent 執行期間安裝。
- 不要將 host Docker socket、私有 NAS 目錄或憑證掛入 sandbox。

## 進入維護環境

先登入 NAS，並切換至專用使用者：

```bash
ssh nas
sudo -iu openclaw

export PATH="$HOME/.local/openclaw/bin:$HOME/.local/bin:$PATH"
export OPENCLAW_CONFIG_PATH="$HOME/.openclaw/openclaw.json"
export OPENCLAW_STATE_DIR="$HOME/.openclaw"
export DOCKER_HOST="unix:///run/user/$(id -u)/docker.sock"
```

避免以 root 身份直接執行 OpenClaw。root 僅用於 NAS 層級維護或安裝系統更新。

## 日常健康檢查

```bash
openclaw gateway status
openclaw sandbox list
openclaw models status --check
openclaw channels status --probe
openclaw security audit --deep
```

Gateway 異常時：

```bash
openclaw gateway restart
openclaw gateway status
```

sandbox container 由 OpenClaw 自動建立與管理；不要用 Docker 手動啟動它。

查看 Gateway 最近日誌時，以 NAS 管理帳號執行：

```bash
sudo -u openclaw \
  XDG_RUNTIME_DIR=/run/user/1001 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus \
  journalctl --user -u openclaw-gateway -n 100 --no-pager
```

## 更新 OpenClaw

先預覽：

```bash
openclaw update status
openclaw update --dry-run
```

確認後以互動方式更新：

```bash
openclaw update
```

更新後檢查：

```bash
openclaw doctor --lint
openclaw security audit --deep
openclaw gateway status
openclaw channels status --probe
```

如果更新要求 plugin capability 擴權，應先閱讀權限變化。不要為了省事使用自動接受擴權。待新版穩定一段時間後，才考慮執行：

```bash
openclaw update cleanup
```

此動作會清理更新復原資料，降低回滾能力。

## 自訂 sandbox image

預設 image 是刻意精簡的：

```text
openclaw-sandbox:bookworm-slim
```

若 agent 需要更多工具，建立帶日期或版本號的新 image，例如：

```text
openclaw-sandbox:tools-YYYY-MM-DD
```

repository 的 `sandbox/` 目錄提供可獨立維護的套件清單：

```text
scripts/build-sandbox-image.sh   # 內建建議基礎 apt 與 pip 套件
sandbox/apt-packages.txt         # 不追蹤：此 NAS 額外的 Debian 套件
sandbox/pip-packages.txt         # 不追蹤：此 NAS 額外的 Python 套件
sandbox/Dockerfile               # 不需修改；建置時讀取腳本產生的清單
```

腳本內建一般 agent 常用的基礎工具：Git、curl、jq、ripgrep、Python、HTTP/HTML Python 套件與壓縮工具。`rclone`、`ffmpeg`、`opencc`、`gh`、資料分析套件等較專門的需求，放入本機套件檔即可。

要加入 NAS 專用套件時，建立或編輯這兩個本機檔案：

```bash
touch sandbox/apt-packages.txt sandbox/pip-packages.txt
```

兩者已列入 `.gitignore`，不會被提交；每行一個套件，仍不得放入 token、密碼或其他憑證。

首次在 NAS 上，以 `openclaw` 使用者將本 repository clone 到其 home 目錄；之後在 repository 根目錄執行：

```bash
./scripts/build-sandbox-image.sh
```

腳本會自動完成以下流程：建置帶當日版本 tag 的 image、更新 sandbox image 設定、驗證設定、重啟 Gateway、刪除舊 sandbox container，並列出新狀態。下一次 agent 執行時，新 container 會自動建立。

同一天再次修改套件時，傳入新的版本尾碼：

```bash
./scripts/build-sandbox-image.sh 2026-09-09-r2
```

腳本拒絕覆蓋既有 image tag，避免失去可回退的版本。

### 新增套件的固定流程

```text
修改本機 apt 或 pip 套件清單
→ 建置新 versioned image
→ 變更 OpenClaw image 設定
→ 驗證設定
→ 重啟 Gateway
→ 重建 sandbox
→ 實測 agent
```

不要覆蓋舊 image tag。保留上一個可用版本，才能快速回退。

### Playwright Chromium

不要在執行中的 sandbox 裡使用 `playwright install-deps` 或 `playwright install chromium`。sandbox 的 root filesystem 是唯讀；正確做法是在 image 建置時安裝。

先在 NAS 本機的 `sandbox/pip-packages.txt` 加入 `playwright`，再執行：

```bash
./scripts/build-sandbox-image.sh 2026-09-09-playwright --playwright-chromium
```

這會在 image build 階段下載 Chromium、安裝它的 Debian 系統依賴，並在完成後套用新 image。image 會明顯變大，這是正常的；之後 agent 不必也不應在 runtime 再執行 Playwright 安裝。

## 網路與 GitHub 的注意事項

即使 image 內已有 `curl`、`git`、`gh` 或 `rclone`，在 sandbox 網路仍是 `none` 時，它們仍無法連外。若特定 agent 確有需求，應逐一評估其網路例外，不要一口氣開放所有 agent。

sandbox 內的 `gh` 不會自動繼承 OpenClaw 的 GitHub OAuth。不要將 GitHub token、LINE token 或模型 API key 放入 Dockerfile、image、workspace 或 Git repository。

## 設定、備份與 reverse proxy

變更設定後，先驗證再重啟：

```bash
openclaw config validate
openclaw gateway restart
```

尤其是以下設定，應視為安全敏感項目：Gateway auth、trusted proxies、Control UI origins、channel credentials、provider credentials，以及 sandbox mounts。

應備份並保護：

```text
~/.openclaw/
~/.config/openclaw/gateway.env
自訂 sandbox Dockerfile 與 image 版本紀錄
```

備份必須加密或限制存取。若以檔案方式備份 SQLite state，必須在一致性快照內連同 `.sqlite`、`-wal` 與 `-shm` 一併保存。

外部 HTTPS 通常由 reverse proxy 提供，並將流量轉送到 NAS Gateway 的 `18789` port。一般 OpenClaw 更新不需要變更 reverse proxy；外部連線異常時，依序確認 Gateway、LAN 上游連線、reverse proxy 與 DNS/NAT。

## 不應執行的操作

- 不要讓 `openclaw` 使用者取得 sudo。
- 不要將 host Docker socket 掛入 sandbox。
- 不要把 token 或 secret 寫入 image、Dockerfile、workspace 或 repository。
- 不要在共用的 system Docker daemon 上執行廣泛清理。
- 不要在確認不再需要前刪除 state、sessions、workspace 或復原備份。

## 每月例行項目

```text
1. 檢查更新並閱讀 release / capability 變化。
2. 執行 doctor lint 與 security audit --deep。
3. 測試 Gateway、channel 與模型連線。
4. 確認備份可讀取且受保護。
5. 檢視 image 與 plugin / skill 是否仍有必要。
```
