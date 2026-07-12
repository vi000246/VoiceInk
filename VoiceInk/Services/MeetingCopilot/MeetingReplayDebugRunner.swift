#if DEBUG
import Foundation
import AppKit
import SwiftData
import os

/// **DEBUG 專用**:用**真實的** ASR 跑一個預錄音檔,走完整的 meeting-copilot pipeline,
/// 完全**不需要開啟任何會議軟體**。
///
/// # 為什麼需要這個(而不是靠 XCTest)
///
/// `MeetingCopilotReplayTests` 用的是 `FakeMeetingTranscriptStream` —— 它驗證**接線**
/// (分流 → 降頻 → 雙路 → 講者歸屬),但**不驗證真實 ASR 能不能吃我們產出的音訊格式**。
///
/// 那件事在 XCTest 裡驗不了:host-app 測試 + CoreAudio headless 脆弱 + FluidAudio 需要
/// 先下載 CoreML 模型。所以留這個人工入口。
///
/// # 用法
///
/// 1. 錄一段自己講話的音檔(例如講「你會怎麼設計一個短網址服務？」),存成 wav/m4a。
/// 2. 選單 → 「Replay 會議音檔…（DEBUG）」→ 選那個檔。
/// 3. Console.app 過濾 `🎧` → 應該看到真實 ASR 的 partial / committed 文字流出來。
///
/// 這證明 source → 降頻 → **真 ASR** → 講者歸屬 整條路在真實模型下可用。
@MainActor
final class MeetingReplayDebugRunner {

    static let shared = MeetingReplayDebugRunner()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")
    private var transcriber: MeetingLiveTranscriber?

    private init() {}

    func run() async {
        // 已經在跑 → 停掉
        if let existing = transcriber {
            await existing.stop()
            transcriber = nil
            logger.notice("🎧 [replay] stopped")
            NotificationManager.shared.showNotification(title: "Replay 已停止", type: .info)
            return
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "選一個「對方聲音」的音檔（模擬會議中對方在說話）"
        panel.prompt = "Replay"

        guard panel.runModal() == .OK, let remoteURL = panel.url else { return }

        // 找一個支援串流的模型(優先用設定裡選的)
        let configured = MeetingCopilotConfigStore.shared.asrModelName
        let streamingModels = TranscriptionModelRegistry.models.filter { $0.supportsStreaming }

        guard let model = streamingModels.first(where: { $0.name == configured })
                ?? streamingModels.first else {
            logger.error("🎧 [replay] 找不到任何支援串流的轉錄模型")
            NotificationManager.shared.showNotification(
                title: "找不到支援串流的模型",
                type: .error
            )
            return
        }

        guard let container = try? ModelContainer(for: Transcription.self) else {
            logger.error("🎧 [replay] 無法建立 ModelContainer")
            return
        }
        let context = ModelContext(container)

        logger.notice("🎧 [replay] 開始 — file=\(remoteURL.lastPathComponent, privacy: .public) model=\(model.displayName, privacy: .public)")
        logger.notice("🎧 [replay] tapFirst=\(MeetingChannelLayout.tapFirst, privacy: .public) isVerified=\(MeetingChannelLayout.isVerified, privacy: .public)")

        let source = ReplayMeetingAudioSource(remoteURL: remoteURL, localURL: nil, speed: 1.0)
        let remoteStream = LiveMeetingTranscriptStream(
            modelContext: context,
            model: model,
            label: "remote"
        )

        let t = MeetingLiveTranscriber(
            source: source,
            remoteStream: remoteStream,
            localStream: nil
        )

        t.onRemoteCommitted = { [weak self] text in
            self?.logger.notice("🎧 [replay] COMMITTED ▸ \(text, privacy: .public)")
        }

        do {
            try await t.start()
            transcriber = t
            NotificationManager.shared.showNotification(
                title: "Replay 開始 — Console 過濾 🎧",
                type: .info
            )
        } catch {
            logger.error("🎧 [replay] start failed: \(error.localizedDescription, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: "Replay 失敗:\(error.localizedDescription)",
                type: .error
            )
        }
    }
}
#endif
