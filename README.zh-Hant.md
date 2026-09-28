# Claude Chrome

<img src="Resources/Logo.png" alt="Claude Chrome 圖示" width="128">

[English](README.md)

Claude Chrome 1.1.0 是輕量原生 macOS 啟動器，使用獨立 Google Chrome profile 及固定本機 HTTP 代理。專案以 MIT License 發布於 [miku233333/claude-chrome](https://github.com/miku233333/claude-chrome)。

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

## 啟動方式

Claude Chrome 會在有網址列及分頁的標準 Chrome 視窗開啟內置環境檢查頁。按 `⌘L` 輸入網址、`⌘N` 新增視窗、`⌘T` 新增分頁；再次開啟 Claude Chrome 會在同一專用瀏覽器程序新增檢查頁視窗。

專用 profile 關閉 Google 瀏覽器登入、同步及網址列的 AI Mode 按鈕。Chrome 原生新增視窗及分頁指令會使用內建的新分頁頁面；環境檢查控制首頁的繼續按鈕，網址列可直接前往其他網站。可在 Chrome「設定 → 搜尋引擎」選擇 Google 或 DuckDuckGo；啟動器會保留這項選擇。

獨立 profile 位於 `~/Library/Application Support/Claude Chrome/Profile`；如已有舊 profile `~/.local/share/claude-network-guard/chrome-login-profile`，App 會沿用它。Profile 必須是權限 `0700` 的真實目錄，不能是 symlink。

啟動器把它設為離線瀏覽器 profile：關閉 Chrome 的 Google 登入偏好，並以 `--disable-sync` 啟動。通過檢查後仍可另行登入 Claude 網站，兩者互不相干。Chrome 使用：

- `--proxy-server=http://127.0.0.1:17897`；
- `--webrtc-ip-handling-policy=disable_non_proxied_udp`；
- `--lang=<出口主要 locale>`，profile 的 selected 與 accepted languages 會按出口國家設定；
- `--new-window <本機環境檢查頁>`。

啟動器使用 `curl -q`、明確指定 loopback 代理及空白 `--noproxy`，避免沿用代理繞過設定。它會向 ipwho.is 取得出口 IP、國家及 IANA 時區，再以 `TZ=<IANA timezone>` 啟動專用 Chrome process。這不會改變 macOS 時區或其他 Chrome profile。

同一次 App 存活期間，Claude Chrome 會保留自己啟動的 Chrome process、所用時區及語言。再次開啟只會重用仍在運行、屬於此 App，且受保護 flags、已記錄時區及語言均吻合的 process。正常結束 Claude Chrome 會關閉其專用 Chrome；如 App 異常結束，留下的 Chrome 會視為未受管理，必須完全結束該視窗後再開啟 Claude Chrome。

啟動器會用 macOS Foundation 與 ICU likely-subtags，按出口國家推導主要 locale。例如日本為 `ja-JP`、`ja`，美國為 `en-US`、`en`，台灣為 `zh-Hant-TW`、`zh-Hant`，新加坡為 `en-SG`、`en`；多語國家採系統 locale 資料的預設主要語言。出口國家或語言改變時必須冷啟動。

## 環境檢查

本機首頁所有必要檢查通過後，繼續按鈕才會開啟 `https://claude.ai`。按下繼續時會重新執行出口與信譽檢查；出口、快照或風險改變會清除之前的確認。

- **出口及地區：** Cloudflare Trace 及 ipwho.is 的最新結果必須有相同公網 IP 及國家，並符合 native 啟動評估。`Resources/SupportedRegions.js` 收錄 [Anthropic 支援國家頁](https://www.anthropic.com/supported-countries) 於 `2026-09-29` 的 185 個 Claude.ai 國家快照。出口位於烏克蘭時，Crimea、Donetsk、Kherson、Luhansk 或 Zaporizhzhia 分區會被排除；缺少分區資料則為未知。
- **時區及時鐘：** 出口時區與 UTC offset 必須同時符合主頁及 Blob Worker 即時回讀的 `Intl`／`Date` 結果。
- **IP 信譽：** native 評估會無 API key 查詢 ProxyCheck v3，並要求 `hosting`、`proxy`、`vpn`、`tor`、`compromised`、`scraper`、`anonymous` 七項風險布林值齊全。任何風險為 true 或分數高於 25，預設均未通過。只有完整、新鮮且符合當前出口的快照，並且僅 `hosting` 為 true、其餘各項明確為 false 時，才可勾選預設未勾、只在本頁有效的確認。接受機房 IP 與風險分數不會略過地區、出口一致性、WebRTC、時區、語言或瀏覽器基線檢查。資料未知及其他任一風險為 true 時不能確認；快照或風險改變會清除之前的確認。有效結果按相同出口 IP 儲存在專用 profile 的私人快取最多 30 分鐘，出口改變或快取過期時重新查詢。匿名服務限制為[每日 100 次查詢](https://proxycheck.io/api/)。
- **WebRTC：** Cloudflare STUN 觀察必須完成，並且沒有私人位址、未經代理的 UDP 位址或與 HTTPS 出口不同的公網位址。
- **語言及瀏覽器基線：** native 的出口語言及有序語言清單必須符合最新出口國家，並與 `navigator.language`／`navigator.languages` 一致；同時核對 `navigator.webdriver`、macOS Chrome user agent 與 platform、畫面及處理器資料、可重複的本機 Canvas 結果及 WebGL renderer。

這是本專案採用的保守 App 門檻，並非 Anthropic 官方規則、個別 IP 白名單、帳戶資格判斷或防封禁保證。上游回應無法取得、格式錯誤、互相矛盾、過期或超出限額時，結果會標為未知並保持鎖定。

### 私隱

Cloudflare Trace、ipwho.is 及 ProxyCheck 會收到檢查所需的出口 IP；Cloudflare STUN 服務可觀察 WebRTC 請求。瀏覽器指紋值及 Canvas 摘要只在本機評估，本 App 不會外送。Native 評估快照會放入本機 `file:` URL fragment，因此可留在此 profile 的本機瀏覽紀錄，亦會儲存在私人 profile 快取。

### 本機代理設定

預設代理是 `http://127.0.0.1:17897`。如需使用其他本機 HTTP 代理，建立 `~/Library/Application Support/Claude Chrome/config.json`，然後重新開啟 App：

```json
{
  "proxyURL": "http://127.0.0.1:7897"
}
```

`config.json` 只接受 `proxyURL`。網址必須是 `http` 或 `https`，主機為 `localhost`、`127.0.0.1` 或 `::1`，並明確包含連接埠。不支援帳號密碼、URL 路徑、PAC 或直連繞過設定，亦不需要 API key。

## 安全範圍

本 App 是 Chrome 私隱輔助工具，並非作業系統層級的網絡 kill switch。它不會修改 macOS 網絡設定，且只套用至經此啟動器開啟的 Chrome；使用前必須先啟動本機代理。

Claude Chrome 是獨立專案，與 Anthropic 或 Google 沒有從屬、認可或支援關係。

本專案以 MIT License 發布。
