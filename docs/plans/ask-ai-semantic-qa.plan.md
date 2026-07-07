---
linear_issue: null
---
# Plan: Ask AI — 跨庫語意問答（新模組 ask-ai）

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type`. Mode B（任務先測）：索引/檢索/引用層全部先測；網路層以 payload 純函式測試替代（repo 無 mock-network 前例）；UI 手動驗證。
> **前置依賴**：`docs/srs/recorder-automation-recording-library.srs.md` 的 focus 鉤子（引用跳轉升級版用；v1 引用開 detail sheet **不依賴**它，可獨立實作）。

## Summary
新 `ask-ai` 模組：所有 `Transcription`（聽寫/錄音/會議）切塊 → 雲端 embedding（預設 Gemini `gemini-embedding-001` @768 維、OpenAI `text-embedding-3-small` 備援）→ 第 4 個 SwiftData store 本地向量庫 → vDSP 暴力 cosine top-k → 一次 `completeChat` 產生**附編號引用**的繁中回答；含既有歷史回填（可中斷、冪等、費用預估）、範圍 chips（來源/分類/日期）、對話持久化、新側欄頁。

## User Story
As a 語音庫的主人, I want 用自然語言問「上週會議誰承諾了什麼」並得到附出處的回答, so that 我不必記得內容藏在哪筆錄音裡。

## Problem → Solution
只有線性列表＋關鍵字搜尋 → chunk＋embedding＋檢索＋引用生成；索引為衍生資料（可隨時砍掉重建），核心資料零風險。

## Metadata
- **Module**: ask-ai
- **Parent Plan**: N/A
- **Source PRD**: docs/prd/ask-ai-and-recording-library.prd.md（Milestones 2–3）
- **Source Feature SRS**: docs/srs/ask-ai-semantic-qa.srs.md
- **Source Module Spec**: docs/spec/ask-ai.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature ｜ **Size**: L ｜ **Complexity**: Large
- **Rigor**: balanced ｜ **Mode**: B — 任務先測 ｜ **TDD**: on ｜ **Commit cadence**: per-task
- **Estimated Files**: ~14（4 modified + 7 created + tests）

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/ask-ai-semantic-qa.srs.md` | all | 需求＋資料模型＋AC |
| P0 | `docs/spec/ask-ai.spec.md` | all | 模組架構（本 plan 不重新設計，照 spec 施工） |
| P0 | `VoiceInk/VoiceInk.swift` | :50-56（Schema 陣列）、:236-299（兩個 container factory） | 第 4 store 註冊——**兩個 factory 都要加** |
| P1 | `VoiceInk/Services/AIEnhancement/AIChatCompletionService.swift` | :5-91 | `completeChat(provider:modelName:messages:systemPrompt:timeout:)`＋`chatAPIKey` |
| P1 | `VoiceInk/Services/APIKeyManager.swift` | :12-48 | provider→keychain 鍵解析（embedding 金鑰共用 Gemini/OpenAI 既有條目） |
| P1 | `VoiceInk/Services/RecorderAutomation/TokenEstimator.swift` | :9-31 | CJK-aware 估算（chunk 尺寸） |
| P1 | `VoiceInk/Services/RecorderAutomation/LongTranscriptSummarizer.swift` | :60-85 | 段落邊界切塊基底（chunker 鏡射對象） |
| P1 | `VoiceInk/Views/Recorder/RecorderComponents.swift` | :396-552（AssistantPanelView） | 聊天 UI 結構鏡射（ScrollViewReader＋bubble＋MarkdownContentView） |
| P1 | `VoiceInk/Views/ContentView.swift` | :4-23（ViewType）、:74-110（routing） | `.askAI` 五處註冊之二 |
| P1 | `VoiceInk/Views/Sidebar/AppSidebar.swift` | :74-97（title/sections）、:106-162（icon/style） | 五處註冊之三（DEBUG assert 強制齊全） |
| P1 | `VoiceInk/Transcription/Cloud/ElevenLabsDiarizingClient.swift` | all | in-repo HTTP client 樣式（EmbeddingClient 鏡射；LLMkit 無 embeddings） |
| P2 | `VoiceInk/Models/Transcription.swift` | :43-50、:74-140 | JSON-in-raw-field accessor（citationsRaw 同款）；speakerSegments（chunk 邊界用） |
| P2 | `VoiceInk/Notifications/AppNotifications.swift` | :3-23 | `.transcriptionCompleted`/`.transcriptionDeleted` 名稱 |
| P2 | `VoiceInk/Views/History/TranscriptionDetailView.swift` | 開檔確認 init 參數 | 引用 sheet 的目標 view |

## External Documentation

| Topic | Source | Key Takeaway |
|---|---|---|
| Gemini embeddings | ai.google.dev/gemini-api/docs/embeddings | `models/gemini-embedding-001:batchEmbedContents`；`outputDimensionality: 768`（MRL）；免費層 ~1,500 req/day；$0.15/1M std |
| OpenAI embeddings | platform.openai.com/docs（text-embedding-3-small） | `POST /v1/embeddings`、1536 維（支援 `dimensions` 參數）、input 上限 8,191 tokens、$0.02/1M |
| 檢索規模 | 2026 vector-search 基準文獻（研究紀錄於 session） | 50k×768 f32 ≈150MB、暴力搜尋 ≪100ms——**不需 ANN**；向量寫入時 L2 normalize → cosine＝dot |
| Chunking | firecrawl/langcopilot 2026 指南 | 400–512 tokens、10% overlap 起步（overlap 效益存疑——AC 後可 A/B 0%）；逐字稿優先講者輪次邊界 |
| ⚠️ 空間相容 | Gemini 文件 | `-001` 與 `-2-preview` 與 OpenAI 向量空間互不相容——`embeddingModel` 標籤查詢時強制檢查，換模型＝全量重嵌 |

---

## Patterns to Mirror

### FOURTH_STORE（兩個 factory 都要）
```swift
// SOURCE: VoiceInk.swift:246-252（default store 的組法；index store 照抄改名）
let transcriptConfig = ModelConfiguration("default",
    schema: Schema([Transcription.self, ImportLedgerEntry.self]),
    url: appSupportURL.appendingPathComponent("default.store"),
    cloudKitDatabase: .none)
// → ModelConfiguration("index", schema: Schema([EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self]),
//     url: ...("index.store"), cloudKitDatabase: .none)
// 並加入 :276 與 :294 兩處 ModelContainer(configurations:) 變參
```

### ONE_SHOT_COMPLETION（回答呼叫）
```swift
// SOURCE: AIChatCompletionService.swift:5-12 — 簽名與用法
func completeChat(provider: AIProvider, modelName: String? = nil,
                  messages: [ChatMessage], systemPrompt: String? = nil,
                  timeout: TimeInterval = 30) async throws -> String
// 用法：completeChat(provider: p, modelName: m, messages: [ChatMessage.user(userBlock)], systemPrompt: sys, timeout: 60)
```

### CHUNK_BASIS（切塊基底）
```swift
// SOURCE: LongTranscriptSummarizer.swift:60-85 — 段落/換行邊界、上限硬切；chunker 改小尺寸＋overlap＋講者輪次
// SOURCE: TokenEstimator.swift:9-16 — CJK ~1:1、其餘 /4
```

### JSON_RAW_FIELD（citations 存取器）
```swift
// SOURCE: Models/Transcription.swift:43-50 — audioChunkURLs/audioChunkPathsRaw 的 raw-String + computed 存取器樣式
```

### IN_REPO_HTTP_CLIENT
```swift
// SOURCE: Transcription/Cloud/ElevenLabsDiarizingClient.swift — URLRequest 組裝/錯誤字串/async 呼叫的房內慣例
```

### CHAT_UI_STRUCTURE
```swift
// SOURCE: RecorderComponents.swift:439-473 — ScrollViewReader{ScrollView{ForEach(messages){bubble}}}＋scrollToBottom；
// :554-589 MarkdownContentView 泡泡渲染
```

### VIEWTYPE_REGISTRATION（五處，assert 強制）
```swift
// SOURCE: ContentView.swift:4-23（case）+ :74-110（routing）；AppSidebar.swift:92-97（sections，DEBUG assert）
// + :74-89（title）+ :106-125（icon）+ :127-162（sidebarIconStyle，無 default 的 exhaustive switch）
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Models/AskAIModels.swift` | CREATE | `EmbeddingChunk`/`AskAIThread`/`AskAIMessage` @Model＋`ChunkRef` Codable |
| `VoiceInk/VoiceInk.swift` | UPDATE | Schema＋第 4 `ModelConfiguration`（兩 factory） |
| `VoiceInk/Services/AskAI/TranscriptChunker.swift` | CREATE | 純切塊（講者輪次感知） |
| `VoiceInk/Services/AskAI/EmbeddingClient.swift` | CREATE | Gemini/OpenAI HTTP＋batch＋backoff＋L2 normalize |
| `VoiceInk/Services/AskAI/TranscriptIndexService.swift` | CREATE | upsert/delete/backfill（冪等、progress、費用預估） |
| `VoiceInk/Services/AskAI/RetrievalService.swift` | CREATE | scope 預過濾＋vDSP top-k |
| `VoiceInk/Services/AskAI/AskAIService.swift` | CREATE | prompt 組裝＋引用解析驗證＋thread 持久化 |
| `VoiceInk/Views/AskAI/AskAIView.swift`（+子元件） | CREATE | 聊天頁＋scope chips＋backfill/設定/空狀態 |
| `VoiceInk/Views/ContentView.swift`＋`Views/Sidebar/AppSidebar.swift` | UPDATE | `.askAI` 五處註冊 |
| `VoiceInkTests/AskAI*(Chunker/Index/Retrieval/Service)Tests.swift` | CREATE | Task 1-6 測試 |

## NOT Building
本地 embedding／離線問答；ANN 索引；多跳 agentic 檢索；自動摘要；跨裝置；聊天中編輯逐字稿；段落級高亮（Could，記 Follow-ups）。

---

## Step-by-Step Tasks

### Task 1: 資料模型＋第 4 store
- **ACTION**: 三個 @Model＋`ChunkRef`；Schema/兩 factory 註冊。
- **TEST FIRST**（`AskAIIndexTests`）:
  ```swift
  func testIndexStoreRoundtrip() throws {
      let c = try ModelContainer(for: EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self,
          configurations: ModelConfiguration(isStoredInMemoryOnly: true))
      let ctx = ModelContext(c)
      ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "hi",
                                vector: Data([0,0,128,63]), dims: 1, embeddingModel: "test",
                                sourceKind: "dictation", categoryId: nil, timestamp: .now))
      try ctx.save()
      XCTAssertEqual(try ctx.fetchCount(FetchDescriptor<EmbeddingChunk>()), 1)
  }
  ```
  Run: `xcodebuild test ... -only-testing:VoiceInkTests/AskAIIndexTests` — FAIL
- **IMPLEMENT**（`AskAIModels.swift`；欄位照 SRS schema 區塊逐字）:
  ```swift
  @Model final class EmbeddingChunk {
      var transcriptionId: UUID; var chunkIndex: Int; var text: String
      var vector: Data          // Float32 LE、L2-normalized
      var dims: Int; var embeddingModel: String
      var sourceKind: String    // "dictation" | "recorder" | "meeting"
      var categoryId: UUID?; var timestamp: Date
      #Index<EmbeddingChunk>([\.transcriptionId], [\.timestamp])
      init(...) { ... }         // memberwise
  }
  @Model final class AskAIThread { var title: String; var createdAt: Date; ... }
  @Model final class AskAIMessage {
      var thread: AskAIThread?; var role: String; var text: String
      var citationsRaw: String?; var createdAt: Date
      // computed `citations: [ChunkRef]` 鏡射 JSON_RAW_FIELD
  }
  struct ChunkRef: Codable, Equatable { var transcriptionId: UUID; var chunkIndex: Int; var excerpt: String }
  ```
  `VoiceInk.swift`：Schema 陣列加三型別；`createPersistentContainer`＋`createInMemoryContainer` 各加 `ModelConfiguration("index", ...)`＋變參（鏡射 FOURTH_STORE）。
- **VALIDATE**: 測試 PASS＋app 啟動（`make local` build）。
- **COMMIT**: `feat(ask-ai): index store models + 4th ModelConfiguration`

### Task 2: TranscriptChunker
- **ACTION**: `chunks(for text:speakerSegments:target:overlapRatio:) -> [ChunkDraft]`——講者輪次優先、段落次之、`TokenEstimator` 控尺寸（預設 target 450 tokens、overlap 10%）。
- **TEST FIRST**（`AskAIChunkerTests`）:
  ```swift
  func testChunksRespectTokenTarget()      // 長文 → 每塊 est ≤ 512
  func testSpeakerTurnsStayIntact()        // segments 給定 → 塊邊界不切斷單一輪次（輪次本身超限才硬切）
  func testShortTextSingleChunk()          // 短文 → 1 塊、無 overlap
  func testChunkIndicesAreStableAndOrdered()
  ```
  — FAIL
- **IMPLEMENT**: 純 enum/struct（無依賴）；輸入有 segments 時以「講者N：text」輪次串為單位聚合，無則沿 CHUNK_BASIS 的段落切法；overlap 取前一塊尾部 ~10% tokens 的完整句。`ChunkDraft { index, text }`。
- **VALIDATE**: 四測試 PASS。
- **COMMIT**: `feat(ask-ai): speaker-turn-aware chunker`

### Task 3: EmbeddingClient
- **ACTION**: 兩 provider 的 batch embed＋backoff＋normalize；payload 組裝/解析抽純函式（可測）。
- **TEST FIRST**（`AskAIEmbeddingTests`——純函式，不打網路）:
  ```swift
  func testGeminiPayloadShape()    // encodeBatchRequest(texts:dims:768) → JSON 含 outputDimensionality、requests[n]
  func testOpenAIPayloadShape()    // model=text-embedding-3-small、input array
  func testParseAndNormalize()     // 模擬回應 JSON → [[Float]]；斷言 |v|₂ == 1（±1e-5）
  func testVectorDataRoundtrip()   // [Float] ↔ Data LE
  ```
  — FAIL
- **IMPLEMENT**: `enum EmbeddingModel { case gemini001_768, openaiSmall1536; var dims/name/provider }`；
  `EmbeddingClient.embed(texts:[String], model:) async throws -> [[Float]]`——URLRequest 組裝鏡射 IN_REPO_HTTP_CLIENT；金鑰 `APIKeyManager.shared.getAPIKey(forProvider:)`（Gemini/OpenAI 既有條目——先 grep provider 名確認鍵名）；batch ≤100 texts/請求；429/5xx 指數退避（3 次）；回傳前 L2 normalize＋`floatsToData/dataToFloats` helpers（vDSP）。
- **GOTCHA**: Gemini API key 以 query param 或 `x-goog-api-key` header——照現有 Gemini 轉錄 client 的作法（grep `generativelanguage` 找既有用法鏡射）。
- **VALIDATE**: 四測試 PASS。
- **COMMIT**: `feat(ask-ai): embedding client with pure payload seams`

### Task 4: TranscriptIndexService（事件掛鉤＋回填）
- **ACTION**: upsert on `.transcriptionCompleted`、delete on `.transcriptionDeleted`、`backfill()`（progress AsyncStream、pause/resume、冪等、費用預估、模型標籤檢查）。
- **TEST FIRST**（`AskAIIndexTests` 續，mock EmbeddingClient via protocol）:
  ```swift
  func testUpsertIsIdempotentByChunkIdentity()   // 同 transcription 兩次 upsert → chunk 數不變、舊塊被替換
  func testDeleteRemovesChunks()
  func testBackfillResumesWithoutDuplicates()    // 半途 cancel → 再跑 → 每筆恰一組塊
  func testMixedModelVectorsRefused()            // store 有 modelA 塊、查詢 modelB → 丟 AskAIError.mixedVectorSpace
  ```
  — FAIL
- **IMPLEMENT**: `protocol Embedding { func embed(...) }`（EmbeddingClient 遵循；測試用 fake 回固定向量）；`@MainActor singleton`＋`configure(modelContext:)`；upsert = 刪同 transcriptionId 舊塊→插新塊（單 save）；索引文本 = `enhancedText ?? text`；sourceKind 判定：`recorderSourceLabel != nil → "meeting"`、`importFingerprint != nil → "recorder"`、else `"dictation"`；backfill 走 default-store 全量 id 游標、批 20 筆、`AsyncStream<Progress{done,total,estTokens}>`；費用預估 = `TokenEstimator` 總和 × 單價常數。通知掛鉤在 configure 時註冊（鏡射 RecorderImportService init 的 addObserver 樣式）。
- **VALIDATE**: 四測試 PASS。
- **COMMIT**: `feat(ask-ai): index lifecycle + resumable backfill`

### Task 5: RetrievalService
- **ACTION**: scope predicate 撈候選塊 → dot product top-k（k=12）。
- **TEST FIRST**（`AskAIRetrievalTests`）:
  ```swift
  func testScopePredicateFilters()   // 三種 sourceKind＋日期界線 seed → 範圍外零候選
  func testTopKOrdersByScore()       // 已知向量 → 排序正確
  func testPerf50k()                 // 50k 隨機 768 維 → 單查 <100ms（measure block；Apple Silicon）
  ```
  — FAIL
- **IMPLEMENT**: `struct AskAIScope { sources: Set<String>?, categoryId: UUID?, dateRange: ClosedRange<Date>? }` → `#Predicate<EmbeddingChunk>`；fetch 後 `vDSP_dotpr` 逐塊（向量已 normalize）＋partial top-k（維護 k 大小的最小堆或簡單 sort——50k sort 也 <100ms，先 sort，perf 測試把關）；回 `[ScoredChunk{chunk, score}]`。
- **VALIDATE**: 三測試 PASS（perf 數字記進 report）。
- **COMMIT**: `feat(ask-ai): scoped brute-force retrieval`

### Task 6: AskAIService（回答＋引用驗證＋持久化）
- **ACTION**: 檢索 → system/user prompt 組裝 → `completeChat` → 解析 `[n]` 並**驗證只指向檢索集**（幻覺引用歸零的機制保證）→ 存 AskAIMessage（citationsRaw）。
- **TEST FIRST**（`AskAIServiceTests`，mock completion via protocol）:
  ```swift
  func testCitationsMapToRetrievedChunks()   // 回答含 [1][3] → citations 恰為檢索集第 1/3 塊的 ChunkRef
  func testOutOfRangeCitationDropped()       // 回答含 [9]（檢索僅 5 塊）→ 該標記剔除＋log
  func testEmptyRetrievalShortCircuits()     // 候選空 → 不呼叫 completion、回「找不到」訊息
  func testThreadPersistence()               // ask 兩輪 → thread.messages 依序存檔
  ```
  — FAIL
- **IMPLEMENT**: system prompt（照 spec API Contracts 逐字）＋user block：`[n] <chunk.text>\n（來源：<標題或日期>）`；`ask(question:scope:thread:) async -> AskAIMessage`；引用 regex `\[(\d+)\]` → 驗證 1...k；答案模型 = 現有 enhancement 預設（`AIService` 的 selectedModel 機制——picker 交 Task 8）。
- **VALIDATE**: 四測試 PASS。
- **COMMIT**: `feat(ask-ai): cited answers with retrieval-set validation`

### Task 7: AskAIView＋五處註冊＋引用 sheet
- **ACTION**: `.askAI` case（Shared & System 區、icon `bubble.left.and.text.bubble.right.fill`、style 沿 `AppTheme.Sidebar.dictionary` 類比）；頁面：thread 側列（或 v1 單 thread 下拉）＋訊息列（鏡 CHAT_UI_STRUCTURE＋MarkdownContentView）＋輸入列＋scope chips（來源/分類/日期 menu）＋引用按鈕 → `TranscriptionDetailView` sheet（fetch by id；已刪 → toast）。空狀態三種：無金鑰（設定 CTA）／索引空（回填 CTA）／回填中（進度）。
- **TEST FIRST**: N/A（UI）——build＋assert（sidebar DEBUG assert 會抓漏註冊）。
- **IMPLEMENT**: 五處註冊照 VIEWTYPE_REGISTRATION 清單逐一；view 檔組件化（`AskAIMessageBubble`/`ScopeChipBar`/`BackfillBanner`）。
- **VALIDATE**: `make local` 綠＋手動走查。
- **COMMIT**: `feat(ask-ai): chat page + sidebar registration + citation sheet`

### Task 8: 設定與模型選擇
- **ACTION**: AskAIView 內設定 popover（或 Settings 區塊）：embedding provider（Gemini 768 預設／OpenAI 1536）＋金鑰狀態檢查；answer model picker（復用現有 provider/model picker 樣式——grep `RecorderModelChoice` 的實作鏡射）；**換 embedding 模型 → 確認 dialog「需全量重嵌 N 塊」→ 清空索引＋觸發回填**。
- **TEST FIRST**: `testModelSwitchInvalidatesIndex()`（service 層：switch → chunks 清空＋狀態旗標）— FAIL
- **IMPLEMENT**: `TranscriptIndexService.switchModel(to:)`；UI 綁定。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(ask-ai): provider settings + model-switch re-embed flow`

### Task 9: 收尾
- **ACTION**: 全套 Validation → 20 題人工 eval 清單（從真實歷史出題，含 5 題庫外對照——AC-1 的 90%/零幻覺門檻）寫進 Linear 驗證 issue → `docs/spec/ask-ai.spec.md` Change History＋SPEC_ROADMAP → bump（兩處）→ `make deploy` → 回報 build 號 → plan/SRS 移 completed/。
- **COMMIT**: `chore(ask-ai): bump build, docs, deploy`

---

## Testing Strategy

| Test | Input | Expected | Edge |
|---|---|---|---|
| StoreRoundtrip | 三模型插取 | 正常 | — |
| Chunker ×4 | 長文/輪次/短文 | 尺寸與邊界正確 | 單輪次超限硬切 |
| Payload ×4 | texts | JSON shape／normalize | 空 texts |
| Index ×4 | upsert/delete/backfill/混模型 | 冪等/清除/續跑/拒絕 | cancel 時機 |
| Retrieval ×3 | scope＋50k perf | 過濾/排序/<100ms | 空候選 |
| Service ×4 | mock completion | 引用驗證/短路/持久化 | 越界引用 |
| ModelSwitch | 切換 | 索引清空 | — |

### Edge Cases Checklist
- [ ] 無任何金鑰／只有 OpenAI 無 Gemini（fallback 順序）
- [ ] 回填中途 app 重啟 → 續跑無重複
- [ ] Gemini 免費層 429 → backoff 且 progress 不倒退
- [ ] 引用目標 transcription 已刪 → sheet 開啟前偵測＋toast
- [ ] 問題含程式碼/emoji；超長問題（>8k tokens → 截斷 query 嵌入）
- [ ] scope 全排除（零候選）→ 「找不到」而非幻覺

## Validation Commands
```bash
make local
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO -only-testing:VoiceInkTests
make deploy
```

### Manual Validation（→ Linear 驗證 issue）
- [ ] 回填全庫：進度/ETA/費用預估顯示、可暫停續跑、完成計數＝歷史筆數
- [ ] AC-1：20 題 eval ≥90% 引用正確；5 題庫外對照全部回「找不到」（零幻覺引用）
- [ ] AC-2：新聽寫/錄音/會議 ~1 分鐘內可問到
- [ ] AC-4：引用點擊開出正確逐字稿
- [ ] AC-6：檢索 <100ms、整體回答 <10s
- [ ] 換 embedding 模型 → 重嵌流程完整

## Acceptance Criteria
- [ ] SRS AC-1〜AC-6 全過；四個空/異常狀態不卡死

## Risks
| Risk | L | I | Mitigation |
|---|---|---|---|
| 幻覺引用 | M | H | 引用集驗證（Task 6 機制性剔除）＋對照題 AC |
| Gemini 金鑰缺（使用者實際只有他牌） | M | L | OpenAI fallback；Task 8 首跑時檢查並提示（SRS Open Question） |
| SwiftData 批量插入慢 | M | M | 批 20＋單 save；不行改背景 context（Notes 記錄） |
| completeChat 對長 context 逾時 | L | M | timeout 60s＋k=12 控制 prompt 尺寸 |

## Notes
- 引用跳轉升級（開錄音庫並聚焦該列）依賴 recording-library plan Task 5 的 `pendingFocusTranscriptionId`——兩者都完成後補一小 task 接線（Follow-ups）。
- Float16 壓縮、overlap A/B、段落級高亮全部進 Follow-ups，不進 v1。
