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

/// RAG 片段在 user prompt 裡的**來源標題**。
///
/// 為什麼要分兩種:aboutMe 的片段**全部**來自個人筆記(`sources: ["obsidian"]`),而 aboutMe 的
/// system prompt 把它們立為「**唯一事實來源**、沒記載就說筆記沒記」。標題若還沿用技術 cue 那句
/// 「僅供參考,可能過時」,同一則 user message 裡就有兩種相反的語氣——模型會傾向不敢引用筆記、
/// 動不動說「筆記沒記」,正好毀掉這個功能存在的理由(被問到自己的專案時腦袋空白,要的就是
/// 筆記裡的事實)。2026-07-14 修。
enum MeetingExcerptLabel {
    /// 技術 cue:歷史逐字稿。**確實**可能過時——那句話留著是對的。
    case history
    /// aboutMe:我自己寫的筆記。可信,且是這一題的唯一事實來源。
    case personalNotes

    var title: String {
        switch self {
        case .history:
            return "我過去的相關逐字稿/筆記(僅供參考,可能過時):"
        case .personalNotes:
            return "我的筆記(我自己寫的,是回答這題的**唯一事實來源**;這裡沒寫到的,就是我沒記):"
        }
    }
}

/// 組 prompt 用的接地快照(brief + RAG 片段 + 螢幕 OCR 文字)。全部靜默降級。
struct MeetingGrounding: Equatable {
    var brief: String
    var ragExcerpts: [String]   // 已編號的檢索片段([1] … [n])
    var screenText: String?
    /// RAG 靜默降級的原因(覆盤用;nil = 未失敗)。**不進 prompt**,只回寫 cue 的 groundingNote。
    var ragError: String? = nil

    static let empty = MeetingGrounding(brief: "", ragExcerpts: [], screenText: nil)

    /// 注入 user block 的接地段落(空來源自動略過)。
    /// - Parameter excerptLabel: RAG 片段的來源標題。**aboutMe 必須傳 `.personalNotes`**
    ///   ——見 `MeetingExcerptLabel` 的說明(標題與 system prompt 不同調會讓模型不敢引用筆記)。
    func userBlock(excerptLabel: MeetingExcerptLabel = .history) -> String {
        var lines: [String] = []
        if !brief.isEmpty {
            lines.append("會前 brief:")
            lines.append(brief)
            lines.append("")
        }
        if !ragExcerpts.isEmpty {
            lines.append(excerptLabel.title)
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
