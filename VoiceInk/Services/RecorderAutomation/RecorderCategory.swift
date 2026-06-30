import Foundation

/// A user-defined content class (e.g. 面試 / 演講 / 通用). Binds an existing `CustomPrompt`,
/// a classifier "when to use" description, and a vault sub-folder. Persisted as JSON in UserDefaults.
struct RecorderCategory: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var classifierDescription: String   // "when to use" text fed to the classifier
    var customPromptId: UUID?           // binds an existing CustomPrompt (nil → raw enhancement)
    var subfolderName: String           // under the vault root
    var isFallback: Bool                // exactly one true; undeletable
    var aiProviderName: String?         // analysis model override (nil → use the default model)
    var aiModelName: String?

    init(id: UUID = UUID(), name: String, classifierDescription: String = "",
         customPromptId: UUID? = nil, subfolderName: String, isFallback: Bool = false,
         aiProviderName: String? = nil, aiModelName: String? = nil) {
        self.id = id
        self.name = name
        self.classifierDescription = classifierDescription
        self.customPromptId = customPromptId
        self.subfolderName = subfolderName
        self.isFallback = isFallback
        self.aiProviderName = aiProviderName
        self.aiModelName = aiModelName
    }

    /// The seeded, undeletable fallback used when classification is `uncertain`.
    static func makeFallback() -> RecorderCategory {
        RecorderCategory(name: "通用", classifierDescription: "無法明確分類時的預設類別",
                         customPromptId: nil, subfolderName: "Inbox", isFallback: true)
    }
}
