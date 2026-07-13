# Implementation Report: Meeting Copilot M3 — 三層回應 + SSE + 接地

- **Plan**: `docs/plans/meeting-copilot-m3-tiered-response.plan.md`
- **Feature SRS**: `docs/srs/meeting-copilot-m3-tiered-response.srs.md`
- **Branch**: `feat/meeting-copilot-m1`
- **Build**: 249 → **250**
- **Date**: 2026-07-13

## Summary

把 M2 偵測到的一則 cue 變成「開口稿 + 深度分析」，接地於 brief/RAG/螢幕。**無 UI**——結果落 `MeetingLiveCue`，M4 讀取渲染。

- **Tier 0**（無 LLM，關鍵字表）→ 領域標籤 + 關鍵字。
- **Tier 1**（fast model SSE）→ `opener` + 恰 3 bullets；最新一則 cue 自動預跑。
- **Tier 2**（deep model SSE，帶入 Tier 1 草稿）→ analysis + followUps + uncertainties；可取消。
- 接地三來源全靜默降級：brief + RAG（直呼 embed+retrieve）+ 螢幕 OCR（只 Tier 2）。

## Tasks Completed（10/10）

| # | Task | Test | Status |
|---|---|---|---|
| 1 | StreamingChatClient（OpenAI parser）| `StreamingChatClientTests`（AC-11）| ✅ |
| 2 | StreamingChatClient（Anthropic parser）| 同上（AC-12）| ✅ |
| 3 | AIService.streamChat + seam | `StreamChatDispatchTests` | ✅ |
| 4 | MeetingCopilotModels.resolve | `MeetingCopilotModelsTests` | ✅ |
| 5 | ConfigStore 擴充（deep/prefetch/persona/RAG/screen）| 同上 | ✅ |
| 6 | TierTypes + Tier0Classifier | `Tier0KeywordTests`（AC-5）| ✅ |
| 7 | TierPrompts + TierParsers | `TierGeneratorTests`（AC-6, AC-14）| ✅ |
| 8 | MeetingGroundingProvider | `GroundingTests`（AC-9, AC-10）| ✅ |
| 9 | AnswerCoordinator | `AnswerCoordinatorTests`（AC-7, AC-8, AC-13）| ✅ |
| 10 | 接進 controller + build 250 | 全套迴歸 | ✅ |

## Validation

- 編譯零錯誤；9 個新測試檔全綠；全套 `VoiceInkTests`（M1+M2+M3）零回歸。
- 手動（真實模型的 SSE 串流品質、Tier 延遲體感）待 M4 UI + `make deploy` 後驗。

## AC Verification Map（AC-5 ~ AC-14）

| AC | Test | Status |
|----|------|--------|
| AC-5 Tier0 免 LLM | `Tier0KeywordTests::testProducesKeywordsWithoutLLMCall` | ✅ |
| AC-6 opener + 恰 3 bullets | `TierGeneratorTests::testTier1Parser...ThreeBullets` | ✅ |
| AC-7 預跑零等待 | `AnswerCoordinatorTests::testPrefetchNewest...`（fast callCount==1）| ✅ |
| AC-8 Tier2 帶入 Tier1 草稿 | 同上（deep.lastUser 含 opener）| ✅ |
| AC-9 RAG 靜默降級 | `GroundingTests::testRagSkippedSilentlyWhenEmbedderThrows` | ✅ |
| AC-10 螢幕只在 Tier2 | `GroundingTests::testScreenContextOnlyWhenIncluded` | ✅ |
| AC-11 OpenAI SSE parser | `StreamingChatClientTests::testOpenAIParser...` | ✅ |
| AC-12 Anthropic SSE parser | `StreamingChatClientTests::testAnthropicParser...` | ✅ |
| AC-13 失敗靜默降級 | `AnswerCoordinatorTests::testDeepFailureKeeps...` | ✅ |
| AC-14 不得編造 | `TierGeneratorTests::testDeepSystemPromptForbidsFabrication` | ✅ |

## Deviations from Plan（里程碑間不一致的調和）

實作時發現 M2（subagent 產）與 M3（我補完）plan 間有三處型別不一致，一律**以 M2 已 commit 的為準**，避免改動已落地的 model：

1. **config 的 fast 欄位**：M3 plan 原寫 `fastProvider: String = "Groq"`（非 optional），但 M2 已 commit `fastProviderName: String?`（nil=跟隨預設）。→ M3 只**新增** deep 欄位 + 開關，沿用 M2 的 optional 風格。
2. **`FollowUp` 型別**：M3 設計有 `FollowUp{question,oneLineAnswer}` 結構，但 M2 的 `MeetingLiveCue.tier2FollowUps` 是 `[String]`。→ M3 內部用 FollowUp，寫回 cue 時 `map(\.displayLine)` 序列化成字串。
3. **cue status**：M3 plan 引用 `.tier1`/`.tier2` 狀態，但 M2 的 `MeetingCueStatus` 只有 `.detected`/`.answered`。→ Tier1 完成由 `tier1Opener` 非空推斷，Tier2 完成才 `.answered`。

## Outstanding

- [ ] 真實模型驗證：SSE 串流對真實 Groq/Anthropic 端點的行為（fake SSE 只驗 parser 邏輯）。
- [ ] fast model 預設跟隨全域 provider——若使用者全域是慢的推理模型，Tier1 延遲會差。M5 設定 UI 應引導選 Groq；或未來讓 resolve 有低延遲預設。
- [ ] Tier0 關鍵字種子表的實會議調校（Open Question）。

## Next Steps

- M4 — 隱蔽 overlay + 熱鍵（讀 `MeetingCopilotController.cues` + `MeetingLiveCue` 的 tier 欄位渲染）。
  **含 sharingType 在 macOS 15.4+ 被 SCK 忽略的誠實邊界**（見 M4 plan/SRS）。
- M5 — 管理頁 + 設定 UI（雙 model picker 驅動 fast/deep）。
