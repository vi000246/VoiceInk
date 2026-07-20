import AppKit
import SwiftUI

/// 熱鍵一覽表(cheat sheet)。按 `.toggleHotkeyCheatSheet` 熱鍵或選單列入口展開,
/// 列出目前所有可設定熱鍵與其組合鍵。
///
/// 依使用者要求,修飾鍵一律用 **ctrl / alt / shift / cmd / fn 文字表示法**
/// (`Shortcut.textualDisplayString`),不用 ⌃⌥⇧⌘ 符號。
struct HotkeyCheatSheetView: View {
    /// `ShortcutStore` 不是 observable —— 收到 `shortcutDidChange` 就 bump 這個
    /// 逼 body 重算(pattern 同 MeetingIndicatorView.shortcutTick)。
    @State private var shortcutTick = 0

    private struct Row: Identifiable {
        let id: String
        let name: String
        /// nil = 未設定。
        let keys: String?
    }

    private struct RowGroup: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
        /// 群組底部的補充說明(例:錄音面板內的固定鍵)。
        var footnote: String? = nil
    }

    private func row(_ name: String, _ action: ShortcutAction) -> Row {
        Row(id: action.storageName, name: name,
            keys: ShortcutStore.shortcut(for: action)?.textualDisplayString)
    }

    private var groups: [RowGroup] {
        _ = shortcutTick   // 綁定重算依賴

        // 模式熱鍵:每個已設定熱鍵的模式一列(沒設定的不列,避免長清單全是「未設定」)。
        let modeRows: [Row] = ModeManager.shared.configurations.compactMap { config in
            guard let shortcut = ShortcutStore.shortcut(for: .mode(config.id)) else { return nil }
            return Row(id: "mode_\(config.id.uuidString)",
                       name: "模式聽寫：\(config.name)",
                       keys: shortcut.textualDisplayString)
        }

        var result: [RowGroup] = [
            RowGroup(id: "dictation", title: "聽寫錄音", rows: [
                row("開始/停止聽寫（主要）", .primaryRecording),
                row("開始/停止聽寫（次要）", .secondaryRecording),
                row("取消聽寫", .cancelRecorder),
            ], footnote: "錄音面板開啟時：esc 取消；1–9、0 快速選模式"),
            RowGroup(id: "output", title: "輸出與歷史", rows: [
                row("貼上上次轉錄（原文）", .pasteLastTranscription),
                row("貼上上次轉錄（增強後）", .pasteLastEnhancement),
                row("重試上次轉錄", .retryLastTranscription),
                row("開啟歷史視窗", .openHistoryWindow),
                row("快速加入字典", .quickAddToDictionary),
            ]),
            RowGroup(id: "meeting", title: "會議 copilot", rows: [
                row("開始/停止會議錄製", .toggleMeetingRecording),
                row("開關即時輔助視窗", .toggleMeetingCopilotOverlay),
                row("按住暫看輔助視窗", .peekMeetingCopilotOverlay),
                row("緊急隱藏（收起所有會議浮動視窗）", .panicHideMeetingCopilot),
                row("截圖（加入截圖深答佇列）", .captureCopilotScreenshot),
                row("讀稿面板（預設講稿）", .togglePresenterScript),
                row("展開/收合分析", .toggleCopilotCueExpansion),
                row("展開/收合翻譯", .toggleTranslationExpansion),
            ]),
        ]

        if !modeRows.isEmpty {
            result.append(RowGroup(id: "modes", title: "模式聽寫", rows: modeRows))
        }

        result.append(RowGroup(id: "misc", title: "其他", rows: [
            row("語音記待辦（Vikunja）", .voiceCaptureVikunja),
            row("晨間簡報", .showMorningBriefing),
            row("熱鍵一覽表（本視窗）", .toggleHotkeyCheatSheet),
        ]))

        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "keyboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("熱鍵一覽")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    HotkeyCheatSheetWindowManager.shared.hideAndUnpin()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .delayedTooltip("關閉（再按一次熱鍵也可）")
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                            ForEach(group.rows) { r in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(r.name)
                                        .font(.system(size: 12))
                                    Spacer(minLength: 8)
                                    Text(r.keys ?? "未設定")
                                        .font(.system(size: 12, weight: r.keys == nil ? .regular : .semibold, design: .monospaced))
                                        .foregroundStyle(r.keys == nil ? Color.secondary.opacity(0.6) : Color.primary)
                                }
                                .padding(.vertical, 2)
                            }
                            if let footnote = group.footnote {
                                Text(footnote)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 2)
                            }
                        }
                    }
                    Text("到「設定 → Shortcuts」與「會議copilot設定」可修改熱鍵。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)
            }
        }
        .padding(14)
        .frame(width: 440, height: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        // 整窗拖曳:點任一空白處可拖(按鈕/捲動優先),pattern 同讀稿面板。
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .floatingWindowDrag(
            currentOrigin: { HotkeyCheatSheetWindowManager.shared.panelOrigin },
            setOrigin: { HotkeyCheatSheetWindowManager.shared.setPanelOrigin($0) })
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { _ in
            shortcutTick &+= 1
        }
    }
}

/// cheat sheet 專用 panel:non-activating、不搶焦點(可能在會議/打字中呼出)。
/// 層級與收放行為鏡射 `MeetingIndicatorPanel` 一家。
final class HotkeyCheatSheetPanel: NSPanel {
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
        // 拖曳走 SwiftUI 手勢(見 HotkeyCheatSheetView 的 floatingWindowDrag);
        // 系統拖曳會激活 app、把主視窗帶到前景(同 MeetingIndicatorPanel 的實測)。
        isMovable = false
        isMovableByWindowBackground = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        standardWindowButton(.closeButton)?.isHidden = true
        // 熱鍵清單也不該入鏡(分享畫面時會暴露會議輔助功能的存在)。誠實邊界同
        // CopilotOverlayPanel:macOS 15.4+ 分享整個螢幕時仍會被錄到。
        sharingType = .none
    }
}

/// cheat sheet 視窗生命週期(show/hide/toggle)。鏡射 `PresenterScriptWindowManager`。
@MainActor
final class HotkeyCheatSheetWindowManager: ObservableObject {

    static let shared = HotkeyCheatSheetWindowManager()

    private var windowController: NSWindowController?
    private var panel: HotkeyCheatSheetPanel?

    /// 顯示狀態(熱鍵/選單列共用)。
    @Published private(set) var isPinned = false

    private init() {}

    var panelOrigin: NSPoint? { panel?.frame.origin }
    func setPanelOrigin(_ origin: NSPoint) { panel?.setFrameOrigin(origin) }

    /// `.toggleHotkeyCheatSheet` 熱鍵(keyUp-only)與選單列入口共用。
    func toggle() {
        if isPinned {
            hideAndUnpin()
        } else {
            show()
            isPinned = panel != nil
        }
    }

    func hideAndUnpin() {
        isPinned = false
        panel?.orderOut(nil)
    }

    func show() {
        if panel == nil { initializeWindow() }
        guard let panel else { return }
        // 使用者沒拖過、或位置已不在任何螢幕上 → 重新置中主螢幕。
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.contains(center) }
        if !onScreen { panel.setFrame(Self.calculateWindowMetrics(), display: true) }
        panel.orderFrontRegardless()   // 絕不 makeKeyAndOrderFront(不搶焦點)
    }

    private func initializeWindow() {
        let metrics = Self.calculateWindowMetrics()
        let newPanel = HotkeyCheatSheetPanel(contentRect: metrics)
        let hosting = NSHostingController(rootView: HotkeyCheatSheetView())
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

    /// 主螢幕正中央(內容自體撐高,panel 高度給上限)。
    static func calculateWindowMetrics() -> NSRect {
        let size = NSSize(width: 440, height: 600)
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
