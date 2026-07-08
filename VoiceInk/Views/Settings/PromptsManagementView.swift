import SwiftUI

/// Dedicated page to manage the shared CustomPrompt library (the "範本") used by both voice-input
/// Modes and recorder Categories. Add / edit / delete prompts via the wide PromptEditorView sheet.
/// 每個範本可屬「語音輸入」「錄音輸入」或兩者;此頁列出全部並可依所屬類別篩選。
struct PromptsManagementView: View {
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @State private var editing: PromptEditTarget?
    @State private var scopeFilter: LibraryScopeFilter = .all

    /// 範本列表的分類篩選。
    enum LibraryScopeFilter: String, CaseIterable, Identifiable {
        case all, voice, recorder, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "全部"
            case .voice: return "語音輸入"
            case .recorder: return "錄音輸入"
            case .both: return "兩者都用"
            }
        }
        func matches(_ p: CustomPrompt) -> Bool {
            switch self {
            case .all: return true
            case .voice: return p.categories.contains(.voiceInput)
            case .recorder: return p.categories.contains(.recorderInput)
            case .both: return p.categories.contains(.voiceInput) && p.categories.contains(.recorderInput)
            }
        }
    }

    enum PromptEditTarget: Identifiable {
        case add
        case edit(CustomPrompt)
        var id: String { switch self { case .add: return "add"; case .edit(let p): return p.id.uuidString } }
        var mode: PromptEditorView.Mode { switch self { case .add: return .add; case .edit(let p): return .edit(p) } }
    }

    private var filteredPrompts: [CustomPrompt] {
        enhancementService.libraryPrompts.filter { scopeFilter.matches($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "共用範本",
                infoMessage: "共用範本是給 AI 的指令，把逐字稿整理成你要的格式。每個範本可勾選用於「語音輸入」（語音模式）或「錄音輸入」（錄音模式），兩者可同時勾。錄音模式頁的下拉選單只會列出勾了「錄音輸入」的範本。",
                infoURL: nil
            ) {
                AppIconButton(systemName: "plus.circle.fill", help: "新增範本") { editing = .add }
            }

            scopeFilterBar

            if filteredPrompts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filteredPrompts) { prompt in
                            PromptCard(prompt: prompt) { editing = .edit(prompt) }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $editing) { target in
            PromptEditorView(
                mode: target.mode,
                onDismiss: { editing = nil },
                onSave: { prompt in
                    if enhancementService.libraryPrompts.contains(where: { $0.id == prompt.id }) {
                        enhancementService.updatePrompt(prompt)
                    } else {
                        enhancementService.upsertPrompt(prompt)
                    }
                    editing = nil
                },
                onDelete: { prompt in
                    enhancementService.deletePrompt(prompt)
                    editing = nil
                }
            )
            .environmentObject(enhancementService)
            .frame(width: 820, height: 680)
        }
    }

    private var scopeFilterBar: some View {
        HStack(spacing: 10) {
            Picker("篩選", selection: $scopeFilter) {
                ForEach(LibraryScopeFilter.allCases) { f in Text(f.label).tag(f) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            Spacer()
            Text("\(filteredPrompts.count) 個範本")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.6))
            Text(scopeFilter == .all ? "尚無範本" : "此分類尚無範本").font(.system(size: 16, weight: .medium))
            Text("點右上「+」新增一個範本（給 AI 的指令），並勾選它要用於語音輸入或錄音輸入。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
    }
}

/// 範本所屬類別的小徽章列（語音輸入／錄音輸入）。
private struct TemplateCategoryBadges: View {
    let categories: [TemplateCategory]

    var body: some View {
        HStack(spacing: 5) {
            if categories.isEmpty {
                badge("未指派", color: .secondary)
            } else {
                ForEach(categories, id: \.self) { c in
                    badge(c.displayName, color: c == .recorderInput ? AppTheme.Accent.primary : Color.secondary)
                }
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct PromptCard: View {
    let prompt: CustomPrompt
    let onEdit: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 15)).foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(AppTheme.Accent.primary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(prompt.title).font(.system(size: 14, weight: .semibold))
                    TemplateCategoryBadges(categories: prompt.categories)
                }
                Text(prompt.promptText.replacingOccurrences(of: "\n", with: " "))
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
