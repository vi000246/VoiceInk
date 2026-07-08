---
linear_issue: null
---
# Plan: 共用範本庫 + 導覽重構（WP1+WP2）

> Mode B（任務先測）。核心是**行為保留的重構**：合併兩個範本庫為單一 `TemplateStore`，範本 id 不變，
> 舊呼叫端透過 computed 視圖零改動；遷移任務用 in-memory 測試鎖定「保留綁定 + 冪等」。

## Summary
把語音範本庫（`AIEnhancementService.customPrompts`）與錄音範本庫（`RecorderConfigStore.recorderPrompts`）
合併成單一 `TemplateStore`；`CustomPrompt` 加 `categories: [TemplateCategory]`；語音/錄音模式編輯時用類別
多選篩選挑範本，讓範本跨兩種輸入共用。連帶側欄更名/分組（錄音範本→錄音模式、語音範本→共用範本移到
共用與系統、Recorder→Obsidian→錄音輸入、Ask AI 獨立群組）。

## User Story
As a 同時用語音輸入與錄音輸入的使用者, I want 一份範本能同時套用在語音模式與錄音模式, so that 不必在兩個
分開的庫維護重複範本。

## Problem → Solution
兩個分離的 UserDefaults 範本陣列（`customPrompts` / `recorderCategoryPromptsV1`）→ 單一共用庫 + 類別標籤；
舊綁定（模式 `selectedPrompt`、分類 `customPromptId`）靠範本 id 不變 + computed 視圖無感遷移。

## Metadata
- **Module**: templates
- **Parent Plan**: N/A
- **Source PRD**: N/A
- **Source Feature SRS**: docs/srs/templates-shared-library-and-ia.srs.md
- **Source Module Spec**: docs/spec/templates.spec.md
- **Source Linear Issue**: N/A
- **Type**: refactor ｜ **Size**: M ｜ **Complexity**: Medium
- **Rigor**: balanced ｜ **Mode**: B — 任務先測 ｜ **TDD**: on ｜ **Commit cadence**: per-task
- **Estimated Files**: ~12（8 modified + 2 created + tests）

---

## UX Design

### Before
```
側欄  Voice Input: 語音模式 / 語音範本 / 輸入歷史
      Recorder → Obsidian: 錄音裝置 / 錄音設定 / 錄音範本 / 錄音管理
      Shared & System: Models / Ask AI / … 
語音範本庫 ≠ 錄音範本庫（各自維護）
```
### After
```
側欄  Voice Input: 語音模式 / 輸入歷史（暫留，SRS-B 拆）
      錄音輸入: 錄音裝置 / 錄音設定 / 錄音模式 / 錄音管理
      Ask AI: Ask AI
      Shared & System: 共用範本 / Models / System Template / … 
單一共用範本庫;每範本標語音輸入/錄音輸入;模式編輯用類別多選篩選
```

### Interaction Changes
| Touchpoint | Before | After | Notes |
|---|---|---|---|
| 範本編輯器 | 只有標題/內容 | 加類別多選（語音輸入/錄音輸入） | 至少一類 |
| 語音模式範本 picker | 列語音範本庫 | 列含 .voiceInput 的範本 + 類別篩選切換 | 來源改共用庫 |
| 錄音分類範本 picker | 列錄音範本庫 | 列含 .recorderInput + 篩選 | 同上 |
| 側欄 | 見 Before | 見 After | 更名/分組 |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | docs/srs/templates-shared-library-and-ia.srs.md | all | 需求 + AC |
| P0 | docs/spec/templates.spec.md | all | 架構（不重新設計） |
| P0 | VoiceInk/Models/CustomPrompt.swift | all（1-50） | 加 categories 的目標 |
| P0 | VoiceInk/Services/AIEnhancement/AIEnhancementService.swift | 11-21, 43-47, 454-506 | customPrompts stored→computed；add/update/delete；savePrompts |
| P0 | VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift | 25, 78, 113-115, 239-275 | recorderPrompts + recorderPrompt(byId:)/upsert/delete |
| P1 | VoiceInk/Modes/ModeConfig.swift | 75, 160, 208 | selectedPrompt（id 綁定，不變） |
| P1 | VoiceInk/Services/RecorderAutomation/RecorderCategory.swift | 9 | customPromptId（不變） |
| P1 | VoiceInk/Views/PromptEditorView.swift | all | 範本編輯器加類別控制 |
| P1 | VoiceInk/Views/ContentView.swift | 4-23, 74-110 | ViewType 更名 |
| P1 | VoiceInk/Views/Sidebar/AppSidebar.swift | 74-97, 106-162 | 標題/分組/icon/style |
| P2 | 本 session `.askAI` 註冊 commit | — | 側欄 5 處改動經驗 |
| P2 | 記憶檔 voiceink-running-unit-tests / build / deploy | — | 測試/建置/部署鐵律 |

## External Documentation
No external research needed — 純內部重構。

---

## Patterns to Mirror

### PUBLISHED_USERDEFAULTS_STORE（TemplateStore 樣式）
```swift
// SOURCE: AIEnhancementService.swift:11-21, 43-47, 505-506（customPrompts didSet save）
@Published var customPrompts: [CustomPrompt] { didSet { savePrompts() } }
// load: if let data = UserDefaults.standard.data(forKey: "customPrompts"),
//          let decoded = try? JSONDecoder().decode([CustomPrompt].self, from: data) { self.customPrompts = decoded }
private func savePrompts() {
    if let encoded = try? JSONEncoder().encode(customPrompts) { UserDefaults.standard.set(encoded, forKey: "customPrompts") }
}
```

### RECORDER_PROMPT_CRUD（錄音側 CRUD 樣式）
```swift
// SOURCE: RecorderConfigStore.swift:265-275
func recorderPrompt(byId id: UUID?) -> CustomPrompt? {
    guard let id else { return nil }
    return recorderPrompts.first { $0.id == id }
}
func upsertRecorderPrompt(_ prompt: CustomPrompt) {
    if let i = recorderPrompts.firstIndex(where: { $0.id == prompt.id }) { recorderPrompts[i] = prompt }
    else { recorderPrompts.append(prompt) }
    saveRecorderPrompts()
}
```

### ADDITIVE_CODABLE（categories 向後相容）
```swift
// SOURCE: CustomPrompt.swift:26-32（decodeIfPresent 樣式）
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ...
    useSystemInstructions = try c.decodeIfPresent(Bool.self, forKey: .useSystemInstructions) ?? true
    // NEW: categories = try c.decodeIfPresent([TemplateCategory].self, forKey: .categories) ?? []
}
```

### ONE_TIME_MIGRATION_FLAG（遷移冪等）
```swift
// SOURCE: VoiceInk.swift（recorderDefaultsSeededV1 seed 慣例）
if !UserDefaults.standard.bool(forKey: "recorderDefaultsSeededV1") {
    RecorderConfigStore.shared.seedDefaultTemplates()
    UserDefaults.standard.set(true, forKey: "recorderDefaultsSeededV1")
}
```

### SIDEBAR_REGISTRATION（5 處 + assert）
```swift
// SOURCE: 本 session .askAI 註冊 — ViewType case + detailView routing + title + icon + sidebarIconStyle + sidebarSections
// AppSidebar.swift:92-97 sidebarSections;:74-89 title;:106-125 icon;:127-162 style（exhaustive，無 default，必加）
```

### TEST_STRUCTURE
```swift
// SOURCE: VoiceInkTests 慣例 — @MainActor XCTestCase；真 UserDefaults 存取用 save/restore defer
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| VoiceInk/Models/CustomPrompt.swift | UPDATE | 加 `categories` + `TemplateCategory` enum |
| VoiceInk/Services/Templates/TemplateStore.swift | CREATE | 單一共用庫 + 遷移 |
| VoiceInk/Services/AIEnhancement/AIEnhancementService.swift | UPDATE | customPrompts→computed；add/update/delete 轉呼 store |
| VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift | UPDATE | recorderPrompts→computed；recorderPrompt(byId:)/upsert/delete 轉呼 store |
| VoiceInk/Views/PromptEditorView.swift | UPDATE | 類別多選控制 |
| VoiceInk/Views/Settings/PromptsManagementView.swift | UPDATE | 共用範本頁顯示類別 chips |
| VoiceInk/Modes/ModeConfigEditorView.swift（或範本 picker 所在） | UPDATE | 語音模式範本 picker 類別篩選 |
| VoiceInk/Views/Settings/CategoriesSettingsView.swift | UPDATE | 錄音分類範本 picker 類別篩選 |
| VoiceInk/Views/ContentView.swift + Views/Sidebar/AppSidebar.swift | UPDATE | 側欄更名/分組/Ask AI 群組 |
| VoiceInk/VoiceInk.swift | UPDATE | 啟動呼叫 `TemplateStore.shared.migrateIfNeeded()` |
| VoiceInkTests/TemplateStoreTests.swift + TemplateMigrationTests.swift | CREATE | 遷移/篩選/共用測試 |

## NOT Building
- 輸入歷史拆分（SRS-B）;會議（SRS-C）;Ask AI 增強與範本頁（SRS-D，本 plan 只建 Ask AI 空群組移入現有 `.askAI`）。
- 雲端同步。

---

## Step-by-Step Tasks

### Task 1: `TemplateCategory` + `CustomPrompt.categories`
- **ACTION**: 加 enum 與 additive 欄位。
- **TEST FIRST**（`TemplateStoreTests`）:
  ```swift
  func testCustomPromptCategoriesCodableBackCompat() throws {
      // 舊 JSON（無 categories）解出 []
      let legacy = #"{"id":"\#(UUID().uuidString)","title":"T","promptText":"P","useSystemInstructions":true}"#.data(using: .utf8)!
      let p = try JSONDecoder().decode(CustomPrompt.self, from: legacy)
      XCTAssertEqual(p.categories, [])
      // round-trip 保留
      var p2 = p; p2.categories = [.voiceInput, .recorderInput]
      let back = try JSONDecoder().decode(CustomPrompt.self, from: JSONEncoder().encode(p2))
      XCTAssertEqual(back.categories, [.voiceInput, .recorderInput])
  }
  ```
  Run: `xcodebuild test … -only-testing:VoiceInkTests/TemplateStoreTests/testCustomPromptCategoriesCodableBackCompat` — FAIL
- **IMPLEMENT**（`CustomPrompt.swift`，鏡射 ADDITIVE_CODABLE）:
  - `enum TemplateCategory: String, Codable, CaseIterable, Equatable { case voiceInput, recorderInput }`
  - `var categories: [TemplateCategory]`（非 let，供編輯）;init 參數 `categories: [TemplateCategory] = []`
  - CodingKeys 加 `categories`;`init(from:)` `decodeIfPresent ?? []`;`encode` 寫入。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(templates): TemplateCategory + CustomPrompt.categories (additive)`

### Task 2: `TemplateStore` + 一次性遷移
- **ACTION**: 單一庫 + `migrateIfNeeded`。
- **TEST FIRST**（`TemplateMigrationTests`，真 UserDefaults save/restore defer）:
  ```swift
  @MainActor func testMigratesAndPreservesBindingsIdempotent() {
      let d = UserDefaults.standard
      // 備份三個 key
      let keys = ["customPrompts","recorderCategoryPromptsV1","sharedTemplatesV1"]
      let backup = keys.map { ($0, d.data(forKey: $0)) }
      defer { for (k,v) in backup { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } }; TemplateStore.shared.reload() }

      let voice = CustomPrompt(title: "V", promptText: "v")
      let rec = CustomPrompt(title: "R", promptText: "r")
      d.set(try! JSONEncoder().encode([voice]), forKey: "customPrompts")
      d.set(try! JSONEncoder().encode([rec]), forKey: "recorderCategoryPromptsV1")
      d.removeObject(forKey: "sharedTemplatesV1")

      TemplateStore.shared.migrateIfNeeded(); TemplateStore.shared.reload()
      XCTAssertEqual(TemplateStore.shared.template(byId: voice.id)?.categories, [.voiceInput])
      XCTAssertEqual(TemplateStore.shared.template(byId: rec.id)?.categories, [.recorderInput])
      let countAfterFirst = TemplateStore.shared.templates.count
      TemplateStore.shared.migrateIfNeeded()   // 冪等
      XCTAssertEqual(TemplateStore.shared.templates.count, countAfterFirst)
  }
  ```
  Run — FAIL
- **IMPLEMENT**（`TemplateStore.swift`，鏡射 PUBLISHED_USERDEFAULTS_STORE）:
  ```swift
  @MainActor final class TemplateStore: ObservableObject {
      static let shared = TemplateStore()
      @Published private(set) var templates: [CustomPrompt] = []
      private let key = "sharedTemplatesV1"
      private init() { load() }
      func reload() { load() }
      private func load() {
          if let data = UserDefaults.standard.data(forKey: key),
             let decoded = try? JSONDecoder().decode([CustomPrompt].self, from: data) { templates = decoded }
      }
      private func save() { if let e = try? JSONEncoder().encode(templates) { UserDefaults.standard.set(e, forKey: key) } }
      func templates(for category: TemplateCategory) -> [CustomPrompt] { templates.filter { $0.categories.contains(category) } }
      func template(byId id: UUID?) -> CustomPrompt? { guard let id else { return nil }; return templates.first { $0.id == id } }
      func upsert(_ p: CustomPrompt) {
          if let i = templates.firstIndex(where: { $0.id == p.id }) { templates[i] = p } else { templates.append(p) }
          save()
      }
      func delete(_ id: UUID) { templates.removeAll { $0.id == id }; save() }
      /// 首次無 sharedTemplatesV1 → 合併舊兩庫（舊 key 保留供 rollback）。冪等。
      func migrateIfNeeded() {
          guard UserDefaults.standard.data(forKey: key) == nil else { return }
          var merged: [CustomPrompt] = []
          if let d = UserDefaults.standard.data(forKey: "customPrompts"),
             let voice = try? JSONDecoder().decode([CustomPrompt].self, from: d) {
              merged += voice.map { var p = $0; p.categories = uniq(p.categories + [.voiceInput]); return p }
          }
          if let d = UserDefaults.standard.data(forKey: "recorderCategoryPromptsV1"),
             let rec = try? JSONDecoder().decode([CustomPrompt].self, from: d) {
              for var p in rec {
                  if let i = merged.firstIndex(where: { $0.id == p.id }) {   // 同 id 兩邊 → 合併類別
                      merged[i].categories = uniq(merged[i].categories + [.recorderInput])
                  } else { p.categories = uniq(p.categories + [.recorderInput]); merged.append(p) }
              }
          }
          templates = merged; save()
      }
      private func uniq(_ c: [TemplateCategory]) -> [TemplateCategory] { c.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } }
  }
  ```
- **IMPLEMENT（接線）**: `VoiceInk.swift` 啟動處（`RecorderConfigStore` seed 附近）加 `TemplateStore.shared.migrateIfNeeded()`——**須在** AIEnhancementService/RecorderConfigStore 首次讀範本前。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(templates): unified TemplateStore + idempotent one-time migration`

### Task 3: 語音側 computed 視圖
- **ACTION**: `AIEnhancementService.customPrompts` 由 stored 改 computed（讀 store 的 .voiceInput 子集）;add/update/delete 轉呼 store（保留方法簽名，零呼叫端改動）。
- **TEST FIRST**:
  ```swift
  @MainActor func testVoiceServiceReadsAndWritesSharedStore() {
      // 前置：store 有一個 .voiceInput 範本 → customPrompts 見得到；addPrompt → 進 store 且標 .voiceInput
      // （用 save/restore defer 保護 UserDefaults；斷言 AIEnhancementService.shared.customPrompts 反映 store）
  }
  ```
  Run — FAIL
- **IMPLEMENT**: 讀該檔確認所有 `customPrompts` 讀寫點（grep）。改：
  - `var customPrompts: [CustomPrompt] { TemplateStore.shared.templates(for: .voiceInput) }`（computed，移除 stored + didSet + load/savePrompts 對 "customPrompts" 的寫入；load 保留給遷移前相容——實際遷移後不再用）。
  - `addPrompt(...)`：建 `CustomPrompt(..., categories: [.voiceInput])` → `TemplateStore.shared.upsert`。
  - `updatePrompt`/`deletePrompt` → `upsert`/`delete`。
  - `repairModePromptSelections()`（:479）：確認仍以 id 比對，來源改 store（語音子集或全庫）。
  - `@Published` 消失後，UI 若依賴 objectWillChange：讓 view 觀察 `TemplateStore.shared`（`@StateObject`/`@ObservedObject`）。grep 用到 `customPrompts` 的 view，改觀察 store（或 service 轉發 store 的 objectWillChange）。**GOTCHA**：SwiftUI 綁定來源改變——plan 期逐一確認訂閱者。
- **VALIDATE**: 測試 PASS + 既有 mode 相關測試綠。
- **COMMIT**: `refactor(templates): voice prompts as computed view over shared store`

### Task 4: 錄音側 computed 視圖
- **ACTION**: `RecorderConfigStore.recorderPrompts` computed（.recorderInput 子集）;`recorderPrompt(byId:)` 查共用庫;upsert/delete 轉呼 store（標 .recorderInput）。
- **TEST FIRST**:
  ```swift
  @MainActor func testRecorderPromptsReadWriteSharedStore() {
      // store 有 .recorderInput 範本 → recorderPrompts 見得到；upsertRecorderPrompt → 進 store 標 .recorderInput
  }
  ```
  Run — FAIL
- **IMPLEMENT**: `recorderPrompts` → `TemplateStore.shared.templates(for: .recorderInput)`（移除 stored + saveRecorderPrompts 寫入）;`recorderPrompt(byId:)` → `TemplateStore.shared.template(byId:)`;upsert/delete 轉呼 store（新建時 `categories: [.recorderInput]`）。`RecorderCategory.customPromptId` 不動。
- **VALIDATE**: 測試 PASS + `RecorderPipelineTests` 綠。
- **COMMIT**: `refactor(templates): recorder prompts as computed view over shared store`

### Task 5: 範本編輯器類別多選
- **ACTION**: `PromptEditorView` 加類別多選控制（Toggle/chips），至少一類防呆。
- **TEST FIRST**: N/A（SwiftUI）——VALIDATE 手動 + build。
- **IMPLEMENT**: 讀 `PromptEditorView` 現有 state（title/promptText）;加 `@State categories: Set<TemplateCategory>`;儲存時寫入 `CustomPrompt.categories`（陣列化）;全空 → 依進入點預設（語音頁進入 `.voiceInput`、錄音頁 `.recorderInput`）。UI：兩個 Toggle「語音輸入」「錄音輸入」。
- **VALIDATE**: build 綠;手動編輯範本可勾類別並持久。
- **COMMIT**: `feat(templates): category multi-select in prompt editor`

### Task 6: 模式/分類範本 picker 類別篩選
- **ACTION**: 語音模式編輯（`ModeConfigEditorView` 的範本選擇）與錄音分類編輯（`CategoriesSettingsView`）的 picker 資料源已透過 Task 3/4 的 computed 視圖自動變成對應類別子集;再加一個「顯示全部類別」切換供跨類挑選。
- **TEST FIRST**: N/A（UI）。
- **IMPLEMENT**: 先 grep 兩處 picker 的資料源（`customPrompts` / `recorderPrompts`）確認已是子集;加一個 `@State showAllCategories` Toggle，開啟時資料源改 `TemplateStore.shared.templates`。
- **VALIDATE**: build 綠;手動：雙類範本在兩種模式 picker 都選得到（AC-2）。
- **COMMIT**: `feat(templates): category filter toggle in mode/category pickers`

### Task 7: 側欄 IA 重構
- **ACTION**: 更名 + 分組 + Ask AI 群組。
- **TEST FIRST**: DEBUG `assertSidebarItemsCoverAllCases`（既有）——build DEBUG 即驗。
- **IMPLEMENT**（鏡射 SIDEBAR_REGISTRATION）:
  - `AppSidebar.title`：`.categories` → 「錄音模式」;`.prompts` → 「共用範本」。
  - `sidebarSections`：`.prompts` 從 Voice Input 移到 Shared & System（放最前）;「Recorder → Obsidian」字串 → 「錄音輸入」;新增獨立區 `("Ask AI", [.askAI])`，並把 `.askAI` 從 Shared & System 移除。
  - `.history` 暫留 Voice Input（SRS-B 處理）。
- **VALIDATE**: DEBUG build 綠（assert 通過）;手動側欄外觀。
- **COMMIT**: `feat(templates): sidebar IA — renames, groups, Ask AI section`

### Task 8: 收尾
- **ACTION**: 全套 build+test;`docs/spec/templates.spec.md` Change History 加 implemented 行;bump build（兩處）;`make deploy`;回報 build 號;plan/SRS 移 completed/。
- **VALIDATE**: Settings→About 新 build;既有全套測試零回歸。
- **COMMIT**: `chore(templates): bump build, docs, deploy`

---

## Testing Strategy
| Test | Input | Expected | Edge |
|---|---|---|---|
| CodableBackCompat | 舊 JSON | categories==[] | round-trip |
| MigrateAndPreserve | 舊兩庫 | 各標對類別、綁定保留 | 同 id 合併 |
| MigrateIdempotent | 已遷移 | 不重複 | — |
| VoiceComputedView | store 有 .voiceInput | service.customPrompts 反映;add 標 .voiceInput | — |
| RecorderComputedView | store 有 .recorderInput | recorderPrompts 反映 | — |
| SharedVisibleBoth | 雙類範本 | 兩 picker 皆見 | — |

### Edge Cases Checklist
- [ ] 舊資料無 categories → []（遷移填一類）
- [ ] 同一 CustomPrompt id 兩庫都有（理論上無）→ 合併類別
- [ ] 範本全空類別 → 編輯器防呆至少一類
- [ ] 遷移後既有 mode selectedPrompt / category customPromptId 仍解析（AC-1）
- [ ] 側欄漏註冊 → DEBUG assert 掛

## Validation Commands
```bash
make local
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO -only-testing:VoiceInkTests
make deploy
```

### Manual Validation
- [ ] 升級後既有語音模式/錄音分類的範本綁定仍在、套用結果不變（AC-1）
- [ ] 建一個雙類範本 → 語音模式與錄音分類 picker 都選得到（AC-2）
- [ ] 類別篩選切換正確（AC-3）
- [ ] 側欄：共用範本在共用與系統、錄音模式、錄音輸入、Ask AI 群（AC-5）

## Acceptance Criteria
- [ ] SRS AC-1〜AC-5 通過;全套測試零回歸

## Risks
| Risk | L | I | Mitigation |
|---|---|---|---|
| computed 化破壞 UI 訂閱（objectWillChange 來源變） | M | H | Task 3 逐一確認訂閱者改觀察 TemplateStore;build+手動驗 |
| 遷移標錯類別 | L | M | 規則簡單;AC-1;舊 key 保留可 rollback |
| 側欄漏一處 | L | L | DEBUG assert |

## Notes
- 關鍵是「範本 id 不變 + computed 視圖」把重構半徑壓到最小;絕不改 `ModeConfig.selectedPrompt` / `RecorderCategory.customPromptId` 的語意。
- 舊 UserDefaults key（customPrompts / recorderCategoryPromptsV1）保留不刪，rollback 安全。
