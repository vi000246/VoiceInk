import SwiftUI

/// 隱蔽 overlay 的內容(FR-26)。繁中字面,不進 xcstrings(近期新頁面慣例)。
///
/// 三層漸進渲染(M3 回寫在 `MeetingLiveCue` 的欄位):
///   Tier 0 關鍵字(tier0Keywords) → Tier 1 opener + 3 bullets → Tier 2 analysis + followUps + uncertainties。
struct CopilotOverlayView: View {
    @ObservedObject var controller: MeetingCopilotController
    @ObservedObject private var config = MeetingCopilotConfigStore.shared
    /// 點一則 cue → 觸發 Tier 2(接 M3 AnswerCoordinator;click-through 開啟時自然不會觸發)。
    var onCueTapped: ((MeetingLiveCue) -> Void)?

    private var arranged: [(cue: MeetingLiveCue, emphasis: CopilotOverlayEmphasis)] {
        CopilotOverlayArranger.arrange(
            controller.cues,
            askedAt: { $0.askedAt },
            isAnswered: { $0.status == .answered },
            maxCount: config.maxCuesShown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            shareWarningBanner
            if arranged.isEmpty {
                Text("等待對方提問…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(arranged.enumerated()), id: \.offset) { _, item in
                    cueRow(item.cue, emphasis: item.emphasis)
                }
            }
        }
        .padding(14)
        .frame(width: 360, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
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

    @ViewBuilder
    private func cueRow(_ cue: MeetingLiveCue, emphasis: CopilotOverlayEmphasis) -> some View {
        switch emphasis {
        case .focus:
            focusCard(cue)
        case .recent:
            Text(cue.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { onCueTapped?(cue) }
        case .answered:
            Text(cue.text)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { onCueTapped?(cue) }
        }
    }

    /// focus cue:opener 最大字級單獨呈現(FR-26 的核心——讓你能直接照著念)。
    @ViewBuilder
    private func focusCard(_ cue: MeetingLiveCue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // cue 原句 + Tier 0 關鍵字
            Text(cue.text)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2)
            if !cue.tier0Keywords.isEmpty {
                Text(cue.tier0Keywords)
                    .font(.system(size: 10))
                    .foregroundStyle(.blue)
            }

            // Tier 1:開口稿(最大字級)+ 3 bullets
            if !cue.tier1Opener.isEmpty {
                Text(cue.tier1Opener)
                    .font(.system(size: 20, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(cue.tier1Bullets.filter { !$0.isEmpty }, id: \.self) { b in
                    Label(b, systemImage: "circle.fill")
                        .font(.system(size: 12))
                        .labelStyle(BulletLabelStyle())
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
                    }
                }
                if !cue.tier2Uncertainties.isEmpty {
                    ForEach(cue.tier2Uncertainties, id: \.self) { u in
                        Label(u, systemImage: "questionmark.circle")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            } else {
                Text("點此展開深度分析")
                    .font(.system(size: 11))
                    .foregroundStyle(.blue)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture { onCueTapped?(cue) }
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
