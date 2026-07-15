---
linear_issue: null
---
# SRS: Ask AI RAG 檢索精準度（標頭語意化 + 查詢改寫 + 多輪上下文）

## Metadata
- **Module**: `ask-ai`
- **Module Spec**: `docs/spec/ask-ai.spec.md`
- **Source PRD**: N/A（由 2026-07-15 使用者實測回報驅動：問「今年爬過哪些山」引用全錯、follow-up 被當獨立問題）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-15

## Feature Summary

提升 Ask AI 對**筆記型語料**（尤其日記）的檢索命中率與多輪對話的上下文連貫性。三條主軸：索引端讓每個塊自帶語意標頭（內文標題、標籤、段落 heading），查詢端把口語問句改寫成帶時間與同義詞的檢索查詢，回答端把最近幾輪對話一起餵進生成。

## Delta from Current Module State

> 現有架構見 `docs/spec/ask-ai.spec.md`。本節只描述**改變**的部分。

### New / Changed API Endpoints

無對外 API。全部是模組內部函式契約變更。

### New / Changed Data Models

- **`EmbeddingChunk.text` 內容格式改變**（欄位不變）：筆記塊的標頭從 `《檔名》` 擴充為 `《檔名 + 內文標題 + 標籤》`，並在 heading-aware 切塊下於塊身前置 heading 麵包屑。
- **`ObsidianNoteIndexService.sidecarSchema` 2 → 3**：塊內容格式改變必須升版，觸發全 vault 一次性重嵌（既有自癒機制，`loadState` 回空 → `discardAllNoteChunks` → 重建）。逐字稿語料（`TranscriptIndexService`）**不受影響、不重嵌**。

### Changed Business Logic

1. **筆記切塊（`ObsidianNoteChunking`）**：新增 (a) 抽取 Dataview 行內標題 `標題::`、(b) 抽取標籤 `標籤::` / `#tag`、(c) heading-aware 切塊——依 markdown heading 分節、每塊前置該節 heading 路徑。塊標頭與塊身都納入嵌入。
2. **檢索查詢改寫（`AskAIService`）**：把上週的「同義詞擴展」單一 fast 呼叫升級為「多輪上下文感知的查詢改寫 + 同義詞擴展」——輸入含當前日期、最近 N 輪對話、當前問句，輸出一個獨立完整查詢 + 2-3 個同義變體；沿用 best-effort（失敗退回原問句）。
3. **回答帶對話歷史（`AskAIService.ask`）**：`buildUserBlock` 之外，把最近 N 輪 `AskAIMessage` 摘要注入 system/user，讓生成模型看得到 follow-up 的上文。

### Explicitly Out of Scope

- LLM reranker（檢索後重排）——每問多一次呼叫，成本考量暫不做。
- BM25 / 關鍵字混合檢索——工程量大，本輪不做。
- 從檔名 parse 日期做結構化日期過濾——改由查詢改寫把「2026」放進查詢文字達成等價效果，避免筆記日期欄位（檔案 mtime）不可信造成的不一致。
- 逐字稿（dictation/recorder/meeting）語料的切塊方式——不動，不重嵌。
- 會議 copilot 的即時接地與拒答紀律——完全不碰（即時場景不能靠猜，維持嚴格）。

## Functional Requirements

- [ ] **FR-1**：筆記塊標頭納入內文 `標題::` 值（有此行時）。日記檔名是日期，語意標題寫在內文，不抽出來檢索對不上。
- [ ] **FR-2**：筆記塊標頭納入標籤（`標籤::` 行與內文 `#tag`）。反例佐證：日記「大同大禮兩日」無「山」字，靠 `#Diary/Tag/爬山健行` 才標出是爬山。
- [ ] **FR-3**：heading-aware 切塊——筆記依 markdown heading（`#`~`######`）分節，塊不跨 heading 邊界，每塊塊身前置該節 heading 路徑麵包屑。無 heading 的筆記退化為現行段落切塊。
- [ ] **FR-4**：`sidecarSchema` 升版觸發全 vault 筆記重嵌；逐字稿索引不受影響。
- [ ] **FR-5**：檢索前用 fast 模型把問句改寫成「獨立、完整、帶時間與同義詞」的檢索查詢集；改寫看得到當前日期與最近 N 輪對話。
- [ ] **FR-6**：改寫 best-effort——未設定模型 / 呼叫失敗 / 解析失敗 → 退回原問句檢索，行為不劣於現況。
- [ ] **FR-7**：`ask` 回答時把最近 N 輪對話注入生成 prompt；follow-up 問題能理解上文。
- [ ] **FR-8**：改寫與歷史注入只作用於全庫檢索路徑（`ask`）；單檔提問（`askSingleRecording`）不套用（它本就不經向量檢索）。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 檢索召回（筆記聚合問題） | 「今年爬過哪些山」能引用到 ≥ 半數相關日記 | 標頭語意化（塊自帶山名+日期+tag）+ 查詢改寫（時間+同義詞）+ 既有多查詢聯集 |
| 首字延遲（Ask AI 非即時） | 改寫不新增呼叫（併入既有 fast 呼叫）；歷史注入 token 增量可忽略 | 改寫重用上週已加的 fast 呼叫；歷史截斷 ~3 輪 |
| 一次性重嵌成本 | < 1 USD、數分鐘、之後回到增量 | schema 升版一次全量，之後 hash 增量 |
| 退化安全 | 任何新路徑失敗 = 現況，不更差 | best-effort + 退回原問句；heading 解析失敗退回段落切塊 |
| 語料隔離 | 逐字稿/會議 copilot 零影響 | 只改 `ObsidianNoteChunking` 與 `AskAIService.ask` 全庫路徑 |

## Architecture Notes

- **標頭語意化在索引端一次性付費**：塊的向量在建索引時就把「檔名 + 標題 + 標籤 + heading」一起嵌進去，查詢時零額外成本。代價是塊標頭佔用 embedding 容量，但相對塊身數百字可忽略。
- **查詢改寫 vs 結構化過濾**：選查詢改寫（把「今年」→「2026 登山 健行」放進查詢文字），棄結構化日期過濾。理由：筆記 `timestamp` 是檔案 mtime（不可信，見既有 `RetrievalService` 註解對筆記日期的豁免），改寫用文字達成時間錨定更穩健且更簡單。
- **多查詢聯集已就緒**：`RetrievalService.retrieveUnion` / `fuseByMaxScore`（2026-07-15 已加）直接消費改寫產出的多個查詢向量，max-score fusion 讓「強配任一變體」的塊浮上來。本 SRS 只需把改寫接上去。
- **對話歷史雙路注入**：檢索端靠改寫把上文濃縮進查詢（治「撈錯塊」）；回答端靠歷史注入讓生成看得到上文（治「答錯理解」）。兩者互補，缺一不可。
- **schema 自癒是唯一重嵌觸發**：不需手動遷移腳本；升 `sidecarSchema` 常數即讓 `loadState` 判定舊 sidecar 不可信 → 全量重嵌（見 `ObsidianNoteIndexService.reindex` 對 `oldState.isEmpty` 的處理）。

## Acceptance Criteria

### AC-1: 日記塊標頭帶內文標題
- **Given**: 一篇日記檔名 `2026-03-16.md`，內文含 `標題::去爬小觀音山，約會吃串燒`
- **When**: 對它切塊
- **Then**: 每一塊的 `text` 標頭含「2026-03-16」與「去爬小觀音山」；用「爬過哪些山」的向量檢索能命中此塊
- **Test**: `VoiceInkTests/ObsidianNoteIndexTests.swift`（chunk 標頭斷言）

### AC-2: 無「山」字但有爬山標籤的日記可被檢索
- **Given**: 日記標題「大同大禮兩日」（無「山」字），標籤 `#Diary/Tag/爬山健行`
- **When**: 切塊
- **Then**: 塊標頭含「爬山健行」，使命中「登山/健行」類查詢成為可能
- **Test**: `ObsidianNoteIndexTests`（tag 併入標頭）

### AC-3: heading-aware 切塊不跨節、帶 heading 麵包屑
- **Given**: 一篇筆記含 `## solution\n<解法段>` 與 `## 時序\n<時序段>`
- **When**: 切塊
- **Then**: 解法段與時序段落在不同塊；解法塊塊身前置「solution」麵包屑；無 heading 的筆記結果與現行段落切塊一致
- **Test**: `ObsidianNoteIndexTests`（heading 分節 + 麵包屑；無 heading 回退）

### AC-4: schema 升版觸發全量重嵌、逐字稿不動
- **Given**: `sidecarSchema` 由 2 升到 3、既有 sidecar 是版本 2
- **When**: `loadState`
- **Then**: 回空 → 觸發筆記全量重嵌；`TranscriptIndexService` 的逐字稿塊不受影響
- **Test**: `ObsidianNoteIndexTests`（schema 不符 → loadState 空）

### AC-5: 查詢改寫把時間與同義詞放進檢索
- **Given**: 問句「今年爬過哪些山」、當前日期 2026-07-15
- **When**: 查詢改寫
- **Then**: 產出的查詢集含「2026」與「登山/百岳/健行」類詞；退回機制在解析失敗時給回原問句
- **Test**: `VoiceInkTests/AskAIServiceTests.swift`（改寫解析 + 退回）

### AC-6: follow-up 帶上文檢索
- **Given**: 第一輪問「今年爬過哪些山」，第二輪問「哪一次最累」
- **When**: 第二輪改寫
- **Then**: 改寫看得到第一輪，產出含「爬山/2026」上下文的查詢（而非只拿「哪一次最累」五個字檢索）
- **Test**: `AskAIServiceTests`（歷史注入改寫）

### AC-7: 回答理解 follow-up
- **Given**: 同 AC-6 的兩輪對話、檢索到爬山塊
- **When**: 生成第二輪回答
- **Then**: 生成 prompt 含最近數輪對話，回答針對「爬山中哪次最累」而非空泛回應
- **Test**: `AskAIAnswerTests`（歷史注入生成 prompt）

### AC-8: 改寫零新增呼叫、失敗不劣化
- **Given**: 改寫模型回無法解析的內容
- **When**: `ask`
- **Then**: 退回原問句單查詢檢索；答案照常產出（等同現況）
- **Test**: `AskAIAnswerTests`（改寫 garbage → 退回，沿用既有 `testQueryExpansionFallsBackGracefullyOnGarbage` 精神）

## Open Questions

- [ ] 對話歷史注入輪數 N 的最佳值（初值 3）——實測後校準。
- [ ] heading 麵包屑要不要含祖先層級（`# 大標 > ## solution`）還是只含最近一層——初版只含最近一層，長筆記深層再評估。
