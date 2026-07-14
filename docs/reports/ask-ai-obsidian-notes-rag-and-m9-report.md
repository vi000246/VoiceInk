# Implementation Report: Ask AI × Obsidian 筆記 RAG ＋ Meeting Copilot M9

## Summary

兩份 plan 以平行 worktree 實作、merge 回 `feat/meeting-copilot-m8`：

- **ask-ai-obsidian-notes-rag** — Obsidian 筆記升為 Ask AI 一級語料庫（雙 chip scope、facet 豁免、筆記管線設定收編、引用回 Obsidian），並修掉「`.all` 的 `sources = nil` 讓筆記塊已經漏進預設查詢」的現有漏洞。
- **meeting-copilot-m9** — aboutMe 結構性防幻覺（零接地不呼叫 LLM）、覆盤生命週期（標題連動／刪除傳播／背景佇列／覆盤中 badge）、深答風格三選一。

## Assessment vs Reality

| Metric | Predicted (Plan) | Actual |
|---|---|---|
| Plans | 2（可平行） | 2，平行 worktree 實作，1 個 merge 衝突（測試檔，如 plan 預期的共檔） |
| Tasks | 12 + 11 | 全數完成（+ 4 個審計後補修） |
| Files Changed | ~16 + ~14 | 30（CREATE 7 / UPDATE 23） |
| Tests | — | **330 passed / 0 failed** |

## 執行過程的偏離

| 事件 | 說明 |
|---|---|
| Workflow args 送達為字串 | `prp-implement-parallel.workflow.js` 只認物件形式的 `args.plans`，字串送達時靜默回 `no-plans`（12ms、0 agent，看起來像正常完成）。已修為兩種型別都解析。 |
| 中途暫停 → quiet 模式 | 使用者要求不跑自動化測試（`xcodebuild test` 會啟動 app 搶焦點、build 吃滿 CPU）。為 workflow 加 quiet 模式：跳過 validate agent、禁止 merge/衝突 agent 跑 build。 |
| Resume 未命中快取 | 續跑時從 wave 1 重跑（多出一個標籤誤植的 commit，內容只是把 validate agent 遺留的測試修補掃進來）。實作本身冪等，無重複程式碼。 |
| **驗證與收尾改為手動** | 兩份 plan 的實作 wave 都已完成，被中斷的正是 validate agent。後續 merge／build／test／修錯由主 session 直接執行。 |

## Validation Results

| Level | Status | Notes |
|---|---|---|
| Build | ✅ BUILD SUCCEEDED | |
| Unit Tests | ✅ 330 passed / 0 failed | `-only-testing:VoiceInkTests` |
| M8 回歸鎖 | ✅ 全綠 | `testEmbeddingModelSwitchForcesFullReembed`、`testReconcileOrphansPreservesObsidianChunks` |
| UI Tests | ⚠️ 環境問題 | `VoiceInkUITests-Runner` 逾時（automation mode 權限），與本次改動無關 |

## 驗證階段自己抓到的缺陷（validate agent 被中斷時正在處理的）

1. **Task 11 實作從未落地** — 測試呼叫 `AskAIService.emptyRetrievalMessage`，但該函式不存在 → 測試 target 編譯失敗。補上（含「只問筆記且筆記塊為 0 → 指向筆記來源設定」的分支）。
2. **`.all` 非 nil 化帶出的訊息回歸** — 原本用 `scope.sources != nil` 判斷「使用者有篩選」，改成明確集合後此條件恆真 → 任何空檢索都叫使用者「把篩選改回全部」，即使他根本沒篩。改為看 sources 有沒有涵蓋全部 kind。
3. **舊測試把漏洞當契約鎖住** — `AskAIEnhancementTests.testSourceFilterRecorderIncludesMeeting` 斷言 `.all.sources == nil`。更新到新契約。
4. **merge 遺漏的覆蓋率** — ask-ai 刪掉 `testEmptyExcludedFoldersOverridesDefault` 時沒搬到新 store 的測試檔，「空清單可覆寫預設」這個 bug 類別會變成無人守。已補進 `ObsidianRAGConfigStoreTests`。

## SRS Drift 審計（對抗性，2 verifier + 1 critic）

逐條 AC 追「實作在哪、哪個測試會因為它壞掉而紅」。**揪出四個測試照不到的真缺陷**，全部已修：

| # | 缺陷 | 影響 |
|---|---|---|
| 1 | 🔴 **FR-11 完全沒做**（`MeetingCopilotSettingsView.notesRAGSection` 未瘦身） | (a) 該頁 vault 繞過 `effectiveVaultRoot()` → 設了筆記 vault override 後兩頁顯示不同 vault、該頁「重建索引」建到錯的 vault；(b) 兩頁寫同一組 UserDefaults 鍵，該頁 TextField 只在 onAppear 種一次 @State → 在 Ask AI 勾完資料夾後，會議設定頁一個按鍵就把選擇整組覆寫掉 |
| 2 | 🔴 `MeetingSessionReconciler` 的通知 closure 寫死 `.shared` 而非捕獲 self | instance 路徑永久 no-op；AC-53 的測試證明不了接線；block observer 洩漏進後續測試 |
| 3 | 🔴 `AskAIScope.all` 仍是 `sources = nil` | 原漏洞的**第二條路**——`AskAISourceFilter.all` 已修，但這個同名「不過濾」常數還在介面上 |
| 4 | 🟠 `MeetingReplayQueue.runReal` 缺依賴時靜默 `return` | 按了「產生覆盤」→ badge 閃一下就消失、什麼都沒發生、log 一行都沒有 |

## AC 覆蓋現況

| SRS | implemented_and_tested | implemented_no_test |
|---|---|---|
| ask-ai（AC-1..13） | 8 | 5 |
| M9（AC-48..58） | 9 | 2 |

**`implemented_no_test` 全數集中在 SwiftUI view 層**（chip 防呆、chip disabled 狀態、citation popup 分流、覆盤中 badge、背景不中斷）。本專案沒有 view 測試基建（無 ViewInspector），plan 本來就把這些列在手動驗證清單。實作皆存在且非 stub。

### 需人工驗證的項目（真 vault ＋ 真金鑰）

- [ ] 預設（筆記 chip 關）提問 → 引用全是錄音/聽寫
- [ ] 開筆記 chip → 自動增量掃（Console `🗂️`）→ 只問筆記能答
- [ ] 雙開＋分類篩選 → 筆記仍出現
- [ ] 點筆記引用 → 標題正確＋「在 Obsidian 開啟」真的開到那篇
- [ ] 換 vault override → 重建 → 查得到新 vault 內容；改回跟隨 → 行為回復
- [ ] 關閉唯一開啟的 chip → 維持開啟（不可全關）
- [ ] 無筆記索引時問「你做過什麼專案」→ overlay 顯示「筆記沒有記載」＋自介，Console 無 fast model 呼叫
- [ ] aboutMe cue 不出現深度分析；技術 cue 照常 auto-deep
- [ ] 深答風格三檔切換：條列式 ≤4 條關鍵詞開頭／簡潔 2~3 句／詳細＝舊觀感
- [ ] 錄音改名 → 覆盤頁標題即時反映；刪錄音 → 該場 live＋replay 消失
- [ ] 產生覆盤後立刻關掉詳情 → 兩頁都有「覆盤中」badge → 跑完消失、session 完整
- [ ] 有 live 的錄音看不到「產生」；到覆盤頁刪掉該 live → 按鈕回來

## 已知殘留（低風險，記錄在案）

- **`diagnoseEmptyRetrieval` 的分支順序**：`totalAll == 0` 與 `forModel == 0` 兩級在筆記分支**之前**，兩者都回「請按重建索引」——而那顆按鈕只回填逐字稿。實務上難以觸及（索引全空時 UI 走 empty state；換模型會清光所有塊），但嚴格說，索引空／模型不符時的訊息對筆記使用者沒有幫助。
