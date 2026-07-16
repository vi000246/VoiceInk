import Foundation
import Combine

/// M11 會議開始偵測的設定（FR-85）。
///
/// 樣式鏡射 `MeetingCopilotConfigStore`：`@Published private(set)` + `…V1` UserDefaults key +
/// `set…()` mutator，並**重用同一個 `MeetingCopilotDefaults` 後端抽象**，測試才能用 `InMemoryDefaults`
/// 完全隔離（見 `TestDefaults.swift`：suiteName 擋不住讀取 fallthrough 的教訓）。
@MainActor
final class MeetingDetectionConfigStore: ObservableObject {

    static let shared = MeetingDetectionConfigStore()

    // MARK: - Keys
    private let enabledKey = "meetingDetectEnabledV1"
    private let nativeBundleIdsKey = "meetingDetectNativeBundleIdsV1"
    private let browsersEnabledKey = "meetingDetectBrowsersEnabledV1"
    private let debounceKey = "meetingDetectDebounceSecondsV1"
    private let rearmKey = "meetingDetectRearmSecondsV1"

    static let debounceRange: ClosedRange<Double> = 1...15
    static let rearmRange: ClosedRange<Double> = 10...300

    // MARK: - Settings
    /// 總開關（關 = detector tick 早退、watcher 不輪詢、零 effects）。預設 true。
    @Published private(set) var enabled: Bool = true
    /// 啟用的原生會議 app bundle id 集合（來自 `MeetingDetectionCatalog.nativeApps` 目錄）。
    @Published private(set) var nativeEnabledBundleIds: Set<String> =
        MeetingDetectionCatalog.defaultEnabledNativeBundleIds
    /// 瀏覽器路徑總開關（含標題確認）。預設 true。
    @Published private(set) var browsersEnabled: Bool = true
    /// mic 持續多久（秒）才算候選。預設 3，夾 [1, 15]。
    @Published private(set) var debounceSeconds: Double = 3
    /// mic 停多久（秒）後同 app 可再提示。預設 30，夾 [10, 300]。UI 不暴露（內部參數）。
    @Published private(set) var rearmSeconds: Double = 30

    private let defaults: MeetingCopilotDefaults

    init(defaults: MeetingCopilotDefaults = UserDefaults.standard) {
        self.defaults = defaults
        load()
    }

    private func load() {
        let d = defaults
        enabled = (d.object(forKey: enabledKey) as? Bool) ?? true
        if let arr = d.object(forKey: nativeBundleIdsKey) as? [String] {
            nativeEnabledBundleIds = Set(arr)
        }
        browsersEnabled = (d.object(forKey: browsersEnabledKey) as? Bool) ?? true
        if let db = d.object(forKey: debounceKey) as? Double {
            debounceSeconds = Self.clampDebounce(db)
        }
        if let rr = d.object(forKey: rearmKey) as? Double {
            rearmSeconds = Self.clampRearm(rr)
        }
    }

    static func clampDebounce(_ v: Double) -> Double {
        min(max(v, debounceRange.lowerBound), debounceRange.upperBound)
    }
    static func clampRearm(_ v: Double) -> Double {
        min(max(v, rearmRange.lowerBound), rearmRange.upperBound)
    }

    // MARK: - Mutators
    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
    }

    func setBrowsersEnabled(_ value: Bool) {
        browsersEnabled = value
        defaults.set(value, forKey: browsersEnabledKey)
    }

    func setNativeEnabled(_ bundleId: String, _ on: Bool) {
        if on { nativeEnabledBundleIds.insert(bundleId) }
        else { nativeEnabledBundleIds.remove(bundleId) }
        // sorted array = 決定性儲存（可讀、diff-friendly）。
        defaults.set(nativeEnabledBundleIds.sorted(), forKey: nativeBundleIdsKey)
    }

    func setDebounceSeconds(_ value: Double) {
        debounceSeconds = Self.clampDebounce(value)
        defaults.set(debounceSeconds, forKey: debounceKey)
    }

    func setRearmSeconds(_ value: Double) {
        rearmSeconds = Self.clampRearm(value)
        defaults.set(rearmSeconds, forKey: rearmKey)
    }
}
