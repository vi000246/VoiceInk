import SwiftUI
import AppKit

struct RecordersSettingsView: View {
    @StateObject private var store = RecorderConfigStore.shared

    var body: some View {
        Form {
            Section("已設定的錄音筆") {
                if store.devices.isEmpty {
                    Text("尚未設定。插入錄音筆後點下方新增。").foregroundStyle(.secondary)
                }
                ForEach(store.devices) { d in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.displayName).font(.headline)
                                Text("符合磁碟名稱：\(d.volumeNameMatch)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { store.remove(d.id) } label: { Image(systemName: "trash") }
                        }
                        Toggle("自動匯入", isOn: bindingAutoImport(d))
                        Toggle("匯入後刪除裝置上的原始檔（成功匯入＋轉錄＋輸出後才刪）", isOn: bindingDeleteAfterImport(d))
                        HStack {
                            Text("Obsidian Vault：\(d.vaultRootBookmark == nil ? "未設定（不輸出）" : "已設定")")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("選擇 Vault 根目錄…") { chooseVaultRoot(d) }
                        }
                    }
                }
            }
            Section { Button("新增目前插入的裝置…") { addCurrentDevice() } }
        }
        .formStyle(.grouped)
    }

    private func bindingAutoImport(_ d: RecorderDevice) -> Binding<Bool> {
        Binding(get: { d.autoImportEnabled },
                set: { var x = d; x.autoImportEnabled = $0; store.upsert(x) })
    }

    private func bindingDeleteAfterImport(_ d: RecorderDevice) -> Binding<Bool> {
        Binding(get: { d.deleteAfterImport },
                set: { var x = d; x.deleteAfterImport = $0; store.upsert(x) })
    }

    private func chooseVaultRoot(_ d: RecorderDevice) {
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
        var x = d; x.vaultRootBookmark = bookmark; store.upsert(x)
    }

    private func addCurrentDevice() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "選擇錄音筆上存放錄音的資料夾"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let volumeName = (try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? folder.lastPathComponent
        guard let bookmark = try? folder.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) else {
            NotificationManager.shared.showNotification(title: "無法建立資料夾授權", type: .error, duration: 4); return
        }
        store.upsert(RecorderDevice(displayName: volumeName, volumeNameMatch: volumeName, sourceFolderBookmark: bookmark))
    }
}
