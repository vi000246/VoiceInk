---
linear_issue: null
---
# Plan: Meeting Copilot M10 — 三階段回答 + 深思模型分級（Deep-Reasoning Tier）

> **For agentic workers:** **Mode B（任務先測）**：每個含邏輯的 task 先寫鎖行為的測試 → 實作 → 通過 → commit。
> **Rigor: strict** — `AnswerCoordinator` 是全 copilot 的答案編排核心，取消/保護/世代不變量一旦破壞會靜默出錯（會議中無從察覺）。
>
> **⚠️ 前置依賴**：M3/M8/M9 已實作並 commit；且**本 session 已建**的截圖深答 / panic-hide / 串流資源逾時已在工作樹
> （未 commit）。開工前先 `git --no-pager diff` 看清本 session 改動，並讀 SRS 全文與下方「規劃期發現」。
>
> **🔴 慢層平移，不是新寫**：M8 的世代取消 / 展開保護（FR-54）/ 未讀徽章（FR-51）/ 進度 spinner **整組從 Tier 2 平移到
> Tier 3**。中度（Tier 2）降格為「開口稿的自動續寫」，不掛這些機制。動手前務必理解現有 `runAutoDeep`/`runTier2`/
> `startDeep`/`isDeepProtected`/`deepGeneration`/`deepTaskCueId`/`onDeepCompleted` 這組不變量，平移時**逐一對應**。
>
> **Checkbox states:** `- [ ]` todo · `- [~]` in-progress · `- [x]` done。

## Summary

把「開口稿→深答」兩段重構為「開口稿（即時）→ 中度分析（即時，恆自動）→ 深度分析（深思，閘門）」三段；把 fast/deep 兩個
model 設定整併為「即時模型 / 深思模型」兩下拉（深思預設 `gemini-2.5-pro`）；為深度分析加自動/手動觸發閘門（自動＝中度順手
吐 `needsDeep` 才放行）；把本 session 的截圖深答改接深度分析；併同修正對抗式 review 確認的四個缺陷（成功判定、在途保護、
視覺閘門、panic 還原）。

## User Story

As a 會議中被問難題的使用者, I want 開口稿與中度分析維持即時、真正需要推理的題由一顆深思模型自動或手動補上深度分析,
so that 我不必在「即時」與「有深度」之間二選一，也不必怕換慢模型拖垮開口。

## Problem → Solution

快/深同顆 flash → 深答無推理增量；換慢模型又拖垮即時。
→ 兩顆模型拆延遲預算（即時 flash 承載開口稿＋中度；深思推理模型只在閘門放行時跑深度分析、晚到＋徽章吸收其慢）；判斷
「難不難」交給已試答過的中度順手產出（零額外呼叫）。

## Metadata
- **Module**: meeting-copilot
- **Parent Plan**: 依賴鏈 M3 → M8 → M9 → **M10**
- **Source PRD**: `docs/prd/meeting-copilot-deep-reasoning-tier.prd.md`
- **Source Feature SRS**: `docs/srs/meeting-copilot-m10-deep-reasoning-tier.srs.md`
- **Source Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Type**: feature ｜ **Size**: L ｜ **Complexity**: Large
- **Rigor**: strict ｜ **Mode**: B — 任務先測 ｜ **TDD**: on（引擎層 task-level；view 層無 ViewInspector → 人工 gate）
- **Estimated Files**: ~13（2 created 已存 / ~11 modified + ~5 test files）
- **Build**: 現值 → **現值+1**（bump `CURRENT_PROJECT_VERSION`，Debug + Release **兩處**）
- **FR 覆蓋**: FR-74 ~ FR-84
- **AC 覆蓋**: AC-59 ~ AC-69（AC-62 overlay disable、AC-66 部分 = 人工/ViewInspector gate）

---

## ⚠️ 規劃期發現（實作前必讀）

### 發現 1 — 慢層機制目前綁 Tier 2，必須整組平移到 Tier 3
`AnswerCoordinator` 的 `deepTask`/`deepGeneration`/`deepTaskCueId`/`isDeepProtected`/`onDeepCompleted`/`unreadDeepCueIds`/
`deepInFlightCueId` 現全綁「Tier 2 = 深答」。M10 後 Tier 2 = 中度（即時、無這些機制），Tier 3 = 深度（承接全部）。平移時
**逐一對應欄位與 completer**，別遺漏世代守門（被取消的舊 deep 不得抹新 deep 的在途標記——M8 踩過）。

### 發現 2 — 成功判定不能靠 `tierNError.isEmpty`（review CONFIRMED）
`runTier2` 取消時走 `Task.isCancelled` 早退、**不寫** error；`AsyncThrowingStream` 消費端取消只 finish 不 throw。故
`requestDeepWithImages` 現在的 `if !cue.tier2Error.isEmpty` 會把**取消**誤判成功、清空截圖佇列。**正解**：`runDeep` 成功寫回後
把 `generation` 記入 `completedDeepGenerations: Set<Int>`；呼叫端以 `contains(gen)` 判定。

### 發現 3 — 在途截圖深答會被新 cue 的自動升級秒殺（review CONFIRMED）
`expandedCueId==nil`（自動跟隨最新）時 `isDeepProtected` 回 false，新 cue 的自動升級 `deepTask?.cancel()` 會取消在途的
image-deep。**正解**：`trigger=="image"` 的在途 Tier 3 視同受保護（FR-82）。

### 發現 4 — 視覺閘門漏 gpt-5 家族（review CONFIRMED）
`VisionModelSupport.visionMarkers` 無 `gpt-5`；OpenAI 預設 `gpt-5.5` 被判無視覺、截圖深答直接中止，且訊息建議不存在的
`gpt-4o`。**正解**：加 `"gpt-5"` marker（FR-83），訊息改建議 `availableModels` 內型號。

### 發現 5 — panic 還原用過期 snapshot 會反向（review CONFIRMED）
`togglePanicHide` 只看 `panicSnapshot != nil`；獨立 toggle 改了可見性卻不動 snapshot。**正解**：以當下實際可見狀態判斷（FR-84）。

### 發現 6 — 深思預設須對 `availableModels` 驗證
`gemini-2.5-pro` 確在 `AIService.availableModels(for: .gemini)` 且 `ReasoningConfig` 認得為 thinking（recon 2026-07-16）。
無 Gemini key 時 `MeetingCopilotModels.resolve` 回退預設 provider（可能非推理）——屬可接受降級，UI 提示。

### 發現 7 — 測試禁碰 `UserDefaults.standard`
config 測試一律用注入的 `MeetingCopilotDefaults` 假後端（memory `voiceink-tests-never-touch-userdefaults`）；平行測試共用
domain，碰了就隨機紅燈。

---

## Mandatory Reading

| Priority | File | Why |
|---|---|---|
| P0 | `docs/srs/meeting-copilot-m10-deep-reasoning-tier.srs.md` | 本 milestone 需求 + AC + 缺陷根因全文 |
| P0 | `VoiceInk/Services/MeetingCopilot/AnswerCoordinator.swift` | 三段重構主場；慢層不變量 |
| P0 | `VoiceInk/Services/MeetingCopilot/TierPrompts.swift` / `TierTypes.swift` / `TierParsers.swift` | 中度加 needsDeep、新增 tier3 prompt/parse |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotLiveController.swift` | 兩顆 completer 解析與接線 |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | 模型整併 + deepTrigger |
| P1 | `VoiceInk/Views/MeetingCopilot/CopilotOverlayView.swift` | 三段渲染 + 深入鈕 disable |
| P1 | 本 session diff（`git --no-pager diff` + 兩個新檔） | 截圖深答/panic 現況，M10 在其上重寫 |

---

## Tasks

### Task 1 — Schema：`MeetingLiveCue` 加 Tier 3 + 升級訊號欄位
- [ ] **測試先**：`MeetingLiveModelsTests::tier3FieldsDefaultAndRoundTrip`（新欄位預設值 + JSON-in-raw 陣列存取器往返；lightweight migration 安全）
- [ ] 加 `tier3Analysis/tier3FollowUpsRaw/tier3UncertaintiesRaw`（+ `@Transient` 快取存取器，鏡射 tier2）、
      `tier3PromptUser/tier3RawReply/tier3GroundingElapsedMs/tier3StreamElapsedMs/tier3Error/tier3GroundingNote/tier3At/tier3TriggerRaw/deepThinkModelName`、
      `mediumNeedsDeep: Bool=false`、`mediumDeepReason: String=""`（皆有預設值）
- [ ] Commit

### Task 2 — 型別 + 解析：中度加 `needsDeep`/`deepReason`
- [ ] **測試先**：`TierParsersTests::parsesNeedsDeepAndReasonWithDefaults`（含缺鍵防呆）→ AC-60
- [ ] `Tier2Analysis` 加 `needsDeep: Bool` + `deepReason: String`；`TierParsers.parseTier2` 解析兩鍵（缺→false/""）；
      `parseTier3` 沿用 parseTier2 結構（needsDeep 在 tier3 忽略）
- [ ] Commit

### Task 3 — Prompt：中度自評 + 深度推理
- [ ] **測試先**：`TierPromptsTests::mediumSystemAsksNeedsDeep`（中度 system 含 needsDeep 契約與判準字串）、
      `::deepSystemIsReasoningPrompt`（tier3 system 要求深入推理 + 禁編造，沿用 FR-27 紅線）
- [ ] `tier2System`（中度）JSON 契約加 `needsDeep`/`deepReason` + 判準（多方案取捨/多步推導/架構演算法/實質不確定才 true）
- [ ] 新增 `tier3System`/`tier3User`（帶中度草稿全文；推理指示；沿用 outputLanguage/deepStyle/persona/guidance）
- [ ] Commit

### Task 4 — Config：模型整併 + `deepTrigger`
- [ ] **測試先**：`MeetingCopilotConfigStoreTests::consolidatedModelsAndDeepThinkDefault`（注入假後端）→ AC-65
- [ ] 新增 `deepThinkProviderV1`/`deepThinkModelV1`（預設 Gemini/`gemini-2.5-pro`）、`deepTrigger: {auto,manual}`（預設 `.auto`）
      + setters + load；`fast*` 語意註解改「即時模型」；停止讀取 `deep*`（key 保留不刪）；移除/固定中度的 `autoDeepEnabled` 相依
- [ ] Commit

### Task 5 — `AnswerCoordinator` 三段重構（核心）
- [ ] **測試先**：`AnswerCoordinatorTests::mediumAlwaysFollowsOpenerOnFastModel`（AC-59）、
      `DeepGateTests::autoFiresOnlyWhenNeedsDeep`（AC-61）、`::manualModeRequiresButton`（AC-62）、
      `::aboutMeAndInformationalNeverDeep`（AC-64）、`::deepCompletionDrivesBadgeNotMedium`（AC-63）
- [ ] `runTier1` 完成 → 恆接 `runMedium`（即時 completer；移除中度層 gating）；`runMedium` 解析 needsDeep 寫回 →
      `deepEligible(cue)` && `deepTrigger==.auto` && needsDeep → `startDeep`（Tier 3）
- [ ] 慢層機制平移到 Tier 3：`runDeep`（深思 completer，寫 tier3*）、世代取消、`isDeepProtected`、`onDeepCompleted`（badge）
      改在 Tier 3；`requestDeep` 起 Tier 3；`completedDeepGenerations` 成功標記（FR-81 種子，Task 7 用）
- [ ] Commit

### Task 6 — `VisionModelSupport` + panic 還原修正（缺陷 3、5）
- [ ] **測試先**：`VisionModelSupportTests::gpt5FamilyIsVisionCapable` + `::unsupportedMessageSuggestsAvailableModel`（AC-68）、
      `PanicHideTests::restoreDecisionUsesActualVisibilityNotStaleSnapshot`（AC-69）
- [ ] `visionMarkers` 加 `"gpt-5"`；不支援訊息改建議 availableModels 內型號
- [ ] `togglePanicHide` 改以「當下三面板實際可見狀態」決定收/放（任一可見→收+快照；全隱→依快照還原）
- [ ] Commit

### Task 7 — 截圖深答改接 Tier 3 + 成功訊號 + 在途保護（缺陷 1、2；FR-80/81/82）
- [ ] **測試先**：`ImageDeepTests::imageDeepTargetsDeepThinkAndSkipsOCR`（AC-66）、
      `::cancelledImageDeepKeepsQueueAndReportsFailure` + `::inflightImageDeepProtectedFromAutoEscalation`（AC-67）
- [ ] `requestDeepWithImages` 起 Tier 3（深思 completer + images）；視覺閘門對象改深思模型；
      成功以 `completedDeepGenerations.contains(gen)` 判定（非 tier3Error 空）→ 只在成功時 `CopilotScreenshotStore.clear()`；
      `trigger=="image"` 的在途 Tier 3 於 `isDeepProtected` 視同受保護
- [ ] Commit

### Task 8 — 接線：`MeetingCopilotLiveController` 兩顆 completer
- [ ] 解析深思 completer（`makeStreamingCompleter(deepThinkProvider, deepThinkModel)`，label→`deepThinkModelName`）；
      中度改用即時 completer；Tier 3 用深思 completer；截圖深答閉包走 Tier 3；`onImageUnsupported` 接線不變
- [ ] **測試**：`MeetingCopilotLiveControllerTests`（若有）或人工 gate；build 綠
- [ ] Commit

### Task 9 — Overlay 三段渲染 + 深入鈕（FR-77 disable）
- [ ] `CopilotOverlayView.focusCard` 三分區：開口稿 / 中度分析 / 深度分析（各自標題）；深度分區 spinner 綁 `deepInFlightCueId`
      + 徽章綁 tier3；「深入分析」鈕：`deepInFlightCueId==cue.id` 時 disabled（AC-62）；截圖深答鈕接 Tier 3；`deepReason` 作鈕 tooltip
- [ ] **人工/ViewInspector gate**（view 層無自動化基建）：列入 Validation 清單
- [ ] Commit

### Task 10 — Settings：兩下拉 + 觸發 picker
- [ ] `MeetingCopilotSettingsView` 模型 section：移除舊 deep picker，改「即時模型」+「深思模型」兩 picker（深思提示選 thinking 類）；
      加「深度分析觸發：自動/手動」picker（`bind(\.deepTrigger, store.setDeepTrigger)`）
- [ ] **人工 gate**；build 綠
- [ ] Commit

### Task 11 — 端到端 replay + 全量測試 + build
- [ ] `FakeStreamingChatCompleting` 腳本化「開口稿 → 中度(needsDeep=true) → 自動 Tier 3」端到端；斷言三段落欄位、深思僅放行時呼叫、badge 綁 Tier 3
- [ ] `make`/xcodebuild build 綠 + 全 meeting-copilot 測試綠（含 M8/M9 因慢層平移需更新的既有測試）
- [ ] bump build number（Debug+Release）；Commit

### Task 12 — 實作報告
- [ ] `docs/reports/meeting-copilot-m10-deep-reasoning-tier-report.md`：AC 逐條狀態、慢層平移對照、四缺陷修正驗證、人工 gate 清單、翻案記錄
- [ ] 更新 `docs/spec/SPEC_ROADMAP.md` 的 Recent Feature Changes；SRS front-matter/狀態標記
- [ ] Commit

---

## Validation（人工 gate — view 層無 ViewInspector 基建）

- [ ] 實機：技術難題 → 開口稿 <1s、中度 ~5s、自動模式下難題自動升級 Tier 3（深思模型、晚到、徽章）；簡單題停在中度
- [ ] 實機：手動模式 → 中度後不自動深答；按「深入分析」才跑；跑的當下按鈕 disabled
- [ ] 實機：截圖深答 → 走深思模型、覆蓋深度分析；深思模型設非視覺（如某純文字模型）→ 明確提示換模型（訊息型號可選）
- [ ] 實機：截圖深答在途時湧入新 cue → 截圖深答不被取消、佇列不被清（缺陷 2）
- [ ] 實機：panic → 手動 toggle 叫回 overlay → 再按 panic → 走收起（缺陷 5）

## Risks

| Risk | Mitigation |
|---|---|
| 慢層平移遺漏世代守門 → 取消互抹、徽章漏 | Task 5 逐一對應 M8 不變量；世代測試（AC-63/67） |
| 既有 M8/M9 測試因 tier2→中度語意變更而紅 | Task 11 明確納入「更新既有測試」；區分「行為該變」vs「意外壞掉」 |
| `needsDeep` 判準過鬆 → 每題升級燒錢 | 首版保守（明確難題才 true）；覆盤校準（Open Question） |
| 深思模型無 key/非推理 → 深答降級 | `MeetingCopilotModels.resolve` 回退 + UI 提示；不 crash |
| 截圖深答成功訊號改動觸及取消路徑 | 世代完成標記純邏輯可測（AC-67）；不靠 error 空 |
