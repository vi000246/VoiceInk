---
linear_issue: null
---
# SRS: Meeting Copilot M8 — 筆記 RAG（aboutMe）+ auto-deep 閱讀保護 + 離線覆盤 + 即時翻譯

## Metadata
- **Module**: `meeting-copilot`
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source PRD**: N/A — 2026-07-13 使用者需求（設計討論定案於對話；Grill level: 1）
- **Source Linear Issue**: N/A（`docs/prp.config.yml` skip: true）
- **Created**: 2026-07-13
- **Plan**: `docs/plans/meeting-copilot-m8-notes-rag-auto-deep.plan.md`（2026-07-13，Mode B／balanced）

## Feature Summary

同一目標（「突然被問到我自己的事，腦袋空白；且要能調校辨識品質」）的三組綁定升級：
**(A) 個人筆記 RAG** — cue 分類新增 `aboutMe`（問我本人／我做過的專案／績效考核類），
這類 cue 的答案接地改為檢索使用者的 Obsidian 筆記，Tier 1 輸出「記憶錨點」助記詞。
**(B) auto-deep 與閱讀保護** — 最新 cue 的 Tier 1 顯示後自動接跑 Tier 2 並自動展開結果，
配套「閱讀保護」不變量（展開中的 cue 不被擠出／不被搶展開／不被取消）與展開 toggle 熱鍵。
**(C) 離線覆盤** — 錄音管理中**非即時來源**的錄音也能事後跑同一條 cue→tier 管線產生覆盤；
覆盤清單改為 debug 導向排序：有辨識、有回應的在最上，**漏抓掃描**找出的「未被辨識的
通用性問題」在最下，作為調校 cue 分類機制的迴圈。
**(D) 即時翻譯** — 對方每段 committed 逐字稿即時譯入目標語言（預設繁中；LLM 翻譯，
天然支援混語自動辨識），overlay 上方為翻譯字幕流、下方為 cue／回應區，明確視覺區隔；
三層回應一律以目標語言輸出。設定頁改為 tab 結構，新增「即時翻譯」tab。

## Delta from Current Module State

> 現有架構見 `docs/spec/meeting-copilot.spec.md`。本節只描述變更。

### New / Changed Data Models

| Model | 變更 | Migration |
|---|---|---|
| `MeetingCueKind` | 新增 `case aboutMe`（String-in-raw；舊資料 fallback `informational` 不受影響） | 無 schema 變更 |
| `MeetingLiveCue` | 新增 `searchHint: String = ""`（aboutMe 的檢索改寫，覆盤用）、`tier2TriggerRaw: String = ""`（`"auto"`/`"manual"`/空=未跑，成本歸因） | 有預設值 → lightweight |
| `MeetingLiveSession` | 新增 `sourceRaw: String = "live"`（`"live"`/`"replay"`；覆盤列表顯示「離線覆盤」badge）、`reviewSweepRaw: String = ""`（漏抓掃描結果 JSON，JSON-in-raw 慣例） | 有預設值 → lightweight |
| `MeetingLiveSegment` | 新增 `translatedText: String = ""`、`translationElapsedMs: Int = 0`、`translationError: String = ""`（remote 段的即時翻譯結果與觀測；覆盤可回看雙語） | 有預設值 → lightweight |
| `EmbeddingChunk`（ask-ai 所有） | **無 schema 變更**。新 `sourceKind` 值 `"obsidian"`；`transcriptionId` 對筆記存「vault 相對路徑 SHA-256 前 16 bytes」的**確定性 UUID**；`timestamp` = 檔案 mtime | 無 |
| 索引增量狀態 | **非 SwiftData**：sidecar JSON（Application Support，path → contentHash），遺失只代價全量重嵌 | — |
| `MeetingCopilotRunConfig`（JSON 快照） | 納入新開關與 aboutMe prompt 全文（覆盤錨點） | additive |

### Changed Business Logic

- `ResponseCueExtractor.systemPrompt`：四分類 → **五分類**。行為面試／績效考核（貢獻、成就、
  負責範圍、自我介紹、經驗題）從 `informational` **搬出**到 `aboutMe`；薪資／住址／寒暄／行政
  留在 `informational`。同一次呼叫對 aboutMe 額外輸出 `searchHint`（檢索改寫）——**零新增 LLM 呼叫**。
- `MeetingGroundingProviding.gather` 增加 `sources: Set<String>?` 參數，按 cue 種類路由檢索範圍。
- `AnswerCoordinator`：auto-deep 狀態機（最新 cue Tier 1 完成 → 自動 Tier 2）＋閱讀保護的取消語意
  （展開中 cue 的 in-flight Tier 2 不因新 cue 而取消）。
- `TranscriptIndexService.reconcileOrphans`：**跳過 `sourceKind == "obsidian"`**（否則任一次轉錄刪除
  會清空筆記索引）；`switchModel` 清索引後提供筆記重嵌入口。
- Overlay 展開狀態 `expandedCueId` 從 `CopilotOverlayView` 的 `@State` **升級到 controller 層**
  （熱鍵、自動展開、arranger 防擠出三方都要讀寫，view-local state 做不到）。
- 覆盤詳情頁（`MeetingSessionDetailSheet`）：cue 清單改三層排序（有回應 → 無回應 → 漏抓區）。
- 錄音管理詳情頁：無關聯 session 的錄音顯示「產生會議copilot覆盤」按鈕（離線 replay 入口）。
- 即時翻譯：remote committed 的**第二個獨立 consumer**（與 cue 抽取平行、互不阻塞、各自靜默容錯）；
  翻譯 prompt 純函式（自動辨識來源語言 → 譯入 `targetLanguage`；輸入已是目標語言則原樣輸出）。
- `CopilotOverlayView`：`liveTranslationEnabled` 時上方新增翻譯字幕區（最近 N 句、按 committedAt
  排序），與下方 cue／回應區以標題＋分隔線區隔；關閉時佈局完全不變。
- `MeetingCopilotSettingsView`：改為 tab 結構（「一般」＝現有全部內容原樣、「即時翻譯」＝新設定）。
- `TierPrompts`：所有 tier system prompt 附加輸出語言指示（= `targetLanguage`，預設繁中）。

### Explicitly Out of Scope

- Ask AI 聊天頁使用筆記檢索（索引就緒後 scope 可加，但本次不含 UI）。
- 筆記的 wiki-link／graph 結構檢索、本機 embedding 模型。
- vault 的 FSEvents 即時監看 —— 用「設定頁手動重建 + copilot attach 後背景增量掃描」。
- 技術 cue 預設接筆記（僅提供 opt-in 開關）。
- informational cue 的即時行為變更（覆盤排序不影響 overlay）。
- **離線覆盤不重跑 ASR／聲道分流**：「等同即時輔助」的等同性從**逐字稿之後**的管線開始
  （分段 → cue 抽取 → tier）。重演音訊既無聲道資訊（錄音筆為混音單聲道）也無必要。
- 離線覆盤的自動 Tier 2（deep 全跑太貴；覆盤頁點擊即跑，無即時壓力）。
- 翻譯 local（我方）串流（翻譯目的是幫我聽懂對方；我說的話不需要）。
- 專用翻譯 API（DeepL／Google Translate）—— 用既有 LLM provider 基建即可，混語辨識還更好。
- 逐 partial 的字幕級翻譯（等 committed 才譯：partial 會回改，譯了會閃爍浪費；committed
  延遲 ~1.5s 停頓切段，字幕體感可接受）。

## Functional Requirements

### A 組 — 個人筆記 RAG

- [ ] **FR-41 筆記索引器**：新 `ObsidianNoteIndexService`（形狀鏡射 `TranscriptIndexService`）。
  掃描 vault（**重用 `RecorderConfigStore.vaultRootBookmark`**，不新增 vault 位置設定）下的 `.md`
  → 去 YAML frontmatter → 每塊前綴 `《筆記標題》` → `TranscriptChunker.chunks`
  → `TranscriptIndexService.shared.model` 嵌入 → 存 `EmbeddingChunk(sourceKind: "obsidian")`。
  vault 未設定／無 embedding key → 整條靜默降級（不 throw、不跳 UI）。
- [ ] **FR-42 增量索引**：sidecar JSON 記 path → contentHash；只重嵌變更檔、刪除消失檔的 chunks
  （確定性 UUID 使 upsert = 取代式）。觸發：設定頁「重建索引」按鈕（全量）＋ copilot attach 後
  **背景**增量掃描（不阻塞會議啟動）。
- [ ] **FR-43 索引範圍設定**：`includeOnlyFolders: [String]`（空 = 全 vault）＋
  `excludedFolders: [String]`（預設 `[".obsidian", ".trash", "Templates"]`）。
- [ ] **FR-44 索引共存防護**：`reconcileOrphans` 不得刪除 obsidian chunks；`switchModel`
  清空索引後，設定頁的重嵌流程須涵蓋筆記（否則筆記 RAG 靜默失效）。
- [ ] **FR-45 aboutMe 分類**：`MeetingCueKind.aboutMe`。判準：**需要回憶「我做過什麼／我的貢獻／
  我的觀點」才能答的**（不限技術）→ `aboutMe`；純隱私資料（薪資、住址）／寒暄／行政 → 仍
  `informational`。aboutMe 與其他非 informational cue 同樣觸發三層回應（`ingest` 條件不變）。
- [ ] **FR-46 檢索改寫（searchHint）**：抽取 JSON 對 aboutMe cue 多輸出 `searchHint`
  （把模糊考核題改寫成筆記用語的檢索詞）；persist 至 cue；檢索 query 用 searchHint，空則退回 cue 原文。
- [ ] **FR-47 檢索路由**：`gather(sources:)` —— aboutMe cue → **強制** RAG、`sources = ["obsidian"]`
  （不看 `useHistoryRAG`；`useNotesRAG` 為總開關）；技術三類 cue → `useHistoryRAG` 開啟時
  `sources = ["dictation","recorder","meeting"]`（**明確排除筆記**，保持現行為），
  `notesInTechnicalRAG` 開啟時加 `"obsidian"`。
- [ ] **FR-48 aboutMe tier prompts**：Tier 1 變體 —— 鐵律「**只能使用筆記片段與 aboutMeBrief，
  沒記載的直接說筆記沒記**」；bullets 輸出記憶錨點（專案名／我的角色／具體貢獻／量化成果），
  不是論述句。Tier 2 變體 —— 完整回顧＋預判追問；`uncertainties` 語意改為
  「筆記沒覆蓋、需靠現場記憶的部分」。輸出格式與既有 parser 相容（OPENER+bullets / Tier2 JSON）。
- [ ] **FR-49 設定**：`MeetingCopilotConfigStore` 新增（`…V1` key + `set…()` 慣例）：
  `useNotesRAG: Bool = true`、`notesInTechnicalRAG: Bool = false`、`aboutMeBrief: String = ""`
  （常駐自介，檢索失敗時的保底事實）。設定頁「個人筆記 RAG」區段：vault 狀態（唯讀，指向
  錄音設定的 vault）、範圍欄位、索引統計（檔數／chunk 數／上次時間）、重建按鈕、
  無 embedding key 警告。索引 top-k 沿用 `ragK = 6`，不進設定。

### B 組 — auto-deep 與閱讀保護

- [ ] **FR-50 自動深度分析**：`autoDeepEnabled: Bool = true`。**只有最新 cue**（鏡射 Tier 1
  預跑的「只保最新」邏輯）在 Tier 1 完成後自動觸發 Tier 2；`tier2TriggerRaw = "auto"`。
  任何 cue 仍可手動點擊觸發（`"manual"`）。`prefetchEnabled == false` 時 auto-deep 也不生效
  （沒有 Tier 1 草稿就沒有 Tier 2）。
- [ ] **FR-51 自動展開**：auto Tier 2 完成 → 若目前**沒有**使用者展開中的 cue → 自動展開該
  cue 的分析；若使用者正在讀別則 → **不搶**，該 cue 只亮「分析完成」標記。
- [ ] **FR-52 展開 toggle 熱鍵**：新 `ShortcutAction`（四處註冊：`ShortcutAction` /
  `ShortcutMigration` / `RecordingShortcutManager` / `SettingsView`）。語意：有展開中 cue →
  收合；無 → 展開**最新一則有 tier 內容**的 cue。
- [ ] **FR-53 閱讀保護不變量**：展開中的 cue——
  (a) 不被 `maxCuesShown` 擠出（arranger 永遠保留展開者）；
  (b) 其 in-flight Tier 2 不被新 cue 的 auto-deep 取消；
  (c) 展開狀態不被自動展開搶走；
  (d) tier 內容寫入完成後不再變動（既有「串流累積完一次寫入」行為，鎖為驗收不變量）。
- [ ] **FR-54 觀測**：`tier2TriggerRaw` persist；auto-deep 的跳過原因（前 cue 展開保護中）
  記 log（🫆 系列），供覆盤成本歸因。

### C 組 — 離線覆盤與 debug 排序

- [ ] **FR-55 離線覆盤入口**：錄音管理詳情頁——該錄音**無**關聯 copilot session
  （`importFingerprint` 查無）時顯示「產生會議copilot覆盤」按鈕；已有 replay session 時
  照既有邏輯顯示「會議copilot覆盤」，另提供「重新產生」。
- [ ] **FR-56 離線 replay 管線**：從**既有逐字稿**（不重跑 ASR）分段——有 `speakerSegments`
  時以講者輪次為段（一輪一段，鏡射 live 的 per-committed 抽取），否則按句群切至與 live
  committed 相近的長度——逐段餵既有 `ResponseCueExtractor` → 去重 → persist
  `MeetingLiveSession(sourceRaw: "replay", importFingerprint: 該錄音, configSnapshotRaw: 當下設定)`
  ＋ cues ＋ segments（含抽取 provenance，與 live 同格式）→ 所有非 informational cue
  **序列**跑 Tier 1（aboutMe 含筆記接地；Tier 2 於覆盤頁點擊才跑）。
  執行中顯示進度（段數／cue 數），可取消；失敗中止不留半套 session（刪除未完成 session）。
- [ ] **FR-57 漏抓掃描（miss sweep）**：以**無主題過濾**的通用 prompt（「列出逐字稿中所有
  可能需要聽者回應的問題／指派／質疑」）掃描全逐字稿 → 與該 session 已 persist 的 cues 做
  `MeetingCueDeduplicator.jaccard` 匹配 → **未匹配項** = 漏抓候選，persist 至
  `session.reviewSweepRaw`（JSON：text＋sweep 建議分類＋匹配狀態）。離線覆盤自動執行；
  live session 的覆盤詳情頁提供「執行漏抓掃描」按鈕（事後補跑）。
- [ ] **FR-58 覆盤 debug 排序**：覆盤詳情頁 cue 清單三層——
  (1) 有 tier 回應的 cue（tier1 或 tier2 非空），依 askedAt；
  (2) 偵測到但無回應（informational、tier1 失敗），依 askedAt；
  (3) 漏抓區（`reviewSweepRaw` 未匹配項，標示 sweep 建議分類與「未被即時辨識」）。
  各層有標題分隔，層 (3) 明確標示為調校線索。
- [ ] **FR-59 session 來源標記**：`sourceRaw: "live" | "replay"`；覆盤列表對 replay 顯示
  「離線覆盤」badge。同一錄音允許**多次** replay（各帶當下 `configSnapshotRaw`）——
  這是 prompt 調校的 A/B 基礎；不自動刪舊 session。

### D 組 — 即時翻譯

- [ ] **FR-60 翻譯設定**：`MeetingCopilotConfigStore` 新增 `liveTranslationEnabled: Bool = false`、
  `translationProviderName: String?`／`translationModelName: String?`（nil = 跟隨 fast model；
  picker 鏡射 fast/deep 雙模型形態）、`translationSourceLanguage: String = "auto"`（顯示用提示，
  auto = 由 LLM 自動辨識）、`translationTargetLanguage: String = "zh-TW"`（繁中預設）。
  設定頁改 tab 結構：「一般」tab = 現有內容原樣；「即時翻譯」tab = 上述設定＋
  **混語 ASR 提示**（Parakeet auto 對中文會輸出亂碼——實測定案；混語會議建議選
  Nemotron Multilingual 或雲端多語模型）。
- [ ] **FR-61 翻譯管線**：`liveTranslationEnabled` 時，每段 remote committed 觸發一次
  非串流翻譯呼叫（prompt 純函式：**無論輸入語言**（可能中英混雜）譯入 `targetLanguage`；
  輸入已是目標語言則原樣輸出；只輸出譯文）。結果寫入 `MeetingLiveSegment.translatedText`
  並推入 overlay 翻譯區（按 `committedAt` 排序，不因完成先後亂序）。
  失敗靜默：該句顯示原文＋`translationError` persist。與 cue 抽取**平行、互不阻塞**。
- [ ] **FR-62 overlay 翻譯區**：開啟時 overlay 上方為翻譯字幕流（最近 N 句滾動，N 沿用
  `maxCuesShown` 或固定小值），下方為既有 cue／回應區；兩區以標題與分隔線**明確區隔**
  （使用者一眼可辨「這是翻譯」vs「這是辨識出的問題與回覆」）。關閉時佈局完全不變。
- [ ] **FR-63 回應語言**：所有 tier system prompt（含 aboutMe 變體）附加輸出語言指示
  = `translationTargetLanguage`（預設繁中）——與翻譯開關**無關**，恆生效（回應語言本就
  應可控；預設值即滿足「回應先用中文」）。
- [ ] **FR-64 翻譯觀測**：`translatedText`／`translationElapsedMs`／`translationError`
  persist 至 segment；覆盤詳情的逐段時間軸顯示雙語對照。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| aboutMe Tier 1 延遲 | 接地（embed 1 次 HTTP + 檢索 <100ms）+ fast model ≤ 約 3.5s | 檢索為暴力 dot product（個人規模）；embed 只打一次 |
| 技術 cue 零回歸 | 預設行為 bit-for-bit 不變 | `useHistoryRAG` 預設 false 不動；sources 明確排除 obsidian |
| 索引成本 | 增量掃描只重嵌變更檔；全量 batch 100 texts/req | contentHash diff；`EmbeddingClient.batchLimit` |
| auto-deep 成本 | deep 呼叫數 ≤ cue 數（僅最新一則自動） | 鏡射 prefetch 的 latest-only；`autoDeepEnabled` 可關 |
| 離線覆盤成本 | 只用 fast model（抽取＋Tier 1＋sweep）；deep 點擊才跑 | 序列執行、可取消；無即時壓力 |
| 翻譯延遲 | remote committed → 譯文上 overlay ≤ 2s | fast model 單句非串流；與 cue 抽取平行 |
| 翻譯成本 | 每 remote 段一次 fast 呼叫；預設關閉 | `liveTranslationEnabled = false` 預設 |
| 隱私 | 筆記／逐字稿僅本機儲存＋送使用者自選 provider | 與既有接地同一邊界 |
| 失敗語意 | 索引／檢索／replay 任何失敗靜默降級或明確中止，無半套資料 | 沿用 `ragError` 慣例；replay 失敗刪未完成 session |

## Architecture Notes

- **分類零成本**：aboutMe 分類與 searchHint 掛在既有 cue 抽取的單次 fast model 呼叫上，
  不新增任何 LLM 往返。A 組唯一的真正新元件是 `ObsidianNoteIndexService`。
- **重用 `EmbeddingChunk` 的兩個地雷**（FR-44 的由來）：`reconcileOrphans` 會把「沒有對應
  Transcription 的 chunk」全刪——obsidian chunks 永遠是孤兒；`switchModel` 清全索引。
  兩處都必須顯式處理，否則筆記索引會被靜默清空。
- **確定性 UUID**：`transcriptionId`（欄位名沿用，語意為 sourceId）= vault 相對路徑
  SHA-256 前 16 bytes。同檔重嵌自然取代、改名／刪除 = 舊 UUID 消失 → 刪其 chunks。
- **展開狀態升級**：`expandedCueId` 移到 controller（`@Published`），overlay view、熱鍵
  handler、`CopilotOverlayArranger`、auto-expand 邏輯共讀寫。「nil = 自動跟隨最新」語意保留。
- **取消語意**：現行 `deepTask?.cancel()`（新 requestDeep 取消前一個）改為：目標 cue 為
  展開中 cue 時不取消其在途 deep；auto-deep 對展開保護中的情境改為跳過並記 log（FR-54）。
- **離線 replay 的重用面**：`ResponseCueExtractor`／`MeetingCueDeduplicator`／
  `AnswerCoordinator`／persist 格式全部原樣重用——replay 只是把「committed 段」的來源從
  live ASR 換成逐字稿分段。`MeetingReplayDebugRunner`（DEBUG 選單）已驗證此接線，
  本功能將其產品化並移出 DEBUG。
- **sweep 與 cue 的匹配**：重用 `MeetingCueDeduplicator.jaccard`（bigram，中英混合穩健），
  門檻沿用 `defaultThreshold = 0.6`；sweep 是「偵測器的偵測器」，本身不觸發 tier。
- **翻譯 = remote committed 的第二個獨立 consumer**：與 cue 抽取同源不同 Task，任一失敗不
  影響另一方；LLM 翻譯天然處理混語（有人講中文、有人講英文），不需要語言偵測器。
  ASR 是翻譯品質的上限——混語會議的 ASR 模型選擇是既有已知取捨（見設定提示），非本功能可解。
- **vault 授權**：app 未沙盒（`app-sandbox=false`），但沿用既有 security-scoped bookmark
  存取模式（`VaultExportService.resolveVaultRoot` + `startAccessingSecurityScopedResource`）。

## Acceptance Criteria

> BDD Given/When/Then。測試檔沿用 `VoiceInkTests/` 既有命名。

### AC-28: 筆記索引產生正確的 chunks
- **Given**: 暫存 vault 內有一個含 YAML frontmatter 與多段落的 `.md`（fake embedder）
- **When**: 執行全量索引
- **Then**: 產生 `sourceKind == "obsidian"` 的 `EmbeddingChunk`；chunk 文字以 `《檔名標題》` 開頭、
  不含 frontmatter；`transcriptionId` 對同一路徑恆定
- **Test**: `VoiceInkTests/ObsidianNoteIndexTests.swift`

### AC-29: 增量索引只動變更檔
- **Given**: 已完成索引的 vault（fake embedder 計數歸零）
- **When**: 修改一檔、刪除一檔後增量掃描
- **Then**: 只有修改檔被重嵌（embedder 呼叫數 = 該檔 chunk 批次）；刪除檔的 chunks 消失；其餘不動
- **Test**: `ObsidianNoteIndexTests`

### AC-30: reconcileOrphans 不誤刪筆記索引
- **Given**: 索引內同時有 transcription chunks 與 obsidian chunks，且所有 Transcription 已刪除
- **When**: `reconcileOrphans()`
- **Then**: transcription 孤兒 chunks 被刪；obsidian chunks 完整保留
- **Test**: `AskAIIndexTests`

### AC-31: aboutMe 分類與 searchHint（golden）
- **Given**: 「你對 X 專案有什麼貢獻？」「自我介紹一下」「你覺得哪個專案最有成就感？」
- **When**: `ResponseCueExtractor.parse`（餵 golden JSON）與 prompt 建構
- **Then**: kind = `aboutMe` 且 `searchHint` 非空；「你的期望待遇？」→ `informational`；
  systemPrompt 含五分類定義與績效考核正例
- **Test**: `ResponseCueExtractorTests`

### AC-32: 檢索路由按 cue 種類分流
- **Given**: fake grounding／retrieval 記錄收到的 scope
- **When**: aboutMe cue 跑 Tier 1；技術 cue 在 `useHistoryRAG=true` 下跑 Tier 1
- **Then**: aboutMe → `sources == ["obsidian"]` 且 query 用 searchHint；技術 →
  `sources == ["dictation","recorder","meeting"]`（`notesInTechnicalRAG=true` 時才含 obsidian）
- **Test**: `GroundingTests`

### AC-33: aboutMe prompt 變體（golden）
- **Given**: aboutMe cue + 筆記片段 + `aboutMeBrief`
- **When**: `TierPrompts.tier1User/tier2User`（aboutMe 變體）
- **Then**: user prompt 含筆記片段與 brief；system prompt 含「只用筆記、沒記載就說沒記」鐵律
  與記憶錨點格式指示；Tier 2 的 uncertainties 指示為「筆記沒覆蓋的部分」
- **Test**: `TierPromptsTests`（新）或併入 `AnswerCoordinatorTests`

### AC-34: auto-deep 觸發與保護取消語意
- **Given**: `autoDeepEnabled=true`、fake streaming completer
- **When**: 新 cue Tier 1 完成
- **Then**: Tier 2 自動執行、`tier2TriggerRaw == "auto"`；
  **And Given** cue A 展開中且其 Tier 2 在途，**When** cue B 到達觸發 auto-deep，
  **Then** A 的 Tier 2 不被取消（完整寫回）
- **Test**: `AnswerCoordinatorTests`

### AC-35: 自動展開不搶閱讀
- **Given**: 無展開中 cue
- **When**: auto Tier 2 完成
- **Then**: `expandedCueId` = 該 cue；
  **And Given** 使用者已展開 cue A，**When** cue B 的分析完成，**Then** `expandedCueId` 仍為 A
- **Test**: `MeetingCopilotControllerTests`（狀態層，不測 SwiftUI）

### AC-36: 展開熱鍵 toggle 語意
- **Given**: 有展開中 cue → **When** 熱鍵 → **Then** 收合；
  **Given** 無展開且存在有 tier 內容的 cue → **When** 熱鍵 → **Then** 展開最新一則有內容者
- **Test**: 狀態層單元測試（熱鍵四處註冊由 `ShortcutMigration` 的 exhaustive switch 編譯把關）

### AC-37: 展開中 cue 不被擠出
- **Given**: 展開中 cue 依 `askedAt` 排序已落在 `maxCuesShown` 窗外
- **When**: `CopilotOverlayArranger.arrange`
- **Then**: 展開中 cue 仍在輸出清單
- **Test**: `CopilotOverlayArrangerTests`

### AC-38: 離線 replay 產生完整覆盤 session
- **Given**: 錄音管理一筆含逐字稿的 `Transcription`（fake completer 回 golden cue JSON 與 tier 回覆）
- **When**: 「產生會議copilot覆盤」
- **Then**: 產生 `MeetingLiveSession(sourceRaw == "replay")`、`importFingerprint` 關聯該錄音、
  segments 含抽取 provenance、非 informational cue 皆有 Tier 1 內容
- **Test**: `MeetingReplayReviewTests`（新）

### AC-39: replay 分段策略
- **Given**: 有 `speakerSegments` 的逐字稿／只有純文字的逐字稿
- **When**: replay 分段
- **Then**: 前者按講者輪次一輪一段；後者按句群切段（段數與內容可斷言）
- **Test**: `MeetingReplayReviewTests`

### AC-40: 漏抓掃描只留未匹配項
- **Given**: session 已有 3 則 cue；sweep（fake）回 5 題，其中 3 題與既有 cue Jaccard ≥ 0.6
- **When**: 執行漏抓掃描
- **Then**: `reviewSweepRaw` 僅含未匹配的 2 題（含建議分類）
- **Test**: `MeetingReplayReviewTests`

### AC-41: 覆盤三層排序
- **Given**: session 內混有「有 tier 回應」「informational／無回應」cues 與漏抓項
- **When**: 覆盤詳情頁排序（純函式抽出）
- **Then**: 順序為 有回應 → 無回應 → 漏抓，層內依 askedAt
- **Test**: `MeetingReplayReviewTests` 或 `MeetingLiveModelsTests`

### AC-42: 重複 replay 並存
- **Given**: 同一錄音已有一個 replay session
- **When**: 再次「重新產生」
- **Then**: 新 session 建立、舊 session 完整保留（各帶自己的 `configSnapshotRaw`）
- **Test**: `MeetingReplayReviewTests`

### AC-43: 翻譯管線寫回與順序
- **Given**: `liveTranslationEnabled=true`、fake completer（可控完成順序）
- **When**: 兩段 remote committed 依序到達、第二段的翻譯先完成
- **Then**: 兩段的 `translatedText` 皆寫回；overlay 翻譯 feed 按 `committedAt` 排序（不亂序）
- **Test**: `MeetingTranslationTests`（新）

### AC-44: 翻譯失敗靜默顯示原文
- **Given**: fake completer 對某段 throw
- **When**: 該段翻譯
- **Then**: 翻譯 feed 該句顯示原文、`translationError` 非空；cue 抽取照常執行（互不阻塞）
- **Test**: `MeetingTranslationTests`

### AC-45: 翻譯 prompt 混語與同語言行為（golden）
- **Given**: `targetLanguage="zh-TW"`、source="auto"
- **When**: 翻譯 prompt 建構（純函式）
- **Then**: prompt 含「無論輸入語言譯入繁體中文」「已是繁中則原樣輸出」「只輸出譯文」指示；
  指定 source 時 prompt 帶來源語言提示
- **Test**: `MeetingTranslationTests`

### AC-46: 回應語言指示恆生效
- **Given**: 任一 tier system prompt（含 aboutMe 變體）、`targetLanguage="zh-TW"`
- **When**: prompt 建構
- **Then**: system prompt 含以繁體中文輸出的指示（與 `liveTranslationEnabled` 無關）
- **Test**: `TierPromptsTests`

### AC-47: 翻譯開關不影響既有佈局與行為
- **Given**: `liveTranslationEnabled=false`（預設）
- **When**: remote committed 到達
- **Then**: 不發任何翻譯呼叫（fake completer 零呼叫）；overlay 無翻譯區
- **Test**: `MeetingTranslationTests`

## Open Questions

- [ ] searchHint 的改寫品質是否需要按 cue 細類（貢獻／成就／經驗）調校 —— 先上線收覆盤資料再定。
- [ ] 大 vault（>5k 檔）首次全量索引的 rate limit 體驗 —— backfill 進度 UI 已有前例，需要時再加。
- [ ] aboutMe 檢索是否納入 meeting 歷史逐字稿（v1 僅 obsidian；靠 `tier1PromptUser` 覆盤觀測召回缺口後決定）。
- [ ] 建議使用者在 vault 維護「成就清單」（brag document）筆記 —— 是否在設定頁給提示文案。
- [ ] 離線 replay 對混音（無講者）錄音會把「我」說的話也抽成 cue —— v1 接受（覆盤本來就是全檢視），
  未來若有 role-detected diarization 可加「排除我方講者」選項。
- [ ] 翻譯字幕流在長會議的 overlay 高度／捲動策略（先固定顯示最近數句，實測後調）。
- [ ] 翻譯是否需要串流輸出（v1 單句非串流；句子短、fast model 快，先驗證體感）。
