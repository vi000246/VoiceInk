---
linear_issue: null
---
# SRS: Ask AI × Obsidian 筆記 RAG（雙語料庫 scope + 筆記設定收編 + 引用回筆記）

## Metadata
- **Module**: `ask-ai`
- **Module Spec**: `docs/spec/ask-ai.spec.md`
- **Source PRD**: N/A（standalone 技術任務 — 2026-07-14 使用者需求；FOUNDATION/DESIGN 訪談以對話中的代碼調查與設計覆核代替，Grill level 1）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-14
- **Plan**: `docs/plans/ask-ai-obsidian-notes-rag.plan.md`

## Feature Summary

把 M8 為 meeting-copilot 建立的 Obsidian 筆記索引升級為 Ask AI 的**一級查詢語料庫**：scope bar 以「語音庫／Obsidian 筆記」雙 chip 明示這一題查什麼、筆記管線設定（vault override、資料夾過濾、重建索引）收編到 Ask AI 側、引用可點回 Obsidian 原始筆記。同時修掉現有漏洞——預設「全部來源」的 `sources = nil` 完全不過濾 `sourceKind`，筆記塊**現在就已經**漏進 Ask AI 回答，且引用被誤稱「來源錄音」、無法點回出處。

## Delta from Current Module State

> 現有架構見 `docs/spec/ask-ai.spec.md`。本節只描述變更。

### New / Changed Interfaces（無 HTTP API — 皆為 in-process）

| Interface | Change | Consumers |
|---|---|---|
| `AskAISourceFilter.sources` | `.all` 從 `nil` 改為明確 `{"dictation","recorder","meeting"}`（漏洞回歸鎖） | `AskAIView.currentScope` |
| scope 組合純函式（新） | `(語音庫 on/off, 筆記 on/off, 子篩選) → Set<String>` | `AskAIView`、單元測試 |
| `RetrievalService.retrieve` | categoryName／dateRange 過濾**豁免** `sourceKind == "obsidian"` 塊；sources 過濾不豁免 | Ask AI；meeting-copilot 行為不變（它不傳 category/date） |
| `ObsidianRAGConfigStore`（新，@MainActor singleton） | `notesVaultBookmark: Data?`（override）、`includeOnlyFolders`、`excludedFolders`、`effectiveVaultRoot() -> URL?` | Ask AI 筆記設定 sheet、Ask AI onAppear 觸發、meeting attach 觸發、citation 的 obsidian:// 組 URL |
| `ObsidianNoteIndexService.defaultStateURL()`（搬遷） | `notesIndexStateURL()` 從 `MeetingCopilotLiveController` 搬入本 service（**檔案路徑不變** `obsidian-index-state.json`） | 兩個自動觸發點 + 手動重建按鈕 |
| `AppNavigator.navigate(to: .askAI)` | 既有 API、新呼叫點 | `MeetingCopilotSettingsView` 的「筆記索引設定 →」連結 |

### New / Changed Data Models

| Model | Change | Migration |
|---|---|---|
| `EmbeddingChunk`（@Model, index.store） | + `sourceTitle: String?`、+ `sourcePath: String?`（obsidian 塊寫入：標題＝檔名去副檔名、路徑＝vault 相對路徑；轉錄塊恆 nil） | SwiftData 輕量遷移（additive optional） |
| `ChunkRef`（Codable, JSON-in-raw-field） | + `sourceTitle: String?`、+ `sourcePath: String?` | 舊 JSON 缺鍵 → decode 為 nil（向下相容） |
| sidecar `IndexState`（JSON） | + `schema: Int`（本版 = 2）；缺失或不符 → 整份視為空 ＝ 全量重嵌 | 自癒式：升級後第一次 reindex 全量重嵌一次，回填舊塊 metadata |
| UserDefaults | 新鍵 `notesRAGVaultBookmarkV1`（vault override）、`askAIScopeTranscriptsV1`（chip，預設 true）、`askAIScopeNotesV1`（chip，預設 false）；`meetingCopilotNotesIncludeOnlyV1`／`meetingCopilotNotesExcludedV1` **鍵名沿用**、所有權搬到新 store | 零資料遷移 |
| `MeetingCopilotConfigStore` | − `notesIncludeOnlyFolders`、− `notesExcludedFolders`（含 setters）；`useNotesRAG`／`notesInTechnicalRAG`／`aboutMeBrief` 留下（消費開關） | 編譯期改呼叫點 |

### Changed Business Logic

- **檢索 scope 組成**改由雙 chip 決定（FR-2/FR-3）；轉錄 facet（子來源/分類/時間）降為語音庫 chip 的下屬篩選，且只作用於轉錄塊（FR-4）。
- **筆記索引生命週期**新增兩個自動觸發點（Ask AI 頁 onAppear、筆記 chip 開啟；FR-8），與既有的會議 attach 觸發、手動重建共用同一 sidecar 與 single-flight 紀律。
- **引用管線**全程攜帶筆記 metadata：索引寫入 → 檢索 → `extractCitations` → `ChunkRef` 持久化 → CitationPopup 分流（FR-9/FR-10）。

### Explicitly Out of Scope

- **根目錄散檔 checkbox**（使用者明確排除）——「只索引」非空時 vault 根目錄散檔維持現狀被排除，僅以 caption 說明，不提供勾選。
- timer／FSEvents 檔案監看式自動索引（觸發點只有：onAppear、chip 開啟、會議 attach、手動）。
- 檢索層的資料夾過濾（include/exclude 資料夾只是**索引層**的過濾粒度；問答時不能按資料夾篩）。
- 筆記的分類/tag facet（筆記無分類概念——facet 豁免正是 domain 規則）。
- meeting-copilot 的 aboutMe／技術 cue 檢索路由（`gather(sources:)` 白名單機制一字不動）。
- 錄音匯出 pipeline（`RecorderConfigStore.vaultRootBookmark` 語意不變；筆記 vault 只是新增 override）。

## Functional Requirements

- [ ] **FR-1（漏洞修補＋回歸鎖）**：`AskAISourceFilter.all.sources` 回傳明確 `{"dictation","recorder","meeting"}` 而非 `nil`；筆記 chip 關閉時，Ask AI 全庫檢索的候選集永不含 `sourceKind == "obsidian"` 塊。
- [ ] **FR-2（雙語料庫 chips）**：scope bar 顯示「語音庫」「Obsidian 筆記」兩顆可獨立開關的 chip；@AppStorage 持久化（`askAIScopeTranscriptsV1` 預設 true、`askAIScopeNotesV1` 預設 false）；關閉最後一顆開啟中的 chip ＝ no-op（維持開啟）；筆記 chip 在 `effectiveVaultRoot() == nil` 時 disabled ＋ help 提示（「尚未設定筆記 vault — 到齒輪『筆記來源設定』選擇」）；單檔限定模式（`focusedTranscriptionId`）覆蓋 chips，現行為不變。
- [ ] **FR-3（scope 組成）**：語音庫 only → `sources` ＝ 子篩選的明確集合；筆記 only → `sources = {"obsidian"}`，轉錄 facet picker 隱藏且不參與 scope（categoryName/dateRange 一律 nil）；雙開 → `sources` ＝ 子篩選集合 ∪ `{"obsidian"}`。組成邏輯抽成純函式供測試。
- [ ] **FR-4（facet 豁免）**：`RetrievalService` 的 categoryName 與 dateRange 過濾豁免 obsidian 塊——分類過濾現況會誤殺筆記（合成 UUID 查不到 `displayTag` → 整批被丟）；日期過濾對筆記的檔案 mtime 語意不對（筆記是無時效知識）。實作上 dateRange 需自 `#Predicate` 移出或加 OR 分支（注意既有的 optional-in-predicate type-check 爆炸前例，建議 in-memory）。`sources` 過濾不豁免。
- [ ] **FR-5（ObsidianRAGConfigStore）**：新 @MainActor ObservableObject singleton，持有 `notesVaultBookmark: Data?`（新鍵；nil ＝ 跟隨 `RecorderConfigStore.vaultRootBookmark`）、`includeOnlyFolders: [String]`、`excludedFolders: [String]`（沿用既有鍵與既有預設 `[".obsidian", ".trash", "Templates"]`）；`effectiveVaultRoot()` 統一解析（override 優先，經 `VaultExportService.resolveVaultRoot` 同一條路徑）。
- [ ] **FR-6（config 所有權搬移）**：`MeetingCopilotConfigStore` 移除資料夾兩屬性與 setters；`MeetingCopilotLiveController.scheduleNotesReindex` 與 `MeetingCopilotSettingsView` 改讀新 store ＋ effective vault；讀值結果與搬移前 bit-for-bit 相同（鍵名沿用）。
- [ ] **FR-7（筆記來源設定 sheet）**：Ask AI 齒輪 Menu 加「筆記來源設定…」開 sheet，內含：(a) vault 卡片——顯示 effective vault 路徑與「跟隨錄音匯出 Vault／自訂」狀態、「更換…」（NSOpenPanel ＋ security-scoped bookmark，鏡射 `VaultRootCard`）、自訂時「清除」回復跟隨；(b) 「只索引」與「排除」兩個資料夾 multi-checkbox 選單——動態列出 effective vault 第一層目錄（含 dot 目錄、排序；掃描時包 security-scope），勾選雙向繫結 store，vault 未設定時 disabled；(c) 「重建筆記索引」按鈕＋進度/結果/錯誤訊息（沿用現有 `reindexNotes` 訊息語彙——「已是最新」「已索引 N 檔」「需要 embedding 金鑰」）；(d) captions：「只索引」非空時根目錄散檔不會被索引；索引需要 embedding 金鑰（同 Ask AI）。
- [ ] **FR-8（自動索引觸發）**：Ask AI 頁 onAppear、以及筆記 chip 由關轉開時，若筆記 chip 開啟且 effective vault 已設定 → 背景增量 reindex（`Task.detached(priority: .background)`、single-flight guard 防併發、失敗靜默只記 os_log——與 `scheduleNotesReindex` 同紀律）；手動重建按鈕仍是唯一 surface 錯誤的地方。`notesIndexStateURL` 搬到 `ObsidianNoteIndexService`（路徑不變），三個觸發點＋手動共用同一份 sidecar。
- [ ] **FR-9（塊 metadata ＋ sidecar schema 自癒）**：`EmbeddingChunk` 加 `sourceTitle`/`sourcePath`（obsidian 塊由 `ObsidianNoteIndexService` 寫入）；sidecar `IndexState` 加 `schema: Int`（本版 2），schema 缺失或不符 → `loadState` 回空 ＝ 全量重嵌（鏡射既有 embeddingModel tag 檢查，兩個條件都必須成立才信任 state）；**全量重嵌起點（oldState 為空）時先清空所有 obsidian 塊（不分 model tag）**——否則 sidecar 重置後，磁碟上已消失的筆記的塊會成為永不回收、仍可被檢索到的幽靈（此規則涵蓋並取代現有 `discardStaleNoteChunks` 的異模型清理）。
- [ ] **FR-10（引用回筆記）**：`ChunkRef` 加 `sourceTitle`/`sourcePath`；`extractCitations` 從 chunk 帶入；`openCitation` 標題 fallback 鏈改為「Transcription 標題 → `ref.sourceTitle` → 泛稱」（筆記不再被稱「來源錄音」）；`CitationPopup` 筆記變體：筆記標題＋「在 Obsidian 開啟」按鈕（`obsidian://open?path=` ＋ percent-encoded 絕對路徑 ＝ effectiveVaultRoot ＋ sourcePath；檔案不存在時隱藏按鈕），無「開啟完整逐字稿」；轉錄變體不變。
- [ ] **FR-11（meeting 設定頁瘦身）**：`notesRAGSection` 保留 `useNotesRAG`／`notesInTechnicalRAG` 開關與 `aboutMeBrief` 欄位；vault 顯示列、兩個資料夾 TextField、重建按鈕移除；加「筆記索引設定（Ask AI）→」按鈕 ＝ `AppNavigator.shared.navigate(to: .askAI)`，附一行說明。
- [ ] **FR-12（空檢索診斷筆記感知）**：`diagnoseEmptyRetrieval` 加分支——scope.sources 含 `"obsidian"` 且索引中 obsidian 塊數為 0 → 回「筆記尚未建立索引——到齒輪『筆記來源設定』重建索引」（區分「筆記沒索引」與「篩選太窄」）。
- [ ] **FR-13（文案）**：`AppScreenHeader` infoMessage 更新為知識庫語意（聽寫／錄音／會議／筆記）；輸入框 placeholder「問你的語音庫……」同步調整。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 回歸安全（meeting-copilot） | aboutMe／技術 cue 檢索行為 bit-for-bit 不變 | `gather(sources:)` 白名單機制不動；只改 config 讀取來源（鍵名沿用） |
| 回歸安全（錄音匯出） | Obsidian 匯出 pipeline 不變 | `RecorderConfigStore`／`VaultExportService` 介面零改動 |
| 效能 | onAppear 增量掃不阻塞 UI；vault 無變更時零 embedding API 呼叫 | 背景 task ＋ 內容 hash 比對跳過＋ single-flight |
| 成本 | schema bump 觸發的全量重嵌恰好一次 | schema 寫回 sidecar 後不再觸發 |
| 資料相容 | 舊 `ChunkRef` JSON、既有 `EmbeddingChunk` rows、既有 UserDefaults 值全部可讀 | optional 欄位＋輕量遷移＋鍵名沿用 |
| 觀測 | 自動索引結果進 os_log（category 沿用） | 鏡射 `scheduleNotesReindex` 的 log 語彙 |

## Architecture Notes

- **Effective Vault 單點解析**：`ObsidianRAGConfigStore.effectiveVaultRoot()` 是唯一解析點，四個消費者（sheet 顯示、onAppear 觸發、meeting attach 觸發、citation URL）不得各自解 bookmark——否則 override 與跟隨的優先序會在某處走岔。
- **Facet 豁免是 domain 規則不是實作巧合**：筆記沒有分類、mtime ≠ 內容時間。寫進 `RetrievalService` 的過濾段並鎖測試。
- **Sidecar 自癒模式**：`loadState` 的信任條件 ＝ `schema == 2 && embeddingModel == currentTag`，任一不符回空。回空 ＝「重建一切」，因此重建起點必須先清光 obsidian 塊（FR-9），否則「重建」語意不完整。
- **`#Predicate` type-check 前例**：optional／nested `??` 進 predicate 會爆炸（`RetrievalService.swift:38-41` 註解）。facet 豁免建議一律 in-memory，date 過濾自 predicate 移出（個人規模 fetch-all-for-model 本來就是 nil dateRange 的現況成本）。
- **UI 階層**：轉錄 facet 從屬於語音庫 chip（隱藏於筆記 only 模式）——facet 是轉錄的屬性，不是查詢的屬性。

## Acceptance Criteria

> BDD Given/When/Then。測試檔建議沿用現有命名慣例（`VoiceInkTests/`）。

### AC-1: 預設 scope 不漏筆記（漏洞回歸鎖）
- **Given**: 索引同時含 obsidian 與 dictation 塊
- **When**: 以預設 scope（語音庫開、筆記關、子篩選「全部來源」）檢索
- **Then**: 候選集不含任何 obsidian 塊；`AskAISourceFilter.all.sources == {"dictation","recorder","meeting"}`
- **Test**: `AskAIIndexTests` / 新 scope 組成測試

### AC-2: 筆記 only 模式
- **Given**: 兩種塊都在索引中
- **When**: 筆記 chip 開、語音庫 chip 關
- **Then**: 只檢索 obsidian 塊；轉錄 facet picker 不顯示；scope 的 categoryName/dateRange 為 nil

### AC-3: 雙開＋分類篩選不誤殺筆記
- **Given**: 雙 chip 開、categoryName 設為某分類
- **When**: 檢索
- **Then**: 轉錄塊按 displayTag 過濾、obsidian 塊全數保留

### AC-4: 雙開＋時間篩選豁免筆記
- **Given**: 雙 chip 開、dateRange ＝ 近 7 天、某 obsidian 塊 timestamp（mtime）在範圍外
- **When**: 檢索
- **Then**: 該 obsidian 塊仍在候選集；範圍外的轉錄塊被過濾

### AC-5: chip 防呆
- **When**: 關閉唯一開啟中的 chip
- **Then**: chip 維持開啟（no-op）

### AC-6: 無 vault 時筆記 chip disabled
- **Given**: 無 recorder vault 且無 override
- **Then**: 筆記 chip disabled ＋提示；sheet 內資料夾選單 disabled

### AC-7: sidecar schema 自癒（一次全量重嵌＋metadata 回填＋幽靈清理）
- **Given**: 既有 obsidian 塊（`sourceTitle == nil`）＋舊版 sidecar（無 `schema` 欄位）＋一個 state 中有、磁碟上已刪的筆記的殘塊
- **When**: reindex
- **Then**: 全量重嵌；所有 obsidian 塊 `sourceTitle`/`sourcePath` 非 nil；已刪筆記的殘塊被清掉；sidecar 寫回 `schema: 2`
- **Test**: `ObsidianNoteIndexTests`（與既有 `testEmbeddingModelSwitchForcesFullReembed` 並存，該測試必須維持綠）

### AC-8: 引用點回筆記
- **Given**: 回答引用了 obsidian 塊、該筆記檔案存在
- **When**: 點擊 [n]
- **Then**: popup 顯示筆記標題＋「在 Obsidian 開啟」；無「開啟完整逐字稿」；標題不是「來源錄音」；按鈕開啟 `obsidian://open?path=<percent-encoded 絕對路徑>`

### AC-9: ChunkRef 向下相容
- **Given**: 舊三欄 JSON（無 sourceTitle/sourcePath）
- **When**: decode
- **Then**: 成功，新欄為 nil，引用照舊可開（轉錄路徑）

### AC-10: config 搬移零遷移
- **Given**: UserDefaults 既有 include/exclude 資料夾值
- **When**: 升級後由新 store 讀取
- **Then**: 值不變；meeting attach 的 reindex 讀新 store 與 effective vault，行為與搬移前一致

### AC-11: onAppear 自動增量索引
- **Given**: 筆記 chip 開、vault 已設定、vault 無變更
- **When**: 進入 Ask AI 頁（含快速連續進入）
- **Then**: 排程一次背景增量掃（single-flight 不重複）；重嵌 0 檔、零 embedding API 呼叫；失敗靜默記 log

### AC-12: 空索引診斷
- **Given**: 筆記 only scope、索引無 obsidian 塊
- **When**: 提問
- **Then**: 回覆引導至「筆記來源設定」重建索引，而非泛用「找不到」

### AC-13: 資料夾 multi-checkbox
- **Given**: effective vault 有第一層目錄
- **When**: 開「排除資料夾」選單勾選某目錄
- **Then**: store 持久化；下次 reindex 該目錄被跳過（includeOnly 同理）

## Open Questions

- [ ] `obsidian://open?path=` 需要該檔所屬 vault 曾在 Obsidian 開啟過（Obsidian 以已知 vault 清單解析 path）；未註冊過的 vault 會跳 Obsidian 錯誤對話框。v1 接受——按鈕只檢查檔案存在，不驗證 vault 註冊狀態。
- [ ] 筆記塊與轉錄塊在同一次檢索中的分數可比性（同一 embedding 空間，理論上可比；若實務上筆記長期壓過轉錄，考慮 per-source k 配額——留待實際使用觀察）。
