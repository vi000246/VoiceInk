# Spec: Ask AI (Semantic QA)

## Metadata
- **Module**: ask-ai
- **Parent Module**: N/A
- **Sub-modules**: N/A
- **Source PRDs**:
  - `docs/prd/ask-ai-and-recording-library.prd.md` — initial creation (Milestones 2–3; Milestone 1 lives in `recorder-automation`)
- **Source Linear Issue**: N/A
- **Owner**: TBD (personal fork — vi000246/VoiceInk)
- **Status**: ACTIVE — living document
- **Created**: 2026-07-06
- **Last Updated**: 2026-07-06

## Change History

| Date | Source PRD | Feature SRS | Summary |
|------|------------|-------------|---------|
| 2026-07-06 | `docs/prd/ask-ai-and-recording-library.prd.md` | `docs/srs/ask-ai-semantic-qa.srs.md` | Created — RAG over all Transcription history: chunk → cloud embeddings (BYOK, Gemini default) → local vector index in a new 4th SwiftData store → vDSP brute-force top-k → one `completeChat` answer with numbered citations; new sidebar chat page + backfill. Not yet implemented. |

## Summary

`ask-ai` turns the app's transcription history (dictation, recorder imports, meetings) into a
queryable knowledge base: text is chunked and embedded via a cloud embedding API, vectors live in a
local SwiftData store, retrieval is exact brute-force cosine (personal scale — no ANN), and answers
come from one existing-provider chat call with retrieved excerpts and enforced citations. The module
is read-only over core data: it consumes `Transcription` rows and lifecycle notifications, and never
mutates them.

---

## Domain Model

### Bounded Context
- **Context Name**: AskAI
- **Domain Layer**: Supporting Domain (retrieval/answering over Core transcription data)
- **Parent Module**: N/A

### Ubiquitous Language
| Term | Definition |
|------|-----------|
| Chunk | A ~400–512-token slice of one transcription's text (`enhancedText ?? text`), paragraph/speaker-turn aware. Identity = `(transcriptionId, chunkIndex)` — the idempotency key for indexing. |
| Index | The set of `EmbeddingChunk` rows in the dedicated `index.store`. Dropping/rebuilding it never touches core data. |
| Vector Space | The embedding model that produced a vector (`embeddingModel` tag). Vectors from different spaces are never compared; switching models ⇒ full re-embed. |
| Backfill | The one-time (resumable, idempotent) job that indexes pre-existing history. |
| Scope | Retrieval pre-filter (source kind / category / date range) applied as a store predicate before similarity. |
| Citation | A `[n]` marker in an answer mapping to a retrieved chunk (`ChunkRef {transcriptionId, chunkIndex, excerpt}`); tapping opens the source transcript. Fabricated citations are a defect (AC-gated). |
| Thread | A persisted Ask AI conversation (`AskAIThread` + `AskAIMessage`), distinct from the ephemeral dictation Assistant. |

### Domain Events
| Event | Trigger Condition | Consumers |
|---|---|---|
| `.transcriptionCompleted` (existing) | Any pipeline finishes a transcription | `TranscriptIndexService.upsert` |
| `.transcriptionDeleted` (existing, via `TranscriptionStore`) | User deletes a transcription | `TranscriptIndexService.delete(transcriptionId:)` |

---

## System Context

### Scope & Boundaries
- **In scope**: chunking; embedding clients (Gemini/OpenAI, BYOK); index store + lifecycle (upsert/delete/backfill/invalidate-on-model-change); scoped brute-force retrieval; answer assembly with citations; thread persistence; `AskAIView` chat page + scope chips + settings.
- **Out of scope**: local/offline embeddings; ANN indexes; agentic multi-hop retrieval; auto-summarization (category templates own that); mutating transcripts; cross-device sync; the Recording Library page itself (see `recorder-automation-recording-library.srs.md` — it only exposes the citation focus hook this module consumes).

### Actors
| Actor | Type | Interaction |
|---|---|---|
| User | Human | Asks questions, taps citations, runs/monitors backfill, picks providers |
| Embedding API (Gemini / OpenAI) | Service | Batch-embeds chunks and queries (BYOK) |
| Chat provider (any existing `AIProvider`) | Service | One completion per question via `AIService.completeChat` |
| Core transcription pipelines | Internal | Emit completion/deletion events the index follows |

### External Dependencies
| Dependency | Purpose | Failure Mode |
|---|---|---|
| Gemini `gemini-embedding-001` embedContent/batch (default, 768-dim MRL) | Chunk + query embeddings | No key/quota → fall back to OpenAI if configured, else indexing paused with status UI; questions against a stale index still work |
| OpenAI `text-embedding-3-small` /v1/embeddings (fallback, 1536-dim) | Same | Same (roles swapped) |
| Chat provider via `AIService.completeChat` | Answer generation | Existing per-provider error strings surface in the thread; retrieval results shown even if generation fails |

---

## Architecture

### High-Level Diagram
```
                       ┌────────────────────── VoiceInk core (read-only for ask-ai) ─────────────────────┐
                       │ Transcription(@Model, 3 stores)   .transcriptionCompleted / .transcriptionDeleted │
                       └───────────────▲───────────────────────────────┬───────────────────────────────┘
                                       │ fetch text/meta               │ events
     Backfill (resumable) ─────────────┤                               ▼
                                       │                      TranscriptIndexService
                                       │                        │ chunk (TranscriptChunker)
                                       │                        │ embed (EmbeddingClient, batch)
                                       │                        ▼
                                       │                EmbeddingChunk @Model  ←──  index.store (4th store, .none)
                                       │                        ▲
   AskAIView (.askAI page)             │                        │ scoped fetch (predicate: source/category/date)
     │ question + scope chips          │                        │
     ▼                                 │                        ▼
   AskAIService ── embed(query) ───────┘                RetrievalService (vDSP cosine, top-k 12)
     │  top-k chunks + numbered context                         │
     ├────────── completeChat(provider, system+user) ◄──────────┘
     ▼
   answer + [n] citations → AskAIThread/AskAIMessage (persisted) → citation tap → transcript detail
```

### Components
| Component | Responsibility | Interface |
|---|---|---|
| `TranscriptChunker` | Deterministic chunking (~400–512 tokens via `TokenEstimator`, paragraph/speaker-turn boundaries, configurable overlap) | pure: `chunks(for: Transcription) -> [ChunkDraft]` |
| `EmbeddingClient` | In-repo HTTP clients (Gemini + OpenAI-compatible), batching, backoff; keys via `APIKeyManager` | `embed(texts: [String], model: EmbeddingModel) async throws -> [[Float]]` |
| `TranscriptIndexService` | Index lifecycle: upsert on completion, delete on deletion, backfill (progress/pause/resume, idempotent), model-change invalidation | `@MainActor` singleton; `upsert(_:)`, `delete(transcriptionId:)`, `backfill() -> AsyncStream<Progress>` |
| `RetrievalService` | Scoped fetch → vDSP cosine → top-k with scores | `retrieve(queryVector:scope:k:) -> [ScoredChunk]` |
| `AskAIService` | Prompt assembly (citation rules, 「找不到」 rule), `completeChat`, citation parsing, thread persistence | `ask(question:scope:thread:) async -> AskAIMessage` |
| `AskAIView` + `.askAI` ViewType | Chat page, scope chips, thread list, citation buttons, backfill/settings UI | SwiftUI; registered via the 5 mandatory ViewType edits |

### Data Flow
Write path is event-driven and async (completion event → chunk → batch embed → upsert); the user
only sees index status in the page footer. Read path is synchronous per question: embed the query
(1 call) → scoped fetch + brute-force cosine in-memory → one chat completion → persist message with
citations. Backfill is a long-running cancellable task with the same upsert primitive.

### Sequence (ask, happy path)
```
User → AskAIView: question + scope
AskAIView → AskAIService.ask
AskAIService → EmbeddingClient: embed(query)            (~100–300 ms)
AskAIService → RetrievalService: retrieve(v, scope, 12) (<100 ms in-memory)
AskAIService → AIService.completeChat(context+question) (2–8 s)
AskAIService → index.store: persist AskAIMessage(+citations)
AskAIView ← answer with [n] buttons → tap → transcript detail (sheet; library focus when available)
```

---

## Data Model

### Entities
| Entity | Owner | Lifecycle |
|---|---|---|
| `EmbeddingChunk` (@Model) | `TranscriptIndexService` | Upserted on transcription completion/backfill; deleted with its transcription or on index invalidation |
| `AskAIThread` / `AskAIMessage` (@Model) | `AskAIService` | Created in the chat page; user-deletable |

### Schema (new — all in `index.store`)
See `docs/srs/ask-ai-semantic-qa.srs.md` for field-level detail. Keys: `EmbeddingChunk` identity `(transcriptionId, chunkIndex)`; `#Index` on `[\.transcriptionId]`, `[\.timestamp]`; `vector: Data` (Float32 LE, 768 dims default); `embeddingModel` space tag; denormalized `sourceKind`/`categoryId`/`timestamp` for scope predicates.

### Migration Strategy
- **Forward**: additive — 2–3 new `@Model`s appended to the app `Schema` + a 4th `ModelConfiguration("index", …, cloudKitDatabase: .none)` in both container factories (`VoiceInk.swift:50-56, 236-299`). Core stores untouched.
- **Backward**: deleting `index.store` (or removing the config) loses only derived data; rebuildable via backfill.
- **Backfill**: explicit user-triggered job (cost/quota estimate shown first); resumable; idempotent by chunk identity.
- **Coexistence**: index absent ⇒ page shows empty-state with backfill CTA; core app unaffected.

---

## API Contracts

> No HTTP API served. External calls (BYOK):

### Embedding call (logical contract)
```
Gemini:  POST models/gemini-embedding-001:batchEmbedContents   { texts…, outputDimensionality: 768 } → [[Float]]
OpenAI:  POST /v1/embeddings  { model: text-embedding-3-small, input: [texts] }                      → [[Float]]
```
Constraints: OpenAI input cap 8,191 tokens/item (chunker guarantees ≪); Gemini free tier ~1,500 req/day → batch + backoff; vectors L2-normalized on write so cosine = dot product.

### Answer call (logical contract)
```
system: 你是使用者語音庫的問答助手。只根據提供的片段回答（繁體中文）。每個論點標註 [n] 引用。
        片段不足以回答時明說「資料庫中找不到相關內容」，不得編造引用。
user:   [1] <chunk text + 來源: 標題/日期> … [k] <…>\n\n問題: <question>
→ reuses AIService.completeChat provider routing / keys / error handling unchanged
```

### Internal error surface (`AskAIError`)
| Case | Meaning | Handling |
|---|---|---|
| `noEmbeddingKey` | Neither provider configured | Settings CTA; asking disabled |
| `indexEmpty` | No chunks in scope | Empty-state / suggest widening scope or backfill |
| `embeddingFailed` / `generationFailed` | Provider error after retries | Message-level error bubble; retrieval results still listed on generation failure |

### Versioning Strategy
`embeddingModel` tag per chunk = the version. Model switch ⇒ explicit re-embed prompt; mixed-space comparison is checked and refused at query time.

---

## Non-Functional Requirements

| Category | Target | Measurement | How Achieved |
|---|---|---|---|
| Latency | Retrieval <100 ms @ 50k chunks; end-to-end <10 s | Perf test (`RetrievalServicePerfTests`) + manual timing | In-memory vDSP dot product; single completion call |
| Memory | ≤ ~300 MB transient worst case; scoped loads | Instruments spot check | 768-dim Float32; predicate-scoped vector fetch |
| Cost | Backfill ~1k recordings ≈ free-tier / low $ | Estimate shown pre-backfill | Gemini free tier; batch endpoints |
| Integrity | 0 cross-space comparisons; 0 fabricated citations on control questions | Unit + 20-question eval sheet | Space tag check; citation-parse validation against retrieved set |
| Observability | Per-stage os_log | Console.app filter | `Logger` category `AskAI` |

---

## Technology Choices

| Concern | Choice | Alternatives | Rationale |
|---|---|---|---|
| Embedding model | Gemini `gemini-embedding-001` @ 768 (MRL) | OpenAI 3-small (fallback, kept); `gemini-embedding-2` (preview); Voyage/Cohere | Best-reputation multilingual (CJK) line; free personal tier; 768 dims = 4× storage saving; `-2` revisit at GA |
| Vector store | SwiftData `@Model` in dedicated `index.store` | SQLite sidecar (sqlite-vec); files | Mirrors the proven multi-store pattern; no new deps; drop-store = clean invalidation |
| Similarity | Brute-force cosine via Accelerate/vDSP | FAISS/HNSW ANN | 50k×768 ≈ 150 MB, ≪100 ms/query — ANN crossover ~100k vectors; zero deps |
| Embedding HTTP client | In-repo | Extend LLMkit | LLMkit is remote/non-editable and has no embeddings support (precedent: `ElevenLabsDiarizingClient`) |
| Answer generation | Existing `AIService.completeChat` | New client | Provider routing/keys/errors already solid |
| Chat persistence | New `@Model`s in index store | Reuse `AssistantSession` | Assistant is deliberately in-memory/ephemeral; Ask AI threads are durable artifacts |
| Citations v1 | Detail sheet in-place | Cross-page navigation first | Zero nav plumbing to ship v1; library focus hook (recorder-automation SRS FR-8) upgrades it later |

---

## Integration Points

| Touchpoint | Type | Contract | Backwards Compat |
|---|---|---|---|
| `Schema` + container factories (`VoiceInk.swift:50-56,236-299`) | App bootstrap | +3 models, +1 `ModelConfiguration` in BOTH factories | Yes — additive |
| `.transcriptionCompleted` / `.transcriptionDeleted` notifications | Event consume | Upsert/delete index rows | Yes — observer only |
| `AIService.completeChat` (`AIChatCompletionService.swift:5-77`) | In-process async | One-shot completion | Yes — additive caller |
| `APIKeyManager` (`Services/APIKeyManager.swift:45-48`) | Keychain read | Embedding provider keys (Gemini/OpenAI entries exist) | Yes |
| `ViewType`/`ContentView`/`AppSidebar` (5 edits: `ContentView.swift:4-23,74-110`; `AppSidebar.swift:74-97,106-162`) | UI registration | `.askAI` page under Shared & System | Yes — additive (DEBUG assert enforces completeness) |
| Recording Library focus hook (`pendingFocusTranscriptionId`, spec'd in recorder-automation) | In-process nav | Citation → focused library row | Yes — optional enhancement |

### Rollout Strategy
Inert until an embedding key is configured + backfill run. Kill switch: none needed — removing the page/config leaves core untouched; `index.store` deletable at any time.

---

## Codebase Patterns to Follow

| Pattern | Where to Find | Why Follow |
|---|---|---|
| One-shot chat completion | `Services/AIEnhancement/AIChatCompletionService.swift:5-77` | The answer call |
| Provider/key resolution | `Services/APIKeyManager.swift:12-48`, `AIService.swift:253-267` | Embedding + answer keys/models |
| CJK-aware token estimate | `Services/RecorderAutomation/TokenEstimator.swift:9-31` | Chunk sizing |
| Boundary-aware chunking | `Services/RecorderAutomation/LongTranscriptSummarizer.swift:60-85` | Chunker basis (smaller target size) |
| Multi-store setup | `VoiceInk.swift:236-299` | 4th store registration (both factories!) |
| In-repo provider client (bypass LLMkit) | `Transcription/Cloud/ElevenLabsDiarizingClient.swift` | `EmbeddingClient` shape |
| Chat UI structure | `Views/Recorder/RecorderComponents.swift:396-552` (`AssistantPanelView`) + `Views/Common/MarkdownContentView.swift` | `AskAIView` message list/bubbles |
| Cursor pagination (thread list if needed) | `Views/History/InlineHistoryView.swift:22-59` | Large-list convention |
| ViewType registration | `Views/ContentView.swift:4-23,74-110`, `Views/Sidebar/AppSidebar.swift:74-162` | `.askAI` page wiring |
| JSON-in-raw-field accessor | `Models/Transcription.swift:43-50` | `citationsRaw` accessor shape |

---

## Risks & Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Vector-space lock-in (model deprecation/switch ⇒ full re-embed) | M | M | Space tag + explicit re-embed flow; index is derived data by design |
| CJK chunk/retrieval quality below expectation | M | M | Speaker-turn-aware chunking; eval sheet gate (AC-1); provider switchable |
| Fabricated citations / hallucinated answers | M | H | Strict system prompt + citation-set validation + control questions in eval |
| Index store growth (audio-heavy users) | L | L | 768-dim Float32 ≈ 3 KB/chunk; Float16 option queued |
| SwiftData perf on bulk upsert (backfill) | M | M | Batch inserts in background context; progress + resume |
| Gemini free-tier throttling mid-backfill | M | L | Batch + backoff + resumable job; OpenAI fallback |

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|---|---|---|---|
| Retrieval architecture | Embeddings + brute-force cosine | FTS+LLM rerank; agentic tool-use search | CJK FTS is weak; agentic = multi-call latency/cost; exact search trivial at personal scale |
| Default embedding | Gemini 001 @ 768 | OpenAI 3-small; local models | User: cloud OK; CJK reputation + free tier; fallback kept |
| Index placement | 4th SwiftData store | Rows in default store; SQLite sidecar | Derived-data lifecycle independence; no new deps |
| Page identity | New `.askAI` page + durable threads | Extend Assistant | Different jobs: library QA (durable, cited) vs dictation companion (ephemeral) |
| v1 citation UX | In-place detail sheet | Cross-page jump first | Ships without nav plumbing; upgrade path defined |

---

## Open Questions

- [ ] Which embedding key does the user already have (Gemini vs OpenAI)? — decides default order; confirm at plan time.
- [ ] Float16 vector storage — measure quality/size before switching from Float32.
- [ ] Chunk overlap 10% vs 0% — A/B on real corpus (2026 evidence: overlap may not help).
- [ ] Default answer model — reuse enhancement default vs pin a fast model.
- [ ] Segment-level citation highlight in the detail sheet (Could).
