import XCTest
@testable import VoiceInk

final class ObsidianNoteIndexTests: XCTestCase {

    func testStripFrontmatterRemovesYAMLBlock() {
        let md = "---\ntags: [a]\ndate: 2026-01-01\n---\n\n# 標題\n內文段落"
        XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter(md), "# 標題\n內文段落")
        // 沒有 frontmatter 時原樣返回
        XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter("純內容"), "純內容")
        // 只有開頭 --- 沒有收尾 → 不誤刪
        XCTAssertEqual(ObsidianNoteChunking.stripFrontmatter("---\n沒收尾"), "---\n沒收尾")
    }

    func testChunksCarryTitlePrefix() {
        let drafts = ObsidianNoteChunking.chunks(title: "專案A", body: "第一段\n\n第二段")
        XCTAssertFalse(drafts.isEmpty)
        XCTAssertTrue(drafts.allSatisfy { $0.text.hasPrefix("《專案A》") })
    }

    func testDeterministicIdStableAndDistinct() {
        let a1 = ObsidianNoteChunking.noteId(relativePath: "工作/專案A.md")
        let a2 = ObsidianNoteChunking.noteId(relativePath: "工作/專案A.md")
        let b  = ObsidianNoteChunking.noteId(relativePath: "工作/專案B.md")
        XCTAssertEqual(a1, a2, "同路徑恆定")
        XCTAssertNotEqual(a1, b)
    }
}
