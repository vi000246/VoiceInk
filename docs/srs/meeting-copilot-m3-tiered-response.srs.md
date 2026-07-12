---
linear_issue: null
---
# SRS: 會議即時輔助 — M3 三層回應引擎 + SSE + 接地（meeting-copilot）

> 本文件是 umbrella SRS `docs/srs/meeting-copilot-live-assist.srs.md` 的 **M3 里程碑切片**。
> umbrella SRS 定義整個模組（34 FR / 19 AC）；本切片只涵蓋 **M3 — Tiered response + SSE + grounding**，
> 對應 umbrella 的 **FR-13~FR-20、FR-27、FR-28** 與 **AC-5~AC-14**。M1（音訊分流骨幹，build 248）已實作完成；
> M2（cue 偵測引擎）產出的 `MeetingLiveCue` 是本里程碑的輸入；overlay 呈現屬 **M4**、管理頁與設定 UI 屬 **M5**，均不在此。

## Metadata
- **Module**: `meeting-copilot`（新模組，M3 切片）
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Umbrella SRS**: `docs/srs/meeting-copilot-live-assist.srs.md`
- **Source PRD**: N/A（承 umbrella SRS 之產品脈絡）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-12
- **Grill level**: 1 (standard)
- **依賴**: M2（`MeetingLiveCue` @Model + `MeetingCopilotController` 的 `@Published cues`）。M3 消費 cue、產生三層回應並回寫同一 `MeetingLiveCue` 的 tier 欄位。
- **build number**: 250（`CURRENT_PROJECT_VERSION`，Debug + Release 兩處）。

## Feature Summary

把 M2 抽出的一則 **response cue** 變成使用者「能立刻開口的稿子 + 足以應付 follow-up 的深度分析」，
並讓答案**針對我們的專案正確**，而非教科書正確。M3 交付三層漸進揭露引擎：

- **Tier 0**（< 0.5s，**不呼叫 LLM**）：關鍵字表 + 既有 `EmbeddingChunk` 相似度 → 領域標籤 + 關鍵字。
- **Tier 1**（< 1.5s）：fast model **SSE 串流** → 結構化開口稿（`opener` + 恰 3 個 `bullets`）；**最新一則 cue 自動預跑**。
- **Tier 2**（< 15s，點擊才跑）：deep model SSE 串流，帶入 Tier 1 草稿全文 → `analysis` + `followUps[]` + `uncertainties[]`；可取消。

接地（grounding）三來源：**會前 brief**（M2 已存於 `MeetingLiveSession.brief`）、**RAG**（直呼 `LiveEmbedder().embed`
+ `RetrievalService.retrieve` 檢索歷史逐字稿）、**螢幕 OCR**（`ScreenCaptureService.captureAndExtractText()`，只在 Tier 2 擷取一次）。
三者全部**靜默降級**：任何來源失敗都不阻斷回答、不產生任何可見 UI。

因 `AIService.completeChat` 是整包回傳（LLMkit 內 `"stream": false` 寫死、且 LLMkit 為遠端不可編輯的 SPM 套件），
M3 在 repo 內自持一個 SSE client（`StreamingChatClient`），house style 照既有先例 `ElevenLabsDiarizingClient`。

**M3 不含 UI**：不建立 overlay、不接熱鍵、不做 SwiftUI 呈現。M3 產生的 tier 結果落 `MeetingLiveCue`，
由 M4 讀取渲染。M3 的驗證完全走 fake SSE server / fake `StreamingChatCompleting` + replay harness，不需開任何會議軟體。

---

## Delta from Current Module State

> 本里程碑對**既有程式碼**的改動刻意壓到最小：只**唯讀重用** `RetrievalService`、`ScreenCaptureService`、
> `AIService.selectedModel/connectedProviders`，並在 `AIService` **新增** `streamChat`（與 `completeChat` 並存，不改後者）。

### New Data Models

M3 **不新增 @Model**。三層結果回寫 M2 已定義的 `MeetingLiveCue` 欄位
（`tier0Keywords / tier1Opener / tier1BulletsRaw / tier2Analysis / tier2FollowUpsRaw / tier2UncertaintiesRaw /
fastModelName / deepModelName / answeredAt`，見 umbrella SRS「New Data Models」）。陣列欄位沿用 repo 慣例的
**JSON-in-raw-String + `@Transient` 快取**，每個屬性都須有預設值（lightweight migration；repo 無 `VersionedSchema`）。

M3 內部使用的**非持久化**結構（純值型別，不進 SwiftData）：

- **NEW** `Tier1Draft`（`struct`）：`{ opener: String, bullets: [String] }`——恰 3 個 bullets 由 parser/驗證保證。
- **NEW** `Tier2Analysis`（`struct`）：`{ analysis: String, followUps: [FollowUp], uncertainties: [String] }`，
  `FollowUp = { question: String, oneLineAnswer: String }`。
- **NEW** `Tier0Result`（`struct`）：`{ domainLabel: String, keywords: [String] }`。
- **NEW** `MeetingGrounding`（`struct`）：`{ brief: String?, ragChunks: [ScoredChunk], screenText: String? }`——
  組 prompt 用的接地快照。`ScoredChunk` 是既有型別（`Services/AskAI/RetrievalService.swift:20-27`），唯讀重用。

### Changed Business Logic

- **`AIService` 新增 `streamChat(...)`（與 `completeChat` 並存，不改 `completeChat`）**——逐字吐出 delta 供 Tier 1/2 使用。
  鏡射 `completeChat` 的 provider dispatch（`Services/AIEnhancement/AIChatCompletionService.swift:4-77`）：
  `.anthropic` 分支走 Anthropic parser、default（OpenAI-compat：cerebras/groq/gemini/openAI/openRouter/mistral）分支走 OpenAI parser。
- **`AIEnhancementOutputFilter` 的套用時機改變**：`completeChat` 對最終整包字串套用一次
  （`AIChatCompletionService.swift:76`）。串流版**不得逐 delta 套用**——該 filter 以非貪婪多行正則剝
  `<think>/<thinking>/<reasoning>` 整塊，需要完整字串（`Services/AIEnhancement/AIEnhancementOutputFilter.swift:3-21`）。
  M3 累積完整串流字串後套用一次，再落 SwiftData；串流過程可 raw emit（見 Open Questions：是否在 think-tag 內緩衝）。
- **RAG 接地改為直呼底層，絕不經 `AskAIService.ask`**——見「跨里程碑發現 §2」。`AskAIService.ask()` 不是靜默路徑：
  空索引 / embed 失敗時它會 **persist 一則可見的 assistant `AskAIMessage`**（中文診斷字串）並顯示在聊天 UI
  （`Services/AskAI/AskAIService.swift:124-141, 159-174`）。M3 改為：off-main 呼叫 `LiveEmbedder().embed(texts:model:)`
  （`Services/AskAI/TranscriptIndexService.swift:6-14`），再 hop 到 MainActor 呼叫
  `RetrievalService.retrieve(queryVector:scope:k:model:context:)`（`RetrievalService.swift:30-71`），
  全包在自己的 do/catch，失敗回無接地。
- **`MeetingCopilotConfigStore` 擴充**（M1 只有 `copilotEnabled / asrModelName / transcribeLocalMic`）。新增：
  `fastProvider`、`fastModel`、`deepProvider`、`deepModel`、`prefetchEnabled`、`domainPersona`、`useHistoryRAG`、`useScreenContext`。
  沿用 store 樣式：`@Published private(set)` + `…V1` UserDefaults key + `set…()` mutator + `load()`。

### New / Changed API

| 類型 | 元件 | 位置 | 說明 |
|---|---|---|---|
| **NEW** | `StreamingChatClient`（`struct` + `static async throws`） | `Services/AIEnhancement/StreamingChatClient.swift`（新檔） | 自持 SSE client，OpenAI-compat + Anthropic 兩 parser。house style 照 `ElevenLabsDiarizingClient`（`Transcription/Cloud/ElevenLabsDiarizingClient.swift:1-99`）：plain struct + static async、專屬 Error enum、`guard !apiKey.isEmpty` 先 throw、`!(200..<300).contains(statusCode)` 顯式 HTTP 檢查、`req.timeoutInterval = timeout`、pure `parse`。用 `URLSession.shared.bytes(for:)`（**先檢查 HTTP status 再消費 byte stream**）。 |
| **NEW** | `StreamingChatError`（`enum: Error`） | 同上 | `.missingAPIKey` / `.http(Int, String)` / `.emptyResponse`，鏡射 `ElevenLabsDiarizingError`（`ElevenLabsDiarizingClient.swift:1-5`）。 |
| **NEW** | `StreamingChatCompleting`（協定，測試 seam） | `Services/AIEnhancement/` | 與既有 `ChatCompleting`（`Services/AskAI/AskAIService.swift:6-8`）並列。`FakeStreamingChatCompleting` 供腳本化 delta 序列注入。 |
| **NEW** | `AIService.streamChat(provider:modelName:messages:systemPrompt:timeout:)` | `Services/AIEnhancement/`（extension） | `-> AsyncThrowingStream<String, Error>`。鏡射 `completeChat` 的 dispatch 與 `chatAPIKey`/`selectedModel` 解析。 |
| **NEW** | `Tier0Classifier`（`struct`，純本機） | `Services/MeetingCopilot/Tier0Classifier.swift`（新檔） | 關鍵字表 + `EmbeddingChunk` 相似度，**不呼叫 LLM**，< 0.5s，回 `Tier0Result`。 |
| **NEW** | `Tier1Generator` / `Tier2Generator` | `Services/MeetingCopilot/`（新檔） | 各自組 prompt（純函式建構）→ `streamChat` → parse 成 `Tier1Draft` / `Tier2Analysis`。 |
| **NEW** | `AnswerCoordinator`（`@MainActor`，`ObservableObject`） | `Services/MeetingCopilot/AnswerCoordinator.swift`（新檔） | Tier1→Tier2 序列；最新一則 cue 自動預跑 Tier1；Tier2 可取消。 |
| **NEW** | `MeetingGroundingProvider`（`@MainActor`） | `Services/MeetingCopilot/MeetingGroundingProvider.swift`（新檔） | brief + RAG + 螢幕 OCR，全部靜默降級。 |
| **NEW** | `MeetingCopilotModels.resolve(storedProvider:storedModel:defaultProvider:available:)` | `Services/MeetingCopilot/MeetingCopilotModels.swift`（新檔） | fast / deep 純函式，鏡射 `AskAIAnswerModel.resolve`（`Services/AskAI/AskAIConfig.swift:25-39`）；**重新驗證 provider 仍在 `aiService.connectedProviders`**（`Services/AIEnhancement/AIService.swift:234-266`），否則回退預設。 |
| **CHANGED** | `MeetingCopilotConfigStore`（擴充） | `Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | 新增 8 個設定欄位（見上）。 |

### Explicitly Out of Scope（本里程碑不做）

- **所有 UI / overlay / 熱鍵**——`CopilotOverlayPanel`、`sharingType=.none`、`ignoresMouseEvents`、peek 熱鍵、
  說話淡出的**呈現**全屬 **M4**。M3 只把 tier 結果落 `MeetingLiveCue`，不渲染。
- **cue 偵測 / 分類 / 去重**——屬 M2（`ResponseCueExtractor`）。M3 消費既有 cue。
- **`AIService.completeChat` 本身**——不改；`streamChat` 並存新增。
- **RAG 索引 / 嵌入 / 檢索核心演算法**——不改，唯讀重用 `RetrievalService` + `EmbeddingClient`。
- **`ScreenCaptureService` 的實作**——不改，唯讀重用 `captureAndExtractText()`。無法指定目標視窗（見 Architecture Notes 的限制）。
- **`.ollama` / `.localCLI` 分支的串流**——`completeChat` 這兩支把 messages 併成 `<conversation>` XML 走本機非 SSE 路徑
  （`AIChatCompletionService.swift:41-52`）；M3 串流只實作 `.anthropic` 與 default（OpenAI-compat）兩分支。ollama 的串流另有 `OllamaService` 路徑，不在此。
- **管理頁 / 設定 UI**——`MeetingCopilotSettingsView`、雙 model picker 屬 **M5**。M3 只擴充 `MeetingCopilotConfigStore`（資料層）。

---

## Functional Requirements（僅本里程碑）

### 三層回應
- [ ] **FR-13** **Tier 0**（< 0.5s，**不呼叫 LLM**）：`Tier0Classifier` 以關鍵字表 + `EmbeddingChunk` 相似度產出領域標籤 + 2-3 個關鍵字，回 `Tier0Result`。全程零 LLM 請求。
- [ ] **FR-14** **Tier 1**（< 1.5s）：fast model SSE 串流（`streamChat`），輸出**結構化開口稿** `Tier1Draft`（非空 `opener` + **恰 3 個** `bullets`）。
- [ ] **FR-15** **最新一則 cue 的 Tier 1 自動預跑**（`AnswerCoordinator`，受 `prefetchEnabled` 控制，預設 true）；點擊時若已完成則不再發新請求、立即可用。
- [ ] **FR-16** **Tier 2**（< 15s，點擊才跑）：deep model SSE 串流，**user message 帶入 Tier 1 草稿全文**（`opener` + bullets），輸出結構化 `analysis` + `followUps[]` + `uncertainties[]`。
- [ ] **FR-17** Tier 2 **可取消**，取消不影響已存的 Tier 0 / Tier 1 結果。

### 答案接地
- [ ] **FR-18** **會前 brief**：`MeetingLiveSession.brief`（M2 已存）注入 Tier 1 / Tier 2 的 system prompt。
- [ ] **FR-19** **RAG**：以 cue 文字直呼 `LiveEmbedder().embed` + `RetrievalService.retrieve` 檢索歷史逐字稿 top-k，注入 Tier 1 / Tier 2 的 user block；**索引為空或無 embedding key 時靜默跳過**，答案照常產出。**絕不呼叫 `AskAIService.ask`**（它會 persist 可見診斷訊息）。
- [ ] **FR-20** **螢幕上下文**：**只在 Tier 2 啟動時**呼叫一次 `ScreenCaptureService.captureAndExtractText()` 取得分享畫面 OCR 文字；Tier 0 / Tier 1 **不**擷取（避免拖慢首字延遲）；OCR 失敗（權限未授予 / 無視窗 / 無文字 / 逾時）**靜默跳過**。

### 可靠性
- [ ] **FR-27** system prompt **明確禁止**捏造 benchmark 數字、論文、公司名、產品版本；模型無把握的點必須寫進 Tier 2 的 `uncertainties[]`。
- [ ] **FR-28** 任何失敗（LLM / 網路 / embed / OCR）**不得**跳出 modal 或系統通知，且**不得**呼叫 `NotificationManager.showNotification`（它渲染可見 NSPanel、`.error` 會播 esc 音、且無 `sharingType`——三重不合格，見 §Architecture）。失敗逐層降級：Tier 2 失敗保留 Tier 1；Tier 1 失敗保留 Tier 0；RAG / 螢幕失敗靜默跳過答案照出。

---

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| **Tier 0 延遲** | **< 0.5s** | **不呼叫 LLM** — 關鍵字表 + 本機 `EmbeddingChunk` 相似度（`vDSP_dotpr`，`RetrievalService.swift:60-70` 同款本機運算）|
| **Tier 1 延遲** | **< 1.5s**（預跑後點擊為 **~0s**）| fast model（Groq `llama-3.1-8b-instant`）+ SSE + 最新一則預跑 |
| **Tier 2 延遲** | < 15s | 序列啟動（Tier 1 完成後才跑），不與 Tier 1 爭頻寬 |
| 成本 | 預跑只用 fast model 且只跑最新一則；Tier 2 點擊才跑 | `AnswerCoordinator` 只對 newest cue 預跑 Tier 1；`prefetchEnabled` 可關 |
| 正確性（reasoning 不外洩） | OpenAI-compat 串流須注入 `reasoning_effort` + extraBody | 複製 `completeChat` default 分支：`ReasoningConfig.getReasoningParameter` + `getExtraBodyParameters`（`ReasoningConfig.swift:53-82`）；Anthropic 分支兩者皆不用 |
| 正確性（filter） | `<think>` 區塊不外洩 | 累積完整串流字串後套 `AIEnhancementOutputFilter.filter` 一次（`AIEnhancementOutputFilter.swift:3-21`），不逐 delta 套用 |
| 隱蔽性（失敗時） | 失敗不得產生任何可見系統 UI | 無 modal / 無通知 / 不呼叫 `NotificationManager`；三來源接地全靜默降級 |
| 隱私 | 逐字稿與答案僅存本機 | 回寫 `meeting.store`（`cloudKitDatabase: .none`）；RAG 讀本機 `index.store` |
| 執行緒安全 | `RetrievalService` 為 `@MainActor` 同步；embed 為 non-isolated async | embed off-main，`await MainActor.run { retrieve(...) }` hop；不跨 actor 邊界傳 background `ModelContext`（`RetrievalService.swift:30`）|
| 可測性 | 不開會議軟體、不開網路即可驗證 | `StreamingChatCompleting` 協定 + fake；fake SSE server（`URLProtocol` 注入）；replay harness（M1 `ReplayMeetingAudioSource`）|

---

## Architecture Notes

### 兩種 SSE wire format 完全不同 — 需要兩個 parser（跨里程碑發現 §3）

`streamChat` 的 dispatch 鏡射 `completeChat`（`AIChatCompletionService.swift:4-77`）——**anthropic 分支 vs OpenAI-compat default 分支**，
但兩者的 SSE 線格式、auth header、system prompt 位置、reasoning 注入全都不同：

| 面向 | OpenAI-compat（default 分支） | Anthropic 分支 |
|---|---|---|
| endpoint | `provider.baseURL`（**已是完整 `/v1/chat/completions` URL**，`OpenAILLMClient.swift:152` 直接 `URLRequest(url: baseURL)` 不加路徑）| 硬寫 `https://api.anthropic.com/v1/messages`（`AnthropicLLMClient.swift:228`，忽略傳入 baseURL）|
| auth header | `Authorization: Bearer <key>`（`OpenAILLMClient.swift:155`）| `x-api-key: <key>` + `anthropic-version: 2023-06-01`（`AnthropicLLMClient.swift:233-234`，**非 Bearer**）|
| system prompt | 以 `.system(...)` 插入 messages[0]（`OpenAILLMClient.swift:158-161`）| top-level `system` 欄位，並把 system-role 訊息濾出 messages；custom encoder 在 nil 時**省略** system key（`AnthropicLLMClient.swift:237-253, 280-297`）|
| body 串流開關 | `"stream": true`（改 `OpenAILLMClient.swift:167` 的 `false`）+ `Accept: text/event-stream` | 同：body `"stream": true` + `Accept: text/event-stream` |
| reasoning 注入 | `reasoning_effort`（top-level）+ extraBody flat（`ReasoningConfig.swift:53-82`；default 分支才注入，`.custom` 不注入）| **不用**（Anthropic 分支不注入 reasoning/extraBody/temperature）|
| temperature | `1.0` if `resolvedModel.lowercased().hasPrefix("gpt-5")` else `0.3`（`AIChatCompletionService.swift:57`）| 無 temperature；`max_tokens` 預設 8192 |
| delta 位置 | `data: {json}` 行，`choices[0].delta.content`；終止 `data: [DONE]` | `event:<type>` + `data:` 成對，text 在 `delta.text`（`type == text_delta`）；終止 `event: message_stop`（**無 `[DONE]`**）|

**因此 `StreamingChatClient` 必須有兩個 parser。** LLMkit 的 request/response struct（`OpenAIChatResponse`、`AnthropicRequest/Message`、
`AnthropicContentBlock/Response`）**全部 `private`**（`OpenAILLMClient.swift:125-135`、`AnthropicLLMClient.swift:115-146`），
不可跨 module 重用；只有 `ChatMessage` 是 `public`（`ChatMessage.swift:4-27`）。M3 在 repo 內自定義串流 delta 的 `Decodable` struct。

### house style：照 `ElevenLabsDiarizingClient`（跨里程碑發現 §4）

LLMkit 是遠端不可編輯的 SPM 套件，其 `performRequest` 用**帶重試的 ephemeral URLSession**——SSE 不能重用它。
先例 `ElevenLabsDiarizingClient`（`Transcription/Cloud/ElevenLabsDiarizingClient.swift:1-99`）示範：diarization 需要 LLMkit 沒有的能力時，
在 repo 內新增 client 而非改 LLMkit。M3 完全照抄其形態：

1. plain `struct` + `static async throws` 方法（非 class / actor）；
2. 專屬 top-level `Error` enum 帶 associated value（`.missingAPIKey` / `.http(Int, String)` / `.emptyResponse`）；
3. `guard !apiKey.isEmpty else { throw .missingAPIKey }` 先擋；
4. 顯式 `!(200..<300).contains(http.statusCode)` → throw `.http(status, bodyString)`；
5. `req.timeoutInterval = timeout` 設在 request 上；
6. 純可測 `parse` 抽成獨立 static func；
7. doc comment 說明為何繞過 LLMkit。

SSE 走 `URLSession.shared.bytes(for:)`（回 `(URLSession.AsyncBytes, URLResponse)`）——**先從 response header 檢查 HTTP status，
再 `for try await line in bytes.lines` 消費 byte stream**（`ElevenLabsDiarizingClient.swift:578-583` 的 status-before-parse 紀律）。
兩者皆無自動重試（`performRequest` 的重試不適用），需要時 M3 自行加。

### RAG 接地必須直呼底層（跨里程碑發現 §2）— `AskAIService.ask` 是可見路徑，非靜默路徑

- `AskAIError`（`.noEmbeddingKey` / `.indexEmpty`）是 **dead code**——grep 確認全 repo 從未被 throw（`AskAIService.swift:10-19`）。
  不要把 M3 的靜默降級建構在 catch 它之上。
- `AskAIService.ask()` **不是**靜默路徑：空索引 / embed 失敗時它 **persist 一則可見 assistant `AskAIMessage`**（中文診斷字串，
  `diagnoseEmptyRetrieval` / `persistAssistant`）並顯示於聊天 UI（`AskAIService.swift:124-141, 159-174`）。
- 因此 M3 的 `MeetingGroundingProvider` **直呼底層**：
  - `let vec = try await LiveEmbedder().embed(texts: [cueText], model: model).first`
    （`TranscriptIndexService.swift:6-14`；output 已 L2-normalized，直接餵 retrieve）——embed 的 `EmbeddingError.missingAPIKey(provider)`
    是**唯一**的 error 訊號（`EmbeddingClient.swift:113-116`），在自己的 do/catch 內吞掉回無接地；
  - `RetrievalService.retrieve(queryVector:scope:k:model:context:)` 空索引回 `[]` **不 throw**（`RetrievalService.swift:58, 70`）；
  - `model` 取 `TranscriptIndexService.shared.model`（UserDefaults `askAIEmbeddingModelV1`，預設 `.gemini001_768`）——
    query 用不同 model 嵌入時 retrieve 靜默回 `[]`；
  - scope 取會議內容用 `AskAIScope(sources: ["meeting"])` 或 `["recorder","meeting"]`（`AskAIModels.swift` 的 `sourceKind == "meeting"`）；
  - user block 可沿用 `AskAIService.buildUserBlock`（`[1]..[n]` 編號 + `prefix(800)`，`AskAIService.swift:70-79`）或複製其編號慣例。
- **執行緒**：`RetrievalService` 整個 enum 是 `@MainActor` 且 `retrieve` 同步（`RetrievalService.swift:30`）；`EmbeddingClient.embed`
  是 non-isolated async。因此：embed off-main → `await MainActor.run { RetrievalService.retrieve(...) }`，且傳入 **main-actor 的 `ModelContext`**
  （app 內為 `container.mainContext`，單一 container 跨 4 個 store，可同時 fetch `EmbeddingChunk` 與 `Transcription`）。
  不得跨 actor 邊界傳 background context（SwiftData context 非 Sendable）。
- retrieve **無 score threshold**——永遠回 top-k 的 dot product（`RetrievalService.swift:70`）。若 M3 需要相關性下限，自行過濾 `ScoredChunk.score`。
- 剛擷取的會議可能**尚未索引**（`TranscriptIndexService.upsert` 在 `.transcriptionCompleted` 才跑）——retrieve 回 `[]` 是**正常**，非錯誤。

### 螢幕 OCR：只在 Tier 2、一次；且只能抓「前景 focused 視窗」（限制）

`ScreenCaptureService.captureAndExtractText()`（`Services/ScreenCaptureService.swift:40-62`）：instance method、`async`、**無 throws**、
**無參數**，返回 OCR 後的**文字**（不是圖片），**每個失敗路徑都回 nil**（逾時 3.0s / 無視窗 / SCK error / 權限未授予）。
這個 silent-nil 正好滿足 FR-20 的「失敗靜默」，無需額外錯誤處理。

**限制（必須誠實記錄）**：此服務只能擷取 **NSWorkspace 前景 app 的 AX-focused 視窗**（`ScreenCaptureService.swift:92-180` 的
`findActiveWindow`：`processID != currentPID`、`windowLayer == 0`、`isOnScreen`），**沒有任何 API 依 window ID/title 指定目標視窗**。
後果：OCR 只在 Teams/Meet 視窗確為前景時才讀到會議畫面；若使用者切到 Slack，OCR **靜默讀到 Slack**。M3 接受此行為（把它當「盡力接地」而非保證）。
`processID != currentPID` 已排除 app 自身視窗，未來 M4 的 overlay 不會被 OCR 讀回。
**reentrancy**：`isCapturing` guard 是 **per-instance**；`MeetingGroundingProvider` 須持有**單一**長生命週期 `ScreenCaptureService` 實例，否則 guard 形同虛設。

### 失敗必須靜默 — `NotificationManager` 三重不合格（跨里程碑發現，M4 邊界）

FR-28 禁止任何可見 UI。`NotificationManager.showNotification`（`Notifications/NotificationManager.swift:12-99`）**三重不合格**：
(1) 渲染可見的 borderless `NSPanel`（`AppNotificationView`）、**無 `sharingType`** → 分享螢幕時 toast 會被廣播；
(2) `.error` type 呼叫 `SoundManager.shared.playEscSound()` → 會議中可聞的 ding；(3) `makeKeyAndOrderFront` 搶焦點。
M3 一律 **log-only**（OCR 路徑本就 silent-nil，streamChat 的 throw 由 `AnswerCoordinator` 吞掉並降級）。

### 🔴 具名風險：`sharingType=.none` 在 macOS 15.4+ 被 ScreenCaptureKit 忽略（跨里程碑發現 §3 第 1 點）

雖然 overlay 的**呈現**屬 M4，但這是本模組成敗的前提，M3 文件據實記錄以貫穿風險登記：
Apple DTS 明言「目前沒有公開 API 可防螢幕擷取」，`sharingType=.none` 在 **macOS 15.4+ 被 ScreenCaptureKit 忽略**
（Chrome/Google Meet 的 `getDisplayMedia` 走 SCK）。→ 分享**整個螢幕**時 overlay 會被錄到；安全模式是「分享單一視窗/分頁」。
對 M3 的直接牽連：M3 決定 overlay **要顯示什麼內容**（三層答案文字）——若 overlay 可能被錄到，則 M3 產生的答案文字有外洩到會議畫面的殘餘風險。
M4 仍會設 `sharingType=.none`（防 legacy 擷取 + Zoom 視窗過濾 + per-window/tab 分享），但**不得宣稱無條件隱形**。
（來源：Apple Developer Forums thread 792152 + tauri #14200，2026-07 查證。實機三情境驗證見 umbrella AC-15，屬 M4/人工 gate。）

### 模型解析：純函式 + 重新驗證 connected

`MeetingCopilotModels.resolve(storedProvider:storedModel:defaultProvider:available:)` 鏡射 `AskAIAnswerModel.resolve`
（`Services/AskAI/AskAIConfig.swift:25-39`）：stored provider 非空且在 `available` 內 → 用它（+ stored model 或 nil）；否則回退
`defaultProvider` + nil model。**M3 額外要求**：`available` 傳入的是 `aiService.connectedProviders` 的 rawValue 集合
（`AIService.swift:234-266`）——若使用者移除了某 provider 的 API key，該 provider 不再 connected，resolve 必須回退預設，
不得用失效 provider 發請求。fast 與 deep 各解析一次。model picker（M5）可重用 `recorderModelChoices` / `RecorderModelChoice`
（`Views/Settings/CategoriesSettingsView.swift:3-22`）。

### `MeetingCopilotConfigStore` 擴充樣式

沿用既有樣式：`@Published private(set) var …` + `…V1` UserDefaults key + `set…()` mutator + `load()`。
新增 8 欄與預設值（承 umbrella SRS「New Settings」表）：`fastProvider`/`fastModel`（Groq `llama-3.1-8b-instant`）、
`deepProvider`/`deepModel`（跟隨全域預設）、`prefetchEnabled`（**true**）、`domainPersona`（後端系統設計／演算法專家）、
`useHistoryRAG`（true）、`useScreenContext`（true）。設定 UI 屬 M5，M3 只加資料層。

---

## Acceptance Criteria（僅本里程碑，AC-5~AC-14）

### AC-5: Tier 0 不呼叫 LLM 且夠快
- **Given**: 一則新 cue
- **When**: `Tier0Classifier` 執行
- **Then**: 產出領域標籤 + 2-3 關鍵字；**全程未發出任何 LLM 請求**；< 0.5s
- **Test**: `Tier0KeywordTests::producesKeywordsWithoutLLMCall`（以 `FakeStreamingChatCompleting` 斷言呼叫次數為 0）

### AC-6: Tier 1 輸出可直接開口的結構
- **Given**: 一則系統設計問題
- **When**: Tier 1 完成
- **Then**: 產出非空 `opener`（單句）+ **恰 3 個** `bullets`（`Tier1Draft`）
- **Test**: `Tier1DraftTests::producesOpenerAndExactlyThreeBullets`

### AC-7: 預跑讓點擊零等待
- **Given**: `prefetchEnabled = true`，一則新 cue 出現後 2 秒
- **When**: 觸發該 cue 的 Tier 1（模擬點擊）
- **Then**: Tier 1 已完成，**立即**可用，`AnswerCoordinator` **不再發新串流請求**
- **Test**: `PrefetchTests::newestCuePrefetchesTier1`（fake streaming 斷言請求次數 == 1）

### AC-8: 兩階段順序與內容傳遞
- **Given**: 一則已完成 Tier 1 的 cue
- **When**: 觸發 Tier 2
- **Then**: Tier 2 的 user message **確實包含** Tier 1 的 `opener` 與 bullets 全文；產出 `followUps[]`（≥1）與 `uncertainties[]`；可取消而不影響已存的 Tier 0/1
- **Test**: `AnswerCoordinatorTests::deepStageReceivesFastDraft`

### AC-9: RAG 接地與其降級
- **Given**: 歷史逐字稿中有相關內容
- **When**: Tier 1 / Tier 2 產生答案
- **Then**: prompt 的 user block 含 `RetrievalService.retrieve` 檢索到的片段；**若索引為空或無 embedding key，靜默跳過且答案照常產出**（不 throw、不中斷、**不 persist 任何 `AskAIMessage`**、不呼叫 `AskAIService.ask`）
- **Test**: `GroundingTests::ragInjectedWhenAvailableAndSkippedSilentlyWhenNot`

### AC-10: 螢幕上下文只在 Tier 2 擷取
- **Given**: `useScreenContext = true`
- **When**: Tier 0 / Tier 1 執行
- **Then**: **不**呼叫 `ScreenCaptureService.captureAndExtractText()`（不拖慢首字延遲）；Tier 2 啟動時**只擷取一次**；OCR 回 nil 時靜默跳過
- **Test**: `GroundingTests::screenContextOnlyOnDeepStage`（以 fake `ScreenCaptureService` 斷言 Tier0/1 期間呼叫次數 0、Tier2 為 1）

### AC-11: SSE 逐字串流（OpenAI-compat parser）
- **Given**: fake SSE server（`URLProtocol` 注入）回 3 個 `data: {"choices":[{"delta":{"content":"…"}}]}` frame + `data: [DONE]`
- **When**: `AIService.streamChat` 走 OpenAI-compat（default）分支
- **Then**: `AsyncThrowingStream` 依序吐出 3 段 delta；`AIEnhancementOutputFilter` **在串流結束後才對完整累積字串套用一次**（非逐 delta）
- **Test**: `StreamingChatClientTests::openAIParserEmitsDeltasInOrder`

### AC-12: Anthropic parser 逐 delta
- **Given**: fake SSE server 回 `event: content_block_delta` + `data:{"type":"content_block_delta","delta":{"type":"text_delta","text":"…"}}` 三對，終止 `event: message_stop`（**無 `[DONE]`**）
- **When**: `AIService.streamChat` 走 `.anthropic` 分支
- **Then**: 依序吐出 3 段 `delta.text`；auth header 為 `x-api-key` + `anthropic-version: 2023-06-01`（非 Bearer）；system 為 top-level 欄位；**未注入** `reasoning_effort`/extraBody
- **Test**: `StreamingChatClientTests::anthropicParserEmitsTextDeltasAndTerminatesOnMessageStop`

### AC-13: 失敗必須靜默且逐層降級
- **Given**: Tier 2 的 LLM 串流拋出（fake 注入 `.http(500, …)`）
- **When**: 失敗發生
- **Then**: **不**出現任何 modal / 系統通知、**不**呼叫 `NotificationManager.showNotification`；Tier 1 草稿仍在；`AnswerCoordinator` 標記 Tier 2 失敗但保留 Tier 0/1。RAG / OCR 失敗同理靜默、答案照出
- **Test**: `FailureDegradationTests::deepFailureKeepsFastDraftAndEmitsNoVisibleUI`

### AC-14: 不得編造
- **Given**: 一則模型無把握的問題
- **When**: Tier 2 完成
- **Then**: system prompt 含明確禁止捏造 benchmark 數字／論文名／公司名的禁令；模型無把握的點出現在 `uncertainties[]`
- **Test**: `PromptContractTests::deepSystemPromptForbidsFabrication`（斷言 Tier 2 system prompt 含禁令字串）+ 人工抽查

> **端到端 replay（umbrella AC-14）**跨 M2+M3：`ReplayMeetingAudioSource`（M1）→ cue（M2）→ 三層（M3）→ 落 SwiftData。
> M3 以 `FakeStreamingChatCompleting`（腳本化 delta）+ fake grounding 參與該 harness，斷言「Tier 0 有關鍵字 → Tier 1 預跑出 `opener`+3 bullets → 點擊後 Tier 2 收到草稿產出 `followUps[]`」。

---

## Open Questions

- [ ] 串流過程是否要在 `<think>/<thinking>/<reasoning>` 標籤內**緩衝**（避免把 reasoning raw emit 到未來 M4 overlay），還是 raw emit、只在最終字串套 filter？
      非串流 `completeChat` 對整包套一次 filter 隱藏了 reasoning（`AIEnhancementOutputFilter.swift:3-21`）；M3 若 raw emit 可能短暫顯示 reasoning。傾向：在 tag 內緩衝，見到閉合 tag 才放行。
- [ ] Tier 1 / Tier 2 的**結構化解析策略**：要求模型回 JSON（`opener`/`bullets`/`analysis`/`followUps`/`uncertainties`）再解析，還是回帶標記的純文字逐段解析？串流下 JSON 未收完難以 partial render——傾向：Tier 1 用可容忍 partial 的輕量標記格式，Tier 2 收完再解析 JSON。
- [ ] Tier 0 的領域關鍵字表從何而來？（手寫種子表 / 從歷史 `EmbeddingChunk` 自動聚類 / 兩者混合。）傾向：手寫後端＋演算法種子 + `EmbeddingChunk` 相似度補強。
- [ ] RAG 是否需要**相關性下限**過濾？`RetrievalService.retrieve` 無 threshold、永遠回 top-k（`RetrievalService.swift:70`），語意無關時也會塞進 prompt。是否對 `ScoredChunk.score` 設 floor？
- [ ] RAG 的 `k` 值？Ask AI 用 `k=12`（`AskAIService.swift:128`）；會議即時場景可能要更小以省 prompt token。
- [ ] Tier 1 預跑的**觸發時機**與**取消策略**：新 cue 進來時是否取消前一則未完成的預跑？多則 cue 快速連續出現時只保最新一則的預跑（成本控制）。
- [ ] Anthropic `max_tokens`：`completeChat` 路徑用預設 8192（`AnthropicLLMClient.swift:223`）；Tier 1（短開口稿）是否該調小以降延遲/成本？
- [ ] 螢幕 OCR 的目標視窗限制：是否需要一個「指定目標視窗」的 `ScreenCaptureService` 變體，讓使用者切到別的 app 時仍 OCR 會議視窗？（現無此 API，屬額外工程；M3 暫接受「只抓前景 focused 視窗」。）
