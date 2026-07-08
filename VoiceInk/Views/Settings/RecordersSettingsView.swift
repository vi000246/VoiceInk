import SwiftUI
import AppKit

/// Recorders page — device cards + a 400pt slide-out editor (mirrors ModeView), plus the single
/// global Obsidian vault root. Plug in a configured device → zero-click import/transcribe/classify/export.
struct RecordersSettingsView: View {
    @StateObject private var store = RecorderConfigStore.shared
    @State private var editTarget: DeviceEditTarget?

    enum DeviceEditTarget: Identifiable {
        case add
        case edit(RecorderDevice)
        var id: String { switch self { case .add: return "add"; case .edit(let d): return d.id.uuidString } }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "錄音裝置",
                infoMessage: "插入已設定的錄音筆、或監看一般資料夾，偵測到新錄音即自動匯入、轉錄、分類，並輸出到 Obsidian Vault。",
                infoURL: nil
            ) {
                AppIconButton(systemName: "plus.circle.fill", help: "新增錄音來源") { editTarget = .add }
            }

            ScrollView {
                VStack(spacing: 12) {
                    VaultRootCard(store: store)

                    if store.devices.isEmpty {
                        emptyState
                    } else {
                        ForEach(store.devices) { device in
                            RecorderDeviceCard(device: device) { editTarget = .edit(device) }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sidePanel(isPresented: .init(
            get: { editTarget != nil },
            set: { if !$0 { editTarget = nil } }
        ), dismissOnExitCommand: false) {
            if let target = editTarget {
                RecorderDeviceEditorPanel(target: target, store: store, onDismiss: { editTarget = nil })
                    .id(target.id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "recordingtape")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.6))
            Text("尚未設定錄音來源").font(.system(size: 16, weight: .medium))
            Text("點右上「+」新增：錄音筆裝置（插入時比對磁碟名稱），或一般資料夾（持續監看新錄音檔）。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

// MARK: - Global Vault Root Card

private struct VaultRootCard: View {
    @ObservedObject var store: RecorderConfigStore

    private var vaultName: String? {
        guard let bookmark = store.vaultRootBookmark,
              let url = VaultExportService.shared.resolveVaultRoot(bookmark) else { return nil }
        return url.lastPathComponent
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 18)).foregroundStyle(AppTheme.Accent.primary)
                .frame(width: 36, height: 36)
                .background(AppTheme.Accent.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Obsidian Vault").font(.system(size: 14, weight: .semibold))
                Text(vaultName.map { "根目錄：\($0)" } ?? "未設定 — 不會輸出 Markdown")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if store.vaultRootBookmark != nil {
                Button("清除") { store.setVaultRoot(nil) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
            }
            Button(store.vaultRootBookmark == nil ? "選擇 Vault…" : "更換…") { chooseVault() }
                .controlSize(.small)
        }
        .padding(14)
        .background(AppTheme.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.Border.control, lineWidth: 0.5))
    }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "選擇 Obsidian Vault 的根目錄"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        guard let bookmark = try? root.bookmarkData(options: [.withSecurityScope],
                                                    includingResourceValuesForKeys: nil, relativeTo: nil) else {
            NotificationManager.shared.showNotification(title: "無法建立 Vault 授權", type: .error, duration: 4); return
        }
        store.setVaultRoot(bookmark)
    }
}

// MARK: - Device Card

private struct RecorderDeviceCard: View {
    let device: RecorderDevice
    let onEdit: () -> Void
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var transcriptionManager = AudioTranscriptionManager.shared
    @ObservedObject private var importService = RecorderImportService.shared
    @State private var isHovering = false
    @State private var expanded = false
    @State private var files: [RecorderImportService.DeviceFileStatus]?
    @State private var connected = false
    @State private var scanning = false
    @State private var selectedFiles: Set<String> = []
    @State private var confirmReprocess = false
    @State private var filePage = 0
    private static let filePageSize = 50
    @State private var capacity: RecorderImportService.DeviceCapacity?
    @State private var showCleanup = false
    @State private var durations: [String: Double] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: device.kind == .folder ? "folder.fill" : "recordingtape")
                    .font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Sidebar.fallback, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.displayName.isEmpty ? "未命名來源" : device.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        connectionDot
                    }
                    Text(sourceSubtitle)
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        pill(device.autoImportEnabled ? (device.kind == .folder ? "監看中" : "自動匯入") : "已停用",
                             on: device.autoImportEnabled)
                        if device.deleteAfterImport { pill("匯入後刪除", on: false) }
                    }
                }
                Spacer()
                Button("編輯", action: onEdit).controlSize(.small)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)

            capacitySection

            Button {
                expanded.toggle()
                if expanded { scan() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(expanded ? "裝置檔案" : "顯示裝置檔案").font(.system(size: 12, weight: .medium))
                    if scanning { ProgressView().controlSize(.mini).padding(.leading, 2) }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 10)

            progressSection

            if expanded { fileList.padding(.top, 8) }
        }
        .padding(14)
        .background(AppTheme.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isHovering ? AppTheme.Accent.primary.opacity(0.4) : AppTheme.Border.control, lineWidth: 0.5))
        .onHover { isHovering = $0 }
        .onAppear { refreshConnectivity() }
        .onReceive(NotificationCenter.default.publisher(for: .recorderDeviceConnectivityChanged)) { _ in
            refreshConnectivity()
        }
        .sheet(isPresented: $showCleanup) {
            RecorderDeviceCleanupSheet(device: device) { refreshConnectivity(); if expanded { scan() } }
        }
    }

    private func refreshConnectivity() {
        connected = RecorderImportService.shared.isDeviceConnected(device)
        capacity = connected ? RecorderImportService.shared.deviceCapacity(for: device) : nil
    }

    /// Volume usage bar for the backing disk — a red/orange/accent fill by fullness — plus a cleanup
    /// entry point so the user can free space without leaving the app.
    @ViewBuilder private var capacitySection: some View {
        if connected, let cap = capacity, cap.totalBytes > 0 {
            let frac = cap.usedFraction
            let tint: Color = frac >= 0.9 ? AppTheme.Status.error
                : (frac >= 0.75 ? Color.orange : AppTheme.Accent.primary)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("裝置容量").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(Self.sizeText(Int(cap.usedBytes))) / \(Self.sizeText(Int(cap.totalBytes)))（\(Int((frac * 100).rounded()))%）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("清理選項…") { showCleanup = true }.controlSize(.small)
                }
                ProgressView(value: min(max(frac, 0), 1)).progressViewStyle(.linear).tint(tint)
            }
            .padding(.top, 10)
        }
    }

    // MARK: - Batch progress

    /// This device's items currently in the transcription queue (auto-import + manual reprocess).
    private var deviceQueueItems: [AudioFileQueueItem] {
        transcriptionManager.queue.filter {
            if case let .recorderImport(id, _) = $0.origin { return id == device.id }
            return false
        }
    }

    private var isBatchProcessing: Bool { deviceQueueItems.contains { !$0.status.isTerminal } }

    @ViewBuilder private var progressSection: some View {
        // Copy-into-storage phase: no queue item exists yet, so show a lightweight "準備中" row so a
        // reprocess of a large recording doesn't look frozen for the tens of seconds before transcription.
        if importService.preparingDeviceIds.contains(device.id) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("準備中…（複製檔案）").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .padding(.top, 10)
        }
        let items = deviceQueueItems
        if isBatchProcessing, !items.isEmpty {
            let done = items.filter { if case .completed = $0.status { return true }; return false }.count
            let failed = items.filter { if case .failed = $0.status { return true }; return false }.count
            let active = items.first { if case .processing = $0.status { return true }; return false }
            // The linear bar is only meaningful when there's real sub-progress: a chunked (split)
            // recording. A single-file upload can't report true progress, so we show elapsed seconds
            // instead of a bar that just sits at 0.
            let activeIsChunked = (active?.chunkProgress?.total ?? 0) > 1
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("處理中 \(done)/\(items.count)").font(.system(size: 11, weight: .medium))
                    if failed > 0 {
                        Text("・失敗 \(failed)").font(.system(size: 11)).foregroundStyle(AppTheme.Status.error)
                    }
                    Spacer()
                    if let active, let label = activeLabel(active) {
                        Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if activeIsChunked {
                    // Fold the active file's chunk fraction into the bar so a single long recording
                    // still advances smoothly instead of jumping only when a whole file finishes.
                    let value = min(Double(done) + (active?.chunkProgress?.fraction ?? 0), Double(items.count))
                    ProgressView(value: value, total: Double(items.count))
                        .progressViewStyle(.linear).tint(AppTheme.Accent.primary)
                } else if let start = active?.transcribingStartedAt {
                    // Single-file upload: tick elapsed seconds (no fake progress bar).
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Text("上傳／辨識中… 已用 \(Int(max(0, context.date.timeIntervalSince(start)))) 秒")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    /// Live sub-status for the file currently transcribing — phase + chunk progress when chunked.
    private func activeLabel(_ item: AudioFileQueueItem) -> String? {
        var parts: [String] = []
        if case let .processing(phase) = item.status {
            switch phase {
            case .loading: parts.append("載入模型")
            case .processingAudio: parts.append("處理音訊")
            case .transcribing: parts.append("轉錄中")
            case .enhancing: parts.append("增強中")
            }
        }
        if let cp = item.chunkProgress, cp.total > 1 { parts.append("片段 \(cp.done)/\(cp.total)") }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    /// Subtitle: the volume-name match (removable device) or the watched folder path (plain folder).
    private var sourceSubtitle: String {
        switch device.kind {
        case .volume: return "符合磁碟名稱：\(device.volumeNameMatch)"
        case .folder: return "監看資料夾：\(device.resolveSourceFolder()?.path ?? "無法解析")"
        }
    }

    @ViewBuilder private var connectionDot: some View {
        HStack(spacing: 3) {
            Circle().fill(connected ? AppTheme.Status.success : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(connected ? (device.kind == .folder ? "可存取" : "已連接")
                           : (device.kind == .folder ? "無法存取" : "未連接"))
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var fileList: some View {
        if !connected {
            Text("裝置未連接，插入後可在此查看檔案。").font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let files {
            if files.isEmpty {
                Text("來源資料夾沒有支援的音訊檔。").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    let done = files.filter { $0.processed }.count
                    let pageCount = max(1, (files.count + Self.filePageSize - 1) / Self.filePageSize)
                    let page = min(filePage, pageCount - 1)
                    let pagedFiles = Array(files.dropFirst(page * Self.filePageSize).prefix(Self.filePageSize))
                    HStack {
                        Text("共 \(files.count) 檔・已處理 \(done)・未處理 \(files.count - done)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        // 重新處理所選：放在全選左邊、比全選大;未選任何檔時停用。
                        Button { confirmReprocess = true } label: {
                            Label("重新處理所選\(selectedFiles.isEmpty ? "" : "（\(selectedFiles.count)）")",
                                  systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .controlSize(.regular)
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedFiles.isEmpty)
                        Button(selectedFiles.count == files.count ? "取消全選" : "全選") {
                            selectedFiles = selectedFiles.count == files.count ? [] : Set(files.map { $0.fileName })
                        }.controlSize(.mini)
                        Button("重新整理") { scan() }.controlSize(.mini)
                    }
                    // Column header — widths mirror the rows below so 長度/大小/時間/狀態 line up.
                    HStack(spacing: 8) {
                        Color.clear.frame(width: Self.checkColWidth)
                        Color.clear.frame(width: Self.statusIconColWidth)
                        Text("檔名").frame(maxWidth: .infinity, alignment: .leading)
                        Text("長度").frame(width: Self.durationColWidth, alignment: .trailing)
                        Text("大小").frame(width: Self.sizeColWidth, alignment: .trailing)
                        Text("時間").frame(width: Self.dateColWidth, alignment: .trailing)
                        Text("狀態").frame(width: Self.statusColWidth, alignment: .trailing)
                    }
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.top, 2)
                    ForEach(pagedFiles) { f in
                        let isSel = selectedFiles.contains(f.fileName)
                        Button { toggleSelect(f.fileName) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSel ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSel ? AppTheme.Accent.primary : Color.secondary)
                                    .frame(width: Self.checkColWidth)
                                Image(systemName: f.processed ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(f.processed ? AppTheme.Status.success : Color.secondary)
                                    .frame(width: Self.statusIconColWidth)
                                Text(f.fileName).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(durationLabel(f.fileName))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: Self.durationColWidth, alignment: .trailing)
                                Text(Self.sizeText(f.byteSize))
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: Self.sizeColWidth, alignment: .trailing)
                                Text(f.modified.map { Self.rowDateFormatter.string(from: $0) } ?? "—")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                    .frame(width: Self.dateColWidth, alignment: .trailing)
                                Text(f.processed ? "已處理" : "未處理")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(f.processed ? AppTheme.Status.success : .secondary)
                                    .frame(width: Self.statusColWidth, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3).padding(.horizontal, 8)
                            .background((isSel ? AppTheme.Accent.primary.opacity(0.12) : AppTheme.Surface.control.opacity(0.5)),
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    // 分頁控制（每 50 筆一頁）——超過一頁才顯示。
                    if pageCount > 1 {
                        HStack(spacing: 12) {
                            Button { if page > 0 { filePage = page - 1 } } label: {
                                Image(systemName: "chevron.left")
                            }.controlSize(.small).disabled(page == 0)
                            Text("第 \(page + 1) / \(pageCount) 頁").font(.system(size: 11)).foregroundStyle(.secondary)
                            Button { if page < pageCount - 1 { filePage = page + 1 } } label: {
                                Image(systemName: "chevron.right")
                            }.controlSize(.small).disabled(page >= pageCount - 1)
                            if !selectedFiles.isEmpty {
                                Spacer()
                                Text("已選 \(selectedFiles.count) 檔（跨頁）").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .confirmationDialog(reprocessPrompt, isPresented: $confirmReprocess, titleVisibility: .visible) {
                    Button("重新處理") { reprocessSelected() }
                    Button("取消", role: .cancel) {}
                }
            }
        }
    }

    private func scan() {
        scanning = true
        connected = RecorderImportService.shared.isDeviceConnected(device)
        capacity = connected ? RecorderImportService.shared.deviceCapacity(for: device) : nil
        files = RecorderImportService.shared.deviceFiles(for: device, context: modelContext)
        selectedFiles = selectedFiles.intersection(Set(files?.map { $0.fileName } ?? []))
        scanning = false
        // Durations need an async AVAsset load each — fetch them off the instant list scan so the
        // 長度 column fills in progressively rather than blocking the file list from appearing.
        if connected {
            Task { durations = await RecorderImportService.shared.deviceFileDurations(for: device) }
        } else {
            durations = [:]
        }
    }

    /// Compact play-length label (m:ss) for the file list, or "—" until the async probe lands.
    private func durationLabel(_ fileName: String) -> String {
        guard let seconds = durations[fileName] else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func toggleSelect(_ name: String) {
        if selectedFiles.contains(name) { selectedFiles.remove(name) } else { selectedFiles.insert(name) }
    }

    /// Confirmation copy — warns that already-processed picks are duplicated with a serial suffix.
    private var reprocessPrompt: String {
        let processedCount = (files ?? []).filter { selectedFiles.contains($0.fileName) && $0.processed }.count
        if processedCount > 0 {
            return "重新處理所選 \(selectedFiles.count) 檔？其中 \(processedCount) 個已處理，會另存為加流水號的副本（不覆蓋原紀錄、不刪除裝置檔）。"
        }
        return "重新處理所選 \(selectedFiles.count) 檔？"
    }

    private func reprocessSelected() {
        RecorderImportService.shared.reprocess(fileNames: selectedFiles, device: device)
        selectedFiles = []
    }

    private func pill(_ text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(on ? AppTheme.Accent.primary : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill((on ? AppTheme.Accent.primary : Color.secondary).opacity(0.12)))
    }

    /// Human-readable file size (KB / MB) for a device file row.
    static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    // Fixed column widths so the file list's 長度/大小/時間/狀態 columns line up across rows and header.
    static let checkColWidth: CGFloat = 16
    static let statusIconColWidth: CGFloat = 14
    static let durationColWidth: CGFloat = 46
    static let sizeColWidth: CGFloat = 66
    static let dateColWidth: CGFloat = 94
    static let statusColWidth: CGFloat = 44

    /// Fixed-width numeric date (MM/dd HH:mm) so the 時間 column aligns regardless of locale.
    static let rowDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MM/dd HH:mm"; return f
    }()
}

// MARK: - Device Editor (slide-out panel)

private struct RecorderDeviceEditorPanel: View {
    let target: RecordersSettingsView.DeviceEditTarget
    @ObservedObject var store: RecorderConfigStore
    let onDismiss: () -> Void

    @State private var displayName: String
    @State private var kind: RecorderDevice.Kind
    @State private var volumeNameMatch: String
    @State private var sourceFolderBookmark: Data?
    @State private var sourceFolderName: String?
    @State private var autoImportEnabled: Bool
    @State private var deleteAfterImport: Bool
    @State private var recursive: Bool
    @State private var isICloudSource: Bool
    @State private var presetKind: String?
    @State private var defaultCategoryId: UUID?

    private let existingId: UUID?
    private let createdAt: Date

    init(target: RecordersSettingsView.DeviceEditTarget, store: RecorderConfigStore, onDismiss: @escaping () -> Void) {
        self.target = target
        self.store = store
        self.onDismiss = onDismiss
        switch target {
        case .add:
            existingId = nil; createdAt = Date()
            _displayName = State(initialValue: "")
            _kind = State(initialValue: .volume)
            _volumeNameMatch = State(initialValue: "")
            _sourceFolderBookmark = State(initialValue: nil)
            _sourceFolderName = State(initialValue: nil)
            _autoImportEnabled = State(initialValue: true)
            _deleteAfterImport = State(initialValue: false)
            _recursive = State(initialValue: false)
            _isICloudSource = State(initialValue: false)
            _presetKind = State(initialValue: nil)
            _defaultCategoryId = State(initialValue: nil)
        case .edit(let d):
            existingId = d.id; createdAt = d.createdAt
            _displayName = State(initialValue: d.displayName)
            _kind = State(initialValue: d.kind)
            _volumeNameMatch = State(initialValue: d.volumeNameMatch)
            _sourceFolderBookmark = State(initialValue: d.sourceFolderBookmark)
            _sourceFolderName = State(initialValue: d.resolveSourceFolder()?.lastPathComponent)
            _autoImportEnabled = State(initialValue: d.autoImportEnabled)
            _deleteAfterImport = State(initialValue: d.deleteAfterImport)
            _recursive = State(initialValue: d.recursive)
            _isICloudSource = State(initialValue: d.isICloudSource)
            _presetKind = State(initialValue: d.presetKind)
            _defaultCategoryId = State(initialValue: d.defaultCategoryId)
        }
    }

    /// 與 RecorderDevice.protectsOriginals 同義(編輯中的暫態版本)。
    private var protectsOriginals: Bool { isICloudSource || presetKind != nil }

    private var canSave: Bool {
        guard sourceFolderBookmark != nil else { return false }
        if kind == .volume { return !volumeNameMatch.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }

    private var isFolder: Bool { kind == .folder }

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: target.id == "add" ? "新增錄音來源" : "編輯錄音來源", onClose: onDismiss)
            Form {
                Section("類型") {
                    Picker("來源類型", selection: $kind) {
                        Text("錄音筆裝置（插入時比對磁碟名稱）").tag(RecorderDevice.Kind.volume)
                        Text("一般資料夾（持續監看新檔案）").tag(RecorderDevice.Kind.folder)
                    }
                    .pickerStyle(.radioGroup)
                    if existingId == nil {
                        HStack(spacing: 8) {
                            Text("快速設定：").foregroundStyle(.secondary)
                            Button("Just Press Record") { applyJustPressRecordPreset() }
                            Button("Apple 語音備忘錄") { applyVoiceMemosPreset() }
                        }
                        Text("一鍵設定手錶/iPhone 錄音來源：JPR 用 iCloud Drive 容器（遞迴日期資料夾）；語音備忘錄用本機同步資料夾（可能需要「完整磁碟取用權」）。兩者都絕不刪除你的原始錄音。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("辨識") {
                    TextField("顯示名稱", text: $displayName)
                    if !isFolder {
                        TextField("符合磁碟名稱（插入時比對，包含即符合）", text: $volumeNameMatch)
                    }
                }
                Section(isFolder ? "監看資料夾（偵測到新錄音檔即自動匯入）" : "來源資料夾（裝置上存放錄音的位置）") {
                    HStack {
                        Text(sourceFolderName ?? "尚未選擇")
                            .foregroundStyle(sourceFolderName == nil ? .secondary : .primary)
                        Spacer()
                        Button("選擇…") { chooseSourceFolder() }
                    }
                }
                Section("自動化") {
                    Toggle(isFolder ? "偵測到新檔案即自動匯入" : "插入即自動匯入", isOn: $autoImportEnabled)
                    if protectsOriginals {
                        Label("此來源的原始錄音受保護，永不刪除", systemImage: "lock.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("匯入後刪除來源原始檔（成功匯入＋轉錄＋輸出後才刪）", isOn: $deleteAfterImport)
                    }
                    Picker("預設分類", selection: $defaultCategoryId) {
                        Text("自動分類").tag(UUID?.none)
                        ForEach(store.categories) { c in
                            Text(c.name).tag(UUID?.some(c.id))
                        }
                    }
                    Text("指定分類可跳過 AI 分類（結果穩定、省一次呼叫）；「自動分類」維持既有行為。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("儲存", action: save).disabled(!canSave)
                    if existingId != nil {
                        Button("刪除此裝置", role: .destructive, action: deleteDevice)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func chooseSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = isFolder ? "選擇要監看的資料夾" : "選擇錄音筆上存放錄音的資料夾"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard let bookmark = try? folder.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) else {
            NotificationManager.shared.showNotification(title: "無法建立資料夾授權", type: .error, duration: 4); return
        }
        sourceFolderBookmark = bookmark
        sourceFolderName = folder.lastPathComponent
        // Auto-fill names from the folder. For a removable device, match on its volume name;
        // for a plain folder, there's no volume to match, so just seed the display name.
        let volumeName = (try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? folder.lastPathComponent
        if !isFolder, volumeNameMatch.isEmpty { volumeNameMatch = volumeName }
        if displayName.isEmpty { displayName = isFolder ? folder.lastPathComponent : volumeName }
    }

    private func save() {
        guard let bookmark = sourceFolderBookmark else { return }
        let fallbackName = isFolder ? (sourceFolderName ?? "資料夾") : volumeNameMatch
        let device = RecorderDevice(
            id: existingId ?? UUID(),
            displayName: displayName.isEmpty ? fallbackName : displayName,
            kind: kind,
            volumeNameMatch: isFolder ? "" : volumeNameMatch,
            sourceFolderBookmark: bookmark,
            autoImportEnabled: autoImportEnabled,
            deleteAfterImport: protectsOriginals ? false : deleteAfterImport,   // 受保護來源強制關
            createdAt: createdAt,
            recursive: recursive,
            isICloudSource: isICloudSource,
            presetKind: presetKind,
            defaultCategoryId: defaultCategoryId)
        store.upsert(device)
        onDismiss()
    }

    // MARK: - Presets（手錶/iPhone 錄音來源一鍵設定）
    //
    // 兩個預設都走「NSOpenPanel 使用者選取」而非自動讀取受保護路徑:
    // 使用者在面板中確認選取的資料夾,會產生 security-scoped bookmark 直接授權本 app 存取那個
    // 資料夾——**不需要完整磁碟取用權**(面板本身在特權行程執行,能看見受 TCC 保護的位置)。
    // 這也解決了「已開 FDA 仍無權限」的問題:自簽本地建置的 FDA 授權常常綁不上,但使用者親手
    // 選取的 bookmark 一定有效。面板預先導覽到目標位置,使用者通常只要按「打開」。

    /// Just Press Record:iCloud Drive 容器(日期子資料夾巢狀 → 遞迴＋iCloud 語意)。
    /// 自動定位容器並把面板開在那裡;沒安裝 JPR(找不到容器)則開在 iCloud Drive 根目錄,
    /// 讓使用者手動選——不是錯誤,只是需要 JPR 已安裝並使用 iCloud Drive 儲存才有內容。
    private func applyJustPressRecordPreset() {
        let mobileDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents")
        let container = (try? FileManager.default.contentsOfDirectory(
                at: mobileDocs, includingPropertiesForKeys: nil))?
            .first { $0.lastPathComponent.lowercased().contains("openplanetsoftware") }

        let startAt: URL
        let hint: String
        if let container {
            let documents = container.appendingPathComponent("Documents")
            startAt = FileManager.default.fileExists(atPath: documents.path) ? documents : container
            hint = "已定位到 Just Press Record 資料夾，按「打開」確認即可。"
        } else {
            startAt = mobileDocs
            hint = "找不到 Just Press Record 的 iCloud 資料夾。若已安裝並用 iCloud Drive 儲存，請在此手動選取它的資料夾；否則按取消。"
        }
        pickPresetFolder(startAt: startAt, message: hint, displayName: "Just Press Record",
                         presetKind: "justPressRecord", recursive: true, isICloud: true)
    }

    /// Apple 語音備忘錄:本機群組容器(平面 .m4a,CloudKit 同步)。面板預先導覽到 Recordings 資料夾。
    /// 使用者選取後的 bookmark 直接授權,免完整磁碟取用權。
    private func applyVoiceMemosPreset() {
        let recordings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings")
        // Recordings 可能尚未建立(VM 從未同步)→ 退回群組容器根,再退回 ~/Library。
        let groupRoot = recordings.deletingLastPathComponent()
        let startAt = FileManager.default.fileExists(atPath: recordings.path) ? recordings
            : (FileManager.default.fileExists(atPath: groupRoot.path) ? groupRoot
               : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"))
        pickPresetFolder(
            startAt: startAt,
            message: "請選取語音備忘錄的「Recordings」資料夾（在 Group Containers/group.com.apple.VoiceMemos.shared 內）。選取後即可存取，不需完整磁碟取用權。",
            displayName: "語音備忘錄", presetKind: "voiceMemos", recursive: false, isICloud: false)
    }

    /// 開啟資料夾選取面板(預先導覽到 startAt),把使用者選取的資料夾套成預設來源。
    private func pickPresetFolder(startAt: URL, message: String, displayName name: String,
                                  presetKind preset: String, recursive rec: Bool, isICloud: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true          // 目標在隱藏的 ~/Library 內
        panel.directoryURL = startAt
        panel.message = message
        panel.prompt = "選擇此資料夾"
        guard panel.runModal() == .OK, let folder = panel.url else { return }   // 取消 → 靜默,不報錯
        guard let bookmark = try? folder.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) else {
            NotificationManager.shared.showNotification(title: "無法建立資料夾授權", type: .error, duration: 4)
            return
        }
        kind = .folder
        sourceFolderBookmark = bookmark
        sourceFolderName = folder.lastPathComponent
        displayName = name
        volumeNameMatch = ""
        recursive = rec
        isICloudSource = isICloud
        presetKind = preset
        deleteAfterImport = false
        NotificationManager.shared.showNotification(title: "已套用 \(name) 預設，確認後按「儲存」", type: .info, duration: 4)
    }

    private func deleteDevice() {
        if let id = existingId { store.remove(id) }
        onDismiss()
    }
}

// MARK: - Device Cleanup Sheet

/// Free space on a recorder device by deleting source files matching either criterion (OR): older
/// than N days, or shorter than a chosen length. Deletes the on-device originals only — imported
/// records (audio copy + transcript in the app) are untouched.
private struct RecorderDeviceCleanupSheet: View {
    let device: RecorderDevice
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var olderEnabled = true
    @State private var olderDays = 30
    @State private var shorterEnabled = false
    @State private var shorterValue = 10
    @State private var shorterUnit: DurationUnit = .seconds

    @State private var scannedFiles: [RecorderImportService.CleanupFile]?
    @State private var scanning = false
    @State private var confirmDelete = false

    private var shorterSeconds: Int { max(0, shorterValue) * shorterUnit.secondsPerUnit }

    private func matches(_ f: RecorderImportService.CleanupFile) -> Bool {
        var hit = false
        if olderEnabled, olderDays > 0, let mod = f.modified {
            if mod < Date().addingTimeInterval(-Double(olderDays) * 86_400) { hit = true }
        }
        if shorterEnabled, shorterSeconds > 0, let d = f.durationSeconds {
            if d < Double(shorterSeconds) { hit = true }
        }
        return hit
    }

    private var matchedFiles: [RecorderImportService.CleanupFile] {
        (scannedFiles ?? []).filter(matches)
    }
    private var matchedBytes: Int64 { matchedFiles.reduce(0) { $0 + Int64($1.byteSize) } }
    private var noCriteria: Bool { !(olderEnabled && olderDays > 0) && !(shorterEnabled && shorterSeconds > 0) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("清理裝置檔案").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            Form {
                Section("清理條件（符合任一項即刪除）") {
                    Toggle(isOn: $olderEnabled) {
                        HStack {
                            Text("刪除早於")
                            TextField("", value: $olderDays, format: .number)
                                .frame(width: 56).multilineTextAlignment(.trailing)
                                .disabled(!olderEnabled)
                            Text("天前的檔案")
                        }
                    }
                    Toggle(isOn: $shorterEnabled) {
                        HStack {
                            Text("刪除短於")
                            TextField("", value: $shorterValue, format: .number)
                                .frame(width: 56).multilineTextAlignment(.trailing)
                                .disabled(!shorterEnabled)
                            Picker("", selection: $shorterUnit) {
                                ForEach(DurationUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden().frame(width: 76).disabled(!shorterEnabled)
                            Text("的檔案")
                        }
                    }
                }

                Section {
                    if scanning {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("掃描中…").foregroundStyle(.secondary) }
                    } else if noCriteria {
                        Text("請至少啟用一個條件。").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else if let scannedFiles {
                        Text("符合 \(matchedFiles.count) / \(scannedFiles.count) 檔，可釋出約 \(RecorderDeviceCard.sizeText(Int(matchedBytes)))")
                            .font(.system(size: 12, weight: .medium))
                        ForEach(matchedFiles.prefix(50)) { f in
                            HStack(spacing: 8) {
                                Text(f.fileName).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                if let d = f.durationSeconds {
                                    Text(Self.durationText(d)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                if let m = f.modified {
                                    Text(m, format: .dateTime.year().month(.abbreviated).day())
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(RecorderDeviceCard.sizeText(f.byteSize)).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        if matchedFiles.count > 50 {
                            Text("…另有 \(matchedFiles.count - 50) 檔").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("按「掃描」列出符合的檔案。").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button { rescan() } label: { Label("掃描符合檔案", systemImage: "magnifyingglass") }
                        .disabled(scanning || noCriteria)
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("刪除符合的 \(matchedFiles.count) 檔", systemImage: "trash")
                    }
                    .tint(AppTheme.Status.errorStrong)
                    .disabled(scanning || matchedFiles.isEmpty)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 560)
        .onAppear { rescan() }
        .onChange(of: shorterEnabled) { _, _ in rescan() }
        .confirmationDialog("刪除符合的 \(matchedFiles.count) 檔？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除 \(matchedFiles.count) 檔", role: .destructive) { performDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("這會從裝置上永久刪除這些錄音原始檔（釋出約 \(RecorderDeviceCard.sizeText(Int(matchedBytes)))）。已匯入的音檔副本與逐字稿不受影響，無法復原。")
        }
    }

    private func rescan() {
        guard !noCriteria else { scannedFiles = []; return }
        scanning = true
        Task {
            let result = await RecorderImportService.shared.cleanupScan(for: device, probeDuration: shorterEnabled)
            scannedFiles = result ?? []
            scanning = false
        }
    }

    private func performDelete() {
        let names = Set(matchedFiles.map { $0.fileName })
        let (deleted, freed) = RecorderImportService.shared.deleteDeviceFiles(fileNames: names, on: device)
        NotificationManager.shared.showNotification(
            title: "已清理 \(deleted) 檔，釋出 \(RecorderDeviceCard.sizeText(Int(freed)))", type: .success, duration: 3)
        onDone()
        rescan()
    }

    private static func durationText(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 60 ? "\(s / 60)分\(s % 60)秒" : "\(s)秒"
    }
}
