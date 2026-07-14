import SwiftUI
import SwiftData
import AppKit

/// vault 第一層目錄掃描。純邏輯、無 UI 相依 —— 是這個 sheet 唯一值得測的部分。
enum ObsidianVaultBrowser {
    /// vault 第一層目錄名（含 dot 目錄、排序）。呼叫端自行包 security-scope。
    ///
    /// 只列目錄:資料夾 include/exclude 在索引端是「路徑前綴」比對,散檔勾了也不會有任何
    /// 效果 —— 讓它出現在清單裡只是誤導。dot 目錄照列（`.obsidian` 本來就是預設排除項,
    /// 使用者要看得到才能取消排除）。
    static func firstLevelFolders(of root: URL) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent).sorted()
    }
}

/// FR-7:筆記來源設定（Ask AI 右上齒輪 →「筆記來源設定…」）。
///
/// 筆記管線的設定新家:vault（可 override 錄音匯出 vault）、索引範圍（兩組資料夾）、
/// 手動重建。Form + Section 風格鏡射 `MeetingCopilotSettingsView`;`reindexNotes()` 是
/// 從該頁整段搬過來的（Task 11 會把舊的那份刪掉）。
struct AskAINotesSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var notesConfig = ObsidianRAGConfigStore.shared

    /// vault 第一層資料夾的快取。**不**在 body 裡直接掃 —— SwiftUI 每次重繪都會重建 Menu
    /// 的內容,那等於每次重繪都打一次磁碟。開 sheet 與換 vault 時各掃一次就夠。
    @State private var folders: [String] = []
    @State private var indexing = false
    @State private var indexMessage: String?

    /// override 優先、否則跟隨錄音匯出 vault（唯一解析點在 store）。
    private var vaultRoot: URL? { notesConfig.effectiveVaultRoot() }
    private var hasOverride: Bool { notesConfig.notesVaultBookmark != nil }

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "筆記來源設定", onClose: { dismiss() })
            Form {
                vaultSection
                foldersSection
                indexSection
            }
            .formStyle(.grouped)
        }
        .onAppear { refreshFolders() }
        .onChange(of: notesConfig.notesVaultBookmark) { _, _ in refreshFolders() }
    }

    // MARK: - Vault

    private var vaultSection: some View {
        Section("筆記 Vault") {
            LabeledContent("目前 Vault") {
                if let path = vaultRoot?.path {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(path).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(hasOverride ? "自訂" : "跟隨錄音匯出 Vault")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("尚未設定——選一個 Vault,或到「錄音裝置」設定 Obsidian Vault")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            HStack(spacing: 8) {
                Button(vaultRoot == nil ? "選擇 Vault…" : "更換…") { chooseVault() }
                    .controlSize(.small)
                if hasOverride {
                    Button("改回跟隨錄音 Vault") { notesConfig.setNotesVaultBookmark(nil) }
                        .controlSize(.small)
                }
                Spacer()
            }

            Text("筆記索引預設跟著「錄音裝置」頁設定的匯出 Vault 走。筆記在別的 vault 時才需要在這裡另外指定。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// NSOpenPanel + security-scoped bookmark（鏡射 `RecordersSettingsView.chooseVault`）。
    /// 這裡寫的是**筆記專用** override,不會動到錄音匯出的 vault。
    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "選擇筆記的 Obsidian Vault 根目錄"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        guard let bookmark = try? root.bookmarkData(options: [.withSecurityScope],
                                                    includingResourceValuesForKeys: nil, relativeTo: nil) else {
            NotificationManager.shared.showNotification(title: "無法建立 Vault 授權", type: .error, duration: 4); return
        }
        notesConfig.setNotesVaultBookmark(bookmark)
    }

    // MARK: - 資料夾範圍

    private var foldersSection: some View {
        Section("索引範圍") {
            LabeledContent("只索引資料夾") {
                folderMenu(summary: notesConfig.includeOnlyFolders.isEmpty
                            ? "全部"
                            : "\(notesConfig.includeOnlyFolders.count) 個資料夾",
                           selected: notesConfig.includeOnlyFolders,
                           toggle: toggleIncludeOnly)
            }
            LabeledContent("排除資料夾") {
                folderMenu(summary: notesConfig.excludedFolders.isEmpty
                            ? "無"
                            : "\(notesConfig.excludedFolders.count) 個資料夾",
                           selected: notesConfig.excludedFolders,
                           toggle: toggleExcluded)
            }

            Text("指定「只索引」後,vault 根目錄的散檔不會被索引。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 勾選式的資料夾多選（鏡射 `AskAIView.categorySection` 的 checkmark Button 形狀）。
    /// vault 沒設定 → 沒東西可掃,整顆 Menu disable（比給一個空選單誠實）。
    private func folderMenu(summary: String,
                            selected: [String],
                            toggle: @escaping (String) -> Void) -> some View {
        Menu {
            if folders.isEmpty {
                Text("（vault 裡沒有第一層資料夾）")
            } else {
                ForEach(folders, id: \.self) { name in
                    Button { toggle(name) } label: {
                        Label(name, systemImage: selected.contains(name) ? "checkmark" : "")
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(summary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(vaultRoot == nil)
    }

    private func toggleIncludeOnly(_ name: String) {
        notesConfig.setIncludeOnlyFolders(Self.toggled(name, in: notesConfig.includeOnlyFolders))
    }

    private func toggleExcluded(_ name: String) {
        notesConfig.setExcludedFolders(Self.toggled(name, in: notesConfig.excludedFolders))
    }

    /// 已選 → 拿掉;未選 → 加入（維持排序,清單看起來才穩定）。
    private static func toggled(_ name: String, in list: [String]) -> [String] {
        if let i = list.firstIndex(of: name) {
            var next = list
            next.remove(at: i)
            return next
        }
        return (list + [name]).sorted()
    }

    /// vault 是 security-scoped bookmark 解析出來的 URL —— 碰檔案前要開 scope
    /// （鏡射 `ObsidianNoteIndexService.reindex`）。
    private func refreshFolders() {
        guard let vault = vaultRoot else { folders = []; return }
        let accessing = vault.startAccessingSecurityScopedResource()
        defer { if accessing { vault.stopAccessingSecurityScopedResource() } }
        folders = ObsidianVaultBrowser.firstLevelFolders(of: vault)
    }

    // MARK: - 索引

    private var indexSection: some View {
        Section("索引") {
            HStack(spacing: 8) {
                Button("重建筆記索引") { reindexNotes() }
                    .disabled(indexing)
                if indexing { ProgressView().controlSize(.small) }
                if let indexMessage {
                    Text(indexMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("索引需要 embedding 金鑰。進 Ask AI 頁或開啟筆記 chip 時會自動增量掃描（只重嵌改過的檔）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func reindexNotes() {
        guard let vaultRoot else {
            indexMessage = "尚未設定 Obsidian Vault"
            return
        }
        indexing = true
        indexMessage = nil
        Task {
            do {
                // stateURL 與 live 端的背景掃描、Ask AI 的 autoIndex 共用
                // (見 ObsidianNoteIndexService.defaultStateURL)。
                let index = ObsidianNoteIndexService(
                    modelContext: modelContext,
                    stateURL: try ObsidianNoteIndexService.defaultStateURL())
                let count = try await index.reindex(
                    vaultRoot: vaultRoot,
                    includeOnly: notesConfig.includeOnlyFolders,
                    excluded: notesConfig.excludedFolders)
                indexMessage = count == 0
                    ? "已是最新(沒有檔案變動)"
                    : "已索引 \(count) 檔"
            } catch EmbeddingError.missingAPIKey {
                indexMessage = "需要 Gemini/OpenAI embedding 金鑰(Ask AI 設定)"
            } catch {
                indexMessage = "索引失敗:\(error.localizedDescription)"
            }
            indexing = false
        }
    }
}
