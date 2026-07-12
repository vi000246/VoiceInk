import XCTest
@testable import VoiceInk

@MainActor
final class StreamChatDispatchTests: XCTestCase {
    /// fake completer 依腳本吐 delta;累積字串在結束後套 filter 一次(不逐 delta)。
    func testFakeStreamingAccumulatesAndFiltersOnce() async throws {
        let fake = FakeStreamingChatCompleting(script: ["<think>ignore</think>可", "以", "開口"])
        var out = ""
        for try await d in fake.stream(system: "s", user: "u") { out += d }
        // raw 串流含 <think>;呼叫端負責在結束後 filter
        XCTAssertEqual(AIEnhancementOutputFilter.filter(out), "可以開口")
        XCTAssertEqual(fake.callCount, 1)
        XCTAssertEqual(fake.lastUser, "u")
    }

    /// 錯誤沿 AsyncThrowingStream 傳出。
    func testFakeStreamingPropagatesError() async {
        let fake = FakeStreamingChatCompleting(error: StreamingChatError.http(500, "boom"))
        do {
            for try await _ in fake.stream(system: "s", user: "u") {}
            XCTFail("應 throw")
        } catch let StreamingChatError.http(code, _) {
            XCTAssertEqual(code, 500)
        } catch { XCTFail("錯誤型別: \(error)") }
    }
}
