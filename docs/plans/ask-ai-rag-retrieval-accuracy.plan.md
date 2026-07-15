---
linear_issue: null
---
# Plan: Ask AI RAG 檢索精準度（標頭語意化 + 查詢改寫 + 多輪上下文）

> `/prp-implement` 依 Metadata.Type 路由。checkbox：`[ ]` todo · `[~]` doing · `[x]` done。

## Summary
索引端讓每個筆記塊自帶語意標頭（檔名＋內文 `標題::`＋標籤＋heading 麵包屑）並 heading-aware 切塊；查詢端把口語問句改寫成帶日期與同義詞的檢索查詢；回答端注入最近數輪對話。修「今年爬過哪些山引用全錯」與「follow-up 被當獨立問題」。

## User Story
As a 用 Ask AI 問自己筆記的人，I want 問「今年爬過哪些山」和接續的 follow-up 都能撈到對的日記並連貫回答，so that 不用改用關鍵字硬湊也能問到答案。

## Problem → Solution
日記塊標頭只有日期（`《2026-03-16》`）、山名/標籤只在內文 → 向量對不上；查詢只看當前一句、無時間與上下文推理 → 撈錯塊＋follow-up 失憶。 → 塊標頭語意化 + heading-aware 切塊 + 上下文感知查詢改寫 + 對話歷史注入。

## Metadata
- **Module**: ask-ai
- **Parent Plan**: N/A
- **Source PRD**: N/A
- **Source Feature SRS**: `docs/srs/ask-ai-rag-retrieval-accuracy.srs.md`
- **Source Module Spec**: `docs/spec/ask-ai.spec.md`
- **Source Linear Issue**: N/A
- **Type**: feature
- **Size**: M
- **Complexity**: Medium
- **Rigor**: strict（塊內容格式變更觸發全 vault 重嵌 = 資料遷移）
- **Mode**: C — 步步為營
- **TDD**: on
- **Commit cadence**: per-task
- **Estimated Files**: 6（2 服務 + 4 測試）

---

## UX Design
### Before / After
Internal change — 無 UI 變動。使用者感知：問筆記（尤其日記/時間相關/follow-up）命中率提升；升級後首次進 Ask AI 或按「重建筆記索引」會全量重嵌一次。

### Interaction Changes
| Touchpoint | Before | After | Notes |
|---|---|---|---|
| 筆記索引 | 塊頭只有《檔名》 | 塊頭帶標題+標籤+heading | schema 2→3 自動全量重嵌 |
| Ask AI 提問 | 只看當前問句 | 改寫帶日期+近 3 輪對話 | 零新增呼叫（併入既有 fast 呼叫） |
| Ask AI 回答 | 只看當前問句 | 注入近 3 輪對話 | follow-up 連貫 |

---

## Mandatory Reading
| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `VoiceInk/Services/AskAI/ObsidianNoteIndexService.swift` | 7-32, 47-51, 82-96, 120-168 | `ObsidianNoteChunking` 純函式 + reindex/schema 自癒 |
| P0 | `VoiceInk/Services/AskAI/AskAIService.swift` | 106-260 | ask() 流程 + queryExpansions/augment（本次改寫接點） |
| P0 | `VoiceInk/Services/AskAI/TranscriptChunker.swift` | 12-71 | 切塊器（heading-aware 建於此之上） |
| P1 | `VoiceInk/Models/AskAIModels.swift` | 52-90 | AskAIThread/Message（歷史來源） |
| P1 | `VoiceInk/Services/AskAI/RetrievalService.swift` | 108-140 | fuseByMaxScore/retrieveUnion（改寫產出的多查詢直接餵） |
| P2 | `VoiceInkTests/ObsidianNoteIndexTests.swift` | all | 筆記切塊測試樣式 |
| P2 | `VoiceInkTests/AskAIAnswerTests.swift` | all | ask/歷史/改寫測試樣式（FakeEmbedder/BranchingCompleter） |

## External Documentation
No external research needed — 沿用既有內部 pattern（純函式切塊、best-effort LLM 呼叫、FakeEmbedder 測試）。

---

## Patterns to Mirror

### PURE_CHUNKING_FUNCTION
// SOURCE: ObsidianNoteIndexService.swift:19-24
```swift
static func chunks(title: String, body: String) -> [ChunkDraft] {
    TranscriptChunker.chunks(for: body).map {
        ChunkDraft(index: $0.index, text: "《\(title)》\n\($0.text)")
    }
}
```

### SCHEMA_SELF_HEAL
// SOURCE: ObsidianNoteIndexService.swift:47-51
```swift
/// sidecar 的格式版本。改變塊內容或塊欄位語意時必須 +1 —— loadState 回空 → 全量重嵌。
static let sidecarSchema = 2
```

### BEST_EFFORT_LLM_WITH_FALLBACK
// SOURCE: AskAIService.swift（queryExpansions / augmentWithExpandedQueries）
```swift
private func queryExpansions(for question: String) async -> [String] {
    guard let completer else { return [] }
    do { return Self.parseExpansions(try await completer.complete(system: ..., user: question)) }
    catch { logger.error(...); return [] }
}
```

### TOLERANT_JSON_PARSE
// SOURCE: AskAIService.swift（parseExpansions）— 剝 ```json fence、try? decode、失敗回 []

### MULTI_QUERY_FUSION
// SOURCE: RetrievalService.swift（fuseByMaxScore / retrieveUnion）— chunk 身分 transcriptionId#chunkIndex，保留最高分

### FAKE_EMBEDDER_TEST
// SOURCE: AskAIServiceTests.swift:6-15 — `FakeEmbedder(map:dims:)` 逐字對應向量、未映射回零向量

---

## Files to Change
| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/AskAI/ObsidianNoteIndexService.swift` | UPDATE | 塊標頭語意化（title+tags）、heading-aware 切塊、schema 2→3 |
| `VoiceInk/Services/AskAI/AskAIService.swift` | UPDATE | 查詢改寫（date+history）、回答注入歷史 |
| `VoiceInkTests/ObsidianNoteIndexTests.swift` | UPDATE | inlineTitle/tags/heading/displayTitle 測試 |
| `VoiceInkTests/AskAIAnswerTests.swift` | UPDATE | 歷史注入改寫/回答、退回測試 |
| `VoiceInkTests/AskAIServiceTests.swift` | UPDATE | parse 改寫、queryTerms 相容 |

## NOT Building
- Reranker、BM25、結構化日期過濾。
- 逐字稿切塊改動（不動、不重嵌）。
- 會議 copilot 接地/拒答。
- heading 麵包屑的多層祖先路徑（只含最近一層；深層留 Open Question）。

---

## Step-by-Step Tasks（Mode C）

### Task 1: 抽取內文標題 `inlineTitle` + `displayTitle`
**Files:** Modify `ObsidianNoteIndexService.swift`(enum ObsidianNoteChunking); Test `VoiceInkTests/ObsidianNoteIndexTests.swift`

- [ ] **Step 1: 失敗測試**
```swift
func testInlineTitleExtractsDataviewTitle() {
    XCTAssertEqual(ObsidianNoteChunking.inlineTitle(of: "標籤 :: #x\n標題::去爬小觀音山，約會吃串燒\n內文"), "去爬小觀音山，約會吃串燒")
    XCTAssertEqual(ObsidianNoteChunking.inlineTitle(of: "標題 :: 玉山主峰登頂失敗"), "玉山主峰登頂失敗")
    XCTAssertNil(ObsidianNoteChunking.inlineTitle(of: "沒有標題行\n只有內文"))
    XCTAssertNil(ObsidianNoteChunking.inlineTitle(of: "標題::   "))   // 空值不算
}
func testDisplayTitleCombinesFilenameAndInline() {
    XCTAssertEqual(ObsidianNoteChunking.displayTitle(filename: "2026-03-16", body: "標題::去爬小觀音山"), "2026-03-16 去爬小觀音山")
    XCTAssertEqual(ObsidianNoteChunking.displayTitle(filename: "如何改runway", body: "沒有標題行"), "如何改runway")   // 無行內標題 → 只檔名
}
```
Run: `xcodebuild ... build-for-testing`（下同）Expected: FAIL（no member inlineTitle）

- [ ] **Step 2: 實作**
```swift
/// 內文的 Dataview 行內標題（`標題::<值>` / `標題 :: <值>`）。日記檔名是日期，語意標題寫這行。
static func inlineTitle(of body: String) -> String? {
    for line in body.split(separator: "\n", maxSplits: 40, omittingEmptySubsequences: true) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("標題") else { continue }
        let after = t.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard after.hasPrefix("::") else { continue }
        let value = after.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
    return nil
}
/// 塊標頭用標題：檔名 +（行內標題，若有且不與檔名重複）。
static func displayTitle(filename: String, body: String) -> String {
    guard let inline = inlineTitle(of: body), inline != filename else { return filename }
    return "\(filename) \(inline)"
}
```
- [ ] **Step 3: 通過** → `git commit -m "feat(ask-ai): 筆記塊標頭抽入內文 Dataview 標題"`

### Task 2: 抽取標籤併入標頭 `noteTags`
**Files:** same

- [ ] **Step 1: 失敗測試**
```swift
func testNoteTagsExtractsDataviewAndInlineTags() {
    let body = "標籤 :: #Diary/Tag/爬山健行\n標題::大同大禮兩日\n今天走了 #郊山 步道"
    let tags = ObsidianNoteChunking.noteTags(of: body)
    XCTAssertTrue(tags.contains("爬山健行"))
    XCTAssertTrue(tags.contains("郊山"))
}
func testHeaderTextFoldsTitleAndTags() {
    let body = "標籤 :: #Diary/Tag/爬山健行\n標題::大同大禮兩日\n內文"
    let header = ObsidianNoteChunking.headerText(filename: "2026-02-22", body: body)
    XCTAssertTrue(header.contains("大同大禮兩日"))
    XCTAssertTrue(header.contains("爬山健行"), "無『山』字的爬山日記靠標籤才檢索得到")
}
```
- [ ] **Step 2: 實作**
```swift
/// 標籤：`標籤::` 行的 #tag 值 + 內文散落的 #tag。取末段（`#Diary/Tag/爬山健行` → `爬山健行`），去重、上限 6。
static func noteTags(of body: String) -> [String] {
    var out: [String] = []; var seen = Set<String>()
    func add(_ raw: Substring) {
        let last = raw.split(separator: "/").last.map(String.init) ?? String(raw)
        let v = last.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty, seen.insert(v).inserted { out.append(v) }
    }
    for m in body.ranges(of: try! Regex("#[\\p{L}0-9_/]+")) { add(body[m].dropFirst()) }
    return Array(out.prefix(6))
}
/// 塊標頭全文：《檔名 [行內標題] · tag1 tag2》。
static func headerText(filename: String, body: String) -> String {
    var parts = [displayTitle(filename: filename, body: body)]
    let tags = noteTags(of: body)
    if !tags.isEmpty { parts.append(tags.joined(separator: " ")) }
    return parts.joined(separator: " · ")
}
```
> GOTCHA：`Regex` 用 `try!` 是編譯期常量字面，永不 throw；若嫌 `try!` 刺眼可改字元掃描。
- [ ] **Step 3: 通過** → commit `feat(ask-ai): 筆記標頭併入標籤（無山字爬山日記靠 tag 命中）`

### Task 3: heading-aware 切塊
**Files:** same（`chunks(title:body:)` 改寫）

- [ ] **Step 1: 失敗測試**
```swift
func testHeadingAwareChunkingSplitsBySectionWithBreadcrumb() {
    let body = "## solution\nMerge 用 participant id 判斷\n\n## 時序\n開賽前 1 秒的細節"
    let drafts = ObsidianNoteChunking.chunks(title: "50 PIM-30721", body: body)
    // 兩節不在同一塊；解法塊帶 solution 麵包屑
    let sol = drafts.first { $0.text.contains("participant id") }!
    XCTAssertTrue(sol.text.contains("solution"))
    XCTAssertFalse(sol.text.contains("開賽前"), "不同 heading 的內容不該混進同一塊")
}
func testNoHeadingFallsBackToParagraphChunking() {
    let body = "第一段\n\n第二段"   // 無 heading
    let drafts = ObsidianNoteChunking.chunks(title: "T", body: body)
    XCTAssertFalse(drafts.isEmpty)
    XCTAssertTrue(drafts[0].text.hasPrefix("《T》"))   // 行為與現行一致
}
```
- [ ] **Step 2: 實作**（分節 → 每節各自 TranscriptChunker → 塊身前置 heading + 塊頭前置 headerText）
```swift
/// markdown heading 分節：回傳 [(breadcrumb, sectionBody)]；無 heading → 單一 ("", body)。
static func sections(of body: String) -> [(heading: String, body: String)] {
    var result: [(String, String)] = []
    var currentHeading = ""; var buf: [String] = []
    func flush() {
        let t = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { result.append((currentHeading, t)) }
        buf = []
    }
    for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = line.trimmingCharacters(in: .whitespaces)
        if let h = s.firstMatch(of: try! Regex("^#{1,6}\\s+(.+)$"))?.output[1].substring {
            flush(); currentHeading = String(h).trimmingCharacters(in: .whitespaces)
        } else { buf.append(String(line)) }
    }
    flush()
    return result.isEmpty ? [("", body)] : result
}

static func chunks(title: String, body: String) -> [ChunkDraft] {
    let header = headerText(filename: title, body: body)   // Task 2：檔名+標題+標籤
    var drafts: [ChunkDraft] = []
    for (heading, sectionBody) in sections(of: body) {
        for piece in TranscriptChunker.chunks(for: sectionBody) {
            let crumb = heading.isEmpty ? "" : "[\(heading)]\n"
            drafts.append(ChunkDraft(index: drafts.count, text: "《\(header)》\n\(crumb)\(piece.text)"))
        }
    }
    return drafts
}
```
> GOTCHA：`chunks` 呼叫端傳的 `title` 一直是檔名（`reindex` 用 `file.url.deletingPathExtension().lastPathComponent`），所以 `headerText(filename: title, body:)` 語意正確；不需改呼叫端。索引冪等（確定性 noteId + 取代式 upsert）不受影響。
- [ ] **Step 3: 通過** → commit `feat(ask-ai): heading-aware 筆記切塊（塊不跨節、帶 heading 麵包屑）`

### Task 4: schema 2→3 觸發全量重嵌
**Files:** `ObsidianNoteIndexService.swift:51`

- [ ] **Step 1: 失敗測試**（若既有測試斷言 schema==2 則同步改；否則加）
```swift
func testSidecarSchemaBumpedForHeaderChange() {
    XCTAssertEqual(ObsidianNoteIndexService.sidecarSchema, 3, "塊內容格式變更必須升版觸發全量重嵌")
}
```
- [ ] **Step 2: 實作**：`static let sidecarSchema = 3`；更新該行 doc comment 記「3 = 塊標頭語意化 + heading-aware 切塊（2026-07-15）」。
- [ ] **Step 3: 通過**（loadState 對舊版 sidecar 回空的既有測試應仍綠——只是版號數字變）→ commit `feat(ask-ai): sidecarSchema 3 — 標頭語意化重嵌`

### Task 5: 上下文感知查詢改寫（date + 對話歷史）
**Files:** `AskAIService.swift`；Test `AskAIServiceTests.swift` / `AskAIAnswerTests.swift`

- [ ] **Step 1: 失敗測試**（純解析沿用既有 parseExpansions；新增改寫 prompt 建構純函式測試）
```swift
func testRewritePromptCarriesDateAndHistory() {
    let p = AskAIService.rewriteUserBlock(
        question: "哪一次最累", now: isoDate("2026-07-15"),
        history: [("user","今年爬過哪些山"), ("assistant","玉山、嘉明湖…")])
    XCTAssertTrue(p.contains("2026-07-15"))
    XCTAssertTrue(p.contains("今年爬過哪些山"), "改寫要看得到上一輪")
    XCTAssertTrue(p.contains("哪一次最累"))
}
```
- [ ] **Step 2: 實作**：把 `queryExpansionSystemPrompt` 升級成「改寫器」；新增 `rewriteUserBlock(question:now:history:)` 純函式組 user block；`queryExpansions` 改名 `rewriteQueries(question:now:history:)`，system 用新 prompt、user 用 rewriteUserBlock。輸出仍 JSON 字串陣列（parseExpansions 不變）。
```swift
static let queryRewriteSystemPrompt = """
你是檢索查詢改寫器。根據「今天日期 + 最近對話 + 使用者問題」，產生 2-4 個**獨立、完整、可直接向量檢索**的查詢，
把口語問句補成不依賴對話也看得懂的樣子，並涵蓋同義詞/上位詞/具體實例與**相對時間的絕對化**
（例：今天 2026-07-15、問「今年爬過哪些山」→ ["2026 爬山 登山 健行","2026 百岳 縱走","2026 郊山 步道"]；
follow-up「哪一次最累」在爬山脈絡下 → ["2026 爬山 最累 玉山 嘉明湖","登山 體力 疲累"]）。
只輸出 JSON 字串陣列，不要解釋、不要 markdown。
"""
static func rewriteUserBlock(question: String, now: Date, history: [(role: String, text: String)]) -> String {
    var lines = ["今天日期：\(iso8601Day(now))"]
    if !history.isEmpty {
        lines.append("最近對話：")
        for m in history.suffix(6) { lines.append("\(m.role == "assistant" ? "AI" : "我")：\(String(m.text.prefix(200)))") }
    }
    lines.append("使用者問題：\(question)")
    return lines.joined(separator: "\n")
}
```
> GOTCHA：`ask()` 短路契約（空索引不呼叫 LLM）**必須保留**——先 `base` 檢索，空則短路（不呼叫改寫）；非空才呼叫改寫。改寫產出與 `base` 一起丟 `fuseByMaxScore`。best-effort：改寫失敗/解析空 → 只用 base（等同現況）。
- [ ] **Step 3: 通過** → commit `feat(ask-ai): 上下文感知查詢改寫（日期絕對化 + 對話脈絡）`

### Task 6: 回答注入對話歷史
**Files:** `AskAIService.swift`（ask/buildUserBlock）；Test `AskAIAnswerTests.swift`

- [ ] **Step 1: 失敗測試**
```swift
func testAnswerPromptIncludesConversationHistory() async throws {
    // 兩輪：先問山、再 follow-up；completer 記錄收到的 user block
    // 斷言第二輪的 user block 含第一輪問句（歷史注入）
}
```
- [ ] **Step 2: 實作**：`ask()` 在插入當前 user 訊息**前**擷取 `priorMessages`（thread.messages 依 createdAt）；傳給 `rewriteQueries` 與 `buildUserBlock`。`buildUserBlock` 加 `history:` 參數，在「問題:」前插入「先前對話（僅供理解上下文）：…」。
> GOTCHA：`priorMessages` 必須在 `context.insert(AskAIMessage(...user...))` **之前**擷取，否則當前問句自己會混進歷史。單檔提問路徑（`askSingleRecording`）不套用。
- [ ] **Step 3: 通過** → commit `feat(ask-ai): 回答注入近數輪對話（follow-up 連貫）`

### Task 7: 接線 ask() + 退回測試 + build verify
- [ ] **Step 1**：`ask()` 串起 Task 5/6（base→短路 or 改寫→union→帶史生成）。
- [ ] **Step 2**：退回測試——改寫回 garbage → 只用 base、答案照常（沿用 `testQueryExpansionFallsBackGracefullyOnGarbage` 精神，rename 適配）。
- [ ] **Step 3**：`build-for-testing` 綠 → commit `test(ask-ai): 改寫退回 + 歷史注入整合`

---

## Testing Strategy
### Unit Tests
| Test | Input | Expected | Edge? |
|---|---|---|---|
| inlineTitle | `標題::去爬小觀音山` | `去爬小觀音山` | 空值→nil ✓ |
| noteTags | `#Diary/Tag/爬山健行` | 含 `爬山健行` | 末段抽取 ✓ |
| headerText | 大同大禮兩日+爬山健行 tag | 含標題+tag | 無山字命中 ✓ |
| sections | `## solution … ## 時序` | 兩節分塊 | 無 heading 回退 ✓ |
| schema | — | `== 3` | — |
| rewriteUserBlock | 問句+日期+史 | 含三者 | 空史 ✓ |
| history 注入 | 兩輪對話 | 第二輪 block 含第一輪 | 插入順序 ✓ |
| 改寫退回 | garbage reply | 只用 base、答案照常 | 不劣化 ✓ |

### Edge Cases Checklist
- [ ] 無 `標題::`/無標籤/無 heading 的筆記 → 行為同現行
- [ ] 空 body / 只有 frontmatter → drafts 空（既有行為）
- [ ] 新 thread（無歷史）→ 改寫/回答不加歷史段
- [ ] 空索引 → 短路、不呼叫改寫 LLM（保 `testEmptyRetrievalShortCircuits`）

---

## Validation Commands
### Build / Tests（host-app 測試未簽章 headless 會 crash → 用 build-for-testing 編譯驗證，執行交使用者）
```bash
SWIFT_ENABLE_EXPLICIT_MODULES=NO xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk \
  -configuration Debug -derivedDataPath ./.local-build -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) LOCAL_BUILD' build-for-testing
```
EXPECT: `TEST BUILD SUCCEEDED` / 無 ` error: `

### Manual Validation（deploy 後）
- [ ] 設定頁按「重建筆記索引」→ 全量重嵌跑完（schema 3）
- [ ] 問「今年爬過哪些山」→ 引用命中 2026 爬山日記（玉山/嘉明湖/五分山/小觀音山…）
- [ ] follow-up「哪一次最累」→ 回答仍在爬山脈絡、引用正確

---

## Acceptance Criteria
- [ ] 對應 SRS AC-1~AC-8 全部有測試覆蓋（view 層無涉）
- [ ] build-for-testing 綠、無 type error
- [ ] 逐字稿/會議 copilot 路徑零改動
- [ ] 改寫失敗退回 = 現況，不劣化

## Completion Checklist
- [ ] 塊切法遵循 `ObsidianNoteChunking` 純函式 pattern
- [ ] LLM 呼叫沿用 best-effort + tolerant parse
- [ ] 測試沿用 FakeEmbedder/BranchingCompleter，不碰 `UserDefaults.standard`
- [ ] schema 升版註解說明原因
- [ ] 無 placeholder

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| 全 vault 重嵌一次性成本/時間 | H | L | 個人規模 <1 USD/數分鐘；增量恢復；使用者已知同意 |
| heading 正則吃掉非 heading 的 `#tag` 行 | M | M | 正則錨 `^#{1,6}\s+`（空白必需）→ `#tag` 無空白不誤判；測試鎖 |
| 改寫把問句改歪、命中變差 | M | M | 與 base 做 union（max-score），base 仍保底；best-effort 退回 |
| 歷史注入讓 token/成本上升 | L | L | 截斷近 6 則 × 200 字 |
| Regex `try!` 在極端輸入 throw | L | M | 字面 pattern 編譯期固定，永不 throw；或改字元掃描 |

## Notes
- schema 自癒是唯一遷移路徑（無腳本）。逐字稿索引獨立不動。
- 改寫重用上週已加的 fast 呼叫（`queryExpansions`），非新增呼叫——只升級 prompt 與輸入。
- 會議 copilot 的 `ResponseCueExtractor`/`TierPrompts` 嚴格紀律不受本 plan 影響。
