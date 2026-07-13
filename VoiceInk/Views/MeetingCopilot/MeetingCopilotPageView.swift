import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

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
    // 批次刪除（鏡射 RecorderHistoryView 的勾選 + selection bar 模式）。
    @State private var selectedIds: Set<UUID> = []
    @State private var confirmBatchDelete = false

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "會議copilot覆盤",
                infoMessage: "會議即時輔助的覆盤:每場會議偵測到的問題(cue)與三層回應建議。⚠️ 分享「整個螢幕」時輔助浮動視窗會被錄到——請只分享單一視窗/分頁。",
                infoURL: nil
            ) {
                Button { AppNavigator.shared.navigate(to: .meetingCopilotSettings) } label: {
                    Image(systemName: "gearshape.fill")
                }
                .help("會議copilot設定")
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
                            MeetingSessionRow(
                                session: session,
                                isChecked: selectedIds.contains(session.id),
                                onToggleCheck: { toggle(session.id) },
                                onOpen: { detailTarget = session })
                            Divider().opacity(0.35)
                        }
                    }
                }
                Divider()
                selectionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 錄音管理「會議copilot覆盤」按鈕導過來時,直接展開對應 session 的詳情。
        // @Published 會對新訂閱者重放目前值,所以「先導頁、頁面才建立」的順序也吃得到。
        .onReceive(AppNavigator.shared.$pendingMeetingSessionId) { id in
            guard let id, let target = sessions.first(where: { $0.id == id }) else { return }
            detailTarget = target
            DispatchQueue.main.async { AppNavigator.shared.consumePendingMeetingSession() }
        }
        .confirmationDialog("刪除所選 \(selectedIds.count) 場會議？偵測到的問題、回應建議與雙軌逐字稿都會移除（已匯入的錄音檔不受影響）。",
                            isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("刪除 \(selectedIds.count) 場", role: .destructive) { performBatchDelete() }
        }
        .centeredModal(item: $detailTarget) { session in
            MeetingSessionDetailSheet(session: session, onClose: { detailTarget = nil })
                .frame(maxWidth: 900, maxHeight: 820)
                .background(AppTheme.Surface.window, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AppTheme.Border.control, lineWidth: 0.6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 24, y: 10)
        }
    }

    // MARK: - 批次刪除

    private var allSelected: Bool {
        !sessions.isEmpty && sessions.allSatisfy { selectedIds.contains($0.id) }
    }

    private func toggle(_ id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) } else { selectedIds.insert(id) }
    }

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Button(allSelected ? "取消全選" : "全選") {
                if allSelected { selectedIds.removeAll() }
                else { selectedIds = Set(sessions.map { $0.id }) }
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
            if !selectedIds.isEmpty {
                Text("已選 \(selectedIds.count) 場").font(.system(size: 13)).foregroundColor(.secondary)
            }
            Spacer()
            if !selectedIds.isEmpty {
                Button { confirmBatchDelete = true } label: {
                    Label("刪除所選", systemImage: "trash").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain).foregroundColor(AppTheme.Status.error.opacity(0.85))
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(AppTheme.Surface.window.shadow(color: .black.opacity(0.1), radius: 3, y: -2))
    }

    private func performBatchDelete() {
        // cue 由 @Relationship(deleteRule: .cascade) 一併刪除;錄音檔屬 Transcription,不在此範圍。
        for session in sessions where selectedIds.contains(session.id) {
            modelContext.delete(session)
        }
        try? modelContext.save()
        selectedIds.removeAll()
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
            Color.clear.frame(width: 15, height: 1)   // 對齊：勾選欄
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
    let isChecked: Bool
    let onToggleCheck: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggleCheck) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isChecked ? AppTheme.Accent.primary : .secondary)
            }
            .buttonStyle(.plain).frame(width: 15)

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
        .background(isChecked ? AppTheme.Accent.primary.opacity(0.06) : Color.clear)
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

    private var sortedSegments: [MeetingLiveSegment] {
        (session.segments ?? []).sorted { $0.committedAt < $1.committedAt }
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
                                .textSelection(.enabled)
                        }
                    }
                    if !session.localTranscriptRaw.isEmpty {
                        section("我的逐字稿") {
                            Text(session.localTranscriptRaw).font(.system(size: 11)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if !sortedSegments.isEmpty {
                        section("逐字稿時間軸與偵測紀錄（\(sortedSegments.count) 段）") {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(sortedSegments) { seg in segmentBlock(seg) }
                                }
                                .padding(.top, 6)
                            } label: {
                                Text("展開逐段偵測紀錄（每段 committed 的抽取結果與耗時）")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !session.configSnapshotRaw.isEmpty {
                        section("執行設定快照") {
                            DisclosureGroup {
                                Text(session.configSnapshotRaw)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 6)
                            } label: {
                                Text("當場的模型、開關、prompt 與去重參數（JSON）")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    exportRow
                }
                .padding(20)
            }
        }
    }

    // MARK: - 診斷匯出

    private var exportRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                exportDiagnostics()
            } label: {
                Label("匯出診斷 JSON", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            Text("完整原始資料：逐字稿時間軸、每段抽取結果、每則 cue 的三層 prompt／原始回覆／耗時／錯誤、設定快照。可直接餵給 AI 做「漏抓／誤抓／答非所問」的調校分析。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        panel.nameFieldStringValue = "meeting-copilot-\(formatter.string(from: session.startedAt)).json"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = MeetingSessionDiagnostics.build(from: session).encodedJSON() else { return }
        try? data.write(to: url)
    }

    // MARK: - Segment 時間軸

    @ViewBuilder
    private func segmentBlock(_ seg: MeetingLiveSegment) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(seg.channel == .remote ? "對方" : "我")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill((seg.channel == .remote ? Color.orange : Color.green).opacity(0.15)))
                    .foregroundStyle(seg.channel == .remote ? .orange : .green)
                Text(seg.committedAt, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                if seg.channel == .remote {
                    Text(Self.extractionSummary(seg)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Text(seg.text).font(.system(size: 11)).textSelection(.enabled)
            if !seg.extractionError.isEmpty {
                Text("抽取失敗：\(seg.extractionError)")
                    .font(.system(size: 10)).foregroundStyle(AppTheme.Status.error)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    /// remote 段的抽取摘要(非 private 供未來測試;吃原始值)。
    static func extractionSummary(_ seg: MeetingLiveSegment) -> String {
        guard seg.extractedCount >= 0 else { return "未跑抽取" }
        var parts = ["抽出 \(seg.extractedCount) 則", "\(seg.extractionElapsedMs)ms"]
        if seg.dedupDroppedCount > 0 { parts.append("去重丟 \(seg.dedupDroppedCount)") }
        if !seg.extractionModel.isEmpty { parts.append(seg.extractionModel) }
        return parts.joined(separator: " · ")
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
            cueDiagnostics(cue)
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - cue 診斷細節(觀測資料;預設收合,不干擾覆盤主流程)

    @ViewBuilder
    private func cueDiagnostics(_ cue: MeetingLiveCue) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                let metrics = Self.cueMetricsLine(cue)
                if !metrics.isEmpty {
                    Text(metrics).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !cue.contextExcerpt.isEmpty {
                    diagText("觸發片段（committed 節錄）", cue.contextExcerpt)
                }
                if !cue.tier1Error.isEmpty {
                    Text("Tier 1 失敗：\(cue.tier1Error)")
                        .font(.system(size: 10)).foregroundStyle(AppTheme.Status.error)
                }
                if !cue.tier1GroundingNote.isEmpty {
                    Text(cue.tier1GroundingNote).font(.system(size: 10)).foregroundStyle(.orange)
                }
                if !cue.tier1PromptUser.isEmpty {
                    diagText("Tier 1 prompt（user，含接地）", cue.tier1PromptUser)
                }
                if !cue.tier1RawReply.isEmpty {
                    diagText("Tier 1 原始回覆", cue.tier1RawReply)
                }
                if !cue.tier2Error.isEmpty {
                    Text("Tier 2 失敗：\(cue.tier2Error)")
                        .font(.system(size: 10)).foregroundStyle(AppTheme.Status.error)
                }
                if !cue.tier2GroundingNote.isEmpty {
                    Text(cue.tier2GroundingNote).font(.system(size: 10)).foregroundStyle(.orange)
                }
                if !cue.tier2PromptUser.isEmpty {
                    diagText("Tier 2 prompt（user，含草稿＋接地＋螢幕）", cue.tier2PromptUser)
                }
                if !cue.tier2RawReply.isEmpty {
                    diagText("Tier 2 原始回覆", cue.tier2RawReply)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("診斷").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func diagText(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            Text(content)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 一行耗時/模型摘要(非 private 供未來測試;吃 @Model 但只讀原始欄位)。
    static func cueMetricsLine(_ cue: MeetingLiveCue) -> String {
        var parts: [String] = []
        if cue.detectionElapsedMs > 0 { parts.append("偵測 \(cue.detectionElapsedMs)ms") }
        if cue.tier1ElapsedMs > 0 { parts.append("Tier1 \(cue.tier1ElapsedMs)ms") }
        if cue.tier2StreamElapsedMs > 0 {
            parts.append("Tier2 接地 \(cue.tier2GroundingElapsedMs)ms＋串流 \(cue.tier2StreamElapsedMs)ms")
        }
        if !cue.fastModelName.isEmpty { parts.append("fast＝\(cue.fastModelName)") }
        if !cue.deepModelName.isEmpty { parts.append("deep＝\(cue.deepModelName)") }
        return parts.joined(separator: " · ")
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
