---
linear_issue: null
---
# SRS: 會議即時輔助 — M10 三階段回答 + 深思模型分級（meeting-copilot）

> 本文件是 umbrella SRS `docs/srs/meeting-copilot-live-assist.srs.md` 的 **M10 里程碑切片**。
> 承 M3（三層引擎）／M8（auto-deep + 閱讀保護）／M9（aboutMe 不進 deep）。本切片把「開口稿→深答」
> 兩段**重構為三段**（開口稿 / 中度分析 / 深度分析），把「快/深」兩個 model 設定**整併為**「即時模型 / 深思模型」，
> 為深度分析加**自動/手動觸發閘門**，把**截圖深答改接深度分析**，並修正本 session 已建之截圖/panic 程式的四個
> 對抗式 review 確認缺陷。

## Metadata
- **Module**: `meeting-copilot`（M10 切片）
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Umbrella SRS**: `docs/srs/meeting-copilot-live-assist.srs.md`
- **Source PRD**: `docs/prd/meeting-copilot-deep-reasoning-tier.prd.md`
- **Source Linear Issue**: N/A（`docs/prp.config.yml` → skip: true）
- **Created**: 2026-07-16
- **Grill level**: 1 (standard)
- **依賴**: M3（`AnswerCoordinator` / `StreamingChatClient` / `TierPrompts` / `MeetingLiveCue` tier 欄位）、M8（auto-deep 世代取消、`unreadDeepCueIds`、展開保護 FR-54/FR-51）、M9（aboutMe/informational 不進 deep）。**本 session 已建但未列里程碑**的截圖深答（`CopilotScreenshotStore` / `ScreenCaptureService.captureImageData` / `VisionModelSupport` / `AnswerCoordinator.requestDeepWithImages`）與 panic-hide（`MeetingCaptureController.togglePanicHide`）、串流資源逾時（`StreamingChatClient.pooledSession`）在 M10 被正式化並修缺陷。
- **build number**: 現值 → **現值+1**（`CURRENT_PROJECT_VERSION`，Debug + Release 兩處）。

## Feature Summary

**問題**：即時性與思考深度被綁在同一顆模型上。使用者快/深皆設 gemini flash，深度分析因此無推理增量；換慢的推理模型又拖垮即時。

**M10 交付**：把回答與模型都拆成「即時」與「深思」兩軸。

- **開口稿**（Tier 1，<1s，**即時模型**）＝現況不變。
- **中度分析**（Tier 2，~5s，**即時模型**）＝現 Tier 2 角色改吃即時模型；開口稿完成後**恆自動接續**（不可關）。輸出多一個
  **升級訊號** `needsDeep: bool` + `deepReason: string`（模型自評此題是否需複雜推理/多方案取捨/多步推導/高不確定）。
- **深度分析**（Tier 3，10–30s，**深思模型**，新增）＝真正的推理模型。承接 M8 的 latest-only 取消、展開保護（FR-54）、
  未讀徽章與自動展開（FR-51）、進度 spinner——這些「慢層」機制**從 Tier 2 移到 Tier 3**。Tier 3 走**閘門**：
  - **自動模式**：中度回報 `needsDeep=true` 且 cue 可深答 → 自動發起 Tier 3；發起時 overlay 的「深入分析」鈕暫 disabled。
  - **手動模式**：僅使用者按鈕觸發。手動按鈕在兩模式恆存在。

**模型整併**：`MeetingCopilotConfigStore` 的 fast/deep 兩組設定，UI 整併為兩個下拉——**即時模型**（cue 抽取＋開口稿＋
中度分析共用，沿用既有 fast 設定）與**深思模型**（僅深度分析，新設定，預設 `gemini-2.5-pro`）。舊 deep 設定退役
（中度改用即時模型）。

**截圖深答改接 Tier 3**：本 session 已建的截圖深答（原接 Tier 2）改為觸發深度分析（深思模型 + 多模態）。

**併同修正**四個對抗式 review 確認缺陷（見 Architecture Notes §缺陷修正）：(1) 截圖/深答以 tier2Error 空判定成功、
取消被誤判成功而清空截圖佇列；(2) 在途截圖深答被新 cue 自動升級取消；(3) 視覺閘門漏掉 app 內建 gpt-5.x 家族（含
預設 gpt-5.5）；(4) panic 還原以過期 snapshot 判斷、獨立 toggle 後反向。

---

## Delta from Current Module State

> 對既有程式的改動集中在 `AnswerCoordinator`（三段重構 + Tier 3 + 閘門）與 config/UI（模型整併）。串流、接地、
> 取消/保護/徽章機制**唯讀重用或平移**，不重寫。

### New Data Models

**不新增 @Model**。`MeetingLiveCue` 新增 Tier 3 與升級訊號欄位（每欄有預設值 = lightweight migration；沿用 tier2* 的
JSON-in-raw + `@Transient` 快取慣例）：

- `tier3Analysis: String`、`tier3FollowUpsRaw: String`、`tier3UncertaintiesRaw: String`（+ 對應 `@Transient` 快取存取器，鏡射 tier2）。
- 觀測欄位：`tier3PromptUser`、`tier3RawReply`、`tier3GroundingElapsedMs`、`tier3StreamElapsedMs`、`tier3Error`、
  `tier3GroundingNote`、`tier3At: Date?`、`tier3TriggerRaw`（"auto"/"manual"/"image"）、`deepThinkModelName`。
- 升級訊號（中度產出、供閘門）：`mediumNeedsDeep: Bool = false`、`mediumDeepReason: String = ""`。
- **語意平移**：`deepInFlightCueId`、`unreadDeepCueIds`、`answeredAt`、`status=.answered` 從「Tier 2 完成」改綁「**Tier 3** 完成」
  （中度完成不再標未讀/自動展開——它是即時漸進渲染的一部分，如 Tier 1）。

內部值型別（非持久化）：沿用 `Tier1Draft` / `Tier2Analysis` / `FollowUp`；`Tier2Analysis` 增 `needsDeep: Bool` + `deepReason: String`
（`TierParsers.parseTier2` 一併解析）。Tier 3 沿用 `Tier2Analysis` 結構（analysis/followUps/uncertainties），`needsDeep`
在 Tier 3 忽略。

### Changed Business Logic

- **`AnswerCoordinator` 三段重構**：
  - `runTier1`（opener，即時模型）→ 完成後**恆自動接續** `runMedium`（原 `runAutoDeep`→`runTier2` 的位置，但改吃即時模型、
    **移除 `autoDeepEnabled` 對中度的閘門**：中度永遠跑最新一則）。
  - `runMedium`（中度，即時模型，寫 tier2*）→ 解析 `needsDeep`/`deepReason` 寫回 cue → 依 `deepTrigger`：`.auto` 且
    `needsDeep` 且 `deepEligible(cue)` → `startDeep`（Tier 3）；`.manual` → 不自動起（等按鈕）。
  - `runDeep`（Tier 3，深思模型，寫 tier3*，新）＝原 `runTier2` 的「慢層」骨架平移：世代取消、展開保護、
    grounding（有圖跳過 OCR）、串流、`onDeepCompleted`（badge/auto-expand）**改在此觸發**。
  - `requestDeep(cue)`（手動按鈕）→ 起 Tier 3（等中度草稿；aboutMe/informational 守門）。
  - `requestDeepWithImages(cue, images)`（截圖深答）→ 起 Tier 3 **帶圖**（深思模型；視覺閘門；成功判定改用**明確完成訊號**）。
- **`deepEligible(cue)`**：`cue.kind != .aboutMe && cue.kind != .informational`（延續 M9 FR-67）。
- **成功訊號（缺陷 1 修正）**：`runDeep` 只在**成功寫回結果後**把 `generation` 記入 `completedDeepGenerations: Set<Int>`；
  取消/早退不記。`requestDeepWithImages` 以 `completedDeepGenerations.contains(gen)` 判定是否清空截圖佇列，**不再**用
  `tier2Error.isEmpty`（取消時它也是空）。
- **在途截圖深答保護（缺陷 2 修正）**：`isDeepProtected` 視 `deepTaskTrigger == "image"` 為受保護（等同展開中），
  新 cue 的自動升級不得取消在途的截圖深答。
- **`MeetingCopilotConfigStore` 變更**：新增 `deepThinkProvider`/`deepThinkModel`（預設 Gemini/`gemini-2.5-pro`）、
  `deepTrigger: enum {auto, manual}`（預設 `.auto`）。`fastProvider`/`fastModel` 語意擴為「即時模型」（多服務中度）。
  舊 `deepProvider`/`deepModel` 停止讀取（保留 key 不刪，避免破壞）——中度改用即時模型。移除中度的 `autoDeepEnabled` 相依
  （或保留 key 但語意固定為 true）。
- **`VisionModelSupport` 修正（缺陷 3）**：`visionMarkers` 新增 `"gpt-5"`（子字串涵蓋 gpt-5 / gpt-5.4* / gpt-5.5）；
  不支援訊息改建議 app 內實際可選的視覺模型（gemini-2.5-pro / gpt-4.1 等），不再建議不在清單的 gpt-4o。
- **`MeetingCaptureController.togglePanicHide` 修正（缺陷 4）**：還原 vs 隱藏的判斷改以**當下實際可見狀態**為準
  （overlay/presenter `isPinned` 或 pill 顯示中任一為真 = 收起並快照；全不可見 = 依快照還原），不再只看 `panicSnapshot != nil`。

### New / Changed API

| 類型 | 元件 | 位置 | 說明 |
|---|---|---|---|
| **CHANGED** | `AnswerCoordinator`（三段：runTier1 → runMedium → runDeep）+ `requestDeep` / `requestDeepWithImages` 改起 Tier 3 | `Services/MeetingCopilot/AnswerCoordinator.swift` | 中度恆自動；Tier 3 走閘門；慢層機制平移 tier2→tier3 |
| **CHANGED** | `TierPrompts.tier2System/tier2User`（中度）加 `needsDeep`/`deepReason` 契約；新增 `tier3System/tier3User`（深度，推理指示 + reasoning） | `Services/MeetingCopilot/TierPrompts.swift` | 中度自評升級；深度為真推理 prompt |
| **CHANGED** | `TierParsers.parseTier2` 解析 `needsDeep`/`deepReason`；`parseTier3`（可沿用 parseTier2 結構） | `Services/MeetingCopilot/TierParsers.swift` | — |
| **CHANGED** | `MeetingLiveCue` 新增 tier3* + mediumNeedsDeep/mediumDeepReason 欄位 | `Models/MeetingLiveModels.swift` | lightweight migration |
| **CHANGED** | `MeetingCopilotConfigStore`：deepThinkProvider/Model + deepTrigger；fast=即時語意 | `Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | 模型整併 |
| **CHANGED** | `MeetingCopilotLiveController.start`：解析深思 completer、接線 Tier 3 深答 completer；截圖深答走 Tier 3 | `Services/MeetingCopilot/MeetingCopilotLiveController.swift` | 兩顆 completer（即時/深思） |
| **CHANGED** | `MeetingCopilotSettingsView`：模型 section 整併為「即時模型/深思模型」兩下拉 + 「深度分析觸發」自動/手動 picker | `Views/MeetingCopilot/MeetingCopilotSettingsView.swift` | 移除舊 deep picker |
| **CHANGED** | `CopilotOverlayView`：三段渲染（opener/medium/deep 分區）；「深入分析」鈕（自動發起時 disabled）；截圖深答鈕接 Tier 3 | `Views/MeetingCopilot/CopilotOverlayView.swift` | 深度分區 spinner/徽章綁 tier3 |
| **CHANGED** | `VisionModelSupport`（+gpt-5）、`MeetingCaptureController.togglePanicHide`（實際可見判斷） | 各自檔案 | 缺陷 3/4 |

### Explicitly Out of Scope（本里程碑不做）

- **cue 偵測 / 分類 / 去重**（M2）、**SSE client 底層**（M3 `StreamingChatClient` 只加多模態，已於本 session 完成）、
  **RAG 索引/嵌入**（唯讀重用）、**即時翻譯**（M8，不動）。
- **第三顆模型 / 中度可關 / t=0 並行深答**（見 PRD NOT Building）。
- **panic-hide 的 toggle-restore 基本機制與串流資源逾時**——本 session 已建，M10 只修 panic 的還原判斷缺陷（FR-84），
  逾時不動。
- **逐 tier 獨立語言/風格設定**——沿用 outputLanguage / deepStyle。

---

## Functional Requirements（僅本里程碑，FR-74~84）

### 三階段回答
- [ ] **FR-74** **中度分析恆自動接續**：Tier 1（開口稿）完成後**一律**自動接跑中度分析（Tier 2），改由**即時模型**產生；
      **無開關可關**（移除中度層對 `autoDeepEnabled` 的相依）。latest-only 不變（新 cue 取消舊的預跑鏈）。
- [ ] **FR-75** **中度自評升級訊號**：中度分析輸出附 `needsDeep: bool` + `deepReason: string`，模型依「多方案取捨／多步推導／
      架構或演算法決策／實質不確定」自評是否需要深度分析；解析後存於 `cue.mediumNeedsDeep` / `cue.mediumDeepReason`。
- [ ] **FR-76** **深度分析（Tier 3）**：新增第三段，由**深思模型**（推理類）SSE 串流產生，帶入中度草稿全文；承接 M8 的
      世代取消、展開保護（FR-54）、未讀徽章與自動展開（FR-51）、進度 spinner——這些機制由 Tier 2 **平移到 Tier 3**
      （中度完成不再標未讀/自動展開）。
- [ ] **FR-77** **深度分析觸發閘門**：設定 `deepTrigger` = **自動** | **手動**。自動：`mediumNeedsDeep=true` 且 `deepEligible(cue)`
      時**自動發起** Tier 3；手動：僅使用者按鈕觸發。**手動按鈕在兩模式恆存在**；當 Tier 3 正在為該 cue 進行時，按鈕
      **暫時 disabled**（避免重複觸發）。
- [ ] **FR-78** **深答資格**：`aboutMe` 與 `informational` cue **不進** Tier 3（延續 M9 FR-67），自動與手動兩路皆守門。

### 模型整併
- [ ] **FR-79** **模型設定整併為兩個下拉**：**即時模型**（cue 抽取＋開口稿＋中度分析共用，沿用既有 fast 設定）與
      **深思模型**（僅深度分析，新增 `deepThinkProvider`/`deepThinkModel`）。深思模型**預設 Gemini `gemini-2.5-pro`**
      （ReasoningConfig 認得為 thinking、支援視覺）；UI 提示「請選推理/thinking 類模型」。舊 deep 設定退役（中度改用即時模型）。
      深思模型解析走與即時同一套 `MeetingCopilotModels.resolve`（provider 失效回退預設）。

### 截圖深答改接深度
- [ ] **FR-80** **截圖深答走 Tier 3**：本 session 的截圖深答由觸發 Tier 2 改為觸發**深度分析**（深思模型 + 多模態）；
      覆蓋 `tier3*`（非 tier2*）。視覺閘門判定對象改為**深思模型**。

### 缺陷修正（對抗式 review 確認，reachable）
- [ ] **FR-81** **深答成功以明確完成訊號判定**：截圖深答/深度分析是否「成功送出」以**世代完成標記**判定，**不得**以
      `tierNError.isEmpty` 推斷（取消時該欄位亦為空）。截圖佇列**僅在確實完成時**清空；取消/失敗保留佇列並顯示可見錯誤。
- [ ] **FR-82** **在途截圖深答受保護**：`trigger == "image"` 的在途 Tier 3 視同展開保護，**不被**新 cue 的自動升級取消
      （避免使用者剛送出的截圖深答被下一則 cue 秒殺、佇列又被清空）。
- [ ] **FR-83** **視覺閘門涵蓋內建預設模型**：`VisionModelSupport` 的視覺模型清單納入 app `availableModels` 的視覺家族
      （含 `gpt-5` 子字串，涵蓋預設 gpt-5.5）；不支援訊息**只建議 app 內實際可選**的視覺模型（如 gemini-2.5-pro / gpt-4.1）。
- [ ] **FR-84** **panic 還原以實際可見狀態判定**：緊急隱藏在「收起」與「還原」之間的判斷以**當下三個浮動面實際是否可見**
      為準（任一可見→收起並快照；全不可見→依快照還原），不因獨立的 overlay/讀稿面板 toggle 令 `panicSnapshot` 過期而反向。

---

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| **開口稿延遲** | <1s（不變） | 即時模型（flash）+ SSE + 預跑，與 M3 相同 |
| **中度延遲** | ~5s（不變） | 即時模型；恆自動接續，不與開口稿爭頻寬 |
| **深度延遲** | 10–30s，**永不阻擋前兩段** | 深思模型獨立起 task；晚到 + 未讀徽章吸收慢；latest-only + 保護 |
| 成本 | 深思模型只在閘門放行時呼叫 | 自動＝needsDeep 才起；手動＝按鈕才起；aboutMe/informational 不進 |
| 正確性（reasoning 注入） | 深思模型須注入 thinking 參數 | 沿用 `ReasoningConfig`（gemini-2.5-pro / gpt-5.x 已支援）+ OpenAI-compat 串流的 reasoning_effort/extraBody |
| 正確性（filter） | `<think>` 不外洩 | 累積完整串流後套 `AIEnhancementOutputFilter` 一次（沿用 M3） |
| 取消正確性 | 取消不得誤判成功、不得誤清截圖 | 世代完成標記（FR-81）；in-flight image-deep 保護（FR-82） |
| 隱蔽性（失敗） | 失敗不得可見系統 UI | 沿用 M3 log-only；深答不支援/失敗僅在 overlay 顯示可關橫幅 |
| 遷移安全 | 舊資料不壞、舊設定不遺失核心 | 新欄位皆有預設值；舊 deep key 保留不刪；fast=即時沿用 |
| 可測性 | 不開會議軟體/網路即可驗證 | `FakeStreamingChatCompleting` 腳本化 delta（含 needsDeep JSON）；閘門/取消/成功訊號皆純邏輯可測 |

---

## Architecture Notes

### 慢層機制從 Tier 2 平移到 Tier 3（不是新寫）

M8 已建的「慢層」不變量——世代序號取消（被取消的舊 deep 不抹新 deep 的在途標記）、展開保護（在途 deep 目標 == 使用者
展開中 cue → 不取消，FR-54）、完成後自動展開/標未讀（FR-51）、`deepInFlightCueId` 進度 spinner——**整組平移**綁到 Tier 3。
中度（Tier 2）降格為「開口稿的自動續寫」，如同 Tier 1 的漸進渲染，**不掛**未讀徽章/自動展開/展開保護。實作上：現有
`runAutoDeep`/`runTier2`/`startDeep`/`isDeepProtected`/`cancelDeep`/`onDeepCompleted`/`deepGeneration`/`deepTaskCueId` 這組
**改綁 Tier 3 的欄位與 completer**；`runMedium` 是新的「中度」段，用即時 completer、無這些機制。

### 升級閘門：判斷落點在中度輸出（零額外呼叫）

`needsDeep` 由**中度分析**產出——它是唯一「已接地、已試答一次」的節點，判斷最準，且只是多幾個 token，**零額外 LLM 呼叫**。
`TierPrompts.tier2System`（中度）JSON 契約新增兩鍵：`needsDeep`（bool）與 `deepReason`（string，簡短原因，可顯示在
「深入分析」鈕旁 tooltip）。判準寫進 prompt：「涉及**多方案取捨、多步推導、架構/演算法設計、或你有實質不確定**才設
needsDeep=true；單純事實/定義/一句話能答的設 false」。既有 `uncertainties[]` 非空本身也是升級訊號，兩者相輔。
`TierParsers.parseTier2` 解析並防呆（缺鍵預設 false / 空字串）。

### 模型整併與遷移

- **即時模型** = 現 `fastProvider`/`fastModel`（key 不動），語意擴為「cue 抽取＋開口稿＋中度」。`MeetingCopilotLiveController`
  的 `makeFastCompleter`/`makeStreamingCompleter(fast...)` 沿用；中度改用這顆即時 completer（原本用 deep completer）。
- **深思模型** = 新 `deepThinkProviderV1`/`deepThinkModelV1`，預設 Gemini/`gemini-2.5-pro`。Tier 3 用它建 streaming completer。
- **舊 deep 設定退役**：`deepProvider`/`deepModel` 停止讀取（保留 UserDefaults key 不刪，向下相容不破壞；不再影響任何 tier）。
- 觀測 label：Tier 3 記 `deepThinkModelName`（"provider/model"）；中度記 `fastModelName`（與開口稿同顆，觀測時可分辨）。
- **深思預設須對 `availableModels` 驗證**：`gemini-2.5-pro` 確在 `AIService.availableModels(for: .gemini)`（recon 確認）；
  若使用者無 Gemini key，`MeetingCopilotModels.resolve` 回退預設 provider——此時深答可能落到非推理模型，屬可接受降級（UI 提示）。

### 缺陷修正（對抗式 review，2026-07-16，皆 CONFIRMED reachable）

1. **截圖深答把取消誤判成功 → 清空截圖佇列（HIGH）**：`requestDeepWithImages` 以 `!cue.tier2Error.isEmpty` 判失敗；但
   `runTier2` 在**取消**時（`Task.isCancelled` 早退）**不寫** tier2Error，串流用不 throw 的 `AsyncThrowingStream`（消費端取消
   只是 finish、不拋 CancellationError）。且 `autoDeepEnabled` 預設 true、截圖鈕在自動跟隨最新的 focusCard 上、`expandedCueId==nil`
   時 `isDeepProtected` 回 false → 新 cue 的 auto-deep `deepTask?.cancel()` 會取消在途截圖深答；回到 `requestDeepWithImages`
   時 tier2Error 為空 → 誤判成功 → `CopilotScreenshotStore.clear()`，截圖永久遺失、仍顯示舊文字答案、無錯誤。
   **修**：FR-81 的世代完成標記 + FR-82 的 image-deep 保護。
2. **視覺閘門漏 gpt-5 家族（HIGH）**：`visionMarkers` 無 `gpt-5` 子字串；OpenAI 預設 `gpt-5.5` 與多數 gpt-5.x 因此被判無視覺
   → `requestDeepWithImages` 直接中止，且提示訊息建議 `gpt-4o`（不在 `availableModels`）。**修**：FR-83。
3. **panic 還原反向（HIGH）**：`togglePanicHide` 僅以 `panicSnapshot != nil` 決定收/放；獨立的 `.toggleMeetingCopilotOverlay`
   / `.togglePresenterScript` 會改變面板可見性卻不動 snapshot，於是「panic → 手動 toggle 顯示 overlay → 再按 panic」會走還原
   分支、**反而把東西叫出來**。**修**：FR-84 改以實際可見狀態判斷。
4. （較低信心）`deepInFlightCueId` 無世代守衛，理論上兄弟 Task 收尾互抹；但同 cue 重現被既有保護擋住。M10 平移到 Tier 3 時
   一併以世代標記收斂（隨 FR-81 的世代化順手處理），不單獨立 FR。

### 截圖深答的 grounding：有圖跳過 OCR（沿用本 session 決策）

Tier 3 帶圖時，grounding 的 `includeScreen`（螢幕 OCR）**跳過**（圖片已含畫面，再塞 OCR 文字只增 token 又互相矛盾）——
沿用本 session 已實作的 `includeScreen: config.useScreenContext && images.isEmpty`。RAG 接地照常。

---

## Acceptance Criteria（僅本里程碑，AC-59~AC-69）

### AC-59: 中度分析恆自動接續且用即時模型
- **Given**: 一則技術 cue 完成開口稿（Tier 1）
- **When**: 無任何手動操作
- **Then**: 中度分析（Tier 2）**自動**開始，且其串流請求打到**即時模型**（與開口稿同顆），非深思模型；無「中度開關」可關閉此行為
- **Test**: `AnswerCoordinatorTests::mediumAlwaysFollowsOpenerOnFastModel`（fake：斷言中度 completer == fast completer、且無 gating flag 能阻止）

### AC-60: 中度輸出升級訊號
- **Given**: fake 中度回傳 JSON 含 `"needsDeep": true, "deepReason": "多方案取捨"`
- **When**: 中度解析完成
- **Then**: `cue.mediumNeedsDeep == true`、`cue.mediumDeepReason == "多方案取捨"`；缺鍵時預設 false/""
- **Test**: `TierParsersTests::parsesNeedsDeepAndReasonWithDefaults`

### AC-61: 自動閘門放行/不放行
- **Given**: `deepTrigger == .auto`
- **When**: 中度回報 `needsDeep=true`（技術 cue）／`needsDeep=false`
- **Then**: 前者**自動發起 Tier 3**（深思 completer 被呼叫一次）；後者**不發起**（深思 completer 零呼叫）
- **Test**: `DeepGateTests::autoFiresOnlyWhenNeedsDeep`（fake 深思 completer 斷言呼叫次數 1 / 0）

### AC-62: 手動模式只按鈕觸發、按鈕恆存在、進行中 disabled
- **Given**: `deepTrigger == .manual`，中度已完成（含 needsDeep=true）
- **When**: 未按按鈕 / 按下「深入分析」
- **Then**: 未按時 Tier 3 **不跑**；按下後跑一次；Tier 3 為該 cue 進行中時 `deepInFlightCueId == cue.id`（overlay 據此 disable 按鈕）
- **Test**: `DeepGateTests::manualModeRequiresButton` + `overlay` 人工/ViewInspector gate

### AC-63: 深思模型跑 Tier 3、慢層機制綁 Tier 3
- **Given**: Tier 3 由深思模型串流完成
- **When**: 完成寫回
- **Then**: 寫 `tier3Analysis`/`tier3FollowUps`/`tier3Uncertainties`/`deepThinkModelName`；`onDeepCompleted` 觸發（badge/auto-expand）
  **在 Tier 3 完成時**，中度完成**不**觸發 badge；latest-only 與展開保護作用於 Tier 3
- **Test**: `AnswerCoordinatorTests::deepCompletionDrivesBadgeNotMedium`

### AC-64: aboutMe / informational 不進 Tier 3
- **Given**: 一則 `aboutMe`（或 informational）cue，`deepTrigger=.auto` 且中度 needsDeep=true（若有）
- **When**: 中度完成 / 按深入鈕 / 按截圖深答
- **Then**: 三路皆**不**起 Tier 3（no-op，深思 completer 零呼叫）
- **Test**: `DeepGateTests::aboutMeAndInformationalNeverDeep`

### AC-65: 模型整併與遷移
- **Given**: 既有使用者的 fast=gemini flash、deep=gemini flash 設定
- **When**: 升級後載入設定
- **Then**: 即時模型 = 原 fast（開口稿＋中度皆用它）；深思模型 = 預設 `gemini-2.5-pro`（未曾設定）；設定頁只有「即時模型/深思模型」
  兩下拉 + 「深度分析觸發」picker；舊 deep 設定不再影響任何 tier
- **Test**: `MeetingCopilotConfigStoreTests::consolidatedModelsAndDeepThinkDefault`（用注入的 defaults 後端，**不碰 UserDefaults.standard**）

### AC-66: 截圖深答走 Tier 3 深思模型
- **Given**: 截圖佇列有 2 張、深思模型支援視覺
- **When**: 按「以截圖重新深答」
- **Then**: 帶圖的串流打到**深思模型**、寫回 `tier3*`（覆蓋深度分析）、grounding 的螢幕 OCR 被跳過（有圖）
- **Test**: `ImageDeepTests::imageDeepTargetsDeepThinkAndSkipsOCR`

### AC-67: 取消不誤判成功、不清截圖佇列
- **Given**: 截圖深答（image）在途，另一則新 cue 的自動升級嘗試取消 deep
- **When**: image-deep 因保護未被取消而正常完成 ／ 或（無保護情境）被取消
- **Then**: 完成 → 回 true、清佇列；被取消 → 回 false、**保留佇列**、顯示可見錯誤橫幅；**絕不**因 tier3Error 為空而誤判成功
- **Test**: `ImageDeepTests::cancelledImageDeepKeepsQueueAndReportsFailure` + `ImageDeepTests::inflightImageDeepProtectedFromAutoEscalation`

### AC-68: 視覺閘門涵蓋 gpt-5 家族且訊息可行
- **Given**: 深思模型 = `gpt-5.5`（或 `gpt-5.4`）
- **When**: `VisionModelSupport.isVisionCapable(label:)`
- **Then**: 回 true（gpt-5 家族視為視覺）；且不支援情境的提示字串只提及 `availableModels` 內的視覺模型（不含 gpt-4o）
- **Test**: `VisionModelSupportTests::gpt5FamilyIsVisionCapable` + `::unsupportedMessageSuggestsAvailableModel`

### AC-69: panic 還原以實際可見狀態判定
- **Given**: 錄音中，overlay 釘住、presenter 開；按 panic（全收起、快照）→ 用 `.toggleMeetingCopilotOverlay` 手動叫回 overlay
- **When**: 再按 panic
- **Then**: 因**當下有面板可見**（overlay），走**收起**分支（把 overlay 也收掉），**不**走還原分支把 presenter/pill 叫出
- **Test**: `PanicHideTests::restoreDecisionUsesActualVisibilityNotStaleSnapshot`

> **端到端 replay（umbrella）**：`FakeStreamingChatCompleting` 腳本化「開口稿 → 中度(needsDeep=true) → 自動 Tier 3 深答」，
> 斷言三段皆落 `MeetingLiveCue` 對應欄位、深思 completer 僅在放行時被呼叫、badge 綁 Tier 3。

---

## Open Questions

- [ ] 深思模型預設取 `gemini-2.5-pro`（穩、認得 thinking）還是 `gemini-3.1-pro-preview`（更新、preview）？暫定 2.5-pro。
- [ ] `deepTrigger` 預設 `.auto` 還是 `.manual`？暫定 `.auto`（使用者要「有深度且不想手動」；成本已被 needsDeep 閘門壓住）。
- [ ] `needsDeep` 判準鬆緊需實測校準：過鬆＝每題升級燒錢、過嚴＝難題漏升級。首版採保守（傾向 false，明確難題才 true）。
- [ ] 中度已寫「不確定項」時是否自動視為 needsDeep=true（即使模型沒設）？傾向否——交給模型自評，避免雙重來源打架。
- [ ] Tier 3 的 `max_tokens` / 深思延遲上限是否要另設（推理模型可能很長）？暫沿用既有 4096 + 串流資源逾時 180s。
- [ ] 覆盤頁是否顯示 `mediumNeedsDeep`/`deepReason`/`tier3TriggerRaw` 以校準閘門？屬 M5 覆盤頁增強，暫列 Should。
