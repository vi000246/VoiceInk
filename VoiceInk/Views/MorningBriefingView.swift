import AppKit
import SwiftUI

/// 晨間簡報浮窗(M13)。內容由 `MorningBriefingService` 生成;
/// 區塊依序:逾期 → 今天到期 → 無期限 → 昨日會後包 → AI「今日第一件事」,空區塊省略。
struct MorningBriefingView: View {
    @ObservedObject private var service = MorningBriefingService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sun.max")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("晨間簡報")
                    .font(.system(size: 13, weight: .semibold))
                if let generatedAt = service.generatedAt {
                    Text(generatedAt, format: .dateTime.hour().minute())
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    MorningBriefingWindowManager.shared.hideAndUnpin()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .delayedTooltip("關閉")
            }

            if service.isGenerating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("整理今天的簡報…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 20)
            }

            if let model = service.model {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        content(model)
                    }
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if !service.isGenerating {
                Text("尚未生成——按選單列「晨間簡報」或熱鍵重新整理。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 460, height: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        // 整窗拖曳:pattern 同 HotkeyCheatSheetView(系統拖曳會激活 app,不能用)。
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .floatingWindowDrag(
            currentOrigin: { MorningBriefingWindowManager.shared.panelOrigin },
            setOrigin: { MorningBriefingWindowManager.shared.setPanelOrigin($0) })
    }

    // MARK: - 區塊

    @ViewBuilder
    private func content(_ model: MorningBriefingModel) -> some View {
        if let note = model.vikunjaNote {
            sectionHeader("⏰ 任務")
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }

        if !model.overdue.isEmpty {
            section("⏰ 逾期任務", rows: model.overdue)
        }

        if !model.dueToday.isEmpty {
            section("📌 今天到期", rows: model.dueToday)
        }

        if !model.noDue.isEmpty {
            section("🗂 無期限待辦", rows: model.noDue)
            if model.noDueOverflow > 0 {
                Text("還有 \(model.noDueOverflow) 筆——完整清單在 Vikunja。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, -8)
            }
        }

        if !model.packs.isEmpty {
            sectionHeader("📦 昨日會後包")
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.packs) { pack in
                    Button {
                        MorningBriefingService.shared.openPack(fileName: pack.fileName)
                    } label: {
                        Text(pack.fileName.replacingOccurrences(of: ".md", with: ""))
                            .font(.system(size: 12))
                            .foregroundStyle(Color.accentColor)
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                    .delayedTooltip("在 Obsidian 開啟")
                }
            }
        }

        if let suggestion = model.aiSuggestion {
            sectionHeader("☀️ 今日第一件事")
            Text(suggestion)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }

        if !model.hasAnyContent {
            Text("今天沒有待辦與會後包，空白的一天可以自由發揮。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.secondary)
    }

    private func section(_ title: String, rows: [MorningBriefingModel.TaskRow]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            sectionHeader(title)
            ForEach(rows) { row in
                Button {
                    MorningBriefingService.shared.openTask(id: row.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.title)
                            .font(.system(size: 12))
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        if let subtitle = row.subtitle {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .layoutPriority(1)
                        }
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .delayedTooltip("在 Vikunja 開啟")
            }
        }
    }
}

/// 簡報專用 panel:non-activating、不搶焦點。層級/收放行為鏡射 `HotkeyCheatSheetPanel`。
final class MorningBriefingPanel: NSPanel {
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
        // 拖曳走 SwiftUI 手勢(floatingWindowDrag);系統拖曳會激活 app(同 HotkeyCheatSheetPanel 實測)。
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        // 個人待辦清單不該入鏡(分享畫面時)。誠實邊界同 HotkeyCheatSheetPanel:
        // macOS 15.4+ 分享整個螢幕時仍會被錄到。
        sharingType = .none
    }
}

/// 簡報視窗生命週期(show/hide/toggle)。鏡射 `HotkeyCheatSheetWindowManager`。
@MainActor
final class MorningBriefingWindowManager: ObservableObject {

    static let shared = MorningBriefingWindowManager()

    private var windowController: NSWindowController?
    private var panel: MorningBriefingPanel?

    /// 顯示狀態(熱鍵/選單列共用)。
    @Published private(set) var isPinned = false

    private init() {}

    var panelOrigin: NSPoint? { panel?.frame.origin }
    func setPanelOrigin(_ origin: NSPoint) { panel?.setFrameOrigin(origin) }

    func hideAndUnpin() {
        isPinned = false
        panel?.orderOut(nil)
    }

    func show() {
        if panel == nil { initializeWindow() }
        guard let panel else { return }
        // 位置已不在任何螢幕上(拔外接螢幕) → 重新置中主螢幕。
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(center) }
        if !onScreen { panel.setFrame(Self.calculateWindowMetrics(), display: true) }
        panel.orderFrontRegardless()   // 絕不 makeKeyAndOrderFront(不搶焦點)
        isPinned = true
    }

    private func initializeWindow() {
        let metrics = Self.calculateWindowMetrics()
        let newPanel = MorningBriefingPanel(contentRect: metrics)
        let hosting = NSHostingController(rootView: MorningBriefingView())
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

    /// 主螢幕正中央。
    static func calculateWindowMetrics() -> NSRect {
        let size = NSSize(width: 460, height: 600)
        guard let screen = NSScreen.main else {
            return NSRect(origin: .zero, size: size)
        }
        let f = screen.visibleFrame
        return NSRect(
            x: f.midX - size.width / 2,
            y: f.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
