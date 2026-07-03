import SwiftUI
import AppKit
import MarkdownUI

struct MarkdownContentView: View {
    let text: String
    var fontSize: CGFloat
    var foregroundColor: Color
    var alignment: Alignment
    /// When true, fenced code blocks get a dedicated copy button (and stay selectable).
    /// Off by default so transcript/history views keep MarkdownUI's plain code-block look.
    var copyableCodeBlocks: Bool

    init(
        _ text: String,
        fontSize: CGFloat,
        foregroundColor: Color,
        alignment: Alignment = .leading,
        copyableCodeBlocks: Bool = false
    ) {
        self.text = text
        self.fontSize = fontSize
        self.foregroundColor = foregroundColor
        self.alignment = alignment
        self.copyableCodeBlocks = copyableCodeBlocks
    }

    var body: some View {
        let markdown = Markdown(text)
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontSize(fontSize)
                ForegroundColor(foregroundColor)
            }

        Group {
            if copyableCodeBlocks {
                markdown.markdownBlockStyle(\.codeBlock) { configuration in
                    CopyableCodeBlockView(configuration: configuration, fontSize: fontSize)
                }
            } else {
                markdown
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

/// A fenced code block rendered with the standard monospaced look plus a copy button in the
/// top-trailing corner, so users can grab example snippets (e.g. the Template Guide prompts)
/// without fighting text selection inside a scrollable block.
private struct CopyableCodeBlockView: View {
    let configuration: CodeBlockConfiguration
    let fontSize: CGFloat
    @State private var didCopy = false

    var body: some View {
        configuration.label
            .fixedSize(horizontal: false, vertical: true)
            .markdownTextStyle {
                FontFamilyVariant(.monospaced)
                FontSize(fontSize * 0.95)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                Button(action: copy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(didCopy ? Color.green : Color.secondary)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(String(localized: "Copy"))
                .padding(6)
            }
            .padding(.vertical, 4)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.content, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            didCopy = false
        }
    }
}
