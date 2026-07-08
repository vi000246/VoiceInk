# Feature Implementation Report: Ask AI — 跨庫語意問答

## Summary
新 `ask-ai` 模組:所有轉錄(聽寫/錄音/會議)→ chunk → 雲端 embedding(BYOK,Gemini 768 預設 / OpenAI 1536 備援)→ 第 4 個 SwiftData store 向量索引 → vDSP 暴力 cosine top-k → 一次 `completeChat` 產生附編號引用的繁中回答。含回填、範圍 chips、引用跳轉、換模型重嵌。Build 231。

## Strategy Used
- Size: L ｜ Mode: B ｜ 主 session（Fable 額度用盡後轉 Opus 4.8 續完 Tasks 3-9）
- 每個 task 先寫鎖行為測試（純函式 seam + in-memory container + 注入 fake embedder/completer），逐 task build+test

## Tasks Completed
| # | Task | Status | 測試 |
|---|------|--------|------|
| 1 | 3 個 @Model + 第 4 store（兩 factory） | ✅ | AskAIIndexTests ×2 |
| 2 | TranscriptChunker（講者輪次感知） | ✅ | AskAIChunkerTests ×5 |
| 3 | EmbeddingClient（Gemini/OpenAI, batch/backoff） | ✅ | AskAIEmbeddingTests ×6 |
| 4 | TranscriptIndexService（upsert/reconcile/backfill） | ✅ | AskAIIndexServiceTests ×4 |
| 5 | RetrievalService（vDSP top-k, scope） | ✅ | AskAIRetrievalTests ×3 |
| 6 | AskAIService（引用驗證/短路/持久化） | ✅ | AskAIAnswerTests ×4 |
| 7 | AskAIView + `.askAI` 註冊 + 引用 sheet | ✅ | sidebar DEBUG assert |
| 8 | Embedding 模型設定 + 重嵌確認 | ✅ | build |
| 9 | 收尾（build 231/docs/deploy/archive） | ✅ | — |

## Integration Checks
| Check | Status | Notes |
|---|---|---|
| Build | ✅ | 一處 SwiftUI ViewBuilder 誤導錯誤（Group+ternary background）重構解決 |
| Unit tests | ✅ | 全套 88 passed（含 24 新 Ask AI 測試），零回歸 |
| 手動 | ⏳ 待使用者 | 需 embedding 金鑰＋回填後實測；20 題 eval 見下 |

## Key Deviations from Plan/SRS（皆有理由）
1. **刪除傳播用 reconcile 掃描**：`.transcriptionDeleted` 實際以 `object: nil` 發出（批次訊號、不帶 id），SRS 假設帶 id。改為掃索引 vs 現存 id、刪孤兒塊。正確且穩健（連自動清理刪除也涵蓋）。
2. **scope 的 sources/categoryId 在記憶體過濾**：`#Predicate` 對 nested `??`/optional 檢查會型別檢查爆炸（實測，與 recording-library 預期的 optional-UUID 風險同源）。只把 embeddingModel(String)+date range 壓進 predicate,其餘 fetch 後 filter,個人規模成本可忽略。
3. **注入式介面**：`EmbeddingProviding` / `ChatCompleting` 讓全部服務層可脫離網路測試（plan 有提但未強制）。

## Manual Validation（→ Linear 驗證 issue 待授權後建）
- [ ] AI Models 設定 Gemini（或 OpenAI）金鑰 → Ask AI 頁顯示「建立索引」而非缺金鑰空狀態
- [ ] 建立索引:進度/總數/預估 token 顯示;完成後可提問
- [ ] 新聽寫/錄音/會議完成 ~1 分鐘內可問到（自動 upsert）
- [ ] AC-1:自出 20 題（答案在庫中）→ ≥90% 引用正確;5 題庫外對照 → 全部回「找不到」（零幻覺引用）
- [ ] 引用 [n] 點擊 → 開出正確逐字稿;來源已刪 → 提示而非崩潰
- [ ] scope chips（來源/分類/日期）正確縮小範圍
- [ ] 換 embedding 模型 → 確認對話出現 → 清空重嵌
- [ ] 刪除轉錄 → 該筆不再被引用（reconcile）

## Follow-ups
- [ ] Linear 驗證 issue（等 `/mcp` 授權）
- [ ] 引用跳轉升級:接 recording-library 的 `pendingFocusTranscriptionId`（目前開 detail sheet，已足夠）
- [ ] Float16 向量壓縮、chunk overlap A/B（0% vs 10%）、段落級引用高亮 — 皆 v2
- [ ] backfill 大量時移到背景 ModelContext（目前 MainActor 批次;個人規模可接受）
