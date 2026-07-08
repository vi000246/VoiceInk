import Foundation

struct TranscriptionRuntimeConfiguration {
    let mode: ModeConfig?
    let model: any TranscriptionModel
    let language: String
    let isRealtimeEnabled: Bool

    var metadata: (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else {
            return (nil, nil)
        }
        return (mode.name, mode.icon.value)
    }

    var requestContext: TranscriptionRequestContext {
        TranscriptionRequestContext(
            language: language,
            prompt: UserDefaults.standard.string(forKey: "TranscriptionPrompt"),
            noVerbatim: mode?.noVerbatim ?? false
        )
    }
}

struct TranscriptionFormattingConfiguration {
    let mode: ModeConfig?
    let isTextFormattingEnabled: Bool
}

struct EnhancementRuntimeConfiguration {
    let mode: ModeConfig?
    let isEnabled: Bool
    let prompt: CustomPrompt?
    let provider: AIProvider?
    let modelName: String?
    let useClipboardContext: Bool
    let useSelectedTextContext: Bool
    let useScreenCaptureContext: Bool

    func replacingPrompt(_ prompt: CustomPrompt) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: true,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }

    /// Override prompt + provider + model together (used by the recorder pipeline to apply a
    /// category's analysis-model choice).
    func replacing(prompt: CustomPrompt?, provider: AIProvider?, modelName: String?) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: true,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }
}

struct OutputRuntimeConfiguration {
    let mode: ModeConfig?
    let outputMode: ModeOutputMode
    let autoSendKey: AutoSendKey
    let customCommand: ModeCustomCommand?
    /// 「編輯後貼上」：`.paste` 交付前先過外部編輯器。以下三者從 Mode + 全域設定組出。
    let editBeforePaste: Bool
    let editCommand: String     // e.g. "mvim -f {file}"
    let editTarget: String      // "paste"（貼回原框）| "clipboard"（放剪貼簿）

    static let defaultEditCommand = "mvim -f {file}"
    static let editCommandKey = "editBeforePasteCommand"
    static let editTargetKey = "editBeforePasteTarget"
}

@MainActor
enum ModeRuntimeResolver {
    static func transcriptionConfiguration(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        let model = resolvedModel(
            named: mode?.selectedTranscriptionModelName,
            transcriptionModelManager: transcriptionModelManager
        )

        guard let model else { return nil }

        let language = TranscriptionLanguageSupport.validLanguageOrFallback(
            mode?.selectedLanguage,
            for: model,
            realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
        )

        return TranscriptionRuntimeConfiguration(
            mode: mode,
            model: model,
            language: language,
            isRealtimeEnabled: TranscriptionRealtimeSupport.isEnabled(for: model, modeValue: mode?.isRealtimeTranscriptionEnabled)
        )
    }

    static func transcriptionFormattingConfiguration(mode: ModeConfig? = nil) -> TranscriptionFormattingConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return TranscriptionFormattingConfiguration(
            mode: mode,
            isTextFormattingEnabled: mode?.isTextFormattingEnabled ?? UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled")
        )
    }

    static func currentEnhancementConfiguration(
        mode: ModeConfig? = nil,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        let prompt = resolvedPrompt(
            promptId: mode?.selectedPrompt,
            enhancementService: enhancementService
        )
        let provider = resolvedProvider(
            providerName: mode?.selectedAIProvider,
            aiService: aiService
        )
        let modelName = resolvedEnhancementModelName(
            provider: provider,
            configuredModelName: mode?.selectedAIModel,
            aiService: aiService
        )

        return EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: mode?.isAIEnhancementEnabled ?? false,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: mode?.useClipboardContext ?? false,
            useSelectedTextContext: mode?.useSelectedTextContext ?? true,
            useScreenCaptureContext: mode?.useScreenCapture ?? false
        )
    }

    static func outputConfiguration(mode: ModeConfig? = nil) -> OutputRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        let defaults = UserDefaults.standard
        let command = defaults.string(forKey: OutputRuntimeConfiguration.editCommandKey)
        let target = defaults.string(forKey: OutputRuntimeConfiguration.editTargetKey)
        return OutputRuntimeConfiguration(
            mode: mode,
            outputMode: mode?.outputMode ?? .paste,
            autoSendKey: mode?.autoSendKey ?? .none,
            customCommand: mode?.customCommand,
            editBeforePaste: mode?.editBeforePaste ?? false,
            editCommand: (command?.isEmpty == false) ? command! : OutputRuntimeConfiguration.defaultEditCommand,
            editTarget: (target?.isEmpty == false) ? target! : "paste"
        )
    }

    private static func resolvedModel(
        named modelName: String?,
        transcriptionModelManager: TranscriptionModelManager
    ) -> (any TranscriptionModel)? {
        if let modelName,
           let model = transcriptionModelManager.usableModels.first(where: { $0.name == modelName }) {
            return model
        }

        return transcriptionModelManager.usableModels.first
    }

    private static func resolvedPrompt(
        promptId: String?,
        enhancementService: AIEnhancementService
    ) -> CustomPrompt? {
        guard let promptId,
              let uuid = UUID(uuidString: promptId) else {
            return nil
        }

        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    private static func resolvedProvider(
        providerName: String?,
        aiService: AIService
    ) -> AIProvider? {
        if let providerName,
           let provider = AIProvider(rawValue: providerName),
           aiService.connectedProviders.contains(provider) {
            return provider
        }

        return aiService.connectedProviders.first
    }

    private static func resolvedEnhancementModelName(
        provider: AIProvider?,
        configuredModelName: String?,
        aiService: AIService
    ) -> String? {
        guard let provider else { return nil }

        if provider == .localCLI {
            return nil
        }

        let models = aiService.availableModels(for: provider)
        if let configuredModelName,
           !configuredModelName.isEmpty,
           (models.isEmpty || models.contains(configuredModelName)) {
            return configuredModelName
        }

        if let firstModel = models.first {
            return firstModel
        }

        return provider.defaultModel
    }
}
