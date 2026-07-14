---
linear_issue: null
---
# Plan: Meeting Copilot M9 — aboutMe 嚴格接地 + 覆盤生命週期 + 深答風格

> **For agentic workers:** `/prp-implement` will route this plan to the matching skill based on `Metadata.Type` below. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Checkbox states (SDD Dashboard compatible):** `- [ ]` todo · `- [~]` in-progress · `- [x]` done. Treat `[~]` exactly like `[ ]` when judging whether a task is finished — it is NOT done.

## Summary

三組：(A) aboutMe 嚴禁幻覺——接地零筆記片段時**不呼叫 LLM** 直接「筆記沒記載」、有片段 1~3 條錨點
不硬湊、aboutMe 不進 Tier 2；(B) 覆盤生命週期——session 標題 live lookup 錄音名、刪錄音 sweep 全刪
關聯 session、live/replay 不同時並存、`MeetingReplayQueue` 背景佇列＋雙頁「覆盤中」badge；
(C) 深答風格——條列式（預設）／簡潔／詳細三選一，只抽換 tier2System 格式指示段。

## User Story

As a 開會中被問到自己經歷、事後靠覆盤調校的使用者,
I want aboutMe 沒筆記就直說沒記載（絕不編）、覆盤與錄音同名同生命週期、覆盤在背景跑、深答一眼掃完,
So that 我能信任 copilot 給的每一個「事實」，且覆盤管理不再產生孤兒與假名。

## Problem → Solution

aboutMe 零接地照樣呼叫 LLM 自由發揮＝幻覺；覆盤列表日期命名認不出是哪場、刪錄音留孤兒、
覆盤卡在詳情 sheet 裡跑；深答大段文字對話中讀不完 → 空接地短路＋deep 守門；fingerprint
live-lookup 命名＋刪除 sweep＋背景佇列＋雙頁 badge；三檔風格抽換 prompt 格式段。

## Metadata
- **Module**: meeting-copilot
- **Parent Plan**: N/A
- **Source PRD**: N/A
- **Source Feature SRS**: docs/srs/meeting-copilot-m9-aboutme-replay-lifecycle.srs.md
- **Source Module Spec**: docs/spec/meeting-copilot.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature
- **Size**: L
- **Complexity**: Large
- **Rigor**: balanced
- **Mode**: B — 任務先測
- **TDD**: on（task-level test-first）
- **Commit cadence**: per-task
- **Estimated Files**: ~14（CREATE 3 / UPDATE ~11）

---

## UX Design

### Before

```
Overlay（aboutMe、無筆記索引）:        覆盤頁:                          錄音詳情:
┌────────────────────────┐          7月12日 14:30 會議               [產生會議copilot覆盤]
│ Q: 你做過什麼專案?      │          7月13日 10:00 會議  ← 哪場是哪場?   （live 已存在也照樣可補做）
│ 💬 我主導過XX系統重構…  │          （刪錄音 → 孤兒留著）              覆盤進度卡在 sheet 裡
│    ↑ 全是編的           │
│ [15s 後又來一段深度分析] │
└────────────────────────┘
```

### After

```
Overlay（aboutMe、無筆記索引）:        覆盤頁:                          錄音詳情:
┌────────────────────────┐          面試A練習 [離線覆盤][覆盤中]      有 live → [會議copilot覆盤]
│ Q: 你做過什麼專案?      │          週會-產品評審 (live)              無 live → [產生覆盤]（背景跑）
│ 筆記沒有記載這題         │          （錄音改名→這裡跟著變;             錄音列: [覆盤中] badge
│ • 自介: 後端工程師…     │            刪錄音→這裡跟著刪）             跑完 badge 消失
│ （不再有深度分析）        │
└────────────────────────┘
深答（技術題,條列式預設）: • **結論**: 支持方案B  • **風險**: 遷移鎖表  • **反問**: 資料量級?
```

### Interaction Changes

| Touchpoint | Before | After | Notes |
|---|---|---|---|
| aboutMe 零接地 | LLM 自由發揮 | 固定「筆記沒記載」＋自介條列；零 LLM 呼叫 | 結構性防幻覺 |
| aboutMe Tier 2 | auto-deep＋點擊都會跑 | 一律不跑（點擊仍展開 Tier 1） | 引擎層守門 |
| 覆盤列表標題 | 日期組字 | 錄音名（改名即時反映）；查不到退回日期 | fingerprint live lookup |
| 刪錄音 | 覆盤變孤兒 | live＋replay 全刪 | sweep on `.transcriptionDeleted` |
| 覆盤產生 | sheet 內同步跑 | 背景佇列＋雙頁「覆盤中」badge | 關 sheet 不中斷；完成不跳轉 |
| 深答格式 | 固定段落分析 | 條列式（預設）／簡潔／詳細 | 設定頁「一般」tab picker |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/meeting-copilot-m9-aboutme-replay-lifecycle.srs.md` | all | 需求與 AC 來源 |
| P0 | `VoiceInk/Services/MeetingCopilot/AnswerCoordinator.swift` | all | runTier1/runAutoDeep/requestDeep——守門插入點 |
| P0 | `VoiceInk/Services/MeetingCopilot/TierPrompts.swift` | all | tier1/2 aboutMe 變體與 tier2System 格式段 |
| P0 | `VoiceInk/Services/MeetingCopilot/MeetingReplayReviewService.swift` | all | generateReview 契約（失敗刪整場、progress、makeSession） |
| P0 | `VoiceInk/Views/History/RecorderHistoryView.swift` | 935-1088 | 覆盤按鈕/generateReview 現況（要改接佇列）＋badge helper（:639） |
| P1 | `VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift` | 1-70, 160-300 | MeetingRowDisplay＋列/詳情標題呼叫點（:197/:261）＋badge 位置 |
| P1 | `VoiceInk/Models/MeetingLiveModels.swift` | 37-90 | MeetingLiveSession 欄位（importFingerprint/sourceRaw） |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | 17-52, 96-131, 243-346 | 鍵常數/@Published/setter 樣板（deepStyle 照做） |
| P1 | `VoiceInk/Services/AskAI/TranscriptIndexService.swift` | 47-63, 113-129 | configure+observer＋reconcile sweep 樣板 |
| P1 | `VoiceInk/VoiceInk.swift` | 138-160 | bootstrap configure 呼叫點（reconciler/queue 接這裡） |
| P1 | `VoiceInkTests/AnswerCoordinatorTests.swift` | all | NoopGrounding/SpyGrounding/GatedStreaming fixture |
| P2 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotLiveController.swift` | 226-260 | makeStreamingCompleter/makeFastCompleter（佇列工廠沿用） |
| P2 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotDiagnostics.swift` | all | MeetingCopilotRunConfig（deepStyle 進快照、optional 慣例） |
| P2 | `VoiceInkTests/TierPromptsTests.swift` | all | prompt 文字鎖測試樣板 |

## External Documentation

無 — 全部內部樣式。

---

## Patterns to Mirror

### TEST_COMMAND（一字不差；只換 -only-testing 目標）
```bash
# SOURCE: docs/plans/meeting-copilot-m8-notes-rag-auto-deep.plan.md:253-263
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  -only-testing:VoiceInkTests/<TestClass>
```

### COORDINATOR_FIXTURE（fake 接地＋計數串流）
```swift
// SOURCE: VoiceInkTests/AnswerCoordinatorTests.swift:5-25
private struct NoopGrounding: MeetingGroundingProviding {
    func gather(query: String, brief: String, includeRAG: Bool, includeScreen: Bool,
                sources: Set<String>?) async -> MeetingGrounding { .empty }
}
// 計數串流 fake：同檔既有 FakeStreamingChatCompleting（NSLock + @unchecked Sendable），callCount 可斷言。
```

### RECONCILE_SWEEP（nil 批次訊號 → 全量比對）
```swift
// SOURCE: VoiceInk/Services/AskAI/TranscriptIndexService.swift:116-129
func reconcileOrphans() {
    guard let ctx = modelContext else { return }
    let allChunks = (try? ctx.fetch(FetchDescriptor<EmbeddingChunk>())) ?? []
    let candidates = allChunks.filter { $0.sourceKind != ObsidianNoteIndexService.sourceKind }
    let indexedIds = Set(candidates.map(\.transcriptionId))
    guard !indexedIds.isEmpty else { return }
    let liveIds = Set((try? ctx.fetch(FetchDescriptor<Transcription>()))?.map(\.id) ?? [])
    let orphanIds = indexedIds.subtracting(liveIds)
    ...
}
```

### OBSERVER_CONFIGURE（bootstrap 注入＋通知觀察）
```swift
// SOURCE: VoiceInk/Services/AskAI/TranscriptIndexService.swift:47-63 ＋ VoiceInk/VoiceInk.swift:143
func configure(modelContext: ModelContext) {
    self.modelContext = modelContext
    observers = [ NotificationCenter.default.addObserver(forName: .transcriptionDeleted, object: nil, queue: .main) { _ in
        Task { @MainActor in TranscriptIndexService.shared.reconcileOrphans() } } ]
}
// VoiceInk.swift:143: TranscriptIndexService.shared.configure(modelContext: resolvedContainer.mainContext)
```

### CONFIG_SETTER（deepStyle 照這個形狀）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift:319-322
func setUseNotesRAG(_ value: Bool) {
    useNotesRAG = value
    UserDefaults.standard.set(value, forKey: useNotesRAGKey)
}
```

### ROW_BADGE（錄音列 badge helper）
```swift
// SOURCE: VoiceInk/Views/History/RecorderHistoryView.swift:444, 639
if transcription.exportedFilePath != nil { badge("已輸出", "checkmark.circle.fill", AppTheme.Status.success) }
```

### SESSION_ROW_BADGE（覆盤列的 capsule badge）
```swift
// SOURCE: VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift:201-206
if session.sourceRaw == "replay" {
    Text("離線覆盤").font(.system(size: 9, weight: .bold))
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(Color.purple.opacity(0.15)))
        .foregroundStyle(.purple)
}
```

### SHORT_CIRCUIT_PERSIST（tier1 欄位寫回的既有形狀）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/AnswerCoordinator.swift:168-176
cue.tier1Opener = draft.opener
cue.tier1Bullets = draft.bullets.filter { !$0.isEmpty }
cue.tier1ElapsedMs = Int(Date().timeIntervalSince(started) * 1000)
cue.tier1At = Date()
cue.tier1Error = ""
try? cue.modelContext?.save()
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/MeetingCopilot/MeetingReplayQueue.swift` | CREATE | 覆盤背景佇列 |
| `VoiceInk/Services/MeetingCopilot/MeetingSessionReconciler.swift` | CREATE | 刪除傳播 sweep |
| `VoiceInkTests/MeetingReplayQueueTests.swift` | CREATE | 佇列＋reconciler＋三態測試 |
| `VoiceInk/Services/MeetingCopilot/AnswerCoordinator.swift` | UPDATE | 空接地短路＋deep 雙守門 |
| `VoiceInk/Services/MeetingCopilot/TierPrompts.swift` | UPDATE | tier1 aboutMe 放寬/紅線；tier2 aboutMe 移除；tier2System 風格抽換 |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | UPDATE | deepStyle 設定 |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotDiagnostics.swift` | UPDATE | RunConfig 加 deepStyle（optional） |
| `VoiceInk/Services/MeetingCopilot/MeetingReplayReviewService.swift` | UPDATE | @Published currentSessionId（badge 用） |
| `VoiceInk/Views/MeetingCopilot/MeetingCopilotPageView.swift` | UPDATE | 標題連動＋覆盤中 badge |
| `VoiceInk/Views/MeetingCopilot/MeetingCopilotSettingsView.swift` | UPDATE | 深答風格 picker |
| `VoiceInk/Views/History/RecorderHistoryView.swift` | UPDATE | 按鈕三態＋enqueue 改接＋列 badge |
| `VoiceInk/VoiceInk.swift` | UPDATE | reconciler/queue bootstrap configure |
| `VoiceInkTests/AnswerCoordinatorTests.swift` | UPDATE | AC-48/49/51 |
| `VoiceInkTests/TierPromptsTests.swift` | UPDATE | AC-50/58＋tier2 aboutMe 測試移除 |
| `VoiceInkTests/MeetingCopilotConfigStoreTests.swift` | UPDATE | deepStyle round-trip |

## NOT Building

- 覆盤佇列取消 UI（Open Question）
- aboutMe 有接地時的答案品質調校（只管格式與紅線）
- live session 與錄音的關聯建立機制改動（importFingerprint 回填照舊）
- 舊資料清理／fingerprint 為空的 session 一律不動
- Ask AI 的筆記 scope（另一份 plan：`ask-ai-obsidian-notes-rag.plan.md`）

---

## Step-by-Step Tasks

### Task 1: aboutMe 空接地短路（FR-65 / AC-48, AC-49）

- **ACTION**: `AnswerCoordinator.runTier1` 在 gather 之後、prompt 組裝之前插入 aboutMe 守門。
- **TEST FIRST**（`AnswerCoordinatorTests.swift` 追加；fixture 沿用同檔 NoopGrounding＋計數 fake）:
  ```swift
  /// 🔴 AC-48：aboutMe 零接地 → 不呼叫 fast model，固定回應。結構性防幻覺的回歸鎖。
  func testAboutMeZeroGroundingShortCircuitsWithoutLLM() async throws {
      let fast = FakeStreamingChatCompleting(reply: "不該被呼叫")
      let coordinator = AnswerCoordinator(fast: fast, deep: FakeStreamingChatCompleting(reply: ""),
                                          grounding: NoopGrounding(), config: .shared)
      let cue = makeCue(kind: .aboutMe, text: "你做過什麼專案？")   // 同檔既有 helper
      await coordinator.onNewCue(cue)
      await coordinator.drainPrefetchForTest()
      XCTAssertEqual(fast.callCount, 0, "零接地不得呼叫 LLM")
      XCTAssertTrue(cue.tier1Opener.contains("筆記沒有記載"), cue.tier1Opener)
      XCTAssertTrue(cue.tier1GroundingNote.contains("短路"), "觀測要記下短路原因")
  }
  /// AC-49：自介非空 → 成為唯一條列（仍零 LLM）。
  func testAboutMeZeroGroundingUsesBriefAsOnlyBullet() async throws {
      let original = MeetingCopilotConfigStore.shared.aboutMeBrief
      MeetingCopilotConfigStore.shared.setAboutMeBrief("後端工程師，主力訂單系統重構")
      addTeardownBlock { @MainActor in MeetingCopilotConfigStore.shared.setAboutMeBrief(original) }
      let fast = FakeStreamingChatCompleting(reply: "不該被呼叫")
      let coordinator = AnswerCoordinator(fast: fast, deep: FakeStreamingChatCompleting(reply: ""),
                                          grounding: NoopGrounding(), config: .shared)
      let cue = makeCue(kind: .aboutMe, text: "介紹一下你自己")
      await coordinator.onNewCue(cue)
      await coordinator.drainPrefetchForTest()
      XCTAssertEqual(fast.callCount, 0)
      XCTAssertEqual(cue.tier1Bullets, ["後端工程師，主力訂單系統重構"])
  }
  ```
  Run: TEST_COMMAND `-only-testing:VoiceInkTests/AnswerCoordinatorTests` — expect FAIL
- **IMPLEMENT**（`AnswerCoordinator.runTier1`，緊接 `let g = await grounding.gather(…)` 之後）:
  ```swift
  // M9 FR-65：aboutMe 零接地守門——沒有筆記片段就沒有事實可依，呼叫模型只會拿到編的。
  // 不呼叫 LLM 是唯一的結構性保證（prompt 只能降機率）。ragError（RAG 降級）與檢索零命中
  // 在這裡是同一件事。replay 路徑共用本函式，同樣受保護。
  if cue.kind == .aboutMe, g.ragExcerpts.isEmpty {
      cue.tier1Opener = "筆記沒有記載這題——照實說，或把話題帶回你記得的部分。"
      cue.tier1Bullets = config.aboutMeBrief.isEmpty ? [] : [config.aboutMeBrief]
      cue.tier1GroundingNote = "aboutMe 零接地短路（未呼叫 LLM）"
          + (g.ragError.map { "；RAG 降級:\($0)" } ?? "")
      cue.tier1ElapsedMs = Int(Date().timeIntervalSince(started) * 1000)
      cue.tier1At = Date()
      cue.tier1Error = ""
      // fastModelName 不寫：沒打模型就不冒名（覆盤的成本歸因要誠實）。
      try? cue.modelContext?.save()
      return   // 不進 LLM、不進 auto-deep（Task 2 另有 kind 守門，此處 return 先天不會走到）。
  }
  ```
- **MIRROR**: SHORT_CIRCUIT_PERSIST。
- **GOTCHA**: `drafts[cue.id]` **不塞**——短路沒有 Tier 1 草稿，aboutMe 也不進 deep（Task 2）；塞了反而讓 requestDeep 的「無草稿 → 中止」防線失效。
- **VALIDATE**: 兩測試 PASS；同檔既有測試零回歸。
- **COMMIT**: `fix(meeting-copilot): aboutMe 零接地不呼叫 LLM——結構性防幻覺（M9 FR-65）`

### Task 2: aboutMe 不進 Tier 2（FR-67 / AC-51）

- **ACTION**: `runAutoDeep`/`requestDeep` 加 kind 守門；移除 tier2 aboutMe prompt 變體與 `runTier2` 的分支。
- **TEST FIRST**（`AnswerCoordinatorTests.swift` 追加）:
  ```swift
  /// AC-51：aboutMe 一律不進 deep（auto 與手動）；技術 cue 不受影響。
  func testAboutMeNeverEntersDeep() async throws {
      let deep = FakeStreamingChatCompleting(reply: #"{"analysis":"x","followUps":[],"uncertainties":[]}"#)
      let grounding = GroundingWithOneExcerpt()   // 新 fake：回一片筆記片段（讓 tier1 走 LLM 路徑）
      let coordinator = AnswerCoordinator(fast: FakeStreamingChatCompleting(reply: "OPENER: ok"),
                                          deep: deep, grounding: grounding, config: .shared)
      let cue = makeCue(kind: .aboutMe, text: "你的專案？")
      await coordinator.onNewCue(cue)          // autoDeepEnabled 預設 true
      await coordinator.awaitQuiescentForTest()
      XCTAssertEqual(deep.callCount, 0, "auto-deep 必須跳過 aboutMe")
      await coordinator.requestDeep(cue)
      XCTAssertEqual(deep.callCount, 0, "手動 requestDeep 對 aboutMe 也是 no-op")
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**（`AnswerCoordinator.swift`）:
  1. `runAutoDeep` 開頭:
     ```swift
     // M9 FR-67：aboutMe 不進 deep——記憶錨點看一眼就夠，深度分析對「回憶自己的經歷」沒有增量，
     // 只是多一段對話中讀不完的文字＋一次 deep token。
     guard cue.kind != .aboutMe else { return }
     ```
  2. `requestDeep` 開頭:
     ```swift
     guard cue.kind != .aboutMe else {
         logger.notice("🫆 tier2 skipped: aboutMe 不進 deep（M9 FR-67）")
         return
     }
     ```
  3. `runTier2` 的兩處 `cue.kind == .aboutMe ?` 三元分支簡化為直接用 `TierPrompts.tier2System`／`tier2User`（守門後 aboutMe 不可達）。
  4. `TierPrompts.swift`: 刪 `tier2SystemAboutMe`／`tier2UserAboutMe`（含 MARK 區塊）；`TierPromptsTests` 對應測試刪除（同 commit）。
- **VALIDATE**: `-only-testing:VoiceInkTests/AnswerCoordinatorTests`＋`TierPromptsTests` PASS；grep `tier2SystemAboutMe|tier2UserAboutMe` 零殘留。
- **COMMIT**: `feat(meeting-copilot): aboutMe 不進 Tier 2——auto/manual 雙守門（M9 FR-67）`

### Task 3: tier1 aboutMe 格式放寬＋紅線（FR-66 / AC-50）

- **ACTION**: `tier1SystemAboutMe` 的「恰 3 bullets」改「1~3 條、不足不硬湊」＋事實紅線強化。
- **TEST FIRST**（`TierPromptsTests.swift` 追加）:
  ```swift
  /// AC-50：格式放寬（硬湊正是幻覺來源）＋紅線字句鎖。
  func testTier1AboutMeAllowsOneToThreeBulletsAndForbidsFabrication() {
      let system = TierPrompts.tier1SystemAboutMe(persona: "p", outputLanguage: "繁體中文")
      XCTAssertTrue(system.contains("1~3"), "1~3 條、有幾條列幾條")
      XCTAssertTrue(system.contains("不硬湊") || system.contains("不要硬湊"), system)
      XCTAssertTrue(system.contains("一個字都不能出現") || system.contains("不得出現"), "紅線字句")
      XCTAssertFalse(system.contains("恰好 3") || system.contains("恰 3"), "舊的硬性格式必須移除")
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**（`TierPrompts.tier1SystemAboutMe`）: 讀現行全文後只改兩處——
  1. bullets 格式句改為：「條列 **1~3 條**記憶錨點（專案名／你的角色／具體貢獻／量化成果）——**筆記片段撐得起幾條就列幾條，不足不硬湊**；硬湊出來的錨點是假記憶，比沒有更糟。」
  2. 事實紅線句強化為：「筆記片段與自介**沒提到的內容，一個字都不能出現在回答裡**；片段不足以回答時直說『筆記沒有記載』。」
  OPENER＋bullets 的輸出結構標記不動（`TierParsers.parseTier1` 零改動）。
- **VALIDATE**: `-only-testing:VoiceInkTests/TierPromptsTests` PASS。
- **COMMIT**: `feat(meeting-copilot): aboutMe 錨點 1~3 條不硬湊＋事實紅線強化（M9 FR-66）`

### Task 4: deepStyle 設定（FR-73 config / AC-58 持久化）

- **ACTION**: `MeetingDeepStyle` enum＋config store 欄位＋RunConfig 快照＋設定頁 picker。
- **TEST FIRST**（`MeetingCopilotConfigStoreTests.swift` 追加）:
  ```swift
  func testDeepStyleDefaultsToBulletsAndRoundTrips() {
      UserDefaults.standard.removeObject(forKey: "meetingCopilotDeepStyleV1")
      XCTAssertEqual(MeetingCopilotConfigStore().deepStyle, .bullets, "預設條列式＝本需求的目的")
      let store = MeetingCopilotConfigStore()
      store.setDeepStyle(.detailed)
      XCTAssertEqual(MeetingCopilotConfigStore().deepStyle, .detailed, "round-trip")
      UserDefaults.standard.removeObject(forKey: "meetingCopilotDeepStyleV1")
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**:
  1. `MeetingCopilotConfigStore.swift`:
     ```swift
     /// M9 FR-73：深答輸出密度。條列式為預設——現行段落分析在對話中讀不完（刻意的行為變更）。
     enum MeetingDeepStyle: String, CaseIterable {
         case bullets, concise, detailed
         var label: String {
             switch self {
             case .bullets: return "條列式（3 秒掃視）"
             case .concise: return "簡潔（2~3 句結論）"
             case .detailed: return "詳細（完整分析）"
             }
         }
     }
     ```
     ＋鍵常數 `meetingCopilotDeepStyleV1`、`@Published private(set) var deepStyle: MeetingDeepStyle = .bullets`、
     `load()` 段（`if let raw = d.string(forKey:), let v = MeetingDeepStyle(rawValue: raw)`）、CONFIG_SETTER 形狀的 `setDeepStyle`。
  2. `MeetingCopilotDiagnostics.swift`: `MeetingCopilotRunConfig` 加 `var deepStyle: String?`（**optional——M8 教訓：非 optional 新欄位會讓舊快照整份 decode 失敗**）；`capture(…)` 填 `config.deepStyle.rawValue`。
  3. `MeetingCopilotSettingsView.swift` `modelSection`（「回應模型」Section）加:
     ```swift
     Picker("深度分析風格", selection: bind(\.deepStyle, store.setDeepStyle)) {
         ForEach(MeetingDeepStyle.allCases, id: \.self) { Text($0.label).tag($0) }
     }
     ```
- **MIRROR**: CONFIG_SETTER；RunConfig optional 慣例（`MeetingCopilotDiagnostics.swift:42` 註解）。
- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingCopilotConfigStoreTests` PASS。
- **COMMIT**: `feat(meeting-copilot): 深答風格設定（條列式預設）＋進 RunConfig 快照（M9 FR-73）`

### Task 5: tier2System 風格抽換（FR-73 prompt / AC-58）

- **ACTION**: `tier2System(persona:outputLanguage:)` 加 `style: MeetingDeepStyle` 參數；`detailed` 逐字保留現行文字。
- **TEST FIRST**（`TierPromptsTests.swift`——**先跑這步再動手**：把現行 `tier2System` 回傳值抓成測試內的期望字串）:
  ```swift
  /// AC-58：detailed = 現行 prompt 逐字不變（回歸鎖）；bullets/concise 只換格式段。
  func testTier2StyleDetailedIsByteIdenticalToLegacy() {
      let legacy = TierPrompts.tier2System(persona: "p", outputLanguage: "繁體中文")   // 改簽章前先記下
      // 改簽章後這行變成：TierPrompts.tier2System(persona: "p", outputLanguage: "繁體中文", style: .detailed)
      XCTAssertEqual(TierPrompts.tier2System(persona: "p", outputLanguage: "繁體中文", style: .detailed), legacy)
  }
  func testTier2StyleBulletsSwapsFormatSectionOnly() {
      let s = TierPrompts.tier2System(persona: "p", outputLanguage: "繁體中文", style: .bullets)
      XCTAssertTrue(s.contains("4 條") || s.contains("四條"), "analysis ≤4 條")
      XCTAssertTrue(s.contains("關鍵詞"), "關鍵詞開頭")
      XCTAssertTrue(s.contains("analysis") && s.contains("followUps") && s.contains("uncertainties"),
                    "JSON 契約三鍵不變——parser 零改動")
  }
  ```
  （實作法：先在測試檔用字面值鎖住現行輸出——把 `tier2System(persona:"p", outputLanguage:"繁體中文")` 的完整回傳貼成 `let legacy = """…"""`——再改簽章。）
  Run — expect FAIL（無 style 參數）
- **IMPLEMENT**（`TierPrompts.swift`）: `tier2System` 加 `style: MeetingDeepStyle` 參數（**無預設值**——強迫所有呼叫點顯式選擇）；函式內把「analysis 該怎麼寫」那一段抽成 switch:
  - `.detailed` → 現行文字原封不動。
  - `.bullets` → 「analysis 以**條列**輸出：**至多 4 條**、每條一行、格式「**關鍵詞**：一句話」（例：「**風險**：舊資料遷移會鎖表」）。followUps 至多 2 條、uncertainties 至多 2 條。對話進行中只有 3 秒掃視時間——關鍵詞是眼睛的錨點。」
  - `.concise` → 「analysis 以 **2~3 句話**直給結論與建議立場，不條列、不鋪陳。followUps 至多 2 條。」
  JSON 輸出契約段（三鍵、格式範例）三種風格**共用同一段**，不得分岔。
  `AnswerCoordinator.runTier2` 呼叫點帶 `style: config.deepStyle`。
- **GOTCHA**: `AIEnhancementOutputFilter.filter`＋`TierParsers.parseTier2` 零改動——風格只活在 analysis 字串內部。
- **VALIDATE**: `-only-testing:VoiceInkTests/TierPromptsTests` PASS（含 byte-identical 鎖）。
- **COMMIT**: `feat(meeting-copilot): tier2 深答風格抽換（detailed 逐字回歸鎖）（M9 FR-73）`

### Task 6: 覆盤標題連動錄音名（FR-68 / AC-52）

- **ACTION**: `MeetingRowDisplay.title` 加 recordingTitle 參數；頁面以 fingerprint→標題字典解析。
- **TEST FIRST**（`MeetingCopilotPageTests.swift` 或新測試檔追加）:
  ```swift
  /// AC-52：標題解析——錄音名優先，查不到退回日期命名。
  func testSessionTitlePrefersLinkedRecordingName() {
      let date = Date(timeIntervalSince1970: 1_760_000_000)
      XCTAssertEqual(MeetingRowDisplay.title(startedAt: date, recordingTitle: "面試A練習"), "面試A練習")
      XCTAssertEqual(MeetingRowDisplay.title(startedAt: date, recordingTitle: ""),
                     MeetingRowDisplay.title(startedAt: date, recordingTitle: nil), "空字串同 nil")
      XCTAssertTrue(MeetingRowDisplay.title(startedAt: date, recordingTitle: nil).hasSuffix(" 會議"),
                    "fallback 維持現行日期命名")
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**:
  1. `MeetingRowDisplay`:
     ```swift
     /// M9 FR-68：錄音名優先（顯示時 live lookup，不存副本——改名自動反映）；查不到退回日期命名。
     static func title(startedAt: Date, recordingTitle: String?) -> String {
         if let t = recordingTitle, !t.isEmpty { return t }
         return titleFormatter.string(from: startedAt) + " 會議"
     }
     ```
     （舊簽章刪除，兩個呼叫點同 commit 改。）
  2. `MeetingCopilotPageView` 列表層加解析字典（personal scale fetch-all，鏡射 `RetrievalService` categoryName 的字典手法）:
     ```swift
     /// fingerprint → 錄音顯示名。列表 body 進場算一次；改名後重繪自動更新。
     private var recordingTitleByFingerprint: [String: String] {
         let all = (try? modelContext.fetch(FetchDescriptor<Transcription>())) ?? []
         return Dictionary(all.compactMap { t in
             guard let fp = t.importFingerprint, !fp.isEmpty,
                   let title = t.recorderTitle, !title.isEmpty else { return nil }
             return (fp, title)
         }, uniquingKeysWith: { a, _ in a })
     }
     ```
     列（:197）與詳情 header（:261）改傳 `recordingTitle: recordingTitleByFingerprint[session.importFingerprint]`（詳情 sheet 由父層把解析好的字串傳進去，sheet 本身不碰 modelContext）。
- **GOTCHA**: `MeetingSessionDetailSheet` 是獨立 struct——用 init 參數傳 `resolvedTitle: String?`，不要在 sheet 內重複 fetch。
- **VALIDATE**: 測試 PASS＋編譯綠。
- **COMMIT**: `feat(meeting-copilot): 覆盤標題連動錄音名（live lookup 不存副本）（M9 FR-68）`

### Task 7: 刪除傳播 reconciler（FR-69 / AC-53）

- **ACTION**: 新 `MeetingSessionReconciler`：`.transcriptionDeleted` → sweep 刪 fingerprint 孤兒 session。
- **TEST FIRST**（新檔 `MeetingReplayQueueTests.swift` 先放 reconciler 測試；in-memory container 含 `MeetingLiveSession`＋`Transcription`＋cue）:
  ```swift
  /// AC-53：X 的 live＋replay 全刪；Y 與空 fingerprint 不動；cue cascade。
  @MainActor
  func testReconcileDeletesAllSessionsOfDeletedRecording() throws {
      let ctx = try makeInMemoryMeetingContext()
      let keepT = Transcription(text: "y", duration: 1); keepT.importFingerprint = "Y"
      ctx.insert(keepT)   // X 的錄音「不存在」＝已被刪
      let liveX = MeetingLiveSession(); liveX.importFingerprint = "X"; liveX.sourceRaw = "live"
      let replayX = MeetingLiveSession(); replayX.importFingerprint = "X"; replayX.sourceRaw = "replay"
      let sessionY = MeetingLiveSession(); sessionY.importFingerprint = "Y"
      let legacy = MeetingLiveSession()   // fingerprint = ""（未關聯）
      [liveX, replayX, sessionY, legacy].forEach { ctx.insert($0) }
      ctx.insert(MeetingLiveCue(session: liveX, text: "q", kind: .directQuestion, askedAt: Date(), contextExcerpt: ""))
      try ctx.save()

      let reconciler = MeetingSessionReconciler()
      reconciler.configure(modelContext: ctx)
      reconciler.reconcile()

      let remaining = try ctx.fetch(FetchDescriptor<MeetingLiveSession>())
      XCTAssertEqual(Set(remaining.map(\.importFingerprint)), ["Y", ""], "X 全刪；Y 與空 fingerprint 不動")
      XCTAssertTrue(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).isEmpty, "cue cascade")
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**（新檔 `VoiceInk/Services/MeetingCopilot/MeetingSessionReconciler.swift`）:
  ```swift
  import Foundation
  import SwiftData
  import os

  /// M9 FR-69：錄音刪除 → 關聯 session（live＋replay）跟著刪。
  /// `.transcriptionDeleted` 是批次 nil 訊號（不帶 id）→ 只能 sweep 全量比對——
  /// 鏡射 `TranscriptIndexService.reconcileOrphans` 的既驗證形狀。空 fingerprint 永不觸碰。
  @MainActor
  final class MeetingSessionReconciler {
      static let shared = MeetingSessionReconciler()
      private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")
      private var modelContext: ModelContext?
      private var observer: NSObjectProtocol?

      func configure(modelContext: ModelContext) {
          self.modelContext = modelContext
          if let observer { NotificationCenter.default.removeObserver(observer) }
          observer = NotificationCenter.default.addObserver(
              forName: .transcriptionDeleted, object: nil, queue: .main
          ) { _ in
              Task { @MainActor in MeetingSessionReconciler.shared.reconcile() }
          }
      }

      func reconcile() {
          guard let ctx = modelContext else { return }
          let sessions = (try? ctx.fetch(FetchDescriptor<MeetingLiveSession>())) ?? []
          let linked = sessions.filter { !$0.importFingerprint.isEmpty }
          guard !linked.isEmpty else { return }
          let liveFingerprints = Set(
              ((try? ctx.fetch(FetchDescriptor<Transcription>())) ?? []).compactMap(\.importFingerprint))
          let orphans = linked.filter { !liveFingerprints.contains($0.importFingerprint) }
          guard !orphans.isEmpty else { return }
          for s in orphans { ctx.delete(s) }   // cue/segment 由 @Relationship cascade 帶走
          try? ctx.save()
          logger.notice("🧹 覆盤刪除傳播：清掉 \(orphans.count, privacy: .public) 場孤兒 session")
      }
  }
  ```
  `VoiceInk.swift:143` 旁（`TranscriptIndexService.shared.configure` 下一行）加
  `MeetingSessionReconciler.shared.configure(modelContext: resolvedContainer.mainContext)`。
- **MIRROR**: RECONCILE_SWEEP＋OBSERVER_CONFIGURE。
- **GOTCHA**: 測試用 `MeetingSessionReconciler()`（非 shared）避免污染其他測試；shared 只給 bootstrap。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(meeting-copilot): 錄音刪除 → 關聯 session 全刪（sweep）（M9 FR-69）`

### Task 8: 覆盤按鈕三態（FR-70 / AC-54）

- **ACTION**: 三態純函式＋`RecorderHistoryView` 接上。
- **TEST FIRST**（`MeetingReplayQueueTests.swift` 追加）:
  ```swift
  /// AC-54：有 live → 只能查看；無 live 有 replay → 查看＋重新產生；皆無 → 產生。
  func testReviewButtonTriState() {
      let live = (id: UUID(), sourceRaw: "live", startedAt: Date())
      let replay = (id: UUID(), sourceRaw: "replay", startedAt: Date().addingTimeInterval(60))
      switch CopilotReviewButtons.state(sessions: [(live.id, live.sourceRaw, live.startedAt),
                                                   (replay.id, replay.sourceRaw, replay.startedAt)]) {
      case .viewOnly(let id): XCTAssertEqual(id, replay.id, "查看開最新那場")
      default: XCTFail("有 live → viewOnly")
      }
      switch CopilotReviewButtons.state(sessions: [(replay.id, replay.sourceRaw, replay.startedAt)]) {
      case .viewAndRegenerate(let id): XCTAssertEqual(id, replay.id)
      default: XCTFail("只有 replay → 可重新產生（A/B 保留）")
      }
      if case .generate = CopilotReviewButtons.state(sessions: []) {} else { XCTFail("皆無 → 產生") }
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**:
  1. `MeetingReplayQueue.swift` 檔內（或獨立）純函式:
     ```swift
     /// M9 FR-70：live 與 replay 不同時並存——**狀態判斷，非永久規則**：
     /// live 被刪（覆盤頁批次刪除）後，「產生」按鈕就回來。
     enum CopilotReviewButtons {
         enum State: Equatable { case generate, viewOnly(latest: UUID), viewAndRegenerate(latest: UUID) }
         static func state(sessions: [(id: UUID, sourceRaw: String, startedAt: Date)]) -> State {
             guard let latest = sessions.max(by: { $0.startedAt < $1.startedAt }) else { return .generate }
             let hasLive = sessions.contains { $0.sourceRaw == "live" }
             return hasLive ? .viewOnly(latest: latest.id) : .viewAndRegenerate(latest: latest.id)
         }
     }
     ```
  2. `RecorderHistoryView.lookupMeetingSession` 改抓**全部** fingerprint match 的 session（拿掉 fetchLimit 1），存
     `@State private var reviewButtonState: CopilotReviewButtons.State = .generate`；`copilotReviewButtons` 依三態渲染
     （`.viewOnly` → 查看鈕；`.viewAndRegenerate` → 查看＋重新產生；`.generate` → 產生）。
- **VALIDATE**: 測試 PASS＋編譯綠。
- **COMMIT**: `feat(meeting-copilot): 覆盤按鈕三態——live 存在時不提供補做（M9 FR-70）`

### Task 9: MeetingReplayQueue 背景佇列（FR-71 / AC-55, AC-57）

- **ACTION**: FIFO 佇列（防重複、@Published 狀態、失敗通知）；`RecorderHistoryView` 改 enqueue；service 加 `currentSessionId`。
- **TEST FIRST**（`MeetingReplayQueueTests.swift` 追加；佇列以注入 runner 測，不碰真 service）:
  ```swift
  /// AC-57＋序列性：重複 enqueue no-op；兩筆不同錄音 FIFO 序列跑。
  @MainActor
  func testQueueDeduplicatesAndRunsSerially() async throws {
      var started: [UUID] = []
      var finish: [CheckedContinuation<Void, Never>] = []
      let queue = MeetingReplayQueue(runner: { t in
          started.append(t.id)
          await withCheckedContinuation { finish.append($0) }   // 掛住直到測試放行
      })
      let t1 = Transcription(text: "a", duration: 1)
      let t2 = Transcription(text: "b", duration: 1)
      queue.enqueue(t1); queue.enqueue(t1); queue.enqueue(t2)   // t1 重複 → no-op
      XCTAssertTrue(queue.isBusy(t1.id)); XCTAssertTrue(queue.isBusy(t2.id))
      await Task.yield()
      XCTAssertEqual(started, [t1.id], "序列：t2 要等 t1")
      finish.removeFirst().resume()
      try await waitUntil { started.count == 2 }                // 同檔 helper：輪詢至條件成立
      finish.removeFirst().resume()
      try await waitUntil { !queue.isBusy(t1.id) && !queue.isBusy(t2.id) }
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**:
  1. `MeetingReplayReviewService.swift`: 加 `@Published private(set) var currentSessionId: UUID?`——`generateReview` 在 `modelContext.insert(session)` 後設、`defer` 清（覆盤頁 badge 的來源）。
  2. 新檔 `VoiceInk/Services/MeetingCopilot/MeetingReplayQueue.swift`:
     ```swift
     import Foundation
     import SwiftData
     import Combine
     import os

     /// M9 FR-71：覆盤背景佇列。service 仍是「一場覆盤的執行者」（失敗刪整場語意不變），
     /// queue 只管排程＋狀態廣播；view 從此不持有 service。序列（一次一場）沿用 service 的
     /// rate-limit 紅線（見 MeetingReplayReviewService 檔頭「為什麼全程序列」）。
     @MainActor
     final class MeetingReplayQueue: ObservableObject {
         static let shared = MeetingReplayQueue()
         private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

         /// 排隊＋跑動中的錄音 id（兩頁「覆盤中」badge 的單一來源）。
         @Published private(set) var inFlight: Set<UUID> = []
         /// 跑動中那場的 session id（覆盤頁列 badge 用；service 插入 session 後就有值）。
         @Published private(set) var activeSessionId: UUID?
         @Published private(set) var progress: (done: Int, total: Int)?

         private var pending: [Transcription] = []
         private var working = false
         private var cancellables: Set<AnyCancellable> = []
         /// 注入 seam：測試給 fake；正式預設 nil → enqueue(transcription:aiService:modelContext:) 建真 service。
         private let runner: ((Transcription) async throws -> Void)?
         init(runner: ((Transcription) async throws -> Void)? = nil) { self.runner = runner }

         func isBusy(_ transcriptionId: UUID) -> Bool { inFlight.contains(transcriptionId) }

         func enqueue(_ transcription: Transcription, aiService: AIService? = nil, modelContext: ModelContext? = nil) {
             guard !inFlight.contains(transcription.id) else { return }   // AC-57 防重複
             inFlight.insert(transcription.id)
             pending.append(transcription)
             pump(aiService: aiService, modelContext: modelContext)
         }

         private func pump(aiService: AIService?, modelContext: ModelContext?) {
             guard !working, !pending.isEmpty else { return }
             working = true
             let next = pending.removeFirst()
             Task { [weak self] in
                 guard let self else { return }
                 do {
                     if let runner { try await runner(next) }
                     else { try await self.runReal(next, aiService: aiService, modelContext: modelContext) }
                 } catch {
                     // 失敗＝service 已刪整場（不留半套）；背景語意 → toast 告知。
                     NotificationManager.shared.showNotification(
                         title: "覆盤失敗：\(error.localizedDescription)", type: .error, duration: 5)
                 }
                 self.inFlight.remove(next.id)
                 self.activeSessionId = nil
                 self.progress = nil
                 self.cancellables.removeAll()
                 self.working = false
                 self.pump(aiService: aiService, modelContext: modelContext)   // FIFO 下一場
             }
         }

         /// 真跑一場：工廠邏輯自 RecorderHistoryView.generateReview 原樣搬入（那邊改成呼叫 enqueue）。
         private func runReal(_ t: Transcription, aiService: AIService?, modelContext: ModelContext?) async throws {
             guard let aiService, let modelContext else { return }
             let config = MeetingCopilotConfigStore.shared
             let fast = MeetingCopilotLiveController.makeStreamingCompleter(
                 provider: config.fastProviderName, model: config.fastModelName, aiService: aiService)
             let deep = MeetingCopilotLiveController.makeStreamingCompleter(
                 provider: config.deepProviderName, model: config.deepModelName, aiService: aiService)
             let coordinator = AnswerCoordinator(
                 fast: fast.completer, deep: deep.completer,
                 grounding: MeetingGroundingProvider(screen: ScreenCaptureService(), modelContext: modelContext),
                 config: config, fastLabel: fast.label, deepLabel: deep.label)
             let service = MeetingReplayReviewService(
                 extractorChat: MeetingCopilotController.makeFastCompleter(aiService: aiService, config: config),
                 coordinator: coordinator, modelContext: modelContext,
                 extractionModelLabel: fast.label, config: config)
             service.$progress.sink { [weak self] in self?.progress = $0 }.store(in: &cancellables)
             service.$currentSessionId.sink { [weak self] in self?.activeSessionId = $0 }.store(in: &cancellables)
             _ = try await service.generateReview(for: t)
         }
     }
     ```
  3. `RecorderHistoryView`: 刪 `reviewService`/`reviewError` @State 與 `generateReview()`；「產生／重新產生」按鈕改
     `MeetingReplayQueue.shared.enqueue(transcription, aiService: aiService, modelContext: modelContext)`，
     `.disabled(replayQueue.isBusy(transcription.id))`；`ReplayReviewProgressLabel` 改吃 `@ObservedObject var queue: MeetingReplayQueue`（顯示 `queue.progress`）。完成後**不再** `onClose()＋openMeetingReview`（背景語意）。
- **MIRROR**: COORDINATOR 工廠段（RecorderHistoryView:1034-1053 原文搬移）。
- **GOTCHA**: `pending` 持 `Transcription`（@Model 參照）——若跑到它時已被刪，`generateReview` 讀 `transcription.text` 前先 `guard !next.isDeleted else { … }`（skip＋清狀態），避免對已刪 model 讀值。
- **VALIDATE**: `-only-testing:VoiceInkTests/MeetingReplayQueueTests` PASS。
- **COMMIT**: `feat(meeting-copilot): MeetingReplayQueue 覆盤背景佇列（FIFO、防重複、失敗通知）（M9 FR-71）`

### Task 10: 「覆盤中」badge 雙頁（FR-72 / AC-56）

- **ACTION**: 錄音列＋覆盤頁 session 列接 queue 狀態。
- **TEST FIRST**: 狀態語意已由 Task 9 鎖（`isBusy`/`activeSessionId`）；本 task 是 view 接線——編譯＋手動清單。
- **IMPLEMENT**:
  1. `RecorderHistoryView` 的 `RecordingCard`: 加 `@ObservedObject private var replayQueue = MeetingReplayQueue.shared`；badge 列（:444 旁）追加:
     ```swift
     if replayQueue.isBusy(transcription.id) { badge("覆盤中", "arrow.triangle.2.circlepath", AppTheme.Accent.primary) }
     ```
  2. `MeetingCopilotPageView` 的 `MeetingSessionRow`: 加同款 @ObservedObject；「離線覆盤」badge 旁（SESSION_ROW_BADGE 形狀、色改 accent）:
     ```swift
     if session.id == replayQueue.activeSessionId {
         Text("覆盤中").font(.system(size: 9, weight: .bold))
             .padding(.horizontal, 5).padding(.vertical, 1)
             .background(Capsule().fill(AppTheme.Accent.primary.opacity(0.15)))
             .foregroundStyle(AppTheme.Accent.primary)
     }
     ```
- **VALIDATE**: 編譯綠；badge 生命週期進 Task 11 手動清單。
- **COMMIT**: `feat(meeting-copilot): 覆盤中 badge 雙頁顯示（M9 FR-72）`

### Task 11: 全量驗證 + 手動清單

- **VALIDATE**:
  ```bash
  # 型別/編譯（產 app 進 .local-build，勿建到 /tmp——見 voiceink-build-verify skill）
  SWIFT_ENABLE_EXPLICIT_MODULES=NO xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
    -configuration Debug -derivedDataPath ./.local-build -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' build \
    > /tmp/m9-build.log 2>&1; grep -c "BUILD SUCCEEDED" /tmp/m9-build.log
  # 全 target 測試（TEST_COMMAND 去掉 -only-testing）
  ```
- **手動清單**（真模型；TTS 測試法見專案記憶 meeting-copilot-debug-workflow）:
  - [ ] 無筆記索引時問「你做過什麼專案」→ overlay 顯示「筆記沒有記載」＋自介，Console 無 fast model 呼叫（AC-48/49 實測）
  - [ ] aboutMe cue 不出現深度分析；技術 cue 照常 auto-deep（AC-51）
  - [ ] 深答風格三檔切換：條列式 ≤4 條關鍵詞開頭／簡潔 2~3 句／詳細＝舊觀感（AC-58）
  - [ ] 錄音改名 → 覆盤頁標題即時反映；刪錄音 → 該場 live＋replay 消失（AC-52/53）
  - [ ] 產生覆盤後立刻關掉詳情 → 錄音列與覆盤頁都有「覆盤中」badge → 跑完消失、session 完整（AC-55/56）
  - [ ] 有 live 的錄音看不到「產生」；到覆盤頁刪掉該 live → 按鈕回來（AC-54／FR-70 狀態性）
- **COMMIT**: `test(meeting-copilot): M9 全量驗證收尾`

---

## Testing Strategy

### Unit Tests

| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| 零接地短路 | aboutMe＋空接地 | 零 LLM 呼叫＋固定文案 | 🔴 防幻覺核心 |
| 自介條列 | 同上＋brief 非空 | bullets=[brief] | |
| deep 雙守門 | aboutMe auto＋manual | deep callCount=0 | 技術 cue 對照組 |
| tier1 aboutMe prompt | — | 1~3 條＋紅線字句 | 舊「恰3」移除 |
| tier2 風格 | 三檔 | detailed 逐字同舊 | 🔴 回歸鎖 |
| deepStyle round-trip | set→新 store | 讀回一致；預設 bullets | |
| 標題解析 | 錄音名／空／nil | 名優先、退日期 | |
| reconcile sweep | X刪/Y留/空fp | 精確全刪＋cascade | 空 fp 永不動 |
| 按鈕三態 | live/replay 組合 | 三態正確＋最新優先 | |
| 佇列 | 重複＋兩筆 | 防重複＋FIFO 序列 | 掛住的 runner |

### Edge Cases Checklist
- [ ] aboutMe＋RAG 降級（ragError 非 nil）→ 同樣短路且 groundingNote 記原因
- [ ] `useNotesRAG` 關閉 → aboutMe 一樣短路（零片段不論原因）
- [ ] 佇列跑到一半錄音被刪（isDeleted guard）
- [ ] 舊 RunConfig 快照（無 deepStyle）decode 正常（optional）
- [ ] replay 路徑的 aboutMe cue 同樣短路（runTier1ForReplay 共用）

## Validation Commands

見 Task 11。EXPECT: BUILD SUCCEEDED；全測試 PASS；deploy 由使用者 `! make deploy`。

## Acceptance Criteria
- [ ] SRS AC-48 ~ AC-58 全數有對應測試或手動清單項且通過
- [ ] 全 target 測試零回歸；compile check BUILD SUCCEEDED
- [ ] `tier2SystemAboutMe`/`tier2UserAboutMe`/舊 `MeetingRowDisplay.title(startedAt:)` 單參數簽章零殘留（grep）

## Completion Checklist
- [ ] deepStyle 進 `MeetingCopilotRunConfig` 快照（M8 慣例：新設定必進快照、欄位 optional）
- [ ] 失敗路徑：aboutMe 短路與 deep 守門皆 log-only（無 modal）；佇列失敗走 NotificationManager（離線操作，允許 toast）
- [ ] 文件：實作報告 `docs/reports/meeting-copilot-m9-report.md`＋SPEC_ROADMAP 標 implemented＋plan 移 `docs/plans/completed/`

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| 「筆記沒記載」誤傷（筆記有但檢索沒命中） | M | M | 訊息措辭不絕對化（「筆記沒有記載這題」）；searchHint 改寫已在 M8 降低 miss；覆盤 groundingNote 可觀測 |
| 預設條列式改變既有使用觀感 | 確定發生 | L | 這正是需求目的；詳細檔一鍵切回（byte-identical 回歸鎖保證） |
| 佇列跑動中 app 結束 → 半套 session | L | L | service 失敗刪整場語意不變；殘留半套下次手動重跑覆蓋（同 fingerprint 多場並存本就允許） |
| reconcile 與跑動中 replay 撞（錄音剛刪、session 剛插入） | L | M | queue 的 isDeleted guard＋service 失敗路徑本就刪 session；風險窗僅毫秒級 |

## Notes
- Linear：repo config `skip: true`——不建 issue。
- 與 `ask-ai-obsidian-notes-rag.plan.md` 可平行實作（不同 worktree）：共檔 `MeetingCopilotConfigStore.swift`
  （彼刪資料夾欄位／此加 deepStyle——不同區塊）與 `MeetingCopilotSettingsView.swift`（彼瘦身 notesRAG section／
  此在 modelSection 加 picker——不同 Section），merge 衝突可自動解。
