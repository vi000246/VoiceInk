import XCTest
@testable import VoiceInk

/// Plan #1（語音模式編輯後貼上）：外部編輯器 round-trip 的行為（用非互動假命令模擬「編輯」）。
final class ExternalEditorReviewRunnerTests: XCTestCase {

    func testRoundTripsFileContent() async throws {
        // 假編輯器：把檔案內容改寫成 EDITED。
        let out = try await ExternalEditorReviewRunner.review(
            text: "original", command: #"sh -c 'printf EDITED > {file}'"#)
        XCTAssertEqual(out, "EDITED")
    }

    func testNoOpEditorReturnsOriginalText() async throws {
        // 命令不動檔案（true）→ 讀回原內容（含空白路徑也不會壞）。
        let out = try await ExternalEditorReviewRunner.review(text: "原始逐字稿", command: "true")
        XCTAssertEqual(out, "原始逐字稿")
    }

    func testNonZeroExitThrows() async {
        do {
            _ = try await ExternalEditorReviewRunner.review(text: "x", command: "sh -c 'exit 3'")
            XCTFail("非零離開應 throw")
        } catch ExternalEditorReviewError.nonZeroExit(let status) {
            XCTAssertEqual(status, 3)
        } catch {
            XCTFail("預期 nonZeroExit，實際：\(error)")
        }
    }

    func testEmptyCommandThrows() async {
        do {
            _ = try await ExternalEditorReviewRunner.review(text: "x", command: "   ")
            XCTFail("空命令應 throw")
        } catch ExternalEditorReviewError.emptyCommand {
            // ok
        } catch {
            XCTFail("預期 emptyCommand，實際：\(error)")
        }
    }
}
