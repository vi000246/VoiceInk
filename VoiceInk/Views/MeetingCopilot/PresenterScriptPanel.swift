import SwiftUI
import AppKit

/// 預設講稿讀稿器的 panel(M7)。
///
/// **複製** `CopilotOverlayPanel` 的**視窗技術**(螢幕分享排除 + 不搶焦點 + 手動拖曳),
/// 但 root view 是 `PresenterScriptView`,**不持有任何 controller、不接 live pipeline**。
/// 複製的是「怎麼開一個隱蔽浮動視窗」,不是「即時輔助」。
///
/// # 🔴 螢幕分享排除的誠實邊界(同 `CopilotOverlayPanel`)
/// `sharingType = .none` 在 **macOS 15.4+ 被 ScreenCaptureKit 忽略** —— 分享**整個螢幕**時仍會被錄到;
/// 安全模式是「只分享單一視窗/分頁」。它確實擋住 legacy `CGWindowList`、Zoom 進階視窗過濾、
/// 以及所有 per-window / per-tab 分享。**不得宣稱無條件隱形**(view 有常駐警告條)。
final class PresenterScriptPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // 拖曳改走 PresenterScriptView 的把手(手動 setFrameOrigin);AppKit 的
        // isMovableByWindowBackground 系統拖曳會激活 app、帶出主視窗(見 CopilotOverlayPanel)。
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        sharingType = .none
    }
}
