---
linear_issue: null
---
# SRS: 會議即時輔助（Live Assist）— 新模組 meeting-copilot

## Metadata
- **Module**: `meeting-copilot`（新模組）
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source PRD**: N/A（2026-07-12 使用者需求）。產品脈絡承接
  `docs/prd/meeting-capture-to-obsidian.prd.md` 中被明確列為 NOT Building 的
  「即時字幕／即時摘要 HUD — 串流即時化另案評估」——本 SRS 就是那個「另案」。
- **Source Linear Issue**: N/A
- **Created**: 2026-07-12
- **Grill level**: 1 (standard)
- **Milestone 切片**（本 umbrella SRS 拆成 5 個里程碑，各有獨立 SRS + plan）:
  - M1 — 音訊分流骨幹 + 離線 replay harness：SRS 併於本文件；`docs/plans/meeting-copilot-m1-audio-backbone.plan.md`（**已實作，build 248**）
  - M2 — cue 偵測引擎：`docs/srs/meeting-copilot-m2-cue-detection.srs.md` + `docs/plans/meeting-copilot-m2-cue-detection.plan.md`（spec'd + planned，未實作）
  - M3 — 三層回應 + SSE + 接地：`docs/srs/meeting-copilot-m3-tiered-response.srs.md` + `docs/plans/meeting-copilot-m3-tiered-response.plan.md`（spec'd + planned，未實作）
  - M4 — 隱蔽 overlay + 熱鍵：`docs/srs/meeting-copilot-m4-overlay-hotkeys.srs.md` + `docs/plans/meeting-copilot-m4-overlay-hotkeys.plan.md`（spec'd + planned，未實作）
  - M5 — 管理頁 + 設定：`docs/srs/meeting-copilot-m5-management-page.srs.md` + `docs/plans/meeting-copilot-m5-management-page.plan.md`（spec'd + planned，未實作）
  - 依賴鏈：M1 ✅ → M2 → M3 → M4 → M5

> ⚠️ **M1 plan 頂部記載了對本 SRS 的四項修正**（E2E 測試不能用真 FluidAudio、ring buffer 已有現成的、
> `handleIO` 已在 realtime thread 配置記憶體、`GraphRates` 丟掉了 tap 聲道數）。
> 實作前先讀 plan 的「規劃期發現」一節；M1 完成後應把結論回寫進本 SRS。

## Feature Summary

在會議進行中，把**對方的語音**與**我的語音**分成兩條獨立串流即時轉錄，從對方的串流中偵測「需要我回應的東西」，
並以全域熱鍵召喚一個**不會被螢幕分享擷取**的浮動 overlay 呈現。回應以**三層漸進揭露**送達：
0.5 秒內先給方向、1.5 秒內給可直接開口的草稿、10 秒內給足以應付 follow-up 的完整分析。

答案以**你的歷史逐字稿**（既有 Ask AI 向量索引）、**會前 brief**、以及**對方正在分享的螢幕內容**為依據，
而非通用教科書答案。領域聚焦後端系統設計與演算法。

新增側欄頁面「會議錄音管理」承載會議列表、雙軌逐字稿、問答紀錄，以及熱鍵、三個模型與 brief 的設定。

---

## 設計核心：瓶頸不是答案品質，是「開口的頭五秒」

模型答得再好，若你必須先讀完三段文字才敢開口，那段沉默本身就是破綻，而且你會低頭盯著螢幕角落。
**本設計的第一原則是把「從偵測到問題」到「你能開口」的時間壓到最短**，而不是把答案寫得最完整。

由此推導出三個決定，它們主導了整份架構：

1. **三層漸進揭露**——不是等一個完美答案，而是先給方向、再給開口稿、最後才給深度。
2. **結構化輸出而非散文**——階段一必須產出「一句可直接說出口的開場 + 3 個 bullet」，讓你**邊講邊讀**。
3. **預跑而非等點擊**——最新問題的階段一在你按熱鍵之前就已經跑完。

---

## 為何是新模組，而不是擴充 recorder-automation

`recorder-automation` 的 Module Spec 明文寫著 out of scope 包含「streaming/real-time classification」，
且該模組已承載擷取＋匯入＋分類＋範本＋匯出＋diarization 六條職責。本功能的 bounded context 完全不同：
它是**低延遲、記憶體內、會議結束即失效**的即時路徑，與 recorder-automation 的**高延遲、落檔、事後可重跑**
批次路徑在一致性需求、失敗語意、資料生命週期上都相反。

兩者的唯一接點是音源：`meeting-copilot` 從 `MeetingCaptureService` 借一個新的即時 PCM seam，
其餘完全自持。會議錄音的**落檔與事後 Obsidian 匯出行為完全不變**，仍走 recorder-automation。

---

## Delta from Current Module State

> 這是新模組。以下列出對**既有模組**的侵入性改動（必須最小化），以及本模組自持的新元件。

### 對既有程式碼的改動（侵入面，刻意壓到最小）

| 既有元件 | 改動 | 理由 |
|---|---|---|
| `MeetingCaptureService` / `MeetingCaptureContext.handleIO` (`Services/Meeting/MeetingCaptureService.swift:73-163`) | **新增一個可選的即時 PCM seam**：在 `mixToMono` 之前，把已 deinterleave 的 `channelScratch` 按聲道分組推進兩個 ring buffer。錄音落檔行為**完全不變**。 | 全案唯一的擷取端新增點；mixToMono 之後資訊已不可逆地遺失。 |
| `CoreAudioRecorder.swift:930-1000` | **抽出**既有的「Float32 多聲道 → mono → 16k Int16 LE（含線性插值 resample）」邏輯成純函式 `PCMDownsampler`，原處改呼叫它。 | 同一份轉換要被即時路徑重用；避免第二份實作漂移。行為等價，可用既有錄音路徑迴歸。 |
| `AIService` (`Services/AIEnhancement/`) | **新增** `streamChat(...) -> AsyncThrowingStream<String, Error>`，與既有 `completeChat` 並存。 | 兩階段回覆要逐字吐出；`completeChat` 是整包回傳（LLMkit 內 `"stream": false` 寫死）。 |
| `RetrievalService` (`Services/AskAI/`) | **唯讀重用**——即時檢索我的歷史逐字稿作為答案依據。不改其實作。 | 見「RAG 接地」。 |
| `ScreenCaptureService` (`Services/`) | **唯讀重用** `captureAndExtractText()` — 取得對方分享畫面的 **OCR 文字**。不改其實作。 | 見「螢幕上下文」。 |
| `ShortcutAction` / `ShortcutMigration` / `RecordingShortcutManager` / `SettingsView` | 新增 `.toggleMeetingCopilotOverlay`（toggle）與 `.peekMeetingCopilotOverlay`（**按住顯示**）。 | 見「Peek 模式」。 |
| **順手修既有缺陷**：`.toggleMeetingRecording` | 補上 `SettingsView` 的 `ShortcutRecorder` row；並加入 `legacyKeyboardShortcutActions`（`ShortcutValidator.allStoredActions` 據此偵測衝突）。 | 該熱鍵自 build 227 加入後**從未有設定 UI**，使用者無法設定，也逃過重複快捷鍵偵測。 |
| `ContentView.swift` / `AppSidebar.swift` | 新增 `ViewType.meetingCopilot`（2 檔 6 處）。 | 「會議錄音管理」頁面。 |
| `VoiceInk.swift` | 新增第 5 個 SwiftData store `meeting.store`（top-level `Schema` + `createPersistentContainer` + `createInMemoryContainer` **三處都要**）。 | 見 Data Models。 |

**明確不動**：`MeetingAudioMixer.mixToMono`、AAC 落檔、`RecorderImportService.importMeetingFile`、
`RecorderPostProcessor`、diarization、Obsidian 匯出。會議錄完之後的一切維持現狀。

---

## 三層漸進揭露（Tiered Disclosure）

| 層 | 目標延遲 | 由誰產生 | 內容 | 目的 |
|---|---|---|---|---|
| **Tier 0** | **< 0.5s** | **不呼叫 LLM** — 關鍵字比對 + 既有 embedding 相似度 | 領域標籤 + 2-3 個關鍵字（`→ 系統設計 · 快取一致性 · 讀寫分離`） | 光看到關鍵字你可能就想起來怎麼答。零等待。 |
| **Tier 1** | **< 1.5s** | fast model（預設 Groq `llama-3.1-8b-instant`），**SSE 串流**，且**已預跑** | **開口稿**：1 句可直接說出口的開場 + 3 個 bullet | 讓你**立刻開口**，然後邊講邊讀 bullet。 |
| **Tier 2** | **< 15s** | deep model，SSE 串流，帶入 Tier 1 草稿 | 完整分析 + **結構化 follow-up 預判** | 你講完開口稿時，深度內容已在螢幕上。 |

Tier 0 **不使用 LLM** 是刻意的：任何 LLM 往返都不可能穩定低於 0.5 秒。改用領域關鍵字表 + 對既有
`EmbeddingChunk` 索引的相似度查詢，皆為本機運算。

### Tier 1 的輸出契約（強制結構，非散文）

```
opener:  String        // 一句話，可直接照著說出口
bullets: [String]      // 恰 3 點，每點 ≤ 20 字
```

`opener` 是整個功能的關鍵欄位。它不是「答案摘要」，而是**一句能讓你開口、爭取時間的話**——
例如「這題我會先問清楚 QPS 跟讀寫比，再決定要不要分片」。overlay 以最大字級單獨呈現它。

### Tier 2 的輸出契約（結構化，非散文）

```
analysis:      String                       // 完整分析
followUps:     [{ question: String,         // 對方接下來很可能追問
                  oneLineAnswer: String }]  // 各一句話答案
uncertainties: [String]                     // 我不確定的點（見「不得編造」）
```

`followUps` 是結構化欄位而非散文，overlay 才能把它排成可掃視的清單——這正是使用者原始需求
「面對 follow up 時也能即時準備好」的載體。

---

## 答案接地（Grounding）— 讓答案「針對我們專案正確」，而非「教科書正確」

三個上下文來源，依序注入 Tier 1 / Tier 2 的 prompt：

### 1. 會前 brief（成本最低、回報最高）
使用者在「會議錄音管理」頁開會前填入一段脈絡（或選一個 Obsidian 筆記 / 文字檔）：
> 「訂單服務分庫方案的 design review。現況單一 Postgres，日訂單 30 萬，痛點是月結時 report query 拖垮寫入。」

存於 `MeetingLiveSession.brief`。注入所有 tier 的 system prompt。

### 2. RAG：檢索我自己的歷史逐字稿（VoiceInk 的獨門優勢）
repo 已有 `EmbeddingChunk` + `RetrievalService`（Ask AI 模組，build 231 已實作）對**全部歷史逐字稿**
做語意檢索。問題抽出後即以其文字檢索 top-k，注入 Tier 1 / Tier 2 的 user block。

效果：「你上個月在 X 會議討論過這題，當時的結論是…」。**市售的任何 meeting copilot 都沒有你的歷史**，
這條護城河是現成的、零額外基建。

**降級**：embedding key 未設定或索引為空 → 靜默跳過檢索，不阻斷回答（`AskAIError.indexEmpty` 已有先例）。

### 3. 螢幕上下文（對方正在分享的畫面）
重用 `ScreenCaptureService.captureAndExtractText()`——它回傳的是 **Vision OCR 後的文字**，不是圖片。
對方分享架構圖 / 程式碼 / 文件時，我們拿到可直接餵給文字模型的 text，**比送圖便宜且快**，也不需要多模態模型。

觸發時機：Tier 2 啟動時擷取一次（Tier 0/1 不擷取，避免拖慢首字延遲）。
**降級**：OCR 無文字或權限未授予 → 靜默跳過。

---

## 問題偵測：抓「需要我回應的東西」，不只抓問號

真實會議中需要回應的往往是**陳述句**：「我對這個 schema 的效能有點擔心」、「這塊我想聽聽你的看法」。
只抓問號會漏掉一半，而漏掉的那一半常是最需要接的。

`ResponseCueExtractor`（取代原本的 `QuestionExtractor`）從 remote 流的 committed 片段抽出 **response cue**，
分為四類：

| 類別 | 說明 | 範例 | 是否預設顯示 |
|---|---|---|---|
| `directQuestion` | 直接問句 | 「你會怎麼設計 rate limiter？」 | ✅ |
| `impliedChallenge` | 隱含質疑／擔憂 | 「我對這個效能有點擔心」 | ✅ |
| `assignedToMe` | 被點名／被指派 | 「這塊 Logan 你來說明一下」 | ✅（高亮） |
| `informational` | 純資訊，不需回應 | 「我們上週上線了 v2」 | ❌（可切換顯示） |

分類由 fast model 一次完成（與抽取同一次呼叫，不額外增加往返）。prompt 建構為純函式，可單元測試。

**去重**：字面相似度（正規化後 Jaccard）+ 30 秒時間窗。不夠用再上模型（見 Open Questions）。

---

## 預跑策略（此決定與初版相反，刻意翻案）

初版 SRS 決定「v1 不預跑，避免燒 token」。**推翻**：

- 只預跑**最新一則** cue 的 **Tier 1**（fast model，極便宜）。
- 體感從「點擊 → 等 1.5 秒」變成「點擊 → 已經在那了」。這是全案**最便宜的體感升級**。
- Tier 2（deep，貴）**維持點擊才跑**，成本可控。
- Tier 0 本來就是本機運算，全部 cue 都跑。

`prefetchEnabled` 設定可關（預設開）。

---

## Overlay 設計

Clone `MeetingIndicatorPanel`（`Views/Meeting/MeetingIndicatorView.swift:39-101`）——已具備
`NSPanel` + `.floating` + `.nonactivatingPanel` + `canBecomeKey == false`（**不搶焦點**）+ `canJoinAllSpaces` + 透明。

### 純新增能力

| 需求 | 作法 | 備註 |
|---|---|---|
| 螢幕分享時不被擷取 | `panel.sharingType = .none` | **全 repo 從未使用過**。正規 macOS API（1Password 等密碼管理器即以此避免自身視窗被錄進畫面）。同時使其不出現在 `getDisplayMedia` 的視窗選擇器，避免誤分享。 |
| 點擊穿透 | `panel.ignoresMouseEvents` 依設定切換 | **全 repo 從未使用過**。 |
| 浮在所有 app 之上 | `panel.level = .screenSaver` | 既有最高是 `NotchRecorderPanel` 的 `.statusBar + 3`。 |
| 不搶焦點 | 沿用 `canBecomeKey = false` | 已具備。 |

### Peek 模式（按住顯示、放開隱藏）

新增第二個熱鍵 `.peekMeetingCopilotOverlay`：**按住顯示、放開隱藏**。比 toggle 更貼合「瞄一眼」的動作，
且不會忘記關掉。

**先例**：`RecordingShortcutManager` 已有 push-to-talk（`RecordingShortcutManager.swift:68, 467, 490`），
其 keyDown/keyUp 分派機制（`:234-258`）可直接沿用——`recordingMode(for:)` 回傳非 nil 的 action 走
keyDown/keyUp 雙邊，而非 `globalUtilityActions` 的 keyUp-only。

兩個熱鍵並存：`.toggleMeetingCopilotOverlay`（釘住）與 `.peekMeetingCopilotOverlay`（瞄一眼）。

### 定位：靠近鏡頭

overlay 錨定於**螢幕上方中央**（而非角落）。理由很實際：你讀 overlay 時的**視線方向會接近看鏡頭**；
若放在角落，眼球飄移會非常明顯。這一條零成本，但決定了你看起來像不像在讀東西。

錨定螢幕：優先取**會議 app 所在的螢幕**，退回 `NSScreen.main`。（全 repo 目前一律硬寫 `NSScreen.main`，
無跟隨邏輯——這是新增。）

### 我說話時自動淡出

local 流（我的麥克風）能量超過門檻 → overlay 不透明度降至 `speakingOpacity`（預設 0.35）；
我停止說話 1.5 秒後恢復。減少我講話時的視覺干擾。能量偵測直接用 ring buffer 的 RMS，零額外成本。

### 視覺規格（餘光可讀，非專心閱讀）

- `opener` 以最大字級單獨呈現（這是你唯一必須讀到的東西）
- bullets 短行、大字、高對比；深色半透明背景
- 最新 cue 永遠在最上方且最大；較舊的 cue 縮成單行並變灰
- 已回答的 cue 自動下沉變灰

---

## 可靠性契約

### 不得編造（最高優先）
你最大的風險不是答不出來，而是**自信地講錯**——那比沉默傷害大得多。

- system prompt **明確禁止**捏造 benchmark 數字、論文、公司名、產品版本。
- 不確定時必須寫進 Tier 2 的 `uncertainties[]`，overlay 以明顯樣式呈現。
- 寧可輸出「這裡需要實測」也不得給出看似精確的假數字。

### 失敗必須靜默
LLM / ASR / 網路失敗時**絕不**跳出 modal 或系統通知——分享螢幕時那會直接暴露本功能的存在。
失敗只在 overlay 內以小字標紅，並降級：

| 失敗 | 降級行為 |
|---|---|
| Tier 2 失敗 | 保留 Tier 1 草稿，標紅一行 |
| Tier 1 失敗 | 保留 Tier 0 關鍵字 |
| ASR 斷線 | 逐字稿停止，**錄音續行**（落檔不受影響），overlay 標示 |
| RAG / 螢幕 OCR 失敗 | 靜默跳過，答案照出（只是少了接地） |

---

## 術語表偏置（誠實的取捨）

repo 已有 `VocabularyWord` 字典，且**雲端串流 provider 已接好** `getCustomVocabularyTerms()`
（`DeepgramStreamingProvider.swift:32`、`SpeechmaticsStreamingProvider.swift:32`、`SonioxStreamingProvider.swift:32`）。

**但 FluidAudio（本機 ASR）不支援術語偏置**——`FluidAudio*StreamingProvider` 完全沒有這條路徑。

因此這是一個**真實的取捨，不能兩全**：

| ASR 選擇 | 免 API key | 隱私（不出本機） | 術語偏置 |
|---|---|---|---|
| FluidAudio Parakeet（**預設**） | ✅ | ✅ | ❌ |
| Deepgram / Speechmatics / Soniox | ❌ | ❌ | ✅ |

設定頁必須**明白告知**：專案代號、服務名稱容易被本機 ASR 轉錯（如「Kafka」→「咖啡卡」），
而轉錯會直接導致 cue 抽取失準。需要術語準確度的使用者應選雲端 ASR。

（讓 FluidAudio 支援偏置屬上游 FluidAudio 的能力，不在本 SRS 範圍。）

---

### New Data Models（新 store：`meeting.store`，`cloudKitDatabase: .none`）

- **NEW** `MeetingLiveSession`（`@Model`）：
  `{ id, startedAt, endedAt, appName, brief, remoteTranscriptRaw, localTranscriptRaw, cues }`
  `@Relationship(deleteRule: .cascade, inverse: \MeetingLiveCue.session)`
- **NEW** `MeetingLiveCue`（`@Model`）：
  `{ id, session, text, kind, askedAt, contextExcerpt, status,
     tier0Keywords, tier1Opener, tier1BulletsRaw, tier2Analysis, tier2FollowUpsRaw, tier2UncertaintiesRaw,
     fastModelName, deepModelName, answeredAt }`

陣列欄位（bullets / followUps / uncertainties）沿用 repo 慣例的 **JSON-in-raw-String + `@Transient` 快取**
（`Transcription.swift:76-121` 的 `speakerSegmentsRaw` 即此模式）。

**每個屬性都必須有預設值**——全 repo 靠這點做 SwiftData lightweight migration，
專案內**沒有** `VersionedSchema` / `SchemaMigrationPlan`。

**為何開第 5 個 store**：`default.store` 持有使用者所有 `Transcription` 歷史。本模組 schema 初期必然反覆調整；
新 store 檔案**不可能**破壞 `default.store` 的 migration，schema 崩壞時可整檔刪除重來而不損失任何逐字稿。
先例：`index.store`（Ask AI）。

### New Settings（`MeetingCopilotConfigStore`，UserDefaults，`…V1` key 後綴）

鏡射 `RecorderConfigStore` 的 `ObservableObject` + `@Published private(set)` + `set…()` mutator 形態。

| 設定 | 預設 | 說明 |
|---|---|---|
| `copilotEnabled` | false | 總開關（kill switch）。關閉時 realtime seam 完全不執行。 |
| `asrModelName` | FluidAudio Parakeet | 即時轉錄模型（須 `supportsStreaming`）。選雲端才有術語偏置。 |
| `fastProvider` / `fastModel` | Groq `llama-3.1-8b-instant` | Tier 1 + cue 抽取共用。 |
| `deepProvider` / `deepModel` | 跟隨全域預設 | Tier 2。 |
| `prefetchEnabled` | **true** | 預跑最新 cue 的 Tier 1。 |
| `transcribeLocalMic` | true | 是否也即時轉錄我的麥克風。 |
| `domainPersona` | 後端系統設計／演算法專家 | 注入所有 tier 的 system prompt。 |
| `useHistoryRAG` | true | 檢索歷史逐字稿。 |
| `useScreenContext` | true | Tier 2 擷取分享畫面 OCR 文字。 |
| `showInformationalCues` | false | 是否顯示不需回應的資訊型 cue。 |
| `overlayClickThrough` | false | 點擊穿透。 |
| `speakingOpacity` | 0.35 | 我說話時的不透明度。 |
| `maxCuesShown` | 5 | overlay 列出最近幾則。 |

模型解析走**純函式** `MeetingCopilotModels.resolve(storedProvider:storedModel:defaultProvider:available:)`，
鏡射 `AskAIAnswerModel.resolve`（`Services/AskAI/AskAIConfig.swift:31-38`）——**必須重新驗證 stored provider
仍在 `aiService.connectedProviders` 內**，否則回退預設（`RecorderPostProcessor.resolvedAnalysisModel` 同此邏輯）。

---

## Architecture Notes

### 核心洞察：講者歸屬是免費的，不需要 diarization

`MeetingCaptureService` 的 aggregate device 把 **process tap（系統音＝對方）** 與
**麥克風 sub-device（＝我）** 掛在同一個 aggregate 下，因此單次 IOProc callback 的 `AudioBufferList`
**同時含兩者且天生 sample-aligned**。`handleIO` 已把它們 deinterleave 進 `channelScratch`，
才由 `mixToMono` **等權平均壓成單聲道**。

在 `mixToMono` 之前，「誰在說話」是**結構上已知**的，切點就是 tap 的聲道數
（`kAudioTapPropertyFormat` 於 setup 時已讀到）。

串流轉錄路徑**完全沒有 speaker 欄位**，而 diarization 只存在於批次 ElevenLabs 整檔路徑且與串流互斥。
改用聲道分組後，「這句是對方說的」是 **100% 準確且零成本**的。

### 資料流

```
                    ┌─ HAL realtime thread ────────────────────────┐
CoreAudio IOProc ──►│ handleIO: deinterleave → channelScratch      │
 (tap ch + mic ch)  │   ├─► MeetingChannelSplitter                 │
                    │   │      按 tapChannelCount 切 remote/local   │
                    │   │      → 2× SPSC ring buffer (lock-free)   │
                    │   └─► mixToMono → ExtAudioFileWriteAsync     │ ← 落檔不變
                    └──────────────────────────────────────────────┘
                              │ consumer Task（離開 realtime context）
                              ▼
                       PCMDownsampler ×2  (Float32 多聲道 → mono 16k Int16 LE)
                              │
              ┌───────────────┴───────────────┐
              ▼ remote（對方）                  ▼ local（我）
    StreamingTranscriptionService     StreamingTranscriptionService
              │ .committed                     │ .committed（上下文）
              │                                │ + RMS → overlay 淡出
              ▼                                │
      ResponseCueExtractor ◄──────────────────┘
       (fast model；抽取＋4 分類＋去重 一次呼叫)
              │ MeetingLiveCue
              ├──────────────► Tier 0：關鍵字＋embedding 相似度（本機，<0.5s）
              │
              ├──────────────► Tier 1：fast model + SSE（<1.5s，**最新一則預跑**）
              │                  ▲ 接地：brief + RAG(RetrievalService)
              │
              └── 點擊 ────────► Tier 2：deep model + SSE（<15s，帶入 Tier 1 草稿）
                                 ▲ 接地：brief + RAG + 螢幕 OCR(ScreenCaptureService)
                                 │
                                 ▼
                       CopilotOverlayPanel
                       sharingType = .none / ignoresMouseEvents / canBecomeKey = false
                       toggle 熱鍵 + peek 熱鍵（按住顯示）
                       錨定螢幕上方中央（近鏡頭）
```

### Realtime-thread 安全性（不可妥協）

`handleIO` 跑在 HAL realtime thread。新增的 seam **絕對不得**做任何配置、加鎖、或 Swift runtime 呼叫
（`Array` 增長、`Data` 建立、ARC retain/release 皆禁止）。

- `MeetingPCMRingBuffer`：**預先配置**固定容量的 `UnsafeMutablePointer<Float>`，SPSC，head/tail 用原子索引。
  producer（handleIO）只做 memcpy + 原子遞增。
- 滿溢時**丟棄最舊**並遞增 `droppedFrames`（觀測用），**絕不阻塞 realtime thread**。
- consumer 是獨立 `Task`，取出後才進入 Swift 的一般世界。
- 這與既有 `StreamingTranscriptionService.sendAudioChunk` 被宣告為 `nonisolated`（明示可從 CoreAudio 執行緒呼叫）
  是同一種紀律。

### SSE 串流（repo 內自持）

`AIService.completeChat` 是整包字串回傳；LLMkit 內 `"stream": false` 寫死，且 **LLMkit 是遠端不可編輯的 SPM 套件**。
先例明確：diarization 需要 LLMkit 沒有的能力時，做法是**在 repo 內新增 client**
（`Transcription/Cloud/ElevenLabsDiarizingClient.swift`），而非改 LLMkit。沿用同一策略：

- **NEW** `Services/AIEnhancement/StreamingChatClient.swift`：
  - OpenAI-compatible（Groq / Cerebras / OpenAI / OpenRouter / Mistral / Ollama / custom）：`"stream": true`，
    解析 `data: ` SSE frame，`[DONE]` 收尾。
  - Anthropic：`content_block_delta` 事件流。
- **NEW** `AIService.streamChat(...)` 統一漏斗，鏡射 `completeChat` 的 provider switch 與 `chatAPIKey` 解析。
  輸出**不**逐 delta 經 `AIEnhancementOutputFilter`（該 filter 需完整字串才能剝 `<think>` 區塊）——
  改為串流結束後對完整累積字串套用一次，再落 SwiftData。
- **NEW** `StreamingChatCompleting` 協定，與既有 `ChatCompleting`（`Services/AskAI/AskAIService.swift:6-8`）並列，
  作為**可注入測試 seam**。

**Tier 1 → Tier 2 為序列**：Tier 1 串流完畢後 Tier 2 啟動，並將 Tier 1 草稿一併餵入
（prompt 語意：「以下是初步回答，請補強深度、指出其中不準確處、並預判 follow-up」）。
序列的理由：(a) Tier 2 站在草稿上補強而非重跑；(b) 使用者滿意即可取消 Tier 2，token 成本可控。

---

## Functional Requirements

### 擷取與轉錄
- [ ] **FR-1** `MeetingChannelSplitter`（純函式）依 `tapChannelCount` 將 `channelScratch` 切成 remote / local。
- [ ] **FR-2** `handleIO` 在 `mixToMono` 之前把兩組聲道推入各自的 lock-free ring buffer；**AAC 落檔位元組層級不變**。
- [ ] **FR-3** `copilotEnabled == false` 時 seam 不推任何資料，realtime thread 零額外工作。
- [ ] **FR-4** consumer 端經 `PCMDownsampler` 轉為 16kHz mono Int16 LE，餵入兩個獨立的 `StreamingTranscriptionService`。
- [ ] **FR-5** 講者歸屬由**串流來源**決定，不呼叫任何 diarization。
- [ ] **FR-6** ring buffer 滿溢時丟棄最舊 frame 並計數，不阻塞 realtime thread。
- [ ] **FR-7** 選用雲端 ASR 時，`VocabularyWord` 術語表經既有 `getCustomVocabularyTerms()` 注入；選 FluidAudio 時設定頁明示不支援偏置。

### Cue 偵測
- [ ] **FR-8** `ResponseCueExtractor` 於 remote 流每個 `.committed` 片段觸發（debounce），以 fast model **一次呼叫**完成抽取 + 四分類（`directQuestion` / `impliedChallenge` / `assignedToMe` / `informational`）。
- [ ] **FR-9** 陳述句形式的質疑與指派**必須**被偵測，不得只抓問號。
- [ ] **FR-10** 去重：正規化 Jaccard 相似度 + 30 秒時間窗。
- [ ] **FR-11** `informational` 類預設不顯示，可切換。
- [ ] **FR-12** prompt 建構為純函式，可單元測試。

### 三層回應
- [ ] **FR-13** **Tier 0**（< 0.5s，**不呼叫 LLM**）：關鍵字表 + `EmbeddingChunk` 相似度 → 領域標籤 + 2-3 關鍵字。
- [ ] **FR-14** **Tier 1**（< 1.5s）：fast model SSE 串流，輸出**結構化開口稿**（`opener` + 恰 3 個 `bullets`）。
- [ ] **FR-15** **最新一則 cue 的 Tier 1 自動預跑**（`prefetchEnabled`，預設 true）；點擊時若已完成則立即呈現。
- [ ] **FR-16** **Tier 2**（< 15s，點擊才跑）：deep model SSE 串流，帶入 Tier 1 草稿，輸出結構化 `analysis` + `followUps[]` + `uncertainties[]`。
- [ ] **FR-17** Tier 2 可取消，不影響已存的 Tier 0/1 結果。

### 答案接地
- [ ] **FR-18** **會前 brief**：`MeetingLiveSession.brief` 可於「會議錄音管理」頁填寫（或選檔案），注入所有 tier 的 system prompt。
- [ ] **FR-19** **RAG**：重用 `RetrievalService` 以 cue 文字檢索歷史逐字稿 top-k，注入 Tier 1 / Tier 2；索引為空或無 key 時**靜默跳過**。
- [ ] **FR-20** **螢幕上下文**：Tier 2 啟動時重用 `ScreenCaptureService.captureAndExtractText()` 取得分享畫面 OCR 文字；失敗**靜默跳過**。

### Overlay
- [ ] **FR-21** 兩個熱鍵：`.toggleMeetingCopilotOverlay`（釘住）與 `.peekMeetingCopilotOverlay`（**按住顯示、放開隱藏**，沿用 push-to-talk 的 keyDown/keyUp 機制）。
- [ ] **FR-22** overlay `sharingType = .none`——螢幕分享時不被擷取，且不出現在分享視窗選擇器。
- [ ] **FR-23** overlay 可點擊穿透（設定切換），且**永不**從會議 app 搶走鍵盤焦點。
- [ ] **FR-24** overlay 錨定**螢幕上方中央**（近鏡頭）；優先取會議 app 所在螢幕，退回 `NSScreen.main`。
- [ ] **FR-25** local 流 RMS 超過門檻（我在說話）→ 不透明度降至 `speakingOpacity`；停止 1.5 秒後恢復。
- [ ] **FR-26** `opener` 以最大字級單獨呈現；最新 cue 在最上方且最大，舊 cue 縮為單行變灰。

### 可靠性
- [ ] **FR-27** system prompt 明確禁止捏造數字／論文／公司名；不確定項必須進 `uncertainties[]` 並在 overlay 明顯呈現。
- [ ] **FR-28** 任何失敗**不得**跳出 modal 或系統通知；只在 overlay 內小字標紅並逐層降級（Tier 2 失敗保留 Tier 1；Tier 1 失敗保留 Tier 0；ASR 斷線不影響錄音落檔）。

### 頁面與設定
- [ ] **FR-29** 新側欄頁「會議錄音管理」：會議列表 → 詳情（雙軌逐字稿、cue 與三層回應）。
- [ ] **FR-30** 該頁可設定：兩個熱鍵、ASR 模型、fast/deep 兩組 provider+model、brief、predefined 各開關。
- [ ] **FR-31** 模型解析必須重新驗證 provider 仍 connected，否則回退預設。

### 既有缺陷修復
- [ ] **FR-32** 補上 `.toggleMeetingRecording` 的 `ShortcutRecorder` 設定 UI，並納入衝突偵測清單。

### 離線驗證
- [ ] **FR-33** `MeetingAudioSource` 協定作為音源注入 seam；`LiveMeetingAudioSource`（正式）與 `ReplayMeetingAudioSource`（replay WAV）為其兩個實作。
- [ ] **FR-34** 完整 pipeline 可在**不開任何會議軟體、不開 CoreAudio** 的情況下由預錄 WAV 端到端驅動並於 XCTest 中斷言。

---

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 即時安全 | realtime thread 零配置／零鎖／零 ARC | 預配置 SPSC ring buffer；consumer 在獨立 Task |
| **Tier 0 延遲** | **< 0.5s** | **不呼叫 LLM** — 關鍵字表 + 本機 embedding 相似度 |
| **Tier 1 延遲** | **< 1.5s**（預跑後點擊為 **~0s**） | Groq `llama-3.1-8b-instant` + SSE + 最新一則預跑 |
| **Tier 2 延遲** | < 15s | 序列啟動，不與 Tier 1 爭頻寬 |
| 轉錄延遲 | 說完 → `.partial` < 1s | 本機 FluidAudio（免網路往返） |
| 成本 | 預設零 API 成本轉錄；預跑只用 fast model | 本機 FluidAudio；Tier 2 點擊才跑 |
| 隱私 | 逐字稿與答案僅存本機 | `meeting.store`，`cloudKitDatabase: .none`；ASR 預設本機 |
| 相容性 | 既有會議 → Obsidian 管線零回歸 | 落檔位元組不變；既有 Meeting* 測試把關 |
| 隱蔽性（失敗時） | 失敗不得產生任何可見系統 UI | 無 modal／無通知；只在 overlay 內標紅 |

---

## Debug / 驗證流程（不開 Teams / Google Meet）

### 設計：把音源抽象成協定，正式與 replay 兩個實作

```
protocol MeetingAudioSource {
    func start() async throws
    func stop() async
    var frames: AsyncStream<MeetingAudioFrame> { get }   // { remote: [Float], local: [Float], sampleRate }
}
```

- `LiveMeetingAudioSource` — 包住 CoreAudio ring buffer（正式路徑）
- `ReplayMeetingAudioSource(remoteWAV:localWAV:speed:)` — 讀兩個預錄 WAV，依 wall-clock（或加速）吐 frame

**Source 以下的一切完全相同**：splitter → downsampler → 雙 ASR → cue 抽取 → 三層回應 → overlay。
replay 驗證的是**真正要上線的那條 pipeline**，不是平行的假貨。

### 三層驗證

**L1 — 純函式單元測試**（無 I/O，秒級，進 CI）
- `MeetingChannelSplitterTests` — `tapChannelCount = 2`、5 聲道 scratch → remote 取前 2、local 取後 3。邊界：mic 關閉、0 聲道。
- `PCMDownsamplerTests` — 48k 立體聲 Float32 → 16k mono Int16；與既有 `CoreAudioRecorder` 行為等價。
- `MeetingPCMRingBufferTests` — SPSC 正確性、滿溢丟最舊、`droppedFrames` 計數。
- `ResponseCueExtractorTests` — prompt 建構純函式；四分類；**陳述句質疑必須被抓到**；去重。
- `Tier0KeywordTests` — 關鍵字/相似度標籤，不呼叫 LLM。
- `MeetingCopilotModelsTests` — fast/deep 解析；stored provider 已斷線時回退預設。

**L2 — 端到端 replay（XCTest，不需 CoreAudio、不需網路）**
- `MeetingCopilotReplayTests`：
  - fixture `remote.wav`：**至少三種 cue**——一句直接問句（「你會怎麼設計一個短網址服務？」）、
    一句**陳述句質疑**（「我對這個寫入效能有點擔心」）、一句純資訊。`local.wav` 為我的聲音或靜音。
  - ASR：本機 FluidAudio Parakeet（**真實 ASR、免 API key** → CI 可跑）
  - LLM：`FakeStreamingChatCompleting`（腳本化 delta 序列）
  - RAG / 螢幕 OCR：以 fake 注入，並**另測其失敗時靜默跳過**
  - 斷言：三種 cue 皆被抽出且分類正確 → Tier 0 立即有關鍵字 → Tier 1 預跑產出 `opener` + 3 bullets →
    點擊後 Tier 2 收到 Tier 1 草稿並產出 `followUps[]` → 全部落 SwiftData
  - 加速播放（`speed: 10x`）讓測試在數秒內完成

**L3 — 實機 probe（一次性、人工，回答 CoreAudio 與螢幕分享的未知數）**
- **`MeetingChannelLayoutProbe`（`#if DEBUG`）— 這是 Task 1，先於一切。**
  **replay harness 回答不了聲道順序這題**——它從 source 協定以下才接手，刻意繞過了 CoreAudio。
  真實 aggregate device 的串流順序（tap-first 或 subdevice-first）**只能實機量測**：
  靜音麥克風 → 系統音播放已知單音 → 量各聲道 RMS → 有能量者即為 tap（remote）；反向再驗一次。
  結果鎖進常數 + `MeetingChannelSplitterTests` 的 assert。
  **切反的後果**：把「我的話」當成「對方的問題」，症狀隱晦、極難察覺。
- **螢幕分享排除**——**三種情境全部要測**：
  (a) Teams 原生 app 分享整個螢幕；(b) Chrome / Google Meet `getDisplayMedia` 分享整個螢幕；
  (c) Chrome / Google Meet 分享單一視窗。
  `sharingType = .none` 只保證「其他 app 擷取不到本視窗」；須確認上述三條實際擷取路徑下都成立，
  且 overlay **不出現在**分享視窗選擇器中。**任一情境失敗，此功能的前提即不成立。**

### 開發期體感驗證
`#if DEBUG` 選單項「Replay 會議音檔」：選一個 WAV → 走完整 pipeline → **真的把 overlay 叫出來**。
可在不開任何會議軟體的情況下，肉眼驗證三層的延遲節奏、`opener` 是否真的「可以直接念出口」、
overlay 排版與淡出行為。

---

## Acceptance Criteria

### AC-1: 聲道分流正確（講者歸屬）
- **Given**: `tapChannelCount = 2`、麥克風啟用（1 聲道），`channelScratch` 共 3 聲道
- **When**: `MeetingChannelSplitter.split(channelScratch:tapChannelCount:)`
- **Then**: remote 得聲道 0-1、local 得聲道 2（順序依 L3 probe 實測鎖定）
- **Test**: `MeetingChannelSplitterTests::splitsRemoteAndLocalByTapChannelCount`

### AC-2: 錄音落檔零回歸
- **Given**: `copilotEnabled = true`，錄一段會議
- **When**: 停止並匯入
- **Then**: m4a 與 `copilotEnabled = false` 時**位元組等價**；既有 Meeting* 測試全綠
- **Test**: `MeetingCaptureRegressionTests::copilotSeamDoesNotAlterRecording`

### AC-3: realtime thread 不被阻塞
- **Given**: ring buffer 已滿
- **When**: `handleIO` 再次被呼叫
- **Then**: 立即返回、丟最舊、`droppedFrames` 遞增；無配置、無鎖
- **Test**: `MeetingPCMRingBufferTests::overflowDropsOldestWithoutBlocking`

### AC-4: 陳述句質疑必須被偵測（不只抓問號）
- **Given**: remote 流出現「我對這個寫入效能有點擔心」（無問號）
- **When**: `ResponseCueExtractor` 處理
- **Then**: 產生一則 `kind == .impliedChallenge` 的 cue；「我們上週上線了 v2」被歸為 `.informational` 且預設不顯示
- **Test**: `ResponseCueExtractorTests::detectsStatementFormChallenge`

### AC-5: Tier 0 不呼叫 LLM 且夠快
- **Given**: 一則新 cue
- **When**: Tier 0 執行
- **Then**: 產出領域標籤 + 2-3 關鍵字；**全程未發出任何 LLM 請求**；< 0.5s
- **Test**: `Tier0KeywordTests::producesKeywordsWithoutLLMCall`（以 fake LLM 斷言呼叫次數為 0）

### AC-6: Tier 1 輸出可直接開口的結構
- **Given**: 一則系統設計問題
- **When**: Tier 1 完成
- **Then**: 產出非空 `opener`（單句）+ **恰 3 個** `bullets`；overlay 以最大字級單獨呈現 `opener`
- **Test**: `Tier1DraftTests::producesOpenerAndExactlyThreeBullets`

### AC-7: 預跑讓點擊零等待
- **Given**: `prefetchEnabled = true`，一則新 cue 出現後 2 秒
- **When**: 使用者點擊該 cue
- **Then**: Tier 1 已完成，**立即**呈現，不再發新請求
- **Test**: `PrefetchTests::newestCuePrefetchesTier1`

### AC-8: 兩階段順序與內容傳遞
- **Given**: 一則已完成 Tier 1 的 cue
- **When**: 觸發 Tier 2
- **Then**: Tier 2 的 user message **確實包含** Tier 1 的 `opener` 與 bullets 全文；產出 `followUps[]`（≥1）與 `uncertainties[]`；可取消而不影響已存的 Tier 0/1
- **Test**: `AnswerCoordinatorTests::deepStageReceivesFastDraft`

### AC-9: RAG 接地與其降級
- **Given**: 歷史逐字稿中有相關內容
- **When**: Tier 1 / Tier 2 產生答案
- **Then**: prompt 的 user block 含檢索到的片段；**若索引為空或無 embedding key，靜默跳過且答案照常產出**（不報錯、不中斷）
- **Test**: `GroundingTests::ragInjectedWhenAvailableAndSkippedSilentlyWhenNot`

### AC-10: 螢幕上下文只在 Tier 2 擷取
- **Given**: `useScreenContext = true`
- **When**: Tier 0 / Tier 1 執行
- **Then**: **不**呼叫 `ScreenCaptureService`（不拖慢首字延遲）；Tier 2 啟動時才擷取一次；OCR 失敗則靜默跳過
- **Test**: `GroundingTests::screenContextOnlyOnDeepStage`

### AC-11: SSE 逐字串流
- **Given**: fake SSE server 回 3 個 delta
- **When**: `AIService.streamChat`
- **Then**: `AsyncThrowingStream` 依序吐出 3 段；`AIEnhancementOutputFilter` 在串流結束後才對完整字串套用一次
- **Test**: `StreamingChatClientTests::emitsDeltasInOrder`

### AC-12: 失敗必須靜默且逐層降級
- **Given**: Tier 2 的 LLM 請求失敗
- **When**: 失敗發生
- **Then**: **不**出現任何 modal / 系統通知；Tier 1 草稿仍在；overlay 內小字標紅。ASR 斷線時錄音**續行**且落檔不受影響。
- **Test**: `FailureDegradationTests::deepFailureKeepsFastDraftAndShowsNoModal`

### AC-13: 不得編造
- **Given**: 一則模型無把握的問題
- **When**: Tier 2 完成
- **Then**: 不出現捏造的 benchmark 數字／論文名／公司名；不確定項出現在 `uncertainties[]`
- **Test**: `PromptContractTests::systemPromptForbidsFabrication`（斷言 system prompt 含禁令）+ 人工抽查

### AC-14: 端到端 replay（核心，不開會議軟體）
- **Given**: `remote.wav` 含三種 cue（直接問句／陳述句質疑／純資訊），LLM 為 fake
- **When**: 用 `ReplayMeetingAudioSource` 跑完整 pipeline
- **Then**: 三種 cue 皆被抽出且分類正確 → Tier 0 有關鍵字 → Tier 1 預跑出 `opener`+3 bullets → 點擊後 Tier 2 收到草稿並產出 `followUps[]` → 全部落 SwiftData
- **Test**: `MeetingCopilotReplayTests::endToEndFromWavProducesThreeTiers`

### AC-15: Overlay 不被螢幕分享擷取（實機）
- **Given**: overlay 顯示中
- **When**: (a) Teams 原生 app 分享整個螢幕；(b) Chrome/Meet `getDisplayMedia` 分享整個螢幕；(c) Chrome/Meet 分享單一視窗
- **Then**: 三種情境接收端畫面**皆不含** overlay；且 overlay **不出現在**分享視窗選擇器中
- **Test**: 人工驗證（實機，需第二台裝置或錄製接收端畫面存證）

### AC-16: Overlay 不搶焦點 + Peek 模式
- **Given**: Teams 為前景、游標在其輸入框
- **When**: **按住** peek 熱鍵並放開
- **Then**: 按住期間 overlay 顯示、放開即隱藏；全程 Teams 仍為前景 app，鍵盤焦點未轉移
- **Test**: `CopilotOverlayPanelTests::canBecomeKeyIsFalse` + 人工驗證

### AC-17: 我說話時自動淡出
- **Given**: overlay 顯示中，`speakingOpacity = 0.35`
- **When**: local 流 RMS 超過門檻（我在說話）
- **Then**: 不透明度降至 0.35；停止說話 1.5 秒後恢復
- **Test**: `OverlayDimmingTests::dimsWhileLocalStreamActive`（以合成 RMS 序列驅動）

### AC-18: 模型解析回退
- **Given**: `fastProvider` 設為 Groq，隨後移除 Groq API key
- **When**: 解析 fast model
- **Then**: 回退至預設 provider；不 crash、不用失效 provider 發請求
- **Test**: `MeetingCopilotModelsTests::fallsBackWhenProviderDisconnected`

### AC-19: 會議熱鍵可設定（既有缺陷修復）
- **Given**: 設定頁
- **When**: 檢視快捷鍵區
- **Then**: `.toggleMeetingRecording`、`.toggleMeetingCopilotOverlay`、`.peekMeetingCopilotOverlay` **三者**皆有 `ShortcutRecorder` 可設定，且皆納入重複快捷鍵偵測
- **Test**: `MeetingShortcutTests::allMeetingShortcutsAreConfigurableAndValidated`

---

## Risks & Trade-offs

| 風險 | 可能性 | 影響 | 緩解 |
|---|---|---|---|
| **聲道順序切反**（tap-first vs subdevice-first 未經實測） | M | **H** — 把「我的話」當成「對方的問題」，症狀隱晦 | L3 實機 probe 為 **Task 1**；結果鎖進常數 + 單元測試 |
| **喇叭情境下 mic 收到對方聲音**（回音污染 local 流） | **H**（不戴耳機時幾乎必然） | M — local 逐字稿混入對方的話；**cue 抽取只讀 remote 流故不直接受害**，但「我說話時淡出」會誤觸發 | cue 抽取只取 remote（設計上已隔離）；「假設戴耳機」設定；RMS 門檻需可調；未來可加 remote-能量閘門 |
| **本機 ASR 無術語偏置** → 專案代號轉錯 → cue 抽取失準 | **H** | M | 設定頁明示取捨；需要術語準確度者選雲端 ASR（術語表已接好） |
| Tier 0 的關鍵字表品質決定其價值 | M | M | 內建後端／演算法領域關鍵字表；輔以既有 embedding 相似度，非純字面 |
| realtime thread 違反即時紀律 → 爆音／drop | M | H | 預配置 ring buffer；`droppedFrames` 可觀測；既有錄音迴歸測試把關 |
| `sharingType = .none` 在某條擷取路徑失效 | L | **H** — 功能前提破功 | AC-15 三情境實機驗證；未通過則需重新評估整個功能 |
| 裝置切換（`rebuildGraphKeepingFile`）改變 `tapChannelCount` → 聲道錯位 | M | H | splitter 須在 rebuild 後重新讀取 `tapChannelCount`；此路徑列為必測 |
| 預跑 + 三層 + RAG 的 token 成本 | M | M | 預跑只用 fast model 且只跑最新一則；Tier 2 點擊才跑；`prefetchEnabled` 可關 |
| 自持 SSE client 的維護負擔 | M | M | 只實作兩種 frame 格式；沿用 `ElevenLabsDiarizingClient` 先例 |

---

## Open Questions

- [ ] **聲道順序**：aggregate 的 `AudioBufferList` 是 tap-first 還是 subdevice-first？→ L3 probe 實測，**擋在所有事之前**。
- [ ] Tier 0 的領域關鍵字表從何而來？（手寫種子表？從歷史逐字稿的 `EmbeddingChunk` 自動聚類？傾向：手寫種子 + embedding 相似度補強。）
- [ ] cue 去重的字面判準（正規化 Jaccard）門檻值？不夠用時是否升級為模型判語意重複？
- [ ] `ResponseCueExtractor` 的滑動窗大小（幾句 / 幾秒）？需以真實會議逐字稿調校。
- [ ] 「我說話時淡出」的 RMS 門檻在喇叭情境下會被對方聲音誤觸發 → 是否需要「remote 有能量時不觸發淡出」的互斥閘門？
- [ ] 會前 brief 若選 Obsidian 筆記，如何取得？（既有 vault 路徑 + security-scoped bookmark 已有先例於 `VaultExportService`。）
- [ ] 裝置切換時 `tapChannelCount` 變動的完整處理路徑。

---

## 倫理與合規（不可省略）

本功能會**持續錄下會議中其他人的聲音**並送入模型。

- 錄音同意在許多司法管轄區是法律義務（雙方同意制），在所有場合都是基本禮貌。
- 本模組**不**繞過、**不**偽裝、**不**對抗任何會議平台的錄製通知機制；它與平台無關，只讀取本機音訊輸出。
- `sharingType = .none` 的正當用途是**避免自己的私人筆記在分享螢幕時被廣播出去**（與密碼管理器隱藏自身視窗同理），
  這也是本 SRS 唯一據以設計的理由。
- 使用者需自行確保在其會議情境下的使用是被允許的。**在被評估能力的場合（如技術面試、線上考試）使用本功能，
  不在本模組的設計意圖之內。**
