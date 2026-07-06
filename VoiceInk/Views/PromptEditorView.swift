import SwiftUI

struct PromptEditorView: View {
    enum Mode {
        case add
        case edit(CustomPrompt)
        
        static func == (lhs: Mode, rhs: Mode) -> Bool {
            switch (lhs, rhs) {
            case (.add, .add):
                return true
            case let (.edit(prompt1), .edit(prompt2)):
                return prompt1.id == prompt2.id
            default:
                return false
            }
        }
    }
    
    let mode: Mode
    /// Show the "Use System Template" toggle (and honour a prompt's stored value when editing).
    var allowsSystemTemplateToggle: Bool = true
    /// Initial toggle state for NEW prompts. Voice prompts default on; recorder analysis prompts
    /// default off (raw), but the toggle still lets the user opt in.
    var defaultUseSystemTemplate: Bool = true
    /// Show the voice starter-template menu (add mode). Hidden for recorder analysis prompts.
    var showsStarterTemplateMenu: Bool = true
    /// Overrides the save button label. Voice prompts keep the default "Create/Save & Select";
    /// recorder templates pass a plain "存檔" since there is no separate "select" step for them.
    var saveButtonTitleOverride: LocalizedStringKey? = nil
    /// When false, the title is optional — saving is allowed with an empty name (auto-derived from
    /// the prompt) so the recorder template editor isn't blocked by the easily-missed name field.
    var requiresTitle: Bool = true
    /// When true (voice prompts), saving persists into `AIEnhancementService.customPrompts`.
    /// Recorder templates pass false: the editor only builds the prompt and hands it to `onSave`,
    /// so recorder prompts never leak into the voice library.
    var persistsToVoiceLibrary: Bool = true
    @EnvironmentObject private var enhancementService: AIEnhancementService
    let onDismiss: () -> Void
    let onSave: (CustomPrompt) -> Void
    let onDelete: ((CustomPrompt) -> Void)?
    @State private var title: String
    @State private var promptText: String
    @State private var useSystemInstructions: Bool
    @State private var showDeleteConfirmation = false
    @State private var showDiscardConfirmation = false

    private var saveButtonTitle: LocalizedStringKey {
        if let saveButtonTitleOverride { return saveButtonTitleOverride }
        return mode == .add ? "Create & Select" : "Save & Select"
    }

    private var titlePlaceholder: LocalizedStringKey {
        requiresTitle ? "Prompt name" : "Prompt name (optional)"
    }

    /// The title to persist: the typed name, or — when a name isn't required and was left blank —
    /// the prompt's first non-empty line (capped), falling back to a generic label.
    private func resolvedTitle() -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = promptText
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return firstLine.isEmpty ? String(localized: "Untitled Template") : String(firstLine.prefix(20))
    }

    private var editingPrompt: CustomPrompt? {
        if case .edit(let prompt) = mode {
            return prompt
        }
        return nil
    }

    private var canDeletePrompt: Bool {
        editingPrompt != nil && onDelete != nil
    }

    private var isSaveDisabled: Bool {
        let promptEmpty = promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if requiresTitle {
            return promptEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return promptEmpty
    }
    
    init(
        mode: Mode,
        allowsSystemTemplateToggle: Bool = true,
        defaultUseSystemTemplate: Bool = true,
        showsStarterTemplateMenu: Bool = true,
        saveButtonTitle: LocalizedStringKey? = nil,
        requiresTitle: Bool = true,
        persistsToVoiceLibrary: Bool = true,
        onDismiss: @escaping () -> Void,
        onSave: @escaping (CustomPrompt) -> Void,
        onDelete: ((CustomPrompt) -> Void)? = nil
    ) {
        self.mode = mode
        self.allowsSystemTemplateToggle = allowsSystemTemplateToggle
        self.defaultUseSystemTemplate = defaultUseSystemTemplate
        self.showsStarterTemplateMenu = showsStarterTemplateMenu
        self.saveButtonTitleOverride = saveButtonTitle
        self.requiresTitle = requiresTitle
        self.persistsToVoiceLibrary = persistsToVoiceLibrary
        self.onDismiss = onDismiss
        self.onSave = onSave
        self.onDelete = onDelete
        switch mode {
        case .add:
            _title = State(initialValue: "")
            _promptText = State(initialValue: "")
            _useSystemInstructions = State(initialValue: defaultUseSystemTemplate)
        case .edit(let prompt):
            _title = State(initialValue: prompt.title)
            _promptText = State(initialValue: prompt.promptText)
            _useSystemInstructions = State(initialValue: allowsSystemTemplateToggle ? prompt.useSystemInstructions : false)
        }
    }
    
    private func dismissPanel() {
        onDismiss()
    }

    /// Has the user entered/changed anything that would be lost on close?
    private var isDirty: Bool {
        switch mode {
        case .add:
            return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .edit(let prompt):
            let originalUsesSystem = allowsSystemTemplateToggle ? prompt.useSystemInstructions : false
            return title != prompt.title
                || promptText != prompt.promptText
                || useSystemInstructions != originalUsesSystem
        }
    }

    /// Close request from Back / Cancel / Escape — confirm first if there are unsaved changes so a
    /// half-written template isn't lost. Saving uses `dismissPanel()` directly and never prompts.
    private func attemptDismiss() {
        if isDirty { showDiscardConfirmation = true } else { onDismiss() }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if case .add = mode, showsStarterTemplateMenu {
                        templateMenu
                    }

                    instructionsEditor
                    if allowsSystemTemplateToggle {
                        systemTemplateToggle
                    }
                }
                .padding(20)
            }

            footer
        }
        .confirmationDialog(
            "Delete Prompt?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                deletePrompt()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(String(format: String(localized: "Are you sure you want to delete '%@'? This action cannot be undone."), title))
        }
        .confirmationDialog(
            "尚未儲存，確定要離開嗎？",
            isPresented: $showDiscardConfirmation,
            titleVisibility: .visible
        ) {
            Button("捨棄變更", role: .destructive) { onDismiss() }
            Button("繼續編輯", role: .cancel) { }
        } message: {
            Text("你對這個範本做的變更尚未儲存，離開後會遺失。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                attemptDismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 28, height: 28)
                    .background(AppTheme.Surface.card)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Back")

            TextField(titlePlaceholder, text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(Divider().opacity(0.5), alignment: .bottom)
    }

    private var systemTemplateToggle: some View {
        HStack(spacing: 12) {
            Toggle(isOn: $useSystemInstructions) {
                HStack(spacing: 4) {
                    Text("Use System Template")
                    InfoTip("If enabled, your instructions are combined with a general-purpose template to improve transcription quality.\n\nDisable for full control over the AI's system prompt (for advanced users).")
                }
            }
            .toggleStyle(.switch)

            Spacer(minLength: 12)
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(PromptTemplates.all) { template in
                Button {
                    title = template.title
                    promptText = template.promptText
                    useSystemInstructions = template.useSystemInstructions
                } label: {
                    Text(template.title)
                }
            }
        } label: {
            Label("Template", systemImage: "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .help("Start with a template")
    }

    private var instructionsEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $promptText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 440)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(AppCardBackground(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if promptText.isEmpty {
                Text("Write prompt instructions")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
            }
        }
    }

    private var footer: some View {
        HStack {
            if canDeletePrompt {
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Text("Delete")
                        .frame(minWidth: 90)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.Status.errorStrong)
            } else {
                Button("Cancel") {
                    attemptDismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                if let savedPrompt = save() {
                    onSave(savedPrompt)
                }
                dismissPanel()
            } label: {
                Text(saveButtonTitle)
                    .frame(minWidth: 108)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaveDisabled)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Save this prompt and select it.")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .overlay(Divider().opacity(0.5), alignment: .top)
    }

    private func deletePrompt() {
        guard let prompt = editingPrompt, canDeletePrompt else { return }
        onDelete?(prompt)
        dismissPanel()
    }

    private func save() -> CustomPrompt? {
        let finalTitle = resolvedTitle()
        switch mode {
        case .add:
            guard persistsToVoiceLibrary else {
                return CustomPrompt(
                    title: finalTitle,
                    promptText: promptText,
                    useSystemInstructions: useSystemInstructions
                )
            }
            return enhancementService.addPrompt(
                title: finalTitle,
                promptText: promptText,
                useSystemInstructions: useSystemInstructions
            )
        case .edit(let prompt):
            let updatedPrompt = CustomPrompt(
                id: prompt.id,
                title: finalTitle,
                promptText: promptText,
                useSystemInstructions: useSystemInstructions
            )
            if persistsToVoiceLibrary {
                enhancementService.updatePrompt(updatedPrompt)
            }
            return updatedPrompt
        }
    }
}
