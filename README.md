# PiP 翻譯（iOS 私人用）

把螢幕上**自己框選的範圍**裡的英文／日文，即時翻成**繁體中文**，顯示在子母畫面（PiP）浮動視窗裡。
不上架 App Store、不需要 Mac、不需要付費開發者帳號。

## 運作方式

```
[螢幕廣播擴充]  ReplayKit 擷取整個螢幕
      │  只裁切你框的範圍 → Vision OCR（英/日）
      ▼  127.0.0.1 本機連線
[主程式]  翻譯（Apple 離線 或 Google 線上）
      ▼
[子母畫面]  顯示繁中翻譯（可拖到螢幕任何位置、可縮放）
```

## 一、在 GitHub 上編譯（只要瀏覽器）

1. 打開此 repo 的 **Actions** → 左邊選 **Build PiPTranslator IPA** → **Run workflow**。
   （可改 Bundle ID，例如 `tw.你的名字.pipxlate`，避免和別人重複）
2. 約 3～5 分鐘後，點進該次執行，最下方 **Artifacts** 下載 `PiPTranslator-ipa`（zip，解開得到 `PiPTranslator.ipa`）。

> 每次 push 到 `PiPTranslator/` 也會自動重新編譯。

## 二、在 Windows 11 安裝到 iPhone（Sideloadly）

1. 安裝 **iTunes**（Apple 官網版，非 Microsoft Store 版較穩）與 **Sideloadly**。
2. iPhone 用 USB 接電腦，信任此電腦。
3. 把 `PiPTranslator.ipa` 拖進 Sideloadly，輸入你的 Apple ID（建議用小帳），按 Start。
4. iPhone：**設定 → 一般 → VPN 與裝置管理** → 信任你的 Apple ID。
5. iOS 16 以上需開 **設定 → 隱私權與安全性 → 開發者模式**（重開機後確認）。

**免費 Apple ID 的限制**
- 7 天後簽章過期，要再用 Sideloadly 重簽一次（資料會保留）。Sideloadly 可開啟自動更新簽章（電腦需開著、同網路）。
- 本 App 含 1 個擴充，會佔用 2 個 App ID（免費帳號每 7 天最多 10 個）。

## 三、使用步驟

1. 開啟「PiP翻譯」。第一次可按 **下載 Apple 離線語言包**（英→繁中、日→繁中）。
2. 按 **螢幕廣播按鈕** → 選「PiP翻譯」→ 開始直播。狀態變成「● 廣播中，已連線」。
3. 按 **開啟子母畫面**（或直接回主畫面，會自動縮成子母畫面）。
4. 切到你要翻譯的 App（遊戲、影片、網頁…），等 1～2 秒，**再切回 PiP翻譯**：
   會看到剛才那個畫面的截圖，**拖拉黃色框**決定翻譯範圍（拖角落改大小、拖框內移動、框外拖重新畫）。
5. 再切回目標 App，子母畫面就會持續顯示框內文字的繁中翻譯。
6. 把子母畫面拖到**不會蓋住翻譯範圍**的地方；可捏合縮放，也可推到螢幕邊緣暫時藏起來。

結束：點螢幕左上角紅色錄影指示 → 停止。

## 設定說明

| 項目 | 說明 |
|---|---|
| 來源語言 | 自動判斷，或固定英文／日文（固定較準） |
| 翻譯引擎 | **自動**：先用 Apple 離線翻譯，失敗（常見於 App 在背景時）改用 Google<br>**Apple 離線**：不上網、隱私最好，但背景時有可能無法使用<br>**Google 線上**：最穩，但文字會送到 Google |
| 辨識間隔 | 越短越即時、越耗電。字幕建議 0.5～0.8 秒 |
| 字級／原文／深色／比例 | 子母畫面外觀，字太多會自動縮小 |

## 已知限制

- 這不是 iOS 的「疊加層」——iOS 不允許第三方 App 在別的 App 上畫透明框，所以範圍是在截圖上框選，子母畫面是不透明的獨立視窗。
- 只支援**橫書**；漫畫的直書日文 Vision 辨識效果差。
- 有些 App（Netflix 等 DRM 影片）在螢幕錄影時畫面會是黑的，無法辨識。
- 廣播擴充記憶體上限約 50MB，所以範圍太大＋間隔太短時，系統可能中止廣播；縮小範圍或拉長間隔即可。
- 轉向（直/橫）後範圍是依「畫面比例」換算，轉向後建議重新框一次。
- 需要 iOS 18 以上（Apple Translation 框架）。

## 專案結構

```
PiPTranslator/
├─ project.yml                 XcodeGen 專案設定（CI 上自動產生 .xcodeproj）
├─ App/                        主程式（SwiftUI）
│  ├─ AppModel.swift           狀態、收 OCR、送設定
│  ├─ LinkServer.swift         本機 TCP 伺服器
│  ├─ Translator.swift         Apple / Google 翻譯
│  ├─ PiPManager.swift         子母畫面（AVSampleBufferDisplayLayer）
│  ├─ RegionSelector.swift     拖拉選範圍
│  └─ ContentView.swift        主畫面
├─ BroadcastExtension/
│  └─ SampleHandler.swift      螢幕擷取 + OCR
└─ Shared/Link.swift           兩邊共用的通訊格式
```
