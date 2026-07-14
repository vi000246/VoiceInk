import Foundation
import SwiftData
import os

/// M9 FR-69：錄音刪除 → 關聯 session（live＋replay）跟著刪。
///
/// `.transcriptionDeleted` 是批次 nil 訊號（不帶 id）→ 只能 sweep 全量比對——
/// 鏡射 `TranscriptIndexService.reconcileOrphans`（TranscriptIndexService.swift:113-129）
/// 的既驗證形狀。空 fingerprint（未關聯任何錄音的 session）永不觸碰。
@MainActor
final class MeetingSessionReconciler {
    static let shared = MeetingSessionReconciler()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private var modelContext: ModelContext?
    private var observer: NSObjectProtocol?

    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .transcriptionDeleted, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in MeetingSessionReconciler.shared.reconcile() }
        }
    }

    /// 掃掉「指紋已無對應 Transcription」的 session。cue/segment 由 @Relationship cascade 帶走。
    func reconcile() {
        guard let ctx = modelContext else { return }
        let sessions = (try? ctx.fetch(FetchDescriptor<MeetingLiveSession>())) ?? []
        let linked = sessions.filter { !$0.importFingerprint.isEmpty }
        guard !linked.isEmpty else { return }
        let liveFingerprints = Set(
            ((try? ctx.fetch(FetchDescriptor<Transcription>())) ?? []).compactMap(\.importFingerprint))
        let orphans = linked.filter { !liveFingerprints.contains($0.importFingerprint) }
        guard !orphans.isEmpty else { return }
        for session in orphans { ctx.delete(session) }
        try? ctx.save()
        logger.notice("🧹 覆盤刪除傳播：清掉 \(orphans.count, privacy: .public) 場孤兒 session")
    }
}
