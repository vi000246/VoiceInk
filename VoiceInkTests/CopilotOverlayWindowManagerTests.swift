import XCTest
import AppKit
@testable import VoiceInk

final class CopilotOverlayWindowManagerTests: XCTestCase {

    // MARK: - FR-24:近鏡頭錨定(純函式)

    func testAnchorRectIsTopCenter() {
        let visible = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let size = NSSize(width: 560, height: 400)
        let rect = CopilotOverlayWindowManager.anchorRect(visibleFrame: visible, size: size)

        XCTAssertEqual(rect.midX, 960, accuracy: 0.5, "水平置中")
        XCTAssertEqual(rect.maxY, 1080 - 12, accuracy: 0.5, "貼齊上緣(近鏡頭),留 12pt")
        XCTAssertEqual(rect.size, size)
    }

    func testAnchorRectOnSecondaryScreenOrigin() {
        let visible = NSRect(x: 1920, y: 200, width: 1440, height: 900)
        let rect = CopilotOverlayWindowManager.anchorRect(
            visibleFrame: visible, size: NSSize(width: 560, height: 400))

        XCTAssertEqual(rect.midX, 1920 + 720, accuracy: 0.5)
        XCTAssertEqual(rect.maxY, 200 + 900 - 12, accuracy: 0.5)
    }

    // MARK: - peek 守衛

    func testKeyRepeatDoesNotRetrigger() {
        var guard_ = CopilotPeekGuard()
        XCTAssertTrue(guard_.registerKeyDown(at: 0.0), "第一發:顯示")
        XCTAssertFalse(guard_.registerKeyDown(at: 0.05), "repeat:忽略")
        XCTAssertFalse(guard_.registerKeyDown(at: 0.10), "repeat:忽略")
        XCTAssertTrue(guard_.registerKeyUp(), "放開:隱藏")
    }

    func testCooldownBlocksRapidRepress() {
        var guard_ = CopilotPeekGuard()
        XCTAssertTrue(guard_.registerKeyDown(at: 0.0))
        XCTAssertTrue(guard_.registerKeyUp())
        XCTAssertFalse(guard_.registerKeyDown(at: 0.3), "0.3s < 0.5s cooldown")
        XCTAssertFalse(guard_.registerKeyUp(), "沒 show 過就不 hide")
        XCTAssertTrue(guard_.registerKeyDown(at: 0.6), "cooldown 過了")
    }

    func testOrphanKeyUpIsIgnored() {
        var guard_ = CopilotPeekGuard()
        XCTAssertFalse(guard_.registerKeyUp())
    }
}
