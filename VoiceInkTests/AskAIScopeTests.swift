import XCTest
@testable import VoiceInk

final class AskAIScopeTests: XCTestCase {
    /// 🔴 漏洞回歸鎖：.all 絕不可回到 nil（nil = 不過濾 = obsidian 塊漏進預設查詢）。
    func testAllSourceFilterIsExplicitTranscriptKinds() {
        XCTAssertEqual(AskAISourceFilter.all.sources, ["dictation", "recorder", "meeting"])
        XCTAssertEqual(AskAISourceFilter.voice.sources, ["dictation"])
        XCTAssertEqual(AskAISourceFilter.recorder.sources, ["recorder", "meeting"])
    }

    func testScopeComposerCombinations() {
        XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: true, notesOn: false, filter: .all),
                       ["dictation", "recorder", "meeting"])
        XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: false, notesOn: true, filter: .all),
                       ["obsidian"])
        XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: true, notesOn: true, filter: .voice),
                       ["dictation", "obsidian"])
        XCTAssertEqual(AskAIScopeComposer.sources(transcriptsOn: false, notesOn: false, filter: .all),
                       [], "UI 防呆之外的最後防線：空集合 = 檢索空")
    }
}
