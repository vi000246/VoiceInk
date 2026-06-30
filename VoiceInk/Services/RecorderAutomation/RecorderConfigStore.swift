import Foundation
import os

@MainActor
final class RecorderConfigStore: ObservableObject {
    static let shared = RecorderConfigStore()
    @Published private(set) var devices: [RecorderDevice] = []
    @Published private(set) var categories: [RecorderCategory] = []
    /// Global Obsidian vault root (single vault for all devices; per-category sub-folders live under it).
    @Published private(set) var vaultRootBookmark: Data?
    /// Default analysis model (provider + model) used when a category doesn't override it.
    /// nil → fall back to the active Mode's AI model.
    @Published private(set) var defaultAIProviderName: String?
    @Published private(set) var defaultAIModelName: String?
    private let devicesKey = "recorderDevicesV1"
    private let categoriesKey = "recorderCategoriesV1"
    private let vaultRootKey = "recorderVaultRootV1"
    private let defaultProviderKey = "recorderDefaultAIProviderV1"
    private let defaultModelKey = "recorderDefaultAIModelV1"
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
        vaultRootBookmark = UserDefaults.standard.data(forKey: vaultRootKey)
        defaultAIProviderName = UserDefaults.standard.string(forKey: defaultProviderKey)
        defaultAIModelName = UserDefaults.standard.string(forKey: defaultModelKey)
    }

    /// Set (or clear) the single global vault root bookmark.
    func setVaultRoot(_ bookmark: Data?) {
        vaultRootBookmark = bookmark
        if let bookmark { UserDefaults.standard.set(bookmark, forKey: vaultRootKey) }
        else { UserDefaults.standard.removeObject(forKey: vaultRootKey) }
    }

    /// Set (or clear) the default analysis model. Pass nil/nil to follow the active Mode.
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

    // MARK: - Devices
    func upsert(_ device: RecorderDevice) {
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i] = device }
        else { devices.append(device) }
        saveDevices()
    }
    func remove(_ id: UUID) { devices.removeAll { $0.id == id }; saveDevices() }

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

    /// Seed the built-in default categories (通用/會議/演講/面試) + their prompts, plus extra
    /// prompts into the shared prompt library. Idempotent: matches existing prompts/categories by
    /// title/name so it can be re-run safely from the Categories page.
    func seedDefaultTemplates(using enhancementService: AIEnhancementService) {
        func promptId(title: String, text: String) -> UUID {
            if let existing = enhancementService.allPrompts.first(where: { $0.title == title }) {
                return existing.id
            }
            let prompt = CustomPrompt(title: title, promptText: text, useSystemInstructions: true)
            enhancementService.customPrompts.append(prompt)
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
        // Extra prompts into the library (unbound).
        for p in RecorderDefaultTemplates.extraPrompts {
            _ = promptId(title: p.title, text: p.text)
        }
    }
}
