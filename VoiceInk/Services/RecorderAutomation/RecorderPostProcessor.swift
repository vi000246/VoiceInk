import Foundation
import SwiftData
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

        guard let provider = baseConfig.provider else {
            logger.notice("No AI provider configured — leaving raw recorder transcript unclassified")
            return
        }

        // 1. Classify
        let result = await TranscriptClassificationService.shared.classify(
            rawText, categories: categories, aiService: aiService,
            provider: provider, modelName: baseConfig.modelName)

        // 2. Route
        let decision = TemplateRouter.route(
            result: result, categories: categories,
            prompts: enhancementService.allPrompts, confidenceFloor: confidenceFloor)

        // 3. (long?) summarize for the enhancement input
        let analysisInput = await LongTranscriptSummarizer.shared.condense(
            rawText, aiService: aiService, provider: provider, modelName: baseConfig.modelName)

        // 4. Enhance with the category's prompt (if any)
        var analysis = analysisInput
        if let prompt = decision.prompt {
            do {
                let (enhanced, _, _) = try await enhancementService.enhance(
                    analysisInput, configuration: baseConfig.replacingPrompt(prompt))
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
            exportToVault(transcription: transcription, analysis: analysis, rawText: rawText,
                          decision: decision, deviceName: device?.displayName, vaultRoot: vaultRoot,
                          modelContext: modelContext)
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
        guard let provider = baseConfig.provider else { return }
        let rawText = transcription.text

        let analysisInput = await LongTranscriptSummarizer.shared.condense(
            rawText, aiService: aiService, provider: provider, modelName: baseConfig.modelName)
        let prompt = enhancementService.allPrompts.first { $0.id == category.customPromptId }

        var analysis = analysisInput
        if let prompt {
            if let (enhanced, _, _) = try? await enhancementService.enhance(
                analysisInput, configuration: baseConfig.replacingPrompt(prompt)) {
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
            exportToVault(transcription: transcription, analysis: analysis, rawText: rawText,
                          decision: decision, deviceName: device?.displayName, vaultRoot: vaultRoot,
                          modelContext: modelContext)
        }
        try? modelContext.save()
        NotificationCenter.default.post(name: .recorderImportCompleted, object: transcription)
    }

    private func exportToVault(
        transcription: Transcription, analysis: String, rawText: String,
        decision: RoutingDecision, deviceName: String?, vaultRoot: URL,
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
            date: transcription.timestamp, categoryName: decision.category.name, deviceName: deviceName)
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
