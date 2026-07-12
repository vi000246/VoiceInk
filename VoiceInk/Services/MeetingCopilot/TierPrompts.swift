import Foundation

/// Tier 1 / Tier 2 的 system + user prompt 建構(純函式,FR-12)。
///
/// FR-27:Tier 2 system prompt **明確禁止捏造** benchmark 數字/論文/公司名,不確定寫進 uncertainties。
enum TierPrompts {

    // MARK: - Tier 1(開口稿)

    static func tier1System(persona: String) -> String {
        """
        \(persona)
        你正在協助我(聽者)在會議中即時回應對方的問題或質疑。
        目標:讓我能在 2 秒內開口。輸出**極簡**,只給:
        1. 一句「開口稿」——我可以直接照著說出口的第一句話,用來爭取思考時間,不要長。
        2. 恰好 3 個要點,每點一行、以「- 」開頭、每點不超過 20 字。
        嚴格格式(不要任何其他文字、不要 markdown):
        OPENER: <一句可直接說出口的話>
        - <要點一>
        - <要點二>
        - <要點三>
        """
    }

    static func tier1User(cue: String, grounding: MeetingGrounding) -> String {
        var lines: [String] = []
        let g = grounding.userBlock()
        if !g.isEmpty { lines.append(g) }
        lines.append("對方問/說:\(cue)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Tier 2(深度分析 + follow-up 預判)

    static func tier2System(persona: String) -> String {
        """
        \(persona)
        以下是我在會議中被問到的問題,以及我剛才的初步開口稿。請補強成足以應付追問的深度回答。
        **鐵律:不要捏造/編造任何 benchmark 數字、論文名稱、公司名、產品版本或不存在的事實。**
        任何你沒把握的點,不要硬掰——把它列進 uncertainties。
        只輸出 JSON(不要 markdown code fence、不要其他文字),格式:
        {
          "analysis": "<完整分析,可分段>",
          "followUps": [{"question":"<對方很可能接著追問的問題>","oneLineAnswer":"<一句話答案>"}],
          "uncertainties": ["<我不確定、需要實測或查證的點>"]
        }
        followUps 給 2-3 個最可能的追問。
        """
    }

    static func tier2User(cue: String, draft: Tier1Draft, grounding: MeetingGrounding) -> String {
        var lines: [String] = []
        let g = grounding.userBlock()
        if !g.isEmpty { lines.append(g) }
        lines.append("對方問/說:\(cue)")
        lines.append("")
        lines.append("我的初步開口稿:")
        lines.append(draft.draftText)
        return lines.joined(separator: "\n")
    }
}
