# Readify（v11 · 1.0.0-readify）

專為 Android 13～16（API 33–36）設計的原生 Kotlin + Jetpack Compose + 自訂 Canvas 全格式電子書與漫畫閱讀器。

## 功能總覽
- **全格式閱讀支援**：
  - **文字書**：TXT（自動辨識 UTF-8 / UTF-16 / Big5 / GB18030 與分章）、EPUB、Kindle MOBI / AZW3（無 DRM，含複合 KF8、EXTH 201/202 與 CRES 封面自動擷取）。
  - **漫畫與視覺書**：漫畫型 EPUB、CBZ / ZIP / CBR（支援 RAR4 / RAR5）、漫畫型 MOBI / AZW3，支援日漫右翻左、單頁／左右雙頁＋書脊陰影、雙指縮放與雙擊放大。
  - **PDF**：原版面高解析繪製、自動裁切白邊、夜間反白，以及一鍵切換文字重排模式。
- **繁中直橫排與雙頁引擎**：
  - 直排／橫排一鍵切換，橫直書皆為「左右雙頁」＋中間仿真接縫陰影。
  - 自動掃描本機 `/Fonts` 資料夾並顯示字體真實名稱、支援字體加粗。
  - 字體大小、字距、行距、段落距、上下左右邊界皆支援拉桿與直接輸入數值，並支援段首縮排（0～4 字）。
  - 無縫貝茲曲線仿真捲頁動畫、左右滑動、電子紙（E-ink）無動畫高對比模式、九宮格自訂點擊區域、音量鍵翻頁、簡繁一鍵轉換、目錄、書籤與全書搜尋。
- **書架管理**：
  - 初始狀態分類：**全部、未讀、閱讀中、已讀**，並支援自訂分組。
  - 書封右下角即時顯示已讀圖示或閱讀進度百分比（未達 99%）；書名下方顯示作者。
  - 支援單本／批次多選設為已讀、未讀、分組與刪除；支援多檔與整個資料夾遞迴匯入。
- **三大雲端雙向同步**：WebDAV、Google Drive（OAuth 2.0 PKCE）、Microsoft OneDrive（Graph API v1.0），雙向合併書檔、進度、已讀狀態、書籤與閱讀設定。

## 在 Android Studio 編譯 APK
1. 關閉舊專案，解壓縮此資料夾後以 Android Studio **File -> Open** 開啟 `Readify`。
2. 等待 Gradle Sync 完成。
3. 點選 **Build -> Build Bundle(s) / APK(s) -> Build APK(s)** 產生 `app-debug.apk` 直接覆蓋安裝即可（套件識別碼維持 `com.inkflow.reader` 以保留既有的本機書架資料與 OAuth 設定）。
