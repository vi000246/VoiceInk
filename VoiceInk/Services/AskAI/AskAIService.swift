import Foundation
import SwiftData
import os

/// 回答生成的可注入介面(測試用 fake,正式走 AIService.completeChat)。
protocol ChatCompleting {
    func complete(system: String, user: String) async throws -> String
}

enum AskAIError: Error, LocalizedError {
    case noEmbeddingKey
    case indexEmpty
    var errorDescription: String? {
        switch self {
        case .noEmbeddingKey: return "尚未設定 embedding 金鑰"
        case .indexEmpty: return "索引為空,請先建立索引"
        }
    }
}

/// Ask AI 問答:嵌入問題 → scope 檢索 → 組 prompt → completeChat → 驗證引用只指向檢索集
/// → 持久化對話。回答固定繁中,片段不足即明說「找不到」而非編造。
@MainActor
final class AskAIService: ObservableObject {
    static let shared = AskAIService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AskAI")

    private var embedder: EmbeddingProviding = LiveEmbedder()
    private var completer: ChatCompleting?

    private init() {}

    func configureForTesting(embedder: EmbeddingProviding, completer: ChatCompleting) {
        self.embedder = embedder
        self.completer = completer
    }

    func setLiveCompleter(_ completer: ChatCompleting) { self.completer = completer }

    // MARK: - Prompt building (pure, testable)

    /// 預設 persona（未選範本時）。
    static let defaultPersona = "你是使用者個人語音庫的問答助手。"

    /// 固定保留的引用規則段——persona 可換，但這段永遠附加;否則幻覺防護（只據片段、標 [n]、找不到明說）失效。
    static let citationRules = """
    只根據下方提供的片段回答問題,以繁體中文作答。
    每個論點後標註對應的片段編號,格式為 [n](可多個,如 [1][3])。
    若提供的片段不足以回答問題,直接說「資料庫中找不到相關內容」,絕對不要編造答案或引用不存在的片段編號。
    """

    /// 組 system prompt：persona 段（範本提供或預設）＋固定引用規則段。純函式，供測試。
    static func systemPrompt(persona: String? = nil) -> String {
        let trimmed = persona?.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaSection = (trimmed?.isEmpty == false) ? trimmed! : defaultPersona
        return personaSection + "\n" + citationRules
    }

    static func buildUserBlock(question: String, chunks: [ScoredChunk]) -> String {
        var lines: [String] = []
        for (i, scored) in chunks.enumerated() {
            let excerpt = String(scored.chunk.text.prefix(800))
            lines.append("[\(i + 1)] \(excerpt)")
        }
        lines.append("")
        lines.append("問題:\(question)")
        return lines.joined(separator: "\n")
    }

    /// 從回答抽出 [n] 引用,只保留 1...retrieved.count 範圍內的(越界＝幻覺,剔除),去重、保序。
    static func extractCitations(from answer: String, retrieved: [ScoredChunk]) -> [ChunkRef] {
        guard !retrieved.isEmpty else { return [] }
        var seen = Set<Int>()
        var refs: [ChunkRef] = []
        let pattern = try? NSRegularExpression(pattern: #"\[(\d+)\]"#)
        let range = NSRange(answer.startIndex..., in: answer)
        pattern?.enumerateMatches(in: answer, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: answer),
                  let n = Int(answer[r]), n >= 1, n <= retrieved.count, !seen.contains(n) else { return }
            seen.insert(n)
            let chunk = retrieved[n - 1].chunk
            refs.append(ChunkRef(transcriptionId: chunk.transcriptionId,
                                 chunkIndex: chunk.chunkIndex,
                                 excerpt: String(chunk.text.prefix(200))))
        }
        return refs
    }

    // MARK: - Ask

    /// 對語音庫提問。context = index store 的 ModelContext(檢索＋對話持久化)。
    @discardableResult
    func ask(question: String, scope: AskAIScope, thread: AskAIThread?,
             model: EmbeddingModel, context: ModelContext, persona: String? = nil) async throws -> AskAIMessage {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)

        // 持久化 user 訊息。
        let resolvedThread = thread ?? {
            let t = AskAIThread(title: String(trimmed.prefix(30)))
            context.insert(t); return t
        }()
        context.insert(AskAIMessage(thread: resolvedThread, role: "user", text: trimmed))

        // 單檔提問：只問一筆錄音時，直接用它的完整逐字稿當上下文，不經向量索引
        // （索引可能沒回填到這筆／用了不同模型，會誤報「找不到」）。
        if let tid = scope.transcriptionId {
            return await askSingleRecording(transcriptionId: tid, question: trimmed,
                                            thread: resolvedThread, context: context, persona: persona)
        }

        // 嵌入問題(超長問題截斷到 ~8k tokens 以內)。
        let queryText = String(trimmed.prefix(6000))
        let queryVectors = try await embedder.embed(texts: [queryText], model: model)
        guard let queryVector = queryVectors.first else {
            return persistAssistant(text: "資料庫中找不到相關內容。", citations: [],
                                    thread: resolvedThread, context: context)
        }

        let retrieved = RetrievalService.retrieve(queryVector: queryVector, scope: scope, k: 12,
                                                  model: model, context: context)
        // 檢索為空 → 不呼叫生成,直接明說找不到。
        guard !retrieved.isEmpty else {
            return persistAssistant(text: "資料庫中找不到相關內容。", citations: [],
                                    thread: resolvedThread, context: context)
        }

        guard let completer else {
            return persistAssistant(text: "尚未設定回答模型。", citations: [],
                                    thread: resolvedThread, context: context)
        }

        let userBlock = Self.buildUserBlock(question: trimmed, chunks: retrieved)
        let answer: String
        do {
            answer = try await completer.complete(system: Self.systemPrompt(persona: persona), user: userBlock)
        } catch {
            logger.error("Ask AI completion failed: \(error.localizedDescription, privacy: .public)")
            return persistAssistant(text: "回答生成失敗:\(error.localizedDescription)", citations: [],
                                    thread: resolvedThread, context: context)
        }

        let citations = Self.extractCitations(from: answer, retrieved: retrieved)
        return persistAssistant(text: answer, citations: citations,
                                thread: resolvedThread, context: context)
    }

    /// 單檔提問：直接把該筆逐字稿（切塊、限長）餵給回答模型，不依賴向量索引。
    private func askSingleRecording(transcriptionId tid: UUID, question: String,
                                    thread: AskAIThread, context: ModelContext,
                                    persona: String?) async -> AskAIMessage {
        guard let t = (try? context.fetch(FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.id == tid })))?.first else {
            return persistAssistant(text: "找不到這筆錄音（可能已刪除）。", citations: [], thread: thread, context: context)
        }
        let full = (t.enhancedText?.isEmpty == false ? t.enhancedText! : t.text)
        guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return persistAssistant(text: "這筆錄音沒有逐字稿內容可分析。", citations: [], thread: thread, context: context)
        }
        guard let completer else {
            return persistAssistant(text: "尚未設定回答模型。", citations: [], thread: thread, context: context)
        }

        // 切塊（沿用索引用的 chunker）作為 [n] 片段;總量上限，避免超出模型上下文。
        let drafts = TranscriptChunker.chunks(for: full,
            speakerSegments: t.speakerSegmentsAreNative ? t.speakerSegments : [])
        let chunks = drafts.isEmpty ? [ChunkDraft(index: 0, text: full)] : drafts
        let maxChars = 60_000
        var used: [ChunkDraft] = []
        var running = 0
        for c in chunks {
            let piece = String(c.text.prefix(1600))
            if running + piece.count > maxChars { break }
            used.append(ChunkDraft(index: used.count, text: piece))
            running += piece.count
        }
        let truncated = used.count < chunks.count

        var lines: [String] = []
        for (i, c) in used.enumerated() { lines.append("[\(i + 1)] \(c.text)") }
        if truncated { lines.append("（逐字稿較長，僅提供前段內容）") }
        lines.append(""); lines.append("問題:\(question)")
        let userBlock = lines.joined(separator: "\n")

        let answer: String
        do {
            answer = try await completer.complete(system: Self.systemPrompt(persona: persona), user: userBlock)
        } catch {
            logger.error("Single-recording ask failed: \(error.localizedDescription, privacy: .public)")
            return persistAssistant(text: "回答生成失敗:\(error.localizedDescription)", citations: [], thread: thread, context: context)
        }
        let cites = Self.singleRecordingCitations(from: answer, transcriptionId: tid, chunks: used)
        return persistAssistant(text: answer, citations: cites, thread: thread, context: context)
    }

    /// 單檔提問的引用：[n] → 該筆錄音的第 n 塊（越界剔除）。
    static func singleRecordingCitations(from answer: String, transcriptionId tid: UUID,
                                         chunks: [ChunkDraft]) -> [ChunkRef] {
        guard !chunks.isEmpty else { return [] }
        var seen = Set<Int>(); var refs: [ChunkRef] = []
        let pattern = try? NSRegularExpression(pattern: #"\[(\d+)\]"#)
        let range = NSRange(answer.startIndex..., in: answer)
        pattern?.enumerateMatches(in: answer, range: range) { match, _, _ in
            guard let match, let r = Range(match.range(at: 1), in: answer),
                  let n = Int(answer[r]), n >= 1, n <= chunks.count, !seen.contains(n) else { return }
            seen.insert(n)
            refs.append(ChunkRef(transcriptionId: tid, chunkIndex: n - 1,
                                 excerpt: String(chunks[n - 1].text.prefix(200))))
        }
        return refs
    }

    @discardableResult
    private func persistAssistant(text: String, citations: [ChunkRef],
                                  thread: AskAIThread, context: ModelContext) -> AskAIMessage {
        let message = AskAIMessage(thread: thread, role: "assistant", text: text)
        message.citations = citations
        context.insert(message)
        try? context.save()
        return message
    }
}
