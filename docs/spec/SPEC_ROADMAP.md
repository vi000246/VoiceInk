# Spec Roadmap

> Auto-updated index. Last updated: 2026-07-13
>
> **AI Agents**: Read this file first to decide which specs to load. Load only what's relevant to
> your task to avoid context bloat.

## Module Index

| Module | Spec | Domain Layer | Description | Sub-modules |
|--------|------|--------------|-------------|-------------|
| recorder-automation | [recorder-automation.spec.md](./recorder-automation.spec.md) | Supporting Domain | Turns recorder volumes, watched folders, iCloud sources (spec'd) and meeting captures (spec'd) into a zero-click「audio → transcribe+diarize (ElevenLabs whole-file) → classify → template → Obsidian note」pipeline; includes the Recording Library management page (upgrade spec'd). | — |
| ask-ai | [ask-ai.spec.md](./ask-ai.spec.md) | Supporting Domain | Semantic QA over all transcription history: chunk → cloud embeddings (BYOK, Gemini default) → local vector index (4th SwiftData store) → brute-force top-k → cited answers. Implemented (build 231); enhancements (answer model / single-recording / Ask AI templates) spec'd. | — |
| templates | [templates.spec.md](./templates.spec.md) | Supporting Domain | 單一共用範本庫 + 類別標籤（語音輸入／錄音輸入），語音/錄音模式以類別多選篩選共用範本;連帶側欄 IA 重構。Spec'd（WP1+WP2），未實作。 | — |
| library-management | [library-management.spec.md](./library-management.spec.md) | Supporting Domain | Notion 式清單管理頁（欄位/排序/詳情彈窗/批次+星號保護）共用基建，供錄音管理與新語音管理兩頁。Spec'd（WP3+WP4），未實作。 | — |
| voice-input | [voice-input.spec.md](./voice-input.spec.md) | Core Domain | 語音聽寫輸出路徑（Modes + TranscriptionDelivery）;新增「編輯後貼上」——貼上前用外部真 MacVim/nvim 阻塞編輯再貼回。Spec'd，未實作。 | — |
| meeting-copilot | [meeting-copilot.spec.md](./meeting-copilot.spec.md) | Supporting Domain | 會議**即時**輔助。設計第一原則:瓶頸不是答案品質,是「開口的頭五秒」。聲道分流（mixToMono 之前切 tap=對方 / mic=我）取得零成本講者歸屬,免 diarization;`ResponseCueExtractor` 抓「需要我回應的東西」（含陳述句質疑,非只抓問號）;**三層漸進揭露**（Tier0 本機關鍵字 <0.5s 不呼叫 LLM ／ Tier1 fast model 產「開口稿」<1.5s 且最新一則預跑 ／ Tier2 deep model 產結構化 follow-up 預判）;答案接地於 brief + 歷史逐字稿 RAG + 分享畫面 OCR;`sharingType=.none` 的 overlay（toggle + peek 雙熱鍵、近鏡頭定位、說話時淡出、失敗靜默）。Spec'd,未實作。 | — |

## Loading Guide

| Task Type | Load These Specs |
|-----------|-----------------|
| 實作特定子模組功能 | 該子模組 spec + parent spec |
| 跨模組整合 | 相關模組各自的 root spec |
| 第一次理解系統 | 先讀本 SPEC_ROADMAP，再按需載入 |

## Recent Feature Changes

| Date | Module | Feature SRS | One-line Summary |
|------|--------|-------------|-----------------|
| 2026-07-13 | meeting-copilot | [m8-notes-rag-auto-deep.srs.md](../srs/meeting-copilot-m8-notes-rag-auto-deep.srs.md) | **M8 spec'd:筆記 RAG + auto-deep + 離線覆盤 + 即時翻譯** — cue 五分類（新增 `aboutMe`:問我/我的專案/績效考核，同呼叫輸出 searchHint 檢索改寫）+ Obsidian 筆記索引（重用 EmbeddingChunk `sourceKind:"obsidian"`、vault 用既有 `vaultRootBookmark`；reconcile/switchModel 兩地雷顯式防護）+ aboutMe 記憶錨點 tier prompts；最新 cue 自動 Tier2 並自動展開 + 閱讀保護不變量（展開不被擠出/搶展開/取消）+ 展開 toggle 熱鍵；錄音管理任一錄音可離線產生覆盤（逐字稿重演管線,`sourceRaw:"replay"`,可重複 A/B）+ 漏抓掃描 + 覆盤三層 debug 排序；remote committed 即時翻譯（LLM 混語自動辨識→繁中,overlay 翻譯區與 cue 區分隔,回應恆目標語言）。FR-41~64 / AC-28~47。 |
| 2026-07-13 | meeting-copilot | [m7-preset-scripts.srs.md](../srs/meeting-copilot-m7-preset-scripts.srs.md) | **M7 spec'd:預設講稿讀稿器** — 私人提詞面板，顯示使用者事先寫好的具名講稿（自我介紹等），開會看著唸（ADHD 看稿）。硬界線：只顯示自寫文字，**不接 AI/ASR/LLM、不讀 cue、獨立於 copilot 開關**；獨立 panel/store/view，複製 overlay 的螢幕分享排除＋不搶焦點視窗技術但不持有 controller。FR-33~40 / AC-20~27。 |
| 2026-07-13 | meeting-copilot | [m2-cue-detection.srs.md](../srs/meeting-copilot-m2-cue-detection.srs.md) | **M1–M5 全數 implemented + 執行期整合完成（build 253）** — 五個里程碑的引擎與 UI 皆建置且測試通過，並已接成 live pipeline（`MeetingCopilotLiveController` 在會議擷取啟停時建立/釋放：音源→雙路 ASR→cue 偵測→三層回應→overlay）。M1 音訊骨幹（248）/ M2 cue+store（249）/ M3 三層+SSE+接地（250）/ M4 overlay+熱鍵（251）/ M5 頁面+設定（252）/ 整合（253）。**剩純人工 gate**：M1 tapFirst 實機 probe、AC-15 螢幕分享三情境、真實模型 cue/tier 品質。見各 `docs/reports/meeting-copilot-m*-report.md`。 |
| 2026-07-13 | meeting-copilot | [m5-management-page.srs.md](../srs/meeting-copilot-m5-management-page.srs.md) | **M5 切片 spec'd + planned**:「會議錄音管理」側欄新頁（clone VoiceLibraryView）+ 完整設定 UI（fast/deep 雙 model picker、brief、grounding 開關、本機 ASR 無術語偏置明示）+ 修 .toggleMeetingRecording 缺失的 ShortcutRecorder。FR-29~31 / AC-18~19。 |
| 2026-07-13 | meeting-copilot | [m4-overlay-hotkeys.srs.md](../srs/meeting-copilot-m4-overlay-hotkeys.srs.md) | **M4 切片 spec'd + planned**:隱蔽浮動 overlay（sharingType=.none + ignoresMouseEvents + .screenSaver + 近鏡頭定位 + 說話淡出）+ toggle/peek 雙熱鍵（peek 走 keyDown/keyUp）。**誠實記載 sharingType 在 macOS 15.4+ 被 SCK 忽略、分享整螢幕會被錄到**。FR-21~26,32 / AC-16~17（AC-15 人工 gate）。 |
| 2026-07-13 | meeting-copilot | [m3-tiered-response.srs.md](../srs/meeting-copilot-m3-tiered-response.srs.md) | **M3 切片 spec'd + planned**:自持 SSE client（OpenAI-compat + Anthropic 兩 parser）+ AIService.streamChat + Tier0(免 LLM)/Tier1(開口稿)/Tier2(follow-up) + AnswerCoordinator(預跑/取消) + 接地(brief+RAG 直呼 retrieve+螢幕 OCR，靜默降級)。FR-13~20,27,28 / AC-5~14。 |
| 2026-07-13 | meeting-copilot | [m2-cue-detection.srs.md](../srs/meeting-copilot-m2-cue-detection.srs.md) | **M2 切片 spec'd + planned**:SwiftData meeting.store（MeetingLiveSession/Cue）+ ResponseCueExtractor（四分類 directQuestion/impliedChallenge/assignedToMe/informational + Jaccard 去重）+ MeetingCopilotController MVP（接 M1 的 onRemoteCommitted → persist）。FR-8~12 / AC-4。 |
| 2026-07-12 | meeting-copilot | [meeting-copilot-live-assist.srs.md](../srs/meeting-copilot-live-assist.srs.md) | **新模組（umbrella）**:會議即時輔助——聲道分流取代 diarization 取得零成本講者歸屬;偵測「需要我回應的東西」（含陳述句質疑）;三層漸進揭露（Tier0 免 LLM <0.5s ／ Tier1 開口稿 <1.5s 且預跑 ／ Tier2 結構化 follow-up）;接地於 brief + 歷史 RAG + 螢幕 OCR;`sharingType=.none` 的 overlay（toggle+peek、近鏡頭、說話淡出、失敗靜默）;含不開 Teams/Meet 的離線 replay harness。 |
| 2026-07-08 | voice-input | [edit-before-paste.srs.md](../srs/voice-input-edit-before-paste.srs.md) | 語音模式「編輯後貼上」:貼上前用外部真 MacVim/nvim（`mvim -f`）阻塞編輯暫存檔再讀回貼回,吃使用者真 vimrc。 |
| 2026-07-08 | templates | [templates-shared-library-and-ia.srs.md](../srs/templates-shared-library-and-ia.srs.md) | WP1+WP2:合併語音+錄音範本為單一共用庫（類別標籤、模式多選篩選）+ 側欄 IA 重構。 |
| 2026-07-08 | library-management | [library-management-pages.srs.md](../srs/library-management-pages.srs.md) | WP3+WP4:Notion 式錄音管理 + 新語音管理頁（表格/排序/詳情彈窗/批次+星號保護/改名→匯出對齊）。 |
| 2026-07-08 | recorder-automation | [meeting-into-recorder-input.srs.md](../srs/recorder-automation-meeting-into-recorder-input.srs.md) | WP5:會議錄製併入錄音輸入，手動選範本，不自動標會議。 |
| 2026-07-08 | ask-ai | [ask-ai-enhancements.srs.md](../srs/ask-ai-enhancements.srs.md) | WP6:專用答案模型（Gemini Pro）、來源語音/錄音、單檔提問、Ask AI 範本頁、獨立側欄群。 |
| 2026-07-06 | recorder-automation | [meeting-capture.srs.md](../srs/recorder-automation-meeting-capture.srs.md) | One-hotkey meeting recording — system-audio process tap + mic mixed to one m4a, feeding the existing import pipeline with an optional fixed 「會議」 category (skips classifier). |
| 2026-07-06 | recorder-automation | [icloud-sources.srs.md](../srs/recorder-automation-icloud-sources.srs.md) | Just Press Record / Voice Memos preset sources — recursive scan, dataless-placeholder download-then-import, keep-originals forced, per-source default category, true recording-time recovery. |
| 2026-07-06 | recorder-automation | [recording-library.srs.md](../srs/recorder-automation-recording-library.srs.md) | Recording Management → cursor-paginated, predicate-filtered library (category/source/status/starred/date) with batch star/reclassify/re-export and the citation focus hook. |
| 2026-07-06 | ask-ai | [ask-ai-semantic-qa.srs.md](../srs/ask-ai-semantic-qa.srs.md) | New module: RAG over all transcription history — cloud embeddings → local vector index → top-k retrieval → answers with tappable citations; resumable backfill + scope filters. |
| 2026-07-01 | recorder-automation | [speaker-diarization.srs.md](../srs/recorder-automation-speaker-diarization.srs.md) | Universal speaker diarization for recorder transcripts — native diarize where supported (ElevenLabs first) + FluidAudio local fallback; anonymous 講者1/2 labels, manually renamable. |
| 2026-06-30 | recorder-automation | [recorder-mode-and-recording-management.srs.md](../srs/recorder-automation-recorder-mode-and-recording-management.srs.md) | Separate recorder pipeline from voice input (own Recorder Mode model settings), make template apply + Obsidian export a manual, reviewable flow in a new Recording Management page; always preserve raw audio + transcript. |
| 2026-06-29 | recorder-automation | [auto-import-template-routing.srs.md](../srs/recorder-automation-auto-import-template-routing.srs.md) | Plug in a recorder → auto-import, transcribe, classify, apply the category's template, and export an analysis note to the vault. |
