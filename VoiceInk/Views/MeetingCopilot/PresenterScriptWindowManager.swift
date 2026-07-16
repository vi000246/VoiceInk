import AppKit
import SwiftUI

/// 讀稿面板的 show/hide/toggle 與定位(M7,FR-35/38)。
///
/// **獨立於 live pipeline**:show 不需要 `MeetingCopilotController`、不需要任何會議在錄音、
/// 不 gate 在 `copilotEnabled`。它只是一個顯示使用者自寫講稿的視窗。
///
/// 生命週期與焦點契約鏡射 `CopilotOverlayWindowManager`(strong panel + windowController 純為 retain;
/// `canBecomeKey = false` + `orderFrontRegardless()`,從不搶焦點)。`ObservableObject`:
/// 選單列的 toggle 觀察 `isPinned`,與熱鍵共用同一份釘住狀態。
@MainActor
final class PresenterScriptWindowManager: ObservableObject {

    static let shared = PresenterScriptWindowManager()

    private var windowController: NSWindowController?
    private var panel: PresenterScriptPanel?

    /// 釘住狀態(toggle 熱鍵/選單列按鈕共用)。
    @Published private(set) var isPinned = false

    private init() {}

    // MARK: - 手動拖曳(PresenterScriptView 的把手呼叫)

    /// 讀稿面板是否**實際**顯示在螢幕上(緊急隱藏判斷收/放用,FR-84)。
    var isVisibleOnScreen: Bool { panel?.isVisible == true }

    var panelOrigin: NSPoint? { panel?.frame.origin }
    func setPanelOrigin(_ origin: NSPoint) { panel?.setFrameOrigin(origin) }

    /// 移到指定螢幕:重新錨定近鏡頭位置(只在讀稿面板已顯示 = panel 存在時)。
    func move(to screen: NSScreen) {
        guard let panel else { return }
        let f = screen.visibleFrame
        panel.setFrame(Self.anchorRect(visibleFrame: f, size: Self.hostSize(visibleFrame: f)), display: true)
    }

    // MARK: - 熱鍵/按鈕入口

    /// `.togglePresenterScript` 熱鍵(keyUp-only)與選單列 toggle 共用入口。
    func toggle() {
        if isPinned {
            isPinned = false
            hide()
        } else {
            show()
            isPinned = panel != nil
        }
    }

    /// 無條件收起並取消釘住(緊急隱藏共用;鏡射 `CopilotOverlayWindowManager.hideAndUnpin`)。
    /// 回傳收起前是否為釘住狀態——供 panic 的 restore 決定要不要把這個面板叫回。
    @discardableResult
    func hideAndUnpin() -> Bool {
        let wasPinned = isPinned
        isPinned = false
        hide()
        return wasPinned
    }

    /// 緊急隱藏後的還原:把面板重新顯示並釘住(只在 panic 前是釘住狀態時呼叫)。
    func showAndPin() {
        show()
        isPinned = panel != nil
    }

    // MARK: - 視窗生命週期

    func show() {
        if panel == nil { initializeWindow() }
        guard let panel else { return }
        panel.orderFrontRegardless()   // 絕不 makeKeyAndOrderFront(不搶焦點)
    }

    func hide() {
        panel?.orderOut(nil)           // panel 保留重用,不 close()
    }

    private func initializeWindow() {
        let metrics = Self.calculateWindowMetrics()
        let newPanel = PresenterScriptPanel(contentRect: metrics)
        let hosting = NSHostingController(rootView: PresenterScriptView())
        newPanel.contentView = hosting.view
        newPanel.setFrame(metrics, display: true)
        panel = newPanel
        windowController = NSWindowController(window: newPanel)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func handleScreenParametersChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            panel.setFrame(Self.calculateWindowMetrics(), display: true)
        }
    }

    // MARK: - 定位(近鏡頭,純幾何,nonisolated 便於測試)

    /// 動態 host 尺寸:寬 ≈ 螢幕可視寬 1/3(夾在 [420, 800]),高 620。
    nonisolated static func hostSize(visibleFrame: NSRect) -> NSSize {
        NSSize(width: min(max(visibleFrame.width / 3, 420), 800), height: 620)
    }

    /// 螢幕上方中央 = 近鏡頭。純幾何。
    nonisolated static func anchorRect(visibleFrame: NSRect, size: NSSize) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        )
    }

    static func calculateWindowMetrics() -> NSRect {
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: NSSize(width: 480, height: 620))
        }
        let f = screen.visibleFrame
        return anchorRect(visibleFrame: f, size: hostSize(visibleFrame: f))
    }
}
