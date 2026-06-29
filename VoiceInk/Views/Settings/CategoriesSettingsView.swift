import SwiftUI

/// Minimal Categories settings page (FR-13): each category binds a classifier description,
/// an existing CustomPrompt, and a vault sub-folder. The fallback category is undeletable.
struct CategoriesSettingsView: View {
    @StateObject private var store = RecorderConfigStore.shared
    @EnvironmentObject private var enhancementService: AIEnhancementService

    var body: some View {
        Form {
            Section {
                Text("錄音匯入後會用一次輕量 AI 呼叫把逐字稿分類到下列其中一個類別，再套用該類別綁定的提示詞做分析，並輸出到 Vault 對應子資料夾。「通用」為無法分類時的預設類別，不可刪除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(store.categories) { category in
                Section(header: HStack {
                    Text(category.name.isEmpty ? "未命名類別" : category.name)
                    if category.isFallback {
                        Text("預設").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(AppTheme.Surface.control, in: Capsule())
                    }
                }) {
                    TextField("名稱", text: binding(category, \.name))
                    TextField("分類描述（何時使用此類別）", text: binding(category, \.classifierDescription), axis: .vertical)
                        .lineLimit(2...4)
                    TextField("Vault 子資料夾", text: binding(category, \.subfolderName))
                    Picker("分析提示詞", selection: promptBinding(category)) {
                        Text("無（輸出原始逐字稿）").tag(UUID?.none)
                        ForEach(enhancementService.allPrompts) { prompt in
                            Text(prompt.title).tag(UUID?.some(prompt.id))
                        }
                    }
                    if !category.isFallback {
                        Button(role: .destructive) { store.removeCategory(category.id) } label: {
                            Label("刪除類別", systemImage: "trash")
                        }
                    }
                }
            }
            Section {
                Button {
                    store.upsertCategory(RecorderCategory(name: "新類別", subfolderName: "新類別"))
                } label: {
                    Label("新增類別", systemImage: "plus.circle.fill")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ category: RecorderCategory, _ keyPath: WritableKeyPath<RecorderCategory, String>) -> Binding<String> {
        Binding(
            get: { store.category(byId: category.id)?[keyPath: keyPath] ?? category[keyPath: keyPath] },
            set: { var c = category; c[keyPath: keyPath] = $0; store.upsertCategory(c) }
        )
    }

    private func promptBinding(_ category: RecorderCategory) -> Binding<UUID?> {
        Binding(
            get: { store.category(byId: category.id)?.customPromptId },
            set: { var c = category; c.customPromptId = $0; store.upsertCategory(c) }
        )
    }
}
