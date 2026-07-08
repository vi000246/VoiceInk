import XCTest
@testable import VoiceInk

final class AskAIChunkerTests: XCTestCase {

    func testShortTextSingleChunk() {
        let drafts = TranscriptChunker.chunks(for: "只有一句話的短逐字稿。")
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].index, 0)
        XCTAssertEqual(drafts[0].text, "只有一句話的短逐字稿。")
    }

    func testChunksRespectTokenBudget() {
        // 100 段 × ~40 tokens 的中文段落 → 多塊,每塊 ≤ maxTokens(含 overlap 裕度驗證上限用 max)。
        let paragraph = String(repeating: "這是一段大約四十個字的測試內容,用來驗證切塊尺寸。", count: 2)
        let text = Array(repeating: paragraph, count: 100).joined(separator: "\n")
        let drafts = TranscriptChunker.chunks(for: text, targetTokens: 450, maxTokens: 512)
        XCTAssertGreaterThan(drafts.count, 5)
        for d in drafts {
            // overlap 最多 ~10% target,塊本體 ≤ target → 上限放 max + 10% 裕度。
            XCTAssertLessThanOrEqual(TokenEstimator.estimate(d.text), 512 + 64, "塊 \(d.index) 超出預算")
        }
    }

    func testSpeakerTurnsStayIntact() {
        let segments = [
            SpeakerSegment(speaker: "1", text: "大家好,今天討論排程。", start: 0, end: 5),
            SpeakerSegment(speaker: "2", text: "我認為下週三比較合適。", start: 5, end: 10),
            SpeakerSegment(speaker: "1", text: "好,那就下週三。", start: 10, end: 12)
        ]
        let drafts = TranscriptChunker.chunks(for: "ignored", speakerSegments: segments)
        XCTAssertEqual(drafts.count, 1)   // 三短輪次 → 單塊
        XCTAssertTrue(drafts[0].text.contains("講者1：大家好,今天討論排程。"))
        XCTAssertTrue(drafts[0].text.contains("講者2：我認為下週三比較合適。"))
        // 每個輪次都完整出現(不被切斷)。
        for seg in segments {
            XCTAssertTrue(drafts[0].text.contains(seg.text))
        }
    }

    func testChunkIndicesAreStableAndOrdered() {
        let text = Array(repeating: "測試段落內容重複很多次以產生多個塊。", count: 300).joined(separator: "\n")
        let drafts = TranscriptChunker.chunks(for: text)
        XCTAssertEqual(drafts.map(\.index), Array(0..<drafts.count))
    }

    func testOversizedSingleUnitHardSplits() {
        // 單一超長段落(無換行)→ 硬切成多塊,不丟內容長度。
        let huge = String(repeating: "字", count: 2000)   // ~2000 tokens(CJK 1:1)
        let drafts = TranscriptChunker.chunks(for: huge, targetTokens: 450, maxTokens: 512)
        XCTAssertGreaterThan(drafts.count, 2)
        XCTAssertEqual(drafts.map(\.text).joined().count, 2000)
    }
}
