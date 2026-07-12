---
linear_issue: null
---
# Plan: Meeting Copilot M2 — Live cue 偵測引擎 + meeting.store 持久化

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type`。**Mode B（任務先測）**：每個 task 先寫一個鎖行為的測試 → 實作 → 通過 → commit。**Rigor: strict** — 測試 gate 全強制（新 SwiftData store 註冊漏一處 = launch `fatalError`；cue 分類錯 = 整個模組的核心價值失效）。
>
> **⚠️ Task 1 + Task 2 擋在 Task 6 之前。** `meeting.store` 的三處 schema 註冊（canon §3.5）漏任何一處，app 啟動就 `fatalError("VoiceInk failed to initialize storage.")`——先把 store 釘死再寫 controller。
>
> **Checkbox states:** `- [ ]` todo · `- [~]` in-progress · `- [x]` done。`[~]` 不是完成。

## Summary

在 M1 交付的接點 `MeetingLiveTranscriber.onRemoteCommitted`（`MeetingLiveTranscriber.swift:48,128`）上，建立 cue 偵測引擎：每當「對方」有一段 committed 逐字稿，用 **fast model 的一次非串流呼叫**（既有 `ChatCompleting` seam → `AIService.completeChat`，回結構化 JSON）抽出「需要我回應的東西」並四分類（`directQuestion` / `impliedChallenge` / `assignedToMe` / `informational`），經正規化 Jaccard + 30 秒時間窗去重後，持久化到**新的第 5 個 SwiftData store `meeting.store`**（`MeetingLiveSession` + `MeetingLiveCue`，clone `index.store` 的三處註冊），並以 `@Published cues` 暴露給下游（informational 預設隱藏但仍持久化）。

M2 不含 LLM 串流回答（Tier 1/2 = M3）、不含 overlay／熱鍵（M4）、不含頁面／設定 UI（M5）。M2 的交付是：**用 M1 的 replay harness + fake LLM，離線斷言三種 cue（含無問號的陳述句質疑）被抽出、分類正確、去重、persist——不開會議軟體、不打真 LLM。**

## User Story

As a 開會時需要即時輔助的使用者, I want 系統即時偵測「對方說了什麼需要我回應的東西」——包括沒有問號的質疑與點名指派——並持久化下來, so that 後續的三層回應（M3）與 overlay（M4）有結構化、已分類、不重覆的 cue 可以消費。

## Problem → Solution

M1 之後我們有了「對方」的即時逐字稿流，但它只是一條字串流：哪些話需要我接、哪些只是資訊，完全沒有結構。真實會議裡最需要接的話往往是**陳述句**（「我對這個 schema 的效能有點擔心」）——用正規表達式抓問號會漏掉最關鍵的一半（umbrella AC-4）。
→ 用 fast model 做**一次性的語意抽取＋四分類**（非串流、回 JSON、失敗靜默回 `[]`），字面去重後存進獨立的 `meeting.store`。講者歸屬承 M1（cue 只從 remote 流抽，零 diarization），LLM seam 重用 Ask AI 已驗證的 `ChatCompleting`，持久化樣式照抄 `AskAIThread`/`AskAIMessage` 與 `index.store` 註冊塊——**M2 沒有任何新發明的基礎設施**。

## Metadata
- **Module**: meeting-copilot
- **Parent Plan**: `docs/plans/meeting-copilot-m1-audio-backbone.plan.md`（M1，已完成，build 248）
- **Source PRD**: N/A
- **Source Feature SRS**: `docs/srs/meeting-copilot-m2-cue-detection.srs.md`（umbrella `meeting-copilot-live-assist.srs.md` 的 M2 切片）
- **Source Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source Linear Issue**: N/A（`docs/prp.config.yml` → `skip: true`）
- **Type**: feature ｜ **Size**: L ｜ **Complexity**: Large
- **Rigor**: strict ｜ **Mode**: B — 任務先測 ｜ **TDD**: on（task-level）｜ **Commit cadence**: per-task
- **Estimated Files**: ~16（4 created source + 5 modified + 7 test files）
- **Build**: 248 → **249**（`CURRENT_PROJECT_VERSION`，Debug + Release 兩處）
- **FR 覆蓋**: FR-8, FR-9, FR-10, FR-11, FR-12 ＋ FR-M2-P1, FR-M2-P2, FR-M2-P3
- **AC 覆蓋**: SRS AC-1 ~ AC-9（AC-1 = umbrella AC-4「陳述句質疑必須被偵測」的實現）

---

## ⚠️ 規劃期發現：實作前必讀

寫 plan 時交叉驗證 codebase 才發現的。SRS / canon 的部分假設需要修正，另有幾個跨里程碑事實在此誠實記錄：

### 發現 1 — SRS 引用的 `VoiceInk.swift` 行號已過時

SRS 寫 index.store 段落在 `:371-378`、variadic 在 `:381` / `:409`。**實際**（2026-07-12 驗證）：
- master `Schema([...])`：`VoiceInk.swift:50-60`
- `createPersistentContainer`：`:245`；index.store 段落 `:285-292`；variadic `ModelContainer(for:configurations:)` 在 **`:295`**
- `createInMemoryContainer`：`:302`；indexSchema/indexConfig `:312-313`；variadic 在 **`:316`**

三處註冊規則本身不變（canon §3.5）；本 plan 一律用實際行號。

### 發現 2 — LLM seam 不用發明：`ChatCompleting` + adapter + test fake 三件套已存在

- 協定：`ChatCompleting`（`Services/AskAI/AskAIService.swift:6-8`，`complete(system:user:) async throws -> String`）。
- 正式 adapter 先例：`LiveChatCompleter`（`Views/AskAI/AskAIView.swift:5-15`）——包 `AIService.completeChat` + `ChatMessage.user(...)`。
- 測試 fake 先例：`FixedCompleter`（`VoiceInkTests/AskAIAnswerTests.swift:5-12`）。
- 模型解析先例：`AskAIAnswerModel.resolve`（`Services/AskAI/AskAIConfig.swift:31-39`，純函式）+ `AskAIView.swift:431-439` 的接線（`AIProvider(rawValue:) ?? selectedProvider` 回退）。

→ M2 的 `ResponseCueExtractor` **鏡射這三件套**，一行 SSE 都不碰。canon §3.3（兩種 SSE wire format）與 §3.4（LLMkit request/response struct 全 `private`）是 **M3 的問題**——M2 的輸出是結構化 JSON、使用者看不到中間產物，非串流 `completeChat` 正合適。

### 發現 3 — `AskAIError` 是 dead code；`AskAIService.ask()` 不是靜默路徑（canon §3.2）

grep 驗證：`AskAIError` 定義了但**從未被 throw**；`ask()` 在空索引／embed 失敗時會 **persist 可見的繁中診斷訊息**到聊天 UI。M2 不碰 RAG（那是 M3 的接地），但這確立了本模組的「靜默容錯」實作方式：**`try?` + 回 `[]`**（LLM 失敗、JSON 解析失敗都不 throw、不跳 UI、不 persist 診斷）——與 `MeetingLiveTranscriber` 的 ASR error 只記 log 的紀律一致（`MeetingLiveTranscriber.swift:130-132`）。M3 接地時**絕不可**呼叫 `AskAIService.ask()`。

### 發現 4 — `createInMemoryContainer` 是 `private`，AC-7 直接測不到 → 最小可見性調整

SRS AC-7 要求「測試建 in-memory container 驗證 meeting.store」。但 `createInMemoryContainer` 是 `private static`（`VoiceInk.swift:302`），master schema 是 `init()` 的區域變數——`@testable import` 也搆不到。**plan 決定**（Task 2）：
1. 把 master `Schema([...])` 抽成 `static let appSchema`（`init()` 改用 `Self.appSchema`，模型順序一字不動——`:49` 的註解「Keep existing model order stable」仍成立）；
2. `private static func createInMemoryContainer` → `static func`（internal）。

兩者皆為**可見性調整、零行為改變**，讓測試呼叫**真正的 app 註冊碼**而不是複製一份配方（複製會 drift，漏註冊照樣測不到）。

### 發現 5 — pbxproj 有 6 個 `CURRENT_PROJECT_VERSION`，只有 2 個是 app target

`grep -n` 實測：`:508` 與 `:542` 是 app target 的 Debug/Release（目前 = 248，M2 改成 249）；`:571/:589/:606/:622` 是其他 target 的 `= 1`，**不要動**。驗證指令要用 `grep -c "CURRENT_PROJECT_VERSION = 249"` → 恰 **2**。

### 發現 6 — 本機 FluidAudio ASR 無術語偏置（canon §3.8）→ cue 抽取的輸入本身會失真

`VocabularyWord` 字典只接到雲端串流 provider 的 `getCustomVocabularyTerms()`；FluidAudio 完全沒這條路（`MeetingCopilotConfigStore.swift:30-37` 的註解已載明）。專案代號轉錯（「Kafka」→「咖啡卡」）會直接餵髒 cue 抽取。M2 修不了 ASR；緩解是 prompt 明示「輸入是即時 ASR 逐字稿，可能有錯字，判斷語意而非字面」（見 Task 3 的 system prompt），並在 M5 設定 UI 明示取捨。

### 發現 7 — `MeetingReplayDebugRunner` 自建的 container **不含 meeting models**

M1 的 DEBUG runner 用 `ModelContainer(for: Transcription.self)` 自建 context（`MeetingReplayDebugRunner.swift:67-71`）。把 `MeetingLiveCue` insert 進這個 container 會直接掛。Task 8 的 DEBUG controller **必須自建 in-memory meeting container**，不能沿用該 context。

### 發現 8 — 跨里程碑誠實點名（不在 M2 範圍，但影響 M2 產物的下游）

- **M4**：`sharingType = .none` 在 **macOS 15.4+ 被 ScreenCaptureKit 忽略**（canon §3.1；Apple DTS 明言無公開 API 可防螢幕擷取；Chrome/Meet 的 `getDisplayMedia` 走 SCK）。M2 persist 的 cue 一旦在 M4 顯示於 overlay，「分享整個螢幕」時會被錄到——安全模式僅限「分享單一視窗/分頁」。M4 的 SRS/plan 必須寫成明確風險 + UI 警告，不得宣稱無條件隱形。
- **M5**：新 `ViewType` case 的五處 switch 陷阱（canon §3.7）——`icon`/`sidebarIconStyle`/`detailView` 是 exhaustive（漏=compile error，好）；`title` 有 `default:`、`sidebarSections` 是陣列（漏=DEBUG assert crash，壞）。M2 完全不碰 UI，此項留給 M5。
- **三處 schema 註冊是 M2 的責任**（不是 M5）——M2 是全模組第一個寫 `meeting.store` 的里程碑。

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/meeting-copilot-m2-cue-detection.srs.md` | all | 需求＋9 條 AC＋Open Questions（本 plan 逐一裁決，見 NOT Building 後的「Open Questions 裁決」） |
| P0 | `docs/spec/meeting-copilot.spec.md` | Ubiquitous Language、Decisions Log | 命名與已鎖定的決策 |
| P0 | `VoiceInk/Services/MeetingCopilot/MeetingLiveTranscriber.swift` | 20（`@MainActor`）、45-48（`onRemoteCommitted` 宣告）、113-135（committed 事件觸發點） | **M2 的唯一接點**。只掛 closure，不改本體 |
| P0 | `VoiceInk/VoiceInk.swift` | 50-60（master Schema）、245-295（persistent container + index.store 塊 + variadic）、302-316（in-memory container） | **三處 schema 註冊的照抄對象**（index.store 塊）。行號見發現 1 |
| P0 | 專案記憶 `voiceink-running-unit-tests` | all | **測試指令必須照它寫**，否則 host crash（CloudKit `_os_crash`）。`-only-testing` 仍編譯所有測試檔 |
| P1 | `VoiceInk/Models/AskAIModels.swift` | 41-60（`AskAIThread` cascade 父端）、516-545（`AskAIMessage` 裸反向參照 + citations JSON-in-raw） | Task 1 的關係與列舉存取器照抄對象 |
| P1 | `VoiceInk/Models/Transcription.swift` | 73-121（`speakerSegments` JSON-in-raw + `@Transient` 快取） | Task 1 tier 陣列欄位的照抄對象 |
| P1 | `VoiceInk/Services/AskAI/AskAIService.swift` | 6-8（`ChatCompleting`） | Task 3 重用的 LLM seam，**不新發明** |
| P1 | `VoiceInk/Views/AskAI/AskAIView.swift` | 5-15（`LiveChatCompleter`）、425-440（resolve + 接線） | Task 3 正式 adapter、Task 8 模型解析的照抄對象 |
| P1 | `VoiceInk/Services/AIEnhancement/AIChatCompletionService.swift` | 4-77（`completeChat` 全 provider dispatch） | adapter 底下呼叫的實際 API（簽章勿臆造） |
| P1 | `VoiceInk/Services/AskAI/AskAIConfig.swift` | 25-39（`AskAIAnswerModel.resolve` 純函式） | Task 8 借用（M3 才引入專屬 `MeetingCopilotModels.resolve`） |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | all（82 行） | Task 5 擴充的對象；樣式已定（`@Published private(set)` + `…V1` key + mutator） |
| P2 | `VoiceInkTests/AskAIAnswerTests.swift` | 5-12（`FixedCompleter`）、17-22（in-memory `makeContext`） | 測試 fake 與 in-memory container 的房子風格 |
| P2 | `VoiceInk/Services/MeetingCopilot/MeetingTranscriptStream.swift` | 102-152（`FakeMeetingTranscriptStream`：`script:[Int:event]` + `finalText`） | Task 7 replay 腳本化事件的注入點 |
| P2 | `VoiceInkTests/MeetingCopilotReplayTests.swift` | all | Task 7 的 replay harness 房子風格（合成 WAV、speed、sleep 預算） |
| P2 | `VoiceInk/Services/MeetingCopilot/MeetingReplayDebugRunner.swift` | 35-107 | Task 8 擴充的對象；注意發現 7 的 container 陷阱 |
| P2 | 專案記憶 `voiceink-report-build-number`、`voiceink-build-no-ghost-apps` | all | bump build 並回報；**不要 build 進 /tmp**；**不自動 deploy** |

## External Documentation

無需外部研究——全部使用既有內部 pattern（SwiftData 多 store、`ChatCompleting` seam、M1 replay harness）。

---

## Patterns to Mirror

### THREE_PLACE_SCHEMA — meeting.store 的照抄對象（Task 2）

```swift
// SOURCE: VoiceInk/VoiceInk.swift:50-60 — 第 1 處:master Schema(每個 @Model 都要在)
// Keep existing model order stable; append new models after synced entities.
let schema = Schema([
    Transcription.self,
    ImportLedgerEntry.self,
    VocabularyWord.self,
    WordReplacement.self,
    SessionMetric.self,
    EmbeddingChunk.self,
    AskAIThread.self,
    AskAIMessage.self,
    AskAITemplate.self
])
```
```swift
// SOURCE: VoiceInk/VoiceInk.swift:284-295 — 第 2 處:createPersistentContainer(index.store 塊 = 逐字模板)
        // Ask AI 索引與對話:獨立 store——衍生資料,可整顆刪除重建,不影響核心遷移。
        let indexStoreURL = appSupportURL.appendingPathComponent("index.store")
        let indexSchema = Schema([EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self, AskAITemplate.self])
        let indexConfig = ModelConfiguration(
            "index",
            schema: indexSchema,
            url: indexStoreURL,
            cloudKitDatabase: .none
        )

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig, indexConfig)
```
```swift
// SOURCE: VoiceInk/VoiceInk.swift:312-316 — 第 3 處:createInMemoryContainer(無 url/cloudKit)
        let indexSchema = Schema([EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self, AskAITemplate.self])
        let indexConfig = ModelConfiguration("index", schema: indexSchema, isStoredInMemoryOnly: true)

        do {
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig, indexConfig)
```
> 🔴 **經典漏法**：master schema 加了 model 但 `configurations:` 沒 append 新 config → 兩個 container **都** throw → `fatalError("VoiceInk failed to initialize storage.")`。`container.mainContext` 橫跨全部 store——**不需要**為 meeting.store 另開 context；但 `#Predicate` 只能引用同 store 的 model。

### CASCADE_RELATIONSHIP — 非對稱 cascade（Task 1 照抄）

```swift
// SOURCE: VoiceInk/Models/AskAIModels.swift:41-53 — 父端:@Relationship + OPTIONAL 陣列 + 預設 []
@Model
final class AskAIThread {
    var title: String = ""
    var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \AskAIMessage.thread)
    var messages: [AskAIMessage]? = []

    init(title: String, createdAt: Date = Date()) {
        self.title = title
        self.createdAt = createdAt
    }
}

// SOURCE: VoiceInk/Models/AskAIModels.swift:516-531 — 子端:裸可選反向參照(無 @Relationship)+ String-in-raw 列舉欄位
@Model
final class AskAIMessage {
    var thread: AskAIThread?
    var role: String = ""          // "user" | "assistant"
    var text: String = ""
    var citationsRaw: String?      // JSON [ChunkRef];nil = 無引用
    var createdAt: Date = Date()
```
> `@Relationship` 放兩邊、或父端陣列非 optional，都會壞。每個 stored property 都要有預設值（lightweight migration）。

### JSON_IN_RAW_TRANSIENT — 陣列欄位 + decode 快取（Task 1 的 tier 欄位照抄）

```swift
// SOURCE: VoiceInk/Models/Transcription.swift:71-92
    /// JSON-encoded `[SpeakerSegment]` when the transcript was diarized; nil otherwise.
    var speakerSegmentsRaw: String?

    // Decode caches, keyed on the raw JSON they were decoded from (a raw-string compare is
    // orders of magnitude cheaper than re-running JSONDecoder).
    @Transient private var segmentsCacheRaw: String? = nil
    @Transient private var segmentsCacheValue: [SpeakerSegment] = []

    var speakerSegments: [SpeakerSegment] {
        get {
            guard let raw = speakerSegmentsRaw, let data = raw.data(using: .utf8) else { return [] }
            if segmentsCacheRaw == raw { return segmentsCacheValue }
            let decoded = (try? JSONDecoder().decode([SpeakerSegment].self, from: data)) ?? []
            segmentsCacheRaw = raw
            segmentsCacheValue = decoded
            return decoded
        }
        set {
            speakerSegmentsRaw = (try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) }
            segmentsCacheRaw = speakerSegmentsRaw
            segmentsCacheValue = speakerSegmentsRaw == nil ? [] : newValue
            speakerLabeled = !newValue.isEmpty
        }
    }
```
> `@Transient` 欄位**必須有預設值**。M2 的 tier 欄位 raw 用非 optional `String = ""`（SRS 指定），get 端把 `guard let raw` 換成 `guard !raw.isEmpty`——其餘形狀一字不改。

### CHAT_COMPLETING_SEAM — 協定 + 正式 adapter + 測試 fake（Task 3 照抄，不新發明）

```swift
// SOURCE: VoiceInk/Services/AskAI/AskAIService.swift:5-8 — 協定(M2 直接重用)
/// 回答生成的可注入介面(測試用 fake,正式走 AIService.completeChat)。
protocol ChatCompleting {
    func complete(system: String, user: String) async throws -> String
}

// SOURCE: VoiceInk/Views/AskAI/AskAIView.swift:5-15 — 正式 adapter 的形狀
/// 把 AIService.completeChat 包成 AskAIService 需要的 ChatCompleting。
private struct LiveChatCompleter: ChatCompleting {
    let aiService: AIService
    let provider: AIProvider
    var modelName: String?
    func complete(system: String, user: String) async throws -> String {
        try await aiService.completeChat(
            provider: provider, modelName: modelName,
            messages: [ChatMessage.user(user)], systemPrompt: system, timeout: 60)
    }
}

// SOURCE: VoiceInkTests/AskAIAnswerTests.swift:5-12 — 測試 fake 的形狀
private struct FixedCompleter: ChatCompleting {
    let reply: String
    let onCall: (@Sendable () -> Void)?
    func complete(system: String, user: String) async throws -> String {
        onCall?()
        return reply
    }
}
```

### RESOLVE_PURE_FUNCTION — fast model 解析（Task 8 借用；M3 再引入專屬版）

```swift
// SOURCE: VoiceInk/Services/AskAI/AskAIConfig.swift:25-39
enum AskAIAnswerModel {
    static let providerKey = "askAIAnswerProvider"
    static let modelKey = "askAIAnswerModel"

    static func resolve(storedProvider: String?, storedModel: String?,
                        defaultProvider: String, available: [String]) -> (provider: String, model: String?) {
        if let sp = storedProvider, !sp.isEmpty, available.contains(sp) {
            let m = (storedModel?.isEmpty == false) ? storedModel : nil
            return (sp, m)
        }
        return (defaultProvider, nil)
    }
}

// SOURCE: VoiceInk/Views/AskAI/AskAIView.swift:431-439 — 接線(含 provider 回退)
        let resolved = AskAIAnswerModel.resolve(
            storedProvider: answerProviderRaw.isEmpty ? nil : answerProviderRaw,
            storedModel: answerModelRaw.isEmpty ? nil : answerModelRaw,
            defaultProvider: aiService.selectedProvider.rawValue,
            available: aiService.connectedProviders.map(\.rawValue))
        let provider = AIProvider(rawValue: resolved.provider) ?? aiService.selectedProvider
```

### CONFIG_STORE — M2 欄位擴充樣式（Task 5 照抄）

```swift
// SOURCE: VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift:1048-1051, 1067-1072
    private func persistString(_ value: String?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    func setClassifierModel(provider: String?, model: String?) {
        recorderClassifierProviderName = provider
        recorderClassifierModelName = model
        persistString(provider, recClassifierProviderKey)
        persistString(model, recClassifierModelKey)
    }

// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift:51-70 — M1 既有的 load/mutator 形狀(直接延伸)
    private func load() {
        let d = UserDefaults.standard
        copilotEnabled = d.bool(forKey: copilotEnabledKey)   // 未設定 → false
        if let m = d.string(forKey: asrModelNameKey), !m.isEmpty {
            asrModelName = m
        }
        if d.object(forKey: transcribeLocalMicKey) != nil {
            transcribeLocalMic = d.bool(forKey: transcribeLocalMicKey)
        }
    }
    func setCopilotEnabled(_ value: Bool) {
        copilotEnabled = value
        UserDefaults.standard.set(value, forKey: copilotEnabledKey)
    }
```

### TEST_CONTEXT — in-memory container 的房子風格（Task 1/6/7 照抄）

```swift
// SOURCE: VoiceInkTests/AskAIAnswerTests.swift:17-22
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: EmbeddingChunk.self, AskAIThread.self, AskAIMessage.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }
```

### REPLAY_HARNESS — 腳本化 committed 事件（Task 7 照抄 M1）

```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingTranscriptStream.swift:104-107, 120-127
    /// 收到第 N 個 chunk 時吐出對應事件(1-based)。
    private let script: [Int: StreamingTranscriptionEvent]
    /// `finish()` 時吐出的 committed 文字。
    private let finalText: String?

    init(script: [Int: StreamingTranscriptionEvent] = [:], finalText: String? = nil) {

// SOURCE: VoiceInkTests/MeetingCopilotReplayTests.swift — 合成 WAV + replay 的用法
        let source = ReplayMeetingAudioSource(
            remoteURL: remoteWAV,
            localURL: localWAV,
            speed: 50.0,          // 加速,測試數百毫秒內完成
            chunkFrames: 1600     // 0.1s @16k
        )
        let remoteASR = FakeMeetingTranscriptStream(finalText: "你會怎麼設計一個短網址服務？")
        let transcriber = MeetingLiveTranscriber(
            source: source,
            remoteStream: remoteASR,
            localStream: localASR
        )
        var cues: [String] = []
        transcriber.onRemoteCommitted = { cues.append($0) }
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Models/MeetingLiveModels.swift` | CREATE | `MeetingLiveSession` + `MeetingLiveCue` @Model + `MeetingCueKind`/`MeetingCueStatus` 列舉存取器 + tier JSON-in-raw 欄位（FR-M2-P1） |
| `VoiceInk/VoiceInk.swift` | UPDATE | 三處 schema 註冊（clone index.store 塊）＋ `appSchema` 抽出＋ `createInMemoryContainer` 降為 internal（發現 4）（FR-M2-P2） |
| `VoiceInk/Services/MeetingCopilot/ResponseCueExtractor.swift` | CREATE | prompt 純函式 + JSON 契約解析 + 一次非串流抽取 + 正式 adapter `MeetingFastChatCompleter`（FR-8/9/12） |
| `VoiceInk/Services/MeetingCopilot/MeetingCueDeduplicator.swift` | CREATE | 純函式：正規化 + 字元 bigram Jaccard + 30s 窗（FR-10） |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotController.swift` | CREATE | MVP 管線：掛 `onRemoteCommitted` → 抽 → 去重 → persist → `@Published cues`；kill switch；informational 過濾（FR-11/M2-P3） |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | UPDATE | 新增 `fastProviderName`/`fastModelName`/`showInformationalCues` + `persistString` helper |
| `VoiceInk/Services/MeetingCopilot/MeetingReplayDebugRunner.swift` | UPDATE | DEBUG replay 接上 controller（真 fast model 人工驗證）；`run()` → `run(aiService:)` |
| `VoiceInk/Views/MenuBarView.swift` | UPDATE | `:58` 呼叫端改傳 `aiService`（既有 `@EnvironmentObject`，`:13`） |
| `VoiceInk.xcodeproj/project.pbxproj` | UPDATE | `CURRENT_PROJECT_VERSION` 248 → 249（**只動 :508/:542 兩處**，見發現 5） |
| `VoiceInkTests/MeetingLiveModelsTests.swift` | CREATE | AC-6（cascade）＋列舉/JSON 存取器 round-trip |
| `VoiceInkTests/MeetingStoreRegistrationTests.swift` | CREATE | AC-7（in-memory container 背 meeting.store，呼叫真 app 碼） |
| `VoiceInkTests/ResponseCueExtractorTests.swift` | CREATE | AC-1/AC-2/AC-3 ＋ JSON 契約 golden ＋ 靜默容錯；內含共用 fakes |
| `VoiceInkTests/MeetingCueDeduplicatorTests.swift` | CREATE | FR-10 純函式（AC-4 的一半） |
| `VoiceInkTests/MeetingCopilotConfigStoreTests.swift` | CREATE | M2 新欄位預設值與持久化 |
| `VoiceInkTests/MeetingCopilotControllerTests.swift` | CREATE | AC-4/AC-5/AC-9 |
| `VoiceInkTests/MeetingCueDetectionReplayTests.swift` | CREATE | AC-8（端到端 replay，fake ASR + fake LLM） |

> **pbxproj**：專案用 `PBXFileSystemSynchronizedRootGroup`，新 `.swift` 檔**自動入 target**，不需手動註冊。唯一要改 pbxproj 的是 build number。

## NOT Building（M2 明確不做）

- **Tier 0 / Tier 1 / Tier 2 任何回應生成**——關鍵字表、embedding 相似度、opener/bullets/analysis、`AnswerCoordinator`、預跑、取消 → **M3**。cue 的 `tier*` 欄位 M2 宣告但一律留白。
- **SSE 串流 client**（`StreamingChatClient`、`AIService.streamChat`、兩種 wire format parser）→ **M3**。M2 只用非串流 `completeChat`，不觸 LLMkit private struct（canon §3.3/§3.4）。
- **接地**（brief 注入 prompt、RAG〔`LiveEmbedder`+`RetrievalService`〕、螢幕 OCR）→ **M3**。M3 實作時**絕不可**走 `AskAIService.ask()`（發現 3）。
- **`MeetingCopilotModels.resolve()` 專屬純函式** → **M3**（M2 借用 `AskAIAnswerModel.resolve`，SRS Open Question 裁決見下）。
- **Overlay、熱鍵、`sharingType=.none`、修 `.toggleMeetingRecording`** → **M4**。
- **側欄頁面、`ViewType` case、設定 UI、雙軌逐字稿檢視** → **M5**（M2 只加 config store 欄位，無 UI）。
- **語意（embedding）去重**——正規化 Jaccard 夠 M2 用；升級門檻列 M3+ 再議。
- **debounce / 滑動窗批次抽取**——M2 逐 committed 抽取（`recentContext` 參數已留 seam，預設空字串）；節奏要與 M3「最新一則預跑 Tier 1」對齊，M3 再調。
- **不改 M1 既有元件行為**：`MeetingLiveTranscriber` 本體（只掛既有 closure）、`MeetingCaptureService`、splitter、downsampler、ring buffer 全部不動。

### SRS Open Questions 裁決（plan 定案）

| Open Question | 裁決 |
|---|---|
| fast model 解析歸屬 | **借用 `AskAIAnswerModel.resolve`**（既有純函式，不臆造簽章）；M3 引入 `MeetingCopilotModels.resolve` 時回頭替換一處呼叫點 |
| cue 抽取滑動窗 | M2 **逐 committed 抽取**，`buildPrompt(committed:recentContext:)` 留 `recentContext` seam（預設 `""`），M3 調校 |
| 去重門檻 | 正規化字元 bigram Jaccard，**門檻 0.6、窗 30s**，皆為具名常數可調（`MeetingCueDeduplicator.defaultThreshold/.defaultWindow`） |
| debounce 策略 | M2 不 debounce（committed 事件本身已是句級粒度）；成本觀測後 M3 再議 |
| JSON 契約 | **鎖定** `{"cues":[{"text":"…","kind":"directQuestion|impliedChallenge|assignedToMe|informational"}]}`，golden test 把關（Task 3） |
| tier 欄位宣告時機 | **M2 一次宣告**（raw 欄位＋存取器＋預設值）——雖然獨立 store 可重建，一次到位讓 M3 完全不碰 models 檔 |

---

## Step-by-Step Tasks

### Task 1: `MeetingLiveModels` — 兩個 @Model + 列舉/JSON 存取器（AC-6）

**Files:**
- Create: `VoiceInk/Models/MeetingLiveModels.swift`
- Test:   `VoiceInkTests/MeetingLiveModelsTests.swift`

- **ACTION**: 定義 `MeetingLiveSession` / `MeetingLiveCue`，cascade 關係照抄 `AskAIThread`/`AskAIMessage`，tier 陣列欄位照抄 `Transcription.speakerSegments` 的 JSON-in-raw + `@Transient` 快取。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingLiveModelsTests.swift
import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class MeetingLiveModelsTests: XCTestCase {

    /// in-memory container(房子風格:AskAIAnswerTests.makeContext)。
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// AC-6:刪 session → cascade 刪全部 cue,無孤兒。
    func testDeletingSessionCascadesCues() throws {
        let ctx = try makeContext()
        let session = MeetingLiveSession(appName: "teams")
        ctx.insert(session)
        for i in 0..<3 {
            ctx.insert(MeetingLiveCue(
                session: session, text: "cue \(i)", kind: .directQuestion))
        }
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 3)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSession>()).first?.cues?.count, 3)

        ctx.delete(session)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0,
                       ".cascade 應連帶刪除全部 cue")
    }

    /// String-in-raw 列舉:round-trip + 未知值回退不崩(向前相容)。
    func testKindRoundTripsAndUnknownFallsBack() {
        let cue = MeetingLiveCue(session: nil, text: "x", kind: .assignedToMe)
        XCTAssertEqual(cue.kindRaw, "assignedToMe")
        XCTAssertEqual(cue.kind, .assignedToMe)

        cue.kind = .impliedChallenge
        XCTAssertEqual(cue.kindRaw, "impliedChallenge")

        cue.kindRaw = "somethingFromTheFuture"
        XCTAssertEqual(cue.kind, .informational, "未知 kind 回退 informational,不崩")
    }

    /// status 預設 detected。
    func testStatusDefaultsToDetected() {
        let cue = MeetingLiveCue(session: nil, text: "x", kind: .directQuestion)
        XCTAssertEqual(cue.status, .detected)
    }

    /// tier 陣列欄位(M2 宣告不寫入):JSON round-trip + 壞 JSON 回空。
    func testTierArrayAccessorsRoundTripAndTolerateGarbage() {
        let cue = MeetingLiveCue(session: nil, text: "x", kind: .directQuestion)
        XCTAssertEqual(cue.tier1Bullets, [], "預設空")

        cue.tier1Bullets = ["重點一", "重點二", "重點三"]
        XCTAssertEqual(cue.tier1Bullets, ["重點一", "重點二", "重點三"])
        XCTAssertFalse(cue.tier1BulletsRaw.isEmpty)

        cue.tier2FollowUpsRaw = "這不是 JSON"
        XCTAssertEqual(cue.tier2FollowUps, [], "壞 JSON 靜默回空,不崩")
    }
}
```
  Run（**必須用完整指令，見專案記憶 `voiceink-running-unit-tests`**）:
  ```bash
  xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
    -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -only-testing:VoiceInkTests/MeetingLiveModelsTests
  ```
  Expected: **FAIL**（型別不存在，compile error）

- **IMPLEMENT**:
```swift
// VoiceInk/Models/MeetingLiveModels.swift
import Foundation
import SwiftData

/// meeting-copilot 的即時會議 session 與偵測到的 cue。
///
/// **兩個 model 都存於獨立的 `meeting.store`**(`cloudKitDatabase: .none`,只存本機)——
/// 本模組 schema 初期必然反覆調整,獨立 store 檔案不可能破壞 `default.store` 的
/// migration,崩壞時可整檔刪除重來。先例:`index.store`(見 AskAIModels.swift 檔頭)。
///
/// 三處註冊見 VoiceInk.swift(master Schema / createPersistentContainer /
/// createInMemoryContainer)——漏任一處 = launch `fatalError`。

/// cue 的四分類(FR-8)。String-in-raw 慣例:persist `kindRaw`,computed `kind` 包住它。
enum MeetingCueKind: String, Codable, CaseIterable {
    /// 直接問句:「你會怎麼設計一個短網址服務?」
    case directQuestion
    /// 陳述句形式的質疑——沒有問號但期待回應:「我對這個寫入效能有點擔心」(umbrella AC-4 的核心)
    case impliedChallenge
    /// 點名/指派:「這塊 Logan 你來說明一下」
    case assignedToMe
    /// 純資訊,不需回應:「我們上週上線了 v2」(FR-11:persist 但預設不暴露)
    case informational
}

/// cue 的生命週期狀態。M2 只寫入 `.detected`;`.answered` 屬 M3。
enum MeetingCueStatus: String, Codable {
    case detected
    case answered
}

/// 一場即時會議 session(copilot 啟用時每次 attach 建立一筆)。
@Model
final class MeetingLiveSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date?
    /// 會議 app 名稱(例:"zoom" / "teams";M2 由呼叫端傳入,可空)。
    var appName: String = ""
    /// 使用者的會議 brief(M3 接地用;M2 只宣告)。
    var brief: String = ""
    /// 對方/我的累積逐字稿快照(session 結束時回填;M2 只宣告)。
    var remoteTranscriptRaw: String = ""
    var localTranscriptRaw: String = ""

    /// 父端:cascade + inverse(鏡射 AskAIThread.messages,AskAIModels.swift:45-46)。
    /// **OPTIONAL 陣列、預設 []** ——兩者缺一不可。
    @Relationship(deleteRule: .cascade, inverse: \MeetingLiveCue.session)
    var cues: [MeetingLiveCue]? = []

    init(startedAt: Date = Date(), appName: String = "", brief: String = "") {
        self.id = UUID()
        self.startedAt = startedAt
        self.appName = appName
        self.brief = brief
    }
}

/// 一則偵測到的 cue(「需要我回應的東西」)。
@Model
final class MeetingLiveCue {
    var id: UUID = UUID()
    /// 子端:**裸的可選反向參照,無 @Relationship**(非對稱 cascade 語法,
    /// 鏡射 AskAIMessage.thread,AskAIModels.swift:518)。
    var session: MeetingLiveSession?
    /// cue 原句。
    var text: String = ""
    var kindRaw: String = MeetingCueKind.informational.rawValue
    var askedAt: Date = Date()
    /// 觸發這則 cue 的 committed 片段節錄(供 M3 帶上下文、M5 顯示)。
    var contextExcerpt: String = ""
    var statusRaw: String = MeetingCueStatus.detected.rawValue

    // MARK: - M3 欄位(M2 宣告不寫入;每欄有預設值 = lightweight migration 安全)

    var tier0Keywords: String = ""
    var tier1Opener: String = ""
    var tier1BulletsRaw: String = ""
    var tier2Analysis: String = ""
    var tier2FollowUpsRaw: String = ""
    var tier2UncertaintiesRaw: String = ""
    var fastModelName: String = ""
    var deepModelName: String = ""
    var answeredAt: Date?

    init(
        session: MeetingLiveSession?,
        text: String,
        kind: MeetingCueKind,
        askedAt: Date = Date(),
        contextExcerpt: String = ""
    ) {
        self.id = UUID()
        self.session = session
        self.text = text
        self.kindRaw = kind.rawValue
        self.askedAt = askedAt
        self.contextExcerpt = contextExcerpt
    }

    // MARK: - 列舉存取器(String-in-raw,鏡射 AskAIMessage.role 的裸 String 模式)

    var kind: MeetingCueKind {
        get { MeetingCueKind(rawValue: kindRaw) ?? .informational }
        set { kindRaw = newValue.rawValue }
    }

    var status: MeetingCueStatus {
        get { MeetingCueStatus(rawValue: statusRaw) ?? .detected }
        set { statusRaw = newValue.rawValue }
    }

    // MARK: - tier 陣列存取器(JSON-in-raw + @Transient 快取,
    //          鏡射 Transcription.speakerSegments,Transcription.swift:73-92;
    //          raw 為非 optional String,get 端以 isEmpty 取代 nil 檢查)

    @Transient private var bulletsCacheRaw: String = ""
    @Transient private var bulletsCacheValue: [String] = []
    var tier1Bullets: [String] {
        get {
            guard !tier1BulletsRaw.isEmpty, let data = tier1BulletsRaw.data(using: .utf8) else { return [] }
            if bulletsCacheRaw == tier1BulletsRaw { return bulletsCacheValue }
            let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            bulletsCacheRaw = tier1BulletsRaw
            bulletsCacheValue = decoded
            return decoded
        }
        set {
            tier1BulletsRaw = newValue.isEmpty
                ? ""
                : ((try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            bulletsCacheRaw = tier1BulletsRaw
            bulletsCacheValue = newValue
        }
    }

    @Transient private var followUpsCacheRaw: String = ""
    @Transient private var followUpsCacheValue: [String] = []
    var tier2FollowUps: [String] {
        get {
            guard !tier2FollowUpsRaw.isEmpty, let data = tier2FollowUpsRaw.data(using: .utf8) else { return [] }
            if followUpsCacheRaw == tier2FollowUpsRaw { return followUpsCacheValue }
            let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            followUpsCacheRaw = tier2FollowUpsRaw
            followUpsCacheValue = decoded
            return decoded
        }
        set {
            tier2FollowUpsRaw = newValue.isEmpty
                ? ""
                : ((try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            followUpsCacheRaw = tier2FollowUpsRaw
            followUpsCacheValue = newValue
        }
    }

    @Transient private var uncertaintiesCacheRaw: String = ""
    @Transient private var uncertaintiesCacheValue: [String] = []
    var tier2Uncertainties: [String] {
        get {
            guard !tier2UncertaintiesRaw.isEmpty, let data = tier2UncertaintiesRaw.data(using: .utf8) else { return [] }
            if uncertaintiesCacheRaw == tier2UncertaintiesRaw { return uncertaintiesCacheValue }
            let decoded = (try? JSONDecoder().decode([String].self, from: data)) ?? []
            uncertaintiesCacheRaw = tier2UncertaintiesRaw
            uncertaintiesCacheValue = decoded
            return decoded
        }
        set {
            tier2UncertaintiesRaw = newValue.isEmpty
                ? ""
                : ((try? JSONEncoder().encode(newValue)).flatMap { String(data: $0, encoding: .utf8) } ?? "")
            uncertaintiesCacheRaw = tier2UncertaintiesRaw
            uncertaintiesCacheValue = newValue
        }
    }
}
```

- **MIRROR**: `CASCADE_RELATIONSHIP`（AskAIModels.swift:41-53, 516-531）＋ `JSON_IN_RAW_TRANSIENT`（Transcription.swift:73-92）

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingLiveModelsTests` — expect **PASS**（4 測試全綠）

- **GOTCHA**: 測試的 in-memory container 只註冊兩個 meeting model——它驗證 model 定義本身；**app 的三處註冊是 Task 2 的事**，兩者都要綠才算 store 完成。

- **COMMIT**: `feat(meeting-copilot): MeetingLiveSession + MeetingLiveCue @Model (meeting.store schema)`

---

### Task 2: `meeting.store` 三處 schema 註冊（AC-7）🔴 漏一處 = launch fatalError

**Files:**
- Modify: `VoiceInk/VoiceInk.swift`（:50-60、:284-295、:312-316 三處 + 可見性調整）
- Test:   `VoiceInkTests/MeetingStoreRegistrationTests.swift`

- **ACTION**: 完全照抄 index.store 塊註冊第 5 個 store。同時做發現 4 的最小可見性調整，讓測試呼叫**真正的** app 註冊碼。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingStoreRegistrationTests.swift
import XCTest
import SwiftData
import os
@testable import VoiceInk

/// AC-7:meeting.store 三處註冊。呼叫**真正的** VoiceInkApp.createInMemoryContainer
/// (Task 2 將其由 private 降為 internal)+ 真正的 VoiceInkApp.appSchema——
/// 不複製配方,漏註冊(尤其漏 configurations: append)在這裡就會 throw。
@MainActor
final class MeetingStoreRegistrationTests: XCTestCase {

    func testInMemoryContainerBacksMeetingStore() throws {
        let logger = Logger(subsystem: "test", category: "MeetingStoreRegistrationTests")

        // 與 app init 相同的呼叫:master schema + in-memory container。
        // 若 master schema 含 MeetingLiveSession/Cue 但 configurations 沒有 meetingConfig,
        // 這行就 throw(= app 啟動會 fatalError 的同一條路)。
        let container = try VoiceInkApp.createInMemoryContainer(
            schema: VoiceInkApp.appSchema, logger: logger)

        let ctx = container.mainContext
        let session = MeetingLiveSession(appName: "zoom")
        ctx.insert(session)
        ctx.insert(MeetingLiveCue(
            session: session, text: "你會怎麼設計一個短網址服務?", kind: .directQuestion))
        try ctx.save()

        let sessions = try ctx.fetch(FetchDescriptor<MeetingLiveSession>())
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.cues?.count, 1)
        XCTAssertEqual(sessions.first?.cues?.first?.kind, .directQuestion)
    }

    /// master schema 必須同時含兩個 meeting model(漏了 = 上面那個測試根本插不進去,
    /// 但這裡再明確斷言一次,錯誤訊息更直指問題)。
    func testMasterSchemaContainsMeetingModels() {
        let names = VoiceInkApp.appSchema.entities.map(\.name)
        XCTAssertTrue(names.contains("MeetingLiveSession"), "master Schema 漏了 MeetingLiveSession")
        XCTAssertTrue(names.contains("MeetingLiveCue"), "master Schema 漏了 MeetingLiveCue")
    }
}
```
  Run: 完整指令 + `-only-testing:VoiceInkTests/MeetingStoreRegistrationTests` — expect **FAIL**（`appSchema` 不存在 / `createInMemoryContainer` 是 private）

- **IMPLEMENT**（四個編輯，全在 `VoiceInk/VoiceInk.swift`）:

  1. **抽出 master schema**（`:50-60` 的 `let schema = Schema([...])` 改為引用 static，並 append 兩個新 model）：
```swift
        // Keep existing model order stable; append new models after synced entities.
        let schema = Self.appSchema
```
```swift
    // 與 init 內順序一字不動地抽出,供測試(MeetingStoreRegistrationTests)驗證註冊完整性。
    static let appSchema = Schema([
        Transcription.self,
        ImportLedgerEntry.self,
        VocabularyWord.self,
        WordReplacement.self,
        SessionMetric.self,
        EmbeddingChunk.self,
        AskAIThread.self,
        AskAIMessage.self,
        AskAITemplate.self,
        MeetingLiveSession.self,
        MeetingLiveCue.self
    ])
```

  2. **`createPersistentContainer`**（index.store 塊之後、`do { return try ModelContainer(...)` 之前，完全照抄 index 塊的形狀）：
```swift
        // meeting-copilot 即時 session 與 cue:獨立 store——schema 實驗期可整檔刪除重建,
        // 不影響核心遷移。(先例:index.store,上方)
        let meetingStoreURL = appSupportURL.appendingPathComponent("meeting.store")
        let meetingSchema = Schema([MeetingLiveSession.self, MeetingLiveCue.self])
        let meetingConfig = ModelConfiguration(
            "meeting",
            schema: meetingSchema,
            url: meetingStoreURL,
            cloudKitDatabase: .none
        )
```
     並把 variadic（原 `:295`）改為：
```swift
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig, indexConfig, meetingConfig)
```

  3. **`createInMemoryContainer`**（原 `:302`）：`private static func` → `static func`（發現 4）；indexConfig 之後加：
```swift
        let meetingSchema = Schema([MeetingLiveSession.self, MeetingLiveCue.self])
        let meetingConfig = ModelConfiguration("meeting", schema: meetingSchema, isStoredInMemoryOnly: true)
```
     並把 variadic（原 `:316`）改為：
```swift
            return try ModelContainer(for: schema, configurations: transcriptConfig, dictionaryConfig, statsConfig, indexConfig, meetingConfig)
```

- **MIRROR**: `THREE_PLACE_SCHEMA`（VoiceInk.swift:284-295 的 index.store 塊，逐字形狀）

- **VALIDATE**:
  1. `-only-testing:VoiceInkTests/MeetingStoreRegistrationTests` — **PASS**
  2. compile gate（見 Validation Commands）——確認 app target 零錯誤
  3. `-only-testing:VoiceInkTests/AskAIAnswerTests` — **PASS**（既有 store 零回歸）

- **GOTCHA**: `createPersistentContainer` 保持 `private`（測試不需要它；in-memory 版與它只差 URL/CloudKit，compile + 人工啟動覆蓋）。**不要**動 `dictionaryConfig` 的 `#if LOCAL_BUILD` CloudKit 分支。

- **COMMIT**: `feat(meeting-copilot): register meeting.store in all three schema places (clone index.store)`

---

### Task 3: `ResponseCueExtractor` — prompt 純函式 + JSON 契約 + 一次非串流抽取（AC-1/2/3）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/ResponseCueExtractor.swift`
- Test:   `VoiceInkTests/ResponseCueExtractorTests.swift`（內含共用 fakes，後續 task 重用）

- **ACTION**: 重用 `ChatCompleting` seam。抽取＋四分類合併為**單次**非串流呼叫；prompt 為純函式（FR-12）；JSON 解析失敗回 `[]`（靜默容錯，發現 3）。

- **TEST FIRST**:
```swift
// VoiceInkTests/ResponseCueExtractorTests.swift
import XCTest
@testable import VoiceInk

// MARK: - 共用 fakes(鏡射 AskAIAnswerTests.FixedCompleter;非 private——
//         MeetingCopilotControllerTests / MeetingCueDetectionReplayTests 共用)

/// 固定回覆 + 呼叫記錄的 LLM fake。
final class FakeChatCompleting: ChatCompleting, @unchecked Sendable {
    struct StubError: Error {}
    private let reply: String
    private let shouldThrow: Bool
    private let lock = NSLock()
    private var systems: [String] = []
    private var users: [String] = []

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return users.count }
    var lastUser: String? { lock.lock(); defer { lock.unlock() }; return users.last }

    init(reply: String = #"{"cues":[]}"#, shouldThrow: Bool = false) {
        self.reply = reply
        self.shouldThrow = shouldThrow
    }

    func complete(system: String, user: String) async throws -> String {
        lock.lock(); systems.append(system); users.append(user); lock.unlock()
        if shouldThrow { throw StubError() }
        return reply
    }
}

/// 依 user prompt 內容路由回覆的 LLM fake(多段 committed 的測試不吃時序)。
final class KeyedFakeChatCompleting: ChatCompleting, @unchecked Sendable {
    private let routes: [(contains: String, json: String)]
    private let lock = NSLock()
    private var count = 0
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(routes: [(contains: String, json: String)]) { self.routes = routes }

    func complete(system: String, user: String) async throws -> String {
        lock.lock(); count += 1; lock.unlock()
        for r in routes where user.contains(r.contains) { return r.json }
        return #"{"cues":[]}"#
    }
}

// MARK: - Tests

final class ResponseCueExtractorTests: XCTestCase {

    /// AC-3:prompt 純函式——同輸入同輸出,含四分類定義,不讀 UserDefaults/不發網路。
    func testPromptIsPureAndDeterministic() {
        let a = ResponseCueExtractor.buildPrompt(
            committed: "我對這個寫入效能有點擔心", recentContext: "先前在討論 schema")
        let b = ResponseCueExtractor.buildPrompt(
            committed: "我對這個寫入效能有點擔心", recentContext: "先前在討論 schema")
        XCTAssertEqual(a.system, b.system)
        XCTAssertEqual(a.user, b.user)

        for kind in MeetingCueKind.allCases {
            XCTAssertTrue(a.system.contains(kind.rawValue), "system prompt 缺 \(kind.rawValue) 定義")
        }
        XCTAssertTrue(a.system.contains("不要只靠問號"), "必須明示陳述句質疑不可漏(umbrella AC-4)")
        XCTAssertTrue(a.user.contains("我對這個寫入效能有點擔心"))
        XCTAssertTrue(a.user.contains("先前在討論 schema"))
    }

    /// AC-1(realizes umbrella AC-4):三句 → 三 cue,陳述句質疑(無問號)不得漏。
    /// fake 回腳本化 JSON——這裡鎖的是 extract→parse→分類的管線;
    /// 真實 fast model 的行為由 Task 8 的 DEBUG 人工驗證把關。
    func testDetectsStatementFormChallenge() async {
        let json = """
        {"cues":[
          {"text":"你會怎麼設計一個短網址服務？","kind":"directQuestion"},
          {"text":"我對這個寫入效能有點擔心","kind":"impliedChallenge"},
          {"text":"我們上週上線了 v2","kind":"informational"}
        ]}
        """
        let extractor = ResponseCueExtractor(chat: FakeChatCompleting(reply: json))
        let cues = await extractor.extract(
            committed: "你會怎麼設計一個短網址服務？我對這個寫入效能有點擔心。我們上週上線了 v2。")

        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0].kind, .directQuestion)
        XCTAssertEqual(cues[1].kind, .impliedChallenge, "陳述句質疑(無問號)必須被偵測")
        XCTAssertEqual(cues[1].text, "我對這個寫入效能有點擔心")
        XCTAssertEqual(cues[2].kind, .informational)
    }

    /// AC-2:抽取+四分類 = 恰一次呼叫(單趟非串流,未分兩趟)。
    func testExtractionIsSingleNonStreamingCall() async {
        let fake = FakeChatCompleting(
            reply: #"{"cues":[{"text":"x?","kind":"directQuestion"}]}"#)
        let extractor = ResponseCueExtractor(chat: fake)
        _ = await extractor.extract(committed: "x?")
        XCTAssertEqual(fake.callCount, 1, "抽取與四分類必須合併為單次 completeChat")
    }

    /// 靜默容錯:LLM throw → [](不 throw、不跳 UI)。
    func testLLMFailureReturnsEmpty() async {
        let extractor = ResponseCueExtractor(chat: FakeChatCompleting(shouldThrow: true))
        let cues = await extractor.extract(committed: "任何話")
        XCTAssertTrue(cues.isEmpty)
    }

    /// JSON 契約 golden:欄位名 text/kind、envelope key cues——鎖定,M3 依賴此契約。
    func testGoldenJSONContract() {
        let golden = #"{"cues":[{"text":"這塊 Logan 你來說明一下","kind":"assignedToMe"}]}"#
        let parsed = ResponseCueExtractor.parse(golden)
        XCTAssertEqual(parsed, [ExtractedCue(text: "這塊 Logan 你來說明一下", kind: .assignedToMe)])
    }

    /// 解析容錯:壞 JSON / 未知 kind / 空 text / markdown fence。
    func testParseToleratesGarbage() {
        XCTAssertEqual(ResponseCueExtractor.parse("這不是 JSON"), [])
        XCTAssertEqual(ResponseCueExtractor.parse(#"{"cues":[{"text":"x","kind":"notAKind"}]}"#), [],
                       "未知 kind 整則丟棄")
        XCTAssertEqual(ResponseCueExtractor.parse(#"{"cues":[{"text":"  ","kind":"directQuestion"}]}"#), [],
                       "空 text 丟棄")
        let fenced = """
        ```json
        {"cues":[{"text":"x?","kind":"directQuestion"}]}
        ```
        """
        XCTAssertEqual(ResponseCueExtractor.parse(fenced),
                       [ExtractedCue(text: "x?", kind: .directQuestion)],
                       "模型包 code fence 要能剝掉")
    }
}
```
  Run: 完整指令 + `-only-testing:VoiceInkTests/ResponseCueExtractorTests` — expect **FAIL**（型別不存在）

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/ResponseCueExtractor.swift
import Foundation
import LLMkit

/// fast model 從對方 committed 片段抽出的單則 cue(尚未持久化的中間型別)。
struct ExtractedCue: Codable, Equatable {
    let text: String
    let kind: MeetingCueKind
}

/// 從「對方」的 committed 逐字稿抽出 response cue 並四分類(FR-8/FR-9)。
///
/// - **一次非串流呼叫**:輸出是結構化 JSON、使用者看不到中間產物,不需要逐 token 顯示,
///   所以走既有 `AIService.completeChat`,**不碰 SSE**(SSE 屬 M3;canon §3.3/§3.4)。
/// - **LLM seam**:重用 Ask AI 的 `ChatCompleting`(AskAIService.swift:6-8)——測試注入 fake。
/// - **靜默容錯**:LLM 失敗、JSON 解析失敗一律回 `[]`,不 throw、不跳 UI
///   (與 MeetingLiveTranscriber 的 ASR error 只記 log 同一紀律)。
final class ResponseCueExtractor {

    private let chat: ChatCompleting

    init(chat: ChatCompleting) {
        self.chat = chat
    }

    // MARK: - Prompt(純函式,FR-12)

    /// 四分類定義 + JSON 契約。**不要只靠問號**是本模組的核心要求(umbrella AC-4)。
    static let systemPrompt = """
    你是會議即時輔助的 cue 偵測器。輸入是「對方剛說的話」的即時 ASR 逐字稿(可能有錯字,\
    請判斷語意而非字面)。從中抽出所有「需要我(聽者)回應的東西」,每一則分類為以下四類之一:
    - directQuestion:直接問句(例:「你會怎麼設計一個短網址服務?」)
    - impliedChallenge:陳述句形式的質疑或疑慮——沒有問號,但明顯期待我回應\
    (例:「我對這個寫入效能有點擔心」)
    - assignedToMe:點名或指派我說明/負責某事(例:「這塊 Logan 你來說明一下」)
    - informational:純資訊陳述,不需要我回應(例:「我們上週上線了 v2」)
    注意:**不要只靠問號判斷**——質疑與指派常以陳述句出現,漏抓它們是最嚴重的錯誤。
    沒有任何 cue 時回空陣列。
    只輸出 JSON,不要任何其他文字、不要 markdown code fence,格式:
    {"cues":[{"text":"<cue 原句>","kind":"directQuestion|impliedChallenge|assignedToMe|informational"}]}
    """

    /// 組 prompt。純函式:不讀 UserDefaults、不發網路、同輸入同輸出(FR-12)。
    /// `recentContext` 是留給 M3 調校的滑動窗 seam,M2 預設空字串。
    static func buildPrompt(committed: String, recentContext: String = "") -> (system: String, user: String) {
        var lines: [String] = []
        if !recentContext.isEmpty {
            lines.append("先前上下文(僅供理解,不要從這裡抽 cue):")
            lines.append(recentContext)
            lines.append("")
        }
        lines.append("對方剛說:")
        lines.append(committed)
        return (systemPrompt, lines.joined(separator: "\n"))
    }

    // MARK: - JSON 契約(golden test 鎖定;M3 依賴)

    private struct CueEnvelope: Codable {
        let cues: [RawCue]
    }
    private struct RawCue: Codable {
        let text: String
        let kind: String
    }

    /// 解析 fast model 回的 JSON。任何失敗 → [](沿用 repo `try? JSONDecoder` 容錯慣例)。純函式。
    static func parse(_ raw: String) -> [ExtractedCue] {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 容錯:模型偶爾違反指示包 ```json fence——剝掉再解。
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = trimmed.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(CueEnvelope.self, from: data) else { return [] }
        return envelope.cues.compactMap { raw in
            let text = raw.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let kind = MeetingCueKind(rawValue: raw.kind) else { return nil }
            return ExtractedCue(text: text, kind: kind)
        }
    }

    // MARK: - 抽取(一次非串流呼叫,FR-8)

    func extract(committed: String, recentContext: String = "") async -> [ExtractedCue] {
        let (system, user) = Self.buildPrompt(committed: committed, recentContext: recentContext)
        guard let reply = try? await chat.complete(system: system, user: user) else { return [] }
        return Self.parse(reply)
    }
}

// MARK: - 正式 adapter(形狀照抄 AskAIView.LiveChatCompleter,AskAIView.swift:5-15)

/// 把 `ChatCompleting` 轉呼叫 `AIService.completeChat`(fast model,非串流)。
struct MeetingFastChatCompleter: ChatCompleting {
    let aiService: AIService
    let provider: AIProvider
    var modelName: String?

    func complete(system: String, user: String) async throws -> String {
        try await aiService.completeChat(
            provider: provider, modelName: modelName,
            messages: [ChatMessage.user(user)], systemPrompt: system, timeout: 30)
    }
}
```

- **MIRROR**: `CHAT_COMPLETING_SEAM`（AskAIService.swift:6-8 + AskAIView.swift:5-15 + AskAIAnswerTests.swift:5-12）

- **VALIDATE**: `-only-testing:VoiceInkTests/ResponseCueExtractorTests` — expect **PASS**（6 測試全綠）

- **GOTCHA**: `completeChat` 對 `.ollama`/`.localCLI` 分支會把 messages 攤平成 XML-ish 文字（`AIChatCompletionService.swift:38-49, 93-119`）——JSON-only 輸出對本地小模型較不可靠。M2 不擋使用者選 Ollama，但 parse 失敗回 `[]` 的容錯已覆蓋;真實品質由 Task 8 人工驗證。

- **COMMIT**: `feat(meeting-copilot): ResponseCueExtractor — single non-streaming completeChat, 4-way cue classification`

---

### Task 4: `MeetingCueDeduplicator`（純函式，FR-10）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingCueDeduplicator.swift`
- Test:   `VoiceInkTests/MeetingCueDeduplicatorTests.swift`

- **ACTION**: 正規化（小寫、去標點、壓空白）→ 字元 bigram Jaccard（中文無空白斷詞，bigram 對中英混合都穩健）→ 30 秒時間窗內超過門檻即視為重覆。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingCueDeduplicatorTests.swift
import XCTest
@testable import VoiceInk

final class MeetingCueDeduplicatorTests: XCTestCase {

    func testNormalizeStripsPunctuationAndCase() {
        XCTAssertEqual(
            MeetingCueDeduplicator.normalize("你會怎麼設計 Rate Limiter？"),
            MeetingCueDeduplicator.normalize("你會怎麼設計 rate limiter?"))
    }

    /// AC-4 的純函式半部:「一個」之差的變體在 30 秒內 = 重覆。
    func testSimilarVariantIsDuplicateWithinWindow() {
        let base = Date()
        XCTAssertTrue(MeetingCueDeduplicator.isDuplicate(
            text: "你會怎麼設計一個 rate limiter？",
            at: base.addingTimeInterval(5),
            existing: [(text: "你會怎麼設計 rate limiter？", askedAt: base)]))
    }

    func testDifferentQuestionIsNotDuplicate() {
        let base = Date()
        XCTAssertFalse(MeetingCueDeduplicator.isDuplicate(
            text: "資料庫要選 SQL 還是 NoSQL？",
            at: base.addingTimeInterval(5),
            existing: [(text: "你會怎麼設計 rate limiter？", askedAt: base)]))
    }

    /// 同句超出 30 秒窗 → 不算重覆(對方可能真的又問了一次,這次要重新接)。
    func testSameTextOutsideWindowIsNotDuplicate() {
        let base = Date()
        XCTAssertFalse(MeetingCueDeduplicator.isDuplicate(
            text: "你會怎麼設計 rate limiter？",
            at: base.addingTimeInterval(31),
            existing: [(text: "你會怎麼設計 rate limiter？", askedAt: base)]))
    }

    func testEmptyInputsAreNeverDuplicate() {
        XCTAssertFalse(MeetingCueDeduplicator.isDuplicate(text: "", at: .now, existing: []))
        XCTAssertEqual(MeetingCueDeduplicator.jaccard("", "abc"), 0)
        XCTAssertEqual(MeetingCueDeduplicator.jaccard("", ""), 0)
    }
}
```
  Run: 完整指令 + `-only-testing:VoiceInkTests/MeetingCueDeduplicatorTests` — expect **FAIL**

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingCueDeduplicator.swift
import Foundation

/// cue 去重(FR-10):正規化 → 字元 bigram Jaccard + 時間窗。
/// 純函式 namespace,房子風格鏡射 `MeetingAudioMixer` / `MeetingChannelSplitter`。
///
/// 為什麼是**字元 bigram**而不是空白斷詞:中文沒有空白斷詞,ASR 逐字稿的
/// 中英混合句(「你會怎麼設計 rate limiter」)用 bigram 對兩種文字都穩健。
/// 門檻/窗大小是具名常數——調校時只動這兩個值,不動演算法。
enum MeetingCueDeduplicator {

    /// Jaccard 相似度門檻:>= 即視為重覆。(SRS Open Question 裁決:0.6)
    static let defaultThreshold: Double = 0.6
    /// 只與此時間窗內的既有 cue 比對。(FR-10:30 秒)
    static let defaultWindow: TimeInterval = 30

    /// 正規化:小寫、去標點/符號、壓空白。
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        return String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// 正規化後的字元 bigram 集合。
    static func tokens(_ normalized: String) -> Set<String> {
        let chars = Array(normalized.replacingOccurrences(of: " ", with: ""))
        guard chars.count >= 2 else {
            return chars.isEmpty ? [] : [String(chars[0])]
        }
        var out = Set<String>()
        out.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            out.insert(String(chars[i]) + String(chars[i + 1]))
        }
        return out
    }

    /// bigram Jaccard(0...1)。任一邊為空 → 0。
    static func jaccard(_ a: String, _ b: String) -> Double {
        let ta = tokens(normalize(a))
        let tb = tokens(normalize(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    /// FR-10:與時間窗內任一既有 cue 相似度 >= threshold → 重覆(呼叫端丟棄,不 persist)。
    static func isDuplicate(
        text: String,
        at time: Date,
        existing: [(text: String, askedAt: Date)],
        threshold: Double = defaultThreshold,
        window: TimeInterval = defaultWindow
    ) -> Bool {
        guard !text.isEmpty else { return false }
        for prior in existing where abs(time.timeIntervalSince(prior.askedAt)) <= window {
            if jaccard(text, prior.text) >= threshold { return true }
        }
        return false
    }
}
```

- **MIRROR**: `PURE_FUNCTION_NAMESPACE`（M1 plan 的 `MeetingAudioMixer` / `MeetingChannelSplitter` 房子風格）

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingCueDeduplicatorTests` — expect **PASS**（5 測試全綠）

- **COMMIT**: `feat(meeting-copilot): MeetingCueDeduplicator — normalized bigram Jaccard + 30s window`

---

### Task 5: `MeetingCopilotConfigStore` 擴充（fast model + informational 開關）

**Files:**
- Modify: `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift`
- Test:   `VoiceInkTests/MeetingCopilotConfigStoreTests.swift`

- **ACTION**: 沿用既有樣式加三個欄位。設定 **UI 屬 M5**——M2 只加 store 欄位與預設值（不進 `AppDefaults.registerDefaults`，比照 `RecorderConfigStore` 在 `load()` 內硬寫預設）。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingCopilotConfigStoreTests.swift
import XCTest
@testable import VoiceInk

@MainActor
final class MeetingCopilotConfigStoreTests: XCTestCase {

    private let keys = [
        "meetingCopilotFastProviderV1",
        "meetingCopilotFastModelV1",
        "meetingCopilotShowInformationalCuesV1",
    ]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    func testM2FieldDefaultsAndPersistence() {
        let store = MeetingCopilotConfigStore()
        XCTAssertNil(store.fastProviderName, "未設定 → nil = 跟隨預設 provider")
        XCTAssertNil(store.fastModelName)
        XCTAssertFalse(store.showInformationalCues, "FR-11:informational 預設隱藏")

        store.setFastModel(provider: "openai", model: "gpt-4o-mini")
        store.setShowInformationalCues(true)

        // 新實例重新 load() → 值來自 UserDefaults。
        let reloaded = MeetingCopilotConfigStore()
        XCTAssertEqual(reloaded.fastProviderName, "openai")
        XCTAssertEqual(reloaded.fastModelName, "gpt-4o-mini")
        XCTAssertTrue(reloaded.showInformationalCues)

        // 清空 = removeObject(nil 語意,鏡射 RecorderConfigStore.persistString)。
        store.setFastModel(provider: nil, model: nil)
        XCTAssertNil(MeetingCopilotConfigStore().fastProviderName)
        XCTAssertNil(UserDefaults.standard.object(forKey: "meetingCopilotFastProviderV1"))
    }
}
```
  Run: 完整指令 + `-only-testing:VoiceInkTests/MeetingCopilotConfigStoreTests` — expect **FAIL**（欄位不存在）

- **IMPLEMENT**（追加到既有檔，樣式一字不差地延伸）:
```swift
    // MARK: - Keys(M2 新增)

    private let fastProviderKey = "meetingCopilotFastProviderV1"
    private let fastModelKey = "meetingCopilotFastModelV1"
    private let showInformationalCuesKey = "meetingCopilotShowInformationalCuesV1"
```
```swift
    // MARK: - Settings(M2 新增)

    /// cue 抽取用的 fast model(provider rawValue)。nil = 跟隨 AI Models 的預設 provider
    /// (經 `AskAIAnswerModel.resolve` 解析,見 MeetingCopilotController.makeFastCompleter)。
    @Published private(set) var fastProviderName: String?
    /// fast model 名稱。nil = 用該 provider 的預設 model。
    @Published private(set) var fastModelName: String?
    /// FR-11:informational cue 是否納入 `MeetingCopilotController.cues` 暴露面。
    /// **預設 false**(仍會 persist,只是引擎層不暴露);UI 切換屬 M5。
    @Published private(set) var showInformationalCues: Bool = false
```
`load()` 內追加：
```swift
        fastProviderName = d.string(forKey: fastProviderKey)
        fastModelName = d.string(forKey: fastModelKey)
        showInformationalCues = d.bool(forKey: showInformationalCuesKey)   // 未設定 → false
```
Mutators 追加（含 `persistString` helper，鏡射 `RecorderConfigStore.swift` 的同名函式）：
```swift
    private func persistString(_ value: String?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    func setFastModel(provider: String?, model: String?) {
        fastProviderName = provider
        fastModelName = model
        persistString(provider, fastProviderKey)
        persistString(model, fastModelKey)
    }

    func setShowInformationalCues(_ value: Bool) {
        showInformationalCues = value
        UserDefaults.standard.set(value, forKey: showInformationalCuesKey)
    }
```
另把檔頭註解的「M1 只含三項」改為反映 M2 擴充（fast model + informational 屬 M2；deep model、熱鍵、接地開關屬 M3–M5）。

- **MIRROR**: `CONFIG_STORE`（RecorderConfigStore 的 `persistString` + `setClassifierModel` 雙欄位 mutator 形狀）

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingCopilotConfigStoreTests` — expect **PASS**

- **COMMIT**: `feat(meeting-copilot): config store — fast model + showInformationalCues (M2 fields)`

---

### Task 6: `MeetingCopilotController` — MVP 管線（AC-4/5/9）

**Files:**
- Create: `VoiceInk/Services/MeetingCopilot/MeetingCopilotController.swift`
- Test:   `VoiceInkTests/MeetingCopilotControllerTests.swift`

- **ACTION**: 掛 `onRemoteCommitted` → 背景 Task 抽 cue（LLM await 不佔 main）→ 回 `@MainActor` 去重＋persist（`ModelContext` 非 Sendable）→ 更新 `@Published cues`。`copilotEnabled == false` 時完全不動作。

- **TEST FIRST**:
```swift
// VoiceInkTests/MeetingCopilotControllerTests.swift
import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class MeetingCopilotControllerTests: XCTestCase {

    private let keys = [
        "meetingCopilotEnabledV1",
        "meetingCopilotShowInformationalCuesV1",
    ]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// AC-4:30 秒窗內兩句相似 committed → 只 persist 一則 cue。
    func testDedupesSimilarCuesWithinWindow() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        defer { config.setCopilotEnabled(false) }

        let fake = KeyedFakeChatCompleting(routes: [
            ("一個 rate limiter",
             #"{"cues":[{"text":"你會怎麼設計一個 rate limiter？","kind":"directQuestion"}]}"#),
            ("rate limiter",
             #"{"cues":[{"text":"你會怎麼設計 rate limiter？","kind":"directQuestion"}]}"#),
        ])
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)
        controller.beginSession(appName: "test")

        controller.handleRemoteCommitted("你會怎麼設計 rate limiter？")
        await controller.drainInflight()
        controller.handleRemoteCommitted("你會怎麼設計一個 rate limiter？")
        await controller.drainInflight()

        let persisted = try ctx.fetch(FetchDescriptor<MeetingLiveCue>())
        XCTAssertEqual(persisted.count, 1, "相似 cue 應被去重,只 persist 第一則")
        XCTAssertEqual(controller.cues.count, 1)
        XCTAssertEqual(fake.callCount, 2, "去重在 persist 層,抽取仍每 committed 一次")
    }

    /// AC-5:informational persist 但預設不暴露;打開開關後出現。
    func testInformationalPersistedButHiddenByDefault() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        defer { config.setCopilotEnabled(false) }
        XCTAssertFalse(config.showInformationalCues)

        let fake = FakeChatCompleting(
            reply: #"{"cues":[{"text":"我們上週上線了 v2","kind":"informational"}]}"#)
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)
        controller.beginSession(appName: "test")

        controller.handleRemoteCommitted("我們上週上線了 v2")
        await controller.drainInflight()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 1,
                       "informational 仍要 persist(事後可回顧)")
        XCTAssertTrue(controller.cues.isEmpty, "預設不納入 @Published 暴露面")

        config.setShowInformationalCues(true)
        controller.refreshPublishedCues()
        XCTAssertEqual(controller.cues.count, 1, "打開開關後即暴露")
    }

    /// AC-9:kill switch——extractor 未被呼叫、store 無新 cue、cues 為空。
    func testDisabledCopilotExtractsNothing() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(false)

        let fake = FakeChatCompleting(
            reply: #"{"cues":[{"text":"x?","kind":"directQuestion"}]}"#)
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)

        controller.beginSession(appName: "test")   // no-op
        controller.handleRemoteCommitted("你會怎麼設計 rate limiter？")
        await controller.drainInflight()

        XCTAssertEqual(fake.callCount, 0, "關閉時 ResponseCueExtractor 不得被呼叫")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSession>()).count, 0,
                       "關閉時連 session 都不建")
        XCTAssertTrue(controller.cues.isEmpty)
    }
}
```
  Run: 完整指令 + `-only-testing:VoiceInkTests/MeetingCopilotControllerTests` — expect **FAIL**

- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingCopilotController.swift
import Foundation
import SwiftData
import Combine
import os

/// M2 的 MVP 管線(FR-M2-P3):
/// `MeetingLiveTranscriber.onRemoteCommitted` → `ResponseCueExtractor` → 去重(FR-10)
/// → persist 到 meeting.store → `@Published cues`(informational 依設定過濾,FR-11)。
///
/// 不含 Tier 回應(M3)、不含 overlay(M4)、不含頁面(M5)。
///
/// # Threading
/// `MeetingLiveTranscriber` 與 `onRemoteCommitted` 都在 `@MainActor`
/// (MeetingLiveTranscriber.swift:20)。抽取在 `Task` 內 await——`completeChat` 是
/// async,await 期間**不佔 main**;但 SwiftData `ModelContext` 非 Sendable,
/// 去重+persist 一律回到本類的 `@MainActor` 隔離內執行。
@MainActor
final class MeetingCopilotController: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private let extractor: ResponseCueExtractor
    private let config: MeetingCopilotConfigStore
    private let modelContext: ModelContext

    /// 目前的 live session(beginSession 建立並 persist;copilot 關閉時恆為 nil)。
    private(set) var session: MeetingLiveSession?

    /// 已偵測的 cue(依 `showInformationalCues` 過濾;FR-11)。下游 M3/M4 消費這個。
    @Published private(set) var cues: [MeetingLiveCue] = []

    /// 在途抽取(每個 committed 一個 Task)。測試用 `drainInflight()` 等待。
    private var inflightTasks: [Task<Void, Never>] = []

    init(
        extractor: ResponseCueExtractor,
        config: MeetingCopilotConfigStore,
        modelContext: ModelContext
    ) {
        self.extractor = extractor
        self.config = config
        self.modelContext = modelContext
    }

    // MARK: - Session lifecycle

    /// 建立並 persist 一個新 session。`copilotEnabled == false` 時 no-op(AC-9)。
    func beginSession(appName: String = "") {
        guard config.copilotEnabled else { return }
        let s = MeetingLiveSession(appName: appName)
        modelContext.insert(s)
        try? modelContext.save()
        session = s
        cues = []
    }

    /// 掛上 M1 的接點。**只掛既有 closure,不改 MeetingLiveTranscriber 本體。**
    func attach(to transcriber: MeetingLiveTranscriber, appName: String = "") {
        guard config.copilotEnabled else { return }
        beginSession(appName: appName)
        transcriber.onRemoteCommitted = { [weak self] text in
            self?.handleRemoteCommitted(text)
        }
    }

    func endSession() {
        session?.endedAt = Date()
        try? modelContext.save()
    }

    // MARK: - Cue pipeline

    /// 每段對方 committed → 開一個 Task 抽 cue。立即返回,不阻塞轉錄事件迴圈。
    func handleRemoteCommitted(_ text: String) {
        guard config.copilotEnabled, session != nil else { return }
        let extractor = self.extractor
        let task = Task { [weak self] in
            // completeChat 為 async——await 期間讓出 main;失敗 extractor 已回 []。
            let extracted = await extractor.extract(committed: text)
            guard !Task.isCancelled, !extracted.isEmpty else { return }
            self?.ingest(extracted, sourceText: text, at: Date())
        }
        inflightTasks.append(task)
    }

    /// 去重 + persist + 更新暴露面。@MainActor(context 非 Sendable)。
    func ingest(_ extracted: [ExtractedCue], sourceText: String, at time: Date) {
        guard let session else { return }
        var persistedAny = false
        for e in extracted {
            let existing = (session.cues ?? []).map { (text: $0.text, askedAt: $0.askedAt) }
            if MeetingCueDeduplicator.isDuplicate(text: e.text, at: time, existing: existing) {
                continue   // FR-10:相似 cue 不重覆 persist
            }
            let cue = MeetingLiveCue(
                session: session,
                text: e.text,
                kind: e.kind,
                askedAt: time,
                contextExcerpt: String(sourceText.prefix(300)))
            modelContext.insert(cue)
            persistedAny = true
            logger.notice("🧠 cue [\(e.kind.rawValue, privacy: .public)] \(e.text, privacy: .public)")
        }
        if persistedAny { try? modelContext.save() }
        refreshPublishedCues()
    }

    /// FR-11:informational persist 但預設不暴露;開關切換後呼叫本方法重算。
    func refreshPublishedCues() {
        let all = (session?.cues ?? []).sorted { $0.askedAt < $1.askedAt }
        cues = config.showInformationalCues
            ? all
            : all.filter { $0.kind != .informational }
    }

    /// 測試用:等待所有在途抽取完成。
    func drainInflight() async {
        let tasks = inflightTasks
        inflightTasks.removeAll()
        for task in tasks { await task.value }
    }

    // MARK: - 正式 fast completer 工廠(Task 8 的 DEBUG runner 與未來 M3 共用)

    /// 解析 fast model 並組出正式 `ChatCompleting`。
    /// 借用既有純函式 `AskAIAnswerModel.resolve`(AskAIConfig.swift:31-39)+
    /// AskAIView.swift:431-439 的 provider 回退接線;M3 引入
    /// `MeetingCopilotModels.resolve` 時只需替換這一處。
    static func makeFastCompleter(
        aiService: AIService,
        config: MeetingCopilotConfigStore
    ) -> ChatCompleting {
        let resolved = AskAIAnswerModel.resolve(
            storedProvider: config.fastProviderName,
            storedModel: config.fastModelName,
            defaultProvider: aiService.selectedProvider.rawValue,
            available: aiService.connectedProviders.map(\.rawValue))
        let provider = AIProvider(rawValue: resolved.provider) ?? aiService.selectedProvider
        return MeetingFastChatCompleter(
            aiService: aiService, provider: provider, modelName: resolved.model)
    }
}
```

- **MIRROR**: `CHAT_COMPLETING_SEAM`（seam 注入）＋ `RESOLVE_PURE_FUNCTION`（AskAIView.swift:431-439 的接線）＋ recon-rag threading 紀律（await off-main、context 操作回 MainActor）

- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingCopilotControllerTests` — expect **PASS**（3 測試全綠）

- **GOTCHA**:
  1. 多段 committed 的抽取 Task 併發執行，`ingest` 因 `@MainActor` 序列化——但**完成順序不保證**。去重用 `askedAt` 時間窗比對，不依賴到達順序，所以互換順序結果一致。
  2. `handleRemoteCommitted` 在 closure 裡被 `MeetingLiveTranscriber`（@MainActor）呼叫——同 actor，無跨界問題。
  3. `session.cues` 由 SwiftData 反向關係自動維護——insert cue 帶 `session:` 即入列，不要手動 append。

- **COMMIT**: `feat(meeting-copilot): MeetingCopilotController — commit→extract→dedup→persist→@Published pipeline`

---

### Task 7: 端到端 replay 測試（fake ASR + fake LLM，hermetic）🎯 M2 的驗收（AC-8）

**Files:**
- Create: `VoiceInkTests/MeetingCueDetectionReplayTests.swift`

- **ACTION**: 用 M1 的 replay harness 跑完整偵測鏈：合成 WAV → `ReplayMeetingAudioSource` → `FakeMeetingTranscriptStream`（腳本化三種 committed）→ `MeetingLiveTranscriber.onRemoteCommitted` → controller + fake LLM → 斷言抽出／分類／去重後 persist／暴露面。**不開會議軟體、不碰 CoreAudio、不打真 LLM、不需 API key。**

- **TEST FIRST / IMPLEMENT**（此 task 產出的就是測試）:
```swift
// VoiceInkTests/MeetingCueDetectionReplayTests.swift
import XCTest
import AVFoundation
import SwiftData
@testable import VoiceInk

/// AC-8(M2 的驗收):WAV → 分流 → fake ASR(腳本化三種 committed)→ onRemoteCommitted
/// → MeetingCopilotController → ResponseCueExtractor(fake LLM) → meeting.store。
/// 不開 Teams/Meet、不碰 CoreAudio、不打真 LLM。
/// (真實 fast model 的品質驗證在 Task 8 的 DEBUG 選單,人工執行。)
@MainActor
final class MeetingCueDetectionReplayTests: XCTestCase {

    private var tmpDir: URL!
    private let keys = ["meetingCopilotEnabledV1", "meetingCopilotShowInformationalCuesV1"]
    private var saved: [String: Any?] = [:]

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingCueDetectionReplayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
    }

    /// 合成 WAV(照抄 M1 MeetingCopilotReplayTests——ASR 是 fake,要驗的是接線)。
    private func writeSineWAV(named name: String, hz: Double, seconds: Double) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        let rate = 16_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let ch = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            ch[i] = 0.5 * Float(sin(2.0 * .pi * hz * Double(i) / rate))
        }
        try file.write(from: buffer)
        return url
    }

    func testEndToEndFromWavPersistsClassifiedCues() async throws {
        let wav = try writeSineWAV(named: "remote.wav", hz: 440, seconds: 0.5)

        // 三種 committed:直接問句 / 陳述句質疑(無問號) / 純資訊。
        // 0.5s @16k、chunkFrames=1600 → 約 5 個 chunk;script 掛第 1、3 個,第三句走 finish()。
        let remoteASR = FakeMeetingTranscriptStream(
            script: [
                1: .committed(text: "你會怎麼設計一個短網址服務？"),
                3: .committed(text: "我對這個寫入效能有點擔心"),
            ],
            finalText: "我們上週上線了 v2")
        let source = ReplayMeetingAudioSource(
            remoteURL: wav, localURL: nil, speed: 50.0, chunkFrames: 1600)
        let transcriber = MeetingLiveTranscriber(
            source: source, remoteStream: remoteASR, localStream: nil)

        // fake LLM 依 user prompt 內容路由(不吃併發時序)。
        let fake = KeyedFakeChatCompleting(routes: [
            ("短網址", #"{"cues":[{"text":"你會怎麼設計一個短網址服務？","kind":"directQuestion"}]}"#),
            ("寫入效能", #"{"cues":[{"text":"我對這個寫入效能有點擔心","kind":"impliedChallenge"}]}"#),
            ("上線了 v2", #"{"cues":[{"text":"我們上週上線了 v2","kind":"informational"}]}"#),
        ])

        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        config.setShowInformationalCues(false)
        defer { config.setCopilotEnabled(false) }

        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: context)
        controller.attach(to: transcriber, appName: "replay-test")

        try await transcriber.start()
        try await Task.sleep(for: .milliseconds(800))   // replay 0.5s/50x + 餘裕(M1 同預算)
        await transcriber.stop()
        await controller.drainInflight()

        // 1. 三種 cue 全部抽出且 persist(informational 也 persist——FR-11 只是不暴露)。
        let persisted = try context.fetch(FetchDescriptor<MeetingLiveCue>())
        XCTAssertEqual(persisted.count, 3)
        XCTAssertEqual(Set(persisted.map(\.kind)),
                       [.directQuestion, .impliedChallenge, .informational])

        // 2. 陳述句質疑被偵測——umbrella AC-4 的核心。
        XCTAssertTrue(persisted.contains { $0.kind == .impliedChallenge && $0.text.contains("寫入效能") },
                      "無問號的陳述句質疑不得漏抓")

        // 3. 暴露面:informational 預設隱藏。
        XCTAssertEqual(controller.cues.count, 2)
        XCTAssertFalse(controller.cues.contains { $0.kind == .informational })

        // 4. 全部掛在同一 session(cascade 已由 MeetingLiveModelsTests 覆蓋)。
        XCTAssertTrue(persisted.allSatisfy { $0.session != nil })
        XCTAssertEqual(try context.fetch(FetchDescriptor<MeetingLiveSession>()).count, 1)

        // 5. 抽取每 committed 恰一次(三次呼叫,非串流)。
        XCTAssertEqual(fake.callCount, 3)
    }
}
```

- **MIRROR**: `REPLAY_HARNESS`（M1 `MeetingCopilotReplayTests` 的 WAV 合成、speed 50x、sleep 預算、`FakeMeetingTranscriptStream(script:finalText:)`）

- **VALIDATE**:
  ```bash
  xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
    -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO \
    -only-testing:VoiceInkTests/MeetingCueDetectionReplayTests
  ```
  Expected: **PASS**

- **GOTCHA**: `attach` 會覆寫 `transcriber.onRemoteCommitted`——測試裡**先** attach 再 start（與 production 順序一致）。`finish()` 吐出的第三句 committed 發生在 `stop()` 內、event consumer 取消**之前**（`MeetingLiveTranscriber.swift:169-175` 有 50ms 緩衝），所以 `drainInflight()` 放在 `stop()` 之後能收齊。

- **COMMIT**: `test(meeting-copilot): end-to-end cue detection replay — 3 cue kinds classified, deduped, persisted`

---

### Task 8: DEBUG replay 接上 controller（真 fast model，人工驗證）

**Files:**
- Modify: `VoiceInk/Services/MeetingCopilot/MeetingReplayDebugRunner.swift`
- Modify: `VoiceInk/Views/MenuBarView.swift`（`:58` 呼叫端傳 `aiService`）

- **ACTION**: XCTest 用 fake LLM 鎖住管線；**真實 fast model 對陳述句質疑的判準品質**只能人工驗證（同 M1「真 ASR 走 DEBUG 選單」的哲學）。讓既有的「Replay 會議音檔…（DEBUG）」在 `copilotEnabled == true` 時順帶跑 cue 偵測、把 cue 印進 Console。

- **TEST FIRST**: 無自動化測試（人工驗證工具）。gate 是 compile + Console 肉眼驗證。

- **IMPLEMENT**（`MeetingReplayDebugRunner.swift`）:
  1. 加欄位：`private var controller: MeetingCopilotController?`
  2. `func run() async` → `func run(aiService: AIService?) async`；停止分支順帶 `controller = nil`。
  3. 在 `let t = MeetingLiveTranscriber(...)` 之後、既有 `t.onRemoteCommitted = { ... }` log closure 的**位置**，改為：
```swift
        // M2:copilot 啟用時掛 cue 偵測(真 fast model)。
        // ⚠️ 不能沿用上面的 `context`——那個 container 只含 Transcription,
        //    insert MeetingLiveCue 會掛。DEBUG 驗證用獨立 in-memory meeting container
        //    (persist 的正確性由 XCTest 的 in-memory store 覆蓋)。
        if MeetingCopilotConfigStore.shared.copilotEnabled,
           let aiService,
           let meetingContainer = try? ModelContainer(
               for: MeetingLiveSession.self, MeetingLiveCue.self,
               configurations: ModelConfiguration(isStoredInMemoryOnly: true)) {
            let c = MeetingCopilotController(
                extractor: ResponseCueExtractor(
                    chat: MeetingCopilotController.makeFastCompleter(
                        aiService: aiService, config: .shared)),
                config: .shared,
                modelContext: ModelContext(meetingContainer))
            c.attach(to: t)   // 接管 onRemoteCommitted
            controller = c
        }

        // 保留 committed log:attach 可能已接管 onRemoteCommitted → 包一層。
        let handoff = t.onRemoteCommitted
        t.onRemoteCommitted = { [weak self] text in
            handoff?(text)
            self?.logger.notice("🎧 [replay] COMMITTED ▸ \(text, privacy: .public)")
        }
```
  4. `MenuBarView.swift:58`：`Task { await MeetingReplayDebugRunner.shared.run() }` → `Task { await MeetingReplayDebugRunner.shared.run(aiService: aiService) }`（`aiService` 是既有 `@EnvironmentObject`，`MenuBarView.swift:13`）。

- **MIRROR**: `RESOLVE_PURE_FUNCTION`（模型解析接線）；controller 的 `logger.notice("🧠 cue …")`（Task 6）就是 Console 輸出點

- **VALIDATE**（**人工**）:
  1. compile gate 通過後 `make deploy`（**人工跑**；記憶：不 build 進 /tmp、不自動 deploy）
  2. 設定 `copilotEnabled = true`（暫時可用 `defaults write com.prakashjoshipax.VoiceInk meetingCopilotEnabledV1 -bool true`；UI 開關屬 M5）
  3. 錄一段自己講「**我對這個寫入效能有點擔心**」（陳述句、無問號）與「你會怎麼設計一個短網址服務？」的 WAV
  4. 選單 → 「Replay 會議音檔…（DEBUG）」→ 選檔 → Console.app 過濾 `🧠`
  5. **應看到兩則 cue**：`[impliedChallenge] 我對這個寫入效能…` 與 `[directQuestion] 你會怎麼設計…`——**陳述句質疑被真模型抓到**才算過（umbrella AC-4 的實機半部）
  6. `copilotEnabled = false` 再跑一次 → **無 🧠 log**（kill switch 實機驗證）

- **GOTCHA**: fast model 需要至少一個已連接的 AI provider（`aiService.connectedProviders` 非空）；沒有 key 時 `completeChat` throw → extractor 靜默回 `[]`——Console 沒有 🧠 也沒有 crash，符合「失敗靜默」。

- **COMMIT**: `feat(meeting-copilot): DEBUG replay runs live cue detection with real fast model`

---

### Task 9: Bump build 249 + 全套迴歸

**Files:**
- Modify: `VoiceInk.xcodeproj/project.pbxproj`（`CURRENT_PROJECT_VERSION` 248 → **249**，**只動 :508/:542 的 Debug + Release 兩處**；`:571-622` 的 `= 1` 是其他 target，不要動——發現 5）

- **ACTION**: 收尾。

- **VALIDATE**:
  1. **全套測試**（不只新的——確認零回歸）:
     ```bash
     xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
       -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
       -xcconfig LocalBuild.xcconfig \
       CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
       CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
       SWIFT_ENABLE_EXPLICIT_MODULES=NO
     ```
     EXPECT: **全綠**，特別是 M1 的 `MeetingCopilotReplayTests` / `MeetingCaptureRegressionTests` / `MeetingChannelSplitterTests` 與既有 `AskAIAnswerTests`（`ChatCompleting` seam 與 index.store 零回歸）
  2. `grep -c "CURRENT_PROJECT_VERSION = 249" VoiceInk.xcodeproj/project.pbxproj` → **2**
  3. **回報 build 號給使用者**（專案記憶 `voiceink-report-build-number`），提醒 `make deploy` 後到 Settings → About 確認 build 249
  4. 首次啟動人工確認：app 正常開（三處註冊都對才開得起來），`~/Library/Application Support/com.prakashjoshipax.VoiceInk/meeting.store` 檔案出現

- **COMMIT**: `chore: bump build to 249 (meeting-copilot M2)`

---

## Testing Strategy

### Unit Tests

| Test | Input | Expected | Edge? |
|---|---|---|---|
| `MeetingLiveModelsTests::testDeletingSessionCascadesCues` | session + 3 cues → 刪 session | 0 孤兒 cue | 🔴 AC-6 |
| `…::testKindRoundTripsAndUnknownFallsBack` | 未知 kindRaw | 回退 `.informational` 不崩 | ✅ |
| `…::testTierArrayAccessorsRoundTripAndTolerateGarbage` | 壞 JSON raw | 回 `[]` | ✅ |
| `MeetingStoreRegistrationTests::testInMemoryContainerBacksMeetingStore` | 真 app 的 schema + container func | insert/fetch 成功，不 throw | 🔴 AC-7 |
| `ResponseCueExtractorTests::testDetectsStatementFormChallenge` | 三句(問句/陳述句質疑/資訊) | 三分類正確，陳述句不漏 | 🔴 AC-1 = umbrella AC-4 |
| `…::testExtractionIsSingleNonStreamingCall` | 一段 committed | `complete` 恰一次 | 🔴 AC-2 |
| `…::testPromptIsPureAndDeterministic` | 同輸入 ×2 | 同輸出；含四分類定義 | 🔴 AC-3 |
| `…::testLLMFailureReturnsEmpty` | throwing fake | `[]`，不 throw | ✅ |
| `…::testParseToleratesGarbage` | 壞 JSON／未知 kind／fence | `[]`／丟該則／剝 fence | ✅ |
| `MeetingCueDeduplicatorTests::testSimilarVariantIsDuplicateWithinWindow` | 「一個」之差、5s | duplicate | 🔴 FR-10 |
| `…::testSameTextOutsideWindowIsNotDuplicate` | 同句、31s | not duplicate | ✅ |
| `MeetingCopilotConfigStoreTests::testM2FieldDefaultsAndPersistence` | 全新 defaults | nil/nil/false；set 後重載一致 | — |
| `MeetingCopilotControllerTests::testDedupesSimilarCuesWithinWindow` | 兩段相似 committed | persist 1 則 | 🔴 AC-4 |
| `…::testInformationalPersistedButHiddenByDefault` | informational cue | persist 1、cues 空；開關後出現 | 🔴 AC-5 |
| `…::testDisabledCopilotExtractsNothing` | copilotEnabled=false | 0 呼叫、0 persist、0 session | 🔴 AC-9 |
| `MeetingCueDetectionReplayTests::testEndToEndFromWavPersistsClassifiedCues` | WAV + 腳本化三種 committed + fake LLM | 3 cue 分類正確、persist、informational 隱藏 | 🔴 AC-8（M2 驗收） |

### Edge Cases Checklist
- [x] LLM throw／壞 JSON／markdown fence／未知 kind／空 text
- [x] 未知 kindRaw（向前相容回退）
- [x] 去重：相似變體 in-window／同句 out-of-window／不同問題／空字串
- [x] kill switch（copilotEnabled=false 全鏈路 no-op）
- [x] informational persist-but-hidden 兩態
- [x] cascade 刪除無孤兒
- [x] 三處註冊漏 configurations append（registration test 直接 throw）
- [ ] **真實 fast model 對陳述句質疑的判準** — 只有 Task 8 人工可驗（fake 鎖的是管線不是模型）

---

## Validation Commands

### 編譯（快速 gate，不啟動 host）
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  CODE_SIGNING_ALLOWED=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO build
```
EXPECT: 零錯誤。（compile-only 未簽章沒問題，是最快的 gate。）

### 單元測試（**必須用這個完整形式**）
```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  -only-testing:VoiceInkTests/<TestClass>
```
EXPECT: PASS。

> 🔴 **為什麼不能用普通 `xcodebuild test`**（專案記憶 `voiceink-running-unit-tests`）：
> `VoiceInkTests` 是 **host-app** bundle，runner 會啟動 `VoiceInk.app`。未簽章時 SwiftData 的
> `dictionary` store 用 `.private("iCloud...")` CloudKit → 無 iCloud entitlement 下 `_os_crash`，
> **host 開機即死**。上面的完整形式鏡射 `make local`（ad-hoc 簽章 + `LOCAL_BUILD` flag →
> `#if LOCAL_BUILD` 把 dictionary CloudKit 翻成 `.none`）。`SWIFT_ENABLE_EXPLICIT_MODULES=NO`
> 也是必要的，否則 Xcode 16+ 在 `@testable import` 會失敗。
> **`-only-testing` 仍會編譯所有測試檔**——任一檔編譯錯誤 = 整輪失敗。
> ⚠️ M2 額外注意：**三處註冊漏任一處，host app 本身開機就 fatalError**——所有測試整輪爆掉、
> 錯誤訊息不會指向 schema。看到 host 起不來先檢查 Task 2。

### 部署（**人工執行，不要自動跑**）
```bash
make deploy
```
> 專案記憶 `voiceink-build-no-ghost-apps`：**不要 build 進 /tmp**。不自動 deploy——由使用者自己跑，然後在 Settings → About 確認 build 249。

### 手動驗證
- [ ] app 啟動正常、`meeting.store` 檔案在 Application Support 出現（三處註冊實機確認）
- [ ] Task 8：DEBUG replay + 真 fast model → Console `🧠` 看到 `impliedChallenge`（陳述句質疑被真模型抓到）
- [ ] `copilotEnabled = false`（預設）→ replay 無 `🧠` log、無 LLM 呼叫（kill switch）
- [ ] 既有功能零回歸：語音聽寫、會議錄音落檔、Ask AI 問答（`ChatCompleting`/index.store 未被動壞）

---

## Acceptance Criteria

- [ ] **AC-1**（四分類＋陳述句質疑，= umbrella AC-4）：`ResponseCueExtractorTests::testDetectsStatementFormChallenge` 綠；Task 8 人工以真模型復驗
- [ ] **AC-2**（單次非串流呼叫）：`testExtractionIsSingleNonStreamingCall` 綠——恰一次 `complete`，全 plan 零 SSE 程式碼
- [ ] **AC-3**（prompt 純函式）：`testPromptIsPureAndDeterministic` 綠——同輸入同輸出、含四分類定義、不觸 UserDefaults／網路
- [ ] **AC-4**（去重）：`MeetingCopilotControllerTests::testDedupesSimilarCuesWithinWindow` + `MeetingCueDeduplicatorTests` 綠——30 秒窗內相似 cue 只 persist 一則
- [ ] **AC-5**（informational 預設隱藏但持久化）：`testInformationalPersistedButHiddenByDefault` 綠
- [ ] **AC-6**（cascade）：`MeetingLiveModelsTests::testDeletingSessionCascadesCues` 綠——刪 session 無孤兒 cue
- [ ] **AC-7**（三處註冊）：`MeetingStoreRegistrationTests` 綠（呼叫真 app 碼）＋實機啟動不 fatalError
- [ ] **AC-8**（端到端 replay）：`MeetingCueDetectionReplayTests` 綠——不開會議軟體、不打真 LLM，三種 cue 抽出→分類→去重→persist→暴露面正確
- [ ] **AC-9**（kill switch）：`testDisabledCopilotExtractsNothing` 綠——關閉時零抽取、零 persist、零 session
- [ ] 全套測試零回歸（M1 的 Meeting* 測試與 AskAI* 測試全綠）
- [ ] 編譯零錯誤、零新警告
- [ ] Build 249，已回報給使用者

## Completion Checklist
- [ ] 程式碼遵循既有 pattern（cascade 非對稱語法、JSON-in-raw + @Transient、`ChatCompleting` seam、config store 樣式、純函式 namespace）
- [ ] 每個 @Model stored property 與 @Transient property 都有預設值（lightweight migration）
- [ ] `meeting.store` 三處註冊完整，`cloudKitDatabase: .none`（只存本機）
- [ ] LLM／JSON 失敗全鏈路靜默（不 throw、不跳 UI、不 persist 診斷訊息）
- [ ] `copilotEnabled = false` 時零 LLM 呼叫、零 persist、零 session
- [ ] 沒有硬編碼魔法數（去重門檻/窗、prompt 節錄長度皆為具名常數）
- [ ] 沒有超出 M2 範圍的新增（無 SSE／無 Tier／無 RAG／無 overlay／無 UI 頁面）
- [ ] SRS Open Questions 全部有裁決記錄（見 NOT Building 後的表）

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **真實 fast model 把陳述句質疑漏判成 informational**（功能核心價值） | M | **H** | prompt 明列四分類定義＋陳述句範例＋「不要只靠問號」（FR-12 純函式可迭代調校）；AC-1 鎖管線；Task 8 以真模型人工驗證判準；判準差時換 prompt 不動架構 |
| **三處 schema 註冊漏一處 → launch fatalError** | M | **H** | 完全照抄 index.store 塊；`MeetingStoreRegistrationTests` 呼叫**真 app 碼**把關（發現 4 的可見性調整）；Task 9 實機啟動確認 |
| **本機 ASR 無術語偏置 → cue 抽取輸入失真**（canon §3.8） | **H** | M | M2 修不了 ASR；prompt 明示「輸入可能有錯字、判斷語意」；M5 設定 UI 明示取捨；要術語準確選雲端 ASR（M1 已接） |
| Jaccard bigram 門檻 0.6 過鬆漏刪／過嚴誤刪 | M | M | 具名常數可調；`MeetingCueDeduplicatorTests` 鎖典型案例；不夠用時 M3+ 升級語意去重 |
| cue 抽取每 committed 一次 LLM 呼叫 → token 成本 | M | M | 只用 fast model；抽取＋分類合併單次呼叫；`recentContext`/debounce seam 已留，M3 依實測調 |
| UserDefaults-backed config 測試互相汙染 | M | L | 所有 config 測試 setUp/tearDown save→remove→restore（M1 既有慣例） |
| host-app 測試在 CI/headless 掛掉 | **H** | M | 完整 `xcodebuild test` 形式（專案記憶）；E2E 全 fake，不碰 CoreAudio、不打網路 |
| `appSchema`/`createInMemoryContainer` 可見性調整引入回歸 | L | M | 零行為改變（純可見性＋常數抽出）；全套測試 + compile gate 把關 |
| **🔴 跨里程碑（M4）：`sharingType=.none` 在 macOS 15.4+ 被 SCK 忽略**（canon §3.1） | **H**（分享整螢幕時） | **H** | 不在 M2 範圍，但在此點名：M2 persist 的 cue 上了 M4 overlay 後，「分享整個螢幕」會被錄到；安全模式僅「分享單一視窗/分頁」。M4 必須寫成明確風險＋UI 警告，不得宣稱無條件隱形 |

## Notes

- **M2 刻意不含任何 UI 與串流回應**。交付是「離線 replay 跑出三種分類正確、去重、已持久化的 cue」——這是 M3 三層回應引擎的唯一輸入。
- `MeetingCopilotController.cues`（`@Published`）與 `meeting.store` 是 **M3/M4/M5 的接點**：M3 的 `AnswerCoordinator` 消費 cue 產生 Tier 回應（回寫 M2 預宣告的 `tier*` 欄位）；M4 overlay 渲染 `cues`；M5 頁面查詢 `MeetingLiveSession`。
- JSON 契約（`{"cues":[{"text","kind"}]}`）已由 golden test 鎖定——M3 改契約必須先改 golden test。

---

## 里程碑依賴（本 plan 的前後文）

**本 plan（M2）依賴 M1 已實作完成**——事實上 M1 已 commit（build 248）：`MeetingLiveTranscriber.onRemoteCommitted`、`ReplayMeetingAudioSource`、`FakeMeetingTranscriptStream`、`MeetingCopilotConfigStore` 都是 M1 的交付物，M2 直接消費、一律不重做。

**依賴鏈（canon §2）**：M1（音訊分流，✅ done）→ **M2（本 plan：cue 偵測 + meeting.store）** → M3（三層回應 + SSE + 接地——消費 M2 的 cue 與 `tier*` 欄位）→ M4（overlay + 熱鍵——顯示 M2/M3 的狀態）→ M5（管理頁 + 設定——驅動全部開關）。**M3 的 plan 不得在 M2 未完成前開工**；M4/M5 同理遞延。
