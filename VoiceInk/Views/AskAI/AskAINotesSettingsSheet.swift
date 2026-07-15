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
/// 手動重建、**索引覆蓋率**。
///
/// 覆蓋率那一節是這個 sheet 存在的第二個理由:增量索引的失效全是靜默的——新檔沒被掃到、
/// 改過的檔沒重嵌、刪掉的檔留著幽靈塊,使用者一律看不到,只會發現「AI 怎麼不知道我上週寫的
/// 東西」。把「vault 現在有什麼」對上「索引裡真的有什麼」攤成一張表,漏掉的檔就無所遁形。
struct AskAINotesSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @StateObject private var notesConfig = ObsidianRAGConfigStore.shared
    /// 索引的 in-flight 與進度都住在單例上 —— 這個 sheet 只是觀察者,關掉它索引照跑。
    @ObservedObject private var coordinator = NoteIndexCoordinator.shared

    /// vault 第一層資料夾的快取。**不**在 body 裡直接掃 —— SwiftUI 每次重繪都會重建 Menu
    /// 的內容,那等於每次重繪都打一次磁碟。開 sheet 與換 vault 時各掃一次就夠。
    @State private var folders: [String] = []

    // 覆蓋率
    @State private var coverage: NoteIndexCoverage?
    @State private var coverageLoading = false
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var showOnlyProblems = false
    @State private var page = 0
    /// 資料夾群組視圖裡「展開了哪些資料夾」。用 Set 而非 DisclosureGroup 自管狀態:
    /// 覆蓋率每隔幾秒重掃一次,自管狀態在重繪時容易被吃掉,綁 Set 才留得住展開。
    @State private var expandedFolders: Set<String> = []
    @State private var showForceConfirm = false
    /// 覆蓋率掃描的 in-flight ＋ 世代標記：只有「最新的那一輪」有資格把結果寫進畫面。
    @State private var coverageTask: Task<Void, Never>?
    @State private var coverageGeneration = 0

    /// 每頁列數（鏡射 `RecordersSettingsView` 的檔案清單——Form 裡不巢狀 ScrollView,改用分頁）。
    private static let pageSize = 50
    /// 單一資料夾展開時最多列幾個待處理檔（其餘用搜尋定位——避免一個資料夾撐爆整頁）。
    private static let maxExpandedRows = 100

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
                coverageSection
            }
            .formStyle(.grouped)
        }
        .onAppear {
            refreshFolders()
            loadCoverage()
        }
        .onChange(of: notesConfig.notesVaultBookmark) { _, _ in
            refreshFolders()
            loadCoverage()
        }
        // 索引跑完 → 覆蓋率表立刻反映新結果（不用手動按重新整理才看得到自己剛剛做了什麼）。
        .onChange(of: coordinator.lastRun) { _, _ in loadCoverage() }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespaces)
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedQuery = q
                page = 0
            }
        }
        .confirmationDialog("強制全量重嵌整個筆記庫？", isPresented: $showForceConfirm,
                            titleVisibility: .visible) {
            Button("全量重嵌（\(coverage?.entries.count ?? 0) 個檔）", role: .destructive) {
                startNotesIndex(force: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("會無視「這個檔沒變過」的紀錄，把範圍內每一個筆記檔重新送去 embedding API（要花錢）。索引狀態看起來不對、或想確定塊是最新的，才需要這個；平常按「重建筆記庫索引」就夠了——它只重嵌改過的檔。")
        }
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

            Text("指定「只索引」後,vault 根目錄的散檔不會被索引。改動範圍後按「重建筆記庫索引」才會生效。")
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
        page = 0         // 換了範圍＝換了一整份清單，停在第 3 頁沒有意義
        loadCoverage()   // 範圍變了 → 覆蓋率表的分母就變了
    }

    private func toggleExcluded(_ name: String) {
        notesConfig.setExcludedFolders(Self.toggled(name, in: notesConfig.excludedFolders))
        page = 0
        loadCoverage()
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
            if let progress = coordinator.progress {
                runningRow(progress)
            } else {
                HStack(spacing: 8) {
                    Button("重建筆記庫索引") { startNotesIndex(force: false) }
                        .disabled(vaultRoot == nil)
                    Menu {
                        Button("強制全量重嵌…", role: .destructive) { showForceConfirm = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(vaultRoot == nil)
                    Spacer()
                }
                if let last = coordinator.lastRun { lastRunRow(last) }
            }

            Text("只重嵌改過的檔（沒動過的檔不會重打 embedding API）。進 Ask AI 頁、開啟筆記 chip、開始會議時都會自動掃一次。**按下去就可以關掉這個視窗——索引在背景跑,進度會顯示在 Ask AI 頁右上。**")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 索引進行中：進度條 ＋ 目前檔名 ＋ 取消。
    private func runningRow(_ progress: NoteIndexCoordinator.Progress) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.Accent.primary)
                Text("\(progress.scanned)/\(max(progress.total, 1))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Button("取消") { coordinator.cancel() }.controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("已重嵌 \(progress.reembedded) 檔")
                    .font(.caption).foregroundStyle(AppTheme.Accent.primary)
                if let file = progress.currentFile {
                    Text("· \(file)").font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }

    /// 上一輪的結果（跨 sheet 開關保留——關掉再打開仍看得到自己上次做了什麼）。
    private func lastRunRow(_ last: NoteIndexCoordinator.RunResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: last.errorMessage != nil ? "exclamationmark.triangle.fill"
                              : last.cancelled ? "stop.circle" : "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(last.errorMessage != nil ? AppTheme.Status.errorStrong
                                 : last.cancelled ? Color.secondary : AppTheme.Status.positive)
            Text(Self.summary(of: last)).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
    }

    static func summary(of last: NoteIndexCoordinator.RunResult) -> String {
        let time = last.finishedAt.formatted(date: .omitted, time: .shortened)
        if let error = last.errorMessage { return "\(time) 索引失敗：\(error)" }
        if last.cancelled { return "\(time) 已取消（已重嵌 \(last.reembedded) 檔，下次會接著做）" }
        if last.reembedded == 0 { return "\(time) 已是最新（掃了 \(last.totalFiles) 檔，沒有變動）" }
        return "\(time) 已重嵌 \(last.reembedded) 檔（掃了 \(last.totalFiles) 檔）"
    }

    private func startNotesIndex(force: Bool) {
        guard let vaultRoot,
              let stateURL = try? ObsidianNoteIndexService.defaultStateURL() else { return }
        // 交給單例跑：Task 不歸這個 view 所有 → 關掉 sheet 索引照跑。
        coordinator.start(vaultRoot: vaultRoot,
                          includeOnly: notesConfig.includeOnlyFolders,
                          excluded: notesConfig.excludedFolders,
                          stateURL: stateURL,
                          modelContext: modelContext,
                          force: force,
                          announce: true)
    }

    // MARK: - 覆蓋率

    @ViewBuilder
    private var coverageSection: some View {
        Section("索引覆蓋率") {
            if vaultRoot == nil {
                Text("先選一個 Vault。").font(.caption).foregroundStyle(.secondary)
            } else if coverageLoading && coverage == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("掃描 vault 中…").font(.caption).foregroundStyle(.secondary)
                }
            } else if let coverage {
                coverageSummary(coverage)
                if coverage.legacyChunkCount > 0 {
                    Label("索引裡有 \(coverage.legacyChunkCount) 個舊格式塊（認不出屬於哪個檔）。按「強制全量重嵌」清乾淨。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(AppTheme.Status.warningStrong)
                }
                coverageControls
                coverageList
            }
        }
    }

    private func coverageSummary(_ coverage: NoteIndexCoverage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text("範圍內 \(coverage.entries.filter { $0.status != .ghost }.count) 檔")
                    .font(.system(size: 12, weight: .medium))
                Text("· 已索引 \(coverage.indexedFileCount)").font(.system(size: 12))
                    .foregroundStyle(AppTheme.Status.positive)
                if coverage.count(.pending) > 0 {
                    Text("· 尚未索引 \(coverage.count(.pending))").font(.system(size: 12))
                        .foregroundStyle(AppTheme.Status.warningStrong)
                }
                if coverage.count(.stale) > 0 {
                    Text("· 待重嵌 \(coverage.count(.stale))").font(.system(size: 12))
                        .foregroundStyle(AppTheme.Status.warningStrong)
                }
                if coverage.count(.ghost) > 0 {
                    Text("· 待清理 \(coverage.count(.ghost))").font(.system(size: 12))
                        .foregroundStyle(AppTheme.Status.error)
                }
                Spacer()
            }
            Text(coverage.needsReindex
                 ? "有檔案還沒進索引——Ask AI 現在問不到它們。按上面的「重建筆記庫索引」補上。"
                 : "範圍內的筆記都已進索引（共 \(coverage.totalChunkCount) 個片段）。")
                .font(.caption)
                .foregroundStyle(coverage.needsReindex ? AppTheme.Status.warningStrong : .secondary)
        }
    }

    private var coverageControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 11))
                TextField("搜尋檔名／路徑…", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(AppTheme.Surface.card))

            Toggle("只看待處理", isOn: $showOnlyProblems)
                .toggleStyle(.checkbox).font(.system(size: 11))
                .onChange(of: showOnlyProblems) { _, _ in page = 0 }

            Button { loadCoverage() } label: {
                if coverageLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .controlSize(.small)
            .disabled(coverageLoading)
            .help("重新掃描 vault 並比對索引")
        }
    }

    /// 目前要顯示的列（搜尋 ＋「只看待處理」過濾後）。
    private var filteredEntries: [NoteIndexCoverageEntry] {
        guard let coverage else { return [] }
        var list = coverage.entries
        if showOnlyProblems { list = list.filter { $0.status.needsReindex || $0.status == .ghost } }
        if !debouncedQuery.isEmpty {
            list = list.filter { $0.relativePath.localizedCaseInsensitiveContains(debouncedQuery) }
        }
        return list
    }

    @ViewBuilder
    private var coverageList: some View {
        // 搜尋 = 找某個特定檔 → 逐檔查最直接,平鋪符合的列(沿用分頁的舊行為)。
        // 沒搜尋 = 瀏覽 → 依資料夾群組:整個資料夾索引好只顯示一行,部分索引顯示覆蓋率百分比。
        if debouncedQuery.isEmpty {
            folderGroupList
        } else {
            searchResultList
        }
    }

    /// 資料夾群組視圖(瀏覽模式)。
    @ViewBuilder
    private var folderGroupList: some View {
        let groups = folderGroups
        if groups.isEmpty {
            Text(showOnlyProblems ? "沒有待處理的資料夾——索引是完整的。" : "範圍內沒有筆記檔。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 6)
        } else {
            VStack(spacing: 3) {
                ForEach(groups) { folder in folderRow(folder) }
            }
        }
    }

    /// 依「只看待處理」過濾後的資料夾群組(待處理的在前;見 `groupedByFolder`)。
    private var folderGroups: [NoteFolderCoverage] {
        guard let coverage else { return [] }
        let groups = coverage.groupedByFolder()
        return showOnlyProblems ? groups.filter { !$0.isFullyIndexed } : groups
    }

    private func folderDisplayName(_ folder: NoteFolderCoverage) -> String {
        folder.folder.isEmpty ? "（vault 根目錄）" : folder.folder
    }

    @ViewBuilder
    private func folderRow(_ folder: NoteFolderCoverage) -> some View {
        if folder.isFullyIndexed {
            // 全數索引好 → 一行帶過,不展開(使用者不需要逐檔看已經好的)。
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
                    .foregroundStyle(AppTheme.Status.positive).frame(width: 16)
                Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(folderDisplayName(folder)).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("已索引 \(folder.indexedCount) 檔").font(.system(size: 11))
                    .foregroundStyle(AppTheme.Status.positive)
            }
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background(AppTheme.Surface.control.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        } else {
            // 部分索引 → 顯示覆蓋率百分比,點開才列出還沒索引的檔。
            DisclosureGroup(isExpanded: folderExpansion(folder.folder)) {
                let problems = folder.problemEntries
                let shown = Array(problems.prefix(Self.maxExpandedRows))
                VStack(spacing: 3) {
                    ForEach(shown) { entry in coverageRow(entry) }
                    if problems.count > shown.count {
                        Text("…還有 \(problems.count - shown.count) 個(用上方搜尋定位)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
                    }
                }
                .padding(.top, 3)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 11))
                        .foregroundStyle(AppTheme.Status.warningStrong).frame(width: 16)
                    Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(folderDisplayName(folder)).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("待處理 \(folder.problemEntries.count)").font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("\(folder.percentIndexed)%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.Status.warningStrong)
                        .frame(width: 42, alignment: .trailing)
                }
            }
            .padding(.vertical, 2).padding(.horizontal, 8)
            .background(AppTheme.Surface.control.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func folderExpansion(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expandedFolders.contains(key) },
            set: { isOn in
                if isOn { expandedFolders.insert(key) } else { expandedFolders.remove(key) }
            })
    }

    /// 搜尋結果的平鋪清單(搜尋模式)。
    @ViewBuilder
    private var searchResultList: some View {
        let entries = filteredEntries
        if entries.isEmpty {
            Text(showOnlyProblems ? "沒有待處理的檔——索引是完整的。" : "查無符合的檔案。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 6)
        } else {
            // Form 裡不巢狀 ScrollView（全 app 沒有這種寫法）——改用分頁,鏡射 RecordersSettingsView。
            let pageCount = max(1, (entries.count + Self.pageSize - 1) / Self.pageSize)
            let current = min(page, pageCount - 1)
            let paged = Array(entries.dropFirst(current * Self.pageSize).prefix(Self.pageSize))

            VStack(spacing: 3) {
                ForEach(paged) { entry in coverageRow(entry) }
            }

            if pageCount > 1 {
                HStack(spacing: 12) {
                    Spacer()
                    Button { page = max(0, current - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(current == 0).controlSize(.small)
                    Text("第 \(current + 1) / \(pageCount) 頁（共 \(entries.count) 檔）")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Button { page = min(pageCount - 1, current + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(current >= pageCount - 1).controlSize(.small)
                    Spacer()
                }
            }
        }
    }

    private func coverageRow(_ entry: NoteIndexCoverageEntry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.icon(for: entry.status))
                .font(.system(size: 11))
                .foregroundStyle(Self.color(for: entry.status))
                .frame(width: 16)
            Text(entry.relativePath)
                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.chunkCount > 0 ? "\(entry.chunkCount) 塊" : "—")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 46, alignment: .trailing)
            Text(entry.status.label)
                .font(.system(size: 11))
                .foregroundStyle(Self.color(for: entry.status))
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(AppTheme.Surface.control.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .help(entry.relativePath)
    }

    private static func icon(for status: NoteIndexStatus) -> String {
        switch status {
        case .indexed: return "checkmark.circle.fill"
        case .stale:   return "pencil.circle.fill"
        case .pending: return "exclamationmark.circle.fill"
        case .empty:   return "minus.circle"
        case .ghost:   return "xmark.circle.fill"
        }
    }

    private static func color(for status: NoteIndexStatus) -> Color {
        switch status {
        case .indexed: return AppTheme.Status.positive
        case .stale:   return AppTheme.Status.warningStrong
        case .pending: return AppTheme.Status.warningStrong
        case .empty:   return .secondary
        case .ghost:   return AppTheme.Status.error
        }
    }

    /// 掃 vault（背景執行緒）＋ 讀 sidecar ＋ 數索引裡的塊 → 比對成一張表。
    ///
    /// 三個來源缺一不可:
    /// - **塊**（權威）：檢索真正看得到的東西。只信 sidecar 會漏掉「hash 記了、塊卻不在」的情況。
    /// - **sidecar**：分得出「已索引且最新」與「已索引但檔案改過」——光看塊數看不出內容變沒變。
    /// - **vault 掃描**：分得出「新檔還沒進索引」與「索引裡的塊已經沒有對應檔案」。
    private func loadCoverage() {
        guard let vaultRoot else { coverage = nil; return }
        coverageLoading = true

        // 掃描是非同步的,而觸發點有六個（onAppear／換 vault／索引跑完／勾選 include／勾選 exclude／
        // 手動重新整理）。沒有世代標記的話,兩次掃描會**以完成順序**寫結果:在大 vault 上先按下的
        // 全庫掃描（慢）會後於隨後那次「只索引某資料夾」的窄掃描（快）落地,把新的表覆蓋成舊 scope
        // 的數字 —— 使用者看到的「尚未索引 N 檔」屬於一個他已經不再選取的範圍,而且畫面上沒有任何
        // 提示說它是舊的。這正是這張表最不該犯的錯（它存在的目的就是講實話）。
        coverageTask?.cancel()
        coverageGeneration &+= 1
        let generation = coverageGeneration

        let includeOnly = notesConfig.includeOnlyFolders
        let excluded = notesConfig.excludedFolders
        let modelTag = TranscriptIndexService.shared.model.tag
        let stateURL = try? ObsidianNoteIndexService.defaultStateURL()
        // 塊計數必須在 MainActor 上抓（modelContext 不跨執行緒）。
        let (chunkCounts, legacyChunkCount) = Self.obsidianChunkCounts(in: modelContext)

        coverageTask = Task {
            // 幾千個檔的 walk＋SHA-256 掛在 MainActor 上會讓整個視窗卡住 → 丟去背景。
            let scanned = await Task.detached(priority: .userInitiated) {
                ObsidianNoteIndexService.scanNotesWithHashes(
                    vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded)
            }.value
            let sidecar = stateURL.map {
                ObsidianNoteIndexService.loadSidecar(stateURL: $0, currentModelTag: modelTag)
            } ?? [:]
            let computed = NoteIndexCoverage.compute(
                scanned: scanned, sidecar: sidecar,
                chunkCounts: chunkCounts, legacyChunkCount: legacyChunkCount)

            // 落地前確認自己還是最新的那一輪，否則安靜退場（連 coverageLoading 都不要動——
            // 那是接手的那一輪的狀態）。
            guard generation == coverageGeneration else { return }
            coverage = computed
            coverageLoading = false
        }
    }

    /// 索引裡的 obsidian 塊依 `sourcePath` 分組計數；`sourcePath == nil` 的是 M8 舊格式殘留。
    private static func obsidianChunkCounts(in context: ModelContext) -> ([String: Int], Int) {
        let kind = ObsidianNoteIndexService.sourceKind
        let chunks = (try? context.fetch(FetchDescriptor<EmbeddingChunk>(
            predicate: #Predicate { $0.sourceKind == kind }))) ?? []
        var counts: [String: Int] = [:]
        var legacy = 0
        for chunk in chunks {
            if let path = chunk.sourcePath { counts[path, default: 0] += 1 } else { legacy += 1 }
        }
        return (counts, legacy)
    }
}
