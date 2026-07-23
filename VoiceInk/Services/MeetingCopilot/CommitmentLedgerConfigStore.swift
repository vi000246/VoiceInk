import Foundation
import Combine

/// M15 承諾帳本的設定。樣式鏡射 `MeetingCopilotConfigStore`:
/// `@Published private(set)` + `…V1` key + `set…()` mutator + 可注入後端
/// (測試一律注入 `InMemoryDefaults`,不得碰 `.standard`)。
@MainActor
final class CommitmentLedgerConfigStore: ObservableObject {

    static let shared = CommitmentLedgerConfigStore()

    // MARK: - Keys

    private let enabledKey = "commitmentLedgerEnabledV1"
    private let liveToastKey = "commitmentLedgerLiveToastV1"
    private let llmConfirmKey = "commitmentLedgerLLMConfirmV1"

    // MARK: - Settings

    /// 總開關。**預設 true**:承諾外部化是本功能存在的理由,不該藏在設定裡等人發現。
    /// 關閉時 live controller 不接偵測器 → local 段零額外 LLM 呼叫。
    @Published private(set) var enabled: Bool = true

    /// 記帳當下的 3 秒輕量通知(「已記下承諾:…」)。**預設 true**。
    /// overlay 的「🤝N」計數恆顯示(零成本);這顆只管通知——overlay 藏起來時的唯一即時回饋。
    @Published private(set) var liveToastEnabled: Bool = true

    /// 詞表命中後是否交 LLM 確認。**預設 true**。
    /// 關閉 = 純詞表記帳(記 committed 原文、標 unconfirmed)——零 LLM 成本,但誤記率高。
    @Published private(set) var llmConfirmEnabled: Bool = true

    // MARK: - Init

    private let defaults: MeetingCopilotDefaults

    init(defaults: MeetingCopilotDefaults = UserDefaults.standard) {
        self.defaults = defaults
        enabled = (defaults.object(forKey: enabledKey) as? Bool) ?? true
        liveToastEnabled = (defaults.object(forKey: liveToastKey) as? Bool) ?? true
        llmConfirmEnabled = (defaults.object(forKey: llmConfirmKey) as? Bool) ?? true
    }

    // MARK: - Mutators

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: enabledKey)
    }

    func setLiveToastEnabled(_ value: Bool) {
        liveToastEnabled = value
        defaults.set(value, forKey: liveToastKey)
    }

    func setLLMConfirmEnabled(_ value: Bool) {
        llmConfirmEnabled = value
        defaults.set(value, forKey: llmConfirmKey)
    }
}
