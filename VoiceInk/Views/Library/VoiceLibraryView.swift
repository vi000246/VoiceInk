import SwiftUI
import SwiftData

/// 語音管理 — 鏡射錄音管理的 Notion 式表格，但針對語音輸入／聽寫項（無 importFingerprint）：
/// 無匯出/範本/分類，改為手動 tag。欄位：勾選 · ★ · 標題/日期 · tag · 時長;點列開詳情彈窗。
struct VoiceLibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Transcription> { $0.importFingerprint == nil },
           sort: \Transcription.timestamp, order: .reverse)
    private var items: [Transcription]

    @ObservedObject private var sidebarModel = LibrarySidebarModel.shared
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @State private var searchText = ""
    @State private var debouncedQuery = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var selectedIds: Set<UUID> = []
    @State private var lastToggledId: UUID?
    @State private var confirmBatchDelete = false
    @State private var sortField: VoiceSortField = .date
    @State private var sortAscending = false
    @State private var detailTarget: Transcription?

    enum VoiceSortField { case date, title, duration }

    private static let dateSearchFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private var filteredItems: [Transcription] {
        let q = debouncedQuery
        return items.filter { t in
            if let tag = sidebarModel.voiceTagFilter, t.manualTag != tag { return false }
            guard !q.isEmpty else { return true }
            if let tag = t.manualTag, tag.localizedCaseInsensitiveContains(q) { return true }
            if Self.dateSearchFormatter.string(from: t.timestamp).contains(q) { return true }
            if t.text.localizedCaseInsensitiveContains(q) { return true }
            if let enhanced = t.enhancedText, enhanced.localizedCaseInsensitiveContains(q) { return true }
            return false
        }
    }

    private var sortedItems: [Transcription] {
        filteredItems.sorted { a, b in
            let result: Bool
            switch sortField {
            case .date: result = a.timestamp < b.timestamp
            case .duration: result = a.duration < b.duration
            case .title: result = VoiceRowDisplay.title(a).localizedStandardCompare(VoiceRowDisplay.title(b)) == .orderedAscending
            }
            return sortAscending ? result : !result
        }
    }

    private var selectedTranscriptions: [Transcription] { items.filter { selectedIds.contains($0.id) } }
    private var starredInSelection: Int { selectedTranscriptions.filter { $0.recorderFavorite }.count }
    private var allSelected: Bool {
        !filteredItems.isEmpty && filteredItems.allSatisfy { selectedIds.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "語音管理",
                infoMessage: "語音輸入／聽寫的逐字稿。可搜尋、依欄位排序、加手動 tag（左側選單可依 tag 展開篩選）。勾選多筆可批次刪除（星號 ★ 一律保護，需先取消星號）。點一列看完整內容與動作。自動清理設定在左側「語音設定」。",
                infoURL: nil
            ) { EmptyView() }

            searchBar
            Divider()

            if filteredItems.isEmpty {
                emptyState
            } else {
                VoiceTableHeader(sort: $sortField, ascending: $sortAscending)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedItems) { t in
                            VoiceLibraryRow(
                                transcription: t,
                                isChecked: selectedIds.contains(t.id),
                                onToggleCheck: { toggle(t.id) },
                                onOpen: { detailTarget = t }
                            )
                            Divider().opacity(0.35)
                        }
                    }
                }
            }

            if !filteredItems.isEmpty {
                Divider()
                selectionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { sidebarModel.refresh(modelContext) }
        .onChange(of: items.count) { _, _ in sidebarModel.refresh(modelContext) }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            let q = newValue.trimmingCharacters(in: .whitespaces)
            searchDebounceTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedQuery = q
            }
        }
        .confirmationDialog(batchDeleteMessage, isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            // 星號一律保護：只刪非星號的;星號要刪需先取消星號。
            let (protectedDelete, starred) = LibraryFilter.deletionSet(from: selectedTranscriptions, includeStarred: false)
            if !protectedDelete.isEmpty {
                Button("刪除 \(protectedDelete.count) 筆" + (starred > 0 ? "（保留 \(starred) 筆 ★）" : ""), role: .destructive) {
                    performBatchDelete(protectedDelete)
                }
            }
        }
        .centeredModal(item: $detailTarget) { t in
            VoiceDetailSheet(transcription: t, onClose: { detailTarget = nil })
                .environmentObject(enhancementService)
                .frame(maxWidth: 900, maxHeight: 820)
                .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.Border.control, lineWidth: 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.system(size: 12))
                TextField("搜尋逐字稿、tag、日期(yyyy-MM-dd)…", text: $searchText)
                    .textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(AppTheme.Surface.card))
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Button(allSelected ? "取消全選" : "全選") {
                if allSelected { selectedIds.removeAll() }
                else { selectedIds = Set(filteredItems.map { $0.id }) }
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            if !selectedIds.isEmpty {
                Text("已選 \(selectedIds.count) 筆").font(.system(size: 13)).foregroundColor(.secondary)
                if starredInSelection > 0 {
                    Text("· ★\(starredInSelection) 受保護").font(.system(size: 12)).foregroundStyle(Color.yellow)
                }
            }
            Spacer()
            if !selectedIds.isEmpty {
                Button { confirmBatchDelete = true } label: {
                    Label("刪除所選", systemImage: "trash").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundColor(AppTheme.Status.error.opacity(0.85))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(AppTheme.Surface.window.shadow(color: .black.opacity(0.1), radius: 3, y: -2))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "waveform" : "doc.text.magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.6))
            Text(searchText.isEmpty ? "尚無語音逐字稿" : "查無符合").font(.system(size: 16, weight: .medium))
            Text(searchText.isEmpty ? "用快捷鍵聽寫後，逐字稿會列在這裡。" : "換個關鍵字試試。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var batchDeleteMessage: String {
        let n = selectedTranscriptions.count
        if starredInSelection > 0 {
            return "所選 \(n) 筆中有 \(starredInSelection) 筆星號 ★，會被保留、不會刪除。要刪除這些請先在該筆取消星號。"
        }
        return "刪除所選 \(n) 筆逐字稿？"
    }

    private func toggle(_ id: UUID) {
        if NSEvent.modifierFlags.contains(.shift), let anchor = lastToggledId, anchor != id,
           let a = filteredItems.firstIndex(where: { $0.id == anchor }),
           let b = filteredItems.firstIndex(where: { $0.id == id }) {
            let range = a <= b ? a...b : b...a
            selectedIds.formUnion(filteredItems[range].map { $0.id })
        } else {
            if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
        }
        lastToggledId = id
    }

    private func performBatchDelete(_ toDelete: [Transcription]) {
        TranscriptionStore.delete(toDelete, in: modelContext)
        selectedIds.removeAll()
    }
}

// MARK: - Display helper

enum VoiceRowDisplay {
    /// 語音項顯示標題：優先 recorderTitle（少見），否則取 enhancedText/text 的首段做摘要。
    static func title(_ t: Transcription) -> String {
        if let rt = t.recorderTitle, !rt.isEmpty { return rt }
        let source = (t.enhancedText?.isEmpty == false ? t.enhancedText! : t.text)
        let firstLine = source.split(whereSeparator: \.isNewline).first.map(String.init) ?? source
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "（空白逐字稿）" : String(trimmed.prefix(60))
    }

    static func durationText(_ t: Transcription) -> String {
        let total = Int(t.duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Sortable header

private struct VoiceTableHeader: View {
    @Binding var sort: VoiceLibraryView.VoiceSortField
    @Binding var ascending: Bool

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 37, height: 1)   // 對齊：勾選(15)+星號(12)欄
            sortLabel("標題", field: .title).frame(maxWidth: .infinity, alignment: .leading)
            sortLabel("日期", field: .date).frame(width: 150, alignment: .leading)
            Text("Tag").frame(width: 110, alignment: .leading)
            sortLabel("時長", field: .duration).frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(height: 20)
        .padding(.horizontal, 24).padding(.vertical, 6)
    }

    private func sortLabel(_ label: String, field: VoiceLibraryView.VoiceSortField) -> some View {
        Button { toggle(field) } label: {
            HStack(spacing: 3) {
                Text(label)
                if sort == field {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
            }
        }.buttonStyle(.plain)
    }

    private func toggle(_ field: VoiceLibraryView.VoiceSortField) {
        if sort == field { ascending.toggle() } else { sort = field; ascending = false }
    }
}

// MARK: - Row

private struct VoiceLibraryRow: View {
    let transcription: Transcription
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onOpen: () -> Void

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15)).foregroundStyle(isChecked ? AppTheme.Accent.primary : .secondary)
            }
            .buttonStyle(.plain).frame(width: 15)

            Button(action: toggleFavorite) {
                Image(systemName: transcription.recorderFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(transcription.recorderFavorite ? Color.yellow : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain).frame(width: 12)

            Text(VoiceRowDisplay.title(transcription)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(transcription.timestamp, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: 150, alignment: .leading)

            Group {
                if let tag = transcription.manualTag, !tag.isEmpty {
                    Text(tag).font(.system(size: 11, weight: .medium)).foregroundStyle(AppTheme.Accent.primary)
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(AppTheme.Accent.primary.opacity(0.12)))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .frame(width: 110, alignment: .leading)

            Text(VoiceRowDisplay.durationText(transcription)).foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24).padding(.vertical, 9)
        .background(isChecked ? AppTheme.Accent.primary.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }

    private func toggleFavorite() {
        transcription.recorderFavorite.toggle()
        try? modelContext.save()
    }
}

// MARK: - Detail sheet

private struct VoiceDetailSheet: View {
    let transcription: Transcription
    let onClose: () -> Void
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @State private var showAnalysis = false
    @State private var tagText = ""
    @State private var confirmDelete = false
    @State private var selectedTemplateId: UUID?
    @State private var isApplying = false

    /// 可套用到語音逐字稿的範本＝逐字稿範本中勾了「語音輸入」的那些。
    private var voiceTemplates: [CustomPrompt] { TemplateStore.shared.templates(for: .voiceInput) }

    private var hasAnalysis: Bool { transcription.enhancedText?.isEmpty == false }
    private var displayText: String { (showAnalysis ? transcription.enhancedText : transcription.text) ?? transcription.text }

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "逐字稿詳情", onClose: onClose)

            // 動作列：手動 tag + Ask AI + 刪除。
            HStack(spacing: 10) {
                Image(systemName: "tag").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("手動 tag（分類語音）", text: $tagText)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                    .onSubmit(saveTag)
                Button("儲存 tag", action: saveTag).controlSize(.small)
                    .disabled(tagText.trimmingCharacters(in: .whitespaces) == (transcription.manualTag ?? ""))
                Spacer()
                Button {
                    onClose()
                    AppNavigator.shared.askAI(about: transcription.id)
                } label: { Label("Ask AI", systemImage: "bubble.left.and.text.bubble.right.fill") }
                    .controlSize(.small)
                Button(role: .destructive) { confirmDelete = true } label: {
                    Label("刪除", systemImage: "trash")
                }.controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)

            // 套用範本：挑一個逐字稿範本（勾了語音輸入的）把逐字稿整理成想要的格式 → 進「套用後」分頁。
            if !voiceTemplates.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "text.alignleft").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("套用範本", selection: $selectedTemplateId) {
                        Text("選擇逐字稿範本…").tag(UUID?.none)
                        ForEach(voiceTemplates) { p in Text(p.title).tag(UUID?.some(p.id)) }
                    }.labelsHidden().frame(maxWidth: 240)
                    Button("套用", action: applyTemplate).controlSize(.small)
                        .disabled(selectedTemplateId == nil || isApplying)
                    if isApplying {
                        HStack(spacing: 5) { ProgressView().controlSize(.small); Text("處理中…").font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }

            HStack(spacing: 6) {
                tab("原始逐字稿", active: !showAnalysis) { showAnalysis = false }
                if hasAnalysis { tab("套用後", active: showAnalysis) { showAnalysis = true } }
                Spacer()
                CopyIconButton(textToCopy: displayText)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()

            ScrollView {
                Text(displayText.isEmpty ? "（無內容）" : displayText)
                    .font(.system(size: 14))
                    .foregroundStyle(displayText.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(AppTheme.Text.primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { tagText = transcription.manualTag ?? "" }
        .confirmationDialog("刪除這筆逐字稿？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) {
                TranscriptionStore.delete(transcription, in: modelContext)
                onClose()
            }
        }
    }

    private func saveTag() {
        let t = tagText.trimmingCharacters(in: .whitespacesAndNewlines)
        transcription.manualTag = t.isEmpty ? nil : t
        try? modelContext.save()
        LibrarySidebarModel.shared.refresh(modelContext)
    }

    /// 用選定的逐字稿範本整理原始逐字稿，結果寫入 enhancedText（「套用後」分頁）。
    private func applyTemplate() {
        guard let pid = selectedTemplateId,
              let prompt = voiceTemplates.first(where: { $0.id == pid }),
              let ai = enhancementService.getAIService() else { return }
        isApplying = true
        Task {
            defer { isApplying = false }
            let config = EnhancementRuntimeConfiguration(
                mode: nil, isEnabled: true, prompt: prompt,
                provider: ai.selectedProvider, modelName: nil,
                useClipboardContext: false, useSelectedTextContext: false, useScreenCaptureContext: false)
            do {
                let (enhanced, _, _) = try await enhancementService.enhance(transcription.text, configuration: config)
                transcription.enhancedText = enhanced
                try? modelContext.save()
                showAnalysis = true
            } catch {
                NotificationManager.shared.showNotification(
                    title: "套用失敗：\(error.localizedDescription)", type: .error, duration: 5)
            }
        }
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
