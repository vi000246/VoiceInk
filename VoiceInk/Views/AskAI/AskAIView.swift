import SwiftUI
import SwiftData
import LLMkit

/// 把 AIService.completeChat 包成 AskAIService 需要的 ChatCompleting。
private struct LiveChatCompleter: ChatCompleting {
    let aiService: AIService
    let provider: AIProvider
    var modelName: String?
    func complete(system: String, user: String) async throws -> String {
        try await aiService.completeChat(
            provider: provider, modelName: modelName,
            messages: [ChatMessage.user(user)], systemPrompt: system, timeout: 60)
    }
}

struct AskAIView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var aiService: AIService
    @StateObject private var indexService = TranscriptIndexService.shared
    @StateObject private var recorderStore = RecorderConfigStore.shared

    @Query(sort: \EmbeddingChunk.timestamp) private var allChunks: [EmbeddingChunk]
    @Query(sort: \AskAITemplate.createdAt) private var askTemplates: [AskAITemplate]

    @State private var thread: AskAIThread?
    @State private var messages: [AskAIMessage] = []
    @State private var question = ""
    @State private var isAsking = false

    @ObservedObject private var sidebarModel = LibrarySidebarModel.shared
    @ObservedObject private var notesConfig = ObsidianRAGConfigStore.shared

    // Scope
    /// 知識庫兩大來源，各自獨立開關（可同時開）。持久化以免每次回到頁面都要重選。
    @AppStorage("askAIScopeTranscriptsV1") private var scopeTranscripts = true
    @AppStorage("askAIScopeNotesV1") private var scopeNotes = false
    @State private var sourceFilter: AskAISourceFilter = .all   // 全部 / 語音輸入 / 錄音輸入(含會議)
    @State private var categoryNameFilter: String?              // 依分類/tag 名稱（統一 displayTag）
    @State private var dateFilter: String = "all"       // all/7d/30d
    /// 單檔限定（管理頁「Ask AI」按鈕帶入）;非 nil 時覆蓋上面的來源/分類/日期。
    @State private var focusedTranscriptionId: UUID?
    @State private var focusedTitle: String?
    /// 選用的分析角色（persona）範本 id;nil = 無。
    @State private var personaId: UUID?

    // 答案模型（Ask AI 專用，與 embedding／enhancement 預設分離）。
    @AppStorage(AskAIAnswerModel.providerKey) private var answerProviderRaw = ""
    @AppStorage(AskAIAnswerModel.modelKey) private var answerModelRaw = ""

    // Backfill
    @State private var backfillProgress: TranscriptIndexService.Progress?

    // Citation sheet
    @State private var focusTranscription: Transcription?
    @State private var citationTarget: CitationContext?

    // Embedding-model switch
    @State private var pendingModelSwitch: EmbeddingModel?

    /// FR-7:筆記來源設定 sheet（vault／索引範圍／重建）。
    @State private var showNotesSettings = false

    private var hasEmbeddingKey: Bool {
        let key = APIKeyManager.shared.getAPIKey(forProvider: indexService.model.providerName)
        return !(key ?? "").isEmpty
    }
    private var indexIsEmpty: Bool { allChunks.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Ask AI",
                infoMessage: "用自然語言問你的知識庫（聽寫／錄音／會議／Obsidian 筆記）。回答會標註來源片段，點擊可看出處。索引與問答都用雲端 embedding（BYOK）。",
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
        .onAppear {
            sidebarModel.refresh(modelContext)
            // 筆記 chip 開著就順手增量掃一次（single-flight，vault 沒動就是 no-op）。
            if scopeNotes { kickNotesAutoIndex() }
            // 後備：若 onReceive 沒接到（時序/首次建立），這裡再消費一次單檔提問目標。
            if let id = AppNavigator.shared.pendingAskTranscriptionId {
                focusScope(on: id)
                AppNavigator.shared.consumePendingAsk()
            }
        }
        .sheet(item: $focusTranscription) { t in
            TranscriptionDetailView(transcription: t)
                .frame(minWidth: 480, minHeight: 400)
        }
        .sheet(isPresented: $showNotesSettings) {
            AskAINotesSettingsSheet()
                .frame(width: 560, height: 520)
        }
        .centeredModal(item: $citationTarget) { ctx in
            CitationPopup(context: ctx,
                          onClose: { citationTarget = nil },
                          onOpenFull: { t in citationTarget = nil; focusTranscription = t })
                .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.Border.control, lineWidth: 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
        .onReceive(AppNavigator.shared.$pendingAskTranscriptionId) { id in
            guard let id else { return }
            focusScope(on: id)
            AppNavigator.shared.consumePendingAsk()
        }
        .confirmationDialog("切換 embedding 模型需要重建整個索引",
                            isPresented: Binding(get: { pendingModelSwitch != nil },
                                                 set: { if !$0 { pendingModelSwitch = nil } }),
                            titleVisibility: .visible) {
            if let target = pendingModelSwitch {
                Button("清空並重建索引（\(allChunks.count) 個片段）", role: .destructive) {
                    indexService.switchModel(to: target)
                    pendingModelSwitch = nil
                    startBackfill()
                }
            }
            Button("取消", role: .cancel) { pendingModelSwitch = nil }
        } message: {
            Text("不同模型的向量空間互不相容，切換後現有索引會被清空並以新模型重新嵌入。")
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
            Menu {
                Picker("Embedding 模型", selection: embeddingModelBinding) {
                    ForEach(EmbeddingModel.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Picker("回答模型", selection: answerChoiceBinding) {
                    Text("預設（跟隨 AI Models：\(aiService.selectedProvider.rawValue)）").tag(RecorderModelChoice?.none)
                    ForEach(recorderModelChoices(aiService), id: \.self) { c in
                        Text(c.label).tag(RecorderModelChoice?.some(c))
                    }
                }
                Divider()
                Button("筆記來源設定…") { showNotesSettings = true }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuIndicator(.hidden)
            .help("Embedding／回答模型／筆記來源設定")
        }
    }

    /// 換 embedding 模型:若索引非空,先確認(需全量重嵌);空索引直接切換。
    private var embeddingModelBinding: Binding<EmbeddingModel> {
        Binding(
            get: { indexService.model },
            set: { newModel in
                guard newModel != indexService.model else { return }
                if allChunks.isEmpty {
                    indexService.switchModel(to: newModel)
                } else {
                    pendingModelSwitch = newModel
                }
            }
        )
    }

    /// 回答模型選擇（provider·model）;nil = 跟隨 AI Models 預設。存進 AppStorage。
    private var answerChoiceBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard !answerProviderRaw.isEmpty else { return nil }
                return RecorderModelChoice(provider: answerProviderRaw, model: answerModelRaw)
            },
            set: {
                answerProviderRaw = $0?.provider ?? ""
                answerModelRaw = $0?.model ?? ""
            }
        )
    }

    /// 目前選的分析角色 persona 文字（nil = 無）。
    private var selectedPersona: String? {
        guard let personaId else { return nil }
        return askTemplates.first { $0.id == personaId }?.systemPrompt
    }

    // MARK: - Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            scopeBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if messages.count > renderedMessageCap {
                            Text("（僅顯示最近 \(renderedMessageCap) 則;較早的訊息仍在此對話中。按右上「新對話」可重新開始）")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 4)
                        }
                        // 只渲染最近 N 則:多則長回答的 Markdown view 樹會爆記憶體、拖垮甚至當掉。
                        ForEach(messages.suffix(renderedMessageCap)) { message in
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
            if let focusedTitle {
                // 單檔限定：覆蓋一般來源/分類/日期篩選。
                HStack(spacing: 5) {
                    Image(systemName: "target").font(.system(size: 11))
                    Text("限定：\(focusedTitle)").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Button {
                        focusedTranscriptionId = nil
                        self.focusedTitle = nil
                    } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(AppTheme.Accent.primary.opacity(0.14)))
                .foregroundStyle(AppTheme.Accent.primary)
            } else {
                // 知識庫來源雙 chip：語音庫／Obsidian 筆記，可單開也可同時開（不可全關）。
                scopeChip("🎙 語音庫", isOn: scopeTranscripts) { toggleChip(transcripts: true) }
                    .help("把聽寫／錄音／會議逐字稿納入檢索")
                scopeChip("📝 Obsidian 筆記", isOn: scopeNotes) { toggleChip(transcripts: false) }
                    .disabled(notesVaultMissing)
                    .help(notesVaultMissing
                          ? "尚未設定筆記 vault — 到齒輪「筆記來源設定」選擇"
                          : "把 Obsidian 筆記納入檢索")

                // 下面三個 facet 只作用在逐字稿（筆記塊豁免來源/分類/日期），語音庫關掉就一併收起。
                if scopeTranscripts {
                    Picker("", selection: $sourceFilter) {
                        ForEach(AskAISourceFilter.allCases) { f in Text(f.label).tag(f) }
                    }.fixedSize()
                    .onChange(of: sourceFilter) { _, _ in categoryNameFilter = nil }   // 換來源→自動清分類
                    categoryMenu
                    Picker("", selection: $dateFilter) {
                        Text("不限時間").tag("all")
                        Text("近 7 天").tag("7d")
                        Text("近 30 天").tag("30d")
                    }.fixedSize()
                }
            }

            Spacer()

            // 分析角色（persona）範本。
            if !askTemplates.isEmpty {
                Picker("", selection: $personaId) {
                    Text("無分析角色").tag(UUID?.none)
                    ForEach(askTemplates) { t in Text(t.title).tag(UUID?.some(t.id)) }
                }.fixedSize()
                .help("選一個 Ask AI 範本，讓回答以該視角展開")
            }
        }
        .labelsHidden()
        .padding(.horizontal, 14).padding(.vertical, 8)
        // facet 隨語音庫一起藏起來時，把分類殘值一併清掉——否則下次重開語音庫，
        // 一個看不見的舊分類會悄悄套用，使用者只會看到「怎麼都查不到東西」。
        .onChange(of: scopeTranscripts) { _, on in if !on { categoryNameFilter = nil } }
    }

    /// 尚未設定（且錄音匯出也沒有）任何 vault → 筆記 chip 不給點。
    private var notesVaultMissing: Bool { notesConfig.effectiveVaultRoot() == nil }

    /// scope chip：選中 = accent 填色＋checkmark;未選 = secondary 描邊。鏡射單檔限定膠囊的樣式。
    private func scopeChip(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isOn {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(isOn ? AppTheme.Accent.primary.opacity(0.14) : Color.clear))
            .overlay(Capsule().strokeBorder(isOn ? Color.clear : AppTheme.Border.control, lineWidth: 0.8))
            .foregroundStyle(isOn ? AppTheme.Accent.primary : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// 兩顆 chip 至少要開一顆——全關等於「什麼都不查」，是個沒有意義又難察覺的狀態，直接不給關。
    private func toggleChip(transcripts: Bool) {
        if transcripts {
            guard !(scopeTranscripts && !scopeNotes) else { return }   // 禁全關
            scopeTranscripts.toggle()
        } else {
            guard !notesVaultMissing else { return }                   // disabled 的第二道防線
            guard !(scopeNotes && !scopeTranscripts) else { return }   // 禁全關
            scopeNotes.toggle()
            if scopeNotes { kickNotesAutoIndex() }   // 由關轉開 → 立刻補一次增量掃
        }
    }

    /// 背景增量索引筆記（single-flight 在 service 內;失敗只寫 log，不打擾使用者）。
    private func kickNotesAutoIndex() {
        guard let vault = notesConfig.effectiveVaultRoot(),
              let stateURL = try? ObsidianNoteIndexService.defaultStateURL() else { return }
        let include = notesConfig.includeOnlyFolders
        let exclude = notesConfig.excludedFolders
        let ctx = modelContext
        Task {
            await ObsidianNoteIndexService.autoIndex(
                vaultRoot: vault, includeOnly: include, excluded: exclude,
                stateURL: stateURL, modelContext: ctx)
        }
    }

    // 分類/tag 名稱來源：錄音分類 vs 語音 tag。兩者都出現的名稱 → 「通用」。
    private var recorderNames: [String] { sidebarModel.recorderCategories.map(\.name) }
    private var voiceNames: [String] { sidebarModel.voiceTags.map(\.name) }
    private var sharedNames: [String] { Array(Set(recorderNames).intersection(voiceNames)).sorted() }
    private var recorderOnlyNames: [String] { recorderNames.filter { !sharedNames.contains($0) } }
    private var voiceOnlyNames: [String] { voiceNames.filter { !sharedNames.contains($0) } }

    /// 依目前來源自動篩選的分類下拉（全部→group by 通用/錄音/語音;選特定來源→只列該來源）。
    private var categoryMenu: some View {
        Menu {
            Button { categoryNameFilter = nil } label: {
                Label("全部分類", systemImage: categoryNameFilter == nil ? "checkmark" : "")
            }
            switch sourceFilter {
            case .recorder:
                categorySection(nil, recorderNames)
            case .voice:
                categorySection(nil, voiceNames)
            case .all:
                categorySection("通用", sharedNames)
                categorySection("錄音", recorderOnlyNames)
                categorySection("語音", voiceOnlyNames)
            }
        } label: {
            HStack(spacing: 4) {
                Text(categoryNameFilter ?? "全部分類")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private func categorySection(_ title: String?, _ names: [String]) -> some View {
        if !names.isEmpty {
            Section(title ?? "") {
                ForEach(names, id: \.self) { name in
                    Button { categoryNameFilter = name } label: {
                        Label(name, systemImage: categoryNameFilter == name ? "checkmark" : "")
                    }
                }
            }
        }
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

    /// 對話最多渲染的訊息數（較早的仍保存在此對話）。
    private let renderedMessageCap = 12
    /// 超過此長度的回答改用純文字渲染（Markdown 會為大量區塊建龐大 view 樹，長回答會拖垮/當掉）。
    private let markdownMaxChars = 5000

    @ViewBuilder
    private func bubbleContent(_ message: AskAIMessage, isUser: Bool) -> some View {
        if isUser {
            Text(message.text).textSelection(.enabled)
        } else if message.text.count > markdownMaxChars {
            // 超長回答：純文字（可選取），內容完整，只是不套 Markdown 格式，換取穩定不當掉。
            Text(message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            TextField("問你的知識庫……", text: $question, axis: .vertical)
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
        // 解析 Ask AI 專用回答模型（未設 → 跟隨 AI Models 預設 provider）。
        let resolved = AskAIAnswerModel.resolve(
            storedProvider: answerProviderRaw.isEmpty ? nil : answerProviderRaw,
            storedModel: answerModelRaw.isEmpty ? nil : answerModelRaw,
            defaultProvider: aiService.selectedProvider.rawValue,
            available: aiService.connectedProviders.map(\.rawValue))
        let provider = AIProvider(rawValue: resolved.provider) ?? aiService.selectedProvider
        AskAIService.shared.setLiveCompleter(
            LiveChatCompleter(aiService: aiService, provider: provider, modelName: resolved.model))
        let persona = selectedPersona
        Task {
            defer { isAsking = false }
            do {
                // 單檔提問走 AskAIService 內的直餵逐字稿路徑（免索引）;全庫走向量檢索。
                _ = try await AskAIService.shared.ask(
                    question: q, scope: currentScope, thread: thread,
                    model: indexService.model, context: modelContext, persona: persona)
                reloadMessages()
            } catch {
                NotificationManager.shared.showNotification(
                    title: "提問失敗：\(error.localizedDescription)", type: .error, duration: 5)
            }
        }
    }

    private var currentScope: AskAIScope {
        // 單檔限定覆蓋一切其他 scope。
        if let focusedTranscriptionId {
            return AskAIScope(sources: nil, categoryId: nil, dateRange: nil,
                              transcriptionId: focusedTranscriptionId)
        }
        let range: ClosedRange<Date>?
        switch dateFilter {
        case "7d": range = Date().addingTimeInterval(-7 * 86400)...Date().addingTimeInterval(86400)
        case "30d": range = Date().addingTimeInterval(-30 * 86400)...Date().addingTimeInterval(86400)
        default: range = nil
        }
        // 來源集合由雙 chip 組出（語音庫關掉時 sourceFilter 不參與）。
        // 分類/日期是逐字稿專屬 facet：語音庫關掉時一律不帶，否則會連筆記塊一起濾掉。
        let sources = AskAIScopeComposer.sources(
            transcriptsOn: scopeTranscripts, notesOn: scopeNotes, filter: sourceFilter)
        return AskAIScope(sources: sources,
                          categoryName: scopeTranscripts ? categoryNameFilter : nil,
                          dateRange: scopeTranscripts ? range : nil)
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

    /// 從管理頁「Ask AI」進來：限定 scope 到單一錄音並開新對話。
    /// 一律設定 id（scope 才會生效）;標題只是顯示用，抓不到也不影響提問。
    private func focusScope(on id: UUID) {
        focusedTranscriptionId = id
        let match = (try? modelContext.fetch(FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.id == id })))?.first
        focusedTitle = match?.recorderTitle ?? match.map { String($0.text.prefix(20)) } ?? "選定的錄音"
        thread = nil
        messages = []
    }

    private func openCitation(_ ref: ChunkRef) {
        let targetId = ref.transcriptionId
        let match = (try? modelContext.fetch(FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.id == targetId })))?.first
        // 筆記塊的 transcriptionId 是合成 UUID，fetch 必定落空 → 舊的 "來源錄音" 尾巴會把
        // 一則 Obsidian 筆記誤稱成錄音。先試轉錄標題／首句，再退回筆記標題，最後才中性字樣。
        let title = match?.recorderTitle ?? match.map { String($0.text.prefix(24)) }
            ?? ref.sourceTitle ?? "來源"
        citationTarget = CitationContext(ref: ref, title: title, transcription: match)
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

// MARK: - Citation popup（出處）

/// 引用出處的內容：一段被引用的逐字稿片段 + 它來自哪一筆錄音（可再開完整逐字稿）。
struct CitationContext: Identifiable {
    let id = UUID()
    let ref: ChunkRef
    let title: String
    let transcription: Transcription?
}

/// 點引用 [n] 開的出處小視窗：只顯示「這段回答出自哪一段」，不再直接攤開整篇逐字稿。
/// 兩種出處共用同一個殼：轉錄 → 可開完整逐字稿；Obsidian 筆記（`sourcePath` 非 nil）→ 可回 Obsidian 開原檔。
private struct CitationPopup: View {
    let context: CitationContext
    let onClose: () -> Void
    let onOpenFull: (Transcription) -> Void

    @StateObject private var notesConfig = ObsidianRAGConfigStore.shared

    /// 筆記塊的判別式：只有 obsidian 來源會帶 `sourcePath`（轉錄塊恆 nil）。
    private var isNote: Bool { context.ref.sourcePath != nil }

    /// 筆記檔仍在、vault 也解析得出來，才給連結。任一不成立 → nil → 按鈕整個不 render
    /// （筆記被刪／vault 未設 → popup 仍照常顯示標題＋片段，不會留一顆點了沒反應的死按鈕）。
    private var obsidianURL: URL? {
        guard let path = context.ref.sourcePath,
              let vault = notesConfig.effectiveVaultRoot() else { return nil }
        // vault 是 security-scoped bookmark 解析出來的 URL —— 碰檔案前要開 scope
        // （非沙盒下是 no-op，照 house 慣例包起來；鏡射 ObsidianNoteIndexService.reindex）。
        let accessing = vault.startAccessingSecurityScopedResource()
        defer { if accessing { vault.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: vault.appendingPathComponent(path).path) else { return nil }
        return ObsidianLink.openURL(vaultRoot: vault, relativePath: path)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "出處", onClose: onClose)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: isNote ? "doc.richtext" : "quote.opening")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(context.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                }
                Text("這段回答引用的出處段落：").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(context.ref.excerpt.isEmpty ? "（無片段內容）" : context.ref.excerpt)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 300)
                .background(AppTheme.Surface.control, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.Border.control, lineWidth: 0.5))
                // 兩種出處互斥：筆記塊沒有對應的 Transcription，轉錄塊沒有 sourcePath。
                // 筆記出處不掛「開啟完整逐字稿」——那顆開的是錄音詳情，對筆記毫無意義。
                if !isNote, let t = context.transcription {
                    HStack {
                        Spacer()
                        Button { onOpenFull(t) } label: {
                            Label("開啟完整逐字稿", systemImage: "doc.text")
                        }.controlSize(.small)
                    }
                } else if let url = obsidianURL {
                    HStack {
                        Spacer()
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label("在 Obsidian 開啟", systemImage: "arrow.up.forward.app")
                        }.controlSize(.small)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 480)
    }
}
