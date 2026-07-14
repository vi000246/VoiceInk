---
linear_issue: null
---
# Plan: Ask AI × Obsidian 筆記 RAG（雙語料庫 scope + 筆記設定收編 + 引用回筆記）

> **For agentic workers:** `/prp-implement` will route this plan to the matching skill based on `Metadata.Type` below. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **Checkbox states (SDD Dashboard compatible):** `- [ ]` todo · `- [~]` in-progress · `- [x]` done. Treat `[~]` exactly like `[ ]` when judging whether a task is finished — it is NOT done.

## Summary

把 M8 建立的 Obsidian 筆記索引升級為 Ask AI 的一級查詢語料庫：scope bar「語音庫／Obsidian 筆記」
雙 chip、筆記管線設定（vault override＋資料夾 multi-checkbox＋重建）收編到 Ask AI 齒輪 sheet、
引用可「在 Obsidian 開啟」。同時修現有漏洞：`.all` 的 `sources = nil` 不過濾 sourceKind，
筆記塊**已經**漏進預設查詢且引用誤稱「來源錄音」。

## User Story

As a 同時用 Ask AI 問語音庫與維護 Obsidian 筆記的使用者,
I want 每一題都能明示查語音庫、查筆記、或兩者，且引用能點回筆記原文,
So that 筆記知識庫與錄音知識庫在同一個問答入口可控地共存，而不是悄悄混在一起。

## Problem → Solution

筆記塊經由 `sources=nil` 漏進預設查詢、引用斷頭、索引只在開會時更新、vault/資料夾設定埋在
Meeting Copilot 設定頁 → 明確 scope 組合＋facet 豁免＋Ask AI 側自動增量索引＋設定收編＋
`obsidian://` 引用回鏈。

## Metadata
- **Module**: ask-ai
- **Parent Plan**: N/A
- **Source PRD**: N/A
- **Source Feature SRS**: docs/srs/ask-ai-obsidian-notes-rag.srs.md
- **Source Module Spec**: docs/spec/ask-ai.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature
- **Size**: L
- **Complexity**: Large
- **Rigor**: balanced
- **Mode**: B — 任務先測
- **TDD**: on（task-level test-first）
- **Commit cadence**: per-task
- **Estimated Files**: ~16（CREATE 4 / UPDATE ~12）

---

## UX Design

### Before

```
Ask AI scope bar:
[全部來源▾] [全部分類▾] [不限時間▾]        （筆記塊悄悄混在「全部來源」裡）
引用 [1] → popup「來源錄音」＋無動作        （筆記引用斷頭）
筆記設定：Meeting Copilot 設定頁（逗號分隔 TextField）
索引更新：只在開會 attach 時
```

### After

```
Ask AI scope bar:
[🎙 語音庫 ✓] [📝 Obsidian 筆記]  ｜ 語音庫開啟時 → [全部來源▾] [全部分類▾] [不限時間▾]
引用 [1] → 筆記塊 popup：《筆記標題》＋「在 Obsidian 開啟」
齒輪 ▾ → 「筆記來源設定…」sheet：vault 卡片＋資料夾 checkbox＋重建索引
索引更新：進 Ask AI 頁／開筆記 chip 時背景增量（＋開會 attach 照舊）
```

### Interaction Changes

| Touchpoint | Before | After | Notes |
|---|---|---|---|
| scope bar | 單一來源 Picker（全部/語音/錄音） | 雙 chip ＋ 語音庫開啟時才顯示三個 facet picker | chip @AppStorage 持久化；禁全關 |
| 引用 popup | 筆記被誤稱「來源錄音」 | 筆記標題＋「在 Obsidian 開啟」 | 檔案不存在→藏按鈕 |
| Meeting 設定頁筆記區 | vault 顯示＋資料夾 TextField＋重建 | 消費開關＋自介＋「筆記索引設定（Ask AI）→」 | `AppNavigator.navigate(to: .askAI)` |
| 齒輪選單 | 兩個模型 Picker | ＋「筆記來源設定…」項 → sheet | |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/ask-ai-obsidian-notes-rag.srs.md` | all | 本 plan 的需求與 AC 來源 |
| P0 | `VoiceInk/Services/AskAI/ObsidianNoteIndexService.swift` | all | 索引服務全貌：sidecar/確定性 id/取代式 upsert |
| P0 | `VoiceInk/Services/AskAI/RetrievalService.swift` | all | 檢索過濾結構（predicate + in-memory）與 #Predicate 爆炸註解 |
| P0 | `VoiceInk/Views/AskAI/AskAIView.swift` | all | scope bar／齒輪／citation popup／currentScope |
| P1 | `VoiceInk/Services/AskAI/AskAIConfig.swift` | 41-60 | AskAISourceFilter 現貌 |
| P1 | `VoiceInk/Models/AskAIModels.swift` | 7-93 | EmbeddingChunk / ChunkRef |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | 40-52, 122-148, 319-342 | 被搬走的欄位與 setter 形狀 |
| P1 | `VoiceInk/Services/MeetingCopilot/MeetingCopilotLiveController.swift` | 187-225 | scheduleNotesReindex + notesIndexStateURL（要搬家） |
| P1 | `VoiceInk/Views/MeetingCopilot/MeetingCopilotSettingsView.swift` | 200-290 | notesRAGSection（要瘦身）＋ reindexNotes（要搬） |
| P1 | `VoiceInk/Views/Settings/RecordersSettingsView.swift` | 66-114 | VaultRootCard：NSOpenPanel + security-scoped bookmark 樣板 |
| P1 | `VoiceInkTests/ObsidianNoteIndexTests.swift` | all | FakeCountingEmbedder / makeTempVault / 回歸鎖測試 |
| P2 | `VoiceInk/Services/AskAI/AskAIService.swift` | 82-98, 159-174 | extractCitations / diagnoseEmptyRetrieval |
| P2 | `VoiceInk/Services/AskAI/TranscriptIndexService.swift` | 30-37, 113-129 | model 讀取與 reconcile 豁免（不改，理解用） |
| P2 | `VoiceInkTests/MeetingCopilotConfigStoreTests.swift` | all | UserDefaults store 測試樣板 |

## External Documentation

| Topic | Source | Key Takeaway |
|---|---|---|
| Obsidian URI | https://help.obsidian.md/Extending+Obsidian/Obsidian+URI | `obsidian://open?path=<絕對路徑>` 由 Obsidian 解析所屬 vault；vault 需曾在 Obsidian 開啟過 |

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

### CONFIG_STORE（@Published + UserDefaults setter）
```swift
// SOURCE: VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift:334-342
func setNotesIncludeOnlyFolders(_ value: [String]) {
    notesIncludeOnlyFolders = value
    UserDefaults.standard.set(value, forKey: notesIncludeOnlyKey)
}
```

### VAULT_PICKER（NSOpenPanel + security-scoped bookmark）
```swift
// SOURCE: VoiceInk/Views/Settings/RecordersSettingsView.swift:101-113
private func chooseVault() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "選擇 Obsidian Vault 的根目錄"
    guard panel.runModal() == .OK, let root = panel.url else { return }
    guard let bookmark = try? root.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil, relativeTo: nil) else {
        NotificationManager.shared.showNotification(title: "無法建立 Vault 授權", type: .error, duration: 4); return
    }
    store.setVaultRoot(bookmark)
}
```

### SECURITY_SCOPE（vault 存取包裝）
```swift
// SOURCE: VoiceInk/Services/AskAI/ObsidianNoteIndexService.swift:60-61
let accessing = vaultRoot.startAccessingSecurityScopedResource()
defer { if accessing { vaultRoot.stopAccessingSecurityScopedResource() } }
```

### IN_MEMORY_FILTER（RetrievalService 的過濾段——豁免要加在這裡）
```swift
// SOURCE: VoiceInk/Services/AskAI/RetrievalService.swift:55-67
if let sources = scope.sources {
    candidates = candidates.filter { sources.contains($0.sourceKind) }
}
if let categoryId = scope.categoryId {
    candidates = candidates.filter { $0.categoryId == categoryId }
}
if let categoryName = scope.categoryName {
    let all = (try? context.fetch(FetchDescriptor<Transcription>())) ?? []
    let tagById = Dictionary(all.map { ($0.id, $0.displayTag) }, uniquingKeysWith: { a, _ in a })
    candidates = candidates.filter { tagById[$0.transcriptionId] == categoryName }
}
```

### SIDECAR_STATE（IndexState 現貌——schema 欄位加在這裡）
```swift
// SOURCE: VoiceInk/Services/AskAI/ObsidianNoteIndexService.swift:190-213
private struct IndexState: Codable {
    var embeddingModel: String
    var files: [String: String]
}
private func loadState(currentModelTag: String) -> [String: String] {
    guard let data = try? Data(contentsOf: stateURL),
          let state = try? JSONDecoder().decode(IndexState.self, from: data),
          state.embeddingModel == currentModelTag else { return [:] }
    return state.files
}
```

### TEST_FIXTURE（in-memory container + 假嵌入器 + 暫存 vault）
```swift
// SOURCE: VoiceInkTests/ObsidianNoteIndexTests.swift:7-13, 42-64
private final class FakeCountingEmbedder: EmbeddingProviding {
    var embedCallCount = 0
    func embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]] {
        embedCallCount += 1
        return texts.map { _ in [0.25, 0.5, 0.75] }
    }
}
// makeInMemoryContextAndFakeEmbedder() / makeTempVault(files:) 私有 helper 在同檔底部，直接重用。
```

### JSON_IN_RAW（ChunkRef 存取器）
```swift
// SOURCE: VoiceInk/Models/AskAIModels.swift:74-93
var citations: [ChunkRef] {
    get {
        guard let citationsRaw, let data = citationsRaw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([ChunkRef].self, from: data) else { return [] }
        return decoded
    }
    ...
}
```

### CHIP_STYLE（scope bar 的 capsule chip 外觀）
```swift
// SOURCE: VoiceInk/Views/AskAI/AskAIView.swift:236-247（單檔限定 chip）
HStack(spacing: 5) {
    Image(systemName: "target").font(.system(size: 11))
    Text("限定：\(focusedTitle)").font(.system(size: 12, weight: .medium)).lineLimit(1)
}
.padding(.horizontal, 10).padding(.vertical, 5)
.background(Capsule().fill(AppTheme.Accent.primary.opacity(0.14)))
.foregroundStyle(AppTheme.Accent.primary)
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/AskAI/ObsidianRAGConfigStore.swift` | CREATE | 筆記管線設定新家（vault override＋資料夾） |
| `VoiceInk/Views/AskAI/AskAINotesSettingsSheet.swift` | CREATE | 筆記來源設定 sheet（vault 卡片＋checkbox＋重建） |
| `VoiceInkTests/ObsidianRAGConfigStoreTests.swift` | CREATE | 新 store 測試 |
| `VoiceInkTests/AskAIScopeTests.swift` | CREATE | scope 組合＋facet 豁免＋URL builder 測試 |
| `VoiceInk/Services/AskAI/AskAIConfig.swift` | UPDATE | `.all` 明確集合＋scope 組合純函式 |
| `VoiceInk/Services/AskAI/RetrievalService.swift` | UPDATE | facet 豁免（date 移出 predicate） |
| `VoiceInk/Models/AskAIModels.swift` | UPDATE | EmbeddingChunk/ChunkRef 加 sourceTitle/sourcePath |
| `VoiceInk/Services/AskAI/ObsidianNoteIndexService.swift` | UPDATE | metadata 寫入＋schema:2＋全量前清空＋stateURL 搬入＋自動觸發 |
| `VoiceInk/Services/AskAI/AskAIService.swift` | UPDATE | extractCitations 帶 metadata＋diagnose 筆記分支 |
| `VoiceInk/Views/AskAI/AskAIView.swift` | UPDATE | 雙 chip＋currentScope＋齒輪項＋popup 分流＋文案 |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotConfigStore.swift` | UPDATE | 移除資料夾兩欄位與 setters |
| `VoiceInk/Services/MeetingCopilot/MeetingCopilotLiveController.swift` | UPDATE | scheduleNotesReindex 改讀新 store＋effective vault；notesIndexStateURL 移除 |
| `VoiceInk/Views/MeetingCopilot/MeetingCopilotSettingsView.swift` | UPDATE | notesRAG section 瘦身＋導航連結 |
| `VoiceInkTests/ObsidianNoteIndexTests.swift` | UPDATE | schema 自癒＋metadata 回填＋幽靈清理測試 |
| `VoiceInkTests/AskAIIndexTests.swift` | UPDATE | ChunkRef 相容＋extractCitations metadata 測試 |
| `VoiceInkTests/MeetingCopilotConfigStoreTests.swift` | UPDATE | 移除資料夾欄位的測試搬到新 store 測試 |

## NOT Building

- 根目錄散檔 checkbox（使用者明確排除；caption 說明即可）
- timer／FSEvents 檔案監看
- 檢索層資料夾過濾（資料夾只是索引層粒度）
- 筆記的分類/tag facet
- meeting-copilot 的 aboutMe 檢索路由改動（M9 plan 的事，別混進來）
- `RecorderConfigStore`／`VaultExportService` 任何行為變更

---

## Step-by-Step Tasks

### Task 1: `.all` 明確集合 + scope 組合純函式（FR-1/FR-3）

- **ACTION**: `AskAISourceFilter.sources` 型別改 `Set<String>`（非 optional），`.all` 回傳明確三 kind；新增 `AskAIScopeComposer` 純函式。
- **TEST FIRST**（新檔 `VoiceInkTests/AskAIScopeTests.swift`）:
  ```swift
  import XCTest
  @testable import VoiceInk

  final class AskAIScopeTests: XCTestCase {
      /// 🔴 漏洞回歸鎖：.all 絕不可回到 nil（nil = 不過濾 = obsidian 塊漏進預設查詢）。
      func testAllSourceFilterIsExplicitTranscriptKinds() {
          XCTAssertEqual(AskAISourceFilter.all.sources, ["dictation", "recorder", "meeting"])
          XCTAssertEqual(AskAISourceFilter.voice.sources, ["dictation"])
          XCTAssertEqual(AskAISourceFilter.recorder.sources, ["recorder", "meeting"])
      }
      func testScopeComposerCombinations() {
          XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: true, notesOn: false, filter: .all),
                         ["dictation", "recorder", "meeting"])
          XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: false, notesOn: true, filter: .all),
                         ["obsidian"])
          XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: true, notesOn: true, filter: .voice),
                         ["dictation", "obsidian"])
          XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: false, notesOn: false, filter: .all),
                         [], "UI 防呆之外的最後防線：空集合 = 檢索空")
      }
  }
  ```
  Run: TEST_COMMAND `-only-testing:VoiceInkTests/AskAIScopeTests` — expect FAIL（型別不符/類別不存在）
- **IMPLEMENT**（`AskAIConfig.swift`）: `var sources: Set<String>` — `.all → ["dictation","recorder","meeting"]`、`.voice → ["dictation"]`、`.recorder → ["recorder","meeting"]`（doc comment 同步改：nil 語意已移除）。同檔加：
  ```swift
  /// scope bar 雙 chip → 檢索來源集合。空集合 = 兩顆都關（UI 會擋，這裡是最後防線）。
  enum AskAIScopeComposer {
      static func sources(transcriptsOn: Bool, notesOn: Bool, filter: AskAISourceFilter) -> Set<String> {
          var s: Set<String> = []
          if transcriptsOn { s.formUnion(filter.sources) }
          if notesOn { s.insert(ObsidianNoteIndexService.sourceKind) }
          return s
      }
  }
  ```
- **MIRROR**: 純函式 namespace 房子風格（`ObsidianNoteChunking` 同檔案風格）。
- **GOTCHA**: `AskAIView.currentScope` 這時還在用 `sourceFilter.sources`（optional 用法）——同 commit 內把該行改成 `AskAIScope(sources: sourceFilter.sources, …)` 直接包非 optional（`AskAIScope.sources` 本身仍是 optional 型別，塞非 optional 值 OK）。Task 8 才換成 composer。
- **VALIDATE**: TEST_COMMAND `-only-testing:VoiceInkTests/AskAIScopeTests` — PASS；`-only-testing:VoiceInkTests/AskAIIndexTests` — 無回歸。
- **COMMIT**: `fix(ask-ai): .all 明確排除 obsidian 塊（漏洞回歸鎖）＋ scope 組合純函式`

### Task 2: RetrievalService facet 豁免（FR-4）

- **ACTION**: category/date 過濾豁免 obsidian 塊；date 從 `#Predicate` 移到 in-memory。
- **TEST FIRST**（`AskAIScopeTests.swift` 追加；fixture 用 in-memory container，鏡射 `ObsidianNoteIndexTests` 底部 helper 自建一份 container helper）:
  ```swift
  @MainActor
  func testCategoryAndDateFiltersExemptObsidianChunks() throws {
      let ctx = try makeInMemoryIndexContext()   // Schema([EmbeddingChunk.self, Transcription.self, …]) isStoredInMemoryOnly
      let model = EmbeddingModel.gemini001_768
      let vec = EmbeddingClient.floatsToData([1, 0, 0])
      // 一塊 obsidian（mtime 很舊、無分類）＋一塊 dictation（今天、無 tag 命中）
      ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "《筆記》內容",
          vector: vec, dims: 3, embeddingModel: model.tag, sourceKind: "obsidian",
          categoryId: nil, timestamp: Date(timeIntervalSince1970: 0)))
      ctx.insert(EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "逐字稿",
          vector: vec, dims: 3, embeddingModel: model.tag, sourceKind: "dictation",
          categoryId: nil, timestamp: Date()))
      try ctx.save()
      // 近 7 天 + 分類「面試」：obsidian 塊兩個 facet 都豁免 → 唯一存活者
      let scope = AskAIScope(sources: ["dictation", "obsidian"], categoryName: "面試",
                             dateRange: Date().addingTimeInterval(-7 * 86400)...Date())
      let hits = RetrievalService.retrieve(queryVector: [1, 0, 0], scope: scope, k: 10,
                                           model: model, context: ctx)
      XCTAssertEqual(hits.map(\.chunk.sourceKind), ["obsidian"],
                     "obsidian 豁免 category/date；dictation 被 tag 過濾掉")
  }
  ```
  Run — expect FAIL（obsidian 塊被 date predicate／categoryName 過濾殺掉）
- **IMPLEMENT**（`RetrievalService.swift`）: predicate 縮成只剩 `embeddingModel == modelTag`；date 改 in-memory。過濾段每條加豁免：
  ```swift
  let noteKind = ObsidianNoteIndexService.sourceKind
  if let dateRange = scope.dateRange {
      candidates = candidates.filter { $0.sourceKind == noteKind || dateRange.contains($0.timestamp) }
  }
  if let categoryId = scope.categoryId {
      candidates = candidates.filter { $0.sourceKind == noteKind || $0.categoryId == categoryId }
  }
  if let categoryName = scope.categoryName {
      let all = (try? context.fetch(FetchDescriptor<Transcription>())) ?? []
      let tagById = Dictionary(all.map { ($0.id, $0.displayTag) }, uniquingKeysWith: { a, _ in a })
      candidates = candidates.filter { $0.sourceKind == noteKind || tagById[$0.transcriptionId] == categoryName }
  }
  ```
  檔頭與 predicate 註解同步改（說明：facet 是轉錄的屬性，筆記豁免＝domain 規則；date 移出 predicate 是為了豁免＋避 optional 型別爆炸）。
- **MIRROR**: IN_MEMORY_FILTER。
- **GOTCHA**: `sources` 過濾**不豁免**（那是 scope 的本體）。單檔限定 `transcriptionId` 過濾也不豁免（筆記本來就不會命中）。
- **VALIDATE**: 新測試 PASS；`-only-testing:VoiceInkTests/AskAIIndexTests`＋`GroundingTests` 無回歸（meeting 路徑不傳 category/date，行為不變）。
- **COMMIT**: `feat(ask-ai): 檢索 facet 豁免 obsidian 塊（分類過濾不再誤殺筆記）`

### Task 3: 塊 metadata + sidecar schema 自癒（FR-9）

- **ACTION**: `EmbeddingChunk` 加 `sourceTitle`/`sourcePath`；`ObsidianNoteIndexService` 寫入；`IndexState` 加必填 `schema`；全量重嵌起點清空**所有** obsidian 塊。
- **TEST FIRST**（`ObsidianNoteIndexTests.swift` 追加）:
  ```swift
  /// 🔴 AC-7：舊 sidecar（無 schema）→ 全量重嵌＋metadata 回填＋幽靈塊清理＋sidecar 寫回 schema:2。
  @MainActor
  func testSchemaBumpForcesFullReembedBackfillsMetadataAndClearsGhosts() async throws {
      let (ctx, embedder) = try makeInMemoryContextAndFakeEmbedder()
      let vault = try makeTempVault(files: ["工作/專案A.md": "內容甲"])
      let stateURL = vault.appendingPathComponent(".state.json")
      let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: ctx, stateURL: stateURL)
      // 幽靈：state 裡有、磁碟上沒有的檔的塊（同 model tag —— discardStale 不會清它）
      let ghostId = ObsidianNoteChunking.noteId(relativePath: "已刪/舊筆記.md")
      ctx.insert(EmbeddingChunk(transcriptionId: ghostId, chunkIndex: 0, text: "《舊筆記》幽靈",
          vector: EmbeddingClient.floatsToData([0.1, 0.2, 0.3]), dims: 3,
          embeddingModel: TranscriptIndexService.shared.model.tag, sourceKind: "obsidian",
          categoryId: nil, timestamp: Date()))
      try ctx.save()
      // 舊版 sidecar：無 schema 欄位（M8 出貨格式）
      let legacy = #"{"embeddingModel":"\#(TranscriptIndexService.shared.model.tag)","files":{"工作/專案A.md":"deadbeef","已刪/舊筆記.md":"cafebabe"}}"#
      try legacy.write(to: stateURL, atomically: true, encoding: .utf8)

      let n = try await svc.reindex(vaultRoot: vault, includeOnly: [], excluded: [])
      XCTAssertEqual(n, 1, "schema 不符 → 視為空 → 全量重嵌")
      let chunks = try ctx.fetch(FetchDescriptor<EmbeddingChunk>())
      XCTAssertFalse(chunks.contains { $0.text.contains("幽靈") }, "全量起點清掉幽靈塊")
      XCTAssertTrue(chunks.allSatisfy { $0.sourceTitle == "專案A" && $0.sourcePath == "工作/專案A.md" })
      let written = try String(contentsOf: stateURL, encoding: .utf8)
      XCTAssertTrue(written.contains(#""schema":2"#))
  }
  ```
  Run — expect FAIL（欄位不存在）
- **IMPLEMENT**:
  1. `AskAIModels.swift` — `EmbeddingChunk` 加 `var sourceTitle: String?` / `var sourcePath: String?`（optional、無預設值需求＝lightweight migration 安全），init 加 `sourceTitle: String? = nil, sourcePath: String? = nil` 參數（預設 nil → `TranscriptIndexService` 呼叫點零改動）；`sourceKind` 的 doc comment 補上 `| "obsidian"`（spec 揪過的漏）。
  2. `ObsidianNoteIndexService.swift`:
     - `IndexState` 加 `var schema: Int`（**必填非 optional**——舊 JSON 缺鍵直接 decode 失敗 = 天然的版本不符訊號，不用手寫比對）；檔內加 `static let sidecarSchema = 2`。
     - `loadState` guard 追加 `state.schema == Self.sidecarSchema`；`saveState` 寫入 schema。
     - `discardStaleNoteChunks(currentModelTag:)` 改名 `discardAllNoteChunks()` 並改語意：**刪全部 `sourceKind == "obsidian"` 塊（不分 model tag）**——呼叫點不變（仍在 `oldState.isEmpty` 分支）。doc comment 說明：oldState 空 = 「重建一切」，不清光會留下磁碟上已消失的筆記的幽靈塊（同 model tag 時 `RetrievalService` 檢索得到 → 拿已刪筆記回答）。
     - 插入塊時帶 `sourceTitle: title, sourcePath: file.relativePath`。
- **MIRROR**: SIDECAR_STATE。
- **GOTCHA**: 既有 `testEmbeddingModelSwitchForcesFullReembed` 必須維持綠——它寫的是**新版 API 產生的 sidecar**（有 schema），只有 model tag 不同，loadState 的兩個 guard 都要各自獨立生效。
- **VALIDATE**: TEST_COMMAND `-only-testing:VoiceInkTests/ObsidianNoteIndexTests` — 全數 PASS（含既有回歸鎖）。
- **COMMIT**: `feat(ask-ai): 筆記塊帶出處 metadata；sidecar schema:2 自癒（全量重嵌＋防幽靈塊）`

### Task 4: ChunkRef 帶 metadata + extractCitations（FR-10 前半）

- **ACTION**: `ChunkRef` 加 optional 欄位；`extractCitations` 從 chunk 帶入。
- **TEST FIRST**（`AskAIIndexTests.swift` 追加）:
  ```swift
  /// AC-9：M8 之前的三欄 JSON 必須照常 decode（新欄 nil）。
  func testChunkRefDecodesLegacyThreeFieldJSON() throws {
      let legacy = #"[{"transcriptionId":"00000000-0000-0000-0000-000000000001","chunkIndex":0,"excerpt":"舊引用"}]"#
      let refs = try JSONDecoder().decode([ChunkRef].self, from: Data(legacy.utf8))
      XCTAssertEqual(refs.first?.excerpt, "舊引用")
      XCTAssertNil(refs.first?.sourceTitle)
      XCTAssertNil(refs.first?.sourcePath)
  }
  @MainActor
  func testExtractCitationsCarriesNoteMetadata() throws {
      let chunk = EmbeddingChunk(transcriptionId: UUID(), chunkIndex: 0, text: "《專案A》內容",
          vector: Data(), dims: 0, embeddingModel: "m", sourceKind: "obsidian",
          categoryId: nil, timestamp: Date(), sourceTitle: "專案A", sourcePath: "工作/專案A.md")
      let refs = AskAIService.extractCitations(from: "答案 [1]", retrieved: [ScoredChunk(chunk: chunk, score: 1)])
      XCTAssertEqual(refs.first?.sourceTitle, "專案A")
      XCTAssertEqual(refs.first?.sourcePath, "工作/專案A.md")
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**: `ChunkRef` 加 `var sourceTitle: String?` / `var sourcePath: String?`（Codable optional = 舊 JSON 相容，零 CodingKeys 手工）；`AskAIService.extractCitations` 的 `ChunkRef(...)` 建構帶 `sourceTitle: chunk.sourceTitle, sourcePath: chunk.sourcePath`（`singleRecordingCitations` 不帶——單檔提問是逐字稿，恆 nil）。
- **MIRROR**: JSON_IN_RAW。
- **VALIDATE**: `-only-testing:VoiceInkTests/AskAIIndexTests` PASS。
- **COMMIT**: `feat(ask-ai): 引用鏈全程攜帶筆記出處（ChunkRef 舊格式相容）`

### Task 5: ObsidianRAGConfigStore（FR-5）

- **ACTION**: 新 store：vault override＋資料夾設定（鍵沿用）＋`effectiveVaultRoot()`。
- **TEST FIRST**（新檔 `VoiceInkTests/ObsidianRAGConfigStoreTests.swift`；UserDefaults 測試樣板鏡射 `MeetingCopilotConfigStoreTests`——setUp 清鍵、tearDown 還原）:
  ```swift
  @MainActor
  final class ObsidianRAGConfigStoreTests: XCTestCase {
      private let keys = ["notesRAGVaultBookmarkV1", "meetingCopilotNotesIncludeOnlyV1", "meetingCopilotNotesExcludedV1"]
      override func setUp() { super.setUp(); keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
      override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }; super.tearDown() }

      func testFolderKeysReuseMeetingCopilotKeysZeroMigration() {
          UserDefaults.standard.set(["工作"], forKey: "meetingCopilotNotesIncludeOnlyV1")
          UserDefaults.standard.set([".obsidian", "Archive"], forKey: "meetingCopilotNotesExcludedV1")
          let store = ObsidianRAGConfigStore()   // 測試用 internal init，鏡射 MeetingCopilotConfigStore
          XCTAssertEqual(store.includeOnlyFolders, ["工作"], "AC-10：既有值零遷移直接讀到")
          XCTAssertEqual(store.excludedFolders, [".obsidian", "Archive"])
      }
      func testExcludedDefaultsWhenUnset() {
          XCTAssertEqual(ObsidianRAGConfigStore().excludedFolders, [".obsidian", ".trash", "Templates"])
      }
      func testEffectiveVaultRootNilWhenNothingConfigured() {
          XCTAssertNil(ObsidianRAGConfigStore().effectiveVaultRoot())
      }
  }
  ```
  Run — expect FAIL（型別不存在）
- **IMPLEMENT**（新檔 `VoiceInk/Services/AskAI/ObsidianRAGConfigStore.swift`）:
  ```swift
  import Foundation

  /// 筆記 RAG 管線設定的單一權威來源（Ask AI 與 meeting-copilot 兩個消費者）。
  /// 資料夾兩鍵**沿用** meeting-copilot 時期的鍵名 —— 所有權搬家、資料零遷移。
  @MainActor
  final class ObsidianRAGConfigStore: ObservableObject {
      static let shared = ObsidianRAGConfigStore()

      private let vaultKey = "notesRAGVaultBookmarkV1"
      private let includeOnlyKey = "meetingCopilotNotesIncludeOnlyV1"
      private let excludedKey = "meetingCopilotNotesExcludedV1"

      /// 筆記專用 vault（security-scoped bookmark）。nil = 跟隨錄音匯出 vault。
      @Published private(set) var notesVaultBookmark: Data?
      @Published private(set) var includeOnlyFolders: [String] = []
      @Published private(set) var excludedFolders: [String] = [".obsidian", ".trash", "Templates"]

      init() {
          let d = UserDefaults.standard
          notesVaultBookmark = d.data(forKey: vaultKey)
          if let v = d.stringArray(forKey: includeOnlyKey) { includeOnlyFolders = v }
          if let v = d.stringArray(forKey: excludedKey) { excludedFolders = v }
      }

      /// 唯一的 vault 解析點：override 優先，nil 跟隨錄音 vault。四個消費者都走這裡。
      func effectiveVaultRoot() -> URL? {
          if let override = notesVaultBookmark {
              return VaultExportService.shared.resolveVaultRoot(override)
          }
          guard let bookmark = RecorderConfigStore.shared.vaultRootBookmark else { return nil }
          return VaultExportService.shared.resolveVaultRoot(bookmark)
      }

      func setNotesVaultBookmark(_ value: Data?) {
          notesVaultBookmark = value
          if let value { UserDefaults.standard.set(value, forKey: vaultKey) }
          else { UserDefaults.standard.removeObject(forKey: vaultKey) }
      }
      func setIncludeOnlyFolders(_ value: [String]) {
          includeOnlyFolders = value
          UserDefaults.standard.set(value, forKey: includeOnlyKey)
      }
      func setExcludedFolders(_ value: [String]) {
          excludedFolders = value
          UserDefaults.standard.set(value, forKey: excludedKey)
      }
  }
  ```
- **MIRROR**: CONFIG_STORE。
- **GOTCHA**: `excludedFolders` 的預設值只在**鍵未設定**時生效（`stringArray` 回 nil）——使用者清空成 `[]` 是合法狀態，不可用 `?? 預設` 蓋掉（`MeetingCopilotConfigStore.load` 的既有陷阱同款）。
- **VALIDATE**: `-only-testing:VoiceInkTests/ObsidianRAGConfigStoreTests` PASS。
- **COMMIT**: `feat(ask-ai): ObsidianRAGConfigStore — 筆記管線設定新家（鍵沿用零遷移）`

### Task 6: config 所有權搬移 + 消費端改接（FR-6）

- **ACTION**: `MeetingCopilotConfigStore` 移除 `notesIncludeOnlyFolders`/`notesExcludedFolders`（＋load/setter/鍵常數）；`MeetingCopilotLiveController.scheduleNotesReindex` 與 `MeetingCopilotSettingsView` 改讀 `ObsidianRAGConfigStore.shared`＋`effectiveVaultRoot()`。
- **TEST FIRST**: `MeetingCopilotConfigStoreTests` 裡資料夾相關測試**搬**到 `ObsidianRAGConfigStoreTests`（Task 5 已涵蓋語意）→ 這裡先刪舊測試中引用被移除欄位的段落，跑該 target 確認**編譯失敗清單**就是要改的呼叫點清單。
- **IMPLEMENT**:
  1. `MeetingCopilotConfigStore.swift`: 刪 `notesIncludeOnlyKey`/`notesExcludedKey` 常數、兩個 @Published、`load()` 對應段、兩個 setter。`useNotesRAG`/`notesInTechnicalRAG`/`aboutMeBrief` 不動。
  2. `MeetingCopilotLiveController.swift` `scheduleNotesReindex`:
     ```swift
     guard let vaultRoot = ObsidianRAGConfigStore.shared.effectiveVaultRoot() else { return }
     let includeOnly = ObsidianRAGConfigStore.shared.includeOnlyFolders
     let excluded = ObsidianRAGConfigStore.shared.excludedFolders
     ```
     （原 `RecorderConfigStore...vaultRootBookmark` 解析兩行刪除。）
  3. `MeetingCopilotSettingsView.swift`: `includeOnlyText`/`excludedText` 綁定改指 `ObsidianRAGConfigStore.shared`（本 task 只求編譯綠——UI 瘦身在 Task 10）。
- **VALIDATE**: 全 target 編譯 ＋ `-only-testing:VoiceInkTests/MeetingCopilotConfigStoreTests` PASS。
- **COMMIT**: `refactor(meeting-copilot): 筆記資料夾設定所有權移交 ObsidianRAGConfigStore`

### Task 7: stateURL 搬家 + 自動索引觸發（FR-8）

- **ACTION**: `notesIndexStateURL()` 從 `MeetingCopilotLiveController` 搬到 `ObsidianNoteIndexService.defaultStateURL()`（檔案路徑不變）；加 `autoIndexIfNeeded` single-flight 入口。
- **TEST FIRST**（`ObsidianNoteIndexTests.swift` 追加）:
  ```swift
  /// AC-11：single-flight —— 併發兩次 kick 只跑一次 reindex。
  @MainActor
  func testAutoIndexSingleFlight() async throws {
      let (ctx, embedder) = try makeInMemoryContextAndFakeEmbedder()
      let vault = try makeTempVault(files: ["a.md": "內容"])
      async let first: Void = ObsidianNoteIndexService.autoIndex(
          vaultRoot: vault, includeOnly: [], excluded: [],
          stateURL: vault.appendingPathComponent(".s.json"), modelContext: ctx, embedder: embedder)
      async let second: Void = ObsidianNoteIndexService.autoIndex(
          vaultRoot: vault, includeOnly: [], excluded: [],
          stateURL: vault.appendingPathComponent(".s.json"), modelContext: ctx, embedder: embedder)
      _ = await (first, second)
      XCTAssertEqual(embedder.embedCallCount, 1, "第二次 kick 撞 in-flight → no-op")
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**（`ObsidianNoteIndexService.swift` 追加）:
  ```swift
  // MARK: - 自動增量觸發（Ask AI 頁 onAppear／筆記 chip 開啟；attach 觸發沿用 scheduleNotesReindex）

  /// sidecar 路徑（原 MeetingCopilotLiveController.notesIndexStateURL，搬家不搬檔——路徑一字不差，
  /// 否則兩邊各記各的 hash，互看都是「全新 vault」，每次全量重嵌純燒錢）。
  static func defaultStateURL() throws -> URL {
      let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
          .appendingPathComponent("com.prakashjoshipax.VoiceInk")
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      return dir.appendingPathComponent("obsidian-index-state.json")
  }

  @MainActor private static var autoIndexInFlight = false

  /// 背景增量掃（single-flight、失敗靜默 log-only——與 scheduleNotesReindex 同紀律）。
  @MainActor
  static func autoIndex(vaultRoot: URL, includeOnly: [String], excluded: [String],
                        stateURL: URL, modelContext: ModelContext,
                        embedder: EmbeddingProviding = LiveEmbedder()) async {
      guard !autoIndexInFlight else { return }
      autoIndexInFlight = true
      defer { autoIndexInFlight = false }
      do {
          let svc = ObsidianNoteIndexService(embedder: embedder, modelContext: modelContext, stateURL: stateURL)
          let count = try await svc.reindex(vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded)
          Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AskAI")
              .notice("🗂️ Ask AI 筆記增量索引完成（重嵌 \(count, privacy: .public) 檔）")
      } catch {
          Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AskAI")
              .notice("🗂️ Ask AI 筆記增量索引失敗: \(error.localizedDescription, privacy: .public)")
      }
  }
  ```
  `MeetingCopilotLiveController`: 刪 `notesIndexStateURL()`，兩處呼叫（`runNotesReindex`、`MeetingCopilotSettingsView.reindexNotes`）改 `ObsidianNoteIndexService.defaultStateURL()`。
- **GOTCHA**: `autoIndex` 是 @MainActor static；`reindex` 內部已是 async——**不要**再包 `Task.detached`（呼叫端用 `Task { await … }` 即可，embed 的網路等待不佔 main thread）。
- **VALIDATE**: `-only-testing:VoiceInkTests/ObsidianNoteIndexTests` PASS；grep 確認 `notesIndexStateURL` 無殘留引用。
- **COMMIT**: `feat(ask-ai): 筆記索引自動增量觸發（single-flight）＋ sidecar 路徑歸位索引服務`

### Task 8: AskAIView 雙 chip + currentScope + 觸發接線（FR-2/FR-3/FR-13）

- **ACTION**: scope bar 換雙 chip；facet 只在語音庫開啟時顯示；@AppStorage 持久化；onAppear/chip 開啟觸發 autoIndex；header 文案改知識庫。
- **TEST FIRST**: scope 組合已在 Task 1 鎖死；本 task 是 view 接線——以編譯＋既有測試為 gate，行為驗證進 Task 12 手動清單。
- **IMPLEMENT**（`AskAIView.swift`）:
  1. 狀態:
     ```swift
     @AppStorage("askAIScopeTranscriptsV1") private var scopeTranscripts = true
     @AppStorage("askAIScopeNotesV1") private var scopeNotes = false
     @ObservedObject private var notesConfig = ObsidianRAGConfigStore.shared
     ```
  2. `scopeBar` 的非單檔分支改為：兩顆 chip（CHIP_STYLE 樣式；選中 = accent 填色＋checkmark，未選 = secondary 描邊）＋ `if scopeTranscripts { 原三個 picker }`。chip 點擊 handler:
     ```swift
     private func toggleChip(transcripts: Bool) {
         if transcripts {
             guard !(scopeTranscripts && !scopeNotes) else { return }   // 禁全關
             scopeTranscripts.toggle()
         } else {
             guard notesConfig.effectiveVaultRoot() != nil else { return }  // disabled 防線
             guard !(scopeNotes && !scopeTranscripts) else { return }
             scopeNotes.toggle()
             if scopeNotes { kickNotesAutoIndex() }   // FR-8：chip 由關轉開 → 增量掃
         }
     }
     ```
     筆記 chip 在 `effectiveVaultRoot() == nil` 時 `.disabled(true)` ＋ `.help("尚未設定筆記 vault — 到齒輪『筆記來源設定』選擇")`。
  3. `currentScope` 非單檔分支:
     ```swift
     let sources = AskAIScopeComposer.sources(transcriptsOn: scopeTranscripts, notesOn: scopeNotes, filter: sourceFilter)
     return AskAIScope(sources: sources,
                       categoryName: scopeTranscripts ? categoryNameFilter : nil,
                       dateRange: scopeTranscripts ? range : nil)
     ```
  4. `.onAppear` 追加 `if scopeNotes { kickNotesAutoIndex() }`；helper:
     ```swift
     private func kickNotesAutoIndex() {
         guard let vault = notesConfig.effectiveVaultRoot(),
               let stateURL = try? ObsidianNoteIndexService.defaultStateURL() else { return }
         let (include, exclude) = (notesConfig.includeOnlyFolders, notesConfig.excludedFolders)
         let ctx = modelContext
         Task { await ObsidianNoteIndexService.autoIndex(vaultRoot: vault, includeOnly: include,
                                                         excluded: exclude, stateURL: stateURL, modelContext: ctx) }
     }
     ```
  5. 文案: header infoMessage → 「用自然語言問你的知識庫（聽寫／錄音／會議／Obsidian 筆記）。…」；輸入框 placeholder → 「問你的知識庫……」。
- **MIRROR**: CHIP_STYLE；@AppStorage 用法鏡射同檔 `answerProviderRaw`。
- **GOTCHA**: 換來源清分類的既有 `.onChange(of: sourceFilter)` 保留；另加 `.onChange(of: scopeTranscripts) { if !$0 { categoryNameFilter = nil } }`（facet 藏起來時把殘值一併清掉，否則重開語音庫時舊分類悄悄生效）。
- **VALIDATE**: 全 target 編譯綠；`-only-testing:VoiceInkTests/AskAIScopeTests` PASS。
- **COMMIT**: `feat(ask-ai): scope bar 語音庫／Obsidian 筆記雙 chip＋自動索引觸發＋知識庫文案`

### Task 9: 引用回筆記 — URL builder + popup 分流（FR-10 後半）

- **ACTION**: `ObsidianLink` 純函式；`openCitation` 標題 fallback；`CitationPopup` 筆記變體。
- **TEST FIRST**（`AskAIScopeTests.swift` 追加）:
  ```swift
  func testObsidianOpenURLPercentEncodesPath() {
      let url = ObsidianLink.openURL(vaultRoot: URL(fileURLWithPath: "/Users/me/Vault"),
                                     relativePath: "工作/專案 A.md")
      XCTAssertEqual(url?.scheme, "obsidian")
      XCTAssertEqual(url?.host, "open")
      let s = url!.absoluteString
      XCTAssertTrue(s.contains("path="), s)
      XCTAssertFalse(s.contains(" "), "空白必須 percent-encoded")
      XCTAssertTrue(s.contains("%20") || s.contains("+"), s)
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**:
  1. `AskAIConfig.swift`（或 `ObsidianRAGConfigStore.swift` 檔尾）加:
     ```swift
     /// obsidian://open?path=<絕對路徑>。用 URLComponents 組（自動 percent-encode）。
     /// path 變體讓 Obsidian 自行解析所屬 vault（免 vault 名匹配）;vault 需曾在 Obsidian 開啟過。
     enum ObsidianLink {
         static func openURL(vaultRoot: URL, relativePath: String) -> URL? {
             var comps = URLComponents()
             comps.scheme = "obsidian"
             comps.host = "open"
             comps.queryItems = [URLQueryItem(name: "path",
                                              value: vaultRoot.appendingPathComponent(relativePath).path)]
             return comps.url
         }
     }
     ```
  2. `AskAIView.openCitation`: 標題 fallback 鏈改
     ```swift
     let title = match?.recorderTitle ?? match.map { String($0.text.prefix(24)) }
         ?? ref.sourceTitle ?? "來源"
     ```
  3. `CitationPopup`: `context.ref.sourcePath` 非 nil 時——header 圖示換 `doc.richtext`、隱藏「開啟完整逐字稿」、加:
     ```swift
     if let path = context.ref.sourcePath,
        let vault = ObsidianRAGConfigStore.shared.effectiveVaultRoot(),
        FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path),
        let url = ObsidianLink.openURL(vaultRoot: vault, relativePath: path) {
         Button { NSWorkspace.shared.open(url) } label: {
             Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
         }.controlSize(.small)
     }
     ```
     （檔案不存在／vault 未設 → 按鈕整個不出現，popup 仍顯示標題＋片段。）
- **GOTCHA**: `fileExists` 檢查要包 SECURITY_SCOPE（vault 是 security-scoped bookmark 解析出來的 URL）。
- **VALIDATE**: 測試 PASS＋編譯綠。
- **COMMIT**: `feat(ask-ai): 引用點回 Obsidian（obsidian://open?path=）＋筆記出處不再誤稱錄音`

### Task 10: 筆記來源設定 sheet（FR-7）

- **ACTION**: 新 view：vault 卡片＋兩個資料夾 multi-checkbox＋重建按鈕；齒輪選單加入口；`MeetingCopilotSettingsView.reindexNotes` 邏輯搬過來。
- **TEST FIRST**（`ObsidianRAGConfigStoreTests.swift` 追加——資料夾掃描 helper 是純邏輯）:
  ```swift
  func testFirstLevelFoldersScansDirectoriesOnly() throws {
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try FileManager.default.createDirectory(at: tmp.appendingPathComponent("工作"), withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: tmp.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
      try "x".write(to: tmp.appendingPathComponent("散檔.md"), atomically: true, encoding: .utf8)
      XCTAssertEqual(ObsidianVaultBrowser.firstLevelFolders(of: tmp), [".obsidian", "工作"],
                     "只列目錄、含 dot 目錄、排序；散檔不列")
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**（新檔 `VoiceInk/Views/AskAI/AskAINotesSettingsSheet.swift`）:
  1. helper（放檔頭，供測試）:
     ```swift
     enum ObsidianVaultBrowser {
         /// vault 第一層目錄名（含 dot 目錄、排序）。呼叫端自行包 security-scope。
         static func firstLevelFolders(of root: URL) -> [String] {
             let items = (try? FileManager.default.contentsOfDirectory(
                 at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
             return items
                 .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
                 .map(\.lastPathComponent).sorted()
         }
     }
     ```
  2. `AskAINotesSettingsSheet: View`（Form + Section 風格鏡射 `MeetingCopilotSettingsView`）:
     - **Vault section**: `LabeledContent("筆記 Vault")` 顯示 `effectiveVaultRoot()?.path`（truncationMode .middle）＋來源標籤（override 時「自訂」／否則「跟隨錄音匯出 Vault」）；「更換…」按 VAULT_PICKER 樣板寫 `notesConfig.setNotesVaultBookmark(bookmark)`；override 非 nil 時多一顆「改回跟隨錄音 Vault」→ `setNotesVaultBookmark(nil)`。皆未設定 → orange 提示（沿用 MeetingCopilotSettingsView:210 的措辭風格）。
     - **資料夾 section**: 兩顆 `Menu`（「只索引資料夾」「排除資料夾」），label 顯示摘要（空=「全部」／「N 個資料夾」），menu 內容 = `firstLevelFolders`（開 menu 時掃、包 SECURITY_SCOPE）每項一顆 checkmark Button toggle 進 store（鏡射 `AskAIView.categorySection` 的 checkmark Button 形狀）。vault 未設定 → 兩顆 Menu `.disabled(true)`。caption:「指定「只索引」後，vault 根目錄的散檔不會被索引。」
     - **索引 section**: 「重建筆記索引」按鈕＋progress＋結果訊息——邏輯整段從 `MeetingCopilotSettingsView.reindexNotes()` 搬入（`ObsidianNoteIndexService(modelContext:stateURL: try ObsidianNoteIndexService.defaultStateURL())` ＋ 訊息語彙一字不改：「已是最新（沒有檔案變動）」「已索引 N 檔」「需要 Gemini/OpenAI embedding 金鑰（Ask AI 設定）」）。caption:「索引需要 embedding 金鑰。進 Ask AI 頁或開啟筆記 chip 時會自動增量掃描（只重嵌改過的檔）。」
  3. `AskAIView.headerControls` 齒輪 Menu 加 `Divider()` ＋ `Button("筆記來源設定…") { showNotesSettings = true }`；`.sheet(isPresented: $showNotesSettings) { AskAINotesSettingsSheet().frame(width: 560, height: 520) }`。
- **MIRROR**: VAULT_PICKER＋SECURITY_SCOPE＋`categorySection` checkmark 形狀。
- **VALIDATE**: 測試 PASS＋編譯綠。
- **COMMIT**: `feat(ask-ai): 筆記來源設定 sheet（vault override＋資料夾 multi-checkbox＋重建索引）`

### Task 11: meeting 設定頁瘦身 + 診斷筆記分支（FR-11/FR-12）

- **ACTION**: `notesRAGSection` 只留消費開關＋自介＋導航連結；`diagnoseEmptyRetrieval` 加筆記分支。
- **TEST FIRST**（`AskAIAnswerTests.swift` 或 `AskAIIndexTests.swift` 追加——diagnose 是 `AskAIService` 私有 → 若不可測，抽成 internal static 純函式 `diagnoseEmptyRetrieval(scope:model:totalAll:forModel:obsidianCount:)` 再測）:
  ```swift
  func testDiagnoseNotesOnlyEmptyIndexPointsToNotesSettings() {
      let msg = AskAIService.emptyRetrievalMessage(
          scopeSources: ["obsidian"], totalAll: 50, forModel: 50, obsidianCount: 0,
          hasCategoryOrDateFilter: false)
      XCTAssertTrue(msg.contains("筆記"), msg)
      XCTAssertTrue(msg.contains("筆記來源設定") || msg.contains("重建"), msg)
  }
  ```
  Run — expect FAIL
- **IMPLEMENT**:
  1. `AskAIService`: 把 `diagnoseEmptyRetrieval` 的訊息判斷抽成 internal static `emptyRetrievalMessage(scopeSources:totalAll:forModel:obsidianCount:hasCategoryOrDateFilter:)` 純函式（原方法只負責 fetchCount 再委派）。新分支插在「forModel == 0」之後：
     ```swift
     if let sources = scopeSources, sources.contains(ObsidianNoteIndexService.sourceKind), obsidianCount == 0 {
         if sources == [ObsidianNoteIndexService.sourceKind] {
             return "筆記還沒有建立索引。到右上齒輪「筆記來源設定」選擇 vault 並按「重建筆記索引」。"
         }
         // 混合 scope 且筆記空：照常走既有訊息（轉錄塊可能只是沒命中），不誤導。
     }
     ```
  2. `MeetingCopilotSettingsView.notesRAGSection` 瘦身為：兩顆 Toggle＋自介 TextField＋
     ```swift
     Button { AppNavigator.shared.navigate(to: .askAI) } label: {
         Label("筆記索引設定（Ask AI）→", systemImage: "arrow.up.forward.app")
     }
     Text("Vault、資料夾範圍與重建索引已移到 Ask AI 頁的「筆記來源設定」。")
         .font(.caption).foregroundStyle(.secondary)
     ```
     刪除：vault LabeledContent、兩個 TextField、重建按鈕、`includeOnlyText`/`excludedText`/`indexing`/`indexMessage` @State、`reindexNotes()`、`vaultRoot` computed、`parseFolders`（grep 確認無他處引用後刪）。
- **VALIDATE**: 測試 PASS；`-only-testing:VoiceInkTests/AskAIServiceTests` 無回歸；編譯綠。
- **COMMIT**: `feat(ask-ai): 空檢索診斷筆記分支＋meeting 設定頁筆記區瘦身導流`

### Task 12: 全量驗證 + 手動清單

- **ACTION**: build＋全 target 測試＋手動驗證。
- **VALIDATE**:
  ```bash
  # 型別/編譯（產 app 進 .local-build，勿建到 /tmp——見 voiceink-build-verify skill）
  SWIFT_ENABLE_EXPLICIT_MODULES=NO xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
    -configuration Debug -derivedDataPath ./.local-build -xcconfig LocalBuild.xcconfig \
    CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
    CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' build \
    > /tmp/askai-notes-build.log 2>&1; grep -c "BUILD SUCCEEDED" /tmp/askai-notes-build.log
  # 全 target 測試（TEST_COMMAND 去掉 -only-testing）
  ```
- **手動清單**（真 vault＋真金鑰）:
  - [ ] 預設（筆記 chip 關）提問 → 引用全是錄音/聽寫（AC-1 實測）
  - [ ] 開筆記 chip → 首次自動增量掃（Console `🗂️`）→ 只問筆記能答（AC-2/AC-11）
  - [ ] 雙開＋分類篩選 → 筆記仍出現（AC-3）
  - [ ] 點筆記引用 → 標題正確＋「在 Obsidian 開啟」真的開到那篇（AC-8）
  - [ ] 換 vault override → 重建 → 查得到新 vault 內容；改回跟隨 → 行為回復（AC-10）
  - [ ] Meeting Copilot 設定頁連結跳到 Ask AI；開會 attach 的增量掃照常（Console `🗂️`）
- **COMMIT**: `test(ask-ai): notes-rag 全量驗證收尾`

---

## Testing Strategy

### Unit Tests

| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| `.all` 明確集合 | — | 三 kind，非 nil | 回歸鎖 |
| 組合純函式 | chip 四種組合 | 對應集合 | 全關=空集合 |
| facet 豁免 | obsidian＋dictation、category＋date | 只豁免 obsidian | 分類誤殺回歸 |
| schema 自癒 | 舊 sidecar＋幽靈塊 | 全量重嵌＋回填＋清幽靈＋schema:2 | 與 model-switch 鎖並存 |
| ChunkRef 相容 | 三欄舊 JSON | decode 成功、新欄 nil | 持久化資料 |
| store 鍵沿用 | 預設既有值 | 零遷移讀到 | excluded 空陣列合法 |
| single-flight | 併發 kick ×2 | 只跑一次 | |
| URL builder | 中文＋空白路徑 | percent-encoded | |
| 資料夾掃描 | 目錄＋dot 目錄＋散檔 | 只列目錄、排序 | |
| 空索引診斷 | 筆記 only＋0 塊 | 導流訊息 | 混合 scope 不誤導 |

### Edge Cases Checklist
- [ ] vault 未設定（chip disabled、sheet disabled、autoIndex no-op）
- [ ] excluded 清成空陣列（不可被預設值蓋掉）
- [ ] 舊 AskAIMessage 的三欄引用 JSON
- [ ] sidecar 檔損毀（decode 失敗 → 全量重嵌，冪等）
- [ ] 筆記檔已刪但引用還在（popup 藏「在 Obsidian 開啟」）

## Validation Commands

見 Task 12（compile check＋全 target 測試）。EXPECT: BUILD SUCCEEDED；全測試 PASS；deploy 由使用者 `! make deploy`。

## Acceptance Criteria
- [ ] SRS AC-1 ~ AC-13 全數有對應測試或手動清單項且通過
- [ ] 既有 `testEmbeddingModelSwitchForcesFullReembed` 與 `testReconcileOrphansPreservesObsidianChunks` 維持綠
- [ ] 全 target 測試零回歸；compile check BUILD SUCCEEDED

## Completion Checklist
- [ ] `notesIndexStateURL` 舊符號零殘留（grep）
- [ ] `AskAISourceFilter.sources` 無任何 nil 路徑殘留
- [ ] 文件：SPEC_ROADMAP 標 implemented＋plan 移 `docs/plans/completed/`＋（慣例）`/prp-spec` code-sync

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| schema bump 讓既有使用者升級後第一次掃描全量重嵌（費用＋時間） | H（必發生一次） | L | 個人規模＋free tier；完成後 sidecar 寫回 schema:2 不再觸發 |
| date 移出 predicate → 大索引 fetch-all 變慢 | L | L | personal scale（50k 塊 ≪100ms 已驗證）；真變慢再把「無筆記 scope」的查詢走舊 predicate 快路徑 |
| 雙 chip 狀態與 facet 殘值互咬（藏起來的分類還在生效） | M | M | Task 8 GOTCHA 的 onChange 清值＋手動清單驗證 |
| MeetingCopilotConfigStore 欄位移除漏改呼叫點 | L | L | 編譯期錯誤即清單（Task 6 流程刻意如此） |

## Notes
- Linear：repo config `skip: true`——不建 issue、不 push comment。
- 與 `meeting-copilot-m9-aboutme-replay-lifecycle.plan.md` 可平行實作（不同 worktree）：唯一共檔是
  `MeetingCopilotConfigStore.swift`（本 plan 刪資料夾欄位；M9 加 deepStyle 欄位——不同區塊，merge 衝突可自動解）。
