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

/// cue 排列純函式:由新到舊、focus 只給最新未回答者、截斷至 maxCount。
/// generic over C —— 測試用素 struct,view 用 `MeetingLiveCue`(SwiftData @Model)。
enum CopilotOverlayArranger {
    static func arrange<C>(
        _ cues: [C],
        askedAt: (C) -> Date,
        isAnswered: (C) -> Bool,
        maxCount: Int
    ) -> [(cue: C, emphasis: CopilotOverlayEmphasis)] {
        guard maxCount > 0 else { return [] }
        let newestFirst = cues.sorted { askedAt($0) > askedAt($1) }.prefix(maxCount)
        var focusAssigned = false
        return newestFirst.map { cue in
            if isAnswered(cue) {
                return (cue, .answered)
            }
            if !focusAssigned {
                focusAssigned = true
                return (cue, .focus)
            }
            return (cue, .recent)
        }
    }
}
