import SwiftUI
import AppKit

// MARK: - 整窗拖曳

/// 讓浮動視窗可從**任一非互動區域**拖曳,且**不激活 app**(不把主視窗帶到前景)。
///
/// 用 `NSEvent.mouseLocation`(螢幕座標)+ `setFrameOrigin`,不用 SwiftUI translation:
/// 視窗跟著游標移動時,視窗座標系的 translation 會歸零 → 視窗只抖一下不動
/// (原 `CopilotOverlayView` 的把手即此解法,這裡抽成共用)。
///
/// 掛在**最外層容器**上、用 `.gesture`(非 `simultaneousGesture`/`highPriorityGesture`):
/// SwiftUI 讓子手勢優先,所以 ScrollView 捲動、按鈕點擊、cue 展開都照常運作;
/// 只有「非互動的邊框/標題/留白」區域會啟動視窗拖曳 → 達成「點視窗任一空白處都能拖」。
struct FloatingWindowDragGesture: ViewModifier {
    let currentOrigin: () -> NSPoint?
    let setOrigin: (NSPoint) -> Void
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in
                    let mouse = NSEvent.mouseLocation
                    if let start = dragStart {
                        setOrigin(NSPoint(
                            x: start.origin.x + (mouse.x - start.mouse.x),
                            y: start.origin.y + (mouse.y - start.mouse.y)))
                    } else if let origin = currentOrigin() {
                        dragStart = (mouse: mouse, origin: origin)
                    }
                }
                .onEnded { _ in dragStart = nil }
        )
    }
}

extension View {
    /// 見 `FloatingWindowDragGesture`。掛在浮動視窗的最外層容器上,配合 `.contentShape` 讓留白也可拖。
    func floatingWindowDrag(
        currentOrigin: @escaping () -> NSPoint?,
        setOrigin: @escaping (NSPoint) -> Void
    ) -> some View {
        modifier(FloatingWindowDragGesture(currentOrigin: currentOrigin, setOrigin: setOrigin))
    }
}

// MARK: - 螢幕識別

/// NSScreen 的穩定識別與顯示名,供「移到其他螢幕」用。純函式,便於未來測試。
enum MeetingScreens {
    /// 顯示器的 CoreGraphics ID(跨 `NSScreen.screens` 重建仍穩定;`frame` 在排列變動時會改)。
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// 顯示名(macOS 12+ 的 `localizedName`;空字串退回編號)。
    static func name(_ screen: NSScreen, index: Int) -> String {
        let n = screen.localizedName
        return n.isEmpty ? "螢幕 \(index + 1)" : n
    }
}

// MARK: - 螢幕排列選擇器(popover 內容)

/// 「移到其他螢幕」的示意小地圖:把實體螢幕排列畫成比例方框,點非目前的螢幕即回呼。
///
/// 用**示意縮圖**(依實體排列位置 + 尺寸比例的方框 + 顯示名),**不是真實螢幕截圖**:
/// 真截圖需要螢幕錄製權限、又與「本功能要躲開螢幕擷取」自相矛盾;示意圖零權限、即時,
/// 且足以辨識「哪台是哪台、在左在右」。鏡射系統設定的「顯示器排列方式」。
struct ScreenArrangementPicker: View {
    /// 目前浮動視窗所在螢幕的 displayID(該格顯示為「目前」且不可點)。
    let currentDisplayID: CGDirectDisplayID?
    let onPick: (NSScreen) -> Void

    private let mapWidth: CGFloat = 260
    private let mapHeight: CGFloat = 150

    var body: some View {
        let screens = NSScreen.screens
        VStack(alignment: .leading, spacing: 8) {
            Text("移到其他螢幕").font(.system(size: 12, weight: .semibold))
            if screens.count < 2 {
                Text("目前只偵測到一個螢幕。").font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(width: mapWidth, alignment: .leading)
            } else {
                map(screens)
                Text("點另一個螢幕,即把錄製列與所有浮動視窗一起移過去。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(width: mapWidth, alignment: .leading)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func map(_ screens: [NSScreen]) -> some View {
        // 所有螢幕 frame 的聯集(全域座標,AppKit y 向上)。
        let union = screens.dropFirst().reduce(screens[0].frame) { $0.union($1.frame) }
        let scale = min(mapWidth / max(union.width, 1), mapHeight / max(union.height, 1))
        let mapped = CGSize(width: union.width * scale, height: union.height * scale)
        ZStack(alignment: .topLeading) {
            ForEach(Array(screens.enumerated()), id: \.offset) { index, screen in
                let f = screen.frame
                tile(screen: screen, index: index,
                     size: CGSize(width: f.width * scale, height: f.height * scale))
                    // union 左上為原點;翻轉 y(AppKit y-up → 螢幕直覺的往下)。
                    .offset(x: (f.minX - union.minX) * scale,
                            y: (union.maxY - f.maxY) * scale)
            }
        }
        .frame(width: mapped.width, height: mapped.height, alignment: .topLeading)
        .frame(width: mapWidth, height: mapHeight, alignment: .center)
    }

    @ViewBuilder
    private func tile(screen: NSScreen, index: Int, size: CGSize) -> some View {
        let isCurrent = MeetingScreens.displayID(screen) == currentDisplayID
        let label = MeetingScreens.name(screen, index: index)
        Button {
            if !isCurrent { onPick(screen) }
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(isCurrent ? Color.secondary.opacity(0.18) : Color.accentColor.opacity(0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(isCurrent ? Color.secondary.opacity(0.6) : Color.accentColor,
                                      lineWidth: 1))
                .overlay(
                    VStack(spacing: 1) {
                        if !isCurrent {
                            Image(systemName: "arrow.up.forward.circle.fill").font(.system(size: 10))
                        }
                        Text(isCurrent ? "目前" : label)
                            .font(.system(size: 8, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.horizontal, 2)
                    }
                    .foregroundStyle(isCurrent ? Color.secondary : Color.accentColor))
                .frame(width: max(size.width, 34), height: max(size.height, 24))
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
        .help(isCurrent ? "目前所在螢幕" : "移到「\(label)」")
    }
}
