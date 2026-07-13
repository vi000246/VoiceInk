import Foundation

/// 串流累積字串 → 結構化 tier 結果。純函式,容錯(壞輸入回合理預設)。
enum TierParsers {

    /// Tier 1:`OPENER: …` + `- ` bullets。可容忍模型多給/少給 bullet(取前 3,不足補空)。
    static func parseTier1(_ raw: String) -> Tier1Draft {
        var opener = ""
        var bullets: [String] = []
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if opener.isEmpty, let r = line.range(of: "OPENER:", options: [.caseInsensitive]) {
                opener = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") || line.hasPrefix("-\t") {
                let b = line.dropFirst(1).trimmingCharacters(in: .whitespaces)
                if !b.isEmpty { bullets.append(b) }
            } else if line.hasPrefix("•") {
                let b = line.dropFirst(1).trimmingCharacters(in: .whitespaces)
                if !b.isEmpty { bullets.append(b) }
            }
        }
        // opener 若模型沒給標記,退回取第一行非 bullet 的內容。
        if opener.isEmpty {
            opener = raw.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        }
        // 恰 3 個:多截少補。
        if bullets.count > 3 { bullets = Array(bullets.prefix(3)) }
        while bullets.count < 3 { bullets.append("") }
        return Tier1Draft(opener: opener, bullets: bullets)
    }

    // MARK: - Tier 2 JSON

    private struct RawTier2: Decodable {
        struct RawFollowUp: Decodable { let question: String?; let oneLineAnswer: String? }
        let analysis: String?
        let followUps: [RawFollowUp]?
        let uncertainties: [String]?
    }

    /// Tier 2:JSON(容忍 code fence)。任何失敗 → 把整段 raw 當 analysis(降級但不丟資訊)。
    static func parseTier2(_ raw: String) -> Tier2Analysis {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = trimmed.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawTier2.self, from: data) else {
            // 降級:不是 JSON(或串流被中斷)→ 全文當 analysis,follow-up/uncertainty 留空。
            return Tier2Analysis(analysis: trimmed, followUps: [], uncertainties: [])
        }
        let followUps = (decoded.followUps ?? []).compactMap { f -> FollowUp? in
            let q = (f.question ?? "").trimmingCharacters(in: .whitespaces)
            let a = (f.oneLineAnswer ?? "").trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { return nil }
            return FollowUp(question: q, oneLineAnswer: a)
        }
        let result = Tier2Analysis(
            analysis: (decoded.analysis ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            followUps: followUps,
            uncertainties: (decoded.uncertainties ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        // 防呆:RawTier2 全欄位 optional,「合法 JSON 但鍵名不符」(大小寫、外包一層殼)
        // 會 decode「成功」而全 nil → 三欄皆空。這種情況同樣降級成全文,不能丟資訊
        // ——否則 UI 看起來就是「轉圈完什麼都沒有」。
        if result.analysis.isEmpty && result.followUps.isEmpty && result.uncertainties.isEmpty {
            return Tier2Analysis(analysis: trimmed, followUps: [], uncertainties: [])
        }
        return result
    }
}
