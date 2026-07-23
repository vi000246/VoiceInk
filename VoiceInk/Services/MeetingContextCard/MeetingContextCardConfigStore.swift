import Foundation
import Combine

/// M14 會議脈絡卡的設定。
///
/// 樣式鏡射 `MeetingDetectionConfigStore`：`@Published private(set)` + `…V1` key + `set…()` mutator，
/// 重用 `MeetingCopilotDefaults` 後端抽象——測試用 `InMemoryDefaults` 完全隔離，
/// 絕不碰 `UserDefaults.standard`（見 TestDefaults.swift 教訓）。
@MainActor
final class MeetingContextCardConfigStore: ObservableObject {

    static let shared = MeetingContextCardConfigStore()

    // MARK: - Keys
    private let enabledKey = "meetingContextCardEnabledV1"
    private let autoShowKey = "meetingContextCardAutoShowV1"
    private let showWhenEmptyKey = "meetingContextCardShowWhenEmptyV1"

    // MARK: - Settings
    /// 總開關（關 = 兩個觸發入口直接早退，零檢索、零 LLM 呼叫）。預設 true。
    @Published private(set) var enabled: Bool = true
    /// 生成完成後直接浮出卡片；false 改發通知、點了才開卡。預設 true。
    @Published private(set) var autoShow: Bool = true
    /// RAG 零命中且無相關任務時，是否仍顯示中性空卡（「第一次跟這個主題開會」）。預設 false（不打擾）。
    @Published private(set) var showWhenEmpty: Bool = false

    private let defaults: MeetingCopilotDefaults

    init(defaults: MeetingCopilotDefaults = UserDefaults.standard) {
        self.defaults = defaults
        enabled = (defaults.object(forKey: enabledKey) as? Bool) ?? true
        autoShow = (defaults.object(forKey: autoShowKey) as? Bool) ?? true
        showWhenEmpty = (defaults.object(forKey: showWhenEmptyKey) as? Bool) ?? false
    }

    // MARK: - Mutators
    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
    }

    func setAutoShow(_ value: Bool) {
        autoShow = value
        defaults.set(value, forKey: autoShowKey)
    }

    func setShowWhenEmpty(_ value: Bool) {
        showWhenEmpty = value
        defaults.set(value, forKey: showWhenEmptyKey)
    }
}
