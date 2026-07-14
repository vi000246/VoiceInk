---
linear_issue: null
---
# SRS: Meeting Copilot M9 — aboutMe 嚴格接地 + 覆盤生命週期 + 深答風格

## Metadata
- **Module**: `meeting-copilot`
- **Module Spec**: `docs/spec/meeting-copilot.spec.md`
- **Source PRD**: N/A（standalone 技術任務 — 2026-07-14 使用者需求；訪談以對話代替）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-14
- **Plan**: `docs/plans/meeting-copilot-m9-aboutme-replay-lifecycle.plan.md`

## Feature Summary

三組修正：**(A) aboutMe 嚴禁幻覺**——使用者實測：筆記索引還沒建，aboutMe cue 照樣「亂回答」。修法是結構性的：接地結果零筆記片段 → **不呼叫 LLM**，直接回「筆記沒有記載」；有片段 → 簡潔條列記憶錨點（1~3 條、不足不硬湊）；aboutMe 一律**不進 Tier 2**（auto 與手動皆守門）。**(B) 覆盤生命週期**——覆盤 session 標題連動錄音管理的錄音名稱（以 `importFingerprint` 關聯、顯示時 live lookup → 改名自動反映）；刪錄音 → 該錄音的 **live 與 replay session 全刪**；**同一錄音的 live 與 replay 不同時並存**（有 live 紀錄時不提供補做；把 live 紀錄刪掉後即可離線覆盤——狀態判斷，非永久規則）；離線覆盤改為**背景佇列執行**，錄音管理與覆盤頁雙邊顯示「覆盤中」tag，完成即除。**(C) 深答風格可調**——開會對話中沒時間讀大段文字：Tier 2 輸出新增風格設定（條列式／簡潔／詳細），預設改為**關鍵詞開頭短條列**（3 秒掃視為設計目標），JSON 契約與 parser 不動。

## Delta from Current Module State

> 現有架構見 `docs/spec/meeting-copilot.spec.md`。本節只描述變更。

### As-Is 現況（經 code 核對）

| 現況 | 問題 |
|---|---|
| `AnswerCoordinator.runTier1`：aboutMe 走筆記 RAG（`sources=["obsidian"]`），但 `ragExcerpts` 空**不擋**，照樣呼叫 fast model → prompt 裡只剩 cue 原句，模型自由發揮（`AnswerCoordinator.swift:131-147`） | **幻覺來源**：無索引/無 vault/檢索無命中時，答案全是編的 |
| `tier1SystemAboutMe` 要求「恰 3 bullets」（`TierPrompts.swift:46`） | 筆記只撐得起 1 條時，硬湊滿 3 條 = 逼模型編造 |
| auto-deep 不分 cue 種類（`runTier1` 完成 → `runAutoDeep`）；`requestDeep` 也不分；`tier2SystemAboutMe`/`tier2UserAboutMe` 變體存在 | 使用者明示 aboutMe 不需要深模型第二層判斷 |
| 覆盤列表標題 = 純日期組字（`MeetingRowDisplay.title(startedAt:)`：「7月12日 14:30 會議」） | 看不出是哪場錄音；錄音改名不反映 |
| `MeetingLiveSession.importFingerprint` 已存在（live 匯入回填；replay 由 `makeSession` 寫入）；`.transcriptionDeleted`（object: nil 批次訊號）由 `TranscriptionStore` 發送；**無任何 session reconciler** | 刪錄音 → session 變永久孤兒 |
| 錄音詳情 `copilotReviewButtons`：只要 fingerprint 對得到任一 session 就顯示「查看＋重新產生」；對不到顯示「產生」（`RecorderHistoryView.swift:988-1017`） | live 存在時仍可補做 replay——使用者定調兩者互斥 |
| 覆盤產生跑在**詳情 sheet 的 `@State` service**（`RecorderHistoryView.swift:945,1034-1069`）；進度只顯示在 sheet 按鈕區；兩個列表皆無跑動中標記 | 關掉 sheet 進度全失；背景不可見 |
| Tier 2 輸出格式固定（`tier2System` 單一格式指示：段落 analysis＋followUps＋uncertainties） | 開會對話中一次讀不完大段分析；無法按場合調整密度 |

### New / Changed Data Models

**無 schema 變更。** `MeetingLiveSession.importFingerprint` 既有欄位就是關聯鍵；標題採顯示時解析（不存副本）；「覆盤中」是執行期狀態（新單例的 @Published，不落盤）。

### New / Changed Components

| Component | Change |
|---|---|
| `AnswerCoordinator` | aboutMe 空接地守門（不呼叫 LLM）；`runAutoDeep`/`requestDeep` 對 aboutMe 守門 |
| `TierPrompts` | `tier1SystemAboutMe` 格式放寬（1~3 條、不硬湊）＋事實紅線強化；`tier2SystemAboutMe`/`tier2UserAboutMe` 移除（守門後為死碼）；`tier2System` 依深答風格抽換格式指示段（詳細 = 現行原文零變更） |
| `MeetingCopilotConfigStore` | 新設定 `deepStyle`（新鍵 `meetingCopilotDeepStyleV1`；預設條列式） |
| `MeetingCopilotSettingsView` | 「一般」tab 回應模型區加「深度分析風格」picker（條列式／簡潔／詳細） |
| `MeetingReplayQueue`（新，@MainActor singleton） | 覆盤背景佇列：FIFO 序列、防重複 enqueue、@Published in-flight 狀態（供雙頁 tag）、完成/失敗收尾 |
| session reconciler（新，輕量） | 觀察 `.transcriptionDeleted` → sweep 刪孤兒 session（鏡射 `TranscriptIndexService.reconcileOrphans`） |
| `MeetingRowDisplay` / 覆盤頁 / 錄音詳情 | 標題連動、覆盤中 tag、互斥按鈕邏輯 |

### Explicitly Out of Scope

- 覆盤佇列的取消 UI（引擎已支援 `Task.checkCancellation`；v1 不做，記 Open Question）。
- 同一錄音多場 replay 的 A/B 對照行為（**保留**現狀——無 live 時仍可重新產生、多場並存）。
- aboutMe 有接地時的答案品質調校（本次只管「零接地不得編」與格式放寬）。
- live session 與錄音的關聯建立機制（`importFingerprint` 回填既有，不動）。
- 舊資料清理（fingerprint 為空的既有 session 一律不動）。

## Functional Requirements

> 編號延續 M8（FR-41~64 / AC-28~47）。

### A 組 — aboutMe 嚴禁幻覺

- [ ] **FR-65（空接地守門——結構性防幻覺）**：aboutMe cue 的 Tier 1 在接地結果**零筆記片段**時（`ragExcerpts.isEmpty`，不論原因：索引空／未設 vault／`useNotesRAG` 關／檢索無命中）**不呼叫 fast model**，直接寫入固定回應——`tier1Opener` = 「筆記沒有記載這題」語意的固定文案；`tier1Bullets` = `aboutMeBrief` 非空時 `[自介]`、否則空；`tier1GroundingNote` 記「零接地短路」與原因（觀測）。零 LLM 呼叫 = 結構上保證零幻覺。replay 路徑（`runTier1ForReplay`）同樣生效（共用 `runTier1`）。
- [ ] **FR-66（有接地時的格式：條列記憶錨點、不硬湊）**：`tier1SystemAboutMe` 從「恰 3 bullets」放寬為「**1~3 條、只列筆記片段有記載的，不足不硬湊**」；事實紅線強化為「筆記片段與自介**沒提到的內容一個字都不能出現**；片段不足以回答就直說筆記沒記載」。維持記憶錨點語意（專案名／角色／具體貢獻／量化成果）與既有 OPENER+bullets 輸出格式（parser 不動）。
- [ ] **FR-67（aboutMe 不進 Tier 2）**：`runAutoDeep` 對 `cue.kind == .aboutMe` 直接跳過；`requestDeep` 對 aboutMe no-op（log 一行）——**引擎層守門**，涵蓋 overlay 點擊與覆盤頁等所有 UI 入口；UI 對 aboutMe cue 不顯示 deep affordance（點擊只展開 Tier 1 錨點）；`tier2SystemAboutMe`／`tier2UserAboutMe` prompt 變體移除（守門後不可達）。

### B 組 — 覆盤生命週期

- [ ] **FR-68（標題連動錄音名稱）**：覆盤 session 的顯示標題改為：`importFingerprint` 非空且查得到對應 `Transcription` → 用該錄音的顯示標題（與錄音管理**同一條**顯示規則：`recorderTitle` 優先）；否則退回現行日期命名。**顯示時 live lookup、不存副本**——改名（改 `recorderTitle`，fingerprint 不變）自動反映，零同步機制。適用覆盤頁列表、詳情 sheet；live 與 replay session 同規則（replay 靠既有「離線覆盤」badge 區分，標題不加後綴）。
- [ ] **FR-69（刪除傳播）**：觀察 `.transcriptionDeleted`（批次 nil 訊號）→ sweep：`importFingerprint` **非空**、且已無任何 `Transcription` 帶該 fingerprint 的 session → 刪除（**live 與 replay 都刪**——使用者定案「全刪」）；fingerprint 空字串的 session 一律不動；cue/segment 由既有 cascade 帶走。模式鏡射 `TranscriptIndexService.reconcileOrphans`（同一個通知、同一種 sweep、同樣冪等）。
- [ ] **FR-70（live 與 replay 不同時並存——狀態判斷，非永久規則）**：錄音詳情的覆盤按鈕邏輯改為三態，以**當下是否存在** live session 判斷（fingerprint match 且 `sourceRaw == "live"`，顯示時查詢）——存在 live → 只顯示「會議copilot覆盤」查看鈕（**無**「產生」「重新產生」）；無 live 但有 replay → 「查看＋重新產生」（多場 replay 並存的 A/B 行為保留）；皆無 → 「產生會議copilot覆盤」。**live 紀錄被刪（覆盤頁批次刪除等）後，「產生」按鈕即回來**——使用者定案：刪掉 live 紀錄後一樣可以離線覆盤。
- [ ] **FR-71（覆盤背景佇列）**：replay 產生從詳情 sheet 的 `@State` service 升級為 app 層單例 `MeetingReplayQueue`（@MainActor ObservableObject，configure(modelContext:) 於 bootstrap 注入——鏡射 `TranscriptIndexService` 模式）：enqueue(transcription) → **FIFO 序列**執行（一次一場，沿用 `MeetingReplayReviewService` 的序列紅線）；同一錄音已在佇列／跑動中 → 按鈕 disabled（防重複）；關閉詳情 sheet、切頁、開新工作都不中斷；完成 → tag 移除、**不自動跳轉**（背景語意；覆盤頁列表的 cue 數已即時更新）；失敗 → session 已被 service 整場刪除（既有「不留半套」語意不變）＋ `NotificationManager` 錯誤通知。
- [ ] **FR-72（「覆盤中」tag 雙頁顯示）**：跑動中——錄音管理該錄音的列與詳情顯示「覆盤中」badge（來源 = queue 的 @Published in-flight 集合，key = `transcription.id`；含進度 done/total 可選）；覆盤頁跑動中那場 session 的列顯示「覆盤中」badge（session 於 `generateReview` 起點即 insert，跑動中就在列表上；queue expose 進行中 session id）。完成／失敗後兩處 badge 即除。

### C 組 — 深答風格（即時可消化）

- [ ] **FR-73（深度分析風格三選一）**：新設定「深度分析風格」（`MeetingCopilotConfigStore` 新鍵 `meetingCopilotDeepStyleV1`；設定頁「一般」tab 回應模型區 picker）：
  - **條列式（`bullets`，預設）**——analysis 改為**關鍵詞開頭的短條列**（≤4 條、每條一行、「**關鍵詞**：內容」格式）；followUps ≤2；uncertainties ≤2。設計目標：對話進行中 **3 秒掃視**能抓到重點——關鍵詞先行讓眼睛有錨點，行數上限保證不用捲動。
  - **簡潔（`concise`）**——analysis 為 2~3 句直給結論與立場，無條列無鋪陳；followUps ≤2。給「只要告訴我怎麼回」的場合。
  - **詳細（`detailed`）**——現行 prompt **原文零變更**（回歸鎖）。事後覆盤研讀用。
  實作為 `tier2System` 的格式指示段抽換；**JSON 契約不變**（analysis／followUps／uncertainties 三鍵照舊，parser／overlay／覆盤頁零改動——變的只是 analysis 字串內部的排版）。預設值即為條列式 = **刻意的行為變更**（本需求的目的：現行段落分析在對話中讀不完）。aboutMe 不受影響（FR-67 已不進 deep）。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 防幻覺 | aboutMe 零接地路徑 **零 LLM 呼叫**（可測試的結構保證，非 prompt 祈禱） | 守門在 `runTier1` 內、prompt 之前；注入 fake completer 驗證零呼叫 |
| 回歸安全 | 技術 cue（非 aboutMe）三層行為 bit-for-bit 不變；replay 與 live 產物同構不變 | 守門全部以 `kind == .aboutMe` 分支；既有測試不動 |
| 回歸安全 | 覆盤失敗語意不變（整場刪、不留半套） | queue 只是搬執行位置，`generateReview` 契約不動 |
| 資料安全 | 刪除傳播只刪 fingerprint 精確孤兒；空 fingerprint 永不觸碰 | sweep 條件收緊＋單元測試鎖 |
| 效能 | 標題 lookup 與 sweep 皆 personal scale fetch（覆盤頁一次 fetch-all 組字典） | 鏡射 `RetrievalService` categoryName 的 fetch-all＋dictionary 模式 |
| 觀測 | 零接地短路、deep 守門、sweep 刪除數皆記 os_log | 沿用 category `MeetingCopilot` 與既有 emoji 語彙 |

## Architecture Notes

- **守門位置是 A 組的核心決策**：擋在 `AnswerCoordinator.runTier1` 的 gather 之後、prompt 組裝之前——不是加強 prompt。prompt 只能降低機率，不呼叫模型才是保證。`ragError`（RAG 降級）與「檢索成功但零命中」在這裡是同一件事：都沒有事實可依。
- **標題不存副本**：任何「把錄音名 copy 進 session」的設計都會製造第二份真相＋同步義務；顯示時以 fingerprint 查 `Transcription` 是唯一不會腐敗的做法。查不到（已刪、舊資料）自然退回日期命名——與 FR-69 的刪除傳播互補（正常情況查不到的 session 很快會被 sweep 掉）。
- **queue 與 service 的分工**：`MeetingReplayReviewService` 保持「一場覆盤的執行者」不變；`MeetingReplayQueue` 只負責「排程＋狀態廣播」。view 從此不持有 service。
- **`.transcriptionDeleted` 是 nil 批次訊號**：沒有 id 可用，只能 sweep 全量比對——這正是 `reconcileOrphans` 已驗證過的形狀，照抄即可。

## Acceptance Criteria

> 編號延續 M8。BDD Given/When/Then。

### AC-48: aboutMe 零接地 → 零 LLM 呼叫＋固定回應
- **Given**: aboutMe cue、接地回傳零筆記片段（fake grounding）、fast completer 為計數 fake
- **When**: `runTier1`
- **Then**: fast completer **呼叫次數 = 0**；`tier1Opener` = 固定「筆記沒記載」文案；`tier1GroundingNote` 記短路原因
- **Test**: `AnswerCoordinatorTests`

### AC-49: 零接地＋自介非空 → 自介成為唯一條列
- **Given**: 同 AC-48 但 `aboutMeBrief` 非空
- **Then**: `tier1Bullets == [aboutMeBrief]`；仍零 LLM 呼叫

### AC-50: 有接地 → 條列放寬與紅線
- **Given**: aboutMe cue、接地回傳 ≥1 筆記片段
- **When**: `runTier1`
- **Then**: 呼叫 fast model；system prompt 含「1~3 條」「不足不硬湊」「沒提到的一個字都不能出現」指示（prompt 文字測試鎖）
- **Test**: `TierPromptsTests`

### AC-51: aboutMe 不進 Tier 2
- **Given**: aboutMe cue 完成 Tier 1（autoDeepEnabled = true）、deep completer 為計數 fake
- **When**: auto-deep 時機到＋另外顯式呼叫 `requestDeep`
- **Then**: deep completer 呼叫次數 = 0；非 aboutMe cue 不受影響（對照組照常進 deep）

### AC-52: 標題連動錄音名
- **Given**: session.importFingerprint 對得到一筆 `recorderTitle = "面試A"` 的錄音
- **Then**: 覆盤列表標題顯示「面試A」；改名為「面試B」後重繪 → 「面試B」；fingerprint 空或查不到 → 現行日期命名
- **Test**: 標題解析純函式測試

### AC-53: 刪錄音 → 全刪傳播
- **Given**: fingerprint X 有 1 場 live＋2 場 replay session；fingerprint Y 另有 session；一場 fingerprint = "" 的舊 session
- **When**: 刪除 X 的錄音（`.transcriptionDeleted` 發出）
- **Then**: X 的 3 場全刪（cue/segment cascade）；Y 與空 fingerprint 的不動
- **Test**: reconciler 單元測試（in-memory container）

### AC-54: live／replay 互斥三態
- **Given/Then**: 有 live session → 詳情只有「查看」；無 live 有 replay → 「查看＋重新產生」；皆無 → 「產生」
- **Test**: 按鈕狀態解析純函式測試

### AC-55: 背景執行不中斷
- **Given**: enqueue 一場覆盤後立即關閉詳情 sheet
- **When**: 佇列跑完
- **Then**: session 完整（cue／Tier 1／漏抓掃描都在）；完成後不自動跳轉

### AC-56: 覆盤中 tag 生命週期
- **Given**: 覆盤跑動中
- **Then**: 錄音管理該列＋覆盤頁該 session 列都顯示「覆盤中」；完成後兩處消失；失敗 → session 不存在＋錯誤通知、tag 消失

### AC-57: 防重複 enqueue
- **Given**: 同一錄音已在佇列／跑動中
- **When**: 再點「產生」
- **Then**: no-op（按鈕 disabled）；其他錄音可照常排入（FIFO 序列執行）

### AC-58: 深答風格抽換
- **Given**: 深答風格設為條列式
- **When**: Tier 2 組 system prompt
- **Then**: prompt 含條列格式指示（≤4 條、關鍵詞開頭、followUps ≤2；prompt 文字測試鎖）；設為**詳細**時 prompt 與現行**逐字相同**（回歸鎖）；設定值 UserDefaults round-trip 持久化
- **Test**: `TierPromptsTests` / `MeetingCopilotConfigStoreTests`

## Open Questions

- [ ] 覆盤佇列的取消 UI——引擎已支援取消（`Task.checkCancellation` + 失敗刪整場），v1 不做按鈕；若佇列常態多場再補。
- [ ] 覆盤頁多場 replay 的 A/B 對照如何一眼分辨 config 差異（現靠診斷區的設定快照）——與本次無關，留待調校工作流需求明朗。
- [ ] 深答風格是否需要第四個「自訂格式指示」自由文字欄——先用三個 preset 觀察；真有需求再加（自由文字容易寫出破壞 JSON 契約的指示，要多一層防護）。
