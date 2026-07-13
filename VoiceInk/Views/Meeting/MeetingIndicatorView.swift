import SwiftUI
import AppKit

/// 會議錄製中的浮動指示器:紅點＋計時＋停止鈕。
/// 與聽寫 mini recorder 各自獨立;non-activating、不搶鍵盤焦點(會議中使用者在打字)。
struct MeetingIndicatorView: View {
    @ObservedObject var controller: MeetingCaptureController
    @ObservedObject private var overlayManager = CopilotOverlayWindowManager.shared
    @State private var pulsing = false
    @State private var showScreenPicker = false

    private var multipleScreens: Bool { NSScreen.screens.count > 1 }

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
            // copilot 即時輔助狀態 + 隨時開關(亮 = live pipeline 在跑)。
            Button {
                controller.setCopilotEnabled(!controller.copilotActive)
            } label: {
                Image(systemName: controller.copilotActive ? "person.2.wave.2.fill" : "person.2.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(controller.copilotActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(controller.copilotActive ? "會議即時輔助:開啟中(點擊關閉)" : "會議即時輔助:已關閉(點擊開啟)")
            // 即時輔助視窗(overlay)開關 —— 與熱鍵共用釘住狀態;pipeline 沒在跑時停用。
            Button {
                overlayManager.toggle()
            } label: {
                Image(systemName: overlayManager.isPinned ? "macwindow.on.rectangle" : "macwindow")
                    .font(.system(size: 13))
                    .foregroundStyle(controller.copilotActive
                                     ? (overlayManager.isPinned ? Color.accentColor : Color.secondary)
                                     : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!controller.copilotActive)
            .help(overlayManager.isPinned ? "隱藏即時輔助視窗" : "顯示即時輔助視窗")
            // 快速把錄製列 + 所有浮動視窗丟到另一個螢幕(比拖曳快;多螢幕才啟用)。
            Button {
                showScreenPicker = true
            } label: {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .font(.system(size: 13))
                    .foregroundStyle(multipleScreens ? Color.secondary : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!multipleScreens)
            .help(multipleScreens ? "移到其他螢幕" : "只偵測到一個螢幕")
            .popover(isPresented: $showScreenPicker, arrowEdge: .bottom) {
                ScreenArrangementPicker(
                    currentDisplayID: controller.indicatorScreen.flatMap(MeetingScreens.displayID)
                ) { screen in
                    controller.moveFloatingWindows(to: screen)
                    showScreenPicker = false
                }
            }
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
        // 整窗拖曳:點 pill 任一空白處都能拖(按鈕點擊仍優先)。見 FloatingWindowDragGesture。
        .contentShape(Capsule())
        .floatingWindowDrag(
            currentOrigin: { controller.indicatorOrigin },
            setOrigin: { controller.setIndicatorOrigin($0) })
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
        // 拖曳改走 SwiftUI 手勢(整窗可拖,見 MeetingIndicatorView.body 的 floatingWindowDrag):
        // AppKit 的 isMovableByWindowBackground 系統拖曳會**激活 app**、把主視窗帶到前景
        // (同 CopilotOverlayPanel 的實測)。手動 setFrameOrigin 不經 activation,保持不搶焦點。
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        // 比照 CopilotOverlayPanel:錄製 pill 也不該出現在分享/錄影畫面裡
        // (紅點+計時+copilot 按鈕會暴露本功能)。誠實邊界同 overlay(CopilotOverlayPanel.swift:6-13):
        // macOS 15.4+ 的 ScreenCaptureKit 會忽略此設定 → 分享**整個螢幕**時仍會被錄到;
        // 擋得住 legacy CGWindowList、Zoom 進階視窗過濾、以及所有單一視窗/分頁分享。
        sharingType = .none
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

    // MARK: - 手動拖曳 / 移到其他螢幕(MeetingIndicatorView 呼叫)

    /// panel 目前的螢幕座標原點(AppKit y 向上)。
    var panelOrigin: NSPoint? { panel?.frame.origin }
    /// 直接設定 panel 原點(整窗拖曳用;不激活 app)。
    func setPanelOrigin(_ origin: NSPoint) { panel?.setFrameOrigin(origin) }

    /// 錄製列目前所在螢幕(依中心點判定,供螢幕選單排除自己)。
    var currentScreen: NSScreen? {
        guard let panel else { return NSScreen.main }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(center) })
            ?? panel.screen ?? NSScreen.main
    }

    /// 移到指定螢幕:重新錨定該螢幕右上角(近選單列),不保留手動偏移。
    func move(to screen: NSScreen) {
        panel?.setFrame(Self.metrics(for: screen), display: true)
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

    /// 指定螢幕的右上角(選單列下方),避開聽寫 mini recorder 的螢幕底部位置。
    static func metrics(for screen: NSScreen) -> NSRect {
        let width: CGFloat = 226   // 紅點+計時+copilot+overlay+移動螢幕+停止(各 13–16pt icon + 8 spacing)
        let height: CGFloat = 34
        let f = screen.visibleFrame
        return NSRect(x: f.maxX - width - 16, y: f.maxY - height - 12, width: width, height: height)
    }

    private static func calculateWindowMetrics() -> NSRect {
        guard let screen = NSScreen.main else { return NSRect(x: 0, y: 0, width: 226, height: 34) }
        return metrics(for: screen)
    }
}
