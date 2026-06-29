---
linear_issue: null
---
# 錄音筆自動匯入 ＋ 智慧範本路由（Fork VoiceInk）

> 產品層 PRD，不含架構／資料表／API 細節（那些留給 `/prp-srs`）。

## Problem Statement

實體錄音筆使用者目前必須手動匯入檔案、逐一轉錄、手動判斷情境並挑選範本、再手動
另存成想要的格式。整個流程繁瑣且容易選錯範本，導致錄音累積不整理。

## Evidence

- 使用者原話：「插入錄音筆時自動讀取內容，依範本轉成我要的格式」「能辨別出這是會議，
  就自動採用會議的範本」— 直接描述了痛點與期望。
- 假設待驗證：目前每個情境各一套範本、需手動挑選 → 容易選錯／懶得整理（需以實際使用驗證）。

## Proposed Solution

Fork VoiceInk，新增兩個小元件並接進既有轉錄 pipeline：

1. **錄音筆自動匯入** — 偵測磁碟掛載，比對是否為已設定的錄音筆裝置，掃描裝置內指定
   資料夾的新音檔，丟進**現有的**檔案轉錄佇列自動轉錄。全程零點擊，以浮動通知回報進度。
2. **智慧範本路由** — 轉錄完成後用雲端 AI 先做一次內容分類（回傳使用者自訂類別之一，
   或「不確定」），據此自動選對應範本做 AI 改寫，最後依該類別的輸出資料夾把成品存成檔案。
   判不出來則套「通用範本」並存到通用資料夾。

「類別」即 VoiceInk 既有的 `CustomPrompt`，不另造平行系統；新增的只是一層薄路由
（分類→選範本）＋每類別的輸出資料夾對應。**結論：Fork 而非新建** — VoiceInk 已提供
約 80% 能力（檔案批次轉錄、多家本地／雲端引擎、範本＋AI 改寫、歷史 DB、選單列、通知）。

## Flagship Use Cases（v1 聚焦）

使用者明確的兩大主場景，v1 以這兩個情境的品質為優先驗收目標：

### A. 面試對談分析（Interview Analysis）
- **內容形態**：雙人對談（面試官 ↔ 受訪者／使用者本人），通常 20–60 分鐘。
- **想要的產出**：不只是逐字稿，而是**面試覆盤**——逐題拆解「被問了什麼 → 我怎麼答的 →
  答得好不好 → 更好的答法」、整體表現亮點與弱點、可追問清單、後續準備建議。
- **關鍵需求**：**講者區分**（誰是面試官、誰是我）對分析品質影響極大。VoiceInk 目前
  只有 VAD 語音分段、**無講者分離（diarization）**，這是本案需評估的能力缺口。
  - v1 退路：不做真 diarization，改在分類後的分析 prompt 中要求 AI 依語氣／問答結構
    推測發言者並標記（成本低、品質夠用即可），真 diarization 留待後續里程碑評估。

### B. 演講／座談會逐字稿（Talk / Panel Transcript）
- **內容形態**：單人演講或多人座談，通常 30–90 分鐘的長音檔。
- **想要的產出**：乾淨的**結構化逐字稿** + 重點摘要（主題段落、關鍵論點、名詞解釋、
  行動／待查清單、金句）。重逐字稿保真度，分析為輔。
- **關鍵需求**：長音檔轉錄（既有檔案佇列可處理）＋**長逐字稿的 AI 摘要**可能超出單次
  context window，需評估分段摘要（map-reduce）策略；細節留 SRS。

> 這兩個情境分別對應兩張 starter 範本（見 Core Capabilities Must 項），是 v1 出廠即附、
> 也是分類器要能可靠分辨的兩個主類別（外加「通用」fallback）。

## Key Hypothesis

我們相信「插入即自動轉錄＋自動辨別類別套範本＋自動匯出到 vault」能讓錄音筆使用者
**零手動整理**地把語音變成歸好檔的筆記。當使用者插入錄音筆後不做任何點擊，就在目標
資料夾得到分類正確、格式正確的檔案，且分類正確率足以信任（少需手動更正）時，即驗證成功。

## What We're NOT Building

- 不自製轉錄引擎 / 不做新 App — 沿用 VoiceInk 既有能力。
- 不做即時串流分類 — 分類在轉錄完成後一次性進行。
- 不做雲端同步 / 多機共享設定（v1）。
- 不做錄音筆韌體層整合 — 一律當成「插上的隨身碟＋音檔資料夾」處理。
- 不發明平行範本系統 — 類別直接綁既有 `CustomPrompt`。

## Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| 插入後零點擊完成率 | 100%（已設定的裝置） | 插入 → 目標資料夾出現檔案，無需任何點擊 |
| 分類正確率 | ≥ 80%（v1 目標，待校準） | 抽樣比對 AI 類別 vs 人工判斷 |
| 手動更正比例 | ≤ 20% | History 中被改類別的筆數 / 總筆數 |

## Open Questions

- [x] ~~分類正確率門檻？低於多少時改「先確認再套」？~~ **已決定（2026-06-29）：v1 一律全自動，
  分類錯誤事後在 History 用類別徽章手動更正；不做信心分數 gate（如實測正確率太低再追加）。**
- [ ] 面試分析是否需要真 diarization？v1 先用 prompt 推測發言者驗證品質，再決定是否投入。
- [ ] 長座談會逐字稿摘要的分段策略（map-reduce chunk 大小、是否保留全文＋摘要兩份）— 留 SRS。
- [ ] 去重判定鍵（檔名＋修改時間？內容雜湊？）— 細節留 SRS。
- [ ] 匯出檔名規則與檔內 metadata（日期、來源裝置、原始轉錄）格式 — 留 SRS。
- [ ] 多支錄音筆／同一支換不同資料夾的邊界情況 — v1 是否需處理。

---

## Users & Context

**Primary User**
- **Who**：擁有實體錄音筆、會錄會議／訪談／點子備忘，且用 Obsidian（或檔案資料夾）整理筆記的人。
- **Current behavior**：手動拖檔、手動轉錄、手動挑範本、手動另存。
- **Trigger**：把錄音筆插上電腦的那一刻。
- **Success state**：什麼都不點，目標資料夾就出現分類正確、格式正確的筆記檔。

**Job to Be Done**
當我把錄音筆插上電腦，我想要它自動把所有新錄音轉成對應格式的筆記並歸到正確資料夾，
這樣我就不必手動整理、也不會選錯範本。

**Non-Users**
- 純麥克風即時聽寫使用者（VoiceInk 現有功能已涵蓋）。
- 需要團隊共享 / 雲端協作的使用者（v1 不處理）。

---

## Solution Detail

### Core Capabilities (MoSCoW)

| 優先 | 能力 | 理由 |
|---|---|---|
| Must | 偵測錄音筆掛載並自動匯入新音檔到轉錄佇列 | 核心觸發點 |
| Must | 「Recorders」頁：每台裝置一張卡片，設定辨識、來源資料夾、自動化、匯出根目錄 | 使用者掌控與可重複辨識 |
| Must | 轉錄後雲端 AI 內容分類 → 自動選對應範本改寫 | 解決「自動辨別類別」核心訴求 |
| Must | 「Categories」頁：類別↔範本↔子資料夾映射，可增刪改 | 使用者自訂類別與範本 |
| Must | 通用範本 fallback（分類不確定時） | 確保永遠有可用結果 |
| Must | 出廠附「面試覆盤」與「演講／座談會」兩張 starter 範本 | v1 兩大旗艦用途即裝即用 |
| Must | 依類別子資料夾把成品匯出成檔案（vault 根 + 子資料夾） | 「轉入成我要的格式」最終交付 |
| Must | 已匯入檔案去重 | 全自動下必要的安全網 |
| Should | 插入／完成的浮動通知 | 全自動下的可見性 |
| Should | 佇列／歷史每筆顯示「類別徽章」，可手動更正分類 | 修正錯誤分類 |
| Should | 面試範本以 prompt 推測並標記發言者（面試官／我） | diarization 缺口的低成本退路 |
| Should | 長逐字稿分段摘要（map-reduce）以容納 90 分鐘座談 | 超出單次 context window 時仍可摘要 |
| Could | 真講者分離（diarization）標記每句發言者 | 提升面試分析品質，成本較高，後續評估 |
| Could | 匯入成功後自動從裝置刪除原檔（選項，預設關） | 釋放錄音筆空間 |
| Won't | 即時串流分類、雲端同步、新轉錄引擎 | 明確延後／不做 |

### MVP Scope

單台錄音筆 → 自動匯入 → 轉錄 → 雲端分類選範本（含 fallback）→ 匯出到 vault 子資料夾，
全程零點擊。類別與範本可在 Categories 頁增刪改。

### User Flow

1. 一次性設定：Recorders 頁新增裝置卡片（辨識當前已插入磁碟、選來源資料夾、選匯出根
   目錄＝Obsidian vault）；Categories 頁建立幾個類別並各綁範本與子資料夾名。
2. 日常：插入錄音筆 → 通知「匯入 N 個新檔」→ 自動轉錄 → 每筆自動分類套範本 →
   檔案出現在 vault 對應子資料夾 → 通知「完成」。
3. 需要時：在 History／佇列用類別徽章手動更正分類。

### UI 設計（沿用 VoiceInk 既有模式）

- **新側欄頁 Recorders**：每台裝置一張卡片（結構複製 PowerModeView）。卡片點開為右側
  400pt 滑出式 Form：辨識裝置（磁碟名稱比對、當前已插入自動帶入）／來源資料夾＋檔案類型
  ＋去重／自動化開關（插入即匯入、匯入後刪除預設關）／匯出根目錄（`NSOpenPanel` 選目錄，
  可指 Obsidian vault，security-scoped bookmark 持久化）。
- **新側欄頁 Categories**：清單式，每列＝類別，綁一個範本（用既有 `PromptEditorView`）＋
  一個子資料夾名。可新增／編輯／刪除；最底固定「通用（fallback）」不可刪。
- **匯出分層**：單一 vault 根（設在 Recorder 卡片）＋各類別子資料夾。換 vault 只改一處。

---

## Feasibility

**Verdict**: HIGH — VoiceInk 已具備檔案批次轉錄、範本＋雲端 AI 改寫、歷史 DB、選單列、通知；
僅需新增「磁碟掛載監看＋匯入」與「轉錄後分類路由」兩個小服務，並接進既有 pipeline 與既有
UI 模式。

> 架構、資料模型、security-scoped bookmark、分類 prompt 設計、去重鍵、匯出檔名規則等技術
> 細節屬 SRS。執行 `/prp-srs docs/prd/recorder-auto-import-and-template-routing.prd.md`。

---

## Product Milestones

| # | Milestone | User-Visible Value | Status | Depends | SRS | Plan |
|---|-----------|--------------------|--------|---------|-----|------|
| 1 | 錄音筆自動匯入 | 插入錄音筆即自動把新音檔轉錄（成品先進 VoiceInk 歷史） | pending | - | - | - |
| 2 | 智慧範本路由 | 每段轉錄自動辨別類別並套對應範本（判不出用通用範本） | pending | 1 | - | - |
| 3 | 依類別匯出到 vault | 成品自動存成檔案、歸到 vault 對應子資料夾 | pending | 2 | - | - |
| 4 | Categories / Recorders 管理 UI | 可自行新增／編輯／刪除類別、範本、裝置與匯出位置 | pending | 1,2,3 | - | - |

### Milestone Details

**Milestone 1：錄音筆自動匯入**
- **User can now**：插入錄音筆，新音檔零點擊自動匯入並轉錄。
- **Success signal**：插入後不點任何按鈕即產生轉錄；去重不重複處理。
- **Out of scope**：分類與匯出（後續里程碑）。

**Milestone 2：智慧範本路由**
- **User can now**：每段轉錄被自動歸類並套對應範本，判不出用通用範本。
- **Success signal**：分類正確率足以信任、手動更正比例低。
- **Out of scope**：檔案匯出格式（M3）。

**Milestone 3：依類別匯出到 vault**
- **User can now**：成品自動存成 Markdown/txt、歸到 vault 對應子資料夾。
- **Success signal**：目標資料夾出現格式與位置正確的檔案。
- **Out of scope**：完整管理 UI（M4）。

**Milestone 4：Categories / Recorders 管理 UI**
- **User can now**：自助新增／編輯／刪除類別、範本、裝置與匯出位置。
- **Success signal**：使用者無需改設定檔即可維護全部映射。
- **Out of scope**：多機同步。

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| 做法 | Fork VoiceInk | 從零新建工具 | 既有 80% 能力，僅需兩小元件 |
| 自動化 | 全自動 | 先確認再處理 | 使用者要「插入就好」 |
| 輸出 | 匯出檔案 | 只留 App 歷史 | 「轉入成我要的格式」需檔案 |
| AI | 雲端（Anthropic/OpenAI） | 本地 Ollama | 品質優先 |
| 類別模型 | 綁既有 CustomPrompt | 另造平行系統 | 重用範本與編輯器 |
| 匯出分層 | 單一 vault 根＋子資料夾 | 每類別絕對路徑 | 最適合 Obsidian、換 vault 只改一處 |
| Recorders UI | 每台裝置一張卡片 | 單一全域設定 | 多裝置／可重複辨識 |
| Categories UI | 獨立側欄頁 | 併進 Enhancement 頁 | 清楚、好找 |
| v1 聚焦用途 | 面試覆盤＋演講/座談會逐字稿 | 泛用會議紀錄 | 使用者主場景明確，先把這兩類做到可信任 |
| 分類門檻 | 全自動、事後更正 | 低信心先確認 | 使用者要「插入就好」，校正成本低於每次確認 |
| 講者區分 | v1 用 prompt 推測 | 真 diarization | VoiceInk 無 diarization，先低成本驗證品質再投入 |

---

## Research Summary

**Market Context**
同類需求多由「自動轉錄＋AI 整理」工具（如各家 meeting notes）處理，但多為雲端錄音 / 麥克風
情境，少有針對「實體錄音筆插入即匯入 + 內容自動分類套範本 + 匯出到本地 vault」的桌面流程。
本案的差異化在於本地檔案自動化與 Obsidian 友善的資料夾匯出。

**Technical Context（既有可重用）**
- 檔案批次轉錄：`AudioFileTranscriptionManager`、`SupportedMedia`、`AudioFileProcessor`。
- 範本＋AI 改寫：`CustomPrompt`、`AIEnhancementService`、`TranscriptionPipeline`。
- UI 模式：`NavigationSplitView` 側欄、Power Mode 卡片＋400pt 滑出面板、`PromptEditorView`、
  `PromptSelectionGrid`、`NotificationManager`、`AudioFileRow` 狀態徽章。
- **缺口（需新增）**：
  - 磁碟掛載監看（目前無 `didMountNotification`/FSEvents/`mountedVolumeURLs`，已 grep 確認）。
  - 內容分類路由（目前只有 spoken trigger words 與 app/URL Power Mode，無內容分類）。
  - **講者分離（diarization）**：`FluidAudioTranscriptionService` 只有 VAD 語音分段
    （`segmentSpeechAudio`），不標記發言者；面試分析的「誰說的」需另解（v1 prompt 推測）。
  - **長逐字稿摘要**：既有 AI 改寫是單次 prompt，90 分鐘座談逐字稿可能超 context window，
    需分段摘要策略。

---

*Generated: 2026-06-13*
*Calibrated: 2026-06-29 — 聚焦面試分析＋演講/座談會逐字稿；確定全自動分類；標記 diarization 與長逐字稿摘要缺口*
*Status: DRAFT - calibrated, ready for /prp-srs*
*Source Linear Issue: N/A — standalone*
