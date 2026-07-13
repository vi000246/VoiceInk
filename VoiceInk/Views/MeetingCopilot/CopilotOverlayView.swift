import SwiftUI

/// 隱蔽 overlay 的內容(FR-26)。繁中字面,不進 xcstrings(近期新頁面慣例)。
///
/// 三層漸進渲染(M3 回寫在 `MeetingLiveCue` 的欄位):
///   Tier 0 關鍵字(tier0Keywords) → Tier 1 opener + 3 bullets → Tier 2 analysis + followUps + uncertainties。
struct CopilotOverlayView: View {
    @ObservedObject var controller: MeetingCopilotController
    @ObservedObject private var config = MeetingCopilotConfigStore.shared
    /// 點「深度分析」→ 觸發 Tier 2(接 M3 AnswerCoordinator;click-through 開啟時自然不會觸發)。
    var onCueTapped: ((MeetingLiveCue) -> Void)?

    /// 手風琴:使用者手動展開的 cue(nil = 自動展開最新一則)。
    /// 面試官連問兩題時,可點任一題展開、其餘自動收成單行;新題進來仍排最上,
    /// 但不會搶走使用者正在回答的那一題的展開狀態。
    @State private var expandedCueId: UUID?

    private var arranged: [(cue: MeetingLiveCue, emphasis: CopilotOverlayEmphasis)] {
        CopilotOverlayArranger.arrange(
            controller.cues,
            askedAt: { $0.askedAt },
            isAnswered: { $0.status == .answered },
            maxCount: config.maxCuesShown)
    }

    /// 實際展開者:手動選擇優先(且仍在列表上);否則最新一則。
    private var effectiveExpandedId: UUID? {
        if let id = expandedCueId, arranged.contains(where: { $0.cue.id == id }) { return id }
        return arranged.first?.cue.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            gripBar
            shareWarningBanner
            // cue 列表可捲動:文字全面換行後,長分析可能超出卡片高度上限。
            // 把手與警告條留在捲動區外,拖曳手勢才不會和捲動打架。
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if arranged.isEmpty {
                        Text("等待對方提問…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        let expandedId = effectiveExpandedId
                        ForEach(Array(arranged.enumerated()), id: \.offset) { _, item in
                            if item.cue.id == expandedId {
                                focusCard(item.cue)
                            } else {
                                collapsedRow(item.cue)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)   // 內容少時卡片跟著縮,不留空白
        }
        .padding(14)
        // 寬度由 panel 決定(≈ 螢幕寬 1/3,見 CopilotOverlayWindowManager.hostSize)。
        .frame(maxWidth: .infinity, alignment: .leading)
        // 深色實心底 + 白字高對比(使用者要求:不透明、不跟隨系統淺色主題)。
        // 不用 material——material 半透明,底下畫面透出來會降低可讀性。
        .background(Color(red: 0.09, green: 0.10, blue: 0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .environment(\.colorScheme, .dark)   // .primary/.secondary 一律解析成淺色
        // 整窗拖曳:點任一空白/邊框/標題處都能拖(ScrollView 捲動、cue 點擊、深度分析仍優先)。
        .contentShape(Rectangle())
        .floatingWindowDrag(
            currentOrigin: { CopilotOverlayWindowManager.shared.panelOrigin },
            setOrigin: { CopilotOverlayWindowManager.shared.setPanelOrigin($0) })
    }

    // MARK: - 拖曳把手(視覺提示;實際拖曳由整窗 floatingWindowDrag 處理)

    private var gripBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .semibold))
            Text("會議輔助").font(.system(size: 10, weight: .semibold))
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 常駐螢幕分享警告(誠實邊界,不得省略)

    private var shareWarningBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 9))
            Text("分享「整個螢幕」時此視窗會被錄到——請只分享單一視窗/分頁")
                .font(.system(size: 9))
        }
        .foregroundStyle(.orange)
        .lineLimit(2)
    }

    // MARK: - 單則 cue

    /// 收合列:點擊 = 展開這一題(手風琴——其餘自動收合)。已回答者更淡。
    private func collapsedRow(_ cue: MeetingLiveCue) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(cue.text)
                .font(.system(size: 12, weight: cue.status == .answered ? .regular : .medium))
                .foregroundStyle(cue.status == .answered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(2)   // 收合列保持精簡,但至少讓長問題看得出在問什麼
                .fixedSize(horizontal: false, vertical: true)
        }
        .contentShape(Rectangle())
        .onTapGesture { expandedCueId = cue.id }
    }

    /// focus cue:opener 最大字級單獨呈現(FR-26 的核心——讓你能直接照著念)。
    @ViewBuilder
    private func focusCard(_ cue: MeetingLiveCue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // cue 原句 + Tier 0 關鍵字
            Text(cue.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)   // 展開的問題全文換行,不截斷
            if !cue.tier0Keywords.isEmpty {
                Text(cue.tier0Keywords)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))   // 深底上可讀的亮藍
            }

            // Tier 1:開口稿(最大字級)+ 3 bullets
            if !cue.tier1Opener.isEmpty {
                Text(cue.tier1Opener)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(cue.tier1Bullets.filter { !$0.isEmpty }, id: \.self) { b in
                    Label(b, systemImage: "circle.fill")
                        .font(.system(size: 12))
                        .labelStyle(BulletLabelStyle())
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("準備開口稿中…").font(.system(size: 12)).foregroundStyle(.secondary)
            }

            // Tier 2:深度 + follow-up 預判 + 不確定
            if !cue.tier2Analysis.isEmpty {
                Divider()
                Text(cue.tier2Analysis)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if !cue.tier2FollowUps.isEmpty {
                    Text("可能追問").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(cue.tier2FollowUps, id: \.self) { f in
                        Text("· \(f)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !cue.tier2Uncertainties.isEmpty {
                    ForEach(cue.tier2Uncertainties, id: \.self) { u in
                        Label(u, systemImage: "questionmark.circle")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            } else if controller.deepInFlightCueId == cue.id {
                // Tier 2 在跑(等 Tier 1 → RAG/OCR 接地 → deep model 串流,可能十幾秒)。
                // 沒有這個狀態時,點了按鈕到結果出現之間 UI 零回饋,看起來像壞掉。
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("深度分析中…(檢索接地資料+深模型,約需十餘秒)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                // 只有這行文字可觸發 Tier 2——整張卡不再是點擊區,
                // 避免收合/展開操作誤觸深度分析。
                Text("▶ 深度分析")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                    .contentShape(Rectangle())
                    .onTapGesture { onCueTapped?(cue) }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
