import SwiftUI
import SwiftData
import AppKit

/// Recording Management — the hub for imported recordings. Each card keeps the audio + raw transcript,
/// lets the user pick a 錄音筆範本 (category), apply it (preview), export to Obsidian, and delete the
/// audio or the whole record. Nothing is bound to Obsidian until the user exports.
struct RecorderHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Transcription> { $0.importFingerprint != nil },
           sort: \Transcription.timestamp, order: .reverse)
    private var items: [Transcription]
    @State private var fileNameByFingerprint: [String: String] = [:]
    @State private var expandedId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Recording Management",
                infoMessage: "錄音筆匯入的原始檔（音檔＋逐字稿永遠保留）。挑一個錄音筆範本 → 套用 → 預覽 → 匯出到 Obsidian;可只刪音檔或刪整筆。",
                infoURL: nil
            ) { EmptyView() }

            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { t in
                            RecordingCard(
                                transcription: t,
                                fileName: t.importFingerprint.flatMap { fileNameByFingerprint[$0] },
                                isExpanded: expandedId == t.id,
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadFileNames)
        .onChange(of: items.count) { _, _ in loadFileNames() }
    }

    private func loadFileNames() {
        let entries = (try? modelContext.fetch(FetchDescriptor<ImportLedgerEntry>())) ?? []
        fileNameByFingerprint = Dictionary(entries.map { ($0.fingerprint, $0.fileName) },
                                           uniquingKeysWith: { a, _ in a })
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.full")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.6))
            Text("尚無錄音匯入紀錄").font(.system(size: 16, weight: .medium))
            Text("插入已設定的錄音筆後，匯入的檔案會列在這裡。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingCard: View {
    let transcription: Transcription
    let fileName: String?
    let isExpanded: Bool
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

    private var hasAnalysis: Bool { (transcription.enhancedText?.isEmpty == false) }
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
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.Border.control, lineWidth: 0.5))
        .onAppear { if selectedCategoryId == nil { selectedCategoryId = transcription.recorderCategoryId } }
        .confirmationDialog("刪除整筆紀錄？音檔與逐字稿都會移除。", isPresented: $confirmDeleteRecord) {
            Button("刪除整筆", role: .destructive) { deleteRecord() }
        }
        .confirmationDialog("刪除錄音檔？逐字稿會保留。", isPresented: $confirmDeleteAudio) {
            Button("刪除音檔", role: .destructive) { deleteAudio() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 14)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(AppTheme.Sidebar.fallback, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 3) {
                Text(fileName?.isEmpty == false ? fileName! : "錄音匯入")
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
            // Template (category) picker + Apply
            HStack(spacing: 8) {
                Picker("套用範本", selection: $selectedCategoryId) {
                    ForEach(store.categories) { c in Text(c.name).tag(UUID?.some(c.id)) }
                }
                .frame(maxWidth: 240)
                Button("套用") { apply() }.disabled(busy || selectedCategory == nil)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }

            // raw / applied tabs
            HStack(spacing: 4) {
                tab("原始逐字稿", active: !showAnalysis) { showAnalysis = false }
                if hasAnalysis { tab("套用後", active: showAnalysis) { showAnalysis = true } }
                Spacer()
            }
            ScrollView {
                MarkdownContentView(displayText, fontSize: 14, foregroundColor: AppTheme.Text.primary)
            }
            .frame(maxHeight: 300)
            .overlay(alignment: .bottomTrailing) { CopyIconButton(textToCopy: displayText).padding(8) }

            if let url = audioURL {
                Divider()
                AudioPlayerView(url: url, transcription: transcription, onInfoTap: {}).padding(.vertical, 4)
            }

            Divider()
            HStack(spacing: 12) {
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
