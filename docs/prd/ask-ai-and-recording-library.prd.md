---
linear_issue: null
---
# Ask AI 跨庫問答 ＋ 錄音庫管理強化

> 產品層 PRD，不含架構／資料表／API 細節（那些留給 `/prp-srs`）。

## Problem Statement

錄音與聽寫歷史目前只有線性列表＋關鍵字搜尋；「上次那場會議誰承諾了什麼」「上個月講過的那個想法」找不回來。隨著會議模式與 Watch 匯入上線，庫存將快速走向千筆量級，而 Recording Management 現況偏「處理紀錄（log）」視圖——量大時既無法有效瀏覽，也缺批次管理手段。

## Evidence

- 使用者原話：「如果要做 ask ai，那錄音管理的頁面要做得更完整，讓未來錄音數量越來越多時能方便管理瀏覽」（2026-07-06）——明確把管理頁強化綁定為 Ask AI 的前置條件。
- 市場：**chat-with-notes 是全品類最一致的付費牆**——Voicenotes「Ask AI」（Pro $9/月）、Plaud「AskPlaud」（Pro+ 專屬）、Otter 免費版終身只給 20 次 AI 提問。歷史保留與管理則是會議 SaaS 的第一道免費版限制（Granola 免費史料受限、Otter 300 分/月）。兩者共同證明「量大的語音庫需要檢索與管理」有真實付費意願。
- 前置事實：會議模式（每週 3+ 場）＋隨身錄音匯入將使資料量級數成長，現有列表式瀏覽必然失效。

## Proposed Solution

兩件事一包、管理頁先行：

1. **錄音庫管理**——Recording Management 從 log 升級為「庫」：全欄位篩選（分類／來源／日期／講者／星標／處理狀態）、排序、批次操作（重新分類、重新匯出、刪除、星標）、在千筆量級依然流暢的清單。
2. **Ask AI**——新問答頁：自然語言跨庫提問（雲端 embedding 檢索＋既有 LLM 供應商），回答附**可點擊引用**跳回原始逐字稿；可按來源／分類／日期界定提問範圍；新轉錄自動入索引、舊資料一次性回填。

管理頁先做的理由：它同時是 Ask AI 引用跳轉的落點頁，且瀏覽之痛在資料成長後立即出現，不必等問答功能。

## Key Hypothesis

我們相信「秒級可答的跨庫問答＋撐得住量的管理介面」能讓語音庫在千筆量級仍然可用。
當找一筆舊內容 <30 秒、問答 <10 秒給出含正確引用的回答、管理頁千筆操作不卡時，即驗證成功。

## What We're NOT Building

- **本地 embedding／離線問答** — 使用者明示隱私不設限；用雲端換品質與省事。
- **跨裝置同步／行動端問答** — 本 fork 是 Mac 單機工具。
- **自動摘要排程** — 摘要已由分類範本層負責，不重複造輪。
- **筆記編輯器** — Obsidian 是編輯與沉澱的家，本 app 只管找到與跳轉。

## Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| 問答延遲 | <10 秒（檢索＋生成） | 實測計時 |
| 引用正確性 | 引用可點且指向正確來源段落 ≥90% | 抽查 20 題 |
| 管理頁流暢度 | 1,000+ 筆下篩選／捲動響應 <100ms | 實測 |
| 找回舊內容時間 | <30 秒（任務式自評） | 指定目標測試 |

## Open Questions

- [ ] Embedding 供應商與模型選擇（Gemini／OpenAI，依現有 key 與單價）→ SRS
- [ ] 既有歷史回填索引的批次策略、費用估算與進度 UI → SRS
- [ ] 問答預設範圍：全庫 vs 最近 90 天（費用與相關性的平衡）
- [ ] 管理維度是否需要資料夾／自訂標籤，或「分類＋星標＋篩選」已足夠

---

## Users & Context

**Primary User**
- **Who**: 使用者本人——語音庫的唯一擁有者，會議＋隨身錄音＋聽寫三源匯流後的重度查詢者。
- **Current behavior**: 靠記憶＋線性列表翻找；找不到就放棄。
- **Trigger**: 需要引用過去的會議決議、找回某段想法、確認某人說過的話。
- **Success state**: 問一句話，10 秒內拿到附出處的答案，點引用即達原文。

**Job to Be Done**
當我需要回顧過去說過／聽過的內容時，我想要用自然語言直接問我的語音庫，這樣我不必記得它藏在哪一筆錄音裡。

**Non-Users**
需要離線／本地隱私問答的場景（明確排除）；多人協作查詢。

---

## Solution Detail

### Core Capabilities (MoSCoW)

| Priority | Capability | Rationale |
|----------|------------|-----------|
| Must | 管理頁：篩選（分類/來源/日期/星標/狀態）＋排序＋批次操作＋大量資料流暢 | 量成長後的生存需求；引用落點 |
| Must | 問答頁：提問 → 檢索 → 附引用回答；引用點擊跳原始逐字稿 | 功能核心價值 |
| Must | 新轉錄自動入索引；舊資料一次性回填（含進度） | 沒有索引就沒有問答 |
| Should | 提問範圍 chips（來源／分類／日期） | 控費用、提相關性 |
| Should | 問答對話保存與回顧 | 查詢結果本身也是資產 |
| Could | 多輪追問、建議問題 | 體驗加分項 |
| Won't | 本地 embedding、跨裝置、自動摘要排程 | 見 NOT Building |

### MVP Scope

M1 管理頁強化（先解瀏覽痛、鋪引用落點）→ M2 索引＋基本問答（含回填）→ M3 範圍篩選與引用打磨。

### User Flow

側欄開「Ask AI」→ 輸入「上週會議我答應要給誰什麼東西？」→ 10 秒內得到回答＋[1][2] 引用 → 點 [1] 跳到該筆逐字稿的對應段落；或：管理頁按「分類=會議＋最近 30 天」篩選 → 批次重新匯出到 vault。

---

## Feasibility

**Verdict**: HIGH — 逐字稿／講者／分類資料模型與多家 LLM 供應商管線既存；新增為索引層與兩個頁面，無基礎設施缺口。

> Architecture, data model, API contracts, technology choices, and detailed technical risks belong in the SRS. Run `/prp-srs docs/prd/ask-ai-and-recording-library.prd.md` to produce that next.

---

## Product Milestones

| # | Milestone | User-Visible Value | Status | Depends | SRS | Plan |
|---|-----------|--------------------|--------|---------|-----|------|
| 1 | 錄音庫管理強化 | 千筆量級仍能快速篩選、排序、批次整理 | pending | - | - | - |
| 2 | Ask AI 基本問答 | 自然語言問庫，得到附引用的回答（含舊資料回填） | pending | 1 | - | - |
| 3 | 範圍與引用打磨 | 範圍 chips、引用跳至段落、對話保存 | pending | 2 | - | - |

### Milestone Details

**Milestone 1: 錄音庫管理強化**
- **User can now**: 在千筆庫中用篩選＋排序秒級定位，批次重新分類／匯出／刪除／星標。
- **Success signal**: 找回舊內容 <30 秒；千筆操作不卡。
- **Out of scope for this milestone**: 問答、索引。

**Milestone 2: Ask AI 基本問答**
- **User can now**: 對整個語音庫自然語言提問，得到附引用回答；點引用開啟原始逐字稿。
- **Success signal**: 問答 <10 秒、引用正確率 ≥90%；回填完成率 100%。
- **Out of scope for this milestone**: 範圍 chips、多輪追問。

**Milestone 3: 範圍與引用打磨**
- **User can now**: 限定來源／分類／日期提問；引用直達段落；回顧歷史問答。
- **Success signal**: 日常查詢穩定改用 Ask AI 而非翻列表。
- **Out of scope for this milestone**: 建議問題、多輪深度對話。

> Note: Technical phases and parallelism live in the **SRS**. Implementation tasks live in the **Plan**. This PRD only captures product value sequencing.

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| Embedding 位置 | 雲端 | 本地模型 | 使用者明示隱私不設限；品質／省事優先 |
| 施工順序 | 管理頁先於問答 | 先問答 | 管理頁是引用落點＋立即痛點 |
| 問答頁定位 | 獨立新頁 | 併入既有 Assistant 對話 | 職責不同：庫檢索問答 vs 即時對話輔助 |
| 檢索資料範圍 | 聽寫＋錄音＋會議全庫 | 僅錄音庫 | 三源匯流才是「個人語音知識庫」的完整價值 |

---

## Research Summary

**Market Context**
chat-with-notes 是語音筆記品類最一致的付費牆（Voicenotes Pro $9/月、Plaud Pro+、Otter 終身 20 問）；歷史保留量是會議 SaaS 最常見的免費版限制。兩者是本功能包的付費驗證來源。（市場調查：2026-07-06 本 session，~40 產品）

**Technical Context**
2026-07-06 架構討論確認：資料模型（逐字稿／講者段落／分類／時間戳）與 LLM 供應商管線既存；缺口為索引層、問答頁、管理頁的量級化改造。個人量級檢索無需向量資料庫等新基礎設施。

---

*Generated: 2026-07-06*
*Status: DRAFT - needs validation*
*Source Linear Issue: N/A — standalone*
