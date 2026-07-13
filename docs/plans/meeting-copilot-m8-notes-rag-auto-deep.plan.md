---
linear_issue: null
---
# Plan: Meeting Copilot M8 — 筆記 RAG（aboutMe）+ auto-deep 閱讀保護 + 離線覆盤 + 即時翻譯

> **For agentic workers:** `/prp-implement` will route this plan to the matching skill based on `Metadata.Type` below. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Checkbox states (SDD Dashboard compatible):** `- [ ]` todo · `- [~]` in-progress · `- [x]` done. Treat `[~]` exactly like `[ ]` when judging whether a task is finished — it is NOT done.

## Summary

四組綁定升級，依 A→B→C→D 順序實作、每組獨立可驗收：(A) cue 五分類 `aboutMe` + Obsidian 筆記
RAG（重用 EmbeddingChunk 索引基建）；(B) 最新 cue 自動 Tier 2 + 自動展開 + 閱讀保護不變量 +
展開熱鍵；(C) 錄音管理任一錄音可離線產生覆盤 + 漏抓掃描 + 覆盤三層 debug 排序；(D) remote
committed 即時翻譯（混語→繁中）+ overlay 翻譯區 + 設定頁 tab 化。

## User Story

As a 有 ADHD 的工程師（會議中被問到自己的經歷會腦袋空白），
I want copilot 在被問到「我／我的專案／績效考核」時自動從我的 Obsidian 筆記撈記憶錨點、
自動跑完深度分析並穩定地展開給我讀、事後能對任何錄音重演並看出漏抓了什麼、混語會議有即時中文字幕，
So that 我能在 5 秒內開口、讀分析時不被新訊息打斷、並有一個閉環迴圈持續調校辨識品質。

## Problem → Solution

即時管線只服務技術問題（行為面試/考核題被歸 informational 不觸發）、Tier 2 要手點、閱讀會被新 cue
打斷、覆盤只能看已偵測的 cue、無翻譯 → aboutMe 走筆記檢索；自動 deep + 展開即保護；replay + 漏抓
掃描閉環；LLM 逐句翻譯。

## Metadata
- **Module**: meeting-copilot
- **Parent Plan**: N/A
- **Source PRD**: N/A
- **Source Feature SRS**: docs/srs/meeting-copilot-m8-notes-rag-auto-deep.srs.md
- **Source Module Spec**: docs/spec/meeting-copilot.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature
- **Size**: L
- **Complexity**: XL（四組；單一 plan、分組依序交付）
- **Rigor**: balanced
- **Mode**: B — 任務先測
- **TDD**: on（task-level test-first）
- **Commit cadence**: per-task
- **Estimated Files**: ~30（CREATE 8 / UPDATE ~22）

---

## UX Design

### Before

```
Overlay:                              覆盤詳情:                錄音管理詳情:
┌──────────────────────┐            cue 依時間排序           （無 copilot 區塊，
│ 會議輔助             │            （不分有無回應）          除非當場開過 live）
│ [cue1 focus 展開]    │
│ [cue2 單行]          │            設定頁: 單頁 Form
│  ↑新 cue 會把展開的  │            （無筆記 RAG/翻譯）
│   內容擠出 maxCues   │
│  Tier2 要手動點      │
└──────────────────────┘
```

### After

```
Overlay（翻譯開啟時）:               覆盤詳情:                 錄音管理詳情:
┌──────────────────────┐            ── 有回應的問題 ──        [產生會議copilot覆盤]
│ 會議輔助             │            cue+opener+分析…          （或既有覆盤按鈕
│ ── 即時翻譯 ──       │            ── 未回應/資訊 ──          ＋[重新產生]）
│ 「他說…(譯文)」      │            informational…
│ 「剛才那段…(譯文)」  │            ── 漏抓掃描 ⚠ ──         設定頁: [一般|即時翻譯]
│ ── 問題與回應 ──     │            未被辨識的通用問題         tab；一般 tab 內新增
│ [cue1 📌展開=保護]   │            （建議分類標示）           「個人筆記 RAG」區
│ [cue2 完成標記●]     │
│  熱鍵 toggle 展開    │
└──────────────────────┘
```

### Interaction Changes

| Touchpoint | Before | After | Notes |
|---|---|---|---|
| Tier 2 觸發 | 點擊 cue | 最新 cue 自動（`autoDeepEnabled`）；點擊仍可 | `tier2TriggerRaw` 記 auto/manual |
| 分析展開 | 手點；新 cue 進來 focus 轉移 | auto Tier2 完成自動展開（無人閱讀時）；展開=保護；熱鍵 toggle | `expandedCueId` 升到 controller |
| 被問個人問題 | informational，不觸發 | `aboutMe` → 筆記檢索 → 記憶錨點 opener/bullets | 檢索 query 用 searchHint |
| 錄音覆盤 | 只有 live session 有 | 任何錄音可產生 replay 覆盤 | 逐字稿重演，不重跑 ASR |
| 覆盤閱讀 | 依時間平鋪 | 有回應→無回應→漏抓 三層 | 漏抓=調校線索 |
| 混語會議 | 無輔助 | 翻譯字幕區（繁中） | 回應恆繁中 |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/meeting-copilot-m8-notes-rag-auto-deep.srs.md` | all | FR-41~64 / AC-28~47，本 plan 的驗收依據 |
| P0 | 專案記憶 `voiceink-running-unit-tests` | all | 測試指令必須照它，否則 host crash |
| P0 | `VoiceInk/Services/AskAI/TranscriptIndexService.swift` | all | 索引器要鏡射的形狀＋reconcile 要改的地方 |
| P0 | `VoiceInk/Services/MeetingCopilot/AnswerCoordinator.swift` | all | A/B 兩組的核心改動點 |
| P1 | `VoiceInk/Services/MeetingCopilot/ResponseCueExtractor.swift` | all | 五分類 prompt + JSON 契約 |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotController.swift` | 141-184 | ingest 觸發條件、refreshPublishedCues |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | all | 設定欄位慣例（keys/load/mutators） |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingGroundingProvider.swift` | all | gather 的 sources 改動點 |
| P1 | `VoiceInk/Views/MeetingCopilot/CopilotOverlayArranger.swift` | all | 防擠出改動點（純函式） |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotDiagnostics.swift` | all | RunConfig 快照要加欄位；sweep JSON 放這裡 |
| P2 | `VoiceInk/Services/RecorderAutomation/VaultExportService.swift` | 74-97 | bookmark 解析＋security-scope 慣例 |
| P2 | `VoiceInk/Services/AskAI/TranscriptChunker.swift` / `EmbeddingClient.swift` | all | 直接重用，勿重寫 |
| P2 | `VoiceInk/Views/MeetingCopilot/MeetingCopilotSettingsView.swift` | all | bind helper、Section 慣例、tab 化目標 |
| P2 | `VoiceInk/Services/MeetingCopilot/MeetingReplayDebugRunner.swift` | all | replay 接線先例（DEBUG 選單） |
| P2 | `VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift` | 220-300, 464-473 | 覆盤詳情 sheet＋kind 顯示字典 |

## External Documentation

無 — 全部使用既有內部 pattern（embedding/檢索/SSE/熱鍵/SwiftData 均有先例）。

---

## Patterns to Mirror

### CONFIG_STORE_FIELD（新增設定欄位的三件套）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift:32,93,138,206-209
private let useHistoryRAGKey = "meetingCopilotUseRAGV1"                  // 1. key
@Published private(set) var useHistoryRAG: Bool = false                  // 2. @Published private(set)
useHistoryRAG = (d.object(forKey: useHistoryRAGKey) as? Bool) ?? false   // 3a. load()（有非 false 預設值時用 ?? 形式）
func setUseHistoryRAG(_ value: Bool) {                                   // 3b. mutator
    useHistoryRAG = value
    UserDefaults.standard.set(value, forKey: useHistoryRAGKey)
}
```

### INDEX_UPSERT（取代式 upsert：刪舊塊→嵌入→插新塊）
```swift
// SOURCE: VoiceInk/Services/AskAI/TranscriptIndexService.swift:76-101
let vectors = try await embedder.embed(texts: drafts.map(\.text), model: model)
guard vectors.count == drafts.count else { throw EmbeddingError.countMismatch(...) }
deleteChunks(transcriptionId: tid, save: false)
for (draft, vector) in zip(drafts, vectors) {
    ctx.insert(EmbeddingChunk(
        transcriptionId: tid, chunkIndex: draft.index, text: draft.text,
        vector: EmbeddingClient.floatsToData(vector), dims: model.dims,
        embeddingModel: model.tag, sourceKind: kind,
        categoryId: nil, timestamp: mtime))
}
try? ctx.save()
```

### RECONCILE_ORPHANS（要加 obsidian 防護的原文）
```swift
// SOURCE: VoiceInk/Services/AskAI/TranscriptIndexService.swift:114-125
func reconcileOrphans() {
    guard let ctx = modelContext else { return }
    let allChunks = (try? ctx.fetch(FetchDescriptor<EmbeddingChunk>())) ?? []
    let indexedIds = Set(allChunks.map(\.transcriptionId))
    ...
    for chunk in allChunks where orphanIds.contains(chunk.transcriptionId) { ctx.delete(chunk) }
}
```

### EXTRACTOR_JSON_CONTRACT（容錯 parse + 私有 envelope）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/ResponseCueExtractor.swift:79-104
private struct CueEnvelope: Codable { let cues: [RawCue] }
private struct RawCue: Codable { let text: String; let kind: String }
static func parse(_ raw: String) -> [ExtractedCue] {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("```") { trimmed = trimmed.replacingOccurrences(of: "```json", with: "")
        .replacingOccurrences(of: "```", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let data = trimmed.data(using: .utf8),
          let envelope = try? JSONDecoder().decode(CueEnvelope.self, from: data) else { return [] }
    return envelope.cues.compactMap { ... }
}
```

### TIER_RUN（接地→prompt→串流累積→一次寫回 cue；觀測欄位）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/AnswerCoordinator.swift:77-113
private func runTier1(_ cue: MeetingLiveCue) async {
    let started = Date()
    let g = await grounding.gather(cueText: cue.text, brief: cue.session?.brief ?? "",
        includeRAG: config.useHistoryRAG, includeScreen: false)
    let system = TierPrompts.tier1System(persona: config.domainPersona)
    let user = TierPrompts.tier1User(cue: cue.text, grounding: g)
    cue.tier1PromptUser = user
    var acc = ""
    do { for try await d in fast.stream(system: system, user: user) {
            if Task.isCancelled { return }; acc += d } }
    catch { cue.tier1Error = error.localizedDescription; try? cue.modelContext?.save(); return }
    let draft = TierParsers.parseTier1(AIEnhancementOutputFilter.filter(acc))
    drafts[cue.id] = draft
    ...一次寫回全部欄位; try? cue.modelContext?.save()
}
```

### JACCARD_MATCH（sweep 與 cue 匹配直接重用）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingCueDeduplicator.swift:43-50,53-65
static func jaccard(_ a: String, _ b: String) -> Double { ... }   // bigram，中英混合穩健
// 門檻沿用 defaultThreshold = 0.6
```

### ARRANGER（防擠出要改的純函式）
```swift
// SOURCE: VoiceInk/Views/MeetingCopilot/CopilotOverlayArranger.swift:21-33
static func arrange<C>(_ cues: [C], askedAt: (C) -> Date, isAnswered: (C) -> Bool,
                       maxCount: Int) -> [(cue: C, emphasis: CopilotOverlayEmphasis)] {
    let newestFirst = cues.sorted { askedAt($0) > askedAt($1) }.prefix(maxCount)
    return newestFirst.enumerated().map { index, cue in
        if index == 0 { return (cue, .focus) }
        return (cue, isAnswered(cue) ? .answered : .recent) }
}
```

### SETTINGS_BIND（config private(set) 的 Binding 包法）
```swift
// SOURCE: VoiceInk/Views/MeetingCopilot/MeetingCopilotSettingsView.swift:215-217
private func bind<T>(_ keyPath: KeyPath<MeetingCopilotConfigStore, T>,
                     _ setter: @escaping (T) -> Void) -> Binding<T> {
    Binding(get: { store[keyPath: keyPath] }, set: { setter($0) })
}
```

### VAULT_BOOKMARK（vault 解析與 security scope）
```swift
// SOURCE: VoiceInk/Services/RecorderAutomation/VaultExportService.swift:75-77,93-97
let accessing = vaultRoot.startAccessingSecurityScopedResource()
defer { if accessing { vaultRoot.stopAccessingSecurityScopedResource() } }
func resolveVaultRoot(_ bookmark: Data) -> URL? {
    var stale = false
    return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
}
```

### INGEST_TRIGGER（tier 觸發條件——aboutMe 自然涵蓋，勿改條件式）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingCopilotController.swift:166-171
if e.kind != .informational, let coordinator = answerCoordinator {
    let cueRef = cue
    Task { await coordinator.onNewCue(cueRef) }
}
```

### SCOPE_SOURCES（檢索範圍過濾——sources 已支援任意字串）
```swift
// SOURCE: VoiceInk/Services/AskAI/RetrievalService.swift:55-57
if let sources = scope.sources {
    candidates = candidates.filter { sources.contains($0.sourceKind) }
}
```

### TEST_COMMAND（測試指令，一字不差；只換 -only-testing 目標）
```bash
# SOURCE: docs/plans/meeting-copilot-m2-cue-detection.plan.md:492-498 ＋ 專案記憶 voiceink-running-unit-tests
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  -only-testing:VoiceInkTests/<TestClass>
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/AskAI/ObsidianNoteIndexService.swift` | CREATE | A：筆記索引器（掃描/切塊/嵌入/增量/刪除＋sidecar 狀態） |
| `VoiceInk/Services/AskAI/TranscriptIndexService.swift` | UPDATE | A：reconcileOrphans 跳過 obsidian |
| `VoiceInk/Models/MeetingLiveModels.swift` | UPDATE | A/B/C/D：aboutMe case＋cue/session/segment 新欄位 |
| `VoiceInk/Services/MeetingCopilot/ResponseCueExtractor.swift` | UPDATE | A：五分類 prompt＋searchHint |
| `VoiceInk/Services/MeetingCopilot/AnswerCoordinator.swift` | UPDATE | A：sources 路由＋aboutMe prompt；B：auto-deep＋保護 |
| `VoiceInk/Services/MeetingCopilot/MeetingGroundingProvider.swift` | UPDATE | A：gather(sources:) |
| `VoiceInk/Services/MeetingCopilot/TierPrompts.swift` | UPDATE | A：aboutMe 變體；D：輸出語言指示 |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | UPDATE | A/B/D：新設定欄位 |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotDiagnostics.swift` | UPDATE | 快照新欄位＋sweep JSON 型別 |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotController.swift` | UPDATE | B：expandedCueId＋auto-expand；A：searchHint persist |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotLiveController.swift` | UPDATE | A：attach 後背景增量掃描；D：translator 接線 |
| `VoiceInk/Views/MeetingCopilot/CopilotOverlayArranger.swift` | UPDATE | B：pinned 防擠出 |
| `VoiceInk/Views/MeetingCopilot/CopilotOverlayView.swift` | UPDATE | B：controller 展開狀態；D：翻譯區 |
| `VoiceInk/Views/MeetingCopilot/MeetingCopilotSettingsView.swift` | UPDATE | A：筆記 RAG 區；B：auto-deep/熱鍵列；D：tab 化＋翻譯 tab |
| `VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift` | UPDATE | C：三層排序＋漏抓區＋badge；A：aboutMe 顯示字典 |
| `VoiceInk/Shortcuts/ShortcutAction.swift` | UPDATE | B：`toggleCopilotCueExpansion` |
| `VoiceInk/Shortcuts/ShortcutMigration.swift` | UPDATE | B：exhaustive switch |
| `VoiceInk/Shortcuts/RecordingShortcutManager.swift` | UPDATE | B：熱鍵分派 |
| `VoiceInk/Views/Settings/SettingsView.swift` | UPDATE | B：ShortcutRecorder 列（勿漏——.toggleMeetingRecording 曾漏過） |
| `VoiceInk/Services/MeetingCopilot/MeetingReplayReviewService.swift` | CREATE | C：離線 replay 管線 |
| `VoiceInk/Services/MeetingCopilot/MeetingReviewSweep.swift` | CREATE | C：漏抓掃描（prompt/parse/match 純函式＋執行） |
| `VoiceInk/Views/History/RecorderHistoryView.swift` | UPDATE | C：詳情頁「產生會議copilot覆盤」按鈕 |
| `VoiceInk/Services/MeetingCopilot/MeetingLiveTranslator.swift` | CREATE | D：翻譯 consumer |
| `VoiceInk/Services/MeetingCopilot/MeetingTranslationPrompt.swift` | CREATE | D：翻譯 prompt 純函式 |
| `VoiceInkTests/ObsidianNoteIndexTests.swift` | CREATE | AC-28/29 |
| `VoiceInkTests/AskAIIndexTests.swift` | UPDATE | AC-30 |
| `VoiceInkTests/ResponseCueExtractorTests.swift` | UPDATE | AC-31 |
| `VoiceInkTests/GroundingTests.swift` | UPDATE | AC-32 |
| `VoiceInkTests/TierPromptsTests.swift` | CREATE | AC-33/46 |
| `VoiceInkTests/AnswerCoordinatorTests.swift` | UPDATE | AC-34 |
| `VoiceInkTests/MeetingCopilotControllerTests.swift` | UPDATE | AC-35/36 |
| `VoiceInkTests/CopilotOverlayArrangerTests.swift` | UPDATE | AC-37 |
| `VoiceInkTests/MeetingReplayReviewTests.swift` | CREATE | AC-38~42 |
| `VoiceInkTests/MeetingTranslationTests.swift` | CREATE | AC-43/44/45/47 |
| `VoiceInkTests/MeetingCopilotConfigStoreTests.swift` | UPDATE | 新設定欄位 round-trip |

## NOT Building

- Ask AI 聊天頁的筆記檢索 UI（索引就緒即可後續加，本次不動 AskAIView 的 scope）
- vault FSEvents 即時監看、wiki-link/graph 檢索、本機 embedding
- 離線 replay 重跑 ASR／聲道分流；replay 的自動 Tier 2
- 翻譯 local 流、專用翻譯 API、逐 partial 翻譯
- informational cue 的即時行為變更；新 vault 位置設定（重用 `vaultRootBookmark`）

---

## Step-by-Step Tasks

> Mode B：每 task 先寫失敗測試 → 實作整個 task → 測試通過 → commit。
> 測試指令一律用 `TEST_COMMAND` pattern（只換 `-only-testing` 目標），下方以
> `RUN <TestClass>` 縮寫表示。

## A 組 — 個人筆記 RAG（Task 1–7）

### Task 1: 筆記切塊純函式（frontmatter 去除／標題前綴／確定性 UUID）

- **ACTION**: 建 `ObsidianNoteIndexService.swift`，先只放 `enum ObsidianNoteChunking` 純函式
  namespace（鏡射 `TranscriptChunker` 的純函式風格）。
- **TEST FIRST**（`VoiceInkTests/ObsidianNoteIndexTests.swift` 新檔）:
  ```swift
  import XCTest
  @testable import VoiceInk

  final class ObsidianNoteIndexTests: XCTestCase {

      func testStripFrontmatterRemovesYAMLBlock() {
          let md = "---\ntags: [a]\ndate: 2026-01-01\n---\n\n# 標題\n內文段落"
          XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter(md), "# 標題\n內文段落")
          // 沒有 frontmatter 時原樣返回
          XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter("純內容"), "純內容")
          // 只有開頭 --- 沒有收尾 → 不誤刪
          XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter("---\n沒收尾"), "---\n沒收尾")
      }

      func testChunksCarryTitlePrefix() {
          let drafts = ObsidianNoteChunking.chunks(title: "專案A", body: "第一段\n\n第二段")
          XCTAssertFalse(drafts.isEmpty)
          XCTAssertTrue(drafts.allSatisfy { $0.text.hasPrefix("《專案A》") })
      }

      func testDeterministicIdStableAndDistinct() {
          let a1 = ObsidianNoteChunking.noteId(relativePath: "工作/專案A.md")
          let a2 = ObsidianNoteChunking.noteId(relativePath: "工作/專案A.md")
          let b  = ObsidianNoteChunking.noteId(relativePath: "工作/專案B.md")
          XCTAssertEqual(a1, a2, "同路徑恆定")
          XCTAssertNotEqual(a1, b)
      }
  }
  ```
  RUN `ObsidianNoteIndexTests` — expect **FAIL**（型別不存在，compile error）
- **IMPLEMENT**（`VoiceInk/Services/AskAI/ObsidianNoteIndexService.swift` 開頭）:
  ```swift
  import Foundation
  import CryptoKit

  /// Obsidian 筆記 → 索引塊的純函式（切塊委給既有 TranscriptChunker）。
  enum ObsidianNoteChunking {

      /// 去 YAML frontmatter：檔案以 "---\n" 開頭且存在收尾 "\n---" 才剝，否則原樣。
      static func stripFrontmatter(_ md: String) -> String {
          guard md.hasPrefix("---\n") else { return md }
          let afterOpen = md.index(md.startIndex, offsetBy: 4)
          guard let close = md.range(of: "\n---", range: afterOpen..<md.endIndex) else { return md }
          var body = String(md[close.upperBound...])
          if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
          return body.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      /// 每塊前綴《標題》供 LLM 引用出處；切塊沿用 TranscriptChunker（段落、CJK-aware）。
      static func chunks(title: String, body: String) -> [ChunkDraft] {
          TranscriptChunker.chunks(for: body).map {
              ChunkDraft(index: $0.index, text: "《\(title)》\n\($0.text)")
          }
      }

      /// vault 相對路徑 → 確定性 UUID（SHA-256 前 16 bytes）。改名＝新 id＝舊塊變孤兒由 diff 清。
      static func noteId(relativePath: String) -> UUID {
          let digest = SHA256.hash(data: Data(relativePath.utf8))
          let bytes = Array(digest.prefix(16))
          return NSUUID(uuidBytes: bytes) as UUID
      }
  }
  ```
- **MIRROR**: `TranscriptChunker`（純函式 namespace）；`EmbeddingClient` 不在此層觸碰。
- **VALIDATE**: RUN `ObsidianNoteIndexTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): obsidian 筆記切塊純函式（M8 Task 1）`

### Task 2: ObsidianNoteIndexService（掃描／增量／upsert／刪除＋sidecar 狀態）

- **ACTION**: 同檔加 `@MainActor final class ObsidianNoteIndexService`，形狀鏡射
  `TranscriptIndexService`（injectable embedder、modelContext configure）。
- **TEST FIRST**（追加到 `ObsidianNoteIndexTests`；fake embedder 鏡射 `AskAIIndexTests` 的做法——
  回固定向量並計數呼叫）:
  ```swift
  @MainActor
  func testFullIndexThenIncrementalOnlyReembedsChangedFile() async throws {
      let (ctx, embedder) = try makeInMemoryContextAndFakeEmbedder()   // helper 鏡射 AskAIIndexTests
      let vault = try makeTempVault(files: [
          "工作/專案A.md": "---\ntags: [x]\n---\n# A\n內容甲",
          "日記/2026.md": "今天內容"])
      let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx,
                                         stateURL: vault.appendingPathComponent(".state.json"))
      // 全量
      let n1 = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [".obsidian"])
      XCTAssertGreaterThan(n1, 0)
      let all = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
      XCTAssertTrue(all.allSatisfy { $0.sourceKind == "obsidian" })
      XCTAssertTrue(all.contains { $0.text.hasPrefix("《專案A》") && !$0.text.contains("tags:") })
      // 增量：只改一檔＋刪一檔
      embedder.embedCallCount = 0
      try "改過的內容".write(to: vault.appendingPathComponent("工作/專案A.md"), atomically: true, encoding: .utf8)
      try FileManager.default.removeItem(at: vault.appendingPathComponent("日記/2026.md"))
      _ = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [".obsidian"])
      XCTAssertEqual(embedder.embedCallCount, 1, "只有變更檔重嵌")
      let after = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
      XCTAssertFalse(after.contains { $0.text.hasPrefix("《2026》") }, "刪除檔的塊要消失")
  }
  ```
  RUN `ObsidianNoteIndexTests` — expect **FAIL**
- **IMPLEMENT** 要點（完整 class）:
  - `reindex(vaultRoot:includeOnly:excluded:)`：`FileManager.enumerator` 收 `.md`（跳過 excluded
    目錄名；includeOnly 非空時只收其下）→ 每檔算 contentHash（SHA-256）→ 與 sidecar JSON
    （`[String: String]` path→hash，`stateURL` 讀寫）diff → 變更檔走 INDEX_UPSERT pattern
    （`transcriptionId: ObsidianNoteChunking.noteId(...)`、`sourceKind: "obsidian"`、
    `categoryId: nil`、`timestamp:` 檔案 mtime）；消失檔 `deleteChunks(noteId:)`。
  - 標題 = 檔名去 `.md`。空 body（去 frontmatter 後）→ 刪既有塊、不嵌入。
  - vault 存取包 security-scope（VAULT_BOOKMARK pattern；resolve 由呼叫端做，本 service 收 URL）。
  - 任何 embed 失敗 → throw 給呼叫端（設定頁顯示；attach 背景掃描則吞掉記 log——與
    `MeetingGroundingProvider` 的靜默紀律一致）。
  - `static let sourceKind = "obsidian"` 常數，避免魔字串散落。
- **MIRROR**: INDEX_UPSERT；`TranscriptIndexService.configureForTesting` 的注入形狀。
- **GOTCHA**: sidecar 寫入要在 chunks save 成功之後（先 persist 後記 hash，中斷時下次重掃）。
- **VALIDATE**: RUN `ObsidianNoteIndexTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): ObsidianNoteIndexService 增量索引（M8 Task 2）`

### Task 3: reconcileOrphans 跳過 obsidian（AC-30）

- **ACTION**: 改 `TranscriptIndexService.reconcileOrphans`。
- **TEST FIRST**（`AskAIIndexTests` 追加）:
  ```swift
  @MainActor
  func testReconcileOrphansPreservesObsidianChunks() throws {
      let ctx = ...  // 既有 in-memory helper
      ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "孤兒轉錄塊",
          vector: Data(), dims: 1, embeddingModel: "t", sourceKind: "dictation",
          categoryId: nil, timestamp: .now))
      ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "《筆記》塊",
          vector: Data(), dims: 1, embeddingModel: "t", sourceKind: "obsidian",
          categoryId: nil, timestamp: .now))
      try ctx.save()
      TranscriptIndexService.shared.configureForTesting(modelContext: ctx, embedder: FakeEmbedder())
      TranscriptIndexService.shared.reconcileOrphans()
      let left = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
      XCTAssertEqual(left.count, 1)
      XCTAssertEqual(left.first?.sourceKind, "obsidian")
  }
  ```
  RUN `AskAIIndexTests` — expect **FAIL**（obsidian 塊被誤刪）
- **IMPLEMENT**: `reconcileOrphans` 內把候選集合改為
  `allChunks.filter { $0.sourceKind != ObsidianNoteIndexService.sourceKind }` 之後再算
  `indexedIds`／刪除迴圈（兩處都要用過濾後集合）。註解寫明原因（筆記塊無對應 Transcription）。
- **VALIDATE**: RUN `AskAIIndexTests` — expect **PASS**（含既有孤兒清理測試不回歸）
- **COMMIT**: `fix(ask-ai): reconcileOrphans 不清 obsidian 筆記塊（M8 Task 3）`

### Task 4: MeetingCueKind.aboutMe＋五分類 prompt＋searchHint（AC-31）

- **ACTION**: `MeetingLiveModels.swift` 加 `case aboutMe` 與 cue 新欄位；
  `ResponseCueExtractor` 改五分類 systemPrompt、`ExtractedCue`/`RawCue` 加 `searchHint`；
  `MeetingCopilotController.ingest` persist `searchHint`；`MeetingCopilotPageView` 的
  `displayLabelZH` 加 `.aboutMe: "個人"`。
- **TEST FIRST**（`ResponseCueExtractorTests` 追加）:
  ```swift
  func testParseAboutMeWithSearchHint() {
      let raw = #"{"cues":[{"text":"你對X專案有什麼貢獻？","kind":"aboutMe","searchHint":"X專案 貢獻 成果"}]}"#
      let cues = ResponseCueExtractor.parse(raw)
      XCTAssertEqual(cues, [ExtractedCue(text: "你對X專案有什麼貢獻？", kind: .aboutMe,
                                         searchHint: "X專案 貢獻 成果")])
  }
  func testParseMissingSearchHintDefaultsEmpty() {
      let raw = #"{"cues":[{"text":"你會怎麼設計快取？","kind":"directQuestion"}]}"#
      XCTAssertEqual(ResponseCueExtractor.parse(raw).first?.searchHint, "")
  }
  func testSystemPromptCoversFiveKindsAndReviewExamples() {
      let p = ResponseCueExtractor.systemPrompt
      XCTAssertTrue(p.contains("aboutMe"))
      XCTAssertTrue(p.contains("貢獻"))       // 績效考核正例必須在 prompt 裡
      XCTAssertTrue(p.contains("自我介紹"))   // 從 informational 搬到 aboutMe 的關鍵例
      XCTAssertTrue(p.contains("searchHint"))
  }
  ```
  RUN `ResponseCueExtractorTests` — expect **FAIL**
- **IMPLEMENT**:
  - `ExtractedCue` 加 `var searchHint: String = ""`（Codable、Equatable 不變）；`RawCue` 加
    `let searchHint: String?`；`parse` 帶出 `searchHint ?? ""`。
  - systemPrompt 重寫五分類。分類判準段落（照 SRS FR-45/46 措辭）：
    `aboutMe`＝「需要回憶**我做過什麼／我的貢獻／我的觀點**才能答的——問我的專案、我的經歷、
    績效考核（你對某專案有什麼貢獻、最有成就感的專案、負責範圍、學到什麼）、行為面試
    （自我介紹、優缺點、團隊衝突經驗）。**即使非技術也歸此類**」；`informational` 收窄為
    「純資訊陳述＋純隱私資料（薪資/期望待遇/住址）＋寒暄＋行政」。
    JSON 契約行改為
    `{"cues":[{"text":"…","kind":"directQuestion|impliedChallenge|assignedToMe|aboutMe|informational","searchHint":"aboutMe 才給：把問題改寫成筆記檢索詞（專案名/動詞/名詞），其他類給空字串"}]}`。
  - `MeetingLiveCue` 加 `var searchHint: String = ""`、`var tier2TriggerRaw: String = ""`；
    `ingest` 建 cue 時 `cue.searchHint = e.searchHint`。
- **MIRROR**: EXTRACTOR_JSON_CONTRACT；String-in-raw 慣例（kind fallback informational 不變）。
- **GOTCHA**: golden tests 鎖住既有四類的測試會因 prompt 措辭改變而需要同步更新——只更新
  斷言的措辭錨點，不放寬容錯行為。
- **VALIDATE**: RUN `ResponseCueExtractorTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): cue 五分類 aboutMe + searchHint（M8 Task 4）`

### Task 5: gather(sources:)＋AnswerCoordinator 檢索路由（AC-32）

- **ACTION**: `MeetingGroundingProviding.gather` 加 `sources: Set<String>?` 與 `query: String`
  參數（query 取代 cueText 作為 embed 輸入，預設 = cueText）；`MeetingGroundingProvider`
  把 scope 從 `.all` 改為 `AskAIScope(sources: sources)`；`AnswerCoordinator.runTier1/runTier2`
  按 `cue.kind` 決定參數。
- **TEST FIRST**（`GroundingTests` 追加；fake retrieval 記錄收到的 scope——若既有 fake 是
  `MeetingGroundingProviding` 層級，改在 `AnswerCoordinatorTests` 用 spy grounding 斷言）:
  ```swift
  @MainActor
  func testAboutMeRoutesToObsidianWithSearchHint() async {
      let spy = SpyGrounding()   // 記錄 gather 收到的 (query, sources, includeRAG)
      let coordinator = AnswerCoordinator(fast: FakeStreamer(reply: "OPENER: x\n- a\n- b\n- c"),
          deep: FakeStreamer(reply: "{}"), grounding: spy, config: testConfig)
      let cue = makeCue(kind: .aboutMe, text: "最有成就的專案？", searchHint: "專案 成果 上線")
      await coordinator.onNewCue(cue); await coordinator.drainForTest()
      XCTAssertEqual(spy.lastSources, ["obsidian"])
      XCTAssertEqual(spy.lastQuery, "專案 成果 上線")
      XCTAssertTrue(spy.lastIncludeRAG, "aboutMe 強制 RAG，不看 useHistoryRAG")
  }
  @MainActor
  func testTechnicalCueKeepsTranscriptSources() async {
      testConfig.setUseHistoryRAG(true)
      ...
      XCTAssertEqual(spy.lastSources, ["dictation", "recorder", "meeting"])
      // notesInTechnicalRAG=true 時才含 "obsidian"（第二段斷言）
  }
  ```
  RUN `GroundingTests`（或 `AnswerCoordinatorTests`）— expect **FAIL**
- **IMPLEMENT**:
  - protocol 簽章：`gather(query: String, brief: String, includeRAG: Bool, includeScreen: Bool,
    sources: Set<String>?) async -> MeetingGrounding`（一處 protocol＋一處 live＋測試 fakes 同步改）。
  - `MeetingGroundingProvider.gather`：`RetrievalService.retrieve(queryVector:…, scope:
    AskAIScope(sources: sources), …)`；`sources == nil` 維持 `.all`（僅 DEBUG replay 用）。
  - `AnswerCoordinator` 私有 helper：
    ```swift
    private func groundingPlan(for cue: MeetingLiveCue) -> (query: String, includeRAG: Bool, sources: Set<String>?) {
        if cue.kind == .aboutMe {
            let q = cue.searchHint.isEmpty ? cue.text : cue.searchHint
            return (q, config.useNotesRAG, ["obsidian"])
        }
        var s: Set<String> = ["dictation", "recorder", "meeting"]
        if config.notesInTechnicalRAG { s.insert("obsidian") }
        return (cue.text, config.useHistoryRAG, s)
    }
    ```
    `runTier1`/`runTier2` 都改用它（Tier2 的 includeScreen 邏輯不動）。
- **MIRROR**: SCOPE_SOURCES；TIER_RUN。
- **GOTCHA**: `useNotesRAG` 此時尚未存在——本 task 一併在 ConfigStore 加
  `useNotesRAG`/`notesInTechnicalRAG` 兩欄位（CONFIG_STORE_FIELD 三件套；UI 留給 Task 7）。
- **VALIDATE**: RUN `GroundingTests` ＋ `AnswerCoordinatorTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): 檢索路由 gather(sources:)（M8 Task 5）`

### Task 6: aboutMe tier prompt 變體＋aboutMeBrief（AC-33）

- **ACTION**: `TierPrompts` 加 `tier1SystemAboutMe(persona:)`／`tier2SystemAboutMe(persona:)`
  與 user 變體（帶 `aboutMeBrief`）；`AnswerCoordinator` 按 kind 選用；ConfigStore 加
  `aboutMeBrief`。
- **TEST FIRST**（`VoiceInkTests/TierPromptsTests.swift` 新檔）:
  ```swift
  import XCTest
  @testable import VoiceInk

  final class TierPromptsTests: XCTestCase {
      func testAboutMeTier1LocksToNotes() {
          let s = TierPrompts.tier1SystemAboutMe(persona: "p")
          XCTAssertTrue(s.contains("只能使用"))       // 鐵律：只用筆記與自介
          XCTAssertTrue(s.contains("筆記沒記"))       // 沒記載就直說
          XCTAssertTrue(s.contains("OPENER:"))        // 與既有 parser 相容
          let u = TierPrompts.tier1UserAboutMe(cue: "貢獻？",
              grounding: MeetingGrounding(brief: "", ragExcerpts: ["《專案A》內容"], screenText: nil),
              aboutMeBrief: "後端工程師，主力專案A")
          XCTAssertTrue(u.contains("《專案A》內容"))
          XCTAssertTrue(u.contains("主力專案A"))
      }
      func testAboutMeTier2UncertaintiesSemantics() {
          XCTAssertTrue(TierPrompts.tier2SystemAboutMe(persona: "p").contains("筆記沒覆蓋"))
      }
  }
  ```
  RUN `TierPromptsTests` — expect **FAIL**
- **IMPLEMENT**: 變體照既有 `tier1System` 結構。tier1 system 核心句：
  「你是我的個人記憶助手。對方問到**我本人的經歷／專案／貢獻**。下方『我的筆記』與『我的自介』
  是**唯一事實來源**——只能使用它們，筆記沒記載的直接說『筆記沒記』，絕不編造。
  bullets 輸出**記憶錨點**：專案名／我的角色／具體貢獻／量化成果，每點 ≤20 字」；
  格式段落與既有 tier1System 完全相同（OPENER + 恰 3 bullets）。tier2 system 沿用既有 JSON
  契約，`uncertainties` 描述改「筆記沒覆蓋、需要我靠現場記憶補充的部分」。
  user 變體 = 既有 userBlock + `我的自介：\(aboutMeBrief)`（空則略）+ cue 行。
  `AnswerCoordinator.runTier1/runTier2`：`cue.kind == .aboutMe` 時選變體並傳
  `config.aboutMeBrief`。ConfigStore 加 `aboutMeBrief`（CONFIG_STORE_FIELD，String 空預設）。
- **MIRROR**: `TierPrompts.tier1System`（TierPrompts.swift:10-31）。
- **VALIDATE**: RUN `TierPromptsTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): aboutMe 記憶錨點 tier prompts（M8 Task 6）`

### Task 7: 設定 UI「個人筆記 RAG」＋attach 背景增量掃描＋快照欄位

- **ACTION**: `MeetingCopilotSettingsView` 接地 Section 下加「個人筆記 RAG」Section；
  `MeetingCopilotLiveController` attach 成功後 fire-and-forget 背景增量掃描；
  `MeetingCopilotRunConfig` 加新欄位。
- **TEST FIRST**（`MeetingCopilotConfigStoreTests` 追加，round-trip 慣例）:
  ```swift
  func testNotesRAGSettingsRoundTrip() {
      let store = MeetingCopilotConfigStore()
      store.setUseNotesRAG(false); store.setNotesInTechnicalRAG(true)
      store.setAboutMeBrief("後端工程師")
      store.setNotesIncludeOnlyFolders(["工作"]); store.setNotesExcludedFolders([".obsidian"])
      let reloaded = MeetingCopilotConfigStore()
      XCTAssertFalse(reloaded.useNotesRAG)
      XCTAssertTrue(reloaded.notesInTechnicalRAG)
      XCTAssertEqual(reloaded.aboutMeBrief, "後端工程師")
      XCTAssertEqual(reloaded.notesIncludeOnlyFolders, ["工作"])
  }
  ```
  RUN `MeetingCopilotConfigStoreTests` — expect **FAIL**
- **IMPLEMENT**:
  - ConfigStore 加 `notesIncludeOnlyFolders: [String] = []`／
    `notesExcludedFolders: [String] = [".obsidian", ".trash", "Templates"]`
    （UserDefaults `stringArray(forKey:)`；空陣列與未設定同義）。
  - Settings Section（SETTINGS_BIND）：vault 狀態列（`RecorderConfigStore.shared.vaultRootBookmark`
    有值→顯示解析路徑；nil→「尚未設定——到『錄音裝置』設定 Obsidian Vault」）、
    `useNotesRAG`/`notesInTechnicalRAG` Toggle、`aboutMeBrief` TextField、
    include/exclude 資料夾 TextField（逗號分隔 ↔ 陣列）、「重建筆記索引」按鈕
    （呼叫 `ObsidianNoteIndexService.reindex`，跑動中 ProgressView，完成顯示「N 塊」，
    `EmbeddingError.missingAPIKey` → 顯示「需要 Gemini/OpenAI embedding 金鑰」警告字）。
  - `MeetingCopilotLiveController` attach 完成後：
    `Task.detached(priority: .background) { try? await index.reindex(...) }`（失敗吞掉記 log
    `🗂️ 筆記增量索引失敗: …`；vault nil 直接 return）。
  - `MeetingCopilotRunConfig` 加 `useNotesRAG`/`notesInTechnicalRAG`/`aboutMeBrief` 欄位
    （Codable additive，舊快照 decode 相容——欄位用 optional 或帶預設）。
- **MIRROR**: CONFIG_STORE_FIELD；SETTINGS_BIND；groundingSection（MeetingCopilotSettingsView:138-150）。
- **VALIDATE**: RUN `MeetingCopilotConfigStoreTests` — expect **PASS**；
  RUN `MeetingCopilotObservabilityTests`（快照 round-trip 不回歸）
- **COMMIT**: `feat(meeting-copilot): 筆記 RAG 設定與背景增量索引（M8 Task 7）`

## B 組 — auto-deep 與閱讀保護（Task 8–11）

### Task 8: expandedCueId 升到 controller＋arranger 防擠出（AC-37）

- **ACTION**: `MeetingCopilotController` 加 `@Published var expandedCueId: UUID?`；
  `CopilotOverlayArranger.arrange` 加 `pinnedId` 參數；`CopilotOverlayView` 改用 controller
  狀態（刪掉 view 的 `@State private var expandedCueId`）。
- **TEST FIRST**（`CopilotOverlayArrangerTests` 追加；素 struct 慣例）:
  ```swift
  func testPinnedCueSurvivesMaxCountEviction() {
      // 6 則 cue、maxCount 5：最舊那則是展開中 → 必須保留
      let cues = (0..<6).map { TestCue(id: UUID(), askedAt: Date(timeIntervalSince1970: Double($0)), answered: false) }
      let pinned = cues[0].id   // 最舊，正常會被截掉
      let out = CopilotOverlayArranger.arrange(cues, askedAt: \.askedAt.get, isAnswered: \.answered.get,
                                               maxCount: 5, pinnedId: pinned, id: \.id.get)
      XCTAssertTrue(out.contains { $0.cue.id == pinned }, "展開中 cue 不被擠出")
      XCTAssertEqual(out.count, 5, "總數仍受 maxCount 約束（擠掉最舊的非 pinned）")
      XCTAssertEqual(out.first?.cue.id, cues[5].id, "最新仍在最上、仍為 focus")
  }
  func testNilPinnedKeepsExistingBehavior() {
      // pinnedId=nil → 輸出與改動前完全一致（回歸鎖）
  }
  ```
  RUN `CopilotOverlayArrangerTests` — expect **FAIL**（無 pinnedId 參數，compile error）
- **IMPLEMENT**:
  ```swift
  // CopilotOverlayArranger.arrange 簽章加:
  //   pinnedId: AnyHashable? = nil, id: (C) -> AnyHashable
  // 邏輯: 先取 newestFirst prefix(maxCount)；若 pinnedId 存在且不在其中 →
  //   從全集找到它，替換掉 prefix 中最舊的非 pinned 項（維持總數）。
  // emphasis 規則不變（index 0 = focus；pinned 若非最新 → .recent/.answered 照舊，
  //   view 端以 expandedCueId 決定展開，emphasis 只管字級）。
  ```
  `CopilotOverlayView.arranged` 傳 `pinnedId: controller.expandedCueId, id: { $0.id }`；
  view 內兩處 `expandedCueId` 讀寫改為 `controller.expandedCueId`（`@ObservedObject` 已存在）。
- **MIRROR**: ARRANGER（generic over C、素 struct 測試）。
- **GOTCHA**: view 既有語意「nil = 自動展開最新一則」必須保留（`autoExpandedId` 計算屬性照舊）。
- **VALIDATE**: RUN `CopilotOverlayArrangerTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): 展開狀態升 controller + arranger 防擠出（M8 Task 8）`

### Task 9: AnswerCoordinator auto-deep＋保護取消語意（AC-34）

- **ACTION**: `runTier1` 完成後自動觸發 Tier 2（latest-only）；deep 取消保護；
  `tier2TriggerRaw` 寫入；ConfigStore 加 `autoDeepEnabled`。
- **TEST FIRST**（`AnswerCoordinatorTests` 追加；FakeStreamer 沿用既有 fake）:
  ```swift
  @MainActor
  func testAutoDeepRunsAfterTier1AndMarksTrigger() async {
      testConfig.setAutoDeepEnabled(true)
      let coordinator = makeCoordinator(fastReply: "OPENER: x\n- a\n- b\n- c",
                                        deepReply: #"{"analysis":"深","followUps":[],"uncertainties":[]}"#)
      let cue = makeCue(kind: .directQuestion, text: "怎麼設計快取？")
      await coordinator.onNewCue(cue)
      await coordinator.awaitQuiescentForTest()   // 等 prefetch+autoDeep 鏈完成（新增測試 hook）
      XCTAssertEqual(cue.tier2Analysis, "深")
      XCTAssertEqual(cue.tier2TriggerRaw, "auto")
  }
  @MainActor
  func testNewCueDoesNotCancelExpandedCuesInflightDeep() async {
      // deep fake 可掛起（AsyncStream 手動餵）；cue A 展開中（expandedCueIdProvider 回 A.id）
      // cue B 進來觸發 auto-deep → A 的 deep 續跑完成、tier2Analysis 寫回
      ...
      XCTAssertFalse(a.tier2Analysis.isEmpty, "展開中 cue 的 deep 不被取消")
  }
  ```
  RUN `AnswerCoordinatorTests` — expect **FAIL**
- **IMPLEMENT**:
  - `AnswerCoordinator` 加 `var expandedCueIdProvider: () -> UUID? = { nil }`（live 端由
    controller 閉包注入；測試注入 stub——避免 coordinator 依賴 controller）。
  - `runTier1` 尾端（成功寫回後）：
    ```swift
    if config.autoDeepEnabled, !Task.isCancelled {
        await runAutoDeep(cue)
    }
    ```
    `runAutoDeep`：若 `deepTask` 在途且其目標 == `expandedCueIdProvider()` → 跳過並
    `logger.notice("🫆 auto-deep 跳過（展開保護中）")`（FR-54）；否則
    `deepTask?.cancel()`（僅當舊目標**非**展開中）→ 開新 task 跑 `runTier2(cue, draft:)`，
    寫 `cue.tier2TriggerRaw = "auto"`。
  - `requestDeep`（手動路徑）寫 `"manual"`；取消判斷同樣尊重展開保護（手動點擊視為
    使用者意圖，可取消**自己先前**的手動 deep，但不取消展開中 cue 的）。
  - deep 目標追蹤：`private var deepTaskCueId: UUID?` 隨 task 設定/清除。
  - ConfigStore 加 `autoDeepEnabled: Bool = true`（未設定 → true；CONFIG_STORE_FIELD）。
  - `MeetingCopilotRunConfig` 加 `autoDeepEnabled`。
- **MIRROR**: TIER_RUN（prefetchTask 的「只保最新」語意）；`drafts[cue.id]` 快取。
- **GOTCHA**: `runTier1` 在 prefetchTask 內執行，新 cue 會 cancel 舊 prefetch——auto-deep 掛在
  tier1 完成之後，天然只有「活到最後的最新 cue」會進 deep，正是 latest-only 語意。
  但 `Task.isCancelled` 檢查必須在 `runAutoDeep` 前，避免已取消的 tier1 又拉起 deep。
- **VALIDATE**: RUN `AnswerCoordinatorTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): auto-deep + 展開保護取消語意（M8 Task 9）`

### Task 10: 自動展開與完成標記（AC-35）

- **ACTION**: `MeetingCopilotController` 加 auto-expand 決策 + 「分析完成未讀」集合。
- **TEST FIRST**（`MeetingCopilotControllerTests` 追加）:
  ```swift
  @MainActor
  func testAutoExpandOnlyWhenNothingExpanded() {
      let c = makeController()
      let a = UUID(), b = UUID()
      c.handleDeepCompleted(cueId: a)          // 無展開 → 自動展開 a
      XCTAssertEqual(c.expandedCueId, a)
      c.handleDeepCompleted(cueId: b)          // a 展開中 → 不搶，b 進未讀標記
      XCTAssertEqual(c.expandedCueId, a)
      XCTAssertTrue(c.unreadDeepCueIds.contains(b))
      c.toggleExpansion(latestWithContent: b)  // 熱鍵/點擊展開 b → 未讀清除
      XCTAssertFalse(c.unreadDeepCueIds.contains(b))
  }
  ```
  RUN `MeetingCopilotControllerTests` — expect **FAIL**
- **IMPLEMENT**:
  - controller 加 `@Published var unreadDeepCueIds: Set<UUID> = []` 與
    `func handleDeepCompleted(cueId: UUID)`：`expandedCueId == nil ? expandedCueId = cueId
    : unreadDeepCueIds.insert(cueId)`（cueId 已展開者不標未讀）。
  - `AnswerCoordinator` 加 `var onDeepCompleted: (UUID) -> Void = { _ in }`，`runTier2`
    成功寫回後呼叫（auto 與 manual 都叫——手動時 expandedCueId 通常已是該 cue，no-op）。
  - live 接線（`MeetingCopilotLiveController` 建 coordinator 處）：
    `coordinator.onDeepCompleted = { [weak controller] in controller?.handleDeepCompleted(cueId: $0) }`、
    `coordinator.expandedCueIdProvider = { [weak controller] in controller?.expandedCueId }`。
  - `CopilotOverlayView`：cue 行有 `unreadDeepCueIds` 標記時顯示「● 分析完成」小徽章；
    展開該 cue（點擊既有手勢）時 `unreadDeepCueIds.remove`。
- **MIRROR**: `deepInFlightCueId` 的 @Published 慣例（MeetingCopilotController.swift:35）。
- **VALIDATE**: RUN `MeetingCopilotControllerTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): 自動展開與未讀標記（M8 Task 10）`

### Task 11: 展開 toggle 熱鍵（四處註冊）＋設定列（AC-36）

- **ACTION**: 新 `ShortcutAction.toggleCopilotCueExpansion`；controller 加 toggle 語意；
  settings 熱鍵 Section 加 ShortcutRecorder 列＋auto-deep Toggle。
- **TEST FIRST**（`MeetingCopilotControllerTests` 追加）:
  ```swift
  @MainActor
  func testToggleExpansionSemantics() {
      let c = makeController()
      let newest = UUID()
      c.expandedCueId = UUID()
      c.toggleExpansion(latestWithContent: newest)
      XCTAssertNil(c.expandedCueId, "有展開者 → 收合")
      c.toggleExpansion(latestWithContent: newest)
      XCTAssertEqual(c.expandedCueId, newest, "無展開 → 展開最新有內容者")
      c.expandedCueId = nil
      c.toggleExpansion(latestWithContent: nil)
      XCTAssertNil(c.expandedCueId, "沒有任何有內容的 cue → no-op")
  }
  ```
  RUN `MeetingCopilotControllerTests` — expect **FAIL**
- **IMPLEMENT**:
  - controller：`func toggleExpansion(latestWithContent: UUID?)`（測試如上）；
    「最新有內容」的計算屬性：`cues` 反向找第一個 `!tier1Opener.isEmpty || !tier2Analysis.isEmpty`。
  - 四處註冊（照 M4 的 toggle/peek 先例，各檔搜 `toggleMeetingCopilotOverlay` 依樣新增）：
    `ShortcutAction.swift` 加 case＋顯示名「展開/收合分析」；`ShortcutMigration.swift:271`
    exhaustive switch 加分支；`RecordingShortcutManager.swift:334` 分派到
    `CopilotOverlayWindowManager`（轉呼叫 controller.toggleExpansion）；
    `SettingsView.swift:78-100` 加 ShortcutRecorder 列（**這處最容易漏**）。
  - `MeetingCopilotSettingsView` hotkeySection 也加同一 recorder 列（模組設定頁的鏡射列，
    照 `.toggleMeetingCopilotOverlay` 現況）；modelSection 後加
    `Toggle("Tier 1 完成後自動深度分析", isOn: bind(\.autoDeepEnabled, store.setAutoDeepEnabled))`。
- **MIRROR**: 模組 spec「新增全域熱鍵（4 處）」pattern 列；MeetingCopilotSettingsView:196-199。
- **GOTCHA**: `ShortcutMigration` 漏 case 是**編譯錯誤**（好事）；`SettingsView` 漏列只會
  默默讓熱鍵無法設定——用 grep 驗證四處都有新 case 名。
- **VALIDATE**: RUN `MeetingCopilotControllerTests` — expect **PASS**；
  `grep -c toggleCopilotCueExpansion` 於四檔皆 ≥1
- **COMMIT**: `feat(meeting-copilot): 展開 toggle 熱鍵（M8 Task 11）`

## C 組 — 離線覆盤與 debug 排序（Task 12–15）

### Task 12: session/cue 新欄位＋replay 分段純函式（AC-39）

- **ACTION**: `MeetingLiveSession` 加 `sourceRaw`/`reviewSweepRaw`；新
  `MeetingReplayReviewService.swift` 先放 `enum ReplaySegmentation` 純函式。
- **TEST FIRST**（`VoiceInkTests/MeetingReplayReviewTests.swift` 新檔）:
  ```swift
  import XCTest
  @testable import VoiceInk

  final class MeetingReplayReviewTests: XCTestCase {
      func testSegmentationPrefersSpeakerTurns() {
          let segs = [SpeakerSegment(speaker: 1, text: "你好，先自我介紹一下。", start: 0, end: 3),
                      SpeakerSegment(speaker: 2, text: "我是 Logan。", start: 3, end: 5)]
          let units = ReplaySegmentation.segments(text: "整段原文", speakerSegments: segs)
          XCTAssertEqual(units.count, 2)
          XCTAssertEqual(units[0], "你好，先自我介紹一下。")
      }
      func testSegmentationFallsBackToSentenceGroups() {
          let text = "第一句。第二句！第三句？第四句。第五句。第六句。"
          let units = ReplaySegmentation.segments(text: text, speakerSegments: [])
          XCTAssertGreaterThan(units.count, 1, "純文字按句群切多段")
          XCTAssertEqual(units.joined(), text.replacingOccurrences(of: " ", with: ""), "不丟內容")
      }
  }
  ```
  RUN `MeetingReplayReviewTests` — expect **FAIL**
- **IMPLEMENT**:
  - Models：session 兩欄位（見 SRS Data Models 表；預設值 lightweight migration，無需三處註冊
    ——沒有新 @Model）。
  - `ReplaySegmentation.segments(text:speakerSegments:)`：有輪次→逐輪次原文（空輪次過濾）；
    無→以句終符（。．.!?！？\n，沿用 `TranscriptChunker.trailingSentences` 的終符集合）切句後
    聚成 ~200 字上限的句群（貼近 live committed 的段長）。
- **MIRROR**: `TranscriptChunker.makeUnits`（講者輪次優先的先例，TranscriptChunker.swift:61-71）。
- **VALIDATE**: RUN `MeetingReplayReviewTests` — expect **PASS**；
  RUN `MeetingLiveModelsTests`（migration 不回歸）
- **COMMIT**: `feat(meeting-copilot): replay 分段純函式 + session 來源欄位（M8 Task 12）`

### Task 13: MeetingReplayReviewService（AC-38、AC-42）

- **ACTION**: 同檔加 `@MainActor final class MeetingReplayReviewService`：
  Transcription → replay session（抽取＋tier1），progress/cancel，失敗清理。
- **TEST FIRST**（追加）:
  ```swift
  @MainActor
  func testReplayBuildsSessionWithCuesAndTier1() async throws {
      let ctx = makeInMemoryMeetingContext()
      let fakeChat = ScriptedChat(replies: [   // 依呼叫序回覆：每段抽取一次
          #"{"cues":[{"text":"自我介紹一下","kind":"aboutMe","searchHint":"自介"}]}"#,
          #"{"cues":[]}"#])
      let svc = MeetingReplayReviewService(extractorChat: fakeChat,
          coordinator: makeCoordinator(fastReply: "OPENER: 嗨\n- a\n- b\n- c"), modelContext: ctx)
      let t = Transcription(text: "自我介紹一下。好的謝謝。", ...)
      t.importFingerprint = "fp-1"
      let session = try await svc.generateReview(for: t)
      XCTAssertEqual(session.sourceRaw, "replay")
      XCTAssertEqual(session.importFingerprint, "fp-1")
      XCTAssertEqual((session.segments ?? []).count, 2)
      let cues = session.cues ?? []
      XCTAssertEqual(cues.count, 1)
      XCTAssertFalse(cues[0].tier1Opener.isEmpty, "非 informational cue 有 Tier 1")
      // 重跑 → 並存
      let again = try await svc.generateReview(for: t)
      XCTAssertNotEqual(again.id, session.id)
  }
  ```
  RUN `MeetingReplayReviewTests` — expect **FAIL**
- **IMPLEMENT**:
  - `generateReview(for:)`：建 session（`sourceRaw:"replay"`、`appName:"覆盤"`、
    `importFingerprint = t.importFingerprint ?? ""`、`configSnapshotRaw` = 當下
    `MeetingCopilotRunConfig` JSON——重用 live 端的快照組裝函式）→ 逐段
    （`ReplaySegmentation.segments`，`speakerSegmentsAreNative ? t.speakerSegments : []`）：
    `recordSegment` 等價寫入（channel `.remote`）→ `ResponseCueExtractor.extract`（**序列**，
    避免 rate limit）→ `MeetingCueDeduplicator` 去重 → persist cue（含 searchHint）→
    非 informational cue **序列** `await coordinator.runTier1ForReplay(cue)`
    （coordinator 加一個公開包裝，等 tier1 完成、**不觸發 auto-deep**——replay 不進 deep）。
  - `@Published var progress: (done: Int, total: Int)?` 供 UI；`Task.isCancelled` 每段檢查；
    失敗/取消 → `modelContext.delete(session)` 後 rethrow（不留半套）。
  - 抽取用的 chat completer 由呼叫端注入（正式 = `MeetingCopilotController.makeFastCompleter`）。
- **MIRROR**: TIER_RUN；`MeetingCopilotController.ingest` 的去重＋persist 迴圈（141-176）；
  `MeetingReplayDebugRunner` 的接線（DEBUG replay 先例）。
- **GOTCHA**: coordinator 的 `prefetchTask` 語意是「只保最新」——replay 不能走 `onNewCue`
  （會互相取消），要用直呼 tier1 的包裝。
- **VALIDATE**: RUN `MeetingReplayReviewTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): 離線覆盤 replay 管線（M8 Task 13）`

### Task 14: 漏抓掃描 MeetingReviewSweep（AC-40）

- **ACTION**: 新 `MeetingReviewSweep.swift`：通用 prompt、parse、jaccard 匹配、persist。
- **TEST FIRST**（追加）:
  ```swift
  func testSweepKeepsOnlyUnmatched() {
      let existing = ["你對X專案有什麼貢獻", "怎麼設計快取", "自我介紹一下"]
      let sweepItems = [
          SweepItem(text: "你對 X 專案有什麼貢獻？", suggestedKind: "aboutMe"),   // 與 [0] Jaccard ≥0.6
          SweepItem(text: "請自我介紹", suggestedKind: "aboutMe"),               // 與 [2] 匹配
          SweepItem(text: "預期的上線時程是什麼時候", suggestedKind: "directQuestion"),  // 漏抓
          SweepItem(text: "快取要怎麼設計", suggestedKind: "directQuestion"),     // 與 [1] 匹配
          SweepItem(text: "團隊規模多大", suggestedKind: "informational")]        // 漏抓
      let missed = MeetingReviewSweep.unmatched(sweep: sweepItems, existingCueTexts: existing)
      XCTAssertEqual(missed.map(\.text), ["預期的上線時程是什麼時候", "團隊規模多大"])
  }
  func testSweepPromptIsGenericNoTopicFilter() {
      let p = MeetingReviewSweep.systemPrompt
      XCTAssertTrue(p.contains("所有"))
      XCTAssertFalse(p.contains("技術"), "sweep 不帶主題過濾——這正是它與正式抽取的差異")
  }
  ```
  RUN `MeetingReplayReviewTests` — expect **FAIL**
- **IMPLEMENT**:
  - `struct SweepItem: Codable, Equatable { let text: String; let suggestedKind: String;
    var matched: Bool = false }`（放 `MeetingCopilotDiagnostics.swift` 或本檔，Codable 供
    `reviewSweepRaw` JSON）。
  - `systemPrompt`：「列出逐字稿中**所有**可能需要聽者回應的問題／點名／質疑——不做任何主題
    過濾，寧可多列。輸出 JSON {"items":[{"text":"…","suggestedKind":"directQuestion|impliedChallenge|assignedToMe|aboutMe|informational"}]}」。
  - `unmatched(sweep:existingCueTexts:)`：對每個 sweep item，任一 existing 的
    `MeetingCueDeduplicator.jaccard ≥ 0.6` → matched；回傳未匹配清單（純函式）。
  - `run(session:chat:)`：全逐字稿（segments 的 remote 原文串接，或 replay 的全文）→ 一次
    chat 呼叫 → parse（容錯回 []）→ unmatched → `session.reviewSweepRaw = JSON` → save。
  - 接入：Task 13 的 `generateReview` 尾端自動跑；live session 的補跑按鈕屬 Task 15。
- **MIRROR**: EXTRACTOR_JSON_CONTRACT（envelope+容錯）；JACCARD_MATCH。
- **VALIDATE**: RUN `MeetingReplayReviewTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): 漏抓掃描 miss sweep（M8 Task 14）`

### Task 15: 覆盤三層排序＋錄音管理入口＋badge（AC-41）

- **ACTION**: 排序純函式＋`MeetingSessionDetailSheet` 分區＋`RecorderHistoryView` 詳情按鈕＋
  覆盤列表 badge＋live session「執行漏抓掃描」按鈕。
- **TEST FIRST**（追加）:
  ```swift
  func testReviewOrderingThreeTiers() {
      let answered = makeCueStub(text: "有回應", tier1: "OPENER", askedAt: t0)
      let info = makeCueStub(text: "資訊", tier1: "", askedAt: t0.addingTimeInterval(-10))
      let failed = makeCueStub(text: "tier1失敗", tier1: "", askedAt: t0.addingTimeInterval(5))
      let groups = MeetingReviewOrdering.tiers(cues: [info, answered, failed])
      XCTAssertEqual(groups.responded.map(\.text), ["有回應"])
      XCTAssertEqual(groups.unresponded.map(\.text), ["資訊", "tier1失敗"], "層內依 askedAt")
  }
  ```
  RUN `MeetingReplayReviewTests` — expect **FAIL**
- **IMPLEMENT**:
  - `enum MeetingReviewOrdering`（放 MeetingCopilotPageView.swift 或 Diagnostics）：
    `tiers(cues:)` → `(responded: [C], unresponded: [C])`，responded 判準
    `!tier1Opener.isEmpty || !tier2Analysis.isEmpty`，各層 `askedAt` 升冪（generic over
    protocol 或 closure，沿 ARRANGER 的測試法）。
  - `MeetingSessionDetailSheet`：cue 區改三個 Section 標題「✅ 有回應的問題」「◽️ 未回應／資訊」
    「⚠️ 漏抓掃描（未被即時辨識）」；第三區從 `session.reviewSweepRaw` decode `[SweepItem]`
    渲染（text＋suggestedKind badge）；live session 且 `reviewSweepRaw.isEmpty` → 顯示
    「執行漏抓掃描」按鈕（呼叫 `MeetingReviewSweep.run`，跑動中 ProgressView）。
  - 覆盤列表列（MeetingCopilotPageView 的 session row）：`sourceRaw == "replay"` 顯示
    「離線覆盤」Capsule badge（照 `MeetingCueKind.displayLabelZH` 的小標慣例）。
  - `RecorderHistoryView` 詳情：既有「會議copilot覆盤」按鈕邏輯（依 importFingerprint 查
    session）旁——查無 session 顯示「產生會議copilot覆盤」；有 replay session 加「重新產生」。
    按下 → `MeetingReplayReviewService.generateReview`（fast completer 用
    `MeetingCopilotController.makeFastCompleter(aiService:config:)`）；進度以
    sheet/ProgressView 呈現，完成後直接開覆盤詳情。
- **MIRROR**: MeetingCopilotPageView:223-233（sheet 結構）；RecorderHistoryView 詳情列。
- **VALIDATE**: RUN `MeetingReplayReviewTests` — expect **PASS**（排序）；UI 手動驗證屬 Task 20
- **COMMIT**: `feat(meeting-copilot): 覆盤三層排序 + 錄音管理覆盤入口（M8 Task 15）`

## D 組 — 即時翻譯（Task 16–19）

### Task 16: segment 翻譯欄位＋翻譯 prompt 純函式（AC-45）

- **ACTION**: `MeetingLiveSegment` 加三欄位；新 `MeetingTranslationPrompt.swift`。
- **TEST FIRST**（`VoiceInkTests/MeetingTranslationTests.swift` 新檔）:
  ```swift
  import XCTest
  @testable import VoiceInk

  final class MeetingTranslationTests: XCTestCase {
      func testPromptAutoDetectAndSameLanguagePassthrough() {
          let (system, user) = MeetingTranslationPrompt.build(
              text: "Let's discuss the cache design.", sourceLanguage: "auto", targetLanguage: "zh-TW")
          XCTAssertTrue(system.contains("無論輸入"))
          XCTAssertTrue(system.contains("繁體中文"))
          XCTAssertTrue(system.contains("原樣輸出"))     // 已是目標語言 → 不要硬翻
          XCTAssertTrue(system.contains("只輸出"))       // 不要解釋、不要引號
          XCTAssertTrue(user.contains("cache design"))
      }
      func testPromptCarriesExplicitSourceHint() {
          let (system, _) = MeetingTranslationPrompt.build(text: "x", sourceLanguage: "en", targetLanguage: "zh-TW")
          XCTAssertTrue(system.contains("en"))
      }
      func testTargetLanguageDisplayName() {
          XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "zh-TW"), "繁體中文")
      }
  }
  ```
  RUN `MeetingTranslationTests` — expect **FAIL**
- **IMPLEMENT**:
  - Models：segment 三欄位（見 SRS 表）。
  - `enum MeetingTranslationPrompt`：`build(text:sourceLanguage:targetLanguage:) -> (system: String, user: String)`
    純函式。system 核心：「你是會議即時字幕翻譯。**無論輸入是什麼語言**（可能中英夾雜），
    譯成\(displayName)。輸入若已是\(displayName)則原樣輸出（僅修正明顯 ASR 錯字）。
    只輸出譯文本身——不要解釋、不要引號、不要標註語言」；`sourceLanguage != "auto"` 時
    加一行「輸入主要為 \(sourceLanguage)」。`displayName(for:)`：`"zh-TW"→"繁體中文"`、
    `"en"→"English"`、`"ja"→"日本語"`，未知碼原樣返回。
- **MIRROR**: `ResponseCueExtractor.buildPrompt`（純函式、同輸入同輸出）。
- **VALIDATE**: RUN `MeetingTranslationTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): 翻譯 prompt 純函式 + segment 欄位（M8 Task 16）`

### Task 17: MeetingLiveTranslator consumer（AC-43/44/47）

- **ACTION**: 新 `MeetingLiveTranslator.swift`：per-segment 翻譯 Task、有序 feed、persist、
  靜默容錯、關閉時零呼叫。
- **TEST FIRST**（追加）:
  ```swift
  @MainActor
  func testTranslationWritesBackInCommittedOrder() async {
      let ctx = makeInMemoryMeetingContext()
      let chat = ScriptedChat(delays: [0.2, 0.0], replies: ["譯一", "譯二"])   // 第二段先完成
      let translator = MeetingLiveTranslator(chat: chat, config: enabledConfig, modelContext: ctx)
      let s1 = makeSegment(ctx, text: "one", committedAt: t0)
      let s2 = makeSegment(ctx, text: "two", committedAt: t0.addingTimeInterval(1))
      translator.translate(segment: s1); translator.translate(segment: s2)
      await translator.drainForTest()
      XCTAssertEqual(s1.translatedText, "譯一"); XCTAssertEqual(s2.translatedText, "譯二")
      XCTAssertEqual(translator.feed.map(\.translated), ["譯一", "譯二"], "按 committedAt，不按完成序")
  }
  @MainActor
  func testTranslationFailureShowsOriginalSilently() async {
      let chat = ScriptedChat(throwOnCall: 1)
      ...
      XCTAssertEqual(translator.feed.first?.translated, "原文", "失敗顯示原文")
      XCTAssertFalse(seg.translationError.isEmpty)
  }
  @MainActor
  func testDisabledMakesZeroCalls() async {
      let chat = ScriptedChat(replies: ["x"])
      let translator = MeetingLiveTranslator(chat: chat, config: disabledConfig, modelContext: ctx)
      translator.translate(segment: makeSegment(ctx, text: "t", committedAt: t0))
      await translator.drainForTest()
      XCTAssertEqual(chat.callCount, 0)
  }
  ```
  RUN `MeetingTranslationTests` — expect **FAIL**
- **IMPLEMENT**:
  ```swift
  /// remote committed 的第二個獨立 consumer（與 cue 抽取平行、互不阻塞）。
  /// 失敗靜默：feed 顯示原文、error 進 segment（🌐 log）。
  @MainActor
  final class MeetingLiveTranslator: ObservableObject {
      struct FeedLine: Identifiable, Equatable {
          let id: UUID            // = segment.id
          let committedAt: Date
          let original: String
          var translated: String
      }
      @Published private(set) var feed: [FeedLine] = []   // 恆按 committedAt 排序，截尾保留最近 20
      private let chat: ChatCompleting
      private let config: MeetingCopilotConfigStore
      private var inflight: [Task<Void, Never>] = []

      func translate(segment: MeetingLiveSegment) {
          guard config.liveTranslationEnabled else { return }
          let (system, user) = MeetingTranslationPrompt.build(text: segment.text,
              sourceLanguage: config.translationSourceLanguage,
              targetLanguage: config.translationTargetLanguage)
          let start = Date()
          inflight.append(Task { [weak self] in
              var line = FeedLine(id: segment.id, committedAt: segment.committedAt,
                                  original: segment.text, translated: segment.text)
              do {
                  let reply = try await self?.chat.complete(system: system, user: user) ?? ""
                  line.translated = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                  segment.translatedText = line.translated
              } catch {
                  segment.translationError = error.localizedDescription   // feed 留原文
              }
              segment.translationElapsedMs = Int(Date().timeIntervalSince(start) * 1000)
              try? segment.modelContext?.save()
              self?.insertSorted(line)
          })
      }
      private func insertSorted(_ line: FeedLine) {
          feed.removeAll { $0.id == line.id }
          feed.append(line)
          feed.sort { $0.committedAt < $1.committedAt }
          if feed.count > 20 { feed.removeFirst(feed.count - 20) }
      }
  }
  ```
  （`drainForTest` 照 `MeetingCopilotController.drainInflight` 寫。）
  接線：`MeetingCopilotLiveController` 建 translator（chat 用 fast completer 或
  translation model 解析——`MeetingCopilotModels.resolve(storedProvider:
  config.translationProviderName, …)` 鏡射 fast/deep），`onRemoteCommitted` handler 內
  `recordSegment` 回傳的 segment 傳給 `translator.translate(segment:)`（在 cue 抽取 Task 之外，
  平行）。
- **MIRROR**: `MeetingFastChatCompleter`（adapter）；`drainInflight`（測試 hook）。
- **GOTCHA**: `recordSegment` 目前回傳 optional——nil（copilot 關閉）時不翻譯。
- **VALIDATE**: RUN `MeetingTranslationTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): MeetingLiveTranslator 即時翻譯管線（M8 Task 17）`

### Task 18: 翻譯設定欄位＋overlay 翻譯區（AC-47 佈局部分）

- **ACTION**: ConfigStore 加 D 組欄位；overlay 加翻譯字幕區。
- **TEST FIRST**（`MeetingCopilotConfigStoreTests` 追加）:
  ```swift
  func testTranslationSettingsRoundTrip() {
      let store = MeetingCopilotConfigStore()
      store.setLiveTranslationEnabled(true)
      store.setTranslationModel(provider: "groq", model: "llama-3.1-8b-instant")
      store.setTranslationLanguages(source: "auto", target: "zh-TW")
      let r = MeetingCopilotConfigStore()
      XCTAssertTrue(r.liveTranslationEnabled)
      XCTAssertEqual(r.translationProviderName, "groq")
      XCTAssertEqual(r.translationTargetLanguage, "zh-TW")
  }
  func testTranslationDefaults() {
      let store = MeetingCopilotConfigStore()
      XCTAssertFalse(store.liveTranslationEnabled)
      XCTAssertEqual(store.translationSourceLanguage, "auto")
      XCTAssertEqual(store.translationTargetLanguage, "zh-TW")
  }
  ```
  RUN `MeetingCopilotConfigStoreTests` — expect **FAIL**
- **IMPLEMENT**:
  - ConfigStore：`liveTranslationEnabled = false`、`translationProviderName: String?`、
    `translationModelName: String?`、`translationSourceLanguage = "auto"`、
    `translationTargetLanguage = "zh-TW"`（CONFIG_STORE_FIELD ×5；model setter 照
    `setFastModel(provider:model:)` 雙欄形式）。`MeetingCopilotRunConfig` 加同名欄位。
  - `CopilotOverlayView`：`@ObservedObject var translator: MeetingLiveTranslator`（由
    WindowManager 注入；nil 不可——關閉時 feed 恆空）。body 在 `shareWarningBanner` 之後：
    ```swift
    if config.liveTranslationEnabled {
        sectionHeader("即時翻譯")            // 小標＋Divider，與 cue 區同視覺語言
        ForEach(translator.feed.suffix(4)) { line in
            Text(line.translated).font(.system(size: 12)).lineLimit(2)
        }
        Divider().padding(.vertical, 2)
        sectionHeader("問題與回應")           // cue 區從此開始——區隔即 FR-62
    }
    ```
  - `CopilotOverlayWindowManager` 把 translator 傳進 view（與 controller 同路徑）。
- **MIRROR**: SETTINGS_BIND；CopilotOverlayView 既有 section 視覺（gripBar/banner 字級）。
- **VALIDATE**: RUN `MeetingCopilotConfigStoreTests` — expect **PASS**
- **COMMIT**: `feat(meeting-copilot): 翻譯設定 + overlay 字幕區（M8 Task 18）`

### Task 19: 設定頁 tab 化＋回應語言指示（AC-46）

- **ACTION**: `MeetingCopilotSettingsView` 改為 Picker-style tab（「一般」「即時翻譯」）；
  `TierPrompts` 全部 system prompt 附加輸出語言。
- **TEST FIRST**（`TierPromptsTests` 追加）:
  ```swift
  func testAllTierSystemPromptsCarryOutputLanguage() {
      for s in [TierPrompts.tier1System(persona: "p", outputLanguage: "繁體中文"),
                TierPrompts.tier2System(persona: "p", outputLanguage: "繁體中文"),
                TierPrompts.tier1SystemAboutMe(persona: "p", outputLanguage: "繁體中文"),
                TierPrompts.tier2SystemAboutMe(persona: "p", outputLanguage: "繁體中文")] {
          XCTAssertTrue(s.contains("以繁體中文回答"))
      }
  }
  ```
  RUN `TierPromptsTests` — expect **FAIL**
- **IMPLEMENT**:
  - `TierPrompts` 四個 system 函式加 `outputLanguage: String` 參數（呼叫端傳
    `MeetingTranslationPrompt.displayName(for: config.translationTargetLanguage)`），
    prompt 尾加「一律以\(outputLanguage)回答」。`AnswerCoordinator` 兩處呼叫同步改。
    **快照**：`MeetingCopilotRunConfig` 的三個 system prompt 全文欄位自然帶到新內容。
  - Settings tab：body 頂部加 `Picker("", selection: $tab)`（`.pickerStyle(.segmented)`，
    `enum SettingsTab { case general, translation }` @State）；`general` = 既有全部 Section
    原樣搬進 `Form`；`translation` = 新 Form：`liveTranslationEnabled` Toggle、翻譯模型
    picker（鏡射 fastBinding 的 `RecorderModelChoice?` 形式）、來源語言 Picker
    （auto/zh-TW/en/ja）、目標語言 Picker（zh-TW/en/ja）、**混語 ASR 提示**
    （`Text` footnote：「混語會議請在一般 tab 選支援多語的即時轉錄模型（Nemotron
    Multilingual／雲端）——Parakeet 的 auto 對中文會輸出亂碼」）。
- **MIRROR**: MeetingCopilotSettingsView 的 modelSection picker（118-136）與 bind helper。
- **GOTCHA**: 既有 Section 搬移是**純移動**——不改任何 binding 邏輯，diff 保持可審。
- **VALIDATE**: RUN `TierPromptsTests` — expect **PASS**；
  RUN `MeetingCopilotObservabilityTests`（快照含新 prompt 不回歸）
- **COMMIT**: `feat(meeting-copilot): 設定頁 tab 化 + 回應語言指示（M8 Task 19）`

## 收尾（Task 20）

### Task 20: 全套驗證＋手動驗證清單

- **ACTION**: 跑完整測試矩陣與 build，逐項人工驗證。
- **VALIDATE**（依序全綠）:
  ```bash
  # 1. 新增/修改的測試類全跑（TEST_COMMAND，-only-testing 逐一）:
  #    ObsidianNoteIndexTests, AskAIIndexTests, ResponseCueExtractorTests, GroundingTests,
  #    TierPromptsTests, AnswerCoordinatorTests, MeetingCopilotControllerTests,
  #    CopilotOverlayArrangerTests, MeetingReplayReviewTests, MeetingTranslationTests,
  #    MeetingCopilotConfigStoreTests, MeetingCopilotObservabilityTests
  # 2. 全 target 回歸:
  #    -only-testing:VoiceInkTests
  # 3. compile check（skill: voiceink-build-verify 的指令，build 進 ./.local-build）
  ```
  EXPECT: 全 PASS、BUILD SUCCEEDED、0 error
- **手動驗證**（使用者 `! make deploy` 後，照 memory 的 TTS 測試法）:
  - [ ] 設定頁「個人筆記 RAG」重建索引 → 顯示塊數；無 key 時顯示警告
  - [ ] TTS 唸「你對 VoiceInk 專案有什麼貢獻？」→ cue 標「個人」badge、opener/bullets 引用筆記內容
  - [ ] TTS 連問兩題 → 第一題展開閱讀中，第二題完成只亮 ●，不搶畫面；熱鍵 toggle 收合/展開
  - [ ] Tier 1 顯示後 ~15s 內自動出現深度分析（無需點擊）
  - [ ] 錄音管理選一筆舊錄音 → 產生覆盤 → 三層排序、漏抓區有內容
  - [ ] 開即時翻譯 + TTS 唸英文 → overlay 上區出現繁中譯文、下區 cue 照常
  - [ ] 關閉 copilot 總開關 → 以上全部無活動（回歸）
- **COMMIT**: `feat(meeting-copilot): M8 完成 — 筆記 RAG + auto-deep + 離線覆盤 + 即時翻譯`

---

## Testing Strategy

### Unit Tests（新增矩陣）

| Test | Input | Expected | AC |
|---|---|---|---|
| frontmatter 去除/標題前綴/確定性 UUID | golden md | 純函式輸出 | AC-28 |
| 增量索引 | 改一檔刪一檔 | 只重嵌變更、刪除塊消失 | AC-29 |
| reconcile 防護 | 混合孤兒 | obsidian 塊保留 | AC-30 |
| 五分類+searchHint golden | golden JSON | aboutMe 帶 hint | AC-31 |
| 檢索路由 | spy grounding | sources 按 kind | AC-32 |
| aboutMe prompts | grounding+brief | 鐵律/錨點字串 | AC-33 |
| auto-deep+保護 | fake streamer | trigger=auto、不取消展開中 | AC-34 |
| 自動展開/未讀 | 狀態序列 | 不搶展開 | AC-35 |
| 熱鍵 toggle | 狀態序列 | 收合/展開最新 | AC-36 |
| arranger pinned | 6 cue window 5 | 展開者保留 | AC-37 |
| replay 全管線 | scripted chat | session+cues+tier1 | AC-38/39/42 |
| sweep 匹配 | 5 題 3 匹配 | 留 2 漏抓 | AC-40 |
| 三層排序 | 混合 cue | responded→un | AC-41 |
| 翻譯順序/失敗/關閉 | scripted delays | committedAt 序/原文/零呼叫 | AC-43/44/47 |
| 翻譯 prompt/語言指示 | 純函式 | 指示字串 | AC-45/46 |

### Edge Cases Checklist
- [ ] vault 未設定／embedding 無 key（靜默降級，UI 有提示）
- [ ] 空筆記（去 frontmatter 後空 → 不嵌入、清舊塊）
- [ ] searchHint 空（退回 cue 原文）
- [ ] `prefetchEnabled=false` 時 auto-deep 不動作
- [ ] replay 中途取消（不留半套 session）
- [ ] 逐字稿無句終符的長文（句群 fallback 硬切不丟字）
- [ ] 翻譯輸入已是繁中（原樣輸出）
- [ ] 舊資料（無新欄位值）decode/顯示正常（lightweight migration）

## Validation Commands

```bash
# 型別/編譯（產 app 進 .local-build，勿建到 /tmp——見 voiceink-build-verify skill）
SWIFT_ENABLE_EXPLICIT_MODULES=NO xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug -derivedDataPath ./.local-build -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' build \
  > /tmp/m8-build.log 2>&1; grep -c "BUILD SUCCEEDED" /tmp/m8-build.log

# 單元測試（TEST_COMMAND pattern；逐類跑再跑全 target）
# 見 Task 20
```
EXPECT: BUILD SUCCEEDED；全測試 PASS；deploy 由使用者 `! make deploy`。

## Acceptance Criteria
- [ ] SRS AC-28 ~ AC-47 全數有對應測試且通過
- [ ] 全 target 測試零回歸
- [ ] compile check BUILD SUCCEEDED
- [ ] Task 20 手動驗證清單完成（真模型）

## Completion Checklist
- [ ] 新設定欄位全部進 `MeetingCopilotRunConfig` 快照
- [ ] 熱鍵四處註冊 grep 驗證
- [ ] 失敗路徑全靜默（無 modal/系統通知）
- [ ] 覆盤 provenance 欄位（searchHint/tier2Trigger/translation*）有寫入
- [ ] 文件：實作報告 `docs/reports/meeting-copilot-m8-report.md`（照 M1-M5 慣例）＋
      SPEC_ROADMAP 標 implemented ＋ plan 移 `docs/plans/completed/`

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| reconcile 防護漏掉其他清除路徑（switchModel/手動清索引）把筆記塊清掉 | M | M | AC-30 鎖 reconcile；switchModel 後設定頁顯示「筆記需重建」狀態（sidecar hash 對不上 chunk 數） |
| aboutMe 分類把技術問題吸走（過度分類） | M | M | prompt 判準寫死「需要回憶我的經歷才能答」；覆盤 sweep + provenance 可觀測，錯了改 prompt 即可（configSnapshot A/B） |
| auto-deep 在 cue 密集時成本上升 | L | M | latest-only + `autoDeepEnabled` 可關；`tier2TriggerRaw` 成本歸因 |
| 展開保護與 auto-expand 的狀態競態（deep 完成 vs 使用者同時展開） | M | L | 全部 @MainActor 序列化；狀態層單元測試鎖語意 |
| replay 對長錄音（>1hr）耗時/費用 | M | M | 序列＋進度＋可取消；只 fast model |
| 翻譯 feed 在 overlay 擠壓 cue 區 | M | L | feed 只顯示最近 4 句；Open Question 已記，實測後調 |
| SwiftData lightweight migration 失敗（新欄位） | L | H | 全欄位有預設值（repo 慣例）；meeting.store 可刪檔重來不傷主資料 |

## Notes
- 實作順序 = 任務編號；每組結束是穩定點，可獨立 deploy 驗收。
- deploy 一律由使用者執行 `! make deploy`（Release + "VoiceInk Local" 簽章）；agent 只做
  compile check（build 進 `./.local-build`）。
- 調校迴圈：真會議/TTS 測試後，用覆盤頁「匯出診斷 JSON」＋漏抓區檢視分類品質，改
  extractor prompt 後對同一錄音「重新產生」比較（configSnapshot 記錄版本）。



