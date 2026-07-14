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
        // 🔴 捕獲 self,**不能**寫死 `MeetingSessionReconciler.shared`:那樣的話,任何非 shared 實例
        // 呼叫 configure() 都只是替 shared 註冊了一個通知——自己的 modelContext 永遠不會被用到,
        // instance 這條路是永久 no-op(測試因此測不到接線,正式碼只是「剛好」只有 shared 被 configure)。
        observer = NotificationCenter.default.addObserver(
            forName: .transcriptionDeleted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconcile() }
        }
    }

    /// block-based observer 不會自動註銷:實例(例如測試裡的)消失後,那個 block 仍掛在
    /// NotificationCenter 上,漏進後續所有測試。weak self 讓它變成 no-op,這裡再把 token 收掉。
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
