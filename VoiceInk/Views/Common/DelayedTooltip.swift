import SwiftUI

/// 滑鼠停留 `delay` 秒後才浮出的自訂 tooltip(預設 1 秒)。
///
/// # 為什麼不用 `.help()`
/// SwiftUI 的 `.help()` 走 `NSToolTipManager`,顯示延遲是**全 app 共用的系統值**,沒有任何
/// 公開 API 能改成 per-view 的自訂延遲 —— 唯一的槓桿是私有的
/// `NSToolTipManager.setInitialToolTipDelay:`(App Store 風險 + 全域生效)。要 per-view 自訂
/// 延遲只能自己做。
///
/// # 為什麼用 `.popover` 而不是 `.overlay`
/// 會議錄製 pill 只有 ~34pt 高,`.overlay` 畫在 icon 下方會被 panel/NSView 邊界裁掉。
/// `.popover` 在獨立的暫時視窗渲染,不受 pill 邊界限制 —— 且已被同一個 non-activating panel
/// 上的「移到其他螢幕」選單證實可用。
struct DelayedTooltip: ViewModifier {
    let text: String
    var delay: Duration = .seconds(1)
    var edge: Edge = .bottom

    @State private var show = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                if hovering && !text.isEmpty {
                    pending = Task {
                        try? await Task.sleep(for: delay)
                        if !Task.isCancelled { show = true }
                    }
                } else {
                    show = false
                }
            }
            .popover(isPresented: $show, arrowEdge: edge) {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .fixedSize()
            }
            .onDisappear { pending?.cancel() }
    }
}

extension View {
    /// 停留 `delay` 秒後浮出 `text` 的 tooltip(見 `DelayedTooltip`)。`text` 為空時不顯示。
    func delayedTooltip(_ text: String, delay: Duration = .seconds(3), edge: Edge = .bottom) -> some View {
        modifier(DelayedTooltip(text: text, delay: delay, edge: edge))
    }
}
