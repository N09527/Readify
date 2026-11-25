# Readify for iOS / iPadOS（Universal 原生版）

專為 **iPhone 與 iPad（iOS / iPadOS 16.0+）** 改寫的原生 Swift + SwiftUI + CoreGraphics 全格式電子書與漫畫閱讀器，具備與 Android 版完全互通的雙向雲端同步與全部閱讀管理功能。

## 功能總覽
- **全格式閱讀支援**：
  - **文字書**：TXT（自動辨識 UTF-8 / UTF-16 / Big5 / GB18030 與自動分章）、EPUB、Kindle MOBI / AZW3（無 DRM，含複合 KF8、PalmDOC LZ77、HUFF/CDIC、EXTH 201/202 與 CRES 封面自動擷取）。
  - **漫畫與視覺書**：漫畫型 EPUB、CBZ / ZIP、CBR（支援 RAR4 / RAR5）、漫畫型 MOBI / AZW3，支援日漫右翻左、單頁／iPad 橫直屏左右雙頁＋書脊陰影、雙指縮放與雙擊放大。
  - **PDF（原生 PDFKit）**：原版面高解析繪製、自動裁切白邊、夜間深色反白，以及一鍵切換文字重排模式。
- **繁中直橫排與仿真翻頁引擎**：
  - 直排／橫排一鍵切換（含繁中直排標點轉換與行頭禁則），橫直書皆支援「左右雙頁」＋中間仿真接縫陰影。
  - 自動掃描「檔案 App → 我的 iPhone/iPad → Readify → Fonts」資料夾並解析 OpenType `name` 表顯示字體真實繁中名稱，支援字體加粗（含自訂字體合成粗體）。
  - 字體大小、字距、行距、段落距、上下左右邊界皆支援拉桿與直接輸入數值，並支援段首縮排（0～4 字）。
  - 60/120fps ProMotion 貝茲曲線仿真捲頁動畫、左右滑動、電子紙（E-ink）無動畫高對比模式、九宮格自訂點擊區域、音量鍵翻頁、iPad 鍵盤／藍牙翻頁器方向鍵支援、OpenCC 台灣繁簡一鍵轉換、目錄、書籤與全書搜尋。
- **書架管理與雙指書封縮放**：
  - 狀態分類（**全部、未讀、閱讀中、已讀**）＋多標籤 `#Tag` 篩選＋書名／作者搜尋＋排序。
  - **五段書封大小與雙指分段縮放**：提供「緊湊／標準／中／大／特大」五段書封尺寸選單，並支援於書架直接雙指張開／捏合切換檔位，解決 iPad Pro 大螢幕書封過小的問題。
  - 支援單本／批次多選設為已讀、未讀、批次標籤與刪除；支援單檔、多檔、整個資料夾遞迴匯入，以及透過「檔案」App / AirDrop / Mac Finder 檔案共享直接匯入。
  - **沙盒路徑抗重簽設計**：側載續簽或重裝（保留資料）導致 iOS App Container UUID 變更時，書架、封面與自訂字體路徑皆可自動對應不遺失。
- **跨平台雙向雲端同步（與 Android 版 100% 互通）**：
  - 支援 **WebDAV**、**Google Drive** 與 **Microsoft OneDrive**，透過快速檔案指紋自動比對相同書籍，雙向同步閱讀進度、多標籤、書籤（含刪除紀錄）、閱讀排版設定與電子書／漫畫書檔本體。

---

## 安裝方式（免付費 Apple Developer 帳號）

### 方法一：從 GitHub Actions 下載 `Readify-unsigned.ipa` 側載安裝（推薦）
每次推送至 `ios` 分支（或手動觸發 Actions），`.github/workflows/build-ios.yml` 會自動在雲端 macOS（Xcode 16+）編譯並產出未簽名的 `Readify-unsigned.ipa`：

> **提示（Private Repo 注意事項）**：由於目前 `N09527/Readify` 為 **Private（私有）** 倉庫，GitHub Free 帳號在私有倉庫執行 `macos-latest` 會消耗 10 倍免費額度（若帳號未開啟 Actions 額度或佇列繁忙會停留在 `Queued`）。若遇到長時間排隊，你可以：
> - 直接在你的 Mac 執行一行 `./ios/scripts/build_unsigned_ipa.sh` 本機產出完全相同的 `Readify-unsigned.ipa`（需 Xcode 16+），或
> - 暫時將 Repo 設為 Public（公開倉庫享有無限免費 macOS Actions 額度）。

1. 前往 GitHub Repo 的 **Actions → Build iOS Unsigned IPA**，點選最新一次成功的執行紀錄，在最下方 **Artifacts** 下載 `Readify-unsigned-ipa.zip` 並解壓縮取得 `Readify-unsigned.ipa`。
2. 使用你的**免費 Apple ID** 搭配以下任一工具簽名安裝至 iPhone / iPad：
   - **Sideloadly**（Mac / Windows 最簡單）：開啟 Sideloadly，插線連接 iPhone/iPad，拖入 `Readify-unsigned.ipa`，輸入免費 Apple ID 後點 **Start** 即可安裝。
   - **SideStore / AltStore**（支援在手機／iPad 上每 7 天自動無線續簽，不必一直插電腦）：將 `Readify-unsigned.ipa` 傳到 iPhone/iPad 的「檔案」App，在 SideStore / AltStore 內點 `+` 選擇該 `.ipa` 安裝。
   - 首次安裝後，請至 iOS/iPadOS **設定 → 一般 → VPN 與裝置管理** 信任你的 Apple ID 開發者憑證；若為 iOS 16+，請至 **設定 → 隱私權與安全性 → 開發者模式** 開啟開發者模式。

### 方法二：使用你手邊的 Mac + Xcode 直接編譯安裝到 iPhone / iPad
因為你有 Mac 與 Xcode，也可以直接用免費 Apple ID（Personal Team）連線安裝：

1. 在 Mac 終端機安裝 `xcodegen` 並產生 Xcode 專案：
   ```bash
   brew install xcodegen
   cd ios
   xcodegen generate
   open Readify.xcodeproj
   ```
2. 在 Xcode 左側點選 `Readify` 專案 → **TARGETS (`Readify`) → Signing & Capabilities**：
   - 勾選 **Automatically manage signing**。
   - **Team** 選擇你的免費 Apple ID（若尚未登入，點 `Add Account...` 登入一般 Apple ID 即可，不需付費）。
   - **Bundle Identifier** 改為獨一無二的名稱（免費帳號規定全網不可重複，例如改為 `com.inkflow.reader.你的英文名`）。
3. 將 iPhone 或 iPad 接上 Mac，上方裝置清單選擇你的裝置，按 `Cmd + R`（或左上角 `▶`）即可直接編譯並安裝到實機。

> 若想在自己的 Mac 產出未簽名 `.ipa` 給 SideStore / Sideloadly 使用，也可直接執行：
> ```bash
> ./ios/scripts/build_unsigned_ipa.sh
> ```
