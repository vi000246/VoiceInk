import XCTest
@testable import VoiceInk

@MainActor
final class MeetingExportTests: XCTestCase {

    private func input(sourceLabel: String?) -> VaultExportService.ExportInput {
        VaultExportService.ExportInput(
            analysis: "## 重點\n- A", rawTranscript: "line one",
            categoryName: "會議", deviceName: nil, sourceLabel: sourceLabel,
            date: Date(timeIntervalSince1970: 0),
            transcriptionModel: "whisper", enhancementModel: "claude", confidence: nil)
    }

    func testBuildMarkdownEmitsSourceLabelWhenSet() {
        let md = VaultExportService.shared.buildMarkdown(input(sourceLabel: "會議 · Zoom"))
        XCTAssertTrue(md.contains("來源: 會議 · Zoom"))
        // Still inside the frontmatter block (before the closing ---), right after source_device.
        XCTAssertTrue(md.contains("source_device: \"\"\n來源: 會議 · Zoom\ncategory: \"會議\""))
    }

    func testBuildMarkdownOmitsSourceLineWhenNil() {
        let md = VaultExportService.shared.buildMarkdown(input(sourceLabel: nil))
        XCTAssertFalse(md.contains("來源:"))
    }
}
