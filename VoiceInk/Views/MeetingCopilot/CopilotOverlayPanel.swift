import SwiftUI
import AppKit

/// 隱蔽 overlay 的 panel。clone 自 `MeetingIndicatorPanel`,再加 4 個 M4 特性。
///
/// # 🔴 螢幕分享排除的誠實邊界(canon §3.1 / memory voiceink-sharingtype-sck-limitation)
/// `sharingType = .none` 在 **macOS 15.4+ 被 ScreenCaptureKit 忽略**(Apple DTS 明言無公開 API
/// 可防擷取)。Chrome/Google Meet 的 `getDisplayMedia` 走 SCK。→ 分享**整個螢幕**時 overlay
/// 會被錄到;安全模式是「分享單一視窗/分頁」。仍設 `.none`,因為它**確實**擋住:
///   - legacy `CGWindowList` 擷取;
///   - Zoom 的「進階視窗過濾」擷取;
///   - 所有 per-window / per-tab 分享(overlay 是另一個視窗,本就不在被分享的視窗內)。
/// **不得宣稱無條件隱形**——UI 有常駐警告條(CopilotOverlayView)。
final class CopilotOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect, clickThrough: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // 高於既有最高的 NotchRecorderPanel(.statusBar + 3),才不被遮。
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 不可移動:避免使用者不小心把它拖進被分享的視窗區域。
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true

        // M4 的兩個純新增(全 repo 首用):
        sharingType = .none               // 見上方誠實邊界
        ignoresMouseEvents = clickThrough // 點擊穿透(依設定)
    }

    /// 依設定切換點擊穿透(不必重建 panel)。
    func setClickThrough(_ on: Bool) {
        ignoresMouseEvents = on
    }
}
