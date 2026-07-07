import SwiftUI
import AppKit

/// 會議錄製中的浮動指示器:紅點＋計時＋停止鈕。
/// 與聽寫 mini recorder 各自獨立;non-activating、不搶鍵盤焦點(會議中使用者在打字)。
struct MeetingIndicatorView: View {
    @ObservedObject var controller: MeetingCaptureController
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(pulsing ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                .onAppear { pulsing = true }
            Text(controller.elapsedText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Button {
                Task { await controller.stopAndImport() }
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("停止會議錄製")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
    }
}

/// 指示器專用 panel:鏡射 `MiniRecorderPanel` 的浮動設定,但絕不成為 key window。
final class MeetingIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
    }
}

/// 鏡射 `MiniWindowManager` 的 show/hide/initialize 生命週期。
@MainActor
final class MeetingIndicatorWindowManager {
    private var windowController: NSWindowController?
    private var panel: MeetingIndicatorPanel?
    private weak var controller: MeetingCaptureController?

    init(controller: MeetingCaptureController) {
        self.controller = controller
    }

    func show() {
        if panel == nil { initializeWindow() }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func initializeWindow() {
        guard let controller else { return }
        let metrics = Self.calculateWindowMetrics()
        let newPanel = MeetingIndicatorPanel(contentRect: metrics)
        let hosting = NSHostingController(rootView: MeetingIndicatorView(controller: controller))
        newPanel.contentView = hosting.view
        newPanel.setFrame(metrics, display: true)
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    /// 右上角(選單列下方),避開聽寫 mini recorder 的螢幕底部位置。
    private static func calculateWindowMetrics() -> NSRect {
        let width: CGFloat = 150
        let height: CGFloat = 34
        guard let screen = NSScreen.main else { return NSRect(x: 0, y: 0, width: width, height: height) }
        let f = screen.visibleFrame
        return NSRect(x: f.maxX - width - 16, y: f.maxY - height - 12, width: width, height: height)
    }
}
