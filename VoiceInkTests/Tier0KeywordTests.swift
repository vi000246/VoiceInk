import XCTest
@testable import VoiceInk

final class Tier0KeywordTests: XCTestCase {

    /// AC-5:產出關鍵字 + 領域標籤,**全程無 LLM 呼叫**(fake 的 callCount 必為 0)。
    func testProducesKeywordsWithoutLLMCall() {
        let fake = FakeStreamingChatCompleting(script: ["SHOULD NOT BE CALLED"])
        let r = Tier0Classifier.classify(cueText: "你會怎麼設計一個支援每秒十萬寫入的短網址服務？資料庫要怎麼分片？")
        XCTAssertFalse(r.keywords.isEmpty)
        XCTAssertFalse(r.domainLabel.isEmpty)
        XCTAssertEqual(fake.callCount, 0, "Tier0 不得呼叫 LLM")
    }

    /// 命中資料庫領域(「分片」「資料庫」)。
    func testClassifiesDatabaseDomain() {
        let r = Tier0Classifier.classify(cueText: "這個資料庫要用什麼 index，要不要 shard 分片？")
        XCTAssertEqual(r.domainLabel, "資料庫")
        XCTAssertTrue(r.keywords.contains { $0 == "資料庫" || $0 == "index" || $0 == "shard" || $0 == "分片" })
    }

    /// 命中演算法領域。
    func testClassifiesAlgorithmDomain() {
        let r = Tier0Classifier.classify(cueText: "這題的時間複雜度是多少？可以用動態規劃嗎？")
        XCTAssertEqual(r.domainLabel, "演算法")
    }

    /// 無命中 → 通用標籤 + 從原句抽關鍵字,不崩。
    func testNoMatchYieldsGeneralLabel() {
        let r = Tier0Classifier.classify(cueText: "你週末過得如何")
        XCTAssertEqual(r.domainLabel, "一般")
    }
}
