import Foundation

/// M9 FR-70：一筆錄音的覆盤按鈕該長什麼樣，由「這筆錄音現有哪些 session」決定。
///
/// 規則：live 場已經存在時，**不提供補做**——live 是當下真的跑過的那一場，事後再補一份
/// replay 只會讓兩份同構資料互相冒充「這場會議的覆盤」。所以有 live → 只給「查看」。
/// 只有 replay（沒 live）→ 查看＋重新產生：同一份逐字稿的多次 replay 並存，正是 prompt
/// 調校的 A/B 對照（FR-59），要留著。
///
/// **這是狀態判斷，不是永久規則**：live 場被刪掉（覆盤頁批次刪除）之後，這筆錄音就回到
/// 「沒有 live」的狀態，「產生」按鈕自然回來——不需要任何解鎖旗標或例外路徑。
enum CopilotReviewButtons {
    enum State: Equatable {
        /// 這筆錄音沒有任何 copilot session → 只給「產生」。
        case generate
        /// 有 live 場 → 只給「查看」（開 `latest` 那場）。
        case viewOnly(latest: UUID)
        /// 只有 replay → 「查看」＋「重新產生」（舊 replay 不覆蓋，A/B 保留）。
        case viewAndRegenerate(latest: UUID)
    }

    /// - Parameter sessions: 同一 `importFingerprint` 底下的全部 session（不必先排序）。
    static func state(sessions: [(id: UUID, sourceRaw: String, startedAt: Date)]) -> State {
        // 「查看」一律開最新那場——不論它是 live 還是後補的 replay。
        guard let latest = sessions.max(by: { $0.startedAt < $1.startedAt }) else { return .generate }
        let hasLive = sessions.contains { $0.sourceRaw == "live" }
        return hasLive ? .viewOnly(latest: latest.id) : .viewAndRegenerate(latest: latest.id)
    }
}
