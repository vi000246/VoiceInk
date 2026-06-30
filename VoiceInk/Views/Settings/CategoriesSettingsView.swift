import SwiftUI

/// A concrete (provider, model) choice for the analysis-model pickers.
struct RecorderModelChoice: Hashable {
    let provider: String
    let model: String
    var label: String { "\(provider) · \(model)" }
}

/// Flat list of selectable analysis models across the user's connected providers.
@MainActor func recorderModelChoices(_ aiService: AIService) -> [RecorderModelChoice] {
    var out: [RecorderModelChoice] = []
    for p in aiService.connectedProviders {
        let models = aiService.availableModels(for: p)
        if models.isEmpty {
            out.append(RecorderModelChoice(provider: p.rawValue, model: p.defaultModel))
        } else {
            for m in models { out.append(RecorderModelChoice(provider: p.rawValue, model: m)) }
        }
    }
    return out
}

/// Categories page — a default-analysis-model card + category cards + a slide-out editor that
/// opens the reusable `PromptEditorView` (in a wide sheet) for the bound analysis prompt.
struct CategoriesSettingsView: View {
    @StateObject private var store = RecorderConfigStore.shared
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
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
                AppIconButton(systemName: "square.and.arrow.down.on.square", help: "載入預設類別與範本") {
                    store.seedDefaultTemplates(using: enhancementService)
                }
                AppIconButton(systemName: "plus.circle.fill", help: "新增類別") { editTarget = .add }
            }

            ScrollView {
                VStack(spacing: 12) {
                    DefaultModelCard(store: store, aiService: aiService)
                    ForEach(store.categories) { category in
                        RecorderCategoryCard(
                            category: category,
                            promptTitle: enhancementService.allPrompts.first { $0.id == category.customPromptId }?.title,
                            modelLabel: modelLabel(category)
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

    private func modelLabel(_ c: RecorderCategory) -> String? {
        guard let p = c.aiProviderName, let m = c.aiModelName else { return nil }
        return "\(p) · \(m)"
    }
}

// MARK: - Default Analysis Model Card

private struct DefaultModelCard: View {
    @ObservedObject var store: RecorderConfigStore
    let aiService: AIService

    private var selection: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.defaultAIProviderName, let m = store.defaultAIModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setDefaultModel(provider: $0?.provider, model: $0?.model) })
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 18)).foregroundStyle(AppTheme.Accent.primary)
                .frame(width: 36, height: 36)
                .background(AppTheme.Accent.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("預設分析模型").font(.system(size: 14, weight: .semibold))
                Text("分類與套範本分析會用這個模型；個別類別可在下方各自覆寫。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: selection) {
                Text("跟隨目前 Mode").tag(RecorderModelChoice?.none)
                ForEach(recorderModelChoices(aiService), id: \.self) { c in
                    Text(c.label).tag(RecorderModelChoice?.some(c))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
        }
        .padding(14)
        .background(AppTheme.Surface.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.Border.control, lineWidth: 0.5))
    }
}

// MARK: - Category Card

private struct RecorderCategoryCard: View {
    let category: RecorderCategory
    let promptTitle: String?
    let modelLabel: String?
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
                Text("模型：\(modelLabel ?? "預設")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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

// MARK: - Category Editor (slide-out panel; prompt editor in a wide sheet)

private struct CategoryEditorPanel: View {
    let target: CategoriesSettingsView.CategoryEditTarget
    @ObservedObject var store: RecorderConfigStore
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
    let onDismiss: () -> Void

    @State private var name: String
    @State private var classifierDescription: String
    @State private var subfolderName: String
    @State private var customPromptId: UUID?
    @State private var aiProviderName: String?
    @State private var aiModelName: String?
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
            _aiProviderName = State(initialValue: nil)
            _aiModelName = State(initialValue: nil)
        case .edit(let c):
            existingId = c.id; isFallback = c.isFallback
            _name = State(initialValue: c.name)
            _classifierDescription = State(initialValue: c.classifierDescription)
            _subfolderName = State(initialValue: c.subfolderName)
            _customPromptId = State(initialValue: c.customPromptId)
            _aiProviderName = State(initialValue: c.aiProviderName)
            _aiModelName = State(initialValue: c.aiModelName)
        }
    }

    private var boundPrompt: CustomPrompt? {
        enhancementService.allPrompts.first { $0.id == customPromptId }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !subfolderName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var modelSelection: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = aiProviderName, let m = aiModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { aiProviderName = $0?.provider; aiModelName = $0?.model })
    }

    var body: some View {
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
                Section("分析模型") {
                    Picker("模型", selection: modelSelection) {
                        Text("預設（用上方全域預設）").tag(RecorderModelChoice?.none)
                        ForEach(recorderModelChoices(aiService), id: \.self) { c in
                            Text(c.label).tag(RecorderModelChoice?.some(c))
                        }
                    }
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
                        Button("刪除範本", role: .destructive) {
                            if let p = boundPrompt { enhancementService.deletePrompt(p) }
                            customPromptId = nil
                        }
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
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showingPromptEditor) {
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
            .environmentObject(enhancementService)
            .frame(width: 820, height: 680)
        }
    }

    private func save() {
        let category = RecorderCategory(
            id: existingId ?? UUID(),
            name: name,
            classifierDescription: classifierDescription,
            customPromptId: customPromptId,
            subfolderName: subfolderName,
            isFallback: isFallback,
            aiProviderName: aiProviderName,
            aiModelName: aiModelName)
        store.upsertCategory(category)
        onDismiss()
    }

    private func deleteCategory() {
        if let id = existingId { store.removeCategory(id) }
        onDismiss()
    }
}
