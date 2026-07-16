import SwiftUI
import AppKit

/// 會議錄製中的浮動指示器:紅點＋計時＋停止鈕。
/// 與聽寫 mini recorder 各自獨立;non-activating、不搶鍵盤焦點(會議中使用者在打字)。
struct MeetingIndicatorView: View {
    @ObservedObject var controller: MeetingCaptureController
    @ObservedObject private var overlayManager = CopilotOverlayWindowManager.shared
    @ObservedObject private var copilotConfig = MeetingCopilotConfigStore.shared
    @ObservedObject private var scriptStore = PresenterScriptStore.shared
    @ObservedObject private var presenterManager = PresenterScriptWindowManager.shared
    @State private var pulsing = false
    @State private var showScreenPicker = false
    @State private var showScriptPicker = false
    /// `Shortcut.displayString` 不是 observable —— 收到 `shortcutDidChange` 就 bump 這個
    /// 逼 body 重算熱鍵提示(pattern 同 ShortcutRecorder)。
    @State private var shortcutTick = 0

    private var multipleScreens: Bool { NSScreen.screens.count > 1 }

    /// overlay 開關的熱鍵提示(接在 tooltip 後面);未設定熱鍵時回空字串。
    private var overlayHotkeyHint: String {
        _ = shortcutTick   // 綁定重算依賴
        guard let display = ShortcutStore.shortcut(for: .toggleMeetingCopilotOverlay)?.displayString,
              !display.isEmpty else { return "" }
        return "（\(display)）"
    }

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
            .delayedTooltip(controller.copilotActive ? "會議即時輔助:開啟中(點擊關閉)" : "會議即時輔助:已關閉(點擊開啟)")
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
            .delayedTooltip((overlayManager.isPinned ? "隱藏即時輔助視窗" : "顯示即時輔助視窗") + overlayHotkeyHint)
            // 即時翻譯開關 —— 與選單、設定頁共寫同一個 config flag(中途切換下一句立即生效)。
            Button {
                copilotConfig.setLiveTranslationEnabled(!copilotConfig.liveTranslationEnabled)
            } label: {
                Image(systemName: copilotConfig.liveTranslationEnabled ? "globe.badge.chevron.backward" : "globe")
                    .font(.system(size: 13))
                    .foregroundStyle(controller.copilotActive
                                     ? (copilotConfig.liveTranslationEnabled ? Color.accentColor : Color.secondary)
                                     : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!controller.copilotActive)
            .delayedTooltip(copilotConfig.liveTranslationEnabled ? "即時翻譯:開啟中(點擊關閉)" : "即時翻譯:已關閉(點擊開啟)")
            // 預設講稿快速入口:下拉選稿 → 開讀稿面板直接跳到該稿。
            // 讀稿面板獨立於 copilot pipeline(不 gate 在 copilotActive),會議中隨時可用。
            Button {
                showScriptPicker = true
            } label: {
                Image(systemName: "doc.text")
                    .font(.system(size: 13))
                    .foregroundStyle(scriptStore.scripts.isEmpty
                                     ? Color.secondary.opacity(0.4)
                                     : (presenterManager.isPinned ? Color.accentColor : Color.secondary))
            }
            .buttonStyle(.plain)
            .disabled(scriptStore.scripts.isEmpty)
            .delayedTooltip(scriptStore.scripts.isEmpty
                            ? "尚無講稿——到「會議copilot設定 → 預設講稿」新增"
                            : "開啟預設講稿")
            .popover(isPresented: $showScriptPicker, arrowEdge: .bottom) {
                PresenterScriptQuickPicker { id in
                    presenterManager.showScript(id)
                    showScriptPicker = false
                }
            }
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
            .delayedTooltip("停止會議錄製")
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
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            shortcutTick &+= 1
        }
    }
}

/// live pill 講稿下拉的內容:講稿標題直列,點一則 → 開讀稿面板直接跳到該稿。
/// 樣式鏡射 `ScreenArrangementPicker`(同一顆 pill 上的另一個 popover)。
struct PresenterScriptQuickPicker: View {
    let onPick: (UUID) -> Void
    @ObservedObject private var store = PresenterScriptStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("預設講稿").font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(store.scripts) { s in
                    Button { onPick(s.id) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(s.title.isEmpty ? "（未命名）" : s.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("點一則即開啟讀稿面板").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 220)
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
        // `.statusBar + 2`(而非舊的 `.floating` = 3):`.floating` 太低,會議 app 全螢幕時
        // (常見於沒接外接螢幕、把會議開全螢幕)pill 被壓在底下看不到——外接螢幕時會議多為
        // 視窗模式所以沒事,這正是「沒外接螢幕就消失」的成因之一。對齊聽寫的 NotchRecorderPanel
        // (`.statusBar + 3`)與 copilot overlay(`.screenSaver`)這一家always-on-top 錄製 UI;
        // 取 +2 落在 notch recorder 之下、overlay 之下,不互相搶層。
        level = .statusBar + 2
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
        // 螢幕組態變更(拔掉外接螢幕、解析度/排列改變)時重錨:否則 pill 的 frame 留在
        // 消失的外接螢幕座標系裡 = 落到可視範圍外 → 「不見了」。copilot overlay 有這個觀察者,
        // pill 之前漏了,這是「沒外接螢幕就消失」的另一半成因。
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(
            self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show() {
        if panel == nil { initializeWindow() }
        // panel 可能是上一場會議在外接螢幕上建的;若現在那個位置已不在任何螢幕內
        // (拔了螢幕、或本來就沒接),重錨回主螢幕右上角,否則 orderFront 只是把它
        // 重新丟到看不見的座標。
        reanchorIfOffscreen()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// panel 的中心點不落在任何螢幕的可視範圍內 → 視為離屏,重錨回主螢幕。
    /// (保留使用者手動拖曳的位置——只要它還在某個螢幕上就不動。)
    private func reanchorIfOffscreen() {
        guard let panel else { return }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(center) }
        if !onScreen, let screen = NSScreen.main {
            panel.setFrame(Self.metrics(for: screen), display: true)
        }
    }

    @objc private func handleScreenParametersChange() {
        // 稍等螢幕組態穩定(與 CopilotOverlayWindowManager 同步)再判斷是否離屏。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.reanchorIfOffscreen()
        }
    }

    // MARK: - 手動拖曳 / 移到其他螢幕(MeetingIndicatorView 呼叫)

    /// 錄音指示 pill 是否**實際**顯示在螢幕上(緊急隱藏判斷收/放用,FR-84)。
    var isVisibleOnScreen: Bool { panel?.isVisible == true }

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
        let width: CGFloat = 278   // 紅點+計時+copilot+overlay+即時翻譯+講稿+移動螢幕+停止(各 13–16pt icon + 8 spacing)
        let height: CGFloat = 34
        let f = screen.visibleFrame
        return NSRect(x: f.maxX - width - 16, y: f.maxY - height - 12, width: width, height: height)
    }

    private static func calculateWindowMetrics() -> NSRect {
        guard let screen = NSScreen.main else { return NSRect(x: 0, y: 0, width: 250, height: 34) }
        return metrics(for: screen)
    }
}
