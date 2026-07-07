---
linear_issue: null
---
# 會議模式：免 bot 線上會議錄製 → Obsidian 筆記

> 產品層 PRD，不含架構／資料表／API 細節（那些留給 `/prp-srs`）。

## Problem Statement

使用者線上會議頻繁，但會議內容完全在自動化管線之外——既有 Recorder → Obsidian 管線只服務實體錄音筆與本機資料夾。會後要嘛另外手動錄音再手動整理，要嘛根本不留紀錄，決議與待辦隨會議結束而流失。

## Evidence

- 使用者自述：線上會議頻繁，此功能為六功能擴充包中最高優先（2026-07-06 規劃對談）。
- 市場驗證「免 bot 會議捕捉」是被付費證明的能力：Granola（$14/月）整個產品就是「不進會議的 notetaker」；Fathom 免費版以「AI 摘要每月 5 篇」逼升級；MacWhisper 把系統音訊錄製鎖在 Pro（€59 買斷）。
- 反面證據：bot 型產品（Otter 等）被廣泛抱怨——bot 出現在與會者名單造成觀感問題、多人會議講者誤判約 30%。bot-free 是市場明確偏好的方向。

## Proposed Solution

一鍵（選單列或全域快捷鍵）開始會議錄製：把系統音訊（對方聲音）與麥克風（自己聲音）混錄成單一音檔；停止後自動送入**既有的** Recorder 管線——去重 → 轉錄 → 講者分離 → 分類（預設固定歸入「會議」，可切自動分類）→ 會議範本分析 → Obsidian 匯出。錄製中在 mini/notch recorder 顯示紅點與計時。

為何是這個做法：管線後段（含 ElevenLabs 講者分離，本就支援多講者）100% 重用，新工程只有「音源擷取」一段；不做 bot、不接任何會議平台 API，因此 Zoom / Meet / Teams / Discord／任何放得出聲音的軟體一律通用。

## Key Hypothesis

我們相信「一鍵錄會議＋自動產出分類正確的會議筆記」能讓線上會議零手動留下可檢索紀錄。
當每場想留存的會議都實際走管線、會後手動整理時間為零、且筆記中講者／決議／待辦的品質足以事後查用時，即驗證成功。

## What We're NOT Building

- **即時字幕／即時摘要 HUD** — 先把錄後處理跑順；串流即時化另案評估。
- **會議 bot、行事曆與會議平台整合** — bot-free 與平台無關是本功能的定位。
- **自動開始錄製** — v1 手動啟停；「偵測到會議提醒開錄」屬 Should，自動開錄有誤錄疑慮。
- **雙聲道分離錄音（我方=左、對方=右）** — v1 混單聲道交給講者分離處理；實測不足再議。

## Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| 每週經管線產出筆記的會議數 | ≥3 場（貼近實際會議量，代表真的在用） | 歷史頁中來源=會議的筆數 |
| 會後手動整理時間 | 0 分鐘 | 自評：按停止後不需任何操作即得筆記 |
| 講者可辨識度 | 筆記能分清「誰說的」 | 抽查講者分離段落與手動改名頻率 |

## Open Questions

- [ ] 混音單聲道 vs 雙聲道對講者分離品質的實際影響 → SRS 實測決定
- [ ] 超長會議（>2 小時）的檔案大小與分塊行為 → SRS 實測
- [ ] 系統音訊擷取的 TCC 授權提示流程在 macOS 26 的實際行為 → SRS 驗證
- [ ] 耳機 vs 喇叭情境的回音／雙來源音量平衡是否需要增益設定

---

## Users & Context

**Primary User**
- **Who**: 使用者本人——重度線上會議者、Obsidian 知識庫使用者、本 fork 維護者。
- **Current behavior**: 會議內容不錄或另外手動處理；會後憑記憶補記，常漏。
- **Trigger**: 一場需要留下紀錄的線上會議即將開始。
- **Success state**: 會議結束按停止，幾分鐘後 Obsidian 會議資料夾出現有講者、有結構的筆記。

**Job to Be Done**
當我要開線上會議時，我想要一鍵開始錄製並在會後自動得到有講者、有結構的筆記，這樣我不必邊開會邊記錄，也不怕漏掉決議與待辦。

**Non-Users**
團隊協作／共享場景（本 fork 為個人自用）；需要即時字幕輔助的使用者（v1 不含）。

---

## Solution Detail

### Core Capabilities (MoSCoW)

| Priority | Capability | Rationale |
|----------|------------|-----------|
| Must | 選單列＋全域快捷鍵啟停；系統音訊＋麥克風混錄 | 功能核心，缺一即不可用 |
| Must | 錄畢自動走既有管線出 Obsidian 筆記（預設「會議」分類） | 「零手動」假設的載體 |
| Must | 錄製中狀態顯示（紅點＋計時），雙音源正常混合 | 錄了沒、還在錄，必須一目瞭然 |
| Should | 偵測會議 app 於前景＋麥克風使用中 → 通知提醒開錄 | 防忘錄，價值高但非阻斷 |
| Should | 固定分類 vs 自動分類的設定開關 | 確定性與彈性兼顧 |
| Could | 會議 app 名稱／起訖時間寫入筆記 metadata | 錦上添花 |
| Won't | 即時字幕 HUD、bot、行事曆整合 | 見 NOT Building |

### MVP Scope

Must 三項：手動一鍵混錄 → 自動出會議筆記。Should/Could 全部可後補。

### User Flow

會議開始前按快捷鍵（或點選單列）→ 正常開會 → 結束按停止 → 通知「已匯入，處理中」→ 幾分鐘後 Obsidian 出現會議筆記；歷史頁可查完整逐字稿與講者段落。

---

## Feasibility

**Verdict**: HIGH — app 非 sandbox、音訊/螢幕擷取 entitlements 已具備，混錄完成後全走既有管線；需補一項系統音訊用途聲明與 TCC 授權。

> Architecture, data model, API contracts, technology choices, and detailed technical risks belong in the SRS. Run `/prp-srs docs/prd/meeting-capture-to-obsidian.prd.md` to produce that next.

---

## Product Milestones

| # | Milestone | User-Visible Value | Status | Depends | SRS | Plan |
|---|-----------|--------------------|--------|---------|-----|------|
| 1 | 一鍵錄會議出筆記 | 手動啟停混錄；會後零手動得到分類正確的 Obsidian 會議筆記 | complete (build 227) | - | docs/srs/completed/recorder-automation-meeting-capture.srs.md | docs/plans/completed/recorder-automation-meeting-capture.plan.md |
| 2 | 提醒與品質打磨 | 會議 app 偵測提醒開錄；音量平衡／裝置切換情境穩定 | pending | 1 | - | - |

### Milestone Details

**Milestone 1: 一鍵錄會議出筆記**
- **User can now**: 按一個鍵錄下整場線上會議（雙方聲音），會後自動在 Obsidian 得到會議筆記。
- **Success signal**: 連續一週的實際會議都走管線且筆記可用。
- **Out of scope for this milestone**: 提醒通知、metadata、增益調整。

**Milestone 2: 提醒與品質打磨**
- **User can now**: 忘記開錄時收到提醒；耳機/喇叭/切裝置情境下錄音品質穩定。
- **Success signal**: 一個月內零「忘了錄」與零「錄壞」事件。
- **Out of scope for this milestone**: 即時字幕、行事曆整合。

> Note: Technical phases and parallelism live in the **SRS**. Implementation tasks live in the **Plan**. This PRD only captures product value sequencing.

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| 免 bot 系統音訊擷取 | 採用 | 會議 bot／平台 API | 市場偏好明確；通用所有會議軟體；無帳號綁定 |
| 混音方式 | v1 單聲道混音 | 雙聲道我方/對方分離 | 先信任既有講者分離能力，降低複雜度；實測不足再議 |
| 分類方式 | 預設固定「會議」＋可切自動 | 全自動分類 | 確定性高、省一次分類呼叫 |
| 啟停方式 | v1 手動＋提醒通知（Should） | 自動偵測開錄 | 誤錄風險與複雜度不值得 v1 承擔 |

---

## Research Summary

**Market Context**
免 bot 會議捕捉是 2025–26 會議工具的主流敘事與付費核心：Granola（$14/月，免費版史料受限）、Fathom（免費 5 摘要/月）、Krisp（免費 2 筆記/天）、MacWhisper（系統音訊錄製鎖 Pro €59）。原始逐字稿已商品化，各家收費收在 AI 加工層與工作流——本功能把這層價值以零訂閱、本地管線的形式補進 fork。（市場調查：2026-07-06 本 session，~40 產品定價掃描）

**Technical Context**
整合點已於 2026-07-06 架構討論確認：系統音訊擷取（macOS 14.2+ 之系統 API）為唯一新音源工程；後段轉錄／講者分離／分類／範本／匯出全數重用既有 Recorder 管線；entitlements 既備，需補系統音訊用途聲明。

---

*Generated: 2026-07-06*
*Status: DRAFT - needs validation*
*Source Linear Issue: N/A — standalone*
