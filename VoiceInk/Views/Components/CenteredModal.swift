import SwiftUI

/// 置中的浮層 modal（取代 `.sheet`，因為 macOS 的 sheet 不支援「點視窗外關閉」）。
/// 提供暗色背景遮罩：點背景即關閉;Esc 也關閉。內容自行決定尺寸與關閉按鈕。
private struct CenteredModalItem<Item: Identifiable, ModalContent: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let modalContent: (Item) -> ModalContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
            if let item {
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { self.item = nil }         // 點視窗外關閉
                    .transition(.opacity)
                modalContent(item)
                    .onExitCommand { self.item = nil }        // Esc 關閉
                    .padding(40)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.18), value: item != nil)
    }
}

private struct CenteredModalBool<ModalContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    @ViewBuilder let modalContent: () -> ModalContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack {
            content
            if isPresented {
                Rectangle()
                    .fill(Color.black.opacity(0.4))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { isPresented = false }
                    .transition(.opacity)
                modalContent()
                    .onExitCommand { isPresented = false }
                    .padding(40)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(1)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .easeInOut(duration: 0.18), value: isPresented)
    }
}

extension View {
    /// 以 Identifiable item 驅動的置中 modal（點外面 / Esc 關閉）。
    func centeredModal<Item: Identifiable, C: View>(
        item: Binding<Item?>, @ViewBuilder content: @escaping (Item) -> C) -> some View {
        modifier(CenteredModalItem(item: item, modalContent: content))
    }

    /// 以 Bool 驅動的置中 modal（點外面 / Esc 關閉）。
    func centeredModal<C: View>(
        isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(CenteredModalBool(isPresented: isPresented, modalContent: content))
    }
}
