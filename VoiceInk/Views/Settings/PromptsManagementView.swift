import SwiftUI

/// Dedicated page to manage the shared CustomPrompt library (the "範本") used by both voice-input
/// Modes and recorder Categories. Add / edit / delete prompts via the wide PromptEditorView sheet.
struct PromptsManagementView: View {
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @State private var editing: PromptEditTarget?

    enum PromptEditTarget: Identifiable {
        case add
        case edit(CustomPrompt)
        var id: String { switch self { case .add: return "add"; case .edit(let p): return p.id.uuidString } }
        var mode: PromptEditorView.Mode { switch self { case .add: return .add; case .edit(let p): return .edit(p) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Prompts",
                infoMessage: "範本是給 AI 的指令，用來把語音逐字稿整理成你要的格式。這份清單由語音輸入的 Modes 與錄音筆的 Categories 共用。",
                infoURL: nil
            ) {
                AppIconButton(systemName: "plus.circle.fill", help: "新增範本") { editing = .add }
            }

            if enhancementService.allPrompts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(enhancementService.allPrompts) { prompt in
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
                    if enhancementService.allPrompts.contains(where: { $0.id == prompt.id }) {
                        enhancementService.updatePrompt(prompt)
                    } else {
                        enhancementService.customPrompts.append(prompt)
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

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.6))
            Text("尚無範本").font(.system(size: 16, weight: .medium))
            Text("點右上「+」新增一個範本（給 AI 的指令）。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            VStack(alignment: .leading, spacing: 3) {
                Text(prompt.title).font(.system(size: 14, weight: .semibold))
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
