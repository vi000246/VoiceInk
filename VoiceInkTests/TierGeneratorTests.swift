import XCTest
@testable import VoiceInk

final class TierGeneratorTests: XCTestCase {

    // MARK: - Tier 1 parser（AC-6）

    func testTier1ParserProducesOpenerAndExactlyThreeBullets() {
        let raw = "OPENER: 我會先確認 QPS 與讀寫比再決定要不要分片。\n- 先問清楚規模\n- 讀多寫少可加快取\n- 寫爆才考慮分庫"
        let draft = TierParsers.parseTier1(raw)
        XCTAssertEqual(draft.opener, "我會先確認 QPS 與讀寫比再決定要不要分片。")
        XCTAssertEqual(draft.bullets.count, 3)
        XCTAssertEqual(draft.bullets[0], "先問清楚規模")
    }

    /// 模型多給 5 個 bullet → 取前 3。
    func testTier1ParserTruncatesToThreeBullets() {
        let raw = "OPENER: 開口\n- a\n- b\n- c\n- d\n- e"
        let draft = TierParsers.parseTier1(raw)
        XCTAssertEqual(draft.bullets, ["a", "b", "c"])
    }

    /// 模型少給 → 補空到 3(overlay 版面穩定)。
    func testTier1ParserPadsToThreeBullets() {
        let draft = TierParsers.parseTier1("OPENER: 開口\n- 只有一個要點")
        XCTAssertEqual(draft.bullets.count, 3)
    }

    // MARK: - Tier 2 parser

    func testTier2ParserDecodesJSON() {
        let raw = #"""
        {"analysis":"先分片再加快取","followUps":[{"question":"要用一致性雜湊嗎？","oneLineAnswer":"是，減少 rehash"}],"uncertainties":["實際 QPS 需壓測"]}
        """#
        let a = TierParsers.parseTier2(raw)
        XCTAssertEqual(a.analysis, "先分片再加快取")
        XCTAssertEqual(a.followUps.count, 1)
        XCTAssertEqual(a.followUps[0].question, "要用一致性雜湊嗎？")
        XCTAssertEqual(a.uncertainties, ["實際 QPS 需壓測"])
    }

    /// code fence 要能剝掉。
    func testTier2ParserStripsCodeFence() {
        let raw = "```json\n{\"analysis\":\"x\",\"followUps\":[],\"uncertainties\":[]}\n```"
        XCTAssertEqual(TierParsers.parseTier2(raw).analysis, "x")
    }

    /// 非 JSON（串流被中斷）→ 全文當 analysis，不丟資訊。
    func testTier2ParserDegradesGracefully() {
        let a = TierParsers.parseTier2("這只是一段沒收完的純文字")
        XCTAssertEqual(a.analysis, "這只是一段沒收完的純文字")
        XCTAssertTrue(a.followUps.isEmpty)
    }

    // MARK: - Prompt 契約（AC-14）

    /// M9 FR-73:不得編造的鐵律位於**三種風格共用的開頭段**,所以每一種 style 都必須帶著它
    /// ——風格只換 analysis 的格式,不會、也不該換掉這條紅線。
    func testDeepSystemPromptForbidsFabrication() {
        for style in MeetingDeepStyle.allCases {
            let sys = TierPrompts.tier2System(persona: "你是後端專家", style: style)
            XCTAssertTrue(sys.contains("不要") && (sys.contains("捏造") || sys.contains("編造")),
                          "Tier2 system prompt 必須含不得編造禁令(FR-27),style=\(style)")
            XCTAssertTrue(sys.contains("uncertainties"), "style=\(style)")
        }
    }

    /// Tier2 user block 帶入 Tier1 草稿全文（AC-8 的 prompt 半部）。
    func testTier2UserCarriesTier1Draft() {
        let draft = Tier1Draft(opener: "開口稿內容", bullets: ["a", "b", "c"])
        let user = TierPrompts.tier2User(cue: "設計短網址", draft: draft,
                                         grounding: .empty)
        XCTAssertTrue(user.contains("開口稿內容"))
        XCTAssertTrue(user.contains("設計短網址"))
    }

    /// grounding userBlock 空來源自動略過。
    func testGroundingUserBlockSkipsEmptySources() {
        XCTAssertTrue(MeetingGrounding.empty.userBlock().isEmpty)
        let g = MeetingGrounding(brief: "訂單分庫 review", ragExcerpts: ["過去討論過分片"], screenText: nil)
        let block = g.userBlock()
        XCTAssertTrue(block.contains("訂單分庫 review"))
        XCTAssertTrue(block.contains("[1] 過去討論過分片"))
    }
}
