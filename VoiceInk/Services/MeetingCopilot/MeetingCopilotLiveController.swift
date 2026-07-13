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
    /// 與聽寫路徑共用的 FluidAudio 模型快取(registry 的同一實例)。
    /// 本機 parakeet 模型的串流 provider 必需 —— 缺了會 fatalError(見 LiveMeetingTranscriptStream.init)。
    private var fluidAudioService: FluidAudioTranscriptionService?

    // 本次會議的 live 元件(stop 時釋放)。
    private var transcriber: MeetingLiveTranscriber?
    private var controller: MeetingCopilotController?
    private var coordinator: AnswerCoordinator?
    /// grounding 需持有**單一**長生命週期 ScreenCaptureService 實例(per-instance reentrancy guard)。
    private var grounding: MeetingGroundingProvider?

    private init() {}

    /// 目前 live session 的 id(attach 時同步建立;無 live pipeline 時為 nil)。
    /// 供 `MeetingCaptureController` 在匯入錄音檔時回填 `importFingerprint`。
    var currentSessionId: UUID? { controller?.session?.id }

    /// 啟動時注入依賴(比照 RecorderImportService.shared.configure,VoiceInk.swift:135)。
    func configure(aiService: AIService, modelContext: ModelContext,
                   fluidAudioService: FluidAudioTranscriptionService? = nil) {
        self.aiService = aiService
        self.modelContext = modelContext
        self.fluidAudioService = fluidAudioService
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

        // 2. 音源 + 雙路轉錄。FluidAudio 模型必須帶 service(共用模型快取),否則 fatalError。
        let fluid: FluidAudioTranscriptionService? =
            asrModel.provider == .fluidAudio ? fluidAudioService : nil
        if asrModel.provider == .fluidAudio && fluid == nil {
            logger.error("🎧 copilot live start: FluidAudio 模型 \(asrModel.displayName, privacy: .public) 需要 fluidAudioService,但 configure 未注入 —— 中止啟動(避免 createProvider fatalError)")
            return
        }
        let source = LiveMeetingAudioSource(ring: ring, tapChannelCount: tapChannelCount)
        let remoteStream = LiveMeetingTranscriptStream(
            modelContext: modelContext, model: asrModel, label: "remote", fluidAudioService: fluid,
            language: config.asrLanguage)
        let localStream: MeetingTranscriptStream? = config.transcribeLocalMic
            ? LiveMeetingTranscriptStream(
                modelContext: modelContext, model: asrModel, label: "local", fluidAudioService: fluid,
                language: config.asrLanguage)
            : nil
        let transcriber = MeetingLiveTranscriber(source: source, remoteStream: remoteStream, localStream: localStream)

        // 3. cue 偵測 controller。fast label 同時代表 cue 抽取模型
        //    (makeFastCompleter 以同一組設定解析,結果必然相同)。
        let fast = makeStreamingCompleter(provider: config.fastProviderName, model: config.fastModelName, aiService: aiService)
        let deep = makeStreamingCompleter(provider: config.deepProviderName, model: config.deepModelName, aiService: aiService)
        let extractor = ResponseCueExtractor(
            chat: MeetingCopilotController.makeFastCompleter(aiService: aiService, config: config))
        let controller = MeetingCopilotController(
            extractor: extractor, config: config, modelContext: modelContext,
            extractionModelLabel: fast.label)

        // 4. 三層回應 coordinator。
        let grounding = MeetingGroundingProvider(
            embedder: LiveEmbedder(),
            screen: ScreenCaptureService(),
            modelContext: modelContext)
        let coordinator = AnswerCoordinator(
            fast: fast.completer,
            deep: deep.completer,
            grounding: grounding,
            config: config,
            fastLabel: fast.label,
            deepLabel: deep.label)
        controller.answerCoordinator = coordinator

        // 5. overlay 接線。
        CopilotOverlayWindowManager.shared.configure(
            controller: controller,
            onCueTapped: { [weak controller] cue in
                Task {
                    // 進度旗標:Tier 2 全程(等 Tier 1 → 接地 → deep 串流)可能十餘秒,
                    // 沒有可見狀態時點擊看起來像沒反應。
                    controller?.deepInFlightCueId = cue.id
                    await coordinator.requestDeep(cue)
                    controller?.deepInFlightCueId = nil
                }
            })

        // 6. 掛 cue pipeline(內含 beginSession,帶執行設定快照)+ 啟動轉錄。
        let snapshot = MeetingCopilotRunConfig.capture(
            config: config, asrModelDisplayName: asrModel.displayName,
            fastModelLabel: fast.label, deepModelLabel: deep.label)
        controller.attach(to: transcriber, appName: appName, configSnapshot: snapshot.encodedJSON())
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
        // overlay 一併收掉:釘住狀態歸零,避免會議結束後視窗還掛在螢幕上。
        CopilotOverlayWindowManager.shared.hideAndUnpin()
        let controller = self.controller
        Task {
            await transcriber.stop()
            // stop() 之後才讀:finish() 會 flush 最後一段 committed 進累積逐字稿。
            controller?.endSession(
                remoteTranscript: transcriber.remoteTranscript,
                localTranscript: transcriber.localTranscript)
        }
        self.transcriber = nil
        self.controller = nil
        self.coordinator = nil
        self.grounding = nil
    }

    // MARK: - Helpers

    private func makeStreamingCompleter(
        provider: String?, model: String?, aiService: AIService
    ) -> (completer: LiveStreamingChatCompleter, label: String) {
        let resolved = MeetingCopilotModels.resolve(
            storedProvider: provider, storedModel: model,
            defaultProvider: aiService.selectedProvider.rawValue,
            available: aiService.connectedProviders.map(\.rawValue))
        let aiProvider = AIProvider(rawValue: resolved.provider) ?? aiService.selectedProvider
        // 觀測 label:resolved.model nil = 跟隨該 provider 目前選定的 model——記解析後的實名,
        // 覆盤時才知道「當時真正打到哪顆模型」。
        let modelName = resolved.model ?? aiService.selectedModel(for: aiProvider)
        return (LiveStreamingChatCompleter(aiService: aiService, provider: aiProvider, modelName: resolved.model),
                "\(resolved.provider)/\(modelName)")
    }
}
