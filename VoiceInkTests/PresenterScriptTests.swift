import XCTest
import AppKit
@testable import VoiceInk

/// M7 預設講稿讀稿器的純 seam 測試(FR-33/35/36/37,AC-20~27)。
/// 全部不碰 CoreAudio、不碰真 LLM——本功能本來就與 live pipeline 零耦合。
@MainActor
final class PresenterScriptTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PresenterScriptTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Store(AC-20 / AC-26)

    /// AC-20:講稿 CRUD 跨 store 重建仍在(順序、內容不變)。
    func testPersistsAcrossReload() {
        let store = PresenterScriptStore(defaults: defaults)
        store.add(title: "自我介紹", body: "我是 Logan,後端工程師。")
        store.add(title: "期望待遇", body: "我期望的範圍是…")

        let reloaded = PresenterScriptStore(defaults: defaults)
        XCTAssertEqual(reloaded.scripts.count, 2)
        XCTAssertEqual(reloaded.scripts[0].title, "自我介紹")
        XCTAssertEqual(reloaded.scripts[1].body, "我期望的範圍是…")
    }

    func testUpdateAndDelete() {
        let store = PresenterScriptStore(defaults: defaults)
        store.add(title: "A", body: "bodyA")
        let id = store.scripts[0].id

        store.update(id: id, title: "A2", body: "bodyA2")
        XCTAssertEqual(store.scripts[0].title, "A2")
        XCTAssertEqual(store.scripts[0].body, "bodyA2")

        store.delete(id: id)
        XCTAssertTrue(store.scripts.isEmpty)

        let reloaded = PresenterScriptStore(defaults: defaults)
        XCTAssertTrue(reloaded.scripts.isEmpty)
    }

    /// AC-26:字級調整持久化且夾在 [14, 40]。
    func testFontSizePersistsClamped() {
        let store = PresenterScriptStore(defaults: defaults)
        store.setFontSize(100)                       // 上限夾到 40
        XCTAssertEqual(store.fontSize, 40, accuracy: 0.01)

        let reloaded = PresenterScriptStore(defaults: defaults)
        XCTAssertEqual(reloaded.fontSize, 40, accuracy: 0.01)

        store.setFontSize(2)                         // 下限夾到 14
        XCTAssertEqual(store.fontSize, 14, accuracy: 0.01)
    }

    // MARK: - ReaderModel(AC-21 / AC-22 / AC-27)

    /// AC-21:讀稿檢視顯示選定講稿的正文。
    func testReadingShowsSelectedBody() {
        let a = PresenterScript(title: "A", body: "bodyA")
        let b = PresenterScript(title: "B", body: "bodyB")
        let model = PresenterScriptReaderModel()

        XCTAssertNil(model.body(for: [a, b]))        // 未選 → 清單層
        model.select(a.id)
        XCTAssertEqual(model.body(for: [a, b]), "bodyA")
    }

    /// AC-22:chip 切換講稿,「← 講稿清單」回清單層。
    func testChipSwitchesAndBackReturnsToList() {
        let a = PresenterScript(title: "A", body: "bodyA")
        let b = PresenterScript(title: "B", body: "bodyB")
        let model = PresenterScriptReaderModel()

        model.select(a.id)
        model.select(b.id)                           // chip 直接切到 B
        XCTAssertEqual(model.mode, .reading(b.id))
        XCTAssertEqual(model.body(for: [a, b]), "bodyB")

        model.backToList()
        XCTAssertEqual(model.mode, .list)
        XCTAssertNil(model.body(for: [a, b]))
    }

    /// AC-27:空清單——選定 id 找不到對應講稿 → body 為 nil,不崩潰;提示常數存在。
    func testEmptyStateHint() {
        let model = PresenterScriptReaderModel()
        model.select(UUID())
        XCTAssertNil(model.body(for: []))
        XCTAssertFalse(PresenterScriptView.emptyHint.isEmpty)
    }

    // MARK: - Panel(AC-24)

    /// AC-24:面板螢幕分享排除 + 不搶焦點(不激活 app)。
    func testPanelIsScreenShareExcludedNonActivating() {
        let panel = PresenterScriptPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 620))
        XCTAssertEqual(panel.sharingType, .none)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    // MARK: - 定位幾何(近鏡頭)

    func testAnchorRectCentersNearTop() {
        let vf = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let size = PresenterScriptWindowManager.hostSize(visibleFrame: vf)
        XCTAssertEqual(size.width, 640, accuracy: 0.5)          // 1920/3,落在 [420,800]

        let rect = PresenterScriptWindowManager.anchorRect(visibleFrame: vf, size: size)
        XCTAssertEqual(rect.midX, vf.midX, accuracy: 0.5)        // 水平置中
        XCTAssertEqual(rect.maxY, vf.maxY - 12, accuracy: 0.5)   // 貼上緣(近鏡頭)
    }

    func testHostWidthClampedForNarrowAndWideScreens() {
        let narrow = PresenterScriptWindowManager.hostSize(visibleFrame: NSRect(x: 0, y: 0, width: 900, height: 600))
        XCTAssertEqual(narrow.width, 420, accuracy: 0.5)         // 900/3=300 → 夾到下限 420
        let wide = PresenterScriptWindowManager.hostSize(visibleFrame: NSRect(x: 0, y: 0, width: 3840, height: 2160))
        XCTAssertEqual(wide.width, 800, accuracy: 0.5)           // 3840/3=1280 → 夾到上限 800
    }
}
