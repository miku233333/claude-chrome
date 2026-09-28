# Claude Chrome

<img src="Resources/Logo.png" alt="Claude Chrome 圖示" width="128">

[English](README.md)

Claude Chrome 是輕量原生 macOS 啟動器，使用獨立 Chrome profile 及固定本機 HTTP 代理，避免讀寫日常 Chrome profile。

## 系統需求

- Apple 晶片 Mac，macOS 13 或以上
- Google Chrome 安裝於 `/Applications`
- HTTP 代理監聽 `127.0.0.1:17897`
- 已安裝包含 `swiftc` 的 Command Line Tools

## 建置

從源碼建置：

```sh
./scripts/build.sh
```

App 會輸出至 `dist/Claude Chrome.app`，以 ad hoc 簽署供本機使用。建置流程最多保留一份舊版本：`dist/Claude Chrome.app.latest-backup`。

本倉庫只發布源碼及建置說明，不提供未經 notarization 的二進位 release。請自行建置，再將 App 移至 `/Applications`。

## 安裝

將 `dist/Claude Chrome.app` 複製到 `/Applications`，然後開啟。

## 使用

開啟 `Claude Chrome.app` 後，Chrome 會使用：

- `~/Library/Application Support/Claude Chrome/Profile` 的獨立 profile；
- `http://127.0.0.1:17897` 本機代理；
- 停用未經代理的 WebRTC UDP。

如果舊 profile `~/.local/share/claude-network-guard/chrome-login-profile` 已存在，App 會沿用它。Profile 必須是權限 `0700` 的真實目錄，不能是 symlink。

### 本機代理設定

預設代理是 `http://127.0.0.1:17897`。如需使用其他本機 HTTP 代理，建立 `~/Library/Application Support/Claude Chrome/config.json`，然後重新開啟 App：

```json
{
  "proxyURL": "http://127.0.0.1:7897"
}
```

只接受 `http` 或 `https`、主機為 `localhost`、`127.0.0.1` 或 `::1`，並明確包含連接埠的網址。不支援帳號密碼、URL 路徑、PAC 或直連繞過設定。

## 安全範圍

本 App 是 Chrome 私隱輔助工具，並非作業系統層級的網絡 kill switch。它不會修改 macOS 網絡設定，也不能保護經其他方式啟動的 Chrome。使用前必須先啟動本機代理。

本 App 不保證帳戶可用性，亦不能保證避免服務限制或封禁。Claude Chrome 是獨立專案，與 Anthropic 或 Google 沒有從屬、認可或支援關係。

本專案以 MIT License 發布。
