---
linear_issue: null
---
# SRS: Meeting Copilot **M2 — Live cue detection engine**（cue 偵測引擎）

> 這是 umbrella SRS **`docs/srs/meeting-copilot-live-assist.srs.md`** 的 **M2 里程碑切片**。
> umbrella 描述整個 meeting-copilot 模組（34 FR / 19 AC / 五個 store 段落 / overlay / 三層回應）；
> 本文件只涵蓋 **M2**：從對方 committed 逐字稿偵測「需要我回應的東西」、四分類、去重、持久化。
> **不含** LLM 串流回答（Tier 1/2 = M3）、**不含** UI／頁面（M5）、**不含** overlay／熱鍵（M4）。
> 上游 M1（音訊分流骨幹，build 248）**已實作完成並 commit**——本切片以它交付的
> `MeetingLiveTranscriber.onRemoteCommitted` 為唯一接點，不重做任何 M1 元件。

## Metadata
- **Module**: `meeting-copilot`（新模組）
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Umbrella SRS**: `docs/srs/meeting-copilot-live-assist.srs.md`（本文件為其 M2 切片）
- **Source PRD**: N/A（2026-07-12 使用者需求，承接 umbrella SRS）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-12
- **Grill level**: 1 (standard)
- **Milestone**: M2 — Live cue detection engine（依賴鏈 M2 → M3 → M4 → M5 之首）
- **Target build**: 249（`CURRENT_PROJECT_VERSION`，Debug + Release 兩處）

## Feature Summary

M1 已把會議音訊分成「對方」與「我」兩條獨立串流即時轉錄，並在**對方**每產生一段 committed 逐字稿時
呼叫 `MeetingLiveTranscriber.onRemoteCommitted`（`Services/MeetingCopilot/MeetingLiveTranscriber.swift:48,128`）。

M2 在這個接點上，用一個 **fast model 的非串流呼叫**（`AIService.completeChat`，回結構化 JSON）從對方
committed 片段抽出 **response cue**——「需要我回應的東西」——並**四分類**為
`directQuestion` / `impliedChallenge` / `assignedToMe` / `informational`。抽出的 cue 經**字面去重**後
持久化到新的 SwiftData store `meeting.store`，並以 `@Published` 陣列暴露給下游（M3/M4）消費。

本切片的**設計核心**（承 umbrella「抓需要我回應的東西，不只抓問號」）：真實會議裡需要回應的往往是
**陳述句**（「我對這個 schema 的效能有點擔心」），只抓問號會漏掉最需要接的一半。因此 cue 偵測是一次
**LLM 語意分類**，而非正規表達式抓 `?`。**這正是 umbrella AC-4 的驗收重點。**

M2 是純**引擎層**：它偵測與持久化，但不呈現、不回答、不串流。它的所有輸出（committed cue + 分類）
是 M3 三層回應引擎的唯一輸入。

---

## Delta from Current Module State

> 見 `docs/spec/meeting-copilot.spec.md` 與 umbrella SRS。以下為 **M2 專屬**增量；M1 交付面不重列。

### New Data Models（新 store：`meeting.store`，`cloudKitDatabase: .none`）

沿用 umbrella「New Data Models」段落，但 M2 只實作 cue 偵測所需欄位；tier1/tier2 欄位**一併宣告以避免
M3 再做一次 migration**，但 M2 完全不寫入它們（每欄都有預設值，符合 lightweight-migration 慣例）。

- **NEW** `MeetingLiveSession`（`@Model`，`Models/MeetingLiveModels.swift`，new file）：
  `{ id: UUID, startedAt: Date, endedAt: Date?, appName: String, brief: String,
     remoteTranscriptRaw: String, localTranscriptRaw: String, cues: [MeetingLiveCue]? }`
  父端宣告 `@Relationship(deleteRule: .cascade, inverse: \MeetingLiveCue.session) var cues: [MeetingLiveCue]? = []`
  ——**OPTIONAL 陣列、預設 `[]`**，鏡射 `AskAIThread.messages`（`Models/AskAIModels.swift:41-512`，見 `@Relationship(deleteRule: .cascade, inverse: \AskAIMessage.thread)`）。
- **NEW** `MeetingLiveCue`（`@Model`，同檔）：
  `{ id: UUID, session: MeetingLiveSession?, text: String, kindRaw: String, askedAt: Date,
     contextExcerpt: String, statusRaw: String,`
  （以下為 M3 欄位，M2 宣告但不寫入）
  `  tier0Keywords: String, tier1Opener: String, tier1BulletsRaw: String,
     tier2Analysis: String, tier2FollowUpsRaw: String, tier2UncertaintiesRaw: String,
     fastModelName: String, deepModelName: String, answeredAt: Date? }`
  子端 `var session: MeetingLiveSession?` 是**裸的可選反向參照，無 `@Relationship` 屬性**
  （非對稱 cascade 語法，鏡射 `AskAIMessage.thread`，`Models/AskAIModels.swift:518`）。
- **列舉存取器（String-in-raw 慣例）**：
  - `kind: MeetingCueKind`（`enum MeetingCueKind: String { case directQuestion, impliedChallenge, assignedToMe, informational }`）
    以 computed get/set 包住 `kindRaw`，鏡射 `AskAIMessage.role` 的裸 String 欄位模式（`Models/AskAIModels.swift:519`）。
  - `status`（例：`detected` / `answered`）同理包住 `statusRaw`；M2 僅寫入初始 `detected`。
- **陣列欄位（JSON-in-raw-String + `@Transient` 快取）**：M2 不寫入這些欄位，但宣告時沿用 repo 慣例
  ——`…Raw: String` 存 JSON、非持久化 computed `[…]` get/set、加一組 `@Transient` `cacheRaw`+`cacheValue`
  keyed on raw string（鏡射 `Transcription.speakerSegments`，`Models/Transcription.swift:73-121`；
  簡化無快取版見 `AskAIMessage.citations`，`Models/AskAIModels.swift:533-545`）。

> **為何開第 5 個 store**：承 umbrella 決定。`default.store` 持有使用者全部 `Transcription` 歷史；本模組
> schema 初期必然反覆調整，獨立 store 檔案不可能破壞 `default.store` 的 migration，崩壞時可整檔刪除重來。
> 先例：`index.store`（Ask AI）。M2 是全模組**第一個**寫 `meeting.store` 的里程碑，故三處 schema 註冊
> 由本切片負責（見下）。

### Changed Business Logic

- **`MeetingCopilotController`（new，`Services/MeetingCopilot/MeetingCopilotController.swift`）— MVP**：
  在建立 `MeetingLiveTranscriber` 後把自己掛上 `onRemoteCommitted`（`MeetingLiveTranscriber.swift:48`）。
  每次回呼 → 呼叫 `ResponseCueExtractor` 抽 cue → 去重 → persist 到 `meeting.store`（經 `mainContext`）→
  更新 `@Published private(set) var cues: [MeetingLiveCue]`。`copilotEnabled == false` 時不掛回呼、不抽 cue。
- **`ResponseCueExtractor`（new，`Services/MeetingCopilot/ResponseCueExtractor.swift`）**：
  取代 umbrella 提及的假想 `QuestionExtractor`。以 **fast model 的一次非串流呼叫**
  （透過既有 `ChatCompleting` seam，見下）從 committed 片段抽出 cue **並**四分類，回結構化 JSON。
  prompt 建構為**純函式**（FR-12），可單元測試。JSON 解析失敗 → 回 `[]`（靜默，不產生 cue、不報錯，
  沿用 repo `try? JSONDecoder` 容錯慣例）。
- **去重（FR-10）**：純函式，正規化後 **Jaccard 相似度 + 30 秒時間窗**。新 cue 與時間窗內既有 cue 比對，
  超過門檻即丟棄，不 persist。
- **informational 過濾（FR-11）**：`informational` cue **仍被 persist**（不遺失，供事後回顧），但
  `MeetingCopilotController.cues` 在 `showInformationalCues == false`（預設）時**不**把它納入 `@Published`
  暴露面。呈現與否的最終 UI 由 M4/M5 決定；M2 只保證引擎層預設隱藏。

### New / Changed API

- **`meeting.store` 三處 SwiftData 註冊**（clone `index.store` block；漏任一處 → launch 時 container init
  throw → fallback 亦 throw → `fatalError`。canon §3.5）：
  1. master `Schema([...])`（`VoiceInk.swift:48-57`）末端 append `MeetingLiveSession.self, MeetingLiveCue.self`。
  2. `createPersistentContainer`（`VoiceInk.swift:245-386`）：新增 `meetingStoreURL` + `meetingSchema` +
     `ModelConfiguration("meeting", schema: meetingSchema, url: meetingStoreURL, cloudKitDatabase: .none)`，
     並 append `meetingConfig` 到 variadic `ModelContainer(for: schema, configurations: …)`（`:381`）。
     **完全照抄 index.store 段落**（`VoiceInk.swift:371-378`）。
  3. `createInMemoryContainer`（`VoiceInk.swift:302-414`）：同上，但 `isStoredInMemoryOnly: true`、無 url／cloudKit，
     append `meetingConfig` 到 configurations（`:409`）。
- **cue 抽取的 LLM seam**：**重用**既有協定 `ChatCompleting`（`Services/AskAI/AskAIService.swift:6-8`：
  `func complete(system: String, user: String) async throws -> String`）作為可注入測試 seam。
  正式實作是一個薄 adapter，把 `complete(system:user:)` 轉呼叫
  `AIService.completeChat(provider:modelName:messages:[.user(user)]:systemPrompt:system:timeout:)`
  （`Services/AIEnhancement/AIChatCompletionService.swift:4-77`；`ChatMessage.user` 見 LLMkit
  `Sources/LLMkit/LLM/ChatMessage.swift:19`）。測試注入 `FakeChatCompleting`（腳本化 JSON 回應）。
- **`MeetingCopilotConfigStore` 擴充**（`Services/MeetingCopilot/MeetingCopilotConfigStore.swift`，M1 現有三項
  `copilotEnabled` / `asrModelName` / `transcribeLocalMic`，行 17-79）：M2 新增
  - `fastProvider: String?` / `fastModel: String?`（cue 抽取用的 fast model；沿用 `@Published private(set)` +
    `…V1` key + `set…()` mutator + `load()` 樣式）。
  - `showInformationalCues: Bool = false`（FR-11 預設隱藏）。
  設定**UI 屬 M5**；M2 只加 store 欄位與預設值（不進 `AppDefaults.registerDefaults`，比照
  `RecorderConfigStore` 在 `load()` 內硬寫預設）。
- **fast model 解析**：正式 adapter 以既有純函式 `AskAIAnswerModel.resolve(storedProvider:storedModel:defaultProvider:available:)`
  （`Services/AskAI/AskAIConfig.swift:25-39`）解析 `fastProvider/fastModel`，並**重新驗證 stored provider
  仍在 `aiService.connectedProviders` 內**，否則回退預設。（umbrella 之 `MeetingCopilotModels.resolve`
  是 M3 才正式引入的專屬純函式；M2 先借用 `AskAIAnswerModel.resolve` 以免臆造簽章——見 Open Questions。）

### Explicitly Out of Scope（本切片明確不做）

- **Tier 0 / Tier 1 / Tier 2 任何回應生成**——含關鍵字表、embedding 相似度、SSE 串流、opener/bullets/analysis。
  cue 的 `tier*` 欄位在 M2 一律留白。（M3）
- **SSE 串流 client**。M2 的 cue 抽取回**結構化 JSON**，用**非串流** `completeChat` 即可；不需要逐字顯示，
  故不建 `StreamingChatClient`、不觸 LLMkit 的 private request/response struct（canon §3.3、§3.4）。（M3）
- **RAG／螢幕接地**。M2 不呼叫 `RetrievalService` / `LiveEmbedder` / `ScreenCaptureService`
  ——且依 canon §3.2，未來 M3 接地**絕不可**走 `AskAIService.ask()`（它會 persist 可見診斷訊息、非靜默路徑）。（M3）
- **Overlay、熱鍵、`sharingType=.none`**。（M4；但其風險於本文件末段被明確點名，見 Risks）
- **側欄頁面、設定 UI、雙軌逐字稿檢視、cue 顯示樣式**。（M5）
- **既有元件行為改動**：不動 `MeetingCaptureService` 落檔、`MeetingChannelSplitter`、`PCMDownsampler`、
  `MeetingLiveTranscriber` 本體（只掛既有的 `onRemoteCommitted` closure）。

---

## Functional Requirements

> 只列 **M2** 的 FR（umbrella 對應 FR-8 ~ FR-12）。其餘 umbrella FR 屬 M1（已完成）／M3／M4／M5。

### Cue 偵測
- [ ] **FR-8** `ResponseCueExtractor` 於 remote 流每個 `.committed` 片段觸發（掛 `MeetingLiveTranscriber.onRemoteCommitted`，
      建議 debounce），以 fast model **一次非串流呼叫** `completeChat` 完成**抽取 + 四分類**
      （`directQuestion` / `impliedChallenge` / `assignedToMe` / `informational`），回結構化 JSON。
- [ ] **FR-9** 陳述句形式的**質疑與指派必須**被偵測，**不得只抓問號**（例：「我對這個寫入效能有點擔心」→ `impliedChallenge`；
      「這塊 Logan 你來說明一下」→ `assignedToMe`）。**這是 umbrella AC-4 的核心。**
- [ ] **FR-10** 去重（純函式）：正規化後 Jaccard 相似度 + 30 秒時間窗；相似 cue 不重覆 persist。
- [ ] **FR-11** `informational` 類 cue 仍 persist，但引擎層預設**不**納入 `MeetingCopilotController.cues` 暴露面
      （`showInformationalCues` 預設 false，可切換）。
- [ ] **FR-12** cue 抽取 + 四分類的 **prompt 建構為純函式**（不觸 UserDefaults／網路），可單元測試。

### 持久化（本切片實作，支撐 FR-8~FR-12）
- [ ] **FR-M2-P1** `MeetingLiveSession` / `MeetingLiveCue` 兩個 `@Model` 定義於 `meeting.store`；每個屬性有預設值；
      父子為 `.cascade` 關係（刪 session 連帶刪 cue）。
- [ ] **FR-M2-P2** `meeting.store` 完成**三處** schema 註冊（master `Schema` + persistent + in-memory container），
      app 啟動時 container 正常建立、不 `fatalError`。
- [ ] **FR-M2-P3** `MeetingCopilotController` 接 `onRemoteCommitted` → 抽 cue → 去重 → persist 到 `mainContext`
      → 更新 `@Published cues`；`copilotEnabled == false` 時完全不動作。

---

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| **成本** | cue 抽取只用 fast model、每 committed 片段一次呼叫 | 抽取 + 四分類**合併為單次** `completeChat`（非兩趟）；debounce 減少呼叫頻率 |
| **延遲** | cue 抽取不阻塞轉錄／落檔 | 抽取在獨立 `Task` 內 await；`onRemoteCommitted` 立即返回；持久化才 hop 回 `@MainActor` |
| **正確性** | 陳述句質疑不得漏抓 | 以 LLM 語意分類取代問號正則；AC-4 把關 |
| **韌性** | LLM／JSON 失敗不得中斷 | 抽取失敗回 `[]`，不 persist、不報錯、不跳 UI（沿用 `try? JSONDecoder` 容錯） |
| **隱私** | cue 與逐字稿僅存本機 | `meeting.store`，`cloudKitDatabase: .none` |
| **可測性** | 完整偵測鏈可離線斷言 | `ChatCompleting` seam 注入 fake LLM；M1 `ReplayMeetingAudioSource` + `FakeMeetingTranscriptStream` 驅動 |
| **遷移安全** | schema 演進不損逐字稿 | 獨立 `meeting.store`（可整檔重建）；每欄有預設值；tier 欄位預先宣告避免 M3 migration |
| **相容性** | M1 音訊路徑零回歸 | 只掛既有 `onRemoteCommitted` closure，不改 `MeetingLiveTranscriber` 本體與擷取端 |

---

## Architecture Notes

### 掛載點與資料流（M2 範圍）

```
MeetingLiveTranscriber (M1, @MainActor)
  remote 流 .committed
        │  onRemoteCommitted?(text)              ← MeetingLiveTranscriber.swift:48,128
        ▼
MeetingCopilotController (new, @MainActor)
        │  Task { await extractor.extract(committed:) }   （離開 main，等 LLM）
        ▼
ResponseCueExtractor (new)
        │  buildPrompt(committed:, context:) → (system, user)   ← 純函式 (FR-12)
        │  ChatCompleting.complete(system:user:)                ← AskAIService.swift:6-8
        │     └─ live adapter → AIService.completeChat(...)     ← 非串流，回 JSON
        │  parse JSON → [ExtractedCue{ text, kind }]            ← try? JSONDecoder，失敗回 []
        ▼
MeetingCopilotController（hop 回 @MainActor）
        │  dedup（Jaccard + 30s 窗，純函式，FR-10）
        │  persist → MeetingLiveCue 插入 mainContext（meeting.store）
        │  更新 @Published cues（informational 依 showInformationalCues 過濾，FR-11）
        ▼
   下游（M3 Tier 回應 / M4 overlay / M5 頁面）消費
```

### LLM 呼叫：為何非串流、為何不碰 SSE

cue 抽取的輸出是**結構化 JSON**（cue 陣列 + 四分類），使用者**看不到**這段中間產物——它只是餵給 M3 的
資料。因此不需要逐 token 顯示，**非串流 `completeChat` 正合適**。canon §3.4 指出 LLMkit 的 request/response
struct 全 `private`、不可重用，且自持 SSE client 有維護負擔；M2 完全避開這條路——SSE 屬 M3（Tier 1/2 才需要
逐字揭露）。M2 只透過既有 `ChatCompleting` seam 呼叫 `completeChat`，換 fast model 即可。

### 講者歸屬承 M1，M2 零 diarization

cue **只**從 remote 流（對方）抽——local 流（我）不進 `ResponseCueExtractor`。「這句是對方說的」在 M1
已是結構上 100% 準確（依串流來源，非 diarization）。M2 不重新判斷講者。

### Threading

`MeetingLiveTranscriber` 與 `onRemoteCommitted` 在 `@MainActor`（`MeetingLiveTranscriber.swift:20`）。
`completeChat` 是 `async`，可在 background `Task` 中 await（網路往返不佔 main）；但 SwiftData `ModelContext`
非 Sendable，**持久化必須 hop 回 `@MainActor` 用 `mainContext`**（`mainContext` 橫跨全部 store，含新
`meeting.store`）。此紀律與 recon-rag「embed off-main → 回 MainActor 操作 context」一致。

### 持久化樣式（照抄既有）

- **cascade 關係**：父 `@Relationship(deleteRule:.cascade, inverse:\Child.parent) var children:[Child]? = []`
  + 子裸 `var parent: Parent?`（非對稱，鏡射 `AskAIThread`/`AskAIMessage`，`Models/AskAIModels.swift:501-545`）。
- **String-in-raw 列舉**：`kindRaw: String` + computed `kind: MeetingCueKind`（鏡射 `AskAIMessage.role`）。
- **JSON-in-raw + `@Transient` 快取**（tier 欄位，M2 宣告不寫）：鏡射 `Transcription.speakerSegments`
  （`Models/Transcription.swift:73-121`），`@Transient` 欄位一律要預設值。
- **config store**：`@Published private(set)` + `private let …V1` key + `set…()` mutator + `load()`，
  鏡射 `RecorderConfigStore`（recon-nav-persist）與現有 `MeetingCopilotConfigStore`（行 17-79）。

### 離線驗證骨架（承 M1）

M2 端到端測試**不開任何會議軟體、不開 CoreAudio、不打真 LLM**：
`ReplayMeetingAudioSource`（M1，讀 WAV）→ splitter/downsampler（M1）→ `FakeMeetingTranscriptStream`
（M1，`Services/MeetingCopilot/MeetingTranscriptStream.swift:102,129,146-148`，`finish()` 吐腳本化
`.committed`）→ `MeetingLiveTranscriber.onRemoteCommitted` → `MeetingCopilotController` +
`ResponseCueExtractor(chat: FakeChatCompleting)`（腳本化 JSON）→ 斷言 cue 抽出／分類／去重／persist。

---

## Acceptance Criteria

### AC-1: 四分類抽取，且**陳述句質疑必須被偵測**（realizes umbrella AC-4）
- **Given**: remote committed 出現三句——「你會怎麼設計一個短網址服務？」、「我對這個寫入效能有點擔心」（無問號）、「我們上週上線了 v2」
- **When**: `ResponseCueExtractor.extract(committed:)`（注入的 fake `ChatCompleting` 回對應 JSON）
- **Then**: 產生三則 cue，`kind` 分別為 `.directQuestion`、`.impliedChallenge`、`.informational`；**第二句的陳述句質疑不得被漏抓**
- **Test**: `ResponseCueExtractorTests::detectsStatementFormChallenge`

### AC-2: 抽取 + 分類為單次 LLM 呼叫（非串流）
- **Given**: 一段對方 committed 文字
- **When**: `ResponseCueExtractor.extract` 執行
- **Then**: `ChatCompleting.complete` **恰被呼叫一次**（抽取與四分類同一趟，未分兩趟、未走任何 SSE 路徑）
- **Test**: `ResponseCueExtractorTests::extractionIsSingleNonStreamingCall`（fake 記錄呼叫次數）

### AC-3: prompt 為純函式
- **Given**: 相同的 committed 文字與上下文
- **When**: 呼叫 `ResponseCueExtractor.buildPrompt(...)`
- **Then**: 回傳固定的 `(system, user)` 字串，過程不讀 UserDefaults／不發網路；system prompt 含四分類定義
- **Test**: `ResponseCueExtractorTests::promptIsPureAndDeterministic`

### AC-4: 去重（Jaccard + 30 秒窗）
- **Given**: 30 秒內先後出現兩句正規化後高度相似的 committed（例：「你會怎麼設計 rate limiter？」與「你會怎麼設計一個 rate limiter？」）
- **When**: 兩次抽取皆產生 cue，`MeetingCopilotController` 依序處理
- **Then**: 只 persist 一則 cue；第二則因超過相似度門檻被丟棄
- **Test**: `MeetingCopilotControllerTests::dedupesSimilarCuesWithinWindow`

### AC-5: informational 預設隱藏但仍持久化
- **Given**: `showInformationalCues == false`，抽出一則 `.informational` cue
- **When**: `MeetingCopilotController` 處理
- **Then**: 該 cue **有** persist 到 `meeting.store`（可事後查回），但**不**出現在 `@Published cues`；把 `showInformationalCues` 設為 true 後即出現
- **Test**: `MeetingCopilotControllerTests::informationalPersistedButHiddenByDefault`

### AC-6: cue 持久化與 cascade 刪除
- **Given**: 一個 `MeetingLiveSession` 掛三則 `MeetingLiveCue`
- **When**: 刪除該 session
- **Then**: 三則 cue 隨 `.cascade` 一併刪除；`meeting.store` 內無殘留孤兒 cue
- **Test**: `MeetingLiveModelsTests::deletingSessionCascadesCues`

### AC-7: 三處 schema 註冊，container 正常建立
- **Given**: master `Schema` 含 `MeetingLiveSession`/`MeetingLiveCue`，且兩個 container func 皆註冊 `meetingConfig`
- **When**: app 啟動（或測試建 in-memory container）
- **Then**: `ModelContainer` 建立成功、可插入/查詢 `meeting.store`，**不** `fatalError`
- **Test**: `MeetingStoreRegistrationTests::inMemoryContainerBacksMeetingStore`

### AC-8: 端到端 replay（不開會議軟體、不打真 LLM）
- **Given**: `ReplayMeetingAudioSource` + `FakeMeetingTranscriptStream` 腳本化三種 committed（直接問句／陳述句質疑／純資訊）、`ResponseCueExtractor` 注入 fake `ChatCompleting`
- **When**: 用 `MeetingCopilotController` 跑完整偵測鏈（`copilotEnabled == true`）
- **Then**: 三種 cue 皆被抽出且分類正確 → 去重後全部 persist 到 `meeting.store` → `@Published cues` 含應顯示者（informational 依設定過濾）
- **Test**: `MeetingCueDetectionReplayTests::endToEndFromWavPersistsClassifiedCues`

### AC-9: kill switch
- **Given**: `copilotEnabled == false`
- **When**: remote 流產生 committed
- **Then**: `ResponseCueExtractor` **未**被呼叫、`meeting.store` **無**新 cue、`@Published cues` 為空
- **Test**: `MeetingCopilotControllerTests::disabledCopilotExtractsNothing`

---

## Risks & Trade-offs

| 風險 | 可能性 | 影響 | 緩解 |
|---|---|---|---|
| **本機 FluidAudio ASR 無術語偏置**（canon §3.8）→ 專案代號／服務名轉錯（「Kafka」→「咖啡卡」）→ **cue 抽取的輸入本身失真、分類失準** | **H** | M | M2 無法修 ASR；此為輸入品質風險。cue 抽取須對雜訊 tolerant；設定頁（M5）明示取捨；需要術語準確者選雲端 ASR（M1 已接 `getCustomVocabularyTerms()`） |
| 漏掉三處 schema 註冊任一處 → launch `fatalError`（canon §3.5） | M | **H** | **完全照抄 `index.store` block**；AC-7 in-memory container 測試把關；compile gate + host 測試各跑一次 |
| fast model 把陳述句質疑漏判成 `informational` → 需要接的話沒被偵測 | M | **H**（功能核心價值） | prompt 明列四分類定義與陳述句範例（FR-12 純函式可迭代調校）；AC-1/AC-4 把關；門檻與滑窗大小列 Open Questions |
| Jaccard 去重門檻過鬆漏刪、過嚴誤刪不同問題 | M | M | 門檻可調；不夠用時升級語意去重（Open Questions）；AC-4 覆蓋基本情境 |
| cue 抽取 LLM 呼叫過於頻繁 → token 成本 | M | M | debounce committed；只用 fast model；單次呼叫合併抽取＋分類 |
| **🔴 跨里程碑（M4）：`sharingType=.none` 在 macOS 15.4+ 被 ScreenCaptureKit 忽略**（canon §3.1；Apple DTS 明言目前無公開 API 可防螢幕擷取；Chrome/Google Meet `getDisplayMedia` 走 SCK）。**分享整個螢幕**時 M4 的 overlay 會被錄到；安全模式僅限「分享單一視窗/分頁」。 | **H**（分享整螢幕時幾乎必然） | **H** — 整個 meeting-copilot 的「隱蔽呈現」前提取決於此 | **不在 M2 範圍**，但**在此明確點名**：M2 持久化的 cue 一旦在 M4 顯示於 overlay，其隱蔽性受此限制。M4 的 SRS/plan 必須把它寫成明確風險 + UI 警告，**不得宣稱無條件隱形**（來源：Apple Developer Forums thread 792152 + tauri #14200，2026-07 查證） |

---

## Open Questions

- [ ] **fast model 解析歸屬**：M2 借用 `AskAIAnswerModel.resolve`（`AskAIConfig.swift:25-39`）解析 `fastProvider/fastModel`，
      還是提前引入 umbrella 規劃於 M3 的專屬 `MeetingCopilotModels.resolve`？傾向：M2 先借用既有純函式（不臆造簽章），
      M3 再抽出專屬版並回頭替換——plan 定。
- [ ] **cue 抽取的滑動窗大小**（幾句／幾秒 committed 一起餵給 fast model）？單句往往缺上下文（代名詞、被指派對象），
      需以真實會議逐字稿調校。M2 先取合理預設，列為可調。
- [ ] **去重門檻**：正規化 Jaccard 的具體門檻值？何時升級為模型語意去重（成本 vs 準確）？
- [ ] **debounce 策略**：`onRemoteCommitted` 高頻觸發時，是逐 committed 抽取，還是累積 N 秒／N 句一次抽取？
      影響延遲與 token 成本，需與 M3 的「最新一則預跑 Tier 1」節奏對齊。
- [ ] **JSON 契約細節**：fast model 回的 cue 陣列 schema（欄位名、是否附信心分數、是否附原句 span）由 plan 固定，
      並在 `ResponseCueExtractorTests` 以 golden JSON 鎖定。
- [ ] **tier 欄位宣告 vs M3 再加**：M2 是否真要預先宣告全部 tier1/tier2 欄位？獨立 `meeting.store` 可整檔重建，
      M3 才加欄位其實無 migration 風險；預宣告的好處僅是 schema 一次到位。plan 定。

---

## 倫理與合規（承 umbrella，不可省略）

M2 會**持續把會議中其他人的話**送入 fast model 做 cue 抽取，並**持久化**對方逐字稿與抽出的 cue 於本機。

- 錄音／處理他人語音在許多司法管轄區受法律規範（雙方同意制），在所有場合都是基本禮貌。
- 本模組**不**繞過、**不**偽裝、**不**對抗任何會議平台的錄製通知機制。
- `meeting.store` 以 `cloudKitDatabase: .none` 僅存本機，不上傳。
- 使用者需自行確保在其會議情境下的使用被允許。

### 使用情境與設計意圖

本模組是維護者自用於**公司協作會議**的個人輔助工具。維護者有 ADHD，並在高壓情境下有選擇性失憶——高強度、
高壓力的會議中容易當場腦袋空白，一時想不起自己其實熟悉的程式架構與技術細節。cue 偵測 + 三層漸進揭露（尤其
「開口稿」）的目的是**幫我回憶我本來就知道的東西**、在被追問時爭取幾秒開口與思考的時間，避免被會議節奏擊潰。
它輔助的是**「想起」**，不是提供我不懂的知識——事實來源是我自己的歷史逐字稿與筆記。overlay 的隱蔽服務的是
「不想公開自己在用輔助工具」這個**個人隱私**（如同不必向同事揭露身心狀況或無障礙輔具），是隱私而非欺瞞。
