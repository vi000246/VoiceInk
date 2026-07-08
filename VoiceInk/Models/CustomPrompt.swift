import Foundation
import SwiftUI

/// 範本可套用的輸入類別。一個範本可多屬（共用於語音模式與錄音模式）。
enum TemplateCategory: String, Codable, CaseIterable, Equatable {
    case voiceInput      // 語音輸入
    case recorderInput   // 錄音輸入

    var displayName: String {
        switch self {
        case .voiceInput: return String(localized: "語音輸入")
        case .recorderInput: return String(localized: "錄音輸入")
        }
    }
}

struct CustomPrompt: Identifiable, Codable, Equatable {
    let id: UUID
    let title: String
    let promptText: String
    let useSystemInstructions: Bool
    /// 所屬輸入類別（可多選）。空＝未分類（遷移時填入至少一類）。additive、向後相容。
    var categories: [TemplateCategory]

    init(
        id: UUID = UUID(),
        title: String,
        promptText: String,
        useSystemInstructions: Bool = true,
        categories: [TemplateCategory] = []
    ) {
        self.id = id
        self.title = title
        self.promptText = promptText
        self.useSystemInstructions = useSystemInstructions
        self.categories = categories
    }

    enum CodingKeys: String, CodingKey {
        case id, title, promptText, useSystemInstructions, categories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        promptText = try container.decode(String.self, forKey: .promptText)
        useSystemInstructions = try container.decodeIfPresent(Bool.self, forKey: .useSystemInstructions) ?? true
        categories = try container.decodeIfPresent([TemplateCategory].self, forKey: .categories) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(promptText, forKey: .promptText)
        try container.encode(useSystemInstructions, forKey: .useSystemInstructions)
        try container.encode(categories, forKey: .categories)
    }
    
    var finalPromptText: String {
        if useSystemInstructions {
            // Token-replace (not String(format:)) so a user-edited template with stray % is safe.
            return AIPrompts.enhancementSystemTemplate.replacingOccurrences(of: "%@", with: self.promptText)
        } else {
            return self.promptText
        }
    }
}

// MARK: - UI Extensions
extension CustomPrompt {
    func promptIcon(isSelected: Bool, onTap: @escaping () -> Void, onEdit: ((CustomPrompt) -> Void)? = nil, onDelete: ((CustomPrompt) -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 30)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? AppTheme.Accent.primary : AppTheme.Surface.control)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(AppTheme.Border.control, lineWidth: isSelected ? 0 : 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if let onEdit = onEdit {
                onEdit(self)
            }
        }
        .onTapGesture(count: 1) {
            onTap()
        }
        .contextMenu {
            if onEdit != nil || onDelete != nil {
                if let onEdit = onEdit {
                    Button {
                        onEdit(self)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                }
                
                if let onDelete = onDelete {
                    Button(role: .destructive) {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "Delete Prompt?")
                        alert.informativeText = String(format: String(localized: "Are you sure you want to delete '%@' prompt? This action cannot be undone."), self.title)
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: String(localized: "Delete"))
                        alert.addButton(withTitle: String(localized: "Cancel"))
                        
                        let response = alert.runModal()
                        if response == .alertFirstButtonReturn {
                            onDelete(self)
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }
    
    static func addNewButton(action: @escaping () -> Void) -> some View {
        Label("Add New", systemImage: "plus.circle.fill")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 30)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(AppTheme.Surface.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppTheme.Border.control, lineWidth: 0.5)
            )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}
