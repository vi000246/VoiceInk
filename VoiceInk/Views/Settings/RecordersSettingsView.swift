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
                title: "Recorder Devices",
                infoMessage: "插入已設定的錄音筆即自動匯入、轉錄、分類，並輸出到 Obsidian Vault。",
                infoURL: nil
            ) {
                AppIconButton(systemName: "plus.circle.fill", help: "新增錄音筆") { editTarget = .add }
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
            Text("尚未設定錄音筆").font(.system(size: 16, weight: .medium))
            Text("插入錄音筆後點右上「+」新增，選擇裝置上存放錄音的資料夾。")
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
    @State private var isHovering = false
    @State private var expanded = false
    @State private var files: [RecorderImportService.DeviceFileStatus]?
    @State private var connected = false
    @State private var scanning = false
    @State private var selectedFiles: Set<String> = []
    @State private var confirmReprocess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "recordingtape")
                    .font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(AppTheme.Sidebar.fallback, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.displayName.isEmpty ? "未命名裝置" : device.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        connectionDot
                    }
                    Text("符合磁碟名稱：\(device.volumeNameMatch)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        pill(device.autoImportEnabled ? "自動匯入" : "已停用", on: device.autoImportEnabled)
                        if device.deleteAfterImport { pill("匯入後刪除", on: false) }
                    }
                }
                Spacer()
                Button("編輯", action: onEdit).controlSize(.small)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onEdit)

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

            if expanded { fileList.padding(.top, 8) }
        }
        .padding(14)
        .background(AppTheme.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isHovering ? AppTheme.Accent.primary.opacity(0.4) : AppTheme.Border.control, lineWidth: 0.5))
        .onHover { isHovering = $0 }
        .onAppear { connected = RecorderImportService.shared.isDeviceConnected(device) }
    }

    @ViewBuilder private var connectionDot: some View {
        HStack(spacing: 3) {
            Circle().fill(connected ? AppTheme.Status.success : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            Text(connected ? "已連接" : "未連接").font(.system(size: 10)).foregroundStyle(.secondary)
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
                    HStack {
                        Text("共 \(files.count) 檔・已處理 \(done)・未處理 \(files.count - done)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(selectedFiles.count == files.count ? "取消全選" : "全選") {
                            selectedFiles = selectedFiles.count == files.count ? [] : Set(files.map { $0.fileName })
                        }.controlSize(.mini)
                        Button("重新整理") { scan() }.controlSize(.mini)
                    }
                    ForEach(files) { f in
                        let isSel = selectedFiles.contains(f.fileName)
                        Button { toggleSelect(f.fileName) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSel ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSel ? AppTheme.Accent.primary : Color.secondary)
                                Image(systemName: f.processed ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 12))
                                    .foregroundStyle(f.processed ? AppTheme.Status.success : Color.secondary)
                                Text(f.fileName).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                if let m = f.modified {
                                    Text(m, format: .dateTime.month(.abbreviated).day().hour().minute())
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Text(f.processed ? "已處理" : "未處理")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(f.processed ? AppTheme.Status.success : .secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3).padding(.horizontal, 8)
                            .background((isSel ? AppTheme.Accent.primary.opacity(0.12) : AppTheme.Surface.control.opacity(0.5)),
                                        in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    if !selectedFiles.isEmpty {
                        HStack {
                            Text("已選 \(selectedFiles.count) 檔").font(.system(size: 11)).foregroundStyle(.secondary)
                            Spacer()
                            Button { confirmReprocess = true } label: {
                                Label("重新處理所選", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .medium))
                            }.controlSize(.small)
                        }
                        .padding(.top, 2)
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
        files = RecorderImportService.shared.deviceFiles(for: device, context: modelContext)
        selectedFiles = selectedFiles.intersection(Set(files?.map { $0.fileName } ?? []))
        scanning = false
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
}

// MARK: - Device Editor (slide-out panel)

private struct RecorderDeviceEditorPanel: View {
    let target: RecordersSettingsView.DeviceEditTarget
    @ObservedObject var store: RecorderConfigStore
    let onDismiss: () -> Void

    @State private var displayName: String
    @State private var volumeNameMatch: String
    @State private var sourceFolderBookmark: Data?
    @State private var sourceFolderName: String?
    @State private var autoImportEnabled: Bool
    @State private var deleteAfterImport: Bool

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
            _volumeNameMatch = State(initialValue: "")
            _sourceFolderBookmark = State(initialValue: nil)
            _sourceFolderName = State(initialValue: nil)
            _autoImportEnabled = State(initialValue: true)
            _deleteAfterImport = State(initialValue: false)
        case .edit(let d):
            existingId = d.id; createdAt = d.createdAt
            _displayName = State(initialValue: d.displayName)
            _volumeNameMatch = State(initialValue: d.volumeNameMatch)
            _sourceFolderBookmark = State(initialValue: d.sourceFolderBookmark)
            var stale = false
            let url = try? URL(resolvingBookmarkData: d.sourceFolderBookmark, options: [.withSecurityScope],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            _sourceFolderName = State(initialValue: url?.lastPathComponent)
            _autoImportEnabled = State(initialValue: d.autoImportEnabled)
            _deleteAfterImport = State(initialValue: d.deleteAfterImport)
        }
    }

    private var canSave: Bool {
        sourceFolderBookmark != nil && !volumeNameMatch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: target.id == "add" ? "新增錄音筆" : "編輯錄音筆", onClose: onDismiss)
            Form {
                Section("辨識") {
                    TextField("顯示名稱", text: $displayName)
                    TextField("符合磁碟名稱（插入時比對，包含即符合）", text: $volumeNameMatch)
                }
                Section("來源資料夾（裝置上存放錄音的位置）") {
                    HStack {
                        Text(sourceFolderName ?? "尚未選擇")
                            .foregroundStyle(sourceFolderName == nil ? .secondary : .primary)
                        Spacer()
                        Button("選擇…") { chooseSourceFolder() }
                    }
                }
                Section("自動化") {
                    Toggle("插入即自動匯入", isOn: $autoImportEnabled)
                    Toggle("匯入後刪除裝置原始檔（成功匯入＋轉錄＋輸出後才刪）", isOn: $deleteAfterImport)
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
        panel.message = "選擇錄音筆上存放錄音的資料夾"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        guard let bookmark = try? folder.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) else {
            NotificationManager.shared.showNotification(title: "無法建立資料夾授權", type: .error, duration: 4); return
        }
        sourceFolderBookmark = bookmark
        sourceFolderName = folder.lastPathComponent
        // Auto-fill the volume / display name from the folder's volume when blank.
        let volumeName = (try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? folder.lastPathComponent
        if volumeNameMatch.isEmpty { volumeNameMatch = volumeName }
        if displayName.isEmpty { displayName = volumeName }
    }

    private func save() {
        guard let bookmark = sourceFolderBookmark else { return }
        let device = RecorderDevice(
            id: existingId ?? UUID(),
            displayName: displayName.isEmpty ? volumeNameMatch : displayName,
            volumeNameMatch: volumeNameMatch,
            sourceFolderBookmark: bookmark,
            autoImportEnabled: autoImportEnabled,
            deleteAfterImport: deleteAfterImport,
            createdAt: createdAt)
        store.upsert(device)
        onDismiss()
    }

    private func deleteDevice() {
        if let id = existingId { store.remove(id) }
        onDismiss()
    }
}
