import SwiftUI

/// 讀稿檢視的狀態(M7)。抽成獨立 `ObservableObject` 便於純單元測試(FR-36)。
/// `selectedId == nil` → 講稿清單層;否則 → 讀稿層(顯示該稿正文)。
@MainActor
final class PresenterScriptReaderModel: ObservableObject {
    @Published var selectedId: UUID?

    enum Mode: Equatable { case list, reading(UUID) }
    var mode: Mode { selectedId.map { .reading($0) } ?? .list }

    func select(_ id: UUID) { selectedId = id }
    func backToList() { selectedId = nil }

    /// 目前選定講稿的正文;無選定或找不到 → nil。
    func body(for scripts: [PresenterScript]) -> String? {
        guard let id = selectedId else { return nil }
        return scripts.first(where: { $0.id == id })?.body
    }
}

/// 私人提詞面板的內容(M7,FR-36/37/39)。
///
/// **只顯示使用者自寫的講稿** —— 不接 AI/ASR、不讀 cue。深色恆不透明高對比(鏡射 cue overlay)。
/// 兩層導覽:講稿清單 ↔ 讀稿檢視(頂部 chips 快速切換 +「← 講稿清單」一鍵回清單)。
struct PresenterScriptView: View {
    @ObservedObject private var store = PresenterScriptStore.shared
    @StateObject private var model = PresenterScriptReaderModel()

    static let emptyHint = "尚無講稿——到「會議copilot設定 → 預設講稿」新增你自己的講稿。"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            gripBar
            shareWarningBanner

            if store.scripts.isEmpty {
                emptyState
            } else if let id = model.selectedId, store.scripts.contains(where: { $0.id == id }) {
                reader(selectedId: id)
            } else {
                listView
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 深色實心底 + 白字(恆不透明,不跟隨系統淺色主題),鏡射 cue overlay。
        .background(Color(red: 0.09, green: 0.10, blue: 0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        // 整窗拖曳:點任一空白/邊框/標題處都能拖(講稿捲動、清單點擊仍優先)。
        .contentShape(Rectangle())
        .floatingWindowDrag(
            currentOrigin: { PresenterScriptWindowManager.shared.panelOrigin },
            setOrigin: { PresenterScriptWindowManager.shared.setPanelOrigin($0) })
    }

    // MARK: - 拖曳把手(視覺提示;實際拖曳由整窗 floatingWindowDrag 處理)

    private var gripBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .semibold))
            Text("預設講稿").font(.system(size: 10, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 誠實邊界(沿用 cue overlay 的警語,不得省略)

    private var shareWarningBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 9))
            Text("分享「整個螢幕」時此視窗會被錄到——請只分享單一視窗/分頁")
                .font(.system(size: 9))
        }
        .foregroundStyle(.orange)
        .lineLimit(2)
    }

    // MARK: - 空狀態

    private var emptyState: some View {
        Text(Self.emptyHint)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    // MARK: - 講稿清單層

    private var listView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("點一則講稿開始看稿").font(.system(size: 10)).foregroundStyle(.secondary)
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.scripts) { s in
                        Button { model.select(s.id) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(s.title.isEmpty ? "（未命名）" : s.title)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 480)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 讀稿層

    @ViewBuilder
    private func reader(selectedId: UUID) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // 頂部工具列:回清單 + 字級 A− / A+
            HStack(spacing: 8) {
                Button { model.backToList() } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        Text("講稿清單").font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                }
                .buttonStyle(.plain)
                Spacer()
                Button { store.setFontSize(store.fontSize - 2) } label: {
                    Text("A−").font(.system(size: 12, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button { store.setFontSize(store.fontSize + 2) } label: {
                    Text("A+").font(.system(size: 14, weight: .semibold))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }

            // 標題 chips:快速切換,點即切,不必回清單
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(store.scripts) { s in
                        let isCurrent = s.id == selectedId
                        Button { model.select(s.id) } label: {
                            Text(s.title.isEmpty ? "（未命名）" : s.title)
                                .font(.system(size: 11, weight: isCurrent ? .bold : .regular))
                                .foregroundStyle(isCurrent ? .white : .secondary)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(
                                    Capsule().fill(isCurrent
                                        ? Color(red: 0.45, green: 0.72, blue: 1.0).opacity(0.30)
                                        : Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 2)
            }

            Divider().overlay(Color.white.opacity(0.15))

            // 讀稿正文:大字、全文換行、可捲動
            ScrollView(.vertical, showsIndicators: true) {
                Text(currentBody(selectedId))
                    .font(.system(size: store.fontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .lineSpacing(store.fontSize * 0.28)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func currentBody(_ id: UUID) -> String {
        let body = store.scripts.first(where: { $0.id == id })?.body ?? ""
        return body.isEmpty ? "（這則講稿還沒有內容）" : body
    }
}
