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
    ///
    /// 「字面沒對上就別急著說找不到」這條是 2026-07-15 依使用者回報加的:問「今年爬過哪些山」時,
    /// 片段寫的是「玉山」「百岳」而非「山」字,舊版硬規則會讓模型直接拒答。這條只放寬**過度拒答**,
    /// **不動**反幻覺底線(只據片段、標編號、真無關才說找不到)——這是 Ask AI 專用;會議 copilot
    /// 是即時場景不能靠猜,其 prompt(`TierPrompts` / `ResponseCueExtractor`)維持嚴格,不共用這段。
    static let citationRules = """
    只根據下方提供的片段回答問題,以繁體中文作答。
    每個論點後標註對應的片段編號,格式為 [n](可多個,如 [1][3])。
    片段的用詞可能和問題不同、卻是在講同一件事(例:問「山」而片段寫「玉山」「百岳」「合歡」;\
    問「績效」而片段寫「考核」「KPI」)——**只要語意相關就據以回答,不要因為字面沒出現問題裡的那個詞就說找不到**。
    只有在片段**確實與問題無關**時,才說「資料庫中找不到相關內容」;絕對不要編造答案或引用不存在的片段編號。
    """

    /// 組 system prompt：persona 段（範本提供或預設）＋固定引用規則段。純函式，供測試。
    static func systemPrompt(persona: String? = nil) -> String {
        let trimmed = persona?.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaSection = (trimmed?.isEmpty == false) ? trimmed! : defaultPersona
        return personaSection + "\n" + citationRules
    }

    /// 單檔提問專用：餵的是「一整段錄音的完整逐字稿」而非零散檢索片段，所以措辭要自然、
    /// 不要沿用 RAG 那句「片段不足就說『資料庫中找不到相關內容』」——那會讓模型過度拒答。
    static func singleRecordingSystemPrompt(persona: String? = nil) -> String {
        let trimmed = persona?.trimmingCharacters(in: .whitespacesAndNewlines)
        let personaSection = (trimmed?.isEmpty == false) ? trimmed! : "你是使用者的錄音分析助手。"
        return personaSection + "\n" + """
        下方是「一段錄音的完整逐字稿」（可能分段標了 [n]）。請根據這段逐字稿，用繁體中文回答使用者的問題，
        盡量具體、可引用段落編號 [n] 佐證。只有在逐字稿確實完全沒提到時，才說明「這段錄音沒有提到這個」，不要編造。
        """
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
                                 excerpt: String(chunk.text.prefix(600)),
                                 sourceTitle: chunk.sourceTitle,
                                 sourcePath: chunk.sourcePath))
        }
        return refs
    }

    // MARK: - 查詢擴展(多查詢召回;2026-07-15)

    /// 分類器/改寫器 prompt。要求模型吐 2-3 個「用詞不同但語意相近」的檢索查詢。
    static let queryExpansionSystemPrompt = """
    你是檢索查詢改寫器。針對使用者的問題,產生 2-3 個**用詞不同但語意相近**的檢索查詢,\
    涵蓋同義詞、上下位詞與具體實例(例:「山」→「百岳」「登山」「玉山」;「績效」→「考核」「KPI」「年度評核」)。\
    目的是把「講同一件事但字面沒對上」的資料也撈出來。
    只輸出 JSON 字串陣列,例:["改寫一","改寫二"]。不要解釋、不要 markdown、不要問句以外的內容。
    """

    /// 解析擴展查詢 JSON 陣列。任何失敗 → [](沿用 repo `try? JSONDecoder` 容錯慣例)。純函式。
    static func parseExpansions(_ raw: String) -> [String] {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = t.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Array(arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3))
    }

    /// 用快模型把問題改寫成 2-3 個同義查詢。best-effort:未設定 completer / 呼叫失敗 / 解析失敗 → []。
    private func queryExpansions(for question: String) async -> [String] {
        guard let completer else { return [] }
        do {
            let reply = try await completer.complete(system: Self.queryExpansionSystemPrompt, user: question)
            return Self.parseExpansions(reply)
        } catch {
            logger.error("Ask AI 查詢擴展失敗(退回原始檢索): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// 多查詢召回:原始檢索結果 + 各擴展查詢的檢索結果,以 chunk 身分取聯集、保留最高分、取前 12。
    ///
    /// max-score fusion:一段筆記只要**強配上任一個查詢變體**就能浮上來(問「山」時 base 撈不到,
    /// 但「百岳」變體撈得到 → 該段以「百岳」的高分擠掉 base 裡較不相關的段)。送進答案的仍是 12 段,
    /// prompt 大小不變,只是換成更相關的 12 段。全程 best-effort,任一步失敗回 `base`。
    private func augmentWithExpandedQueries(base: [ScoredChunk], question: String, scope: AskAIScope,
                                            model: EmbeddingModel, context: ModelContext) async -> [ScoredChunk] {
        let expansions = await queryExpansions(for: question)
        guard !expansions.isEmpty else { return base }

        let vectors: [[Float]]
        do { vectors = try await embedder.embed(texts: expansions, model: model) }
        catch {
            logger.error("Ask AI 擴展查詢嵌入失敗(退回原始檢索): \(error.localizedDescription, privacy: .public)")
            return base
        }

        // base(原始查詢已檢索好)+ 各擴展查詢的檢索結果,以 chunk 身分取聯集、保留最高分、取前 12。
        let expandedGroups = vectors.map {
            RetrievalService.retrieve(queryVector: $0, scope: scope, k: 12, model: model, context: context)
        }
        return RetrievalService.fuseByMaxScore([base] + expandedGroups, k: 12)
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
            return persistAssistant(text: "問題嵌入失敗——請確認 embedding 金鑰與網路。", citations: [],
                                    thread: resolvedThread, context: context)
        }

        let base = RetrievalService.retrieve(queryVector: queryVector, scope: scope, k: 12,
                                             model: model, context: context)
        // 檢索為空 → 不呼叫生成(含不做查詢擴展:索引/篩選本身是空的,擴展也撈不到,還白花一次
        // LLM 呼叫);先診斷原因再回報（模型不符/索引空/篩選太窄）。這也保住了「空檢索不呼叫 LLM」
        // 的契約(AskAIAnswerTests.testEmptyRetrievalShortCircuits)。
        guard !base.isEmpty else {
            return persistAssistant(text: diagnoseEmptyRetrieval(scope: scope, model: model, context: context),
                                    citations: [], thread: resolvedThread, context: context)
        }

        // 查詢擴展(治本召回,2026-07-15):原問題撈到東西了,再用同義/具體化改寫多撈幾條、聯集後
        // 重排取前 12。字面沒對上的資料(問「山」、筆記寫「百岳」)靠這個進入答案上下文。
        // 全程 best-effort——擴展的任何一步失敗都退回原始檢索,絕不比現況差;送進答案的仍是 12 段。
        let retrieved = await augmentWithExpandedQueries(base: base, question: trimmed,
                                                         scope: scope, model: model, context: context)

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

    /// 全庫檢索為空時，判斷原因並回一句可行動的說明（而非一律「找不到」）。
    private func diagnoseEmptyRetrieval(scope: AskAIScope, model: EmbeddingModel, context: ModelContext) -> String {
        let modelTag = model.tag
        let noteKind = ObsidianNoteIndexService.sourceKind
        let totalAll = (try? context.fetchCount(FetchDescriptor<EmbeddingChunk>())) ?? 0
        let forModel = (try? context.fetchCount(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.embeddingModel == modelTag }))) ?? 0
        // 現行向量空間裡的筆記塊數：分得出「筆記沒索引」與「筆記有索引但沒命中」。
        let obsidianCount = (try? context.fetchCount(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.sourceKind == noteKind && $0.embeddingModel == modelTag }))) ?? 0
        return Self.emptyRetrievalMessage(
            scopeSources: scope.sources, totalAll: totalAll, forModel: forModel,
            obsidianCount: obsidianCount,
            hasCategoryOrDateFilter: scope.categoryName != nil || scope.categoryId != nil
                || scope.dateRange != nil)
    }

    /// 索引統計 + scope → 一句可行動的說明。純函式（不碰 store）以便測試。
    ///
    /// GOTCHA：判斷「篩選太窄」**不能**只看 `scopeSources != nil`。雙 chip 上線後 `sources`
    /// 恆為非 nil（`.all` 也回明確的三種 kind），拿 nil 當「沒篩選」會讓每一次空檢索都叫使用者
    /// 「把篩選改回全部」——即使他根本沒篩。窄不窄要看它**有沒有涵蓋全部 kind**。
    static func emptyRetrievalMessage(scopeSources: Set<String>?, totalAll: Int, forModel: Int,
                                      obsidianCount: Int, hasCategoryOrDateFilter: Bool) -> String {
        if totalAll == 0 {
            return "索引是空的，請按右上齒輪的『重建語音庫索引』後再問。"
        }
        if forModel == 0 {
            return "目前的 embedding 模型和既有索引不一致（索引是用別的模型建立的）。請按右上齒輪選回原本的模型，或按『重建語音庫索引』以目前模型重新嵌入。"
        }

        let noteKind = ObsidianNoteIndexService.sourceKind
        // 只問筆記、而筆記索引是空的 → 指向筆記那條路。「重建語音庫索引」只回填逐字稿，
        // 對筆記毫無幫助——照舊回「找不到」等於叫使用者去按一顆不會有效果的按鈕。
        // 混合 scope 不走這條：轉錄塊可能只是沒命中，說成「筆記沒索引」是誤導。
        if let s = scopeSources, s == [noteKind], obsidianCount == 0 {
            return "筆記還沒有建立索引。到右上齒輪「筆記來源設定」選好 vault，再按『重建筆記庫索引』——那頁的「索引覆蓋率」也看得到哪些檔還沒進索引。"
        }

        let allKinds: Set<String> = ["dictation", "recorder", "meeting", noteKind]
        let sourcesNarrow = scopeSources.map { !allKinds.isSubset(of: $0) } ?? false
        if hasCategoryOrDateFilter || sourcesNarrow {
            return "在目前的篩選範圍（來源／分類／時間）內找不到相關內容。試著把上方篩選放寬再問一次。"
        }
        return "資料庫中找不到相關內容。"
    }

    /// 單檔提問：直接把該筆逐字稿（切塊、限長）餵給回答模型，不依賴向量索引。
    private func askSingleRecording(transcriptionId tid: UUID, question: String,
                                    thread: AskAIThread, context: ModelContext,
                                    persona: String?) async -> AskAIMessage {
        guard let t = (try? context.fetch(FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.id == tid })))?.first else {
            return persistAssistant(text: "找不到這筆錄音（可能已刪除）。", citations: [], thread: thread, context: context)
        }
        // 單檔問答用「最完整」的原始逐字稿（套用後結果常是精簡摘要，答不了細節）;原始為空才退回。
        let full = t.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (t.enhancedText ?? "") : t.text
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
            answer = try await completer.complete(system: Self.singleRecordingSystemPrompt(persona: persona), user: userBlock)
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
                                 excerpt: String(chunks[n - 1].text.prefix(600))))
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
