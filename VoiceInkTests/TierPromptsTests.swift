import XCTest
@testable import VoiceInk

/// M8 AC-33:aboutMe cue 的 tier prompt 變體。
///
/// 純函式(TierPrompts 全是 static),不需 ModelContainer / @MainActor。
final class TierPromptsTests: XCTestCase {

    func testAboutMeTier1LocksToNotes() {
        let s = TierPrompts.tier1SystemAboutMe(persona: "p")
        XCTAssertTrue(s.contains("只能使用"))       // 鐵律:只用筆記與自介
        XCTAssertTrue(s.contains("筆記沒記"))       // 沒記載就直說
        XCTAssertTrue(s.contains("OPENER:"))        // 與既有 parser 相容
        let u = TierPrompts.tier1UserAboutMe(cue: "貢獻?",
            grounding: MeetingGrounding(brief: "", ragExcerpts: ["《專案A》內容"], screenText: nil),
            aboutMeBrief: "後端工程師,主力專案A")
        XCTAssertTrue(u.contains("《專案A》內容"))
        XCTAssertTrue(u.contains("主力專案A"))
    }

    func testAboutMeTier2UncertaintiesSemantics() {
        XCTAssertTrue(TierPrompts.tier2SystemAboutMe(persona: "p").contains("筆記沒覆蓋"))
    }

    /// 自介留空(預設值)→ 不留下一行空的「我的自介:」誤導模型「我沒有自介」。
    func testEmptyAboutMeBriefSkipsLine() {
        let u = TierPrompts.tier1UserAboutMe(cue: "你做過什麼?",
                                             grounding: .empty, aboutMeBrief: "")
        XCTAssertFalse(u.contains("我的自介"))
        XCTAssertTrue(u.contains("你做過什麼?"), "cue 行一定在")
    }

    /// tier2 user 變體照既有 tier2User 契約帶入 Tier 1 草稿(AC-8),外加自介行。
    func testAboutMeTier2UserCarriesDraftAndBrief() {
        let draft = Tier1Draft(opener: "我主導過訂單分庫", bullets: ["訂單分庫", "P99 800→120ms", ""])
        let u = TierPrompts.tier2UserAboutMe(
            cue: "你的貢獻?", draft: draft,
            grounding: MeetingGrounding(brief: "", ragExcerpts: ["《訂單分庫》筆記"], screenText: nil),
            aboutMeBrief: "後端工程師")
        XCTAssertTrue(u.contains("我主導過訂單分庫"), "Tier1 草稿帶入")
        XCTAssertTrue(u.contains("《訂單分庫》筆記"), "接地帶入")
        XCTAssertTrue(u.contains("後端工程師"), "自介帶入")
    }
}
