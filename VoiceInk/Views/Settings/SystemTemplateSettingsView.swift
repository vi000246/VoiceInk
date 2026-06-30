import SwiftUI

/// Edit the global system template that wraps voice prompts (those with "使用系統模板" on).
/// `%@` marks where a prompt's instructions are inserted. Recorder prompts never use this.
struct SystemTemplateSettingsView: View {
    @State private var text: String = AIPrompts.enhancementSystemTemplate
    @State private var savedFlash = false

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "System Template",
                infoMessage: "語音範本若開啟「使用系統模板」，提示詞會被包進這份模板。`%@` 是你的提示詞插入的位置。錄音筆範本不使用此模板。",
                infoURL: nil
            ) {
                Button("重設為預設") {
                    AIPrompts.setEnhancementSystemTemplate(nil)
                    text = AIPrompts.defaultEnhancementSystemTemplate
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("保留 `%@` —— 它會被替換成各範本的提示詞內容。", systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(AppCardBackground(cornerRadius: 8))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                HStack {
                    if !text.contains("%@") {
                        Label("缺少 %@,範本內容將不會被插入。", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.Status.error)
                    }
                    Spacer()
                    if savedFlash {
                        Label("已儲存", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(AppTheme.Status.success)
                    }
                    Button("儲存") {
                        AIPrompts.setEnhancementSystemTemplate(text)
                        withAnimation { savedFlash = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation { savedFlash = false } }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
