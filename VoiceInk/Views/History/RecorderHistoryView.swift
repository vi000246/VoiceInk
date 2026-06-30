import SwiftUI
import SwiftData
import AppKit

/// Recorder import log — rich, History-style list of imported recordings (deduped). Each row keeps
/// the audio file, the original raw transcript + analysis, date/time, category, and export status.
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
                title: "Recorder Log",
                infoMessage: "錄音筆匯入的紀錄（去重後每個檔案只出現一次）：保留音檔、原始逐字稿、分析、日期時間與類別。",
                infoURL: nil
            ) { EmptyView() }

            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { t in
                            RecorderLogCard(
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

private struct RecorderLogCard: View {
    let transcription: Transcription
    let fileName: String?
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var showAnalysis = false

    private var hasAnalysis: Bool { (transcription.enhancedText?.isEmpty == false) }
    private var displayText: String {
        (showAnalysis ? transcription.enhancedText : transcription.text) ?? transcription.text
    }
    private var audioURL: URL? {
        guard let s = transcription.audioFileURL, let u = URL(string: s),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        return u
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        if let c = transcription.recorderCategoryName { categoryBadge(c) }
                        if transcription.exportedFilePath != nil {
                            statusBadge("已輸出", "checkmark.circle.fill", AppTheme.Status.success)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggle)

            if isExpanded { expandedContent.padding(.top, 10) }
        }
        .padding(14)
        .background(AppTheme.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.Border.control, lineWidth: 0.5))
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if hasAnalysis {
                HStack(spacing: 4) {
                    tab("原始逐字稿", active: !showAnalysis) { showAnalysis = false }
                    tab("分析", active: showAnalysis) { showAnalysis = true }
                    Spacer()
                }
            }
            ScrollView {
                MarkdownContentView(displayText, fontSize: 14, foregroundColor: AppTheme.Text.primary)
            }
            .frame(maxHeight: 320)
            .overlay(alignment: .bottomTrailing) { CopyIconButton(textToCopy: displayText).padding(8) }

            if let url = audioURL {
                Divider()
                AudioPlayerView(url: url, transcription: transcription, onInfoTap: {})
                    .padding(.vertical, 4)
            }
            if let path = transcription.exportedFilePath {
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: {
                    Label("在 Obsidian Vault 顯示", systemImage: "folder")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(path)
            }
        }
    }

    private func tab(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundColor(active ? .primary : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(active ? AppTheme.Surface.controlActive : Color.clear))
        }
        .buttonStyle(.plain)
    }

    private func categoryBadge(_ name: String) -> some View {
        statusBadge(name, "tag.fill", AppTheme.Accent.primary)
    }
    private func statusBadge(_ text: String, _ system: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}
