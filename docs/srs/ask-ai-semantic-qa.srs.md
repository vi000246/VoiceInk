---
linear_issue: null
---
# SRS: Ask AI — 跨庫語意問答 (Semantic QA over Transcription History)

## Metadata
- **Module**: `ask-ai`
- **Module Spec**: `docs/spec/ask-ai.spec.md`
- **Source PRD**: `docs/prd/ask-ai-and-recording-library.prd.md` (Milestones 2–3)
- **Source Linear Issue**: N/A
- **Created**: 2026-07-06
- **Grill level**: 1 (standard)
- **Plans**:
  - `docs/plans/ask-ai-semantic-qa.plan.md` (Mode B, created 2026-07-07)

## Feature Summary

A new `ask-ai` module: every `Transcription` (dictation, recorder imports, meetings) is chunked and embedded via a **cloud embedding API (BYOK)** into a local vector index (4th SwiftData store); a new sidebar chat page answers natural-language questions with **top-k retrieved excerpts + one `completeChat` call**, returning answers with **numbered citations** that open the source transcript. Includes a one-time backfill over existing history and scope filters (source/category/date).

## Delta from Current Module State

> New module — see `docs/spec/ask-ai.spec.md` (created with this SRS) for full architecture. Verified greenfield: **zero** embedding/vector/similarity code exists in the repo or LLMkit; assistant chat is in-memory only (`Models/AssistantSession.swift:24-27`), so thread persistence is also net-new. Reused seams: `AIService.completeChat(provider:modelName:messages:systemPrompt:timeout:)` (`Services/AIEnhancement/AIChatCompletionService.swift:5-77`), CJK-aware `TokenEstimator` (`Services/RecorderAutomation/TokenEstimator.swift:9-16`), paragraph-boundary chunker basis (`LongTranscriptSummarizer.chunks`, `Services/RecorderAutomation/LongTranscriptSummarizer.swift:60-85`), Keychain key resolution (`Services/APIKeyManager.swift:45-48`), 3-store SwiftData setup to extend (`VoiceInk.swift:50-56,236-299`), chat UI structure to mirror (`AssistantPanelView`, `Views/Recorder/RecorderComponents.swift:396-552`).

### New / Changed API Endpoints

N/A local. **New external contracts (BYOK, in-repo clients — LLMkit has no embeddings support):**

| Provider | Endpoint | Notes |
|---|---|---|
| Gemini (default) | `models/gemini-embedding-001:embedContent` (+ batch) | 3072-dim MRL → request **768 dims**; free tier ~1,500 req/day; $0.15/1M std |
| OpenAI (fallback) | `POST /v1/embeddings` `text-embedding-3-small` | 1536-dim (`dimensions` param supported); $0.02/1M; 8,191-token input cap |

### New Data Models (all in a NEW 4th SwiftData store `index.store`, `cloudKitDatabase: .none`)

```swift
@Model final class EmbeddingChunk {
    var transcriptionId: UUID      // #Index; join key back to Transcription
    var chunkIndex: Int            // stable (transcriptionId, chunkIndex) identity → idempotent upsert
    var text: String               // the chunk text (for prompt assembly + display)
    var vector: Data               // Float32 array, little-endian (768 dims default)
    var dims: Int
    var embeddingModel: String     // vector-space tag; mixed-model vectors must never be compared
    var sourceKind: String         // "dictation" | "recorder" | "meeting" (denormalized for scope filters)
    var categoryId: UUID?          // denormalized from Transcription
    var timestamp: Date            // denormalized; #Index for date-scope filters
}

@Model final class AskAIThread { var title: String; var createdAt: Date; ... }
@Model final class AskAIMessage {
    var thread: AskAIThread?; var role: String; var text: String
    var citationsRaw: String?      // JSON [ChunkRef {transcriptionId, chunkIndex, excerpt}]
    var createdAt: Date
}
```

Registration: append models to the top-level `Schema` (`VoiceInk.swift:50-56`) + a 4th `ModelConfiguration("index", url: …/index.store, cloudKitDatabase: .none)` in BOTH `createPersistentContainer` (`:236-281`) and `createInMemoryContainer` (`:283-299`).

### New Components

| Component | Responsibility |
|---|---|
| `TranscriptChunker` | `LongTranscriptSummarizer.chunks`-style splitting at ~400–512 tokens (TokenEstimator), paragraph/speaker-turn aware (keep one speaker's utterance intact when `speakerSegments` exist), overlap default 10% (A/B 0% later — evidence says overlap may not help) |
| `EmbeddingClient` | In-repo HTTP clients (Gemini + OpenAI-compatible), batch endpoints, keys via `APIKeyManager`; mirrors the in-repo `ElevenLabsDiarizingClient` precedent for bypassing LLMkit |
| `TranscriptIndexService` | Upsert chunks on transcription completion; delete on `.transcriptionDeleted`; **backfill task** (progress %, ETA, pause/resume, rate-limit aware); index text = `enhancedText ?? text` |
| `RetrievalService` | Load scoped vectors → Accelerate/vDSP cosine → top-k (default 12). Brute force by design: 50k × 768 × 4 B ≈ 150 MB, query ≪100 ms — no ANN at personal scale |
| `AskAIService` | Assemble system prompt (answer in user's language, cite as [n], say 「找不到」 when retrieval is empty/weak) + numbered context blocks → `AIService.completeChat` → parse `[n]` citations → persist thread/messages |
| `AskAIView` (+ `.askAI` ViewType) | Chat page: thread list, scope chips (source/category/date), message bubbles (mirror `AssistantPanelView` + `MarkdownContentView`), citation buttons. Registration = 5 mandatory edits (`ContentView.swift:4-23,74-110`; `AppSidebar.swift:74-97,106-162` — DEBUG assert enforces section membership) |

### Changed Business Logic (outside the new module)

- Index hooks: on the existing completion notification path (`.transcriptionCompleted` / post-processor finalize) call `TranscriptIndexService.upsert`; deletion already broadcasts `.transcriptionDeleted` via `TranscriptionStore` — consume it.
- Citations v1 open the source transcript **in a detail sheet in-place** (reuses `TranscriptionDetailView` / TranscriptSheet); jumping to the Recording Library row uses the focus hook from `docs/srs/recorder-automation-recording-library.srs.md` (FR-8) once that ships.

### Explicitly Out of Scope

- Local/offline embeddings (user decision: cloud, privacy unconstrained); ANN indexes; multi-turn agentic retrieval (v1 = single retrieve→answer per question; thread context is conversational only); auto-summaries; cross-device sync; editing transcripts from the chat.

## Functional Requirements

- [ ] **FR-1** New transcriptions from all three pipelines are indexed automatically within ~1 min of completion; deleting a transcription removes its chunks.
- [ ] **FR-2** Backfill: one-tap indexing of all existing history with progress (n/total, ETA), pause/resume, idempotent by `(transcriptionId, chunkIndex)`; respects provider rate limits (batched requests + backoff); shows estimated cost/quota usage upfront (chunk count × est. tokens).
- [ ] **FR-3** Ask: question → embed → scoped top-k → answer with `[n]` citations; each citation maps to a real retrieved chunk; empty/weak retrieval → explicit 「资料庫中找不到相關內容」-style answer (in 繁中), never a fabricated citation.
- [ ] **FR-4** Citation tap opens the source transcript (detail sheet v1; library-row focus when available).
- [ ] **FR-5** Scope chips: source (聽寫/錄音/會議), category, date range — applied as retrieval pre-filters (SwiftData predicate on denormalized fields).
- [ ] **FR-6** Threads persist across launches; new/rename/delete thread.
- [ ] **FR-7** Settings: embedding provider (Gemini default / OpenAI) + key status check; answer model = any existing enhancement provider/model (reuse current picker patterns); changing embedding model invalidates the index with an explicit re-embed prompt (vector spaces are incompatible — Gemini `-001` vs `-2` vs OpenAI must never mix).
- [ ] **FR-8** Graceful empty states: no key configured, index empty, backfill running.

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| Latency | Retrieval <100 ms @ 50k chunks; total answer <10 s (PRD metric) | In-memory vDSP brute force; single completeChat |
| Memory | Index RAM ≤ ~300 MB worst case; lazy-load vectors per query scope | 768-dim Float32; scoped fetch before similarity |
| Cost | Backfill of ~1,000 recordings ≈ low single-digit $ or free-tier | Gemini free tier / $0.15 per 1M tokens; est. shown in FR-2 |
| Integrity | No cross-model vector comparison, ever | `embeddingModel` tag checked at query time |

## Architecture Notes

- **Embedding default = Gemini `gemini-embedding-001` @ 768 dims (MRL)**: best-reputation multilingual (CJK) line, free personal tier, 4× storage saving vs 3072; OpenAI `text-embedding-3-small` as the no-Gemini-key fallback. `gemini-embedding-2` is preview-only — revisit at GA (full re-embed required by design).
- The index store stays out of the `default` store so history migrations and the index lifecycle (drop/re-embed) stay independent.
- Answer-model choice rides the existing `AIProvider` plumbing — no new chat client work.

## Acceptance Criteria

### AC-1: 附引用問答（品質門檻）
- **Given**: a backfilled index containing a known fact in exactly one recording (seed a 20-question eval list from real history)
- **When**: asking in 繁體中文
- **Then**: answer content is correct AND every citation opens the transcript that actually contains the answer; ≥90% citation correctness over the eval list (PRD metric); zero fabricated citations on the 5 out-of-corpus control questions (model must answer 找不到)
- **Test**: manual eval sheet (Linear checklist) + unit `AskAIServiceTests::citationsMapToRetrievedChunks`

### AC-2: 新資料即時可問
- **Given**: index built; a new dictation/recorder/meeting transcription completes
- **When**: asking about its content ~1 min later
- **Then**: retrievable and correctly cited
- **Test**: `TranscriptIndexServiceTests::upsertOnCompletionNotification` + manual

### AC-3: 回填冪等可中斷
- **Given**: 1,000-item seeded history
- **When**: backfill runs, is killed midway, and reruns
- **Then**: completes with exactly one chunk set per transcription (no dupes), progress accurate
- **Test**: `TranscriptIndexServiceTests::backfillIsIdempotent` (in-memory store, mock client)

### AC-4: 範圍過濾
- **Given**: chunks across sources/categories/dates
- **When**: scope = 會議 + 最近 30 天
- **Then**: retrieval candidates contain zero out-of-scope chunks
- **Test**: `RetrievalServiceTests::scopePredicateFilters`

### AC-5: 刪除傳播
- **Given**: an indexed transcription
- **When**: it is deleted in the app
- **Then**: its chunks are gone; a subsequent question cannot cite it
- **Test**: `TranscriptIndexServiceTests::deleteRemovesChunks`

### AC-6: 檢索效能
- **Given**: 50k synthetic 768-dim vectors
- **When**: one scoped query
- **Then**: similarity + top-k completes <100 ms on Apple Silicon
- **Test**: `RetrievalServicePerfTests::bruteForce50k`

## Open Questions

- [ ] Which embedding key does the user already have (Gemini vs OpenAI)? Confirm before plan; default order may flip.
- [ ] Float16 vector storage (halves store size, negligible quality loss) — measure before deciding; Float32 is the safe v1.
- [ ] Chunk overlap 10% vs 0% — cited 2026 evidence says overlap may add cost without retrieval benefit; A/B on the real corpus.
- [ ] Default answer model (reuse the user's current enhancement default vs a fixed fast model).
- [ ] Segment-level citation highlight inside the detail sheet (v1 opens the transcript; highlighting is a Could).
