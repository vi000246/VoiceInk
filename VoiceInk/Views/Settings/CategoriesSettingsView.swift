import SwiftUI

/// Categories page — category cards + a 400pt slide-out editor that embeds the reusable
/// `PromptEditorView` for the bound analysis prompt. The fallback category is undeletable.
struct CategoriesSettingsView: View {
    @StateObject private var store = RecorderConfigStore.shared
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @State private var editTarget: CategoryEditTarget?

    enum CategoryEditTarget: Identifiable {
        case add
        case edit(RecorderCategory)
        var id: String { switch self { case .add: return "add"; case .edit(let c): return c.id.uuidString } }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Categories",
                infoMessage: "匯入的逐字稿會被分類到其中一個類別，套用該類別綁定的提示詞做分析，並輸出到 Vault 對應子資料夾。「通用」為無法分類時的預設，不可刪除。",
                infoURL: nil
            ) {
                AppIconButton(systemName: "plus.circle.fill", help: "新增類別") { editTarget = .add }
            }

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(store.categories) { category in
                        RecorderCategoryCard(
                            category: category,
                            promptTitle: enhancementService.allPrompts.first { $0.id == category.customPromptId }?.title
                        ) { editTarget = .edit(category) }
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
                CategoryEditorPanel(target: target, store: store, onDismiss: { editTarget = nil })
                    .id(target.id)
            }
        }
    }
}

// MARK: - Category Card

private struct RecorderCategoryCard: View {
    let category: RecorderCategory
    let promptTitle: String?
    let onEdit: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.isFallback ? "tray.fill" : "tag.fill")
                .font(.system(size: 16)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(category.isFallback ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(AppTheme.Accent.primary),
                            in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(category.name.isEmpty ? "未命名類別" : category.name)
                        .font(.system(size: 14, weight: .semibold))
                    if category.isFallback {
                        Text("預設").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
                Text("範本：\(promptTitle ?? "未綁定（輸出原始逐字稿）")   ·   子資料夾：\(category.subfolderName)")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("編輯", action: onEdit).controlSize(.small)
        }
        .padding(14)
        .background(AppTheme.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isHovering ? AppTheme.Accent.primary.opacity(0.4) : AppTheme.Border.control, lineWidth: 0.5))
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Category Editor (slide-out panel; embeds PromptEditorView)

private struct CategoryEditorPanel: View {
    let target: CategoriesSettingsView.CategoryEditTarget
    @ObservedObject var store: RecorderConfigStore
    @EnvironmentObject private var enhancementService: AIEnhancementService
    let onDismiss: () -> Void

    @State private var name: String
    @State private var classifierDescription: String
    @State private var subfolderName: String
    @State private var customPromptId: UUID?
    @State private var showingPromptEditor = false

    private let existingId: UUID?
    private let isFallback: Bool

    init(target: CategoriesSettingsView.CategoryEditTarget, store: RecorderConfigStore, onDismiss: @escaping () -> Void) {
        self.target = target
        self.store = store
        self.onDismiss = onDismiss
        switch target {
        case .add:
            existingId = nil; isFallback = false
            _name = State(initialValue: "")
            _classifierDescription = State(initialValue: "")
            _subfolderName = State(initialValue: "")
            _customPromptId = State(initialValue: nil)
        case .edit(let c):
            existingId = c.id; isFallback = c.isFallback
            _name = State(initialValue: c.name)
            _classifierDescription = State(initialValue: c.classifierDescription)
            _subfolderName = State(initialValue: c.subfolderName)
            _customPromptId = State(initialValue: c.customPromptId)
        }
    }

    private var boundPrompt: CustomPrompt? {
        enhancementService.allPrompts.first { $0.id == customPromptId }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !subfolderName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        Group {
            if showingPromptEditor {
                PromptEditorView(
                    mode: boundPrompt.map { .edit($0) } ?? .add,
                    onDismiss: { showingPromptEditor = false },
                    onSave: { prompt in
                        if enhancementService.allPrompts.contains(where: { $0.id == prompt.id }) {
                            enhancementService.updatePrompt(prompt)
                        } else {
                            enhancementService.customPrompts.append(prompt)
                        }
                        customPromptId = prompt.id
                        showingPromptEditor = false
                    }
                )
            } else {
                editorForm
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var editorForm: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: target.id == "add" ? "新增類別" : "編輯類別", onClose: onDismiss)
            Form {
                Section("類別") {
                    TextField("名稱", text: $name)
                    TextField("分類描述（何時使用此類別 — 餵給分類器）", text: $classifierDescription, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("Vault 子資料夾") {
                    TextField("子資料夾名稱", text: $subfolderName)
                }
                Section("分析範本") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(boundPrompt?.title ?? "未綁定範本")
                                .foregroundStyle(boundPrompt == nil ? .secondary : .primary)
                            if boundPrompt == nil {
                                Text("未綁定時直接輸出原始逐字稿").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button(boundPrompt == nil ? "建立範本…" : "編輯範本…") { showingPromptEditor = true }
                    }
                    if boundPrompt != nil {
                        Button("解除綁定") { customPromptId = nil }
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("儲存", action: save).disabled(!canSave)
                    if existingId != nil && !isFallback {
                        Button("刪除此類別", role: .destructive, action: deleteCategory)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    private func save() {
        let category = RecorderCategory(
            id: existingId ?? UUID(),
            name: name,
            classifierDescription: classifierDescription,
            customPromptId: customPromptId,
            subfolderName: subfolderName,
            isFallback: isFallback)
        store.upsertCategory(category)
        onDismiss()
    }

    private func deleteCategory() {
        if let id = existingId { store.removeCategory(id) }
        onDismiss()
    }
}
