# Spec Roadmap

> Auto-updated index. Last updated: 2026-07-07
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

## Loading Guide

| Task Type | Load These Specs |
|-----------|-----------------|
| 實作特定子模組功能 | 該子模組 spec + parent spec |
| 跨模組整合 | 相關模組各自的 root spec |
| 第一次理解系統 | 先讀本 SPEC_ROADMAP，再按需載入 |

## Recent Feature Changes

| Date | Module | Feature SRS | One-line Summary |
|------|--------|-------------|-----------------|
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
