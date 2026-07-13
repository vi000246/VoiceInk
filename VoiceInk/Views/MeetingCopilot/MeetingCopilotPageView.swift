import SwiftUI
import SwiftData

// MARK: - Row display helpers

/// 管理頁列的顯示邏輯。非 private、吃原始值不吃 @Model —— 供單元測試
/// (鏡射 `VoiceRowDisplay`,VoiceLibraryView.swift:207 的檔內非 private enum 慣例)。
enum MeetingRowDisplay {

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_TW")
        f.timeZone = TimeZone(identifier: "Asia/Taipei")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    /// 列標題:會議沒有使用者命名,一律從開始時間組(例:「7月12日 14:30 會議」)。
    static func title(startedAt: Date) -> String {
        titleFormatter.string(from: startedAt) + " 會議"
    }

    /// 時長:「47 分」;不足 1 分「<1 分」;endedAt nil = 進行中。
    static func durationText(startedAt: Date, endedAt: Date?) -> String {
        guard let end = endedAt else { return "進行中" }
        let minutes = Int(end.timeIntervalSince(startedAt) / 60)
        return minutes < 1 ? "<1 分" : "\(minutes) 分"
    }

    /// cue 數徽章:0 顯示「—」。
    static func cueCountText(_ count: Int) -> String {
        count == 0 ? "—" : "\(count) 則"
    }
}

// MARK: - 會議錄音管理頁

/// 「會議錄音管理」頁:會議列表 + 詳情 modal(雙軌逐字稿 + cue 三層回應)。
/// clone `VoiceLibraryView` 的表格 + centeredModal 結構(繁中字面,不進 xcstrings)。
struct MeetingCopilotPageView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MeetingLiveSession.startedAt, order: .reverse)
    private var sessions: [MeetingLiveSession]

    @State private var detailTarget: MeetingLiveSession?
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "會議錄音管理",
                infoMessage: "會議即時輔助的紀錄:每場會議偵測到的問題(cue)與三層回應建議。⚠️ 分享「整個螢幕」時輔助浮動視窗會被錄到——請只分享單一視窗/分頁。",
                infoURL: nil
            ) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                }
                .help("會議即時輔助設定")
            }

            Divider()

            if sessions.isEmpty {
                emptyState
            } else {
                MeetingTableHeader()
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sessions) { session in
                            MeetingSessionRow(session: session, onOpen: { detailTarget = session })
                            Divider().opacity(0.35)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .centeredModal(item: $detailTarget) { session in
            MeetingSessionDetailSheet(session: session, onClose: { detailTarget = nil })
                .frame(maxWidth: 900, maxHeight: 820)
                .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.Border.control, lineWidth: 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
        .centeredModal(isPresented: $showSettings) {
            MeetingCopilotSettingsView(onClose: { showSettings = false })
                .frame(maxWidth: 640, maxHeight: 760)
                .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.Border.control, lineWidth: 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.2.wave.2").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("尚無會議紀錄").font(.system(size: 14, weight: .medium))
            Text("開會時啟用「會議即時輔助」,偵測到的問題與回應建議會出現在這裡。")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 表頭 / 列

private struct MeetingTableHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("會議").frame(maxWidth: .infinity, alignment: .leading)
            Text("時間").frame(width: 150, alignment: .leading)
            Text("問題數").frame(width: 70, alignment: .trailing)
            Text("時長").frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(height: 20)
        .padding(.horizontal, 24).padding(.vertical, 6)
    }
}

private struct MeetingSessionRow: View {
    let session: MeetingLiveSession
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(MeetingRowDisplay.title(startedAt: session.startedAt))
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !session.appName.isEmpty {
                    Text(session.appName).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(session.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)

            Text(MeetingRowDisplay.cueCountText(session.cues?.count ?? 0))
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)

            Text(MeetingRowDisplay.durationText(startedAt: session.startedAt, endedAt: session.endedAt))
                .font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 24).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}

// MARK: - 詳情 modal

private struct MeetingSessionDetailSheet: View {
    let session: MeetingLiveSession
    let onClose: () -> Void

    private var sortedCues: [MeetingLiveCue] {
        (session.cues ?? []).sorted { $0.askedAt < $1.askedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AppPanelHeader(title: LocalizedStringKey(MeetingRowDisplay.title(startedAt: session.startedAt)), onClose: onClose)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !session.brief.isEmpty {
                        section("會前 brief") { Text(session.brief).font(.system(size: 12)) }
                    }
                    section("偵測到的問題與回應（\(sortedCues.count)）") {
                        if sortedCues.isEmpty {
                            Text("這場會議沒有偵測到需要回應的問題。").font(.system(size: 12)).foregroundStyle(.secondary)
                        } else {
                            ForEach(sortedCues) { cue in cueBlock(cue) }
                        }
                    }
                    if !session.remoteTranscriptRaw.isEmpty {
                        section("對方逐字稿") {
                            Text(session.remoteTranscriptRaw).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    if !session.localTranscriptRaw.isEmpty {
                        section("我的逐字稿") {
                            Text(session.localTranscriptRaw).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
    }

    @ViewBuilder
    private func cueBlock(_ cue: MeetingLiveCue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(cue.kind.displayLabelZH).font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.blue.opacity(0.15))).foregroundStyle(.blue)
                Text(cue.text).font(.system(size: 12, weight: .medium))
            }
            if !cue.tier1Opener.isEmpty {
                Text("開口稿:\(cue.tier1Opener)").font(.system(size: 12))
                ForEach(cue.tier1Bullets.filter { !$0.isEmpty }, id: \.self) { b in
                    Text("· \(b)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !cue.tier2Analysis.isEmpty {
                Text(cue.tier2Analysis).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.8))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension MeetingCueKind {
    var displayLabelZH: String {
        switch self {
        case .directQuestion: return "問題"
        case .impliedChallenge: return "質疑"
        case .assignedToMe: return "點名"
        case .informational: return "資訊"
        }
    }
}
