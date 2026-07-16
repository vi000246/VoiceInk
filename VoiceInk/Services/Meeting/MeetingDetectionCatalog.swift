import Foundation

/// M11 會議開始偵測的共用常數（原生會議 app 目錄、瀏覽器家族、會議標題 pattern）。
///
/// 這些是**程式內常數**（v1 不做使用者自訂），被三個消費者共用：`MeetingDetectionConfigStore`
/// （native 目錄的預設啟用集＋UI toggles）、`MeetingStartDetectorCore`（分類 bundle id）、
/// `MeetingWindowTitleScanner`（視窗 owner 名＋標題 pattern）。集中在此 = 單一事實來源。
enum MeetingDetectionCatalog {

    // MARK: - 原生會議 app 目錄

    /// 一個固定目錄項（bundle id + 顯示名 + 預設是否啟用）。UI 是這份目錄的一排 toggle。
    struct NativeApp: Identifiable, Equatable {
        var id: String { bundleId }
        let bundleId: String
        let displayName: String
        let defaultEnabled: Bool
    }

    /// Teams（new/classic）與 Zoom 預設開；Webex/FaceTime 在目錄中但預設關（不在驗收範圍）。
    /// Webex/FaceTime 的 bundle id 為 best-effort（不同版本可能不同；預設關，實測前不保證命中）。
    static let nativeApps: [NativeApp] = [
        NativeApp(bundleId: "com.microsoft.teams2", displayName: "Microsoft Teams", defaultEnabled: true),
        NativeApp(bundleId: "com.microsoft.teams", displayName: "Microsoft Teams（classic）", defaultEnabled: true),
        NativeApp(bundleId: "us.zoom.xos", displayName: "Zoom", defaultEnabled: true),
        NativeApp(bundleId: "Cisco-Systems.Spark", displayName: "Webex", defaultEnabled: false),
        NativeApp(bundleId: "com.apple.FaceTime", displayName: "FaceTime", defaultEnabled: false),
    ]

    static let defaultEnabledNativeBundleIds: Set<String> =
        Set(nativeApps.filter(\.defaultEnabled).map(\.bundleId))

    static func nativeDisplayName(for bundleId: String) -> String? {
        nativeApps.first { $0.bundleId == bundleId }?.displayName
    }

    // MARK: - 瀏覽器家族

    /// 一個瀏覽器家族。**bundle id 用「前綴」比對**：Chrome 的音訊行程常是
    /// `com.google.Chrome.helper*`、PWA 是 `com.google.Chrome.app.*`，都要能對上。
    /// **視窗 owner 用「名稱」比對**：CGWindowList 拿不到 bundle id，而 helper 行程的 pid
    /// 也對不上 UI 視窗的 ownerPID，只能靠 ownerName。
    struct BrowserFamily: Equatable {
        let id: String
        let displayName: String
        let bundleIdPrefixes: [String]
        let windowOwnerNames: [String]
    }

    static let browserFamilies: [BrowserFamily] = [
        BrowserFamily(id: "chrome", displayName: "Google Chrome",
                      bundleIdPrefixes: ["com.google.Chrome"], windowOwnerNames: ["Google Chrome"]),
        BrowserFamily(id: "edge", displayName: "Microsoft Edge",
                      bundleIdPrefixes: ["com.microsoft.edgemac"], windowOwnerNames: ["Microsoft Edge"]),
        BrowserFamily(id: "arc", displayName: "Arc",
                      bundleIdPrefixes: ["company.thebrowser.Browser"], windowOwnerNames: ["Arc"]),
        BrowserFamily(id: "brave", displayName: "Brave",
                      bundleIdPrefixes: ["com.brave.Browser"], windowOwnerNames: ["Brave Browser"]),
        BrowserFamily(id: "firefox", displayName: "Firefox",
                      bundleIdPrefixes: ["org.mozilla.firefox"], windowOwnerNames: ["Firefox"]),
        BrowserFamily(id: "safari", displayName: "Safari",
                      bundleIdPrefixes: ["com.apple.Safari"], windowOwnerNames: ["Safari"]),
        BrowserFamily(id: "vivaldi", displayName: "Vivaldi",
                      bundleIdPrefixes: ["com.vivaldi.Vivaldi"], windowOwnerNames: ["Vivaldi"]),
    ]

    /// bundle id → 所屬瀏覽器家族（前綴命中；無 → nil）。
    static func browserFamily(forBundleId bundleId: String) -> BrowserFamily? {
        browserFamilies.first { family in
            family.bundleIdPrefixes.contains { bundleId.hasPrefix($0) }
        }
    }

    // MARK: - 會議標題 pattern

    /// contains 比對（大小寫敏感；任一命中即可）。
    /// Google Meet 分頁標題「Meet – <code>」(en dash)／「Meet - 」(hyphen 保險)／「Google Meet」；
    /// Teams 網頁版標題恆含產品名「Microsoft Teams」（中文介面亦同）。
    static let meetingTitlePatterns = ["Meet – ", "Meet - ", "Google Meet", "Microsoft Teams"]

    // MARK: - 分類 / 顯示

    /// bundle id 是否為「我們在意的」候選（原生已啟用，或瀏覽器已啟用且屬某家族）。
    /// core 與 glue 共用，避免兩份分類邏輯漂移。
    static func isCandidate(bundleId: String, nativeEnabled: Set<String>, browsersEnabled: Bool) -> Bool {
        if nativeEnabled.contains(bundleId) { return true }
        if browsersEnabled, browserFamily(forBundleId: bundleId) != nil { return true }
        return false
    }

    /// 給人看的顯示名（通知標題／log 用）。原生取目錄名、瀏覽器取家族名、都不是 → 原字串。
    static func displayName(forBundleId bundleId: String) -> String {
        if let native = nativeDisplayName(for: bundleId) { return native }
        if let family = browserFamily(forBundleId: bundleId) { return family.displayName }
        return bundleId
    }
}

/// 標題掃描結果（core 據此決定瀏覽器路徑）：
/// - `.unavailable` = 無螢幕錄製權限，讀不到標題 → 降級（consume 該 session）。
/// - `.miss` = 有權限但沒有命中的會議視窗 → 維持 pending 繼續等。
/// - `.hit` = 命中會議視窗 → 觸發。
enum TitleCheckResult: Equatable {
    case unavailable
    case miss
    case hit
}
