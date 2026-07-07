---
linear_issue: null
---
# Watch / iPhone 錄音自動匯入（iCloud 資料夾來源）

> 產品層 PRD，不含架構／資料表／API 細節（那些留給 `/prp-srs`）。

## Problem Statement

在外用 Apple Watch 或 iPhone 錄下的想法與對話，困在手機生態裡；必須 AirDrop 或手動搬檔才能進 Mac 的轉錄管線，結果多數隨身錄音從未被整理。既有管線只認 USB 錄音筆（磁碟掛載）與本機資料夾，不懂 iCloud 的同步語意。

## Evidence

- 使用者決策：Just Press Record 與 Apple Voice Memos 兩個來源都要做（2026-07-06）。
- 市場：錄音導向產品全數標配手錶入口——Voicenotes、Just Press Record、Whisper Memos、Oasis 都有 watch app；Whisper Memos 整個產品（$60/年）賣的幾乎就是「手錶錄音→自動轉錄送達」這條體驗。反觀聽寫類（Superwhisper、Wispr Flow）皆無手錶入口，是公認品類缺口——本 fork 用「現成 app 的 iCloud 資料夾」即可補上，零 iOS 工程。
- 既有事實：管線已有資料夾來源、內容指紋去重、錄音時間回填；缺的只是 iCloud 語意（遞迴子資料夾、未下載佔位檔）。

## Proposed Solution

「錄音裝置」頁新增**來源預設集**：Just Press Record（自動定位其 iCloud Drive 資料夾）、Apple Voice Memos（同步資料夾）、自訂 iCloud 資料夾。系統處理遞迴子資料夾掃描、iCloud 未下載佔位檔（先觸發下載、完成後再匯入）、既有去重；iCloud 來源**一律強制不刪原始檔**。匯入後與既有管線完全相同：轉錄 → 分類 → 範本 → Obsidian。

為何是這個做法：用現成 app（JPR $4.99 有離線 watch app；Voice Memos 免費內建）的同步資料夾當入口，把「做 watch app」這種月級工程換成「教管線懂 iCloud」的天級工程。

## Key Hypothesis

我們相信「iCloud 資料夾來源預設集」能讓手錶／手機錄音在回到 Mac 後零操作自動出現在 Obsidian 對應分類。
當一週的隨身錄音 100% 自動進庫、零手動搬檔、零重複匯入時，即驗證成功。

## What We're NOT Building

- **自製 iOS / watchOS app** — 用現成 app 的 iCloud 資料夾，避開整個行動端工程與上架問題。
- **反向同步／回寫手機** — 只讀來源，Mac 端是消費者。
- **即時性保證** — 依 iCloud 同步節奏（分鐘級），不做推播式即時管道。

## Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| 隨身錄音自動進庫率 | 100%，零手動搬檔 | 對照手機端錄音數與匯入筆數 |
| 錄音可見 → 筆記產出延遲 | Mac 喚醒且同步完成後 ≤5 分鐘 | 抽查時間戳 |
| 重複匯入 | 0 筆 | 去重機制驗證（重開機／重掃描後仍不重複） |

## Open Questions

- [ ] Voice Memos 同步資料夾的讀取權限（是否需「完整磁碟取用」）與路徑穩定性 → SRS 實測
- [ ] Voice Memos 是否需 Mac 端 app 開啟過／登入 iCloud 才會把檔案同步下來 → 實測
- [ ] 長錄音大檔的 iCloud 下載策略：全自動下載 or 設大小上限
- [ ] JPR 日期資料夾／檔名的錄音時間解析，與既有錄音時間回填機制的銜接

---

## Users & Context

**Primary User**
- **Who**: 使用者本人——走路／通勤時用手錶或 iPhone 隨手錄想法，回家在 Mac + Obsidian 整理。
- **Current behavior**: 錄了不整理，或偶爾 AirDrop 幾個檔案手動丟進管線。
- **Trigger**: 在外隨手錄了一段語音。
- **Success state**: 回到 Mac，什麼都不做，筆記已經在 Obsidian 裡。

**Job to Be Done**
當我在外面用手錶錄下想法時，我想要回到 Mac 後它自動變成歸好類的筆記，這樣隨身錄音不再堆積失蹤。

**Non-Users**
需要分鐘級即時同步的場景；不用 Apple 生態錄音的使用者。

---

## Solution Detail

### Core Capabilities (MoSCoW)

| Priority | Capability | Rationale |
|----------|------------|-----------|
| Must | Just Press Record 預設集：自動定位資料夾＋遞迴掃描＋佔位檔下載＋去重匯入 | 路徑最乾淨穩定的第一條路 |
| Must | Apple Voice Memos 預設集（含權限引導 UI） | 免費、免裝 app 的內建路徑 |
| Must | iCloud 來源強制不刪原始檔；同步／下載中狀態可見 | 保護使用者手機上的原始資料；可觀察性 |
| Should | 自訂 iCloud 資料夾來源（通用化） | 涵蓋其他任何寫 iCloud 的錄音 app |
| Could | 每來源預設分類（如手錶語音 → 獨白記錄） | 省一次分類呼叫、更可控 |
| Won't | 自製 watch app、雙向同步 | 見 NOT Building |

### MVP Scope

JPR 預設集先行（Milestone 1）——路徑與檔案結構最可控，先驗證整條 iCloud 匯入鏈；Voice Memos 隨後（權限與同步行為需實測）。

### User Flow

設定頁點「新增來源 → Just Press Record」→ 自動找到資料夾並顯示現有檔案數 → 開啟自動匯入 → 出門用手錶錄音 → 回 Mac 喚醒後自動下載、匯入 → Obsidian 出現筆記。

---

## Feasibility

**Verdict**: HIGH — app 非 sandbox 可直讀 iCloud 路徑；資料夾來源機制既存，補遞迴掃描與佔位檔下載即可。唯 Voice Memos 資料夾權限為 MEDIUM 風險點，需實測。

> Architecture, data model, API contracts, technology choices, and detailed technical risks belong in the SRS. Run `/prp-srs docs/prd/icloud-recorder-sources.prd.md` to produce that next.

---

## Product Milestones

| # | Milestone | User-Visible Value | Status | Depends | SRS | Plan |
|---|-----------|--------------------|--------|---------|-----|------|
| 1 | JPR 手錶錄音自動進庫 | 手錶錄的音回 Mac 自動變 Obsidian 筆記 | pending | - | - | - |
| 2 | Voice Memos 來源 | 不買 app，用內建語音備忘錄也走同一條管線 | pending | 1 | - | - |

### Milestone Details

**Milestone 1: JPR 手錶錄音自動進庫**
- **User can now**: 用 Just Press Record 在手錶離線錄音，回 Mac 後零操作得到分類好的筆記。
- **Success signal**: 一週隨身錄音 100% 自動進庫、零重複。
- **Out of scope for this milestone**: Voice Memos、每來源預設分類。

**Milestone 2: Voice Memos 來源**
- **User can now**: 用 iPhone／Watch 內建語音備忘錄錄音，同樣自動進庫。
- **Success signal**: 權限引導一次完成後持續穩定匯入。
- **Out of scope for this milestone**: 自訂 iCloud 資料夾之外的來源型態。

> Note: Technical phases and parallelism live in the **SRS**. Implementation tasks live in the **Plan**. This PRD only captures product value sequencing.

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| 入口策略 | 現成 app 的 iCloud 資料夾 | 自製 iOS/watchOS app | 零行動端工程；天級 vs 月級成本 |
| 來源範圍 | JPR＋Voice Memos 都做，JPR 先行 | 擇一 | 使用者拍板；JPR 路徑穩、VM 免費各有價值 |
| 原始檔處理 | iCloud 來源強制不刪 | 沿用「匯入後刪除」選項 | 絕不能動使用者手機上的原始錄音 |

---

## Research Summary

**Market Context**
手錶入口在錄音類產品是標配、在聽寫類是缺口（Superwhisper／Wispr Flow 皆無）；Whisper Memos 以 $60/年 販售「手錶→轉錄→送達」單一體驗、Just Press Record $4.99 買斷含 watch app 與 iCloud 同步——證明此工作流有真實需求，且本 fork 能以零行動端成本取得。（市場調查：2026-07-06 本 session）

**Technical Context**
2026-07-06 架構討論確認：既有資料夾監看為單層、不懂 iCloud 佔位檔——需求已界定為「遞迴＋同步感知＋下載後匯入」；去重與錄音時間回填機制可直接重用。

---

*Generated: 2026-07-06*
*Status: DRAFT - needs validation*
*Source Linear Issue: N/A — standalone*
