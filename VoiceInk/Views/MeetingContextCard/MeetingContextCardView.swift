import AppKit
import SwiftUI

/// M14 會議脈絡卡浮窗。內容由 `MeetingContextCardService` 生成；
/// 區塊依序：🕐 上次討論 → 📋 未結事項 → 🤝 我答應過的 → 相關筆記 → 相關任務，空區塊省略。
struct MeetingContextCardView: View {
    @ObservedObject private var service = MeetingContextCardService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("會議脈絡")
                    .font(.system(size: 13, weight: .semibold))
                if let model = service.model {
                    Text(model.meetingTitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    MeetingContextCardWindowManager.shared.hideAndUnpin()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .delayedTooltip("關閉")
            }

            // 生成期間**不**先彈「處理中」浮窗——RAG 零命中且 showWhenEmpty=false 時會
            // 「彈了又收」，每場會打擾一次；遲到卡由 service 的 autoShowStaleAfter 降級成通知。
            if let model = service.model {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        content(model)
                    }
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 400, height: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        // hover = 使用者在看 → 取消自動淡出（保留到自己按關閉）。
        .onHover { MeetingContextCardWindowManager.shared.noteHover($0) }
        // 整窗拖曳：pattern 同 MorningBriefingView（系統拖曳會激活 app，不能用）。
        .floatingWindowDrag(
            currentOrigin: { MeetingContextCardWindowManager.shared.panelOrigin },
            setOrigin: { MeetingContextCardWindowManager.shared.setPanelOrigin($0) })
    }

    // MARK: - 區塊

    @ViewBuilder
    private func content(_ model: MeetingContextCardModel) -> some View {
        if model.isFallback {
            Text("AI 整理沒有成功——先列出相關的舊筆記與任務，內容自己點開看。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }

        if model.firstMeeting && model.lastSummary.isEmpty && model.openItems.isEmpty
            && model.myPromises.isEmpty {
            Text("看起來是第一次跟這個主題開會——沒有舊脈絡，輕裝上陣。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }

        if !model.lastSummary.isEmpty {
            bulletSection("🕐 上次討論", items: model.lastSummary)
        }
        if !model.openItems.isEmpty {
            bulletSection("📋 未結事項", items: model.openItems)
        }
        if !model.myPromises.isEmpty {
            bulletSection("🤝 我答應過的", items: model.myPromises)
        }

        if !model.noteLinks.isEmpty {
            sectionHeader("📄 相關筆記")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.noteLinks) { link in
                    Button {
                        MeetingContextCardService.shared.openNote(path: link.path)
                    } label: {
                        Text(link.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .delayedTooltip("在 Obsidian 開啟")
                }
            }
        }

        if !model.tasks.isEmpty {
            sectionHeader("⏰ 可能相關的未結任務")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.tasks) { task in
                    Button {
                        MeetingContextCardService.shared.openTask(id: task.id)
                    } label: {
                        Text(task.title)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .delayedTooltip("在 Vikunja 開啟")
                }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private func bulletSection(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(title)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(item)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.leading)
                }
            }
        }
    }
}

/// 脈絡卡專用 panel：non-activating、不搶焦點——**開會中彈出，絕不能把焦點從會議 app 搶走**。
/// 層級/收放行為鏡射 `MorningBriefingPanel`。
final class MeetingContextCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar + 2
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 拖曳走 SwiftUI 手勢（floatingWindowDrag）；系統拖曳會激活 app（同 HotkeyCheatSheetPanel 實測）。
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        // 「上次討論到哪、我答應了什麼」不該入鏡。誠實邊界同 MorningBriefingPanel：
        // macOS 15.4+ 分享整個螢幕時仍會被錄到——保命靠 panic 熱鍵（orderOut）。
        sharingType = .none
    }
}

/// 脈絡卡視窗生命週期（show/hide/自動淡出）。鏡射 `MorningBriefingWindowManager`，
/// 外加 auto-fade：autoShow 彈出後 10 秒無互動自動淡出（hover 進來就取消，常駐到手動關閉）。
@MainActor
final class MeetingContextCardWindowManager: ObservableObject {

    static let shared = MeetingContextCardWindowManager()

    static let autoFadeDelay: TimeInterval = 10

    private var windowController: NSWindowController?
    private var panel: MeetingContextCardPanel?
    private var autoFadeTimer: Timer?

    @Published private(set) var isPinned = false

    private init() {}

    var panelOrigin: NSPoint? { panel?.frame.origin }
    func setPanelOrigin(_ origin: NSPoint) { panel?.setFrameOrigin(origin) }

    /// panic hide 的可見性判斷（同 `CopilotOverlayWindowManager.isVisibleOnScreen`）。
    var isVisibleOnScreen: Bool { panel?.isVisible == true }

    func hideAndUnpin() {
        cancelAutoFade()
        isPinned = false
        panel?.orderOut(nil)
        panel?.alphaValue = 1   // 淡出中途被收 → 下次 show 不會是隱形視窗
    }

    func show() {
        cancelAutoFade()
        if panel == nil { initializeWindow() }
        guard let panel else { return }
        panel.alphaValue = 1
        // 位置已不在任何螢幕上（拔外接螢幕）→ 重新置中主螢幕。
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(center) }
        if !onScreen { panel.setFrame(Self.calculateWindowMetrics(), display: true) }
        panel.orderFrontRegardless()   // 絕不 makeKeyAndOrderFront（不搶焦點）
        isPinned = true
    }

    /// autoShow 路徑：浮出後 `autoFadeDelay` 秒無互動自動淡出（開會中不佔版面）。
    func showWithAutoFade() {
        show()
        let timer = Timer(timeInterval: Self.autoFadeDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.fadeOut() }
        }
        // .common 模式：選單開著、視窗拖曳中也照跑（同 MeetingStartDetector 的教訓）。
        RunLoop.main.add(timer, forMode: .common)
        autoFadeTimer = timer
    }

    /// hover 進入 = 使用者在看 → 取消淡出，卡片保留到手動關閉。
    /// （淡出動畫已經開跑的極端時序不救——0.6 秒動畫窗內 hover 進來仍會收掉，接受。）
    func noteHover(_ hovering: Bool) {
        if hovering { cancelAutoFade() }
    }

    private func cancelAutoFade() {
        autoFadeTimer?.invalidate()
        autoFadeTimer = nil
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.6
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isPinned = false
                self.panel?.orderOut(nil)
                self.panel?.alphaValue = 1
            }
        })
    }

    private func initializeWindow() {
        let metrics = Self.calculateWindowMetrics()
        let newPanel = MeetingContextCardPanel(contentRect: metrics)
        let hosting = NSHostingController(rootView: MeetingContextCardView())
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
            let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
            let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(center) }
            if !onScreen { panel.setFrame(Self.calculateWindowMetrics(), display: true) }
        }
    }

    /// 主螢幕右上（避開正中央——開會中畫面中央通常是對方的臉/簡報），但頂邊必須讓開
    /// 錄音指示 pill：手動開錄路徑下 pill 與卡片幾乎必同場，直接貼 maxY 會疊在 pill 上
    ///（卡片標題列/關閉鈕壓住 pill 按鈕）。以 pill 實際 frame 計算、不硬編其尺寸。
    static func calculateWindowMetrics() -> NSRect {
        let size = NSSize(width: 400, height: 440)
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let f = screen.visibleFrame
        let pillBottom = MeetingIndicatorWindowManager.metrics(for: screen).minY
        return NSRect(
            x: f.maxX - size.width - 24,
            y: pillBottom - 12 - size.height,
            width: size.width,
            height: size.height
        )
    }
}
