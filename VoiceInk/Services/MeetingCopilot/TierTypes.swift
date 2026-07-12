import Foundation

/// Tier 2 的 follow-up 預判(結構化,非散文——讓 overlay 排成可掃視清單)。
/// M3 內部型別;寫回 `MeetingLiveCue.tier2FollowUps`([String],M2 已定)時序列化成顯示字串。
struct FollowUp: Codable, Equatable {
    var question: String
    var oneLineAnswer: String

    /// 寫回 M2 的 `[String]` 欄位用的顯示字串。
    var displayLine: String { "\(question) → \(oneLineAnswer)" }
}

/// Tier 0:本機關鍵字(< 0.5s,不呼叫 LLM)。
struct Tier0Result: Equatable {
    var domainLabel: String
    var keywords: [String]
    static let empty = Tier0Result(domainLabel: "", keywords: [])
}

/// Tier 1:開口稿。`opener` 是一句可直接說出口的話;`bullets` 恰 3 個。
struct Tier1Draft: Equatable {
    var opener: String
    var bullets: [String]

    /// Tier 2 的 user message 帶入的完整草稿文字(AC-8)。
    var draftText: String {
        ([opener] + bullets.map { "- \($0)" }).joined(separator: "\n")
    }
}

/// Tier 2:深度分析 + follow-up 預判 + 不確定項。
struct Tier2Analysis: Equatable {
    var analysis: String
    var followUps: [FollowUp]
    var uncertainties: [String]
}

/// 組 prompt 用的接地快照(brief + RAG 片段 + 螢幕 OCR 文字)。全部靜默降級。
struct MeetingGrounding: Equatable {
    var brief: String
    var ragExcerpts: [String]   // 已編號的檢索片段([1] … [n])
    var screenText: String?

    static let empty = MeetingGrounding(brief: "", ragExcerpts: [], screenText: nil)

    /// 注入 user block 的接地段落(空來源自動略過)。
    func userBlock() -> String {
        var lines: [String] = []
        if !brief.isEmpty {
            lines.append("會前 brief:")
            lines.append(brief)
            lines.append("")
        }
        if !ragExcerpts.isEmpty {
            lines.append("我過去的相關逐字稿/筆記(僅供參考,可能過時):")
            for (i, e) in ragExcerpts.enumerated() {
                lines.append("[\(i + 1)] \(e)")
            }
            lines.append("")
        }
        if let screenText, !screenText.isEmpty {
            lines.append("對方目前分享的畫面(OCR,可能有誤):")
            lines.append(String(screenText.prefix(1500)))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
