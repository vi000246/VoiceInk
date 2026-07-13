import AppKit
import SwiftUI
import os

/// peek 熱鍵的 press-and-hold 守衛。**語意複製 push-to-talk**:
/// `isPressed` 擋 key-repeat auto-fire、0.5s cooldown 擋短時間重觸。
/// 按住一鍵時 CGEvent tap 會連發 keyDown——沒有這兩個守衛,overlay 會被連續 show 轟炸。
struct CopilotPeekGuard {
    private var isPressed = false
    private var lastPressAt: TimeInterval = -.infinity
    let cooldown: TimeInterval = 0.5

    /// keyDown 抵達。回 true = 第一次按下,執行 show。
    mutating func registerKeyDown(at eventTime: TimeInterval) -> Bool {
        guard !isPressed else { return false }                     // key-repeat
        guard eventTime - lastPressAt >= cooldown else { return false }
        isPressed = true
        lastPressAt = eventTime
        return true
    }

    /// keyUp 抵達。回 true = 有對應的 show,執行 hide。
    mutating func registerKeyUp() -> Bool {
        guard isPressed else { return false }
        isPressed = false
        return true
    }
}

/// overlay 的 show/hide/toggle/peek 與定位(FR-21/24/25)。
///
/// 生命週期照抄 `MeetingIndicatorWindowManager`(strong panel + windowController 純為 retain;
/// hide 只 orderOut,panel 重用)——**但不抄它的 frozen-frame bug**:`show()` 每次重算 + `setFrame`。
///
/// 焦點契約:panel `canBecomeKey=false` + 只用 `orderFrontRegardless()`——從不搶焦點。
@MainActor
final class CopilotOverlayWindowManager {

    static let shared = CopilotOverlayWindowManager()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private var windowController: NSWindowController?
    private var panel: CopilotOverlayPanel?
    private weak var controller: MeetingCopilotController?
    private var onCueTapped: ((MeetingLiveCue) -> Void)?

    private var dimming = OverlayDimmingModel()
    private var peekGuard = CopilotPeekGuard()

    /// toggle 熱鍵釘住的狀態。peek 放開時只在「未釘住」才隱藏。
    private(set) var isPinned = false

    /// 接線點:M2/M3 建立 `MeetingCopilotController` 與 M1 `MeetingLiveTranscriber` 之處呼叫。
    /// `onLocalLevel` 必須在 transcriber.start() **前**掛上(pump 啟動時定格 closure)。
    func configure(
        controller: MeetingCopilotController,
        transcriber: MeetingLiveTranscriber?,
        onCueTapped: ((MeetingLiveCue) -> Void)? = nil
    ) {
        self.controller = controller
        self.onCueTapped = onCueTapped
        transcriber?.onLocalLevel = { [weak self] rms in
            self?.applyLocalLevel(rms)
        }
    }

    // MARK: - 熱鍵入口(RecordingShortcutManager 呼叫)

    /// `.toggleMeetingCopilotOverlay`(keyUp-only)。
    func toggle() {
        if isPinned {
            isPinned = false
            hide()
        } else {
            isPinned = true
            show()
        }
    }

    /// `.peekMeetingCopilotOverlay` 的 keyDown(顯式 branch)。
    func peekKeyDown(at eventTime: TimeInterval) {
        guard peekGuard.registerKeyDown(at: eventTime) else { return }
        show()
    }

    /// `.peekMeetingCopilotOverlay` 的 keyUp。
    func peekKeyUp() {
        guard peekGuard.registerKeyUp() else { return }
        if !isPinned { hide() }
    }

    // MARK: - 視窗生命週期

    func show() {
        if panel == nil { initializeWindow() }
        guard let panel else { return }
        panel.setFrame(Self.calculateWindowMetrics(), display: true)   // 每次 show 重算
        panel.ignoresMouseEvents = MeetingCopilotConfigStore.shared.overlayClickThrough
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()          // 絕不 makeKeyAndOrderFront(不搶焦點)
    }

    func hide() {
        panel?.orderOut(nil)                  // panel 保留重用,不 close()
    }

    private func initializeWindow() {
        guard let controller else {
            logger.error("🫥 overlay show requested but MeetingCopilotController not configured")
            return
        }
        let metrics = Self.calculateWindowMetrics()
        let newPanel = CopilotOverlayPanel(
            contentRect: metrics,
            clickThrough: MeetingCopilotConfigStore.shared.overlayClickThrough
        )
        let hosting = NSHostingController(
            rootView: CopilotOverlayView(controller: controller, onCueTapped: onCueTapped)
        )
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

    // MARK: - FR-25:說話淡出

    private func applyLocalLevel(_ rms: Float) {
        guard let panel, panel.isVisible else { return }
        dimming.speakingOpacity = MeetingCopilotConfigStore.shared.speakingOpacity
        let target = CGFloat(dimming.update(rms: rms, at: ProcessInfo.processInfo.systemUptime))
        guard abs(panel.alphaValue - target) > 0.01 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = target
        }
    }

    // MARK: - FR-24:近鏡頭定位

    /// oversized host——可視卡片大小由 SwiftUI 決定。
    nonisolated static let overlaySize = NSSize(width: 560, height: 400)

    /// 螢幕上方中央 = 近鏡頭:讀 overlay 時視線最接近鏡頭。純幾何,nonisolated。
    nonisolated static func anchorRect(visibleFrame: NSRect, size: NSSize = overlaySize) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 12,
            width: size.width,
            height: size.height
        )
    }

    static func calculateWindowMetrics() -> NSRect {
        let screen = meetingAppScreen() ?? NSScreen.main
        guard let screen else {
            return NSRect(origin: .zero, size: overlaySize)
        }
        return anchorRect(visibleFrame: screen.visibleFrame)
    }

    /// 優先會議 app 所在螢幕(FR-24)。找不到 → nil,呼叫端退回 `NSScreen.main`。
    private static let meetingAppOwnerNames: Set<String> = [
        "Microsoft Teams", "MSTeams", "zoom.us", "Zoom", "Webex", "FaceTime"
    ]

    static func meetingAppScreen() -> NSScreen? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for entry in info {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  meetingAppOwnerNames.contains(owner),
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width > 200, bounds.height > 200
            else { continue }

            // CGWindow 座標 top-left 原點;NSScreen bottom-left。以主螢幕高度翻轉 y。
            guard let primary = NSScreen.screens.first else { return nil }
            let flippedMidY = primary.frame.maxY - bounds.midY
            let midPoint = NSPoint(x: bounds.midX, y: flippedMidY)
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(midPoint) }) {
                return screen
            }
        }
        return nil
    }
}
