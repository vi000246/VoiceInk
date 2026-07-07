import Foundation
import SwiftData
import LLMkit
import os

/// Orchestrates the recorder-item pipeline AFTER raw transcription:
/// classify → route to category prompt → (long?) summarize → enhance → persist metadata → export.
/// Runs per item; all heavy work is async. Decoupled from the transcription engine.
@MainActor
final class RecorderPostProcessor: ObservableObject {
    static let shared = RecorderPostProcessor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() {}

    /// Transcriptions whose post-processing (diarization + classification + optional export) is still
    /// running. The raw transcript is already visible in Recording Management by then, so the UI
    /// watches this to badge those records "處理中" until their category + speaker labels land.
    @Published private(set) var processingIds: Set<UUID> = []

    /// Confidence below this floor routes to the fallback category. Permissive default; calibrate later.
    private var confidenceFloor: Double {
        let stored = UserDefaults.standard.double(forKey: "recorderConfidenceFloor")
        return stored > 0 ? stored : 0.5
    }

    /// Resolve the analysis model: category override → Recorder Mode default → first connected
    /// provider (auto). Fully independent of the voice Modes — the recorder never follows the
    /// active Mode's AI model. Only honours a stored provider that is currently connected.
    private func resolvedAnalysisModel(
        categoryProvider: String?, categoryModel: String?, aiService: AIService
    ) -> (provider: AIProvider, modelName: String?) {
        let store = RecorderConfigStore.shared
        let providerName = categoryProvider ?? store.defaultAIProviderName
        let modelName = categoryModel ?? store.defaultAIModelName
        if let providerName, let p = AIProvider(rawValue: providerName),
           aiService.connectedProviders.contains(p) {
            return (p, modelName)
        }
        // Auto: first connected provider, its default model (nil → provider.defaultModel downstream).
        let fallback = aiService.connectedProviders.first ?? .anthropic
        return (fallback, nil)
    }

    /// Classifier model: dedicated classifier override (e.g. local Ollama) → default analysis model.
    private func resolvedClassifierModel(aiService: AIService) -> (provider: AIProvider, modelName: String?) {
        let store = RecorderConfigStore.shared
        if let name = store.recorderClassifierProviderName, let p = AIProvider(rawValue: name),
           aiService.connectedProviders.contains(p) {
            return (p, store.recorderClassifierModelName)
        }
        return resolvedAnalysisModel(categoryProvider: nil, categoryModel: nil, aiService: aiService)
    }

    /// A recorder-owned enhancement configuration — no voice-Mode context (clipboard/selection/
    /// screen capture), no active Mode. Runs a category's analysis prompt with the recorder model.
    private func recorderEnhancementConfig(
        prompt: CustomPrompt?, model: (provider: AIProvider, modelName: String?)
    ) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: nil, isEnabled: true, prompt: prompt,
            provider: model.provider, modelName: model.modelName,
            useClipboardContext: false, useSelectedTextContext: false, useScreenCaptureContext: false)
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

    /// Mount-path entry: classify (suggest category) — or, when `fixedCategory` is set (meeting
    /// captures with a fixed 分類), assign it directly without running the classifier. If auto-export
    /// is on, also apply the matched template + export; otherwise stop and leave it for manual
    /// handling in Recording Management.
    func process(
        transcription: Transcription,
        rawText: String,
        device: RecorderDevice?,
        fixedCategory: RecorderCategory? = nil,
        modelContext: ModelContext,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) async {
        let store = RecorderConfigStore.shared
        processingIds.insert(transcription.id)                 // badge the record "處理中" in the UI
        defer { processingIds.remove(transcription.id) }

        // Speaker diarization (best-effort, before classification). Native-capable models (ElevenLabs)
        // use their word-accurate API; every other model falls back to the on-device FluidAudio
        // diarizer. Any failure degrades silently to the plain transcript.
        if store.recorderDiarizationEnabled {
            let audioURLs = diarizationAudioURLs(for: transcription)
            if !audioURLs.isEmpty,
               let outcome = await DiarizationCoordinator.diarize(
                audioURLs: audioURLs,
                transcriptionModelName: transcription.transcriptionModelName,
                language: store.recorderLanguage,
                expectedSpeakers: store.recorderExpectedSpeakerCount,
                detectSpeakerRoles: store.recorderDetectSpeakerRoles) {
                transcription.speakerSegments = outcome.segments   // also sets speakerLabeled = true
                transcription.speakerSegmentsAreNative = outcome.isNative
                try? modelContext.save()
            }
        }

        // Traditional Chinese: convert the transcript AND the speaker segments once, before
        // classification/analysis/export, so every downstream consumer sees 繁中 consistently.
        var rawText = rawText
        if store.recorderConvertToTraditional {
            transcription.text = TraditionalChineseConverter.toTraditional(transcription.text)
            let segs = transcription.speakerSegments
            if !segs.isEmpty {
                transcription.speakerSegments = segs.map {
                    var s = $0; s.text = TraditionalChineseConverter.toTraditional(s.text); return s
                }
            }
            rawText = transcription.text
            try? modelContext.save()
        }

        if let fixed = fixedCategory {
            await assignCategory(transcription: transcription, category: fixed, rawText: rawText,
                                 modelContext: modelContext, aiService: aiService)
        } else {
            await suggestCategory(transcription: transcription, rawText: rawText, modelContext: modelContext,
                                  enhancementService: enhancementService, aiService: aiService)
        }

        if store.recorderAutoExportEnabled {
            let category = transcription.recorderCategoryId.flatMap { store.category(byId: $0) } ?? store.fallbackCategory
            await applyTemplate(transcription: transcription, category: category, modelContext: modelContext,
                                enhancementService: enhancementService, aiService: aiService)
            await export(transcription: transcription, category: category, modelContext: modelContext,
                         enhancementService: enhancementService, aiService: aiService)
            if let device, let fp = transcription.importFingerprint {
                RecorderImportService.shared.finalizeImport(fingerprint: fp, device: device,
                                                            exported: transcription.exportedFilePath != nil)
            }
            NotificationManager.shared.showNotification(title: "完成：\(category.name)", type: .success, duration: 3)
        } else {
            NotificationManager.shared.showNotification(
                title: "已轉錄（待處理）：\(transcription.recorderCategoryName ?? "")", type: .info, duration: 3)
        }
        NotificationCenter.default.post(name: .recorderImportCompleted, object: transcription)
    }

    /// Audio to diarize. A long recording transcribed by a cloud model is split into <25MB WAV
    /// chunks; the plain transcript merges them all, so diarization must see every chunk — otherwise
    /// it stops at the first (~10 min) chunk and labels only part of the transcript. Prefer the
    /// ordered chunk list; fall back to the single stored audio file for non-chunked recordings.
    /// `audioFileURL` is an absoluteString (file://…); `audioChunkURLs` are filesystem paths.
    private func diarizationAudioURLs(for transcription: Transcription) -> [URL] {
        let chunks = transcription.audioChunkURLs
        if !chunks.isEmpty { return chunks }
        guard let path = transcription.audioFileURL else { return [] }
        if let url = URL(string: path), url.isFileURL { return [url] }
        if path.hasPrefix("/") { return [URL(fileURLWithPath: path)] }   // legacy plain-path values
        return []
    }

    /// Classify the raw transcript and set the SUGGESTED category metadata. No enhancement, no export.
    func suggestCategory(
        transcription: Transcription, rawText: String, modelContext: ModelContext,
        enhancementService: AIEnhancementService, aiService: AIService
    ) async {
        let store = RecorderConfigStore.shared
        guard !aiService.connectedProviders.isEmpty else {
            logger.notice("No AI provider connected — leaving raw recorder transcript unclassified")
            return
        }
        let classifyModel = resolvedClassifierModel(aiService: aiService)
        let result = await TranscriptClassificationService.shared.classify(
            rawText, categories: store.categories, aiService: aiService,
            provider: classifyModel.provider, modelName: classifyModel.modelName)
        let decision = TemplateRouter.route(
            result: result, categories: store.categories,
            prompts: store.recorderPrompts, confidenceFloor: confidenceFloor)
        transcription.recorderCategoryId = decision.category.id
        transcription.recorderCategoryName = decision.category.name
        transcription.classificationConfidence = result.confidence
        // The recording time lives in the device filename (e.g. 260701_1258.mp3), not the import
        // timestamp — recover it from the ledger so the title carries the real recording time.
        let recordingTime = transcription.importFingerprint
            .flatMap { ImportLedger.shared.fileName(forFingerprint: $0, in: modelContext) }
            .flatMap { RecorderRecordingTime.parse(fromFileName: $0) }
            ?? transcription.timestamp
        transcription.recorderTitle = await makeRecorderTitle(
            from: rawText, model: classifyModel, aiService: aiService, timestamp: recordingTime)
        try? modelContext.save()
    }

    /// 固定分類：設定分類欄位＋產生標題，完全不觸發分類器。
    private func assignCategory(
        transcription: Transcription, category: RecorderCategory, rawText: String,
        modelContext: ModelContext, aiService: AIService
    ) async {
        transcription.recorderCategoryId = category.id
        transcription.recorderCategoryName = category.name
        transcription.classificationConfidence = nil
        // Same recording-time recovery as suggestCategory: the source filename (via the import
        // ledger) wins; fall back to the transcription timestamp.
        let recordingTime = transcription.importFingerprint
            .flatMap { ImportLedger.shared.fileName(forFingerprint: $0, in: modelContext) }
            .flatMap { RecorderRecordingTime.parse(fromFileName: $0) }
            ?? transcription.timestamp
        if aiService.connectedProviders.isEmpty {
            // 沒有已連接的 AI provider：分類欄位照設，標題退回「日期＋內容前綴」，不打 AI。
            let stamp = RecorderRecordingTime.titleStamp(recordingTime)
            let tail = String(rawText.prefix(10)).trimmingCharacters(in: .whitespacesAndNewlines)
            transcription.recorderTitle = tail.isEmpty ? stamp : "\(stamp) \(tail)"
        } else {
            let model = resolvedClassifierModel(aiService: aiService)
            transcription.recorderTitle = await makeRecorderTitle(
                from: rawText, model: model, aiService: aiService, timestamp: recordingTime)
        }
        try? modelContext.save()
    }

    /// Recorder display title = `yyyyMMdd HHmm <≤10-char AI summary>`. Falls back to a raw excerpt
    /// if the summary call fails, so the title always at least carries the date.
    private func makeRecorderTitle(
        from text: String, model: (provider: AIProvider, modelName: String?),
        aiService: AIService, timestamp: Date
    ) async -> String {
        let date = RecorderRecordingTime.titleStamp(timestamp)
        let summary = await generateShortTitle(
            from: text, provider: model.provider, modelName: model.modelName, aiService: aiService)
        let tail = summary ?? String(text.prefix(10)).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? date : "\(date) \(tail)"
    }

    /// Apply a category's template to the raw transcript → `enhancedText` (raw `text` untouched).
    /// Resolves the model: category override → Recorder Mode default → fallback. Returns success.
    @discardableResult
    func applyTemplate(
        transcription: Transcription, category: RecorderCategory, modelContext: ModelContext,
        enhancementService: AIEnhancementService, aiService: AIService
    ) async -> Bool {
        guard !aiService.connectedProviders.isEmpty else {
            NotificationManager.shared.showNotification(
                title: "套用失敗：尚未連接任何 AI provider", type: .warning, duration: 4)
            return false
        }
        let model = resolvedAnalysisModel(categoryProvider: category.aiProviderName,
                                          categoryModel: category.aiModelName,
                                          aiService: aiService)
        // Feed the speaker-labelled transcript (when natively diarized) so templates like meeting
        // notes can attribute who said what; plain transcript otherwise.
        let analysisInput = await LongTranscriptSummarizer.shared.condense(
            speakerLabeledTranscript(transcription), aiService: aiService,
            provider: model.provider, modelName: model.modelName)
        transcription.recorderCategoryId = category.id
        transcription.recorderCategoryName = category.name

        guard let prompt = RecorderConfigStore.shared.recorderPrompt(byId: category.customPromptId) else {
            transcription.enhancedText = analysisInput   // no template → applied result = (condensed) raw
            try? modelContext.save()
            return true
        }
        do {
            let (enhanced, _, _) = try await enhancementService.enhance(
                analysisInput,
                configuration: recorderEnhancementConfig(prompt: prompt, model: model),
                // analysis output is long + local models are slow; the 7s voice default times out.
                timeoutOverride: TimeInterval(RecorderConfigStore.shared.recorderAnalysisTimeoutSeconds))
            transcription.enhancedText = enhanced
            try? modelContext.save()
            return true
        } catch {
            logger.error("Apply template failed: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: "套用失敗（\(model.provider.rawValue) · \(model.modelName ?? model.provider.defaultModel)）：\(error.localizedDescription)",
                type: .error, duration: 6)
            return false
        }
    }

    /// Export the applied result (`enhancedText`, else raw) to `{vault}/{category.subfolder}/`,
    /// superseding any prior export. No-op (with a toast) if no vault root is configured.
    func export(
        transcription: Transcription, category: RecorderCategory, modelContext: ModelContext,
        enhancementService: AIEnhancementService, aiService: AIService
    ) async {
        let store = RecorderConfigStore.shared
        guard let bookmark = store.vaultRootBookmark,
              let vaultRoot = VaultExportService.shared.resolveVaultRoot(bookmark) else {
            NotificationManager.shared.showNotification(title: "尚未設定 Obsidian Vault 根目錄", type: .warning, duration: 4)
            return
        }
        let analysis = transcription.enhancedText ?? transcription.text
        if let old = transcription.exportedFilePath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: old))
            transcription.exportedFilePath = nil
        }
        let model = resolvedAnalysisModel(categoryProvider: category.aiProviderName,
                                          categoryModel: category.aiModelName,
                                          aiService: aiService)
        let title = await generateShortTitle(from: analysis, provider: model.provider,
                                             modelName: model.modelName, aiService: aiService)
        let deviceName = transcription.recorderSourceDeviceId.flatMap { store.device(byId: $0)?.displayName }
        let decision = RoutingDecision(category: category,
                                       prompt: store.recorderPrompt(byId: category.customPromptId),
                                       usedFallback: category.isFallback)
        exportToVault(transcription: transcription, analysis: analysis, rawText: speakerLabeledTranscript(transcription),
                      decision: decision, deviceName: deviceName, title: title,
                      vaultRoot: vaultRoot, modelContext: modelContext)
        NotificationManager.shared.showNotification(title: "已匯出：\(category.name)", type: .success, duration: 3)
    }

    /// The transcript with speaker attribution ("講者N：…") when the recording was natively
    /// diarized, otherwise the plain transcript. Used both for the exported note's raw-transcript
    /// section AND as the analysis input, so a template (e.g. meeting notes) sees who said what.
    private func speakerLabeledTranscript(_ t: Transcription) -> String {
        let segments = t.speakerSegments
        guard t.speakerSegmentsAreNative, !segments.isEmpty else { return t.text }
        return segments
            .map { "**\(t.displayName(for: $0.speaker))：** \($0.text)" }
            .joined(separator: "\n\n")
    }

    /// Manual re-classify (History badge): apply the chosen category's template + re-export.
    func reclassify(
        transcription: Transcription, to category: RecorderCategory, device: RecorderDevice?,
        modelContext: ModelContext, enhancementService: AIEnhancementService, aiService: AIService
    ) async {
        await applyTemplate(transcription: transcription, category: category, modelContext: modelContext,
                            enhancementService: enhancementService, aiService: aiService)
        await export(transcription: transcription, category: category, modelContext: modelContext,
                     enhancementService: enhancementService, aiService: aiService)
    }

    /// The true recording time — parsed from the device filename (e.g. 260701_1258.mp3) via the
    /// import ledger — falling back to the import/transcription timestamp when the name carries no
    /// stamp. Keeps the exported note's title and frontmatter date on the recording time, not the
    /// (possibly much later) import/export time.
    private func recordingDate(for transcription: Transcription, in modelContext: ModelContext) -> Date {
        transcription.importFingerprint
            .flatMap { ImportLedger.shared.fileName(forFingerprint: $0, in: modelContext) }
            .flatMap { RecorderRecordingTime.parse(fromFileName: $0) }
            ?? transcription.timestamp
    }

    private func exportToVault(
        transcription: Transcription, analysis: String, rawText: String,
        decision: RoutingDecision, deviceName: String?, title: String?, vaultRoot: URL,
        modelContext: ModelContext
    ) {
        let recordedAt = recordingDate(for: transcription, in: modelContext)
        let input = VaultExportService.ExportInput(
            analysis: analysis, rawTranscript: rawText,
            categoryName: decision.category.name, deviceName: deviceName,
            sourceLabel: transcription.recorderSourceLabel,
            date: recordedAt,
            transcriptionModel: transcription.transcriptionModelName,
            enhancementModel: transcription.aiEnhancementModelName,
            confidence: transcription.classificationConfidence)
        let markdown = VaultExportService.shared.buildMarkdown(
            input, includeRawTranscript: RecorderConfigStore.shared.recorderExportIncludeRawTranscript)
        let fileName = VaultExportService.shared.suggestedFileName(
            date: recordedAt, categoryName: decision.category.name, title: title)
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
