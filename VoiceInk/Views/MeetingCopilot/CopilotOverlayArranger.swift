import Foundation

/// overlay 上一則 cue 的視覺強調層級(FR-26)。
enum CopilotOverlayEmphasis: Equatable {
    /// 最新未回答——opener 最大字級單獨呈現的那一則。
    case focus
    /// 較舊未回答——縮為單行、次要字級。
    case recent
    /// 已回答——下沉變灰。
    case answered
}

/// cue 排列純函式:由新到舊、**最新一則恆為 focus**、截斷至 maxCount。
/// generic over C —— 測試用素 struct,view 用 `MeetingLiveCue`(SwiftData @Model)。
///
/// 為什麼最新一則已回答也保持 focus:Tier 2 完成的瞬間 cue 轉 `.answered`,
/// 若因此降級成單行,**深度分析剛寫完就被收合**——使用者根本來不及讀
/// (2026-07-13 實測回報「沒跑完視窗裡的字就不見」)。內容保持展開,
/// 直到更新的 cue 進來自然接手 focus。
enum CopilotOverlayArranger {
    static func arrange<C>(
        _ cues: [C],
        askedAt: (C) -> Date,
        isAnswered: (C) -> Bool,
        maxCount: Int
    ) -> [(cue: C, emphasis: CopilotOverlayEmphasis)] {
        guard maxCount > 0 else { return [] }
        let newestFirst = cues.sorted { askedAt($0) > askedAt($1) }.prefix(maxCount)
        return newestFirst.enumerated().map { index, cue in
            if index == 0 { return (cue, .focus) }
            return (cue, isAnswered(cue) ? .answered : .recent)
        }
    }
}
