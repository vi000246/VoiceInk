import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class MeetingImportTests: XCTestCase {
    func testStageMeetingFileFingerprintsAndCopies() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtg-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("250707_1030 會議Zoom.m4a")
        try Data([1, 2, 3, 4]).write(to: src)

        let staged = try await RecorderImportService.shared.stageMeetingFile(src)
        defer { try? FileManager.default.removeItem(at: staged.stagedURL) }   // 清掉 staging 殘留

        XCTAssertEqual(staged.fingerprint, try ImportLedger.contentFingerprint(for: src))
        XCTAssertEqual(staged.displayName, "250707_1030 會議Zoom.m4a")
        XCTAssertEqual(staged.byteSize, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stagedURL.path))
        XCTAssertTrue(staged.stagedURL.path.contains("RecorderImports"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))   // stage 不動原檔
    }

    func testStagedFileNameKeepsRecordingTimeStamp() async throws {
        // capture 檔名帶 yyMMdd_HHmm 開錄時間戳；stage 後 displayName 原樣保留,
        // 供既有 RecorderRecordingTime.parse 回收會議開始時間。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mtg-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("250707_1030 會議.m4a")
        try Data([9]).write(to: src)

        let staged = try await RecorderImportService.shared.stageMeetingFile(src)
        defer { try? FileManager.default.removeItem(at: staged.stagedURL) }

        XCTAssertNotNil(RecorderRecordingTime.parse(fromFileName: staged.displayName))
    }
}
