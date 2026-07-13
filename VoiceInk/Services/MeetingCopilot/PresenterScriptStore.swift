import Foundation
import Combine

/// 一則預設講稿(使用者自寫)。M7:私人提詞面板顯示的內容單元。
///
/// **只是使用者自己打的文字** —— 沒有任何 AI 生成、沒有任何來自對方音訊的內容。
struct PresenterScript: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String = ""
    var body: String = ""
}

/// 預設講稿的儲存(M7,FR-33)。
///
/// # 硬界線(見 `docs/srs/meeting-copilot-m7-preset-scripts.srs.md`)
/// 這個 store 與 live pipeline / AI 完全無關:它只持久化使用者自寫的講稿與讀稿字級,
/// 不接 ASR、不接 LLM、不讀 cue。讀稿面板獨立於 `copilotEnabled`。
///
/// 樣式鏡射 `MeetingCopilotConfigStore`:`@Published private(set)` + `…V1` UserDefaults key + `set…()` mutator。
/// `defaults` 可注入,供單元測試用獨立 suite(不污染 `.standard`)。
@MainActor
final class PresenterScriptStore: ObservableObject {

    static let shared = PresenterScriptStore()

    private let scriptsKey = "meetingCopilotPresenterScriptsV1"
    private let fontSizeKey = "meetingCopilotPresenterFontSizeV1"

    static let minFontSize: Double = 14
    static let maxFontSize: Double = 40
    static let defaultFontSize: Double = 22

    /// 讀稿字級的夾取(FR-37)。
    static func clampFont(_ v: Double) -> Double { min(max(v, minFontSize), maxFontSize) }

    @Published private(set) var scripts: [PresenterScript] = []
    @Published private(set) var fontSize: Double = defaultFontSize

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        if let data = defaults.data(forKey: scriptsKey),
           let decoded = try? JSONDecoder().decode([PresenterScript].self, from: data) {
            scripts = decoded
        }
        if defaults.object(forKey: fontSizeKey) != nil {
            fontSize = Self.clampFont(defaults.double(forKey: fontSizeKey))
        }
    }

    private func persistScripts() {
        if let data = try? JSONEncoder().encode(scripts) {
            defaults.set(data, forKey: scriptsKey)
        }
    }

    // MARK: - Mutators

    func add(title: String, body: String) {
        scripts.append(PresenterScript(title: title, body: body))
        persistScripts()
    }

    func update(id: UUID, title: String, body: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[i].title = title
        scripts[i].body = body
        persistScripts()
    }

    func delete(id: UUID) {
        scripts.removeAll { $0.id == id }
        persistScripts()
    }

    func setFontSize(_ v: Double) {
        fontSize = Self.clampFont(v)
        defaults.set(fontSize, forKey: fontSizeKey)
    }
}
