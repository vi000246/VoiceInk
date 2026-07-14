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
    /// - Parameters:
    ///   - pinnedId: 展開中(使用者正在閱讀)的 cue 身分;nil = 無展開保護,行為與 M8 前完全一致。
    ///   - id: cue 的 hashable 身分擷取器(view 傳 `cue.id`、測試傳素 struct 的欄位)。
    ///     與 `pinnedId` 必須成對給,缺一則不啟用保護。
    static func arrange<C>(
        _ cues: [C],
        askedAt: (C) -> Date,
        isAnswered: (C) -> Bool,
        maxCount: Int,
        pinnedId: AnyHashable? = nil,
        id: ((C) -> AnyHashable)? = nil
    ) -> [(cue: C, emphasis: CopilotOverlayEmphasis)] {
        guard maxCount > 0 else { return [] }
        let newestFirst = cues.sorted { askedAt($0) > askedAt($1) }
        var shown = Array(newestFirst.prefix(maxCount))

        // AC-37 閱讀保護:展開中的 cue = 使用者正在讀它。新 cue 一直進來時,它會被
        // maxCount 從尾端擠掉——等於「讀到一半整段字消失」,正是 M8 要修的痛點。
        // 作法:pinned 不在截斷範圍內時,讓 shown 中**最舊的非 pinned** 那則讓位
        //(shown 已由新到舊排序 → 末項就是最舊者,且必為非 pinned,因 pinned 不在其中)。
        // 總數維持 maxCount,輸出仍由新到舊。
        // 註:maxCount == 1 且 pinned 非最新時,讓位者就是最新那則——展開中的閱讀保護
        // 勝過「恆顯示最新」,這是刻意的取捨(單格 overlay 本就只能二選一)。
        if let pinnedId, let id,
           !shown.contains(where: { id($0) == pinnedId }),
           let pinned = newestFirst.first(where: { id($0) == pinnedId }) {
            if !shown.isEmpty { shown.removeLast() }
            shown.append(pinned)
            shown.sort { askedAt($0) > askedAt($1) }
        }

        // emphasis 規則不變:index 0 = focus(最大字級的載體),其餘依已回答與否下沉。
        // pinned 若非最新 → 照舊拿 .recent/.answered;「展開哪一則」由 view 的
        // expandedCueId 決定,emphasis 只管字級。
        return shown.enumerated().map { index, cue in
            if index == 0 { return (cue, .focus) }
            return (cue, isAnswered(cue) ? .answered : .recent)
        }
    }
}
