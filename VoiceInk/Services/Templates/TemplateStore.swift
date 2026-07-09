import Foundation

/// 單一共用範本庫的權威來源。取代舊的分離兩庫（語音 `customPrompts` / 錄音 `recorderCategoryPromptsV1`）。
/// 每個範本標註所屬輸入類別（語音輸入／錄音輸入，可多選）;語音/錄音模式各取對應類別子集。
@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    @Published private(set) var templates: [CustomPrompt] = []

    private let key = "sharedTemplatesV1"
    // 舊 key（遷移來源）——遷移後不再寫入，保留值供 rollback。
    private let legacyVoiceKey = "customPrompts"
    private let legacyRecorderKey = "recorderCategoryPromptsV1"

    private init() { load() }

    func reload() { load() }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CustomPrompt].self, from: data) {
            templates = decoded
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(encoded, forKey: key)
        }
    }

    // MARK: - Queries

    /// 含指定類別的範本子集（語音模式取 .voiceInput、錄音分類取 .recorderInput）。
    func templates(for category: TemplateCategory) -> [CustomPrompt] {
        templates.filter { $0.categories.contains(category) }
    }

    func template(byId id: UUID?) -> CustomPrompt? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    // MARK: - Mutations

    func upsert(_ prompt: CustomPrompt) {
        if let i = templates.firstIndex(where: { $0.id == prompt.id }) { templates[i] = prompt }
        else { templates.append(prompt) }
        save()
    }

    func delete(_ id: UUID) {
        templates.removeAll { $0.id == id }
        save()
    }

    // MARK: - Migration

    /// 首次（無 `sharedTemplatesV1`）把舊兩庫合併：舊語音範本標 .voiceInput、舊錄音範本標
    /// .recorderInput;同 id 兩邊都有則合併類別。冪等（已遷移即跳過）。舊 key 保留不刪。
    func migrateIfNeeded() {
        guard UserDefaults.standard.data(forKey: key) == nil else { return }
        var merged: [CustomPrompt] = []

        if let d = UserDefaults.standard.data(forKey: legacyVoiceKey),
           let voice = try? JSONDecoder().decode([CustomPrompt].self, from: d) {
            merged += voice.map { var p = $0; p.categories = Self.uniq(p.categories + [.voiceInput]); return p }
        }
        if let d = UserDefaults.standard.data(forKey: legacyRecorderKey),
           let rec = try? JSONDecoder().decode([CustomPrompt].self, from: d) {
            for var p in rec {
                if let i = merged.firstIndex(where: { $0.id == p.id }) {
                    merged[i].categories = Self.uniq(merged[i].categories + [.recorderInput])
                } else {
                    p.categories = Self.uniq(p.categories + [.recorderInput])
                    merged.append(p)
                }
            }
        }
        templates = merged
        save()
    }

    private static func uniq(_ c: [TemplateCategory]) -> [TemplateCategory] {
        c.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    // MARK: - Restore（一次性補救）

    /// 把舊兩庫（`customPrompts` / `recorderCategoryPromptsV1`，遷移後仍保留）中「目前共用庫沒有的」
    /// 範本補回來——依 id 判斷，**只新增、絕不刪除或修改**既有範本。用來還原先前遷移/覆蓋操作漏掉的
    /// 使用者範本。冪等（跑過即跳過）。
    func restoreMissingLegacyTemplatesOnce() {
        let flag = "templatesRestoredFromLegacyV2"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        // 依「標題＋內容」判斷是否已存在（id 因重新種子而變動,不可靠;多個同名如「# ROLE」靠內容區分）。
        func sig(_ p: CustomPrompt) -> String {
            p.title.trimmingCharacters(in: .whitespacesAndNewlines)
                + "\u{1}" + p.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var existing = Set(templates.map(sig))
        var added = 0
        func restore(_ key: String, category: TemplateCategory) {
            guard let d = UserDefaults.standard.data(forKey: key),
                  let arr = try? JSONDecoder().decode([CustomPrompt].self, from: d) else { return }
            for var p in arr {
                let s = sig(p)
                if existing.contains(s) { continue }
                p.categories = Self.uniq(p.categories + [category])
                templates.append(p)
                existing.insert(s)
                added += 1
            }
        }
        restore(legacyVoiceKey, category: .voiceInput)
        restore(legacyRecorderKey, category: .recorderInput)
        if added > 0 { save() }
        UserDefaults.standard.set(true, forKey: flag)
    }
}
