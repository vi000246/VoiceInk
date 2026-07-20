import Foundation
import Combine

/// 語音待辦捕捉(Vikunja)的設定。
///
/// 樣式鏡射 `MeetingDetectionConfigStore`:`@Published private(set)` + `…V1` UserDefaults key +
/// `set…()` mutator,後端走 `MeetingCopilotDefaults` 抽象,測試用 `InMemoryDefaults` 完全隔離。
/// API token 走 Keychain(`KeychainService`),**不進 UserDefaults**。
@MainActor
final class VikunjaConfigStore: ObservableObject {

    static let shared = VikunjaConfigStore()

    // MARK: - Keys
    private let baseURLKey = "vikunjaBaseURLV1"
    private let projectIDKey = "vikunjaDefaultProjectIDV1"
    private let projectNameKey = "vikunjaDefaultProjectNameV1"
    private let enabledKey = "vikunjaEnabledV1"
    /// token 不 iCloud 同步(NAS 私有服務,別台機器拿到也連不上內網)。
    static let tokenKeychainKey = "vikunjaAPIToken"

    // MARK: - Settings
    /// 使用者輸入原文(可含或不含 /api/v1;實際請求前由 `VikunjaService.normalizeBaseURL` 正規化)。
    @Published private(set) var baseURL: String = ""
    /// 建任務的目標專案。0 = 未選(Vikunja 專案 id 從 1 起跳)。
    @Published private(set) var defaultProjectID: Int = 0
    /// 專案顯示名快取——設定頁重開、專案清單尚未載入時,下拉才有字可顯示。
    @Published private(set) var defaultProjectName: String = ""
    /// 總開關(關 = 熱鍵按了只提示未啟用)。預設 false。
    @Published private(set) var enabled: Bool = false

    private let defaults: MeetingCopilotDefaults

    init(defaults: MeetingCopilotDefaults = UserDefaults.standard) {
        self.defaults = defaults
        baseURL = defaults.string(forKey: baseURLKey) ?? ""
        defaultProjectID = defaults.integer(forKey: projectIDKey)
        defaultProjectName = defaults.string(forKey: projectNameKey) ?? ""
        enabled = defaults.bool(forKey: enabledKey)
    }

    // MARK: - Token(Keychain)

    var token: String? {
        KeychainService.shared.getString(forKey: Self.tokenKeychainKey, syncable: false)
    }

    var hasToken: Bool { token?.isEmpty == false }

    /// 回傳 Keychain 是否真的落地——寫入可能失敗(keychain 鎖定、簽章問題),失敗必須讓 UI
    /// 呈現,否則欄位顯示的字與實際儲存脫節,使用者只會在按熱鍵時撞到「尚未設定」而無從診斷
    /// (房子慣例:`APIKeyManager.saveAPIKey` 同樣回 Bool 供呼叫端 guard)。
    @discardableResult
    func setToken(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded: Bool
        if trimmed.isEmpty {
            succeeded = KeychainService.shared.delete(forKey: Self.tokenKeychainKey, syncable: false)
        } else {
            succeeded = KeychainService.shared.save(trimmed, forKey: Self.tokenKeychainKey, syncable: false)
        }
        // 失敗也要通知——UI 得重讀 `hasToken` 才會跟實際 Keychain 狀態一致。
        objectWillChange.send()
        return succeeded
    }

    // MARK: - Readiness

    /// UserDefaults 側是否齊備(純函式供測試;token 另查 Keychain)。
    static func isConfigured(baseURL: String, defaultProjectID: Int) -> Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && defaultProjectID > 0
    }

    /// 熱鍵可以動工的完整條件:啟用 + URL + 專案 + token。
    var isReadyForCapture: Bool {
        enabled && Self.isConfigured(baseURL: baseURL, defaultProjectID: defaultProjectID) && hasToken
    }

    /// 「連線是否設好」:URL + 專案 + token,**不含** `enabled`——那是熱鍵語音記待辦的
    /// 功能開關,與會後包等只重用連線設定的功能無關(沒開熱鍵也該能建任務)。
    var isConnectionReady: Bool {
        Self.isConfigured(baseURL: baseURL, defaultProjectID: defaultProjectID) && hasToken
    }

    // MARK: - Mutators

    func setBaseURL(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        baseURL = trimmed
        defaults.set(trimmed, forKey: baseURLKey)
    }

    func setDefaultProject(id: Int, name: String) {
        defaultProjectID = id
        defaultProjectName = name
        defaults.set(id, forKey: projectIDKey)
        defaults.set(name, forKey: projectNameKey)
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
    }
}
