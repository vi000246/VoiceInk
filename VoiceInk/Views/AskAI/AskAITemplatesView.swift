import SwiftUI
import SwiftData

/// Ask AI 範本（persona）管理頁：CRUD 分析角色。問答時可選一個 → 注入 system prompt 的 persona 段，
/// 引用規則段永遠保留。鏡射共用範本頁的卡片式 CRUD。
struct AskAITemplatesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AskAITemplate.createdAt) private var templates: [AskAITemplate]
    @State private var editing: AskAITemplate?
    @State private var showingAdd = false

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Ask AI 範本",
                infoMessage: "Ask AI 範本是分析「角色」（persona）。在 Ask AI 問答時可選一個，讓回答以該視角展開;引用規則（只依片段、標註來源 [n]、找不到就明說）一律固定保留，不會被覆蓋。",
                infoURL: nil
            ) {
                AppIconButton(systemName: "plus.circle.fill", help: "新增 Ask AI 範本") { showingAdd = true }
            }

            if templates.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(templates) { t in
                            AskAITemplateCard(template: t) { editing = t }
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingAdd) {
            AskAITemplateEditor(template: nil, onDismiss: { showingAdd = false })
        }
        .sheet(item: $editing) { t in
            AskAITemplateEditor(template: t, onDismiss: { editing = nil })
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.rectangle.stack")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.6))
            Text("尚無 Ask AI 範本").font(.system(size: 16, weight: .medium))
            Text("點右上「+」新增一個分析角色（例如「面試覆盤教練」）。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AskAITemplateCard: View {
    let template: AskAITemplate
    let onEdit: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.rectangle.stack.fill")
                .font(.system(size: 15)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(AppTheme.Sidebar.modes, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(template.title).font(.system(size: 14, weight: .semibold))
                Text(template.systemPrompt.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
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

/// 新增／編輯一個 Ask AI 範本。template == nil 為新增。
private struct AskAITemplateEditor: View {
    let template: AskAITemplate?
    let onDismiss: () -> Void
    @Environment(\.modelContext) private var modelContext
    @State private var title: String
    @State private var systemPrompt: String

    init(template: AskAITemplate?, onDismiss: @escaping () -> Void) {
        self.template = template
        self.onDismiss = onDismiss
        _title = State(initialValue: template?.title ?? "")
        _systemPrompt = State(initialValue: template?.systemPrompt ?? "")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: template == nil ? "新增 Ask AI 範本" : "編輯 Ask AI 範本", onClose: onDismiss)
            Form {
                Section("名稱") {
                    TextField("例如：面試覆盤教練", text: $title)
                }
                Section("角色指示（persona）") {
                    TextField("你是……，聚焦……", text: $systemPrompt, axis: .vertical)
                        .lineLimit(4...14)
                    Text("只描述分析角色／視角即可;不用寫引用格式，系統會自動附加固定的引用規則。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("儲存", action: save).disabled(!canSave)
                    if let template {
                        Button("刪除範本", role: .destructive) {
                            modelContext.delete(template)
                            try? modelContext.save()
                            onDismiss()
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: 520)
    }

    private func save() {
        if let template {
            template.title = title
            template.systemPrompt = systemPrompt
        } else {
            modelContext.insert(AskAITemplate(title: title, systemPrompt: systemPrompt))
        }
        try? modelContext.save()
        onDismiss()
    }
}
