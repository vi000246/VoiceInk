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

    /// M8 AC-46:四個 tier system prompt 都要指定輸出語言。
    ///
    /// 英文會議時,cue 原句與接地片段全是英文——模型會很自然地跟著用英文回答,
    /// 於是 overlay 上的「開口稿」變成一句我唸不順的英文。開口稿的用途是**直接照著唸**,
    /// 語言錯了整個功能就報廢,所以這是 prompt 層的硬約束,不是「通常會對」的期待。
    func testAllTierSystemPromptsCarryOutputLanguage() {
        for s in [TierPrompts.tier1System(persona: "p", outputLanguage: "繁體中文"),
                  TierPrompts.tier2System(persona: "p", outputLanguage: "繁體中文"),
                  TierPrompts.tier1SystemAboutMe(persona: "p", outputLanguage: "繁體中文"),
                  TierPrompts.tier2SystemAboutMe(persona: "p", outputLanguage: "繁體中文")] {
            XCTAssertTrue(s.contains("以繁體中文回答"))
        }
    }

    /// 目標語言換成英文 → prompt 跟著換(不是硬編繁中)。
    func testOutputLanguageFollowsTarget() {
        let s = TierPrompts.tier1System(persona: "p", outputLanguage: "English")
        XCTAssertTrue(s.contains("以English回答"))
        XCTAssertFalse(s.contains("以繁體中文回答"))
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
