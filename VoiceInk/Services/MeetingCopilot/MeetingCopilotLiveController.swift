import Foundation
import SwiftData
import os

/// 執行期整合:把 M1–M4 的元件接成一條 live pipeline。
///
/// 生命週期跟著會議錄製走(`MeetingCaptureController.start/stopAndImport` 各呼叫一次),
/// 只在 `copilotEnabled` 時運作。隔離在此,讓 `MeetingCaptureController` 只多兩個 call-out。
///
/// 資料流(全部已由 M1–M4 建置且測試):
/// ```
/// MeetingCaptureService.copilotRingBuffer(realtime seam)
///   → LiveMeetingAudioSource(切分 remote/local)
///   → MeetingLiveTranscriber(雙路串流 ASR)
///       ├─ onRemoteCommitted → MeetingCopilotController(cue 偵測 + persist)
///       │                        → AnswerCoordinator(Tier0 + 預跑 Tier1)
///       └─ onLocalLevel → CopilotOverlayWindowManager(說話淡出)
///   overlay 點 cue → AnswerCoordinator.requestDeep(Tier2)
/// ```
@MainActor
final class MeetingCopilotLiveController {

    static let shared = MeetingCopilotLiveController()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    // 由 VoiceInk.swift 在啟動時注入(mainContext 跨全部 store)。
    private var aiService: AIService?
    private var modelContext: ModelContext?

    // 本次會議的 live 元件(stop 時釋放)。
    private var transcriber: MeetingLiveTranscriber?
    private var controller: MeetingCopilotController?
    private var coordinator: AnswerCoordinator?
    /// grounding 需持有**單一**長生命週期 ScreenCaptureService 實例(per-instance reentrancy guard)。
    private var grounding: MeetingGroundingProvider?

    private init() {}

    /// 啟動時注入依賴(比照 RecorderImportService.shared.configure,VoiceInk.swift:135)。
    func configure(aiService: AIService, modelContext: ModelContext) {
        self.aiService = aiService
        self.modelContext = modelContext
    }

    /// 會議擷取啟動、且 `copilotEnabled` 時呼叫。ring / tapChannelCount 來自 `MeetingCaptureService`。
    func start(ring: MeetingPCMRingBuffer, tapChannelCount: Int, appName: String) {
        guard transcriber == nil else { return }   // 已在跑
        guard let aiService, let modelContext else {
            logger.error("🎧 copilot live start: 尚未 configure(aiService/modelContext)")
            return
        }
        let config = MeetingCopilotConfigStore.shared

        // 1. ASR model(取設定值;退回第一個支援串流的)。
        let streamingModels = TranscriptionModelRegistry.models.filter { $0.supportsStreaming }
        guard let asrModel = streamingModels.first(where: { $0.name == config.asrModelName })
                ?? streamingModels.first else {
            logger.error("🎧 copilot live start: 找不到支援串流的 ASR 模型")
            return
        }

        // 2. 音源 + 雙路轉錄。
        let source = LiveMeetingAudioSource(ring: ring, tapChannelCount: tapChannelCount)
        let remoteStream = LiveMeetingTranscriptStream(modelContext: modelContext, model: asrModel, label: "remote")
        let localStream: MeetingTranscriptStream? = config.transcribeLocalMic
            ? LiveMeetingTranscriptStream(modelContext: modelContext, model: asrModel, label: "local")
            : nil
        let transcriber = MeetingLiveTranscriber(source: source, remoteStream: remoteStream, localStream: localStream)

        // 3. cue 偵測 controller。
        let extractor = ResponseCueExtractor(
            chat: MeetingCopilotController.makeFastCompleter(aiService: aiService, config: config))
        let controller = MeetingCopilotController(extractor: extractor, config: config, modelContext: modelContext)

        // 4. 三層回應 coordinator。
        let grounding = MeetingGroundingProvider(
            embedder: LiveEmbedder(),
            screen: ScreenCaptureService(),
            modelContext: modelContext)
        let coordinator = AnswerCoordinator(
            fast: makeStreamingCompleter(provider: config.fastProviderName, model: config.fastModelName, aiService: aiService),
            deep: makeStreamingCompleter(provider: config.deepProviderName, model: config.deepModelName, aiService: aiService),
            grounding: grounding,
            config: config)
        controller.answerCoordinator = coordinator

        // 5. overlay 接線 —— **必須在 transcriber.start() 之前**(onLocalLevel 於 pump 啟動時定格)。
        CopilotOverlayWindowManager.shared.configure(
            controller: controller,
            transcriber: transcriber,
            onCueTapped: { cue in Task { await coordinator.requestDeep(cue) } })

        // 6. 掛 cue pipeline(內含 beginSession)+ 啟動轉錄。
        controller.attach(to: transcriber, appName: appName)
        Task {
            do {
                try await transcriber.start()
                self.logger.notice("🎧 copilot live pipeline started (asr=\(asrModel.displayName, privacy: .public))")
            } catch {
                self.logger.error("🎧 copilot transcriber start failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        self.transcriber = transcriber
        self.controller = controller
        self.coordinator = coordinator
        self.grounding = grounding
    }

    /// 會議停止時呼叫。停轉錄、收 session、釋放元件。
    func stop() {
        guard let transcriber else { return }
        let controller = self.controller
        Task {
            await transcriber.stop()
            controller?.endSession()
        }
        self.transcriber = nil
        self.controller = nil
        self.coordinator = nil
        self.grounding = nil
    }

    // MARK: - Helpers

    private func makeStreamingCompleter(
        provider: String?, model: String?, aiService: AIService
    ) -> LiveStreamingChatCompleter {
        let resolved = MeetingCopilotModels.resolve(
            storedProvider: provider, storedModel: model,
            defaultProvider: aiService.selectedProvider.rawValue,
            available: aiService.connectedProviders.map(\.rawValue))
        let aiProvider = AIProvider(rawValue: resolved.provider) ?? aiService.selectedProvider
        return LiveStreamingChatCompleter(aiService: aiService, provider: aiProvider, modelName: resolved.model)
    }
}
