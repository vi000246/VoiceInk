import SwiftUI
import SwiftData
import AppKit

/// Recording Management — the hub for imported recordings. Each card keeps the audio + raw transcript,
/// lets the user pick a 錄音筆範本 (category), apply it (preview), export to Obsidian, and delete the
/// audio or the whole record. Supports search + multi-select batch delete.
struct RecorderHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Transcription> { $0.importFingerprint != nil },
           sort: \Transcription.timestamp, order: .reverse)
    private var items: [Transcription]
    @State private var fileNameByFingerprint: [String: String] = [:]
    @State private var expandedId: UUID?
    @State private var searchText = ""
    @State private var categoryFilter: String?   // nil = 全部
    @State private var selectedIds: Set<UUID> = []
    @State private var confirmBatchDelete = false

    private static let dateSearchFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Distinct categories actually present in the imported recordings (for the filter dropdown).
    private var availableCategories: [String] {
        Array(Set(items.compactMap { $0.recorderCategoryName })).sorted()
    }

    private var filteredItems: [Transcription] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { t in
            if let categoryFilter, t.recorderCategoryName != categoryFilter { return false }
            guard !q.isEmpty else { return true }
            let name = t.importFingerprint.flatMap { fileNameByFingerprint[$0] } ?? ""
            let haystack = [
                name, t.text, t.enhancedText ?? "", t.recorderCategoryName ?? "",
                Self.dateSearchFormatter.string(from: t.timestamp)
            ].joined(separator: "\n").lowercased()
            return haystack.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Recording Management",
                infoMessage: "錄音筆匯入的原始檔（音檔＋逐字稿永遠保留）。挑一個錄音筆範本 → 套用 → 預覽 → 匯出到 Obsidian;可只刪音檔或刪整筆。",
                infoURL: nil
            ) { EmptyView() }

            searchBar
            Divider()

            if filteredItems.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredItems) { t in
                            RecordingCard(
                                transcription: t,
                                fileName: t.importFingerprint.flatMap { fileNameByFingerprint[$0] },
                                isExpanded: expandedId == t.id,
                                isChecked: selectedIds.contains(t.id),
                                onToggleCheck: { toggle(t.id) },
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedId = expandedId == t.id ? nil : t.id
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }

            if !selectedIds.isEmpty {
                Divider()
                selectionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadFileNames)
        .onChange(of: items.count) { _, _ in loadFileNames() }
        .confirmationDialog("刪除所選 \(selectedIds.count) 筆？音檔與逐字稿都會移除。", isPresented: $confirmBatchDelete) {
            Button("刪除所選", role: .destructive) { batchDelete() }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 12))
                TextField("搜尋逐字稿、檔名、日期(yyyy-MM-dd)…", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(AppTheme.Surface.card))
            .frame(maxWidth: .infinity)

            Picker("分類", selection: $categoryFilter) {
                Text("全部分類").tag(String?.none)
                ForEach(availableCategories, id: \.self) { c in Text(c).tag(String?.some(c)) }
            }
            .labelsHidden()
            .frame(width: 150)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Text("已選 \(selectedIds.count) 筆").font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
            Spacer()
            Button(allSelected ? "取消全選" : "全選") {
                if allSelected { selectedIds.removeAll() }
                else { selectedIds = Set(filteredItems.map { $0.id }) }
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            Button { confirmBatchDelete = true } label: {
                Label("刪除所選", systemImage: "trash").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain).foregroundColor(AppTheme.Status.error.opacity(0.85))
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(AppTheme.Surface.window.shadow(color: .black.opacity(0.1), radius: 3, y: -2))
    }

    private var allSelected: Bool {
        !filteredItems.isEmpty && filteredItems.allSatisfy { selectedIds.contains($0.id) }
    }

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private func batchDelete() {
        let targets = items.filter { selectedIds.contains($0.id) }
        for t in targets {
            if let s = t.audioFileURL, let u = URL(string: s) { try? FileManager.default.removeItem(at: u) }
            modelContext.delete(t)
        }
        try? modelContext.save()
        selectedIds.removeAll()
        NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
    }

    private func loadFileNames() {
        let entries = (try? modelContext.fetch(FetchDescriptor<ImportLedgerEntry>())) ?? []
        fileNameByFingerprint = Dictionary(entries.map { ($0.fingerprint, $0.fileName) },
                                           uniquingKeysWith: { a, _ in a })
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "tray.full" : "doc.text.magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.6))
            Text(searchText.isEmpty ? "尚無錄音匯入紀錄" : "查無符合").font(.system(size: 16, weight: .medium))
            Text(searchText.isEmpty ? "插入已設定的錄音筆後，匯入的檔案會列在這裡。" : "換個關鍵字試試。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingCard: View {
    let transcription: Transcription
    let fileName: String?
    let isExpanded: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onToggle: () -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
    @StateObject private var store = RecorderConfigStore.shared

    @State private var selectedCategoryId: UUID?
    @State private var showAnalysis = false
    @State private var busy = false
    @State private var confirmDeleteRecord = false
    @State private var confirmDeleteAudio = false
    @State private var showTranscriptSheet = false
    @State private var showRename = false
    @State private var renameText = ""

    private var hasAnalysis: Bool { (transcription.enhancedText?.isEmpty == false) }
    /// Prefer the generated recorder title (date + summary); fall back to the imported file name.
    private var displayTitle: String {
        if let t = transcription.recorderTitle, !t.isEmpty { return t }
        return fileName?.isEmpty == false ? fileName! : "錄音匯入"
    }
    private var displayText: String {
        (showAnalysis ? transcription.enhancedText : transcription.text) ?? transcription.text
    }
    private var audioURL: URL? {
        guard let s = transcription.audioFileURL, let u = URL(string: s),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }
    private var selectedCategory: RecorderCategory? {
        selectedCategoryId.flatMap { store.category(byId: $0) } ?? store.categories.first { $0.isFallback }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded { expandedContent.padding(.top, 10) }
        }
        .padding(14)
        .background(AppTheme.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            isChecked ? AppTheme.Accent.primary.opacity(0.5) : AppTheme.Border.control, lineWidth: isChecked ? 1 : 0.5))
        .onAppear { if selectedCategoryId == nil { selectedCategoryId = transcription.recorderCategoryId } }
        // Auto-select the classifier's category once classification finishes (or on reclassify).
        .onChange(of: transcription.recorderCategoryId) { _, newId in
            if let newId { selectedCategoryId = newId }
        }
        .confirmationDialog("刪除整筆紀錄？音檔與逐字稿都會移除。", isPresented: $confirmDeleteRecord) {
            Button("刪除整筆", role: .destructive) { deleteRecord() }
        }
        .confirmationDialog("刪除錄音檔？逐字稿會保留。", isPresented: $confirmDeleteAudio) {
            Button("刪除音檔", role: .destructive) { deleteAudio() }
        }
        .sheet(isPresented: $showTranscriptSheet) {
            TranscriptSheet(
                title: displayTitle,
                rawText: transcription.text,
                analysisText: transcription.enhancedText,
                showAnalysis: $showAnalysis)
        }
        .alert("重新命名", isPresented: $showRename) {
            TextField("名稱", text: $renameText)
            Button("儲存") {
                let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                transcription.recorderTitle = t.isEmpty ? nil : t
                try? modelContext.save()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("自訂這筆錄音在管理頁顯示的名稱。清空則還原為預設（日期＋摘要或原檔名）。")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16)).foregroundStyle(isChecked ? AppTheme.Accent.primary : .secondary)
            }
            .buttonStyle(.plain)
            Image(systemName: "waveform")
                .font(.system(size: 14)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(AppTheme.Sidebar.fallback, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(displayTitle)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(transcription.timestamp, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if let c = transcription.recorderCategoryName { badge(c, "tag.fill", AppTheme.Accent.primary) }
                    if transcription.exportedFilePath != nil { badge("已輸出", "checkmark.circle.fill", AppTheme.Status.success) }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                .foregroundColor(.secondary).rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("套用範本", selection: $selectedCategoryId) {
                    ForEach(store.categories) { c in Text(c.name).tag(UUID?.some(c.id)) }
                }
                .frame(maxWidth: 240)
                Button("套用") { apply() }.disabled(busy || selectedCategory == nil)
                if busy {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("處理中…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            HStack(spacing: 4) {
                tab("原始逐字稿", active: !showAnalysis) { showAnalysis = false }
                if hasAnalysis { tab("套用後", active: showAnalysis) { showAnalysis = true } }
                Spacer()
            }
            Button { showTranscriptSheet = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(displayText.isEmpty ? "（無內容）" : displayText)
                        .font(.system(size: 13))
                        .foregroundStyle(displayText.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppTheme.Text.primary))
                        .lineLimit(3).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                        Text("點擊看完整內容").font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.Surface.control, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.Border.control, lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let url = audioURL {
                Divider()
                AudioPlayerView(url: url, transcription: transcription, showsEnhancementControls: false)
                    .padding(.vertical, 4)
            }

            Divider()
            HStack(spacing: 12) {
                Button { renameText = displayTitle; showRename = true } label: {
                    Label("重新命名", systemImage: "pencil")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button { export() } label: { Label("匯出到 Obsidian", systemImage: "square.and.arrow.up") }
                    .disabled(busy || !hasAnalysis)
                if let path = transcription.exportedFilePath {
                    Button { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") } label: {
                        Label("在 Vault 顯示", systemImage: "folder")
                    }.buttonStyle(.plain).foregroundStyle(.secondary).help(path)
                }
                Spacer()
                Button(role: .destructive) { confirmDeleteAudio = true } label: { Label("刪除音檔", systemImage: "speaker.slash") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).disabled(audioURL == nil)
                Button(role: .destructive) { confirmDeleteRecord = true } label: { Label("刪除整筆", systemImage: "trash") }
                    .buttonStyle(.plain).foregroundStyle(AppTheme.Status.error.opacity(0.85))
            }
            .font(.system(size: 12))
        }
    }

    // MARK: - Actions

    private func apply() {
        guard let category = selectedCategory, let aiService = enhancementService.getAIService() else { return }
        busy = true
        Task {
            await RecorderPostProcessor.shared.applyTemplate(
                transcription: transcription, category: category, modelContext: modelContext,
                enhancementService: enhancementService, aiService: aiService)
            showAnalysis = true
            busy = false
        }
    }

    private func export() {
        guard let category = selectedCategory, let aiService = enhancementService.getAIService() else { return }
        busy = true
        Task {
            await RecorderPostProcessor.shared.export(
                transcription: transcription, category: category, modelContext: modelContext,
                enhancementService: enhancementService, aiService: aiService)
            busy = false
        }
    }

    private func deleteAudio() {
        if let url = audioURL { try? FileManager.default.removeItem(at: url) }
        transcription.audioFileURL = nil
        try? modelContext.save()
    }

    private func deleteRecord() {
        if let url = audioURL { try? FileManager.default.removeItem(at: url) }
        modelContext.delete(transcription)
        try? modelContext.save()
        NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
    }

    // MARK: - Bits

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundColor(active ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(active ? AppTheme.Surface.controlActive : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, _ system: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

/// Full-screen-ish popup showing a recording's complete transcript (raw or applied), for the
/// long multi-line transcripts that don't fit the card's inline preview.
private struct TranscriptSheet: View {
    let title: String
    let rawText: String
    let analysisText: String?
    @Binding var showAnalysis: Bool
    @Environment(\.dismiss) private var dismiss

    private var hasAnalysis: Bool { analysisText?.isEmpty == false }
    private var text: String { (showAnalysis ? analysisText : rawText) ?? rawText }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.headline).lineLimit(1)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HStack(spacing: 6) {
                tab("原始逐字稿", active: !showAnalysis) { showAnalysis = false }
                if hasAnalysis { tab("套用後", active: showAnalysis) { showAnalysis = true } }
                Spacer()
                CopyIconButton(textToCopy: text)
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            ScrollView {
                MarkdownContentView(text, fontSize: 14, foregroundColor: AppTheme.Text.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 660, height: 620)
    }

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: .medium))
                .foregroundColor(active ? .primary : .secondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Capsule().fill(active ? AppTheme.Surface.controlActive : Color.clear))
        }
        .buttonStyle(.plain)
    }
}
