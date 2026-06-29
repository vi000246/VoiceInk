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
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.displayName).font(.headline)
                            Text("符合磁碟名稱：\(d.volumeNameMatch)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("自動匯入", isOn: bindingAutoImport(d))
                        Button(role: .destructive) { store.remove(d.id) } label: { Image(systemName: "trash") }
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
