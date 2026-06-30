import Foundation
import SwiftData
import LLMkit
import os

/// Orchestrates the recorder-item pipeline AFTER raw transcription:
/// classify → route to category prompt → (long?) summarize → enhance → persist metadata → export.
/// Runs per item; all heavy work is async. Decoupled from the transcription engine.
@MainActor
final class RecorderPostProcessor {
    static let shared = RecorderPostProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() {}

    /// Confidence below this floor routes to the fallback category. Permissive default; calibrate later.
    private var confidenceFloor: Double {
        let stored = UserDefaults.standard.double(forKey: "recorderConfidenceFloor")
        return stored > 0 ? stored : 0.5
    }

    /// Resolve the analysis model: category override → store default → active Mode (baseConfig).
    /// Only honours a stored provider that is currently connected.
    private func resolvedAnalysisModel(
        categoryProvider: String?, categoryModel: String?,
        baseConfig: EnhancementRuntimeConfiguration, aiService: AIService
    ) -> (provider: AIProvider, modelName: String?) {
        let store = RecorderConfigStore.shared
        let providerName = categoryProvider ?? store.defaultAIProviderName
        let modelName = categoryModel ?? store.defaultAIModelName
        if let providerName, let p = AIProvider(rawValue: providerName),
           aiService.connectedProviders.contains(p) {
            return (p, modelName)
        }
        let fallback = baseConfig.provider ?? aiService.connectedProviders.first ?? .anthropic
        return (fallback, baseConfig.modelName)
    }

    /// One lightweight AI call → a ≤10-char content title for the export file name. nil on failure.
    private func generateShortTitle(
        from text: String, provider: AIProvider, modelName: String?, aiService: AIService
    ) async -> String? {
        let excerpt = String(text.prefix(2000))
        let system = "用十個字以內為內容下一個精簡標題。只輸出標題本身，不要任何標點、引號或說明。"
        guard let raw = try? await aiService.completeChat(
            provider: provider, modelName: modelName,
            messages: [ChatMessage.user(excerpt)], systemPrompt: system, timeout: 30) else { return nil }
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|「」『』“”‘’，。、！？.,!?")
        t = t.components(separatedBy: illegal).joined().trimmingCharacters(in: .whitespaces)
        if t.count > 10 { t = String(t.prefix(10)) }
        return t.isEmpty ? nil : t
    }

    func process(
        transcription: Transcription,
        rawText: String,
        device: RecorderDevice?,
        modelContext: ModelContext,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) async {
        let store = RecorderConfigStore.shared
        let categories = store.categories
        let baseConfig = ModeRuntimeResolver.currentEnhancementConfiguration(
            enhancementService: enhancementService, aiService: aiService)

        guard baseConfig.provider != nil else {
            logger.notice("No AI provider configured — leaving raw recorder transcript unclassified")
            return
        }

        // Classification runs before routing, so it uses the default model (or active Mode).
        let classifyModel = resolvedAnalysisModel(categoryProvider: nil, categoryModel: nil,
                                                  baseConfig: baseConfig, aiService: aiService)

        // 1. Classify
        let result = await TranscriptClassificationService.shared.classify(
            rawText, categories: categories, aiService: aiService,
            provider: classifyModel.provider, modelName: classifyModel.modelName)

        // 2. Route
        let decision = TemplateRouter.route(
            result: result, categories: categories,
            prompts: store.recorderPrompts, confidenceFloor: confidenceFloor)

        // Resolve the analysis model for this category: category override → default → active Mode.
        let model = resolvedAnalysisModel(categoryProvider: decision.category.aiProviderName,
                                          categoryModel: decision.category.aiModelName,
                                          baseConfig: baseConfig, aiService: aiService)

        // 3. (long?) summarize for the enhancement input
        let analysisInput = await LongTranscriptSummarizer.shared.condense(
            rawText, aiService: aiService, provider: model.provider, modelName: model.modelName)

        // 4. Enhance with the category's prompt (if any) using the resolved model
        var analysis = analysisInput
        if let prompt = decision.prompt {
            do {
                let (enhanced, _, _) = try await enhancementService.enhance(
                    analysisInput,
                    configuration: baseConfig.replacing(prompt: prompt, provider: model.provider, modelName: model.modelName))
                analysis = enhanced
                transcription.enhancedText = enhanced
            } catch {
                logger.error("Category enhancement failed: \(error, privacy: .public)")
            }
        }

        // 5. Persist classification metadata
        transcription.recorderCategoryId = decision.category.id
        transcription.recorderCategoryName = decision.category.name
        transcription.classificationConfidence = result.confidence
        try? modelContext.save()

        // 6. Export to the global vault (if a vault root is configured)
        if let bookmark = RecorderConfigStore.shared.vaultRootBookmark,
           let vaultRoot = VaultExportService.shared.resolveVaultRoot(bookmark) {
            let title = await generateShortTitle(from: analysis, provider: model.provider,
                                                 modelName: model.modelName, aiService: aiService)
            exportToVault(transcription: transcription, analysis: analysis, rawText: rawText,
                          decision: decision, deviceName: device?.displayName, title: title,
                          vaultRoot: vaultRoot, modelContext: modelContext)
        }

        // 7. Delete-after-import (gated on full success of import + transcription + export)
        if let device, let fp = transcription.importFingerprint {
            RecorderImportService.shared.finalizeImport(fingerprint: fp, device: device,
                                                        exported: transcription.exportedFilePath != nil)
        }

        NotificationManager.shared.showNotification(title: "完成：\(decision.category.name)", type: .success, duration: 3)
        NotificationCenter.default.post(name: .recorderImportCompleted, object: transcription)
    }

    /// Manual re-classification (AC-7): re-route/enhance/export against a user-chosen category,
    /// superseding any previously exported file.
    func reclassify(
        transcription: Transcription,
        to category: RecorderCategory,
        device: RecorderDevice?,
        modelContext: ModelContext,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) async {
        let baseConfig = ModeRuntimeResolver.currentEnhancementConfiguration(
            enhancementService: enhancementService, aiService: aiService)
        guard baseConfig.provider != nil else { return }
        let rawText = transcription.text
        let model = resolvedAnalysisModel(categoryProvider: category.aiProviderName,
                                          categoryModel: category.aiModelName,
                                          baseConfig: baseConfig, aiService: aiService)

        let analysisInput = await LongTranscriptSummarizer.shared.condense(
            rawText, aiService: aiService, provider: model.provider, modelName: model.modelName)
        let prompt = RecorderConfigStore.shared.recorderPrompt(byId: category.customPromptId)

        var analysis = analysisInput
        if let prompt {
            if let (enhanced, _, _) = try? await enhancementService.enhance(
                analysisInput,
                configuration: baseConfig.replacing(prompt: prompt, provider: model.provider, modelName: model.modelName)) {
                analysis = enhanced
                transcription.enhancedText = enhanced
            }
        }
        transcription.recorderCategoryId = category.id
        transcription.recorderCategoryName = category.name

        // Supersede the old exported file.
        if let old = transcription.exportedFilePath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: old))
            transcription.exportedFilePath = nil
        }
        let decision = RoutingDecision(category: category, prompt: prompt, usedFallback: category.isFallback)
        if let bookmark = RecorderConfigStore.shared.vaultRootBookmark,
           let vaultRoot = VaultExportService.shared.resolveVaultRoot(bookmark) {
            let title = await generateShortTitle(from: analysis, provider: model.provider,
                                                 modelName: model.modelName, aiService: aiService)
            exportToVault(transcription: transcription, analysis: analysis, rawText: rawText,
                          decision: decision, deviceName: device?.displayName, title: title,
                          vaultRoot: vaultRoot, modelContext: modelContext)
        }
        try? modelContext.save()
        NotificationCenter.default.post(name: .recorderImportCompleted, object: transcription)
    }

    private func exportToVault(
        transcription: Transcription, analysis: String, rawText: String,
        decision: RoutingDecision, deviceName: String?, title: String?, vaultRoot: URL,
        modelContext: ModelContext
    ) {
        let input = VaultExportService.ExportInput(
            analysis: analysis, rawTranscript: rawText,
            categoryName: decision.category.name, deviceName: deviceName,
            date: transcription.timestamp,
            transcriptionModel: transcription.transcriptionModelName,
            enhancementModel: transcription.aiEnhancementModelName,
            confidence: transcription.classificationConfidence)
        let markdown = VaultExportService.shared.buildMarkdown(input)
        let fileName = VaultExportService.shared.suggestedFileName(
            date: transcription.timestamp, categoryName: decision.category.name, title: title)
        do {
            let url = try VaultExportService.shared.export(
                markdown: markdown, fileName: fileName, vaultRoot: vaultRoot,
                subfolder: decision.category.subfolderName)
            transcription.exportedFilePath = url.path
            try? modelContext.save()
            logger.notice("Exported recorder note to vault: \(url.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Vault export failed: \(error, privacy: .public)")
        }
    }
}
