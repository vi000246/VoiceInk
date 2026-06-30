import SwiftUI
import SwiftData
import AppKit

/// Recorder import log — one row per imported recording (deduped, so each source file appears once),
/// showing date/time, file name, size, classified category, and whether it was exported to the vault.
struct RecorderHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ImportLedgerEntry.importedAt, order: .reverse) private var entries: [ImportLedgerEntry]
    @State private var txById: [UUID: Transcription] = [:]

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Recorder Log",
                infoMessage: "錄音匯入紀錄：每個已建立紀錄的錄音檔（去重後只會出現一次）。",
                infoURL: nil
            ) { EmptyView() }

            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: loadTranscriptions)
        .onChange(of: entries.count) { _, _ in loadTranscriptions() }
    }

    private func loadTranscriptions() {
        var d = FetchDescriptor<Transcription>(predicate: #Predicate { $0.importFingerprint != nil })
        d.propertiesToFetch = []
        let txs = (try? modelContext.fetch(d)) ?? []
        txById = Dictionary(txs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func row(_ entry: ImportLedgerEntry) -> some View {
        let tx = entry.transcriptionId.flatMap { txById[$0] }
        return HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.system(size: 15)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(AppTheme.Sidebar.fallback, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.fileName.isEmpty ? "(未知檔名)" : entry.fileName)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(entry.importedAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    if entry.byteSize > 0 {
                        Text(byteString(entry.byteSize)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if let category = tx?.recorderCategoryName {
                pill(category, system: "tag.fill", tint: AppTheme.Accent.primary)
            }
            if let path = tx?.exportedFilePath {
                Button {
                    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                } label: { pill("已輸出", system: "checkmark.circle.fill", tint: AppTheme.Status.success) }
                .buttonStyle(.plain).help(path)
            } else {
                pill("僅轉錄", system: "doc.text", tint: .secondary)
            }
        }
        .padding(12)
        .background(AppTheme.Surface.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(AppTheme.Border.control, lineWidth: 0.5))
    }

    private func pill(_ text: String, system: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: system).font(.system(size: 9))
            Text(text).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
