# Spec: Ask AI (Semantic QA)

## Metadata
- **Module**: ask-ai
- **Parent Module**: N/A
- **Sub-modules**: N/A
- **Source PRDs**:
  - `docs/prd/ask-ai-and-recording-library.prd.md` — initial creation (Milestones 2–3; Milestone 1 lives in `recorder-automation`)
- **Source Linear Issue**: N/A
- **Owner**: TBD (personal fork — vi000246/VoiceInk)
- **Status**: ACTIVE — living document
- **Created**: 2026-07-06
- **Last Updated**: 2026-07-14

## Change History

| Date | Source PRD | Feature SRS | Summary |
|------|------------|-------------|---------|
| 2026-07-14 | N/A（使用者需求） | N/A（直接實作） | **索引 UX 重整：背景索引 + 進度 + 覆蓋率（已實作）** — ①「重建索引」從頁首搬進齒輪，並依語料庫拆成兩顆：`重建語音庫索引`（逐字稿 backfill）與 `重建筆記庫索引`（Obsidian）。舊名「重建索引」只回填逐字稿，筆記沒索引的人按它一百次也不會有用——名字對不上語料庫就是誤導。②新 `NoteIndexCoordinator`（@MainActor 單例）成為筆記索引**唯一的 in-flight 擁有者**：Task 歸單例持有 → 關掉設定 sheet／離開 Ask AI 頁，索引照跑；`@Published progress/lastRun` 讓 view 只當觀察者（進度不再隨 view 陪葬）。四個入口（頁 onAppear／筆記 chip 開啟／會議 attach／設定頁手動）全部收斂到這裡 → 修掉一個真實的 latent race：「開著 Ask AI 又開會」以前會有**兩份 reindex 同時掃同一份 sidecar**，hash 表互相覆蓋、同一批檔重複打 embedding API。③`reindex` 加 `onProgress` 回報與 `force`（強制全量重嵌，逃生門）＋取消點；取消時**照樣寫回 sidecar**（未處理的檔沿用舊 hash → 已花的錢不白費、還沒做的事也不會被蓋成做完）。④`TranscriptIndexService.backfill()` 的 AsyncStream 改成 service 持有的 Task ＋ `@Published backfillProgress`（同理：回填幾分鐘，使用者一定會切走）。⑤**新 `NoteIndexCoverage`（索引覆蓋率）**：把「vault 現在有什麼」對上「索引裡真的有什麼」（權威來源是 `EmbeddingChunk` 本身，不是 sidecar）→ 每個檔一個狀態：`indexed`／`stale`(改過待重嵌)／`pending`(**新檔還沒進索引**)／`empty`(沒內容，不是漏索引)／`ghost`(檔案沒了但塊還在 → 檢索得到 = AI 拿刪掉的筆記回答)。這是使用者唯一看得見「增量索引靜默失效」的地方。⑥頁首「新對話」→「清除對話」：真的把 thread 從 index store 刪掉（cascade），不再只是清畫面留一堆永遠回不去的死 thread。⑦切換 embedding 模型後順手重建筆記索引（`switchModel` 刪光**所有**塊含筆記，只回填逐字稿的話筆記索引會靜默消失）。 |
| 2026-07-14 | N/A（對抗式審查） | N/A | **索引 UX 的七個缺陷（審查揪出，已修＋回歸鎖）** — 🔴 **取消契約整段是死碼**：迴圈唯一的懸掛點是 embedding 請求，取消時 URLSession 丟的是 `URLError(.cancelled)`（再被 `EmbeddingClient` 包成 `.http(0,…)`），**不是** `CancellationError` → 只認型別的話「取消也要把已嵌好的檔記進 sidecar」永遠不會執行 → 已付費的檔下次全部重嵌，且使用者看到紅色「索引失敗」而非「已取消」。改以 `Task.isCancelled` 為準（service ＋ coordinator 兩端）。🔴 **`force` 全量重嵌先清塊、後失效 sidecar**：sidecar 是最後才寫的，force 那輪中途死掉（斷網／金鑰過期）就等於「塊全沒了、hash 表卻仍有效」→ 下次增量掃描 hash 全命中 → 全部跳過 → **筆記索引永久空著且完全無聲**（重建鈕回報「已是最新」）。改成**先寫空 state、再清塊**。🔴 **取消時弄丟「已消失檔案」的 sidecar 記錄**：消失檔的 key 只存在於 sidecar，取消時只補「磁碟上還在的檔」會讓它蒸發 → 下輪算不出它消失過 → 塊變**永久幽靈**（檢索撈得到 → AI 拿刪掉的筆記回答）。改成沿用**所有** oldState 未處理的 key。🔴 **換 embedding 模型時 backfill 靜默被吞**：`switchModel` 清光所有塊後呼叫的重建撞上新的 single-flight → no-op → 索引永久缺一角。索引期間 disable 模型 picker。🔴 **`清除對話` 刪掉 in-flight `ask()` 手上的 thread** → 寫入已刪除的 SwiftData 物件；提問中 disable。🟠 **覆蓋率謊報「無內容」**：零塊但 hash 命中就判 `.empty` → 上面那個 force 失敗情境下會給出一整排無害的「無內容」＋綠色「都已進索引」，而實際上索引是空的。改成掃描時實際切一次塊（與索引器同一套規則）判斷有無內容；**有內容卻零塊一律 `pending`，不看 hash**（塊是權威，sidecar 只是帳本）。🟠 覆蓋率掃描加世代標記（慢的舊掃描不得覆蓋新 scope 的結果）。 |
| 2026-07-14 | N/A（測試基建） | N/A | **測試不得碰 `UserDefaults.standard`（修 flaky 紅燈）** — `MeetingCopilotConfigStore` 的設定後端抽成 `MeetingCopilotDefaults` protocol（正式 = `UserDefaults.standard`，測試注入 `InMemoryDefaults`）。起因：新增一個 test class 後 `MeetingCopilotConfigStoreTests.testNotesRAGSettingsRoundTrip` 開始隨機紅。根因有二，缺一不可：(a) test target 是 `parallelizable = YES` —— 每個 class 一個 process 但**共用同一個 UserDefaults domain**，`MeetingReplayReviewTests` 寫 `useNotesRAG = false` 的瞬間，另一個 process 正在斷言「未設定 → 預設 true」；(b) 就算改用 `UserDefaults(suiteName:)` 也救不了——suite 只是**加進** search list，讀取仍會 fallthrough 到 app 自己的 domain，於是測試讀到的是**開發機上 VoiceInk 的真實偏好設定**。所以隔離必須換掉整個後端。順手刪掉三處「setUp 備份 / tearDown 還原 `.standard`」的 bracket：它們本身就是在**寫**全域 domain，正是污染源。 |
| 2026-07-14 | N/A（使用者需求） | `docs/srs/ask-ai-obsidian-notes-rag.srs.md` | **Obsidian 筆記升級一級語料庫 spec'd（未實作）** — 修現有漏洞：`AskAISourceFilter.all` 的 `sources = nil` 完全不過濾 sourceKind → 筆記塊**已經**漏進預設查詢、引用誤稱「來源錄音」（修法：`.all` 改明確三 kind 集合＋回歸鎖）。新增：scope bar「語音庫／Obsidian 筆記」雙 chip（@AppStorage 持久化、預設語音庫開/筆記關、禁全關）；轉錄 facet（子來源/分類/時間）只作用轉錄塊，obsidian 塊豁免 category/date 過濾（分類過濾現況會誤殺筆記——合成 id 查不到 displayTag）；新 `ObsidianRAGConfigStore`（vault override 新鍵＋收編 include/exclude 資料夾設定、鍵沿用零遷移、`effectiveVaultRoot()` 單點解析）；齒輪「筆記來源設定」sheet（vault picker＋資料夾 multi-checkbox＋重建按鈕）；自動索引觸發（頁 onAppear＋筆記 chip 開啟，single-flight、失敗靜默）；`EmbeddingChunk`/`ChunkRef` 加 `sourceTitle`/`sourcePath`，sidecar 加 `schema: 2` 版號自癒（全量重嵌回填 metadata＋重嵌起點先清全部 obsidian 塊防幽靈殘留）；CitationPopup 筆記變體「在 Obsidian 開啟」（`obsidian://open?path=`）。meeting-copilot 側：設定頁筆記 section 瘦身＝消費開關＋導航連結；`scheduleNotesReindex` 改讀新 store。 |
| 2026-07-14 | code-sync（`/prp-spec`） | `docs/srs/meeting-copilot-m8-notes-rag-auto-deep.srs.md` | **M8 的索引擴用已實作，但本模組的一半配合沒做（🔴 靜默失效）** — 已落地：`EmbeddingChunk` 第 4 種 `sourceKind` = `"obsidian"`（`ObsidianNoteIndexService`，身分鍵為路徑 SHA-256 前 16 bytes 的確定性 UUID，無 schema 變更）；`reconcileOrphans` 已排除 obsidian 塊（`TranscriptIndexService.swift:120`，測試 `AskAIIndexTests.testReconcileOrphansPreservesObsidianChunks`）。**未落地（FR-44 後半）**：`switchModel` 仍然刪光**所有** `EmbeddingChunk`（含 obsidian）而**不通知筆記索引**——`ObsidianNoteIndexService` 的增量比對只看**檔案內容 hash**、不看 `embeddingModel` tag，所以換模型後 sidecar hash 全部命中 → 筆記**永遠不會被重嵌**，且設定頁「重建筆記索引」會回報 0 檔、看起來一切正常。**筆記 RAG 從此靜默失效。** 修法：sidecar state 加 top-level `embeddingModel` 欄位，`loadState()` 發現 tag 不符 → 整份視為空（= 全量重嵌），語意正好對上「換模型＝向量空間不相容」。另：`AskAIModels.swift:22` 的 `sourceKind` doc comment 仍寫「dictation \| recorder \| meeting」，漏了 obsidian。 |
| 2026-07-13 | N/A（meeting-copilot M8 跨模組） | `docs/srs/meeting-copilot-m8-notes-rag-auto-deep.srs.md` | **索引基建被 meeting-copilot M8 擴用（spec'd）** — `EmbeddingChunk` 新增第 4 種 `sourceKind` 值 `"obsidian"`（Obsidian 筆記塊；`transcriptionId` 對筆記為「vault 相對路徑 SHA-256 前 16 bytes」確定性 UUID、`timestamp` = 檔案 mtime，無 schema 變更）；新 `ObsidianNoteIndexService`（重用 `TranscriptChunker`/`EmbeddingClient`/同一 embedding model）。**本模組兩處行為配合**：`TranscriptIndexService.reconcileOrphans` 必須跳過 `sourceKind == "obsidian"`（筆記塊沒有對應 Transcription，否則任一次轉錄刪除把筆記索引全清）；`switchModel` 清索引後重嵌流程須涵蓋筆記。檢索層零改動（`AskAIScope.sources` 本就支援任意 sourceKind；Ask AI 聊天頁暫不查筆記——現有 scope 過濾不含 `"obsidian"` 即維持現狀）。 |
| 2026-07-08 | N/A（v2 需求） | `docs/srs/ask-ai-enhancements.srs.md` | **Ask AI 增強 spec'd（WP6，未實作）** — 專用答案模型 picker（可選 Gemini Pro 等推理強者，獨立於 enhancement 預設）;來源篩選改語音輸入／錄音輸入（會議歸錄音輸入，映射 sourceKind {recorder,meeting}）;`AskAIScope.transcriptionId` 單檔提問（錄音/語音管理列上「Ask AI」按鈕）;新 `AskAITemplate` @Model + Ask AI 範本頁（預載 persona system prompt）;Ask AI 獨立側欄群 +`.askAITemplates`。 |
| 2026-07-08 | `docs/prd/ask-ai-and-recording-library.prd.md` | `docs/srs/completed/ask-ai-semantic-qa.srs.md` | **Implemented (build 231).** Tasks 1-8: `EmbeddingChunk`/`AskAIThread`/`AskAIMessage` in a 4th `index.store` (both container factories); `TranscriptChunker` (speaker-turn-aware, CJK TokenEstimator, overlap, oversized hard-split); `EmbeddingClient` (Gemini `x-goog-api-key` / OpenAI Bearer, batch+backoff, L2-normalize, Float32-LE Data); `TranscriptIndexService` (idempotent upsert on `.transcriptionCompleted`, **orphan reconciliation** on `.transcriptionDeleted` since that signal carries `object: nil` — no id — so we sweep index vs live ids; resumable backfill AsyncStream; `switchModel` index-clear); `RetrievalService` (vDSP dot-product top-k; model-tag+date in `#Predicate`, sources/category in-memory to dodge optional-UUID/nested-`??` predicate type-check blowup); `AskAIService` (citation-set validation drops out-of-range `[n]` = hallucination; empty retrieval short-circuits without calling the model; thread persistence); `AskAIView` chat page + `.askAI` ViewType (5-point registration, sidebar assert passes) + scope chips + citation→detail-sheet + embedding-model switch w/ re-embed confirm. Injectable embedder+completer throughout → 24 unit tests. Manual AC-1 (20-question eval / zero-hallucination) tracked in Linear verification issue. **Deviations vs SRS:** delete is a reconcile sweep (SRS assumed id-carrying delete); optional filters applied post-fetch not in predicate. |
| 2026-07-06 | `docs/prd/ask-ai-and-recording-library.prd.md` | `docs/srs/completed/ask-ai-semantic-qa.srs.md` | Created — RAG over all Transcription history: chunk → cloud embeddings (BYOK, Gemini default) → local vector index in a new 4th SwiftData store → vDSP brute-force top-k → one `completeChat` answer with numbered citations; new sidebar chat page + backfill. |

## Summary

`ask-ai` turns the app's transcription history (dictation, recorder imports, meetings) **and the
user's Obsidian notes**（spec'd — notes-rag SRS）into a queryable knowledge base: text is chunked
and embedded via a cloud embedding API, vectors live in a local SwiftData store, retrieval is exact
brute-force cosine (personal scale — no ANN), and answers come from one existing-provider chat call
with retrieved excerpts and enforced citations. The module is read-only over core data: it consumes
`Transcription` rows and lifecycle notifications, and never mutates them; notes are likewise
read-only（index 是衍生資料）. Scope 由「語音庫／Obsidian 筆記」雙 chip 組成（per-query 模式，
非全域設定）；轉錄 facet（子來源/分類/時間）只作用於轉錄塊。

---

## Domain Model

### Bounded Context
- **Context Name**: AskAI
- **Domain Layer**: Supporting Domain (retrieval/answering over Core transcription data)
- **Parent Module**: N/A

### Ubiquitous Language
| Term | Definition |
|------|-----------|
| Chunk | A ~400–512-token slice of one transcription's text (`enhancedText ?? text`), paragraph/speaker-turn aware. Identity = `(transcriptionId, chunkIndex)` — the idempotency key for indexing. |
| Index | The set of `EmbeddingChunk` rows in the dedicated `index.store`. Dropping/rebuilding it never touches core data. |
| Vector Space | The embedding model that produced a vector (`embeddingModel` tag). Vectors from different spaces are never compared; switching models ⇒ full re-embed. |
| Backfill | The one-time (resumable, idempotent) job that indexes pre-existing history. |
| Scope | Retrieval pre-filter (source kind / category / date range) applied as a store predicate before similarity. |
| Citation | A `[n]` marker in an answer mapping to a retrieved chunk (`ChunkRef {transcriptionId, chunkIndex, excerpt}`); tapping opens the source transcript. Fabricated citations are a defect (AC-gated). |
| Thread | A persisted Ask AI conversation (`AskAIThread` + `AskAIMessage`), distinct from the ephemeral dictation Assistant. |
| 語料庫 chip | scope bar 上「語音庫」「Obsidian 筆記」兩顆可獨立開關的 chip——決定這一題查哪個語料庫（per-query 模式，@AppStorage 記住上次選擇）。至少一顆開啟。 |
| Effective Vault | 筆記 RAG 實際使用的 vault：`notesVaultBookmark`（override）優先，nil 時跟隨 `RecorderConfigStore.vaultRootBookmark`（錄音匯出 vault）。由 `ObsidianRAGConfigStore.effectiveVaultRoot()` 單點解析。 |
| Facet 豁免 | 轉錄 facet（分類/時間）不套用於 obsidian 塊的 domain 規則——筆記無分類、mtime ≠ 內容時間；不豁免則分類篩選會整批誤殺筆記（合成 id 查不到 displayTag）。 |
| Sidecar schema | 筆記索引 sidecar 的版號（`IndexState.schema`）。信任條件 = schema 與 embeddingModel 皆相符，任一不符 → 全量重嵌（自癒）。 |

### Domain Events
| Event | Trigger Condition | Consumers |
|---|---|---|
| `.transcriptionCompleted` (existing) | Any pipeline finishes a transcription | `TranscriptIndexService.upsert` |
| `.transcriptionDeleted` (existing, via `TranscriptionStore`) | User deletes a transcription | `TranscriptIndexService.delete(transcriptionId:)` |

---

## System Context

### Scope & Boundaries
- **In scope**: chunking; embedding clients (Gemini/OpenAI, BYOK); index store + lifecycle (upsert/delete/backfill/invalidate-on-model-change); scoped brute-force retrieval; answer assembly with citations; thread persistence; `AskAIView` chat page + scope chips + settings.
- **Out of scope**: local/offline embeddings; ANN indexes; agentic multi-hop retrieval; auto-summarization (category templates own that); mutating transcripts; cross-device sync; the Recording Library page itself (see `recorder-automation-recording-library.srs.md` — it only exposes the citation focus hook this module consumes).

### Actors
| Actor | Type | Interaction |
|---|---|---|
| User | Human | Asks questions, taps citations, runs/monitors backfill, picks providers |
| Embedding API (Gemini / OpenAI) | Service | Batch-embeds chunks and queries (BYOK) |
| Chat provider (any existing `AIProvider`) | Service | One completion per question via `AIService.completeChat` |
| Core transcription pipelines | Internal | Emit completion/deletion events the index follows |

### External Dependencies
| Dependency | Purpose | Failure Mode |
|---|---|---|
| Gemini `gemini-embedding-001` embedContent/batch (default, 768-dim MRL) | Chunk + query embeddings | No key/quota → fall back to OpenAI if configured, else indexing paused with status UI; questions against a stale index still work |
| OpenAI `text-embedding-3-small` /v1/embeddings (fallback, 1536-dim) | Same | Same (roles swapped) |
| Chat provider via `AIService.completeChat` | Answer generation | Existing per-provider error strings surface in the thread; retrieval results shown even if generation fails |

---

## Architecture

### High-Level Diagram
```
                       ┌────────────────────── VoiceInk core (read-only for ask-ai) ─────────────────────┐
                       │ Transcription(@Model, 3 stores)   .transcriptionCompleted / .transcriptionDeleted │
                       └───────────────▲───────────────────────────────┬───────────────────────────────┘
                                       │ fetch text/meta               │ events
     Backfill (resumable) ─────────────┤                               ▼
                                       │                      TranscriptIndexService
                                       │                        │ chunk (TranscriptChunker)
                                       │                        │ embed (EmbeddingClient, batch)
                                       │                        ▼
                                       │                EmbeddingChunk @Model  ←──  index.store (4th store, .none)
                                       │                        ▲
   AskAIView (.askAI page)             │                        │ scoped fetch (predicate: source/category/date)
     │ question + scope chips          │                        │
     ▼                                 │                        ▼
   AskAIService ── embed(query) ───────┘                RetrievalService (vDSP cosine, top-k 12)
     │  top-k chunks + numbered context                         │
     ├────────── completeChat(provider, system+user) ◄──────────┘
     ▼
   answer + [n] citations → AskAIThread/AskAIMessage (persisted) → citation tap → transcript detail
```

### Components
| Component | Responsibility | Interface |
|---|---|---|
| `TranscriptChunker` | Deterministic chunking (~400–512 tokens via `TokenEstimator`, paragraph/speaker-turn boundaries, configurable overlap) | pure: `chunks(for: Transcription) -> [ChunkDraft]` |
| `EmbeddingClient` | In-repo HTTP clients (Gemini + OpenAI-compatible), batching, backoff; keys via `APIKeyManager` | `embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]]` |
| `TranscriptIndexService` | Index lifecycle: upsert on completion, delete on deletion, backfill (progress/pause/resume, idempotent), model-change invalidation | `@MainActor` singleton; `upsert(_:)`, `delete(transcriptionId:)`, `backfill() -> AsyncStream<Progress>` |
| `RetrievalService` | Scoped fetch → vDSP cosine → top-k with scores | `retrieve(queryVector:scope:k:) -> [ScoredChunk]` |
| `AskAIService` | Prompt assembly (citation rules, 「找不到」 rule), `completeChat`, citation parsing, thread persistence | `ask(question:scope:thread:) async -> AskAIMessage` |
| `AskAIView` + `.askAI` ViewType | Chat page, scope chips, thread list, citation buttons, backfill/settings UI | SwiftUI; registered via the 5 mandatory ViewType edits |
| `ObsidianNoteIndexService`（M8 起既有；notes-rag SRS 收編為本模組共用基建） | Obsidian vault → 增量向量索引：內容 hash sidecar、確定性 noteId（路徑 SHA-256）、取代式 upsert、schema/model 版號自癒 | `@MainActor`；`reindex(vaultRoot:includeOnly:excluded:) async throws -> Int` |
| `ObsidianRAGConfigStore`（spec'd） | 筆記 RAG 管線設定：vault override、include/exclude 資料夾、effective vault 單點解析 | `@MainActor` singleton；UserDefaults 持久化（資料夾鍵沿用 meeting-copilot 時期鍵名） |

### Data Flow
Write path is event-driven and async (completion event → chunk → batch embed → upsert); the user
only sees index status in the page footer. Read path is synchronous per question: embed the query
(1 call) → scoped fetch + brute-force cosine in-memory → one chat completion → persist message with
citations. Backfill is a long-running cancellable task with the same upsert primitive.

### Sequence (ask, happy path)
```
User → AskAIView: question + scope
AskAIView → AskAIService.ask
AskAIService → EmbeddingClient: embed(query)            (~100–300 ms)
AskAIService → RetrievalService: retrieve(v, scope, 12) (<100 ms in-memory)
AskAIService → AIService.completeChat(context+question) (2–8 s)
AskAIService → index.store: persist AskAIMessage(+citations)
AskAIView ← answer with [n] buttons → tap → transcript detail (sheet; library focus when available)
```

---

## Data Model

### Entities
| Entity | Owner | Lifecycle |
|---|---|---|
| `EmbeddingChunk` (@Model) | `TranscriptIndexService` | Upserted on transcription completion/backfill; deleted with its transcription or on index invalidation |
| `AskAIThread` / `AskAIMessage` (@Model) | `AskAIService` | Created in the chat page; user-deletable |

### Schema (new — all in `index.store`)
See `docs/srs/ask-ai-semantic-qa.srs.md` for field-level detail. Keys: `EmbeddingChunk` identity `(transcriptionId, chunkIndex)`; `#Index` on `[\.transcriptionId]`, `[\.timestamp]`; `vector: Data` (Float32 LE, 768 dims default); `embeddingModel` space tag; denormalized `sourceKind`/`categoryId`/`timestamp` for scope predicates. `sourceKind` 現有 4 值：`dictation`/`recorder`/`meeting`/`obsidian`（obsidian 塊的 `transcriptionId` 為路徑衍生合成 UUID、`timestamp` = 檔案 mtime）。Spec'd（notes-rag SRS）：+`sourceTitle`/`sourcePath` optional（obsidian 塊的出處 metadata，轉錄塊 nil；輕量遷移）。

### Migration Strategy
- **Forward**: additive — 2–3 new `@Model`s appended to the app `Schema` + a 4th `ModelConfiguration("index", …, cloudKitDatabase: .none)` in both container factories (`VoiceInk.swift:50-56, 236-299`). Core stores untouched.
- **Backward**: deleting `index.store` (or removing the config) loses only derived data; rebuildable via backfill.
- **Backfill**: explicit user-triggered job (cost/quota estimate shown first); resumable; idempotent by chunk identity.
- **Coexistence**: index absent ⇒ page shows empty-state with backfill CTA; core app unaffected.

---

## API Contracts

> No HTTP API served. External calls (BYOK):

### Embedding call (logical contract)
```
Gemini:  POST models/gemini-embedding-001:batchEmbedContents   { texts…, outputDimensionality: 768 } → [[Float]]
OpenAI:  POST /v1/embeddings  { model: text-embedding-3-small, input: [texts] }                      → [[Float]]
```
Constraints: OpenAI input cap 8,191 tokens/item (chunker guarantees ≪); Gemini free tier ~1,500 req/day → batch + backoff; vectors L2-normalized on write so cosine = dot product.

### Answer call (logical contract)
```
system: 你是使用者語音庫的問答助手。只根據提供的片段回答（繁體中文）。每個論點標註 [n] 引用。
        片段不足以回答時明說「資料庫中找不到相關內容」，不得編造引用。
user:   [1] <chunk text + 來源: 標題/日期> … [k] <…>\n\n問題: <question>
→ reuses AIService.completeChat provider routing / keys / error handling unchanged
```

### Internal error surface (`AskAIError`)
| Case | Meaning | Handling |
|---|---|---|
| `noEmbeddingKey` | Neither provider configured | Settings CTA; asking disabled |
| `indexEmpty` | No chunks in scope | Empty-state / suggest widening scope or backfill |
| `embeddingFailed` / `generationFailed` | Provider error after retries | Message-level error bubble; retrieval results still listed on generation failure |

### Versioning Strategy
`embeddingModel` tag per chunk = the version. Model switch ⇒ explicit re-embed prompt; mixed-space comparison is checked and refused at query time.

---

## Non-Functional Requirements

| Category | Target | Measurement | How Achieved |
|---|---|---|---|
| Latency | Retrieval <100 ms @ 50k chunks; end-to-end <10 s | Perf test (`RetrievalServicePerfTests`) + manual timing | In-memory vDSP dot product; single completion call |
| Memory | ≤ ~300 MB transient worst case; scoped loads | Instruments spot check | 768-dim Float32; predicate-scoped vector fetch |
| Cost | Backfill ~1k recordings ≈ free-tier / low $ | Estimate shown pre-backfill | Gemini free tier; batch endpoints |
| Integrity | 0 cross-space comparisons; 0 fabricated citations on control questions | Unit + 20-question eval sheet | Space tag check; citation-parse validation against retrieved set |
| Observability | Per-stage os_log | Console.app filter | `Logger` category `AskAI` |

---

## Technology Choices

| Concern | Choice | Alternatives | Rationale |
|---|---|---|---|
| Embedding model | Gemini `gemini-embedding-001` @ 768 (MRL) | OpenAI 3-small (fallback, kept); `gemini-embedding-2` (preview); Voyage/Cohere | Best-reputation multilingual (CJK) line; free personal tier; 768 dims = 4× storage saving; `-2` revisit at GA |
| Vector store | SwiftData `@Model` in dedicated `index.store` | SQLite sidecar (sqlite-vec); files | Mirrors the proven multi-store pattern; no new deps; drop-store = clean invalidation |
| Similarity | Brute-force cosine via Accelerate/vDSP | FAISS/HNSW ANN | 50k×768 ≈ 150 MB, ≪100 ms/query — ANN crossover ~100k vectors; zero deps |
| Embedding HTTP client | In-repo | Extend LLMkit | LLMkit is remote/non-editable and has no embeddings support (precedent: `ElevenLabsDiarizingClient`) |
| Answer generation | Existing `AIService.completeChat` | New client | Provider routing/keys/errors already solid |
| Chat persistence | New `@Model`s in index store | Reuse `AssistantSession` | Assistant is deliberately in-memory/ephemeral; Ask AI threads are durable artifacts |
| Citations v1 | Detail sheet in-place | Cross-page navigation first | Zero nav plumbing to ship v1; library focus hook (recorder-automation SRS FR-8) upgrades it later |

---

## Integration Points

| Touchpoint | Type | Contract | Backwards Compat |
|---|---|---|---|
| `Schema` + container factories (`VoiceInk.swift:50-56,236-299`) | App bootstrap | +3 models, +1 `ModelConfiguration` in BOTH factories | Yes — additive |
| `.transcriptionCompleted` / `.transcriptionDeleted` notifications | Event consume | Upsert/delete index rows | Yes — observer only |
| `AIService.completeChat` (`AIChatCompletionService.swift:5-77`) | In-process async | One-shot completion | Yes — additive caller |
| `APIKeyManager` (`Services/APIKeyManager.swift:45-48`) | Keychain read | Embedding provider keys (Gemini/OpenAI entries exist) | Yes |
| `ViewType`/`ContentView`/`AppSidebar` (5 edits: `ContentView.swift:4-23,74-110`; `AppSidebar.swift:74-97,106-162`) | UI registration | `.askAI` page under Shared & System | Yes — additive (DEBUG assert enforces completeness) |
| Recording Library focus hook (`pendingFocusTranscriptionId`, spec'd in recorder-automation) | In-process nav | Citation → focused library row | Yes — optional enhancement |
| `ObsidianRAGConfigStore` ←→ meeting-copilot（spec'd） | In-process config | 筆記管線設定（vault/資料夾）的單一權威來源；meeting attach 的 `scheduleNotesReindex` 改讀此 store | Yes — UserDefaults 鍵沿用零遷移 |
| `AppNavigator.navigate(to: .askAI)`（spec'd 呼叫點） | In-process nav | meeting-copilot 設定頁「筆記索引設定 →」連結 | Yes — 既有 API |

### Rollout Strategy
Inert until an embedding key is configured + backfill run. Kill switch: none needed — removing the page/config leaves core untouched; `index.store` deletable at any time.

---

## Codebase Patterns to Follow

| Pattern | Where to Find | Why Follow |
|---|---|---|
| One-shot chat completion | `Services/AIEnhancement/AIChatCompletionService.swift:5-77` | The answer call |
| Provider/key resolution | `Services/APIKeyManager.swift:12-48`, `AIService.swift:253-267` | Embedding + answer keys/models |
| CJK-aware token estimate | `Services/RecorderAutomation/TokenEstimator.swift:9-31` | Chunk sizing |
| Boundary-aware chunking | `Services/RecorderAutomation/LongTranscriptSummarizer.swift:60-85` | Chunker basis (smaller target size) |
| Multi-store setup | `VoiceInk.swift:236-299` | 4th store registration (both factories!) |
| In-repo provider client (bypass LLMkit) | `Transcription/Cloud/ElevenLabsDiarizingClient.swift` | `EmbeddingClient` shape |
| Chat UI structure | `Views/Recorder/RecorderComponents.swift:396-552` (`AssistantPanelView`) + `Views/Common/MarkdownContentView.swift` | `AskAIView` message list/bubbles |
| Cursor pagination (thread list if needed) | `Views/History/InlineHistoryView.swift:22-59` | Large-list convention |
| ViewType registration | `Views/ContentView.swift:4-23,74-110`, `Views/Sidebar/AppSidebar.swift:74-162` | `.askAI` page wiring |
| JSON-in-raw-field accessor | `Models/Transcription.swift:43-50` | `citationsRaw` accessor shape |

---

## Risks & Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Vector-space lock-in (model deprecation/switch ⇒ full re-embed) | M | M | Space tag + explicit re-embed flow; index is derived data by design |
| ~~`switchModel` 清索引後 obsidian 筆記塊不會被重嵌~~ **✅ 2026-07-14 已修**（commit `1a38f53`） | — | — | 曾經：`switchModel` 刪光所有 `EmbeddingChunk`（含 obsidian），但筆記索引的 sidecar 只記「路徑 → 內容 hash」、不記 model tag → 下次 `reindex` hash 全部命中、全部跳過 → 筆記 RAG 靜默失效（轉錄塊有 `backfill()` 可救，筆記塊沒有等價路徑）。**修法在 `ObsidianNoteIndexService` 側**（本模組的 `switchModel` 未改）：sidecar 改存 `IndexState { embeddingModel, files }`，tag 不符即全量重嵌，並先清掉舊向量空間的殘留筆記塊 → `reindex` 自我修復，不依賴 `switchModel` 是否跑過。回歸鎖：`ObsidianNoteIndexTests.testEmbeddingModelSwitchForcesFullReembed` |
| CJK chunk/retrieval quality below expectation | M | M | Speaker-turn-aware chunking; eval sheet gate (AC-1); provider switchable |
| Fabricated citations / hallucinated answers | M | H | Strict system prompt + citation-set validation + control questions in eval |
| Index store growth (audio-heavy users) | L | L | 768-dim Float32 ≈ 3 KB/chunk; Float16 option queued |
| SwiftData perf on bulk upsert (backfill) | M | M | Batch inserts in background context; progress + resume |
| Gemini free-tier throttling mid-backfill | M | L | Batch + backoff + resumable job; OpenAI fallback |
| sidecar schema bump 觸發的一次性全量重嵌（重嵌期間筆記索引短暫不完整） | H（升級後必發生一次） | L | 個人規模＋free tier 成本可忽略；重嵌期間檢索退化與今日 switchModel 相同；schema 寫回後不再觸發 |

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|---|---|---|---|
| Retrieval architecture | Embeddings + brute-force cosine | FTS+LLM rerank; agentic tool-use search | CJK FTS is weak; agentic = multi-call latency/cost; exact search trivial at personal scale |
| Default embedding | Gemini 001 @ 768 | OpenAI 3-small; local models | User: cloud OK; CJK reputation + free tier; fallback kept |
| Index placement | 4th SwiftData store | Rows in default store; SQLite sidecar | Derived-data lifecycle independence; no new deps |
| Page identity | New `.askAI` page + durable threads | Extend Assistant | Different jobs: library QA (durable, cited) vs dictation companion (ephemeral) |
| v1 citation UX | In-place detail sheet | Cross-page jump first | Ships without nav plumbing; upgrade path defined |
| 筆記查詢開關位置（notes-rag SRS） | scope bar 雙 chip（per-query 模式） | 設定頁全域開關 | 「查什麼」每題都可能不同，是模式不是配置；@AppStorage 記住上次選擇即獲得設定的效果 |
| 筆記塊 facet 語意（notes-rag SRS） | category/date 豁免 obsidian 塊 | 統一套用全部過濾 | 筆記無分類、mtime≠內容時間；不豁免則分類篩選誤殺筆記（合成 id 查不到 tag） |
| 舊塊 metadata 回填（notes-rag SRS） | sidecar `schema` 版號 → 全量重嵌一次 | 免重嵌的 metadata-only 回填 pass | 三行實作、自癒、鏡射既有 model-tag 檢查；回填 pass 是一次性遷移碼，個人規模重嵌成本可忽略 |
| 筆記管線設定的家（notes-rag SRS） | 新 `ObsidianRAGConfigStore`（ask-ai 側） | 留在 MeetingCopilotConfigStore | 索引成為兩功能共用資產；掛在 meeting 設定下逼 Ask AI-only 使用者翻不相干頁面；鍵沿用零遷移 |
| 點回筆記的 URL（notes-rag SRS） | `obsidian://open?path=`（絕對路徑） | `vault=&file=` 參數對 | path 免 vault 名匹配、Obsidian 自行解析所屬 vault；限制（vault 需在 Obsidian 註冊過）記入 Open Questions |

---

## Open Questions

- [ ] Which embedding key does the user already have (Gemini vs OpenAI)? — decides default order; confirm at plan time.
- [ ] Float16 vector storage — measure quality/size before switching from Float32.
- [ ] Chunk overlap 10% vs 0% — A/B on real corpus (2026 evidence: overlap may not help).
- [ ] Default answer model — reuse enhancement default vs pin a fast model.
- [ ] Segment-level citation highlight in the detail sheet (Could).
- [ ] 筆記塊 vs 轉錄塊的檢索分數平衡——同一 embedding 空間理論可比；若實務上筆記長期壓過轉錄（或反之），考慮 per-source k 配額（notes-rag SRS 觀察項）。
- [ ] `obsidian://open?path=` 對未在 Obsidian 註冊過的 vault 會跳錯誤對話框——v1 只檢查檔案存在，不驗證 vault 註冊狀態。
