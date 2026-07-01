import Foundation
import os

@MainActor
final class RecorderConfigStore: ObservableObject {
    static let shared = RecorderConfigStore()
    @Published private(set) var devices: [RecorderDevice] = []
    @Published private(set) var categories: [RecorderCategory] = []
    /// Recorder category prompts — a SEPARATE library from the voice-input prompts
    /// (`AIEnhancementService.customPrompts`). Categories bind into this list only.
    @Published private(set) var recorderPrompts: [CustomPrompt] = []
    /// Global Obsidian vault root (single vault for all devices; per-category sub-folders live under it).
    @Published private(set) var vaultRootBookmark: Data?
    /// Default analysis model (provider + model) used when a category doesn't override it.
    /// nil → auto: the first connected AI provider (never follows the voice Mode).
    @Published private(set) var defaultAIProviderName: String?
    @Published private(set) var defaultAIModelName: String?
    // MARK: Recorder Mode (recorder's own transcription settings, independent of voice Modes)
    @Published private(set) var recorderTranscriptionModelName: String?   // nil = auto (first usable)
    @Published private(set) var recorderLanguage: String?                 // nil = auto
    @Published private(set) var recorderTextFormattingEnabled: Bool = false
    @Published private(set) var recorderAutoExportEnabled: Bool = false   // default manual
    /// Append the full raw transcript to the exported Obsidian note (below a divider). Default off —
    /// the note carries only the analysis.
    @Published private(set) var recorderExportIncludeRawTranscript: Bool = false
    /// Speaker diarization for recorder transcripts. Default off. Only native-capable models
    /// (e.g. ElevenLabs Scribe) produce labels in M1; others keep a plain transcript.
    @Published private(set) var recorderDiarizationEnabled: Bool = false
    /// Expected number of speakers, forwarded to the diarizer. nil → let the model decide.
    @Published private(set) var recorderExpectedSpeakerCount: Int?
    /// Classifier model (e.g. a cheap local Ollama). nil → use the default analysis model.
    @Published private(set) var recorderClassifierProviderName: String?
    @Published private(set) var recorderClassifierModelName: String?
    /// Timeout (seconds) for a recorder analysis call. Analysis output is long and local models are
    /// slow, so this is far higher than the voice-dictation default (7s). User-adjustable.
    @Published private(set) var recorderAnalysisTimeoutSeconds: Int = 120
    private let devicesKey = "recorderDevicesV1"
    private let categoriesKey = "recorderCategoriesV1"
    private let recorderPromptsKey = "recorderCategoryPromptsV1"
    private let vaultRootKey = "recorderVaultRootV1"
    private let defaultProviderKey = "recorderDefaultAIProviderV1"
    private let defaultModelKey = "recorderDefaultAIModelV1"
    private let recTranscriptionKey = "recorderTranscriptionModelV1"
    private let recLanguageKey = "recorderLanguageV1"
    private let recFormattingKey = "recorderTextFormattingV1"
    private let recAutoExportKey = "recorderAutoExportV1"
    private let recExportRawKey = "recorderExportIncludeRawV1"
    private let recDiarizationKey = "recorderDiarizationEnabledV1"
    private let recExpectedSpeakersKey = "recorderExpectedSpeakerCountV1"
    private let recClassifierProviderKey = "recorderClassifierProviderV1"
    private let recClassifierModelKey = "recorderClassifierModelV1"
    private let recAnalysisTimeoutKey = "recorderAnalysisTimeoutV1"
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() { load(); seedFallbackIfNeeded() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: devicesKey),
           let decoded = try? JSONDecoder().decode([RecorderDevice].self, from: data) {
            devices = decoded
        }
        if let data = UserDefaults.standard.data(forKey: categoriesKey),
           let decoded = try? JSONDecoder().decode([RecorderCategory].self, from: data) {
            categories = decoded
        }
        if let data = UserDefaults.standard.data(forKey: recorderPromptsKey),
           let decoded = try? JSONDecoder().decode([CustomPrompt].self, from: data) {
            recorderPrompts = decoded
        }
        vaultRootBookmark = UserDefaults.standard.data(forKey: vaultRootKey)
        defaultAIProviderName = UserDefaults.standard.string(forKey: defaultProviderKey)
        defaultAIModelName = UserDefaults.standard.string(forKey: defaultModelKey)
        recorderTranscriptionModelName = UserDefaults.standard.string(forKey: recTranscriptionKey)
        recorderLanguage = UserDefaults.standard.string(forKey: recLanguageKey)
        recorderTextFormattingEnabled = UserDefaults.standard.bool(forKey: recFormattingKey)
        recorderAutoExportEnabled = UserDefaults.standard.bool(forKey: recAutoExportKey)
        recorderExportIncludeRawTranscript = UserDefaults.standard.bool(forKey: recExportRawKey)
        recorderDiarizationEnabled = UserDefaults.standard.bool(forKey: recDiarizationKey)
        let storedSpeakers = UserDefaults.standard.integer(forKey: recExpectedSpeakersKey)
        recorderExpectedSpeakerCount = storedSpeakers > 0 ? storedSpeakers : nil
        recorderClassifierProviderName = UserDefaults.standard.string(forKey: recClassifierProviderKey)
        recorderClassifierModelName = UserDefaults.standard.string(forKey: recClassifierModelKey)
        let storedTimeout = UserDefaults.standard.integer(forKey: recAnalysisTimeoutKey)
        recorderAnalysisTimeoutSeconds = storedTimeout > 0 ? storedTimeout : 120
    }

    /// Clamp to a sane range so a stray value can't disable the timeout or make it uselessly short.
    func setRecorderAnalysisTimeout(_ seconds: Int) {
        let clamped = min(600, max(15, seconds))
        recorderAnalysisTimeoutSeconds = clamped
        UserDefaults.standard.set(clamped, forKey: recAnalysisTimeoutKey)
    }

    func setClassifierModel(provider: String?, model: String?) {
        recorderClassifierProviderName = provider
        recorderClassifierModelName = model
        persistString(provider, recClassifierProviderKey)
        persistString(model, recClassifierModelKey)
    }

    // MARK: - Recorder Mode setters
    private func persistString(_ value: String?, _ key: String) {
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
    func setRecorderTranscriptionModel(_ name: String?) {
        recorderTranscriptionModelName = name; persistString(name, recTranscriptionKey)
    }
    func setRecorderLanguage(_ code: String?) {
        recorderLanguage = code; persistString(code, recLanguageKey)
    }
    func setRecorderTextFormatting(_ on: Bool) {
        recorderTextFormattingEnabled = on; UserDefaults.standard.set(on, forKey: recFormattingKey)
    }
    func setRecorderAutoExport(_ on: Bool) {
        recorderAutoExportEnabled = on; UserDefaults.standard.set(on, forKey: recAutoExportKey)
    }
    func setRecorderExportIncludeRawTranscript(_ on: Bool) {
        recorderExportIncludeRawTranscript = on; UserDefaults.standard.set(on, forKey: recExportRawKey)
    }
    func setRecorderDiarizationEnabled(_ on: Bool) {
        recorderDiarizationEnabled = on; UserDefaults.standard.set(on, forKey: recDiarizationKey)
    }
    func setRecorderExpectedSpeakerCount(_ n: Int?) {
        recorderExpectedSpeakerCount = n
        UserDefaults.standard.set(n ?? 0, forKey: recExpectedSpeakersKey)
    }

    /// Set (or clear) the single global vault root bookmark.
    func setVaultRoot(_ bookmark: Data?) {
        vaultRootBookmark = bookmark
        if let bookmark { UserDefaults.standard.set(bookmark, forKey: vaultRootKey) }
        else { UserDefaults.standard.removeObject(forKey: vaultRootKey) }
    }

    /// Set (or clear) the default analysis model. Pass nil/nil for auto (first connected provider).
    func setDefaultModel(provider: String?, model: String?) {
        defaultAIProviderName = provider
        defaultAIModelName = model
        if let provider { UserDefaults.standard.set(provider, forKey: defaultProviderKey) }
        else { UserDefaults.standard.removeObject(forKey: defaultProviderKey) }
        if let model { UserDefaults.standard.set(model, forKey: defaultModelKey) }
        else { UserDefaults.standard.removeObject(forKey: defaultModelKey) }
    }
    private func saveDevices() {
        if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: devicesKey) }
    }
    private func saveCategories() {
        if let data = try? JSONEncoder().encode(categories) { UserDefaults.standard.set(data, forKey: categoriesKey) }
    }
    private func saveRecorderPrompts() {
        if let data = try? JSONEncoder().encode(recorderPrompts) { UserDefaults.standard.set(data, forKey: recorderPromptsKey) }
    }

    // MARK: - Recorder category prompts (separate from voice prompts)
    func recorderPrompt(byId id: UUID?) -> CustomPrompt? {
        guard let id else { return nil }
        return recorderPrompts.first { $0.id == id }
    }
    func upsertRecorderPrompt(_ prompt: CustomPrompt) {
        if let i = recorderPrompts.firstIndex(where: { $0.id == prompt.id }) { recorderPrompts[i] = prompt }
        else { recorderPrompts.append(prompt) }
        saveRecorderPrompts()
    }
    func removeRecorderPrompt(_ id: UUID) {
        recorderPrompts.removeAll { $0.id == id }
        // Unbind any category that used it.
        for i in categories.indices where categories[i].customPromptId == id {
            categories[i].customPromptId = nil
        }
        saveRecorderPrompts(); saveCategories()
    }

    /// One-time migration: recorder prompts must never use the dictation system template.
    func disableSystemTemplateForRecorderPrompts() {
        guard recorderPrompts.contains(where: { $0.useSystemInstructions }) else { return }
        recorderPrompts = recorderPrompts.map {
            CustomPrompt(id: $0.id, title: $0.title, promptText: $0.promptText, useSystemInstructions: false)
        }
        saveRecorderPrompts()
    }

    // MARK: - Devices
    func upsert(_ device: RecorderDevice) {
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i] = device }
        else { devices.append(device) }
        saveDevices()
        RecorderFolderWatcher.shared.sync()
    }
    func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }; saveDevices()
        RecorderFolderWatcher.shared.sync()
    }

    /// First auto-import-enabled device whose match string is contained in the mounted volume name.
    func device(forVolumeName name: String) -> RecorderDevice? {
        devices.first { $0.autoImportEnabled && $0.matches(volumeName: name) }
    }
    func device(byId id: UUID) -> RecorderDevice? { devices.first { $0.id == id } }

    // MARK: - Categories
    /// Ensure exactly one undeletable fallback category exists.
    func seedFallbackIfNeeded() {
        guard !categories.contains(where: { $0.isFallback }) else { return }
        categories.append(.makeFallback())
        saveCategories()
    }

    var fallbackCategory: RecorderCategory {
        categories.first { $0.isFallback } ?? .makeFallback()
    }
    func category(byId id: UUID) -> RecorderCategory? { categories.first { $0.id == id } }

    func upsertCategory(_ category: RecorderCategory) {
        if let i = categories.firstIndex(where: { $0.id == category.id }) { categories[i] = category }
        else { categories.append(category) }
        saveCategories()
    }
    /// Remove a category. The fallback category is undeletable.
    func removeCategory(_ id: UUID) {
        guard let c = categories.first(where: { $0.id == id }), !c.isFallback else { return }
        categories.removeAll { $0.id == id }
        saveCategories()
    }

    /// Seed the built-in default categories (通用/會議/演講/面試) + their prompts into the
    /// recorder-prompt library. Idempotent: matches by prompt title / category name.
    func seedDefaultTemplates() {
        func promptId(title: String, text: String) -> UUID {
            if let existing = recorderPrompts.first(where: { $0.title == title }) { return existing.id }
            // Recorder prompts run raw (analysis tasks) — never wrapped in the dictation system template.
            let prompt = CustomPrompt(title: title, promptText: text, useSystemInstructions: false)
            recorderPrompts.append(prompt)
            return prompt.id
        }

        for t in RecorderDefaultTemplates.all {
            let pid = promptId(title: t.promptTitle, text: t.promptText)
            if t.isFallback {
                if var fb = categories.first(where: { $0.isFallback }) {
                    fb.customPromptId = pid
                    fb.classifierDescription = t.classifierDescription
                    if fb.subfolderName.isEmpty { fb.subfolderName = t.subfolder }
                    upsertCategory(fb)
                }
            } else if !categories.contains(where: { $0.name == t.categoryName }) {
                upsertCategory(RecorderCategory(
                    name: t.categoryName, classifierDescription: t.classifierDescription,
                    customPromptId: pid, subfolderName: t.subfolder, isFallback: false))
            }
        }
        for p in RecorderDefaultTemplates.extraPrompts {
            _ = promptId(title: p.title, text: p.text)
        }
        saveRecorderPrompts()
    }

    /// One-time migration: move recorder-default prompts that were previously seeded into the
    /// shared voice library back out into the recorder-prompt store (preserving ids so existing
    /// category bindings keep resolving), then remove them from the voice list.
    func migrateRecorderPromptsOut(from enhancementService: AIEnhancementService) {
        let recorderTitles = Set(RecorderDefaultTemplates.all.map { $0.promptTitle }
                                 + RecorderDefaultTemplates.extraPrompts.map { $0.title })
        let toMove = enhancementService.allPrompts.filter { recorderTitles.contains($0.title) }
        guard !toMove.isEmpty else { return }
        for p in toMove {
            if !recorderPrompts.contains(where: { $0.id == p.id }) { recorderPrompts.append(p) }
            enhancementService.deletePrompt(p)
        }
        saveRecorderPrompts()
    }
}
