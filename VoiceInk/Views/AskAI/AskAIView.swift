import SwiftUI
import SwiftData
import LLMkit

/// 把 AIService.completeChat 包成 AskAIService 需要的 ChatCompleting。
private struct LiveChatCompleter: ChatCompleting {
    let aiService: AIService
    let provider: AIProvider
    func complete(system: String, user: String) async throws -> String {
        try await aiService.completeChat(
            provider: provider, modelName: nil,
            messages: [ChatMessage.user(user)], systemPrompt: system, timeout: 60)
    }
}

struct AskAIView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var aiService: AIService
    @StateObject private var indexService = TranscriptIndexService.shared
    @StateObject private var recorderStore = RecorderConfigStore.shared

    @Query(sort: \EmbeddingChunk.timestamp) private var allChunks: [EmbeddingChunk]

    @State private var thread: AskAIThread?
    @State private var messages: [AskAIMessage] = []
    @State private var question = ""
    @State private var isAsking = false

    // Scope
    @State private var sourceFilter: String = "all"     // all/dictation/recorder/meeting
    @State private var categoryId: UUID?
    @State private var dateFilter: String = "all"       // all/7d/30d

    // Backfill
    @State private var backfillProgress: TranscriptIndexService.Progress?

    // Citation sheet
    @State private var focusTranscription: Transcription?

    private var hasEmbeddingKey: Bool {
        let key = APIKeyManager.shared.getAPIKey(forProvider: indexService.model.providerName)
        return !(key ?? "").isEmpty
    }
    private var indexIsEmpty: Bool { allChunks.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Ask AI",
                infoMessage: "用自然語言問你的語音庫（聽寫／錄音／會議）。回答會標註來源片段，點擊可跳到原始逐字稿。索引與問答都用雲端 embedding（BYOK）。",
                infoURL: nil
            ) { headerControls }

            if !hasEmbeddingKey {
                emptyState(icon: "key.slash",
                           title: "尚未設定 embedding 金鑰",
                           detail: "Ask AI 需要 \(indexService.model.displayName) 的 API 金鑰。請到「Transcription & AI Models」設定 \(indexService.model.providerName) 金鑰。")
            } else if let progress = backfillProgress {
                backfillBanner(progress)
            } else if indexIsEmpty {
                emptyState(icon: "tray",
                           title: "索引是空的",
                           detail: "先建立索引，才能對你的語音庫提問。",
                           action: ("建立索引", startBackfill))
            } else {
                conversation
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $focusTranscription) { t in
            TranscriptionDetailView(transcription: t)
                .frame(minWidth: 480, minHeight: 400)
        }
    }

    // MARK: - Header controls

    private var headerControls: some View {
        HStack(spacing: 8) {
            if !indexIsEmpty {
                Button {
                    thread = nil; messages = []
                } label: { Label("新對話", systemImage: "square.and.pencil") }
                Button(action: startBackfill) {
                    Label("重建索引", systemImage: "arrow.clockwise")
                }.help("重新索引所有轉錄（新增的會自動索引，這裡用於一次性回填舊資料）")
            }
        }
    }

    // MARK: - Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            scopeBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(messages) { message in
                            messageBubble(message).id(message.persistentModelID)
                        }
                        if isAsking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("查詢中…").foregroundStyle(.secondary)
                            }.padding(.horizontal, 14)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: messages.count) {
                    if let last = messages.last { withAnimation { proxy.scrollTo(last.persistentModelID, anchor: .bottom) } }
                }
            }
            inputRow
        }
    }

    private var scopeBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $sourceFilter) {
                Text("全部來源").tag("all")
                Text("聽寫").tag("dictation")
                Text("錄音").tag("recorder")
                Text("會議").tag("meeting")
            }.fixedSize()
            Picker("", selection: $categoryId) {
                Text("全部分類").tag(UUID?.none)
                ForEach(recorderStore.categories) { c in Text(c.name).tag(UUID?.some(c.id)) }
            }.fixedSize()
            Picker("", selection: $dateFilter) {
                Text("不限時間").tag("all")
                Text("近 7 天").tag("7d")
                Text("近 30 天").tag("30d")
            }.fixedSize()
            Spacer()
        }
        .labelsHidden()
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    @ViewBuilder
    private func messageBubble(_ message: AskAIMessage) -> some View {
        let isUser = message.role == "user"
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            HStack(spacing: 0) {
                if isUser { Spacer(minLength: 40) }
                bubbleContent(message, isUser: isUser)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isUser ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.10))
                    }
                if !isUser { Spacer(minLength: 40) }
            }
            if !message.citations.isEmpty {
                citationRow(message.citations)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    @ViewBuilder
    private func bubbleContent(_ message: AskAIMessage, isUser: Bool) -> some View {
        if isUser {
            Text(message.text).textSelection(.enabled)
        } else {
            MarkdownContentView(message.text, fontSize: 13, foregroundColor: .primary)
        }
    }

    private func citationRow(_ citations: [ChunkRef]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(citations.enumerated()), id: \.offset) { index, ref in
                Button {
                    openCitation(ref)
                } label: {
                    Text("[\(index + 1)]")
                        .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                }
                .buttonStyle(.plain)
                .help(ref.excerpt)
            }
        }
    }

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("問你的語音庫……", text: $question, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || isAsking)
        }
        .padding(12)
    }

    // MARK: - Empty / backfill states

    private func emptyState(icon: String, title: String, detail: String,
                            action: (String, () -> Void)? = nil) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 380)
            if let (label, run) = action {
                Button(label, action: run).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func backfillBanner(_ progress: TranscriptIndexService.Progress) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                .frame(maxWidth: 320)
            Text("建立索引中… \(progress.done)/\(progress.total)")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("預估 \(progress.estimatedTokens / 1000)k tokens")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !isAsking else { return }
        question = ""
        isAsking = true
        AskAIService.shared.setLiveCompleter(LiveChatCompleter(aiService: aiService, provider: aiService.selectedProvider))
        Task {
            defer { isAsking = false }
            do {
                _ = try await AskAIService.shared.ask(
                    question: q, scope: currentScope, thread: thread,
                    model: indexService.model, context: modelContext)
                reloadMessages()
            } catch {
                NotificationManager.shared.showNotification(
                    title: "提問失敗：\(error.localizedDescription)", type: .error, duration: 5)
            }
        }
    }

    private var currentScope: AskAIScope {
        let sources: Set<String>? = sourceFilter == "all" ? nil : [sourceFilter]
        let range: ClosedRange<Date>?
        switch dateFilter {
        case "7d": range = Date().addingTimeInterval(-7 * 86400)...Date().addingTimeInterval(86400)
        case "30d": range = Date().addingTimeInterval(-30 * 86400)...Date().addingTimeInterval(86400)
        default: range = nil
        }
        return AskAIScope(sources: sources, categoryId: categoryId, dateRange: range)
    }

    private func reloadMessages() {
        // ask() 建立/沿用 thread;抓最新一個 thread 的訊息(單對話 v1)。
        if thread == nil {
            thread = (try? modelContext.fetch(FetchDescriptor<AskAIThread>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)])))?.first
        }
        guard let thread else { messages = []; return }
        let tid = thread.persistentModelID
        let fetched = (try? modelContext.fetch(FetchDescriptor<AskAIMessage>(
            sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        messages = fetched.filter { $0.thread?.persistentModelID == tid }
    }

    private func openCitation(_ ref: ChunkRef) {
        let targetId = ref.transcriptionId
        let match = (try? modelContext.fetch(FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.id == targetId })))?.first
        if let match {
            focusTranscription = match
        } else {
            NotificationManager.shared.showNotification(
                title: "來源逐字稿已被刪除", type: .warning, duration: 4)
        }
    }

    private func startBackfill() {
        Task {
            for await progress in indexService.backfill() {
                backfillProgress = progress
            }
            backfillProgress = nil
            reloadMessages()
        }
    }
}
