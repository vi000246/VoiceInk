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
///
/// `ObservableObject`:錄音指示器與選單列的視窗開關按鈕觀察 `isPinned`,
/// 與熱鍵共用同一份釘住狀態。
@MainActor
final class CopilotOverlayWindowManager: ObservableObject {

    static let shared = CopilotOverlayWindowManager()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private var windowController: NSWindowController?
    private var panel: CopilotOverlayPanel?
    private weak var controller: MeetingCopilotController?
    private var onCueTapped: ((MeetingLiveCue) -> Void)?

    private var peekGuard = CopilotPeekGuard()

    /// 釘住狀態(toggle 熱鍵/UI 按鈕共用)。peek 放開時只在「未釘住」才隱藏。
    @Published private(set) var isPinned = false

    /// 即時翻譯字幕的展開狀態(Stage B):收合 = 顯示最近 5 句,展開 = 最近 30 句。
    /// overlay 上的按鈕與熱鍵共用同一份狀態(overlay view 觀察它)。
    @Published private(set) var translationExpanded = false

    /// 接線點:M2/M3 建立 `MeetingCopilotController` 之處呼叫。
    /// (原本還掛 transcriber.onLocalLevel 做「說話淡出」——2026-07-13 依使用者要求整個移除,
    /// overlay 恆為不透明;onLocalLevel 無訂閱者時 transcriber 端零成本。)
    func configure(
        controller: MeetingCopilotController,
        onCueTapped: ((MeetingLiveCue) -> Void)? = nil
    ) {
        // 換場(新的 live session)時必須丟棄舊 panel:hosting view 對上一場的
        // controller 是強持有,重用會讓 overlay 永遠顯示上一場的殭屍 cue。
        if self.controller !== controller, panel != nil {
            panel?.orderOut(nil)
            panel = nil
            windowController = nil
            NotificationCenter.default.removeObserver(
                self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        self.controller = controller
        self.onCueTapped = onCueTapped
    }

    /// live pipeline 停止時呼叫:取消釘住並隱藏,讓按鈕/熱鍵狀態歸零,
    /// 避免會議結束後 overlay 還掛在螢幕上。
    func hideAndUnpin() {
        isPinned = false
        translationExpanded = false   // 下次開 overlay 從收合的 5 句起(不殘留上一場的展開)
        hide()
    }

    // MARK: - 手動拖曳(CopilotOverlayView 的把手呼叫)

    /// panel 目前的螢幕座標原點(AppKit y 向上)。
    var panelOrigin: NSPoint? { panel?.frame.origin }

    /// 直接設定 panel 原點——把手用 NSEvent.mouseLocation 的螢幕座標計算,
    /// 不用 SwiftUI translation(視窗跟著游標移動時,視窗座標系的 translation 會歸零)。
    func setPanelOrigin(_ origin: NSPoint) {
        panel?.setFrameOrigin(origin)
    }

    /// 移到指定螢幕:重新錨定近鏡頭位置(只在 overlay 已顯示 = panel 存在時)。
    func move(to screen: NSScreen) {
        guard let panel else { return }
        let f = screen.visibleFrame
        panel.setFrame(Self.anchorRect(visibleFrame: f, size: Self.hostSize(visibleFrame: f)), display: true)
    }

    // MARK: - 熱鍵入口(RecordingShortcutManager 呼叫)

    /// `.toggleMeetingCopilotOverlay` 熱鍵(keyUp-only)與 UI 按鈕共用入口。
    func toggle() {
        if isPinned {
            isPinned = false
            hide()
        } else {
            show()
            // show() 失敗(live pipeline 未跑、controller 未 configure)時 panel 仍為 nil
            // —— 不假裝釘住,否則按鈕會亮著但螢幕上什麼都沒有。
            isPinned = panel != nil
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

    /// `.toggleCopilotCueExpansion` 熱鍵(keyUp-only,AC-36):展開/收合最新一則有內容的分析。
    /// 「展開哪一則」的邏輯全在 controller(`toggleExpansion()`),這裡只轉呼叫。
    ///
    /// **overlay 沒顯示時一律 no-op**(而非順手 show):
    /// 1. 一鍵一事——掀開視窗是 `.toggleMeetingCopilotOverlay` / peek 的職責。分享整個螢幕時
    ///    overlay 會被錄到,不該由「展開分析」這種純閱讀動作意外把它推上畫面。
    /// 2. 看不見的展開等於沒發生,還會害下次開 overlay 時莫名有一則是展開的。
    /// live pipeline 沒跑(controller 未 configure)時同樣 no-op。
    func toggleCueExpansion() {
        guard panel?.isVisible == true else { return }
        controller?.toggleExpansion()
    }

    /// `.toggleTranslationExpansion` 熱鍵(keyUp-only)與 overlay 上的展開鈕共用入口:
    /// 即時翻譯字幕在「最近 5 句 ↔ 最近 30 句」之間切換。overlay 沒顯示時 no-op(理由同
    /// `toggleCueExpansion`:看不見的展開等於沒發生)。
    func toggleTranslationExpansion() {
        guard panel?.isVisible == true else { return }
        translationExpanded.toggle()
    }

    // MARK: - 視窗生命週期

    func show() {
        if panel == nil { initializeWindow() }
        guard let panel else { return }
        // 不在每次 show 重算位置——panel 可拖曳後,重算會蓋掉使用者拖到的位置。
        // 初始位置由 initializeWindow 錨定,螢幕組態變更由 handleScreenParametersChange 處理。
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
            rootView: CopilotOverlayView(
                controller: controller,
                // 翻譯字幕源(M8 FR-62)。live controller 在 `configure` **之前**就把 translator
                // 掛上 controller(且翻譯關閉時照樣建),所以這裡取到的恆非 nil;
                // 沒有 live pipeline 的路徑取到 nil → overlay 的翻譯區整段不渲染。
                translator: controller.translator,
                onCueTapped: onCueTapped)
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

    // MARK: - FR-24:近鏡頭定位

    /// oversized host——可視卡片大小由 SwiftUI 決定(卡片寬 = panel 寬,高度 hug 內容)。
    nonisolated static let overlaySize = NSSize(width: 560, height: 400)

    /// 動態 host 尺寸:寬 ≈ 螢幕可視寬的 1/3(夾在 [420, 800],小螢幕仍可讀、超寬螢幕不氾濫);
    /// 高度給足 660 讓換行後的長分析有捲動空間(卡片本身 hug 內容 + 內部 ScrollView 上限 520)。
    nonisolated static func hostSize(visibleFrame: NSRect) -> NSSize {
        NSSize(width: min(max(visibleFrame.width / 3, 420), 800), height: 660)
    }

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
        let f = screen.visibleFrame
        return anchorRect(visibleFrame: f, size: hostSize(visibleFrame: f))
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
