import Foundation
import Combine

/// 會後自動閉環包(M12)的設定。
///
/// 樣式鏡射 `VikunjaConfigStore`:`@Published private(set)` + `…V1` key + `set…()` mutator,
/// 後端走 `MeetingCopilotDefaults` 抽象,測試用 `InMemoryDefaults` 完全隔離。
@MainActor
final class MeetingPackConfigStore: ObservableObject {

    static let shared = MeetingPackConfigStore()

    // MARK: - Keys
    private let enabledKey = "meetingPackEnabledV1"
    private let subfolderKey = "meetingPackSubfolderV1"
    private let vikunjaAutoCreateKey = "meetingPackVikunjaAutoCreateV1"

    static let defaultSubfolder = "會後包"

    // MARK: - Settings
    /// 總開關。預設 **true**——會後包是被動產出,不打斷任何流程,預設開啟才符合
    /// 「散會即有結構化紀錄」的核心價值(關掉 = 完全零行為)。
    @Published private(set) var enabled: Bool = true
    /// vault 根目錄下的匯出子資料夾(根目錄沿用錄音設定的 `vaultRootBookmark`)。
    @Published private(set) var subfolder: String = MeetingPackConfigStore.defaultSubfolder
    /// 「我答應的」自動建成 Vikunja 任務。預設 false = 通知帶按鈕,按了才批次建。
    @Published private(set) var vikunjaAutoCreate: Bool = false

    private let defaults: MeetingCopilotDefaults

    init(defaults: MeetingCopilotDefaults = UserDefaults.standard) {
        self.defaults = defaults
        enabled = (defaults.object(forKey: enabledKey) as? Bool) ?? true   // 未設定 → true
        let stored = defaults.string(forKey: subfolderKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        subfolder = (stored?.isEmpty == false) ? stored! : Self.defaultSubfolder
        vikunjaAutoCreate = defaults.bool(forKey: vikunjaAutoCreateKey)
    }

    // MARK: - Mutators

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
    }

    /// 清成空白 = 還原預設子資料夾(空字串會讓匯出直接落在 vault 根目錄,不是使用者要的)。
    func setSubfolder(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        subfolder = trimmed.isEmpty ? Self.defaultSubfolder : trimmed
        defaults.set(subfolder, forKey: subfolderKey)
    }

    func setVikunjaAutoCreate(_ value: Bool) {
        vikunjaAutoCreate = value
        defaults.set(value, forKey: vikunjaAutoCreateKey)
    }
}
