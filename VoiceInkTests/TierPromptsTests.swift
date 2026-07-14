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

    /// 🟠 回歸鎖（2026-07-14）：aboutMe 的**片段標題不得自打嘴巴**。
    ///
    /// aboutMe 的 system prompt 把筆記立為「唯一事實來源、沒記載就說筆記沒記」。若 user block
    /// 的片段標題還沿用技術 cue 那句「僅供參考，**可能過時**」，同一則訊息裡就有兩種相反語氣 ——
    /// 模型會傾向不敢引用筆記、動不動說「筆記沒記」，正好毀掉這個功能存在的理由
    /// （被問到自己的專案時腦袋空白，要的就是筆記裡的事實）。
    func testAboutMeLabelsNotesAsAuthoritativeNotStale() {
        let g = MeetingGrounding(brief: "", ragExcerpts: ["《專案A》我主導了快取重構，P99 800→120ms"],
                                 screenText: nil)

        for u in [TierPrompts.tier1UserAboutMe(cue: "你有什麼貢獻?", grounding: g, aboutMeBrief: ""),
                  TierPrompts.tier2UserAboutMe(cue: "你有什麼貢獻?",
                                               draft: Tier1Draft(opener: "o", bullets: []),
                                               grounding: g, aboutMeBrief: "")] {
            XCTAssertTrue(u.contains("唯一事實來源"), "aboutMe 的筆記是唯一事實來源，標題要這樣說")
            XCTAssertFalse(u.contains("可能過時"), "不能同時說「唯一事實來源」又說「可能過時」")
            XCTAssertTrue(u.contains("我主導了快取重構"), "片段本身照樣帶入")
        }

        // 技術 cue 的歷史逐字稿**確實**可能過時 —— 那句話留著，不是回歸。
        let technical = TierPrompts.tier1User(cue: "怎麼設計快取?", grounding: g)
        XCTAssertTrue(technical.contains("可能過時"), "技術 cue 的歷史逐字稿標題不變")
    }
}
