---
linear_issue: null
---
# Plan: Meeting Copilot M3 — 三層回應引擎 + SSE + 接地

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type`。**Mode B（任務先測）**：每個 task 先寫一個鎖行為的測試 → 實作 → 通過 → commit。**Rigor: strict** — 測試 gate 全強制（本里程碑觸碰 LLM 金鑰解析、SSE 網路層、與使用者會議資料的持久化）。
>
> **⚠️ 依賴 M2。** 本 plan 消費 M2 交付的 `MeetingLiveCue` @Model（含 tier 欄位）與 `MeetingCopilotController` 的 `@Published cues`。M2 未合併前，Task 8 之後的任務無法編譯。Task 1–7（SSE client、dispatch、config、resolve、Tier0）不依賴 M2，可先行。
>
> **Checkbox states:** `- [ ]` todo · `- [~]` in-progress · `- [x]` done。`[~]` 不是完成。

## Summary

把 M2 抽出的一則 **response cue** 變成「能立刻開口的稿子 + 足以應付 follow-up 的深度分析」：

- **Tier 0**（< 0.5s，**不呼叫 LLM**）：關鍵字種子表 + 本機文字相似度 → 領域標籤 + 2-3 關鍵字。
- **Tier 1**（< 1.5s）：fast model **SSE 串流** → 結構化 `opener` + **恰 3 個** bullets；**最新一則 cue 自動預跑**。
- **Tier 2**（< 15s，點擊才跑）：deep model SSE，**user message 帶入 Tier 1 草稿全文** → `analysis` + `followUps[]` + `uncertainties[]`；可取消。

接地三來源全部**靜默降級**：會前 brief（`MeetingLiveSession.brief`）、RAG（**直呼** `LiveEmbedder().embed` + `RetrievalService.retrieve`，**絕不用 `AskAIService.ask`**）、螢幕 OCR（`ScreenCaptureService.captureAndExtractText()`，**只在 Tier 2 擷取一次**）。

因 LLMkit 的 `"stream": false` 寫死且為遠端不可編輯套件，M3 在 repo 內自持 `StreamingChatClient`（house style 照 `ElevenLabsDiarizingClient`），並在 `AIService` 新增 `streamChat`（鏡射 `completeChat` 的 dispatch，與其並存不改它）。**M3 不含任何 UI**——tier 結果落 `MeetingLiveCue`，由 M4 讀取渲染。驗證全走 fake SSE server（`URLProtocol` 注入）+ `FakeStreamingChatCompleting`，不開會議軟體、不出網路。

## User Story

As a 開會時被問到技術問題的使用者, I want 系統在我按下熱鍵前就備好一句可直接說出口的開場 + 三個要點，並能按需展開帶 follow-up 預判的深度分析, so that 我開口的頭五秒不再空白，且答案針對**我們的專案**而非教科書。

## Problem → Solution

`AIService.completeChat` 是整包回傳（LLMkit `OpenAILLMClient.swift:167` 的 `"stream": false` 寫死），首字延遲 = 整包延遲，對「開口稿」場景體感差；且 Ask AI 的 RAG 入口 `AskAIService.ask()` 會把空索引/無 key 的診斷訊息 **persist 成可見聊天訊息**，不能當背景接地用。
→ repo 內自持 SSE client（兩 parser：OpenAI-compat + Anthropic 線格式完全不同）、`AIService.streamChat` 並存新增；接地直呼 `LiveEmbedder().embed` + `RetrievalService.retrieve`（空索引回 `[]` 不 throw），全包自己的 do/catch 靜默降級。

## Metadata
- **Module**: meeting-copilot
- **Parent Plan**: N/A（M1 plan：`docs/plans/meeting-copilot-m1-audio-backbone.plan.md`）
- **Source PRD**: N/A
- **Source Feature SRS**: `docs/srs/meeting-copilot-m3-tiered-response.srs.md`（umbrella：`docs/srs/meeting-copilot-live-assist.srs.md`）
- **Source Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source Linear Issue**: N/A（`docs/prp.config.yml` → `skip: true`）
- **Type**: feature ｜ **Size**: L ｜ **Complexity**: Large
- **Rigor**: strict ｜ **Mode**: B — 任務先測 ｜ **TDD**: on（task-level）｜ **Commit cadence**: per-task
- **Estimated Files**: ~21（10 created + 2 modified + 9 test files）
- **Build**: 249 → **250**（M2 交付 249；`CURRENT_PROJECT_VERSION`，Debug + Release 兩處）
- **FR 覆蓋**: FR-13 ~ FR-20、FR-27、FR-28
- **AC 覆蓋**: AC-5 ~ AC-14

---

## ⚠️ 規劃期發現（寫 plan 時交叉驗證 codebase / 上游文件的結論，實作前必讀）

### 發現 1 — 兩種 SSE wire format 完全不同，`StreamingChatClient` 必須有兩個 parser（canon §3.3）

OpenAI-compat 與 Anthropic 的線格式、auth header、system prompt 位置、reasoning 注入**全都不同**：

| 面向 | OpenAI-compat（default 分支） | Anthropic 分支 |
|---|---|---|
| endpoint | `provider.baseURL` **已是完整** `/v1/chat/completions` URL（`OpenAILLMClient.swift:152` 直接 `URLRequest(url: baseURL)`，不加路徑）| 硬寫 `https://api.anthropic.com/v1/messages`（`AnthropicLLMClient.swift:228`，忽略傳入 baseURL）|
| auth | `Authorization: Bearer <key>` | `x-api-key: <key>` + `anthropic-version: 2023-06-01`（**非 Bearer**）|
| system prompt | `.system(...)` 插入 messages[0] | top-level `system` 欄位 + 濾掉 system-role 訊息；nil 時**省略** key（custom encoder）|
| delta | `data: {json}` 行，`choices[0].delta.content`；終止 `data: [DONE]` | `event:<type>` + `data:` 成對；text 在 `delta.text`（`type == "text_delta"`）；終止 `event: message_stop`（**無 `[DONE]`**）|
| reasoning | `reasoning_effort` + extraBody flat（**只在 default 分支注入**，`ReasoningConfig.swift:53-82`）| 兩者皆不用 |
| temperature | `1.0` if model 前綴 `gpt-5` else `0.3` | 無 temperature；`max_tokens` 預設 8192 |

### 發現 2 — `AskAIError` 是 dead code；`AskAIService.ask()` **不是**靜默路徑（canon §3.2）

grep 確認 `AskAIError`（`.noEmbeddingKey`/`.indexEmpty`）全 repo 從未被 throw——**不要**把靜默降級建構在 catch 它之上。`AskAIService.ask()` 在空索引/embed 失敗時會 **persist 一則可見 assistant `AskAIMessage`**（中文診斷字串，`AskAIService.swift:124-141, 159-174`）並顯示在聊天 UI。真正的訊號是：`RetrievalService.retrieve` 空索引回 `[]` **不 throw**（`RetrievalService.swift:58,70`）；`EmbeddingClient.embed` 無 key 時 throw `EmbeddingError.missingAPIKey(provider)`（`EmbeddingClient.swift:113-116`）——這是**唯一**的 error 訊號，在自己的 do/catch 吞掉即可。

### 發現 3 — LLMkit 的 request/response struct 全 `private`；`chatAPIKey` 也是 file-private（canon §3.4）

`OpenAIChatResponse`、`AnthropicRequest/Message/ContentBlock/Response` 全部 `private`（`OpenAILLMClient.swift:125-135`、`AnthropicLLMClient.swift:115-146`），不可跨 module 重用；只有 `ChatMessage` public。M3 在 repo 內自定義串流 delta 的 `Decodable` struct。另外 `AIService.chatAPIKey(for:modelName:)` 是 `AIChatCompletionService.swift` 的 **file-private**（:89），`streamChat` 在新檔案裡呼叫不到——**照抄**它的解析邏輯（`APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue)`，missing/empty → `EnhancementError.notConfigured`）。SSE 用 `URLSession.bytes(for:)`，**先檢查 HTTP status 再消費 byte stream**；LLMkit 的 `performRequest`（ephemeral + retry）不能重用。

### 發現 4 — 失敗必須靜默：`NotificationManager.showNotification` 三重不合格

(1) 渲染可見 borderless `NSPanel` 且**無 `sharingType`** → 分享螢幕時 toast 被廣播；(2) `.error` 呼叫 `SoundManager.shared.playEscSound()` → 會議中可聞的 ding；(3) `makeKeyAndOrderFront` 搶焦點（`NotificationManager.swift:12-99`）。FR-28：M3 一律 **log-only**，任何失敗不得產生可見 UI。

### 發現 5 — 螢幕 OCR 只能抓「前景 focused 視窗」，且 reentrancy guard 是 per-instance

`ScreenCaptureService.captureAndExtractText()`（`ScreenCaptureService.swift:40-62`）：instance method、`async`、無 throws、無參數，**每個失敗路徑都回 nil**（逾時 3.0s / 無視窗 / SCK error / 權限未授予）——silent-nil 正好滿足 FR-20，無需額外錯誤處理。但它**沒有任何 API 指定目標視窗**：只抓 NSWorkspace 前景 app 的 AX-focused 視窗（:92-180）。使用者切到 Slack 時 OCR **靜默讀到 Slack**——M3 接受此行為（盡力接地，非保證）。`isCapturing` guard 是 **per-instance**（`RecordingContextSnapshot.swift:49` 每次 new 一個實例就繞過了）→ `MeetingGroundingProvider` 必須持有**單一**長生命週期實例。`processID != currentPID` 已排除自家視窗，M4 overlay 不會被 OCR 讀回。

### 發現 6 — RAG 執行緒紀律：embed off-main → MainActor retrieve；model tag 不符靜默回空

`RetrievalService` 整個 enum 是 `@MainActor` 且 `retrieve` 同步（`RetrievalService.swift:30`）；`EmbeddingClient.embed` 是 non-isolated async。embed 輸出**已 L2-normalized**，直接餵 retrieve，不要再 normalize。retrieve 只比對 `embeddingModel == model.tag` 的 chunk——query 用不同 model 嵌入時**靜默回 `[]`**，所以 model 一律取 `TranscriptIndexService.shared.model`（UserDefaults `askAIEmbeddingModelV1`）。retrieve **無 score threshold**，永遠回 top-k；剛擷取的會議可能尚未索引（upsert 在 `.transcriptionCompleted` 才跑）→ 回 `[]` 是**正常**，非錯誤。ModelContext 必須是 main-actor 的 `container.mainContext`（單一 container 跨全部 store，才能同時 fetch `EmbeddingChunk` 與 `Transcription`）。

### 發現 7 — `AIEnhancementOutputFilter` 只能對完整字串套用一次，不可逐 delta

它以非貪婪多行正則剝 `<think>/<thinking>/<reasoning>` **整塊**（`AIEnhancementOutputFilter.swift:3-21`），需要開閉兩個 tag 都在。`completeChat` 對最終整包套一次（`AIChatCompletionService.swift:76`）。M3：generator **累積完整串流字串後套一次**，再 parse、再落 SwiftData。M3 無 UI，raw delta 不會顯示給任何人，所以不需要 think-tag 內緩衝（該 Open Question 留給 M4 決定 overlay 的漸進渲染策略）。

### 發現 8 — 鄰接里程碑的誠實邊界（本 plan 不處理，但風險登記須貫穿）

- **M4**：`sharingType = .none` 在 **macOS 15.4+ 被 ScreenCaptureKit 忽略**（Apple DTS 明言無公開 API 可防擷取；Chrome/Meet 的 `getDisplayMedia` 走 SCK）。對 M3 的牽連：M3 產生的答案文字就是 overlay 要顯示的內容——分享整螢幕時有外洩到會議畫面的殘餘風險。M4 必須做 UI 警告，不得宣稱無條件隱形。
- **M2**：三處 schema 註冊（master `Schema`、`createPersistentContainer`、`createInMemoryContainer`）漏一處 = launch crash——**屬 M2**，M3 不新增 @Model、不碰 schema 註冊。
- **M5**：`ViewType` 的 `title`/`sidebarSections` 非 exhaustive switch 陷阱——屬 M5，M3 無 UI。

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/meeting-copilot-m3-tiered-response.srs.md` | all | 本里程碑需求 + AC-5~AC-14 + Open Questions 的傾向決策 |
| P0 | 專案記憶 `voiceink-running-unit-tests` | all | **測試指令必須照它寫**，否則 host-app crash（CloudKit `_os_crash`）|
| P0 | `VoiceInk/Services/AIEnhancement/AIChatCompletionService.swift` | 4-77（dispatch）、79-101（`chatAPIKey`）| `streamChat` 鏡射的對象：五分支 dispatch、model/key 解析、filter 套用時機 |
| P0 | `VoiceInk/Transcription/Cloud/ElevenLabsDiarizingClient.swift` | 1-99 | **house style 照抄對象**：struct + static async + 專屬 Error enum + 顯式 HTTP 檢查 + pure parse |
| P0 | `.local-build/SourcePackages/checkouts/LLMkit/Sources/LLMkit/LLM/OpenAILLMClient.swift` | 22-73、125-135 | OpenAI-compat request 的**逐 key 形狀**（改 `stream:true` 其餘照抄）；private struct 證據 |
| P0 | `.local-build/SourcePackages/checkouts/LLMkit/Sources/LLMkit/LLM/AnthropicLLMClient.swift` | 19-67、115-146 | Anthropic request 形狀：x-api-key、top-level system、nil 省略 system key |
| P0 | `VoiceInk/Services/AskAI/RetrievalService.swift` | 6-82 | `AskAIScope`/`ScoredChunk`/retrieve 簽章與 @MainActor 紀律 |
| P0 | `VoiceInk/Services/AskAI/AskAIService.swift` | 6-8（`ChatCompleting`）、70-79（`buildUserBlock`）、124-141（**反面教材**：可見診斷路徑）| seam 先例 + [n] 編號慣例 + 為何不能走 ask() |
| P1 | `VoiceInk/Services/AIEnhancement/ReasoningConfig.swift` | 53-82 | default 分支必須複製的 `reasoning_effort` + extraBody 注入 |
| P1 | `VoiceInk/Services/AIEnhancement/AIEnhancementOutputFilter.swift` | 3-21 | 只能整包套一次的 filter |
| P1 | `VoiceInk/Services/ScreenCaptureService.swift` | 40-62、92-180 | OCR 的 silent-nil 行為與前景視窗限制 |
| P1 | `VoiceInk/Services/AskAI/TranscriptIndexService.swift` | 6-14 | `EmbeddingProviding` 協定 + `LiveEmbedder`（RAG 的注入 seam，**直接重用**）|
| P1 | `VoiceInk/Services/AskAI/AskAIConfig.swift` | 25-39 | `AskAIAnswerModel.resolve` — `MeetingCopilotModels.resolve` 的鏡射對象 |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | all | M1 交付的 store（本 plan 擴充它，樣式不變）|
| P1 | `VoiceInk/Services/AIEnhancement/AIService.swift` | 4-55（`AIProvider` + `baseURL`）、234-266（`connectedProviders`）、469-474（`selectedModel(for:)`）| provider 名冊、connected 驗證、model 解析 |
| P2 | `docs/srs/meeting-copilot-m2-cue-detection.srs.md` | Delta、FR | M2 交付的 `MeetingLiveCue` 欄位與 `MeetingCopilotController` 接點（M3 的輸入）|
| P2 | `VoiceInk/Models/AskAIModels.swift` | 8-39 | `EmbeddingChunk` 欄位（`sourceKind == "meeting"` scope）|
| P2 | 專案記憶 `voiceink-report-build-number`、`voiceink-build-no-ghost-apps` | all | bump build 並回報；不 build 進 /tmp；不自動 deploy |

## External Documentation

- OpenAI-compat SSE 格式與 Anthropic SSE event 格式：**已由 recon 定案**（見「規劃期發現 1」表格），無需再查。Anthropic 端若遇未知 event type（`ping`/`content_block_start`…）一律忽略、只取 `content_block_delta`+`text_delta`，這是向前相容的正確姿勢。

---

## Patterns to Mirror

### DISPATCH — `completeChat` 的 provider 分支（`streamChat` 逐分支鏡射）
```swift
// SOURCE: VoiceInk/Services/AIEnhancement/AIChatCompletionService.swift:4-77
extension AIService {
    func completeChat(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        let resolvedModel = modelName?.isEmpty == false ? modelName! : selectedModel(for: provider)

        let result: String
        switch provider {
        case .anthropic:
            result = try await AnthropicLLMClient.chatCompletion(
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                timeout: timeout
            )
        // …(.custom / .ollama / .localCLI 分支省略——M3 串流不做這三支)…
        default:
            guard let baseURL = URL(string: provider.baseURL) else {
                throw EnhancementError.notConfigured
            }
            let temperature = resolvedModel.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3
            let reasoningEffort = ReasoningConfig.getReasoningParameter(
                for: provider,
                modelName: resolvedModel
            )
            let extraBody = ReasoningConfig.getExtraBodyParameters(
                for: provider,
                modelName: resolvedModel
            )
            result = try await OpenAILLMClient.chatCompletion(
                baseURL: baseURL,
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: temperature,
                reasoningEffort: reasoningEffort,
                extraBody: extraBody,
                timeout: timeout
            )
        }

        return AIEnhancementOutputFilter.filter(result)
    }
```

### KEY_RESOLUTION — `chatAPIKey`（file-private，`streamChat` 照抄邏輯）
```swift
// SOURCE: VoiceInk/Services/AIEnhancement/AIChatCompletionService.swift:89-101
    private func chatAPIKey(for provider: AIProvider, modelName: String) throws -> String {
        if provider == .custom {
            guard let customConfiguration = CustomAIProviderManager.shared.requestConfiguration(forModel: modelName) else {
                throw EnhancementError.notConfigured
            }
            return customConfiguration.apiKey
        }

        guard let key = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue), !key.isEmpty else {
            throw EnhancementError.notConfigured
        }
        return key
    }
```

### HOUSE_STYLE — `ElevenLabsDiarizingClient`（`StreamingChatClient` 照抄形態）
```swift
// SOURCE: VoiceInk/Transcription/Cloud/ElevenLabsDiarizingClient.swift:1-99（節錄）
enum ElevenLabsDiarizingError: Error {
    case missingAPIKey
    case http(Int, String)
    case noWords
}

/// In-repo ElevenLabs speech-to-text client with speaker diarization (`diarize=true`).
///
/// The bundled `LLMkit.ElevenLabsClient` is a remote, non-editable dependency that only parses
/// `text`, so diarization lives here instead.
struct ElevenLabsDiarizingClient {
    /// Pure: decode the ElevenLabs diarized JSON → text + merged speaker segments.
    static func parse(_ data: Data) throws -> Result { ... }

    static func transcribeDiarized(audioData: Data, fileName: String, apiKey: String,
                                   model: String, language: String?, numSpeakers: Int?,
                                   detectSpeakerRoles: Bool = false, noVerbatim: Bool = false,
                                   timeout: TimeInterval) async throws -> Result {
        guard !apiKey.isEmpty else { throw ElevenLabsDiarizingError.missingAPIKey }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        // …headers…
        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ElevenLabsDiarizingError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let result = try parse(data)
        guard !result.segments.isEmpty else { throw ElevenLabsDiarizingError.noWords }
        return result
    }
}
```
> 照抄的八個要素：(1) plain `struct` + `static async throws`；(2) 專屬 top-level Error enum 帶 associated value；(3) `guard !apiKey.isEmpty` 先 throw；(4) 顯式 `!(200..<300).contains(statusCode)` → `.http(status, bodyString)`；(5) `req.timeoutInterval = timeout`；(6) pure 可測 `parse` 獨立 static func；(7) doc comment 說明為何繞過 LLMkit；(8) `URLSession.shared`（SSE 改用 `.bytes(for:)`，**status 先於消費**）。

### OPENAI_REQUEST — 逐 key 照抄（只把 `stream` 改 true + `Accept` header）
```swift
// SOURCE: LLMkit/Sources/LLMkit/LLM/OpenAILLMClient.swift:152-183（節錄）
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        // Prepend system prompt if provided explicitly
        var allMessages = messages
        if let systemPrompt, !systemPrompt.isEmpty {
            allMessages.insert(.system(systemPrompt), at: 0)
        }

        var bodyDict: [String: Any] = [
            "model": model,
            "messages": allMessages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "stream": false          // ← M3 串流版改 true
        ]

        if let reasoningEffort {
            bodyDict["reasoning_effort"] = reasoningEffort
        }

        if let extraBody {
            for (key, value) in extraBody {
                bodyDict[key] = value
            }
        }
```

### ANTHROPIC_REQUEST — x-api-key + top-level system（nil 時省略 key）
```swift
// SOURCE: LLMkit/Sources/LLMkit/LLM/AnthropicLLMClient.swift:228-253（節錄）
        let url = URL(string: "https://api.anthropic.com/v1/messages")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        // Extract system prompt: explicit parameter takes priority, then system messages from array
        let system: String?
        let nonSystemMessages: [ChatMessage]
        if let systemPrompt {
            system = systemPrompt
            nonSystemMessages = messages.filter { $0.role != "system" }
        } else {
            let systemMessages = messages.filter { $0.role == "system" }
            system = systemMessages.isEmpty ? nil : systemMessages.map(\.content).joined(separator: "\n")
            nonSystemMessages = messages.filter { $0.role != "system" }
        }
// SOURCE: AnthropicLLMClient.swift:286-292 — custom encode 在 nil 時省略 system key
        if let system { try container.encode(system, forKey: .system) }
```
> M3 用 `JSONSerialization` dict 組 body（LLMkit struct 是 private），nil 時**不插入** `system` key 即等價。

### REASONING — default 分支必須複製的注入（Anthropic 分支兩者皆不用）
```swift
// SOURCE: VoiceInk/Services/AIEnhancement/ReasoningConfig.swift:53-82（節錄）
    static func getReasoningParameter(for provider: AIProvider, modelName: String) -> String? {
        switch provider {
        case .gemini:
            if geminiNoneReasoningModels.contains(modelName) { return "none" }
            else if geminiLowReasoningModels.contains(modelName) { return "low" }
            else if geminiMinimalReasoningModels.contains(modelName) { return "minimal" }
        case .openAI:
            if openAINoneReasoningModels.contains(modelName) { return "none" }
        case .cerebras:
            if cerebrasGPTOSSMinimumReasoningModels.contains(modelName) { return "low" }
            else if cerebrasNoneReasoningModels.contains(modelName) { return "none" }
        case .groq:
            if groqGPTOSSMinimumReasoningModels.contains(modelName) { return "low" }
            else if groqQwenReasoningModels.contains(modelName) { return "none" }
        default:
            return nil
        }
        return nil
    }

    static func getExtraBodyParameters(for provider: AIProvider, modelName: String) -> [String: Any]? {
        if provider == .cerebras && modelName == "gpt-oss-120b" {
            return ["reasoning_format": "hidden"]
        } else if provider == .groq && (modelName == "openai/gpt-oss-120b" || modelName == "openai/gpt-oss-20b") {
            return ["include_reasoning": false]
        }
        return nil
    }
```

### OUTPUT_FILTER — 只能整包套一次
```swift
// SOURCE: VoiceInk/Services/AIEnhancement/AIEnhancementOutputFilter.swift:3-21
struct AIEnhancementOutputFilter {
    static func filter(_ text: String) -> String {
        var processedText = text
        let patterns = [
            #"(?s)<thinking>(.*?)</thinking>"#,
            #"(?s)<think>(.*?)</think>"#,
            #"(?s)<reasoning>(.*?)</reasoning>"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(processedText.startIndex..., in: processedText)
                processedText = regex.stringByReplacingMatches(in: processedText, options: [], range: range, withTemplate: "")
            }
        }

        return processedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

### RAG_DIRECT — 底層 embed + retrieve（**不走** `AskAIService.ask`）
```swift
// SOURCE: VoiceInk/Services/AskAI/TranscriptIndexService.swift:6-14
protocol EmbeddingProviding {
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]]
}

struct LiveEmbedder: EmbeddingProviding {
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        try await EmbeddingClient.embed(texts: texts, model: model)
    }
}

// SOURCE: VoiceInk/Services/AskAI/RetrievalService.swift:29-33 — @MainActor、同步、空索引回 []
@MainActor
enum RetrievalService {
    static func retrieve(queryVector: [Float], scope: AskAIScope, k: Int,
                         model: EmbeddingModel, context: ModelContext) -> [ScoredChunk] { ... }
}

// SOURCE: VoiceInk/Services/AskAI/AskAIService.swift:122-124 — query embed 的呼叫姿勢
let queryText = String(trimmed.prefix(6000))
let queryVectors = try await embedder.embed(texts: [queryText], model: model)
guard let queryVector = queryVectors.first else { /* embed failure branch */ }
```

### USER_BLOCK — 檢索片段的 [n] 編號慣例（M3 複製此慣例）
```swift
// SOURCE: VoiceInk/Services/AskAI/AskAIService.swift:70-79
static func buildUserBlock(question: String, chunks: [ScoredChunk]) -> String {
    var lines: [String] = []
    for (i, scored) in chunks.enumerated() {
        let excerpt = String(scored.chunk.text.prefix(800))
        lines.append("[\(i + 1)] \(excerpt)")
    }
    lines.append("")
    lines.append("問題:\(question)")
    return lines.joined(separator: "\n")
}
```

### MODEL_RESOLVE — `AskAIAnswerModel.resolve`（純函式，`MeetingCopilotModels.resolve` 鏡射）
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
```

### SCREEN_OCR — 唯一簽章（silent-nil 即 FR-20 的降級）
```swift
// SOURCE: VoiceInk/Services/ScreenCaptureService.swift:40-62
    func captureAndExtractText() async -> String? {
        guard !isCapturing else { return nil }

        isCapturing = true
        defer {
            isCapturing = false
        }
        // …SCShareableContent → findActiveWindow → SCScreenshotManager → Vision OCR…
        // 每個失敗路徑（timeout 3.0s / 無視窗 / SCK error / 權限未授予）都 return nil
    }
```

### CHAT_SEAM — `ChatCompleting`（`StreamingChatCompleting` 的並列先例）
```swift
// SOURCE: VoiceInk/Services/AskAI/AskAIService.swift:5-8
/// 回答生成的可注入介面(測試用 fake,正式走 AIService.completeChat)。
protocol ChatCompleting {
    func complete(system: String, user: String) async throws -> String
}
```

### CONFIG_STORE — M1 交付的樣式（擴充時一字不差沿用）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift（M1，節錄）
@MainActor
final class MeetingCopilotConfigStore: ObservableObject {
    static let shared = MeetingCopilotConfigStore()
    private let copilotEnabledKey = "meetingCopilotEnabledV1"
    @Published private(set) var copilotEnabled: Bool = false
    init() { load() }
    private func load() {
        let d = UserDefaults.standard
        copilotEnabled = d.bool(forKey: copilotEnabledKey)   // 未設定 → false
    }
    func setCopilotEnabled(_ value: Bool) {
        copilotEnabled = value
        UserDefaults.standard.set(value, forKey: copilotEnabledKey)
    }
}
```

### TEST_STRUCTURE（全部測試照抄）
```swift
// SOURCE: VoiceInkTests/MeetingAudioMixerTests.swift:1-16
import XCTest
@testable import VoiceInk

final class MeetingAudioMixerTests: XCTestCase {
    func testMixAveragesAllChannelsToMono() {
        let tap: [[Float]] = [[1, 1], [0, 0]]
        let mic: [[Float]] = [[0.5, 0.5]]
        XCTAssertEqual(MeetingAudioMixer.mixToMono(channelBuffers: tap + mic, frameCount: 2), [0.5, 0.5])
    }
}
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/AIEnhancement/StreamingChatClient.swift` | CREATE | 自持 SSE client（兩 parser）+ `StreamingChatError` |
| `VoiceInk/Services/AIEnhancement/AIServiceStreaming.swift` | CREATE | `AIService.streamChat` extension + `StreamingChatCompleting` 協定 + `LiveStreamingChatCompleter` + `FakeStreamingChatCompleting` |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotModels.swift` | CREATE | `resolve()` 純函式（fast/deep）|
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | UPDATE | 擴充 8 個設定欄位 |
| `VoiceInk/Services/MeetingCopilot/TierTypes.swift` | CREATE | `Tier0Result` / `Tier1Draft` / `Tier2Analysis` / `MeetingGrounding`（`FollowUp` 已在 M2 的 `MeetingLiveModels.swift`）|
| `VoiceInk/Services/MeetingCopilot/Tier0Classifier.swift` | CREATE | 關鍵字表 + embedding 相似度，**無 LLM** |
| `VoiceInk/Services/MeetingCopilot/TierPrompts.swift` | CREATE | Tier1/Tier2 的 system+user prompt 純函式建構（含不得編造禁令）|
| `VoiceInk/Services/MeetingCopilot/TierParsers.swift` | CREATE | 串流字串 → `Tier1Draft` / `Tier2Analysis` 純函式解析 |
| `VoiceInk/Services/MeetingCopilot/MeetingGroundingProvider.swift` | CREATE | brief + RAG + 螢幕 OCR，靜默降級 |
| `VoiceInk/Services/MeetingCopilot/AnswerCoordinator.swift` | CREATE | Tier1→Tier2 序列、預跑、取消 |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotController.swift` | UPDATE | 接 `AnswerCoordinator`：新 cue → Tier0 + 預跑 Tier1（M2 交付此檔，M3 擴充）|
| `VoiceInk.xcodeproj/project.pbxproj` | UPDATE | `CURRENT_PROJECT_VERSION` 249 → 250（Debug + Release 兩處）|
| `VoiceInkTests/StreamingChatClientTests.swift` | CREATE | AC-11、AC-12（`URLProtocol` 注入 SSE）|
| `VoiceInkTests/StreamChatDispatchTests.swift` | CREATE | dispatch + filter 套用時機 |
| `VoiceInkTests/MeetingCopilotModelsTests.swift` | CREATE | resolve 回退 |
| `VoiceInkTests/Tier0KeywordTests.swift` | CREATE | AC-5 |
| `VoiceInkTests/TierGeneratorTests.swift` | CREATE | AC-6、AC-8、AC-14 |
| `VoiceInkTests/GroundingTests.swift` | CREATE | AC-9、AC-10 |
| `VoiceInkTests/AnswerCoordinatorTests.swift` | CREATE | AC-7、AC-13 |

> pbxproj 只改 build number；新 `.swift` 由 `PBXFileSystemSynchronizedRootGroup` 自動入 target。

## NOT Building（M3 明確不做）

- 所有 UI / overlay / 熱鍵 / `sharingType` / 說話淡出的**呈現** → **M4**
- cue 偵測 / 分類 / 去重（`ResponseCueExtractor`）→ **M2**（M3 消費既有 cue）
- `AIService.completeChat` 本身 → 不改，`streamChat` 並存
- RAG 索引 / 嵌入 / 檢索核心 → 唯讀重用 `RetrievalService` + `EmbeddingClient`
- `ScreenCaptureService` 實作 / 指定目標視窗 → 不改，接受「只抓前景視窗」
- `.ollama` / `.localCLI` 串流 → M3 只做 `.anthropic` 與 default（OpenAI-compat）
- 管理頁 / 設定 UI / 雙 model picker → **M5**（M3 只加 config 資料層）
- think-tag 內漸進緩衝 → 留給 M4 的 overlay 渲染策略（M3 無 UI，raw delta 不顯示給任何人）

---

## Step-by-Step Tasks

### Task 1: StreamingChatError + StreamingChatClient（OpenAI-compat parser）

**Files:** Create `VoiceInk/Services/AIEnhancement/StreamingChatClient.swift`；Test `VoiceInkTests/StreamingChatClientTests.swift`

- **ACTION**: 自持 SSE client 的骨架 + OpenAI-compat parser，逐 delta 吐 `AsyncThrowingStream<String, Error>`。
- **TEST FIRST**:
```swift
// VoiceInkTests/StreamingChatClientTests.swift
import XCTest
@testable import VoiceInk

/// 用 URLProtocol 注入假 SSE 回應，完全不出網路。
final class StreamingChatClientTests: XCTestCase {

    override func setUp() { MockSSEProtocol.reset() }

    /// AC-11：OpenAI-compat parser 依序吐出 3 段 delta，[DONE] 終止。
    func testOpenAIParserEmitsDeltasInOrder() async throws {
        MockSSEProtocol.body = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"你\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"好\"}}]}",
            "data: {\"choices\":[{\"delta\":{\"content\":\"嗎\"}}]}",
            "data: [DONE]",
        ].joined(separator: "\n\n") + "\n\n"

        let session = MockSSEProtocol.makeSession()
        var deltas: [String] = []
        let stream = StreamingChatClient.streamOpenAI(
            baseURL: URL(string: "https://mock.local/v1/chat/completions")!,
            apiKey: "k", model: "m", messages: [.user("hi")],
            systemPrompt: nil, temperature: 0.3, reasoningEffort: nil, extraBody: nil,
            timeout: 5, session: session)
        for try await d in stream { deltas.append(d) }
        XCTAssertEqual(deltas, ["你", "好", "嗎"])
    }

    /// 非 2xx → throw .http(status, body)，未吐任何 delta。
    func testHTTPErrorThrowsBeforeDeltas() async {
        MockSSEProtocol.status = 500
        MockSSEProtocol.body = "upstream boom"
        let session = MockSSEProtocol.makeSession()
        let stream = StreamingChatClient.streamOpenAI(
            baseURL: URL(string: "https://mock.local/v1/chat/completions")!,
            apiKey: "k", model: "m", messages: [.user("hi")],
            systemPrompt: nil, temperature: 0.3, reasoningEffort: nil, extraBody: nil,
            timeout: 5, session: session)
        do {
            for try await _ in stream { XCTFail("不該吐 delta") }
            XCTFail("應 throw")
        } catch let StreamingChatError.http(code, body) {
            XCTAssertEqual(code, 500); XCTAssertTrue(body.contains("boom"))
        } catch { XCTFail("錯誤型別: \(error)") }
    }

    func testMissingKeyThrows() async {
        let stream = StreamingChatClient.streamOpenAI(
            baseURL: URL(string: "https://mock.local/x")!, apiKey: "", model: "m",
            messages: [.user("hi")], systemPrompt: nil, temperature: 0.3,
            reasoningEffort: nil, extraBody: nil, timeout: 5, session: .shared)
        do { for try await _ in stream {}; XCTFail("應 throw") }
        catch StreamingChatError.missingAPIKey {} catch { XCTFail("錯誤型別") }
    }
}

/// 最小 URLProtocol：把 body 當成一個「完整回應」回放（bytes(for:) 會逐行讀）。
final class MockSSEProtocol: URLProtocol {
    static var body = ""
    static var status = 200
    static func reset() { body = ""; status = 200 }
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockSSEProtocol.self]
        return URLSession(configuration: cfg)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let resp = HTTPURLResponse(url: request.url!, statusCode: Self.status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
```
  Run: 上方 canon §4 完整指令 + `-only-testing:VoiceInkTests/StreamingChatClientTests` — expect **FAIL**（型別不存在）
- **IMPLEMENT**:
```swift
// VoiceInk/Services/AIEnhancement/StreamingChatClient.swift
import Foundation

enum StreamingChatError: Error {
    case missingAPIKey
    case http(Int, String)
    case emptyResponse
}

/// In-repo SSE streaming chat client. 兩 parser：OpenAI-compat 與 Anthropic。
///
/// 存在理由（照 ElevenLabsDiarizingClient 先例）：LLMkit 是遠端不可編輯的 SPM 套件，其
/// OpenAILLMClient/AnthropicLLMClient 的 body 寫死 `"stream": false`，且 request/response
/// struct 全 private。SSE 需 `URLSession.bytes(for:)`，先檢查 HTTP status 再消費 byte stream。
enum StreamingChatClient {

    // MARK: - OpenAI-compat（data: {json} + [DONE]）

    private struct OpenAIChunk: Decodable {
        struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta? }
        let choices: [Choice]?
    }

    static func streamOpenAI(
        baseURL: URL, apiKey: String, model: String, messages: [ChatMessage],
        systemPrompt: String?, temperature: Double, reasoningEffort: String?,
        extraBody: [String: Any]?, timeout: TimeInterval, session: URLSession = .shared
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw StreamingChatError.missingAPIKey }
                    var req = URLRequest(url: baseURL)
                    req.httpMethod = "POST"
                    req.timeoutInterval = timeout
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    var all = messages
                    if let systemPrompt, !systemPrompt.isEmpty { all.insert(.system(systemPrompt), at: 0) }
                    var body: [String: Any] = [
                        "model": model,
                        "messages": all.map { ["role": $0.role, "content": $0.content] },
                        "temperature": temperature,
                        "stream": true,
                    ]
                    if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
                    if let extraBody { for (k, v) in extraBody { body[k] = v } }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    try Self.checkStatus(response, bytes: bytes)

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(OpenAIChunk.self, from: data),
                              let piece = chunk.choices?.first?.delta?.content, !piece.isEmpty
                        else { continue }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Shared

    /// 消費 byte stream **之前**先檢查 HTTP status（照 ElevenLabsDiarizingClient:578-583）。
    private static func checkStatus(_ response: URLResponse, bytes: URLSession.AsyncBytes) async throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }
        // 錯誤時 body 常是小段 JSON，收集起來塞進 .http
        var collected = ""
        for try await line in bytes.lines { collected += line; if collected.count > 2000 { break } }
        throw StreamingChatError.http(http.statusCode, collected)
    }
}
```
- **VALIDATE**: `-only-testing:VoiceInkTests/StreamingChatClientTests` 的三個 OpenAI 測試 PASS（Anthropic 測試 Task 2 才加）。
- **COMMIT**: `feat(meeting-copilot): StreamingChatClient — OpenAI-compat SSE parser`

---

### Task 2: StreamingChatClient — Anthropic parser

**Files:** Modify `StreamingChatClient.swift`；Modify `StreamingChatClientTests.swift`

- **ACTION**: 加 Anthropic parser（`event:`/`text_delta`/`message_stop`，x-api-key，top-level system）。
- **TEST FIRST**（追加）:
```swift
// AC-12
func testAnthropicParserEmitsTextDeltasAndTerminatesOnMessageStop() async throws {
    MockSSEProtocol.body = [
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"分\"}}",
        "event: content_block_delta",
        "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"片\"}}",
        "event: message_stop",
        "data: {\"type\":\"message_stop\"}",
    ].joined(separator: "\n") + "\n\n"
    let session = MockSSEProtocol.makeSession()
    var deltas: [String] = []
    let stream = StreamingChatClient.streamAnthropic(
        apiKey: "k", model: "claude-x", messages: [.user("hi")], systemPrompt: "你是專家",
        maxTokens: 1024, timeout: 5, session: session)
    for try await d in stream { deltas.append(d) }
    XCTAssertEqual(deltas, ["分", "片"])
    // 驗 request header 由 MockSSEProtocol 側錄（見下）
    XCTAssertEqual(MockSSEProtocol.lastHeaders["x-api-key"], "k")
    XCTAssertEqual(MockSSEProtocol.lastHeaders["anthropic-version"], "2023-06-01")
    XCTAssertNil(MockSSEProtocol.lastHeaders["Authorization"])
}
```
  並在 `MockSSEProtocol.startLoading` 開頭側錄 header：`Self.lastHeaders = request.allHTTPHeaderFields ?? [:]`（加 `static var lastHeaders: [String:String] = [:]`）。
- **IMPLEMENT**（加進 `StreamingChatClient`）:
```swift
    private struct AnthropicChunk: Decodable {
        struct Delta: Decodable { let type: String?; let text: String? }
        let type: String?
        let delta: Delta?
    }

    static func streamAnthropic(
        apiKey: String, model: String, messages: [ChatMessage], systemPrompt: String?,
        maxTokens: Int, timeout: TimeInterval, session: URLSession = .shared
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard !apiKey.isEmpty else { throw StreamingChatError.missingAPIKey }
                    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = timeout
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

                    // system 拆成 top-level；messages 濾掉 system role
                    let sys: String?
                    if let systemPrompt, !systemPrompt.isEmpty { sys = systemPrompt }
                    else {
                        let s = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
                        sys = s.isEmpty ? nil : s
                    }
                    let nonSystem = messages.filter { $0.role != "system" }
                    var body: [String: Any] = [
                        "model": model,
                        "max_tokens": maxTokens,
                        "messages": nonSystem.map { ["role": $0.role, "content": $0.content] },
                        "stream": true,
                    ]
                    if let sys { body["system"] = sys }   // nil 時省略 key（等價 LLMkit custom encoder）
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await session.bytes(for: req)
                    try Self.checkStatus(response, bytes: bytes)

                    for try await line in bytes.lines {
                        // Anthropic：只取 data: 行且 type==content_block_delta / delta.type==text_delta
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(AnthropicChunk.self, from: data)
                        else { continue }
                        if chunk.type == "message_stop" { break }
                        if chunk.type == "content_block_delta",
                           chunk.delta?.type == "text_delta",
                           let text = chunk.delta?.text, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
```
- **VALIDATE**: `-only-testing:VoiceInkTests/StreamingChatClientTests` 全綠（OpenAI + Anthropic）。
- **COMMIT**: `feat(meeting-copilot): StreamingChatClient — Anthropic SSE parser`

---

### Task 3: AIService.streamChat + StreamingChatCompleting seam

**Files:** Create `AIServiceStreaming.swift`；Test `StreamChatDispatchTests.swift`

- **ACTION**: `streamChat` 鏡射 `completeChat` 的 dispatch（anthropic vs default），解析 model/key/reasoning。加可注入協定 + fake。
- **TEST FIRST**:
```swift
// VoiceInkTests/StreamChatDispatchTests.swift
import XCTest
@testable import VoiceInk

@MainActor
final class StreamChatDispatchTests: XCTestCase {
    /// fake completer 依腳本吐 delta；累積字串在結束後套 filter 一次。
    func testFakeStreamingAccumulatesAndFiltersOnce() async throws {
        let fake = FakeStreamingChatCompleting(script: ["<think>ignore</think>可", "以", "開口"])
        var out = ""
        for try await d in fake.stream(system: "s", user: "u") { out += d }
        // raw 串流含 <think>；呼叫端負責在結束後 filter
        XCTAssertEqual(AIEnhancementOutputFilter.filter(out), "可以開口")
        XCTAssertEqual(fake.callCount, 1)
    }
}
```
- **IMPLEMENT**:
```swift
// VoiceInk/Services/AIEnhancement/AIServiceStreaming.swift
import Foundation

/// 串流版可注入 seam（與既有 ChatCompleting 並列，AskAIService.swift:6-8）。
protocol StreamingChatCompleting {
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error>
}

extension AIService {
    /// completeChat 的串流並存版。只做 .anthropic 與 default(OpenAI-compat) 兩分支。
    func streamChat(
        provider: AIProvider, modelName: String?, messages: [ChatMessage],
        systemPrompt: String?, timeout: TimeInterval = 60
    ) -> AsyncThrowingStream<String, Error> {
        let resolvedModel = modelName?.isEmpty == false ? modelName! : selectedModel(for: provider)
        // key 解析照抄 chatAPIKey（它是 file-private）
        func key() throws -> String {
            guard let k = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue), !k.isEmpty
            else { throw EnhancementError.notConfigured }
            return k
        }
        switch provider {
        case .anthropic:
            return AsyncThrowingStream { c in
                let t = Task {
                    do {
                        let inner = StreamingChatClient.streamAnthropic(
                            apiKey: try key(), model: resolvedModel, messages: messages,
                            systemPrompt: systemPrompt, maxTokens: 4096, timeout: timeout)
                        for try await d in inner { c.yield(d) }
                        c.finish()
                    } catch { c.finish(throwing: error) }
                }
                c.onTermination = { _ in t.cancel() }
            }
        default:
            return AsyncThrowingStream { c in
                let t = Task {
                    do {
                        guard let baseURL = URL(string: provider.baseURL) else { throw EnhancementError.notConfigured }
                        let temp = resolvedModel.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3
                        let inner = StreamingChatClient.streamOpenAI(
                            baseURL: baseURL, apiKey: try key(), model: resolvedModel,
                            messages: messages, systemPrompt: systemPrompt, temperature: temp,
                            reasoningEffort: ReasoningConfig.getReasoningParameter(for: provider, modelName: resolvedModel),
                            extraBody: ReasoningConfig.getExtraBodyParameters(for: provider, modelName: resolvedModel),
                            timeout: timeout)
                        for try await d in inner { c.yield(d) }
                        c.finish()
                    } catch { c.finish(throwing: error) }
                }
                c.onTermination = { _ in t.cancel() }
            }
        }
    }
}

/// 正式 completer：包 streamChat（system+user → messages）。
struct LiveStreamingChatCompleter: StreamingChatCompleting {
    let aiService: AIService
    let provider: AIProvider
    var modelName: String?
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        aiService.streamChat(provider: provider, modelName: modelName,
                             messages: [.user(user)], systemPrompt: system, timeout: 60)
    }
}

/// 測試用：腳本化 delta，忽略輸入。
final class FakeStreamingChatCompleting: StreamingChatCompleting, @unchecked Sendable {
    private let script: [String]
    private let error: Error?
    private(set) var callCount = 0
    private(set) var lastUser = ""
    private(set) var lastSystem = ""
    init(script: [String] = [], error: Error? = nil) { self.script = script; self.error = error }
    func stream(system: String, user: String) -> AsyncThrowingStream<String, Error> {
        callCount += 1; lastUser = user; lastSystem = system
        let script = self.script; let error = self.error
        return AsyncThrowingStream { c in
            for s in script { c.yield(s) }
            if let error { c.finish(throwing: error) } else { c.finish() }
        }
    }
}
```
- **MIRROR**: DISPATCH / KEY_RESOLUTION / REASONING / CHAT_SEAM。
- **VALIDATE**: `-only-testing:VoiceInkTests/StreamChatDispatchTests` PASS。
- **COMMIT**: `feat(meeting-copilot): AIService.streamChat + StreamingChatCompleting seam`

---

### Task 4: MeetingCopilotModels.resolve（fast/deep 純函式）

**Files:** Create `MeetingCopilotModels.swift`；Test `MeetingCopilotModelsTests.swift`

- **ACTION**: 鏡射 `AskAIAnswerModel.resolve`，重新驗證 provider 仍 connected。
- **TEST FIRST**:
```swift
func testFallsBackWhenProviderDisconnected() {
    // Groq 已存但不在 available（key 被移除）→ 回退預設
    let r = MeetingCopilotModels.resolve(storedProvider: "Groq", storedModel: "llama-3.1-8b-instant",
                                         defaultProvider: "Anthropic", available: ["Anthropic", "OpenAI"])
    XCTAssertEqual(r.provider, "Anthropic"); XCTAssertNil(r.model)
}
func testHonorsStoredWhenConnected() {
    let r = MeetingCopilotModels.resolve(storedProvider: "Groq", storedModel: "llama-3.1-8b-instant",
                                         defaultProvider: "Anthropic", available: ["Groq", "Anthropic"])
    XCTAssertEqual(r.provider, "Groq"); XCTAssertEqual(r.model, "llama-3.1-8b-instant")
}
```
- **IMPLEMENT**:
```swift
// VoiceInk/Services/MeetingCopilot/MeetingCopilotModels.swift
import Foundation

enum MeetingCopilotModels {
    /// fast / deep 各解析一次。available = aiService.connectedProviders 的 rawValue。
    static func resolve(storedProvider: String?, storedModel: String?,
                        defaultProvider: String, available: [String]) -> (provider: String, model: String?) {
        if let sp = storedProvider, !sp.isEmpty, available.contains(sp) {
            let m = (storedModel?.isEmpty == false) ? storedModel : nil
            return (sp, m)
        }
        return (defaultProvider, nil)
    }
}
```
- **MIRROR**: MODEL_RESOLVE。
- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingCopilotModelsTests` PASS。
- **COMMIT**: `feat(meeting-copilot): MeetingCopilotModels.resolve (fast/deep, re-validates connected)`

---

### Task 5: MeetingCopilotConfigStore 擴充（8 欄）

**Files:** Modify `MeetingCopilotConfigStore.swift`；Test 併入 `MeetingCopilotModelsTests.swift`

- **ACTION**: 加 fast/deep provider+model、prefetchEnabled、domainPersona、useHistoryRAG、useScreenContext。沿用 M1 樣式。
- **TEST FIRST**:
```swift
func testConfigStoreNewDefaults() {
    let keys = ["meetingCopilotFastProviderV1","meetingCopilotFastModelV1","meetingCopilotDeepProviderV1",
                "meetingCopilotDeepModelV1","meetingCopilotPrefetchV1","meetingCopilotPersonaV1",
                "meetingCopilotUseRAGV1","meetingCopilotUseScreenV1"]
    keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    let s = MeetingCopilotConfigStore()
    XCTAssertEqual(s.fastProvider, "Groq")
    XCTAssertEqual(s.fastModel, "llama-3.1-8b-instant")
    XCTAssertTrue(s.prefetchEnabled)
    XCTAssertTrue(s.useHistoryRAG)
    XCTAssertTrue(s.useScreenContext)
    XCTAssertFalse(s.domainPersona.isEmpty)
}
```
- **IMPLEMENT**（追加到 store，鏡射 CONFIG_STORE 樣式；`@Published private(set)` + `…V1` key + `set…()` + `load()`）:
```swift
    @Published private(set) var fastProvider: String = "Groq"
    @Published private(set) var fastModel: String = "llama-3.1-8b-instant"
    @Published private(set) var deepProvider: String = ""   // "" = 跟隨全域預設
    @Published private(set) var deepModel: String = ""
    @Published private(set) var prefetchEnabled: Bool = true
    @Published private(set) var domainPersona: String = "你是資深後端工程師，專精分散式系統設計與演算法。"
    @Published private(set) var useHistoryRAG: Bool = true
    @Published private(set) var useScreenContext: Bool = true
    // …對應 …V1 key + set…() mutator + 在 load() 內以 (object(forKey:) as? Bool) ?? true 讀 Bool、string(forKey:) 讀 String…
```
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(meeting-copilot): expand config store (fast/deep models, prefetch, grounding toggles)`

---

### Task 6: Tier0Classifier（無 LLM）

**Files:** Create `TierTypes.swift` + `Tier0Classifier.swift`；Test `Tier0KeywordTests.swift`

- **ACTION**: 關鍵字種子表 + 本機字面/相似度 → `Tier0Result`。**不呼叫任何 LLM。**
- **TEST FIRST**（AC-5）:
```swift
func testProducesKeywordsWithoutLLMCall() {
    let fake = FakeStreamingChatCompleting(script: ["SHOULD NOT BE CALLED"])
    let r = Tier0Classifier.classify(cueText: "你會怎麼設計一個支援每秒十萬寫入的短網址服務？")
    XCTAssertFalse(r.keywords.isEmpty)
    XCTAssertFalse(r.domainLabel.isEmpty)
    XCTAssertEqual(fake.callCount, 0, "Tier0 不得呼叫 LLM")
}
```
- **IMPLEMENT**: `TierTypes.swift` 定義 `Tier0Result/Tier1Draft/Tier2Analysis/MeetingGrounding`；`Tier0Classifier.classify(cueText:)` 用一張後端/演算法領域關鍵字表（system-design/algorithm/database/concurrency…）做關鍵字命中 + 命中數決定 `domainLabel`。純函式、零 I/O。（Open Question：日後可加 `EmbeddingChunk` 相似度補強；M3 先種子表。）
- **VALIDATE**: `-only-testing:VoiceInkTests/Tier0KeywordTests` PASS。
- **COMMIT**: `feat(meeting-copilot): Tier0Classifier — keyword-based, zero LLM`

---

### Task 7: TierPrompts + TierParsers + Tier1（開口稿）

**Files:** Create `TierPrompts.swift` + `TierParsers.swift`；Test `TierGeneratorTests.swift`

- **ACTION**: Tier1 的 system+user prompt 純函式建構（含 persona + brief + RAG）；串流字串 → `Tier1Draft`（`opener` + 恰 3 bullets）。
- **TEST FIRST**（AC-6 + AC-14 的 prompt 契約）:
```swift
func testTier1ParserProducesOpenerAndExactlyThreeBullets() {
    let raw = "OPENER: 我會先確認 QPS 與讀寫比再決定要不要分片。\n- 先問清楚規模\n- 讀多寫少可加快取\n- 寫爆才考慮分庫"
    let draft = TierParsers.parseTier1(raw)
    XCTAssertEqual(draft.opener, "我會先確認 QPS 與讀寫比再決定要不要分片。")
    XCTAssertEqual(draft.bullets.count, 3)
}
func testDeepSystemPromptForbidsFabrication() {
    let sys = TierPrompts.tier2System(persona: "你是後端專家")
    XCTAssertTrue(sys.contains("不要") && (sys.contains("捏造") || sys.contains("編造")))
}
```
- **IMPLEMENT**: `TierPrompts.tier1System/tier1User/tier2System/tier2User`（純函式，Tier2 system 含明確「不得捏造 benchmark 數字／論文／公司名，不確定寫進 uncertainties」禁令＝FR-27/FR-14）；`TierParsers.parseTier1`（容忍 partial 的標記格式：`OPENER:` 行 + `-` bullets，取前 3）、`parseTier2`（收完 JSON 或標記段解析成 `Tier2Analysis`）。
- **VALIDATE**: PASS。
- **COMMIT**: `feat(meeting-copilot): tier prompts + parsers (opener + 3 bullets, no-fabrication clause)`

---

### Task 8: MeetingGroundingProvider（brief + RAG + 螢幕，靜默降級）

**Files:** Create `MeetingGroundingProvider.swift`；Test `GroundingTests.swift`

- **ACTION**: 組 `MeetingGrounding`。RAG 直呼 embed+retrieve；螢幕只在 Tier2；全靜默降級。持有**單一** `ScreenCaptureService` 實例。
- **TEST FIRST**（AC-9 + AC-10）:
```swift
@MainActor func testRagInjectedWhenAvailableAndSkippedSilentlyWhenNot() async {
    // fake embedder throw missingAPIKey → grounding.ragChunks 為空、不 throw、不 persist
    let g = MeetingGroundingProvider(embedder: ThrowingEmbedder(), screen: FakeScreen())
    let out = await g.gather(cueText: "x", brief: "訂單分庫 review", includeScreen: false)
    XCTAssertTrue(out.ragChunks.isEmpty)
    XCTAssertEqual(out.brief, "訂單分庫 review")
}
@MainActor func testScreenContextOnlyOnDeepStage() async {
    let screen = FakeScreen()
    let g = MeetingGroundingProvider(embedder: EmptyEmbedder(), screen: screen)
    _ = await g.gather(cueText: "x", brief: "", includeScreen: false)  // Tier0/1
    XCTAssertEqual(screen.callCount, 0)
    _ = await g.gather(cueText: "x", brief: "", includeScreen: true)   // Tier2
    XCTAssertEqual(screen.callCount, 1)
}
```
- **IMPLEMENT**: `gather(cueText:brief:includeScreen:) async -> MeetingGrounding`。RAG 段：`do { let vec = try await embedder.embed(...).first; ... await MainActor.run { RetrievalService.retrieve(...) } } catch { /* 靜默，回空 */ }`。screen 段：`if includeScreen { screenText = await screen.captureAndExtractText() }`（silent-nil）。抽象 `ScreenCapturing` 協定包住 `ScreenCaptureService` 供 fake 注入。
- **MIRROR**: RAG_DIRECT / USER_BLOCK / SCREEN_OCR。
- **VALIDATE**: `-only-testing:VoiceInkTests/GroundingTests` PASS。
- **COMMIT**: `feat(meeting-copilot): grounding provider (brief + RAG direct + screen OCR, silent degrade)`

---

### Task 9: AnswerCoordinator（Tier1→Tier2 序列、預跑、取消、失敗降級）

**Files:** Create `AnswerCoordinator.swift`；Test `AnswerCoordinatorTests.swift`

- **ACTION**: 對 cue 跑 Tier0（即時）+ 預跑最新 cue 的 Tier1；點擊觸發 Tier2（帶 Tier1 草稿）；Tier2 可取消；失敗逐層降級。回寫 `MeetingLiveCue`。
- **TEST FIRST**（AC-7 + AC-8 + AC-13）:
```swift
@MainActor func testPrefetchNewestAndDeepReceivesFastDraft() async throws {
    let fastFake = FakeStreamingChatCompleting(script: ["OPENER: 開口\n- a\n- b\n- c"])
    let deepFake = RecordingStreamingCompleter(script: ["{\"analysis\":\"深\",\"followUps\":[{\"question\":\"q\",\"oneLineAnswer\":\"a\"}],\"uncertainties\":[]}"])
    let coord = AnswerCoordinator(fast: fastFake, deep: deepFake, grounding: NoopGrounding())
    let cue = makeCue(text: "設計短網址")
    await coord.onNewCue(cue)                 // Tier0 + 預跑 Tier1
    XCTAssertEqual(fastFake.callCount, 1)     // AC-7：預跑
    await coord.requestDeep(cue)              // 點擊 Tier2
    XCTAssertTrue(deepFake.lastUser.contains("開口"))  // AC-8：帶入 Tier1 草稿
    XCTAssertFalse(cue.tier2FollowUps.isEmpty)
}
@MainActor func testDeepFailureKeepsFastDraftAndEmitsNoVisibleUI() async {
    let coord = AnswerCoordinator(fast: FakeStreamingChatCompleting(script: ["OPENER: 開口\n- a\n- b\n- c"]),
                                  deep: FakeStreamingChatCompleting(error: StreamingChatError.http(500, "x")),
                                  grounding: NoopGrounding())
    let cue = makeCue(text: "x")
    await coord.onNewCue(cue); await coord.requestDeep(cue)
    XCTAssertEqual(cue.tier1Opener, "開口")   // Tier1 保留
    XCTAssertEqual(cue.status, .tier1)         // 降級：不是 tier2、也不是全失敗
    // 無可見 UI：測試環境無法斷言 NSPanel，但 coordinator 不得呼叫 NotificationManager（code review gate）
}
```
- **IMPLEMENT**: `@MainActor final class AnswerCoordinator: ObservableObject`。`onNewCue`：跑 Tier0（同步）寫 `cue.tier0*`；若 `prefetchEnabled` 對**最新** cue 跑 Tier1（取消前一則未完成的預跑 Task）。`requestDeep`：確保 Tier1 完成 → 組 Tier2 user（含 Tier1 草稿 + grounding）→ 串流累積 → filter → parseTier2 → 寫 `cue.tier2*`、`answeredAt`。所有 `for try await` 包 do/catch，throw 時降級（保留較低 tier、設 status、log-only，**不呼叫 NotificationManager**）。Tier2 task 存 handle 供 `cancelDeep()`。
- **MIRROR**: OUTPUT_FILTER（累積後套一次）。
- **VALIDATE**: `-only-testing:VoiceInkTests/AnswerCoordinatorTests` PASS。
- **COMMIT**: `feat(meeting-copilot): AnswerCoordinator — tier sequence, prefetch, cancel, silent degrade`

---

### Task 10: 接進 MeetingCopilotController + build bump + 全套迴歸

**Files:** Modify `MeetingCopilotController.swift`（M2 交付）；Modify `project.pbxproj`

- **ACTION**: controller 在偵測到新 cue 後呼叫 `AnswerCoordinator.onNewCue`；暴露 coordinator 供 M4 讀。bump build 250。
- **VALIDATE**:
  1. 全套 `-only-testing:VoiceInkTests`（含 M1/M2 迴歸）全綠。
  2. `grep -c "CURRENT_PROJECT_VERSION = 250" VoiceInk.xcodeproj/project.pbxproj` → 2。
  3. 回報 build 250。
- **COMMIT**: `chore: bump build to 250 (meeting-copilot M3)`

---

## Validation Commands

### 編譯（快速 gate）
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  CODE_SIGNING_ALLOWED=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO build
```
EXPECT: 零錯誤。

### 單元測試（host-app，必須用完整形式 — 見 canon §4 / 記憶 voiceink-running-unit-tests）
```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  -only-testing:VoiceInkTests/StreamingChatClientTests
```
（各 test class 逐一；最後跑整包 `-only-testing:VoiceInkTests` 確認零回歸。UI 測試 target 的環境失敗與本模組無關。）

### 部署（人工）
`make deploy` → Settings → About 應顯示 build 250。（不 build 進 /tmp；不自動 deploy。）

---

## Acceptance Criteria

- [ ] **AC-5** Tier0 免 LLM：`Tier0KeywordTests::producesKeywordsWithoutLLMCall`
- [ ] **AC-6** Tier1 opener + 恰 3 bullets：`TierGeneratorTests::...ExactlyThreeBullets`
- [ ] **AC-7** 預跑：`AnswerCoordinatorTests::testPrefetchNewestAndDeepReceivesFastDraft`（callCount==1）
- [ ] **AC-8** Tier2 帶入 Tier1 草稿：同上（lastUser 含 opener）
- [ ] **AC-9** RAG 靜默降級：`GroundingTests::ragInjectedWhenAvailableAndSkippedSilentlyWhenNot`
- [ ] **AC-10** 螢幕只在 Tier2：`GroundingTests::screenContextOnlyOnDeepStage`
- [ ] **AC-11** OpenAI SSE parser：`StreamingChatClientTests::openAIParserEmitsDeltasInOrder`
- [ ] **AC-12** Anthropic SSE parser：`StreamingChatClientTests::anthropicParser...`
- [ ] **AC-13** 失敗靜默降級：`AnswerCoordinatorTests::testDeepFailureKeepsFastDraft...`
- [ ] **AC-14** 不得編造：`TierGeneratorTests::testDeepSystemPromptForbidsFabrication`
- [ ] 全套測試零回歸；編譯零錯誤；Build 250

## Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| SSE parser 對非標準 frame（`ping`/`content_block_start`）處理不當 | M | M | 只取白名單事件（OpenAI 的 `choices[].delta.content` / Anthropic 的 `content_block_delta`+`text_delta`），其餘忽略 |
| `bytes(for:)` 在 status 檢查後才發現錯誤 body 已被部分消費 | L | M | `checkStatus` 在消費 delta 迴圈**之前**呼叫；錯誤時另收集 body |
| RAG 跨 actor 傳 `ModelContext` crash | M | H | embed off-main → `MainActor.run { retrieve(mainContext) }`；不傳 background context |
| 逐 delta 套 filter 導致 `<think>` 半塊外洩 | M | M | 只在累積完整字串後套一次（發現 7）；M3 無 UI 故 raw delta 不顯示 |
| **🔴 M4 邊界**：sharingType 在 SCK 15.4+ 失效 → M3 答案文字有外洩風險 | M | H | M4 誠實 UI 警告；M3 不宣稱隱形。屬 M4 gate |
| screen OCR 讀到非會議前景視窗 | H | L | 接受「盡力接地」；持單一實例避免 reentrancy guard 失效 |

## Notes

- **M3 依賴 M2**：`MeetingLiveCue`（tier 欄位）+ `MeetingCopilotController`。Task 1–7 不依賴 M2 可先行；Task 8–10 需 M2 已合併。
- **依賴鏈**：M1（✅ done）→ M2（cue）→ **M3（本 plan：三層 + SSE + 接地）** → M4（overlay 讀 tier 結果）→ M5（設定驅動）。
- M3 的 tier 結果落 `MeetingLiveCue` 是 **M4 的唯一輸入**；M4 不重算，只渲染。
