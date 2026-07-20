import Foundation
import Combine

/// 晨間簡報(M13)的設定。
///
/// 樣式鏡射 `MeetingPackConfigStore`:`@Published private(set)` + `…V1` key + `set…()` mutator,
/// 後端走 `MeetingCopilotDefaults` 抽象,測試用 `InMemoryDefaults` 完全隔離。
@MainActor
final class MorningBriefingConfigStore: ObservableObject {

    static let shared = MorningBriefingConfigStore()

    // MARK: - Keys
    private let enabledKey = "morningBriefingEnabledV1"
    private let timeKey = "morningBriefingTimeMinutesV1"
    private let aiSuggestionKey = "morningBriefingAISuggestionV1"
    /// 每日只自動彈一次的 semaphore("yyyy-MM-dd";手動看過也蓋章)。
    private let lastShownDayKey = "morningBriefingLastShownDayV1"

    /// 08:30(分鐘制;`MeetingCopilotDefaults` 沒有 double 介面,存 Int 分鐘最單純)。
    static let defaultTimeMinutes = 8 * 60 + 30

    // MARK: - Settings
    /// 總開關。預設 **true**——簡報是每天一次的低頻主動提示,預設開啟才符合
    /// 「一天的起點被送到眼前」的核心價值(ADHD 使用者不會記得自己去開)。
    @Published private(set) var enabled: Bool = true
    /// 自動顯示時刻(自 00:00 起算的分鐘數,0..<1440)。
    @Published private(set) var timeMinutes: Int = MorningBriefingConfigStore.defaultTimeMinutes
    /// 「今日第一件事」AI 建議。預設 true;LLM 失敗只是該區塊省略,不影響簡報本體。
    @Published private(set) var aiSuggestionEnabled: Bool = true
    /// 最後一次顯示的日期 key(nil = 從未顯示)。
    @Published private(set) var lastShownDay: String?

    private let defaults: MeetingCopilotDefaults

    init(defaults: MeetingCopilotDefaults = UserDefaults.standard) {
        self.defaults = defaults
        enabled = (defaults.object(forKey: enabledKey) as? Bool) ?? true
        let storedTime = defaults.object(forKey: timeKey) as? Int
        // 範圍外的殘值(手改 plist 等)靜默回預設——排程器拿到負分鐘會排出過去時刻,永遠 catch-up。
        timeMinutes = storedTime.flatMap { (0..<1440).contains($0) ? $0 : nil }
            ?? Self.defaultTimeMinutes
        aiSuggestionEnabled = (defaults.object(forKey: aiSuggestionKey) as? Bool) ?? true
        lastShownDay = defaults.string(forKey: lastShownDayKey)
    }

    // MARK: - Mutators

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
    }

    func setTimeMinutes(_ value: Int) {
        let clamped = min(max(value, 0), 1439)
        timeMinutes = clamped
        defaults.set(clamped, forKey: timeKey)
    }

    func setAISuggestionEnabled(_ value: Bool) {
        aiSuggestionEnabled = value
        defaults.set(value, forKey: aiSuggestionKey)
    }

    func markShown(day: String) {
        lastShownDay = day
        defaults.set(day, forKey: lastShownDayKey)
    }
}
