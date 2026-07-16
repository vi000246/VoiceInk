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
    /// 即時字幕翻譯(M8)。overlay 之後綁的是這同一個實例。
    private var translator: MeetingLiveTranslator?
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
        // M10:即時模型(fast)= 開口稿 + 中度分析共用;深思模型(deep)= 僅深度分析(Tier 3)。
        let fast = Self.makeStreamingCompleter(provider: config.fastProviderName, model: config.fastModelName, aiService: aiService)
        let deep = Self.makeStreamingCompleter(provider: config.deepThinkProviderName, model: config.deepThinkModelName, aiService: aiService)
        let extractor = ResponseCueExtractor(
            chat: MeetingCopilotController.makeFastCompleter(aiService: aiService, config: config),
            systemPrompt: config.effectiveCuePrompt)
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
        // 展開狀態的雙向接線(closure 反轉依賴:coordinator 是引擎層,不認得 UI controller;
        // controller 已持有 coordinator,直接互相引用就成環)。
        //   - 讀:在途 deep 是不是使用者眼前正在讀的那則 → 不得被新 cue 取消(FR-54)。
        //   - 寫:deep 完成 → 沒人在讀就自動展開,有人在讀就只標未讀(FR-51)。
        // 兩個 closure 都在 @MainActor 上被呼叫(AnswerCoordinator 是 @MainActor),直接碰 controller 安全。
        coordinator.expandedCueIdProvider = { [weak controller] in controller?.expandedCueId }
        coordinator.onDeepCompleted = { [weak controller] id in controller?.handleDeepCompleted(cueId: id) }
        // 截圖深答:模型不支援圖片/送出失敗 → 把清楚訊息浮到 overlay(closure 反轉依賴,同上)。
        coordinator.onImageUnsupported = { [weak controller] msg in controller?.imageDeepError = msg }
        // 深度分析在途旗標的**單一事實來源**:三路(auto/manual/image)都經 coordinator 的 startDeep/runDeep
        // 驅動,overlay 才能在**自動**深答進行中也顯示 spinner + disable 按鈕(修 FR-77/AC-62 缺陷)。
        coordinator.onDeepInFlight = { [weak controller] id in controller?.deepInFlightCueId = id }

        // 5. 即時翻譯(M8 D 組)。**翻譯關閉時照樣建**——建構本身不打任何 API(guard 在
        //    translator.translate 內,AC-47),而恆存在的實例讓 overlay 有個穩定的
        //    @ObservedObject 可綁:設定中途開/關翻譯不必重建整條 pipeline,feed 空著就是了。
        let translator = MeetingLiveTranslator(
            chat: Self.makeTranslationCompleter(config: config, aiService: aiService),
            config: config)
        controller.translator = translator

        // Stage B:把 remote 流的「未定稿尾巴」接到翻譯器的 provisional 即時翻譯。
        // 在 transcriber.start() 之前設好(start 內才建 tick task);翻譯關閉時 observePartialTail
        // 自帶 guard,零成本。只接 remote(對方的話)——local 是我自己說的,不翻。
        remoteStream.onProvisionalTail = { [weak translator] tail in
            translator?.observePartialTail(tail)
        }

        // 6. overlay 接線。
        CopilotOverlayWindowManager.shared.configure(
            controller: controller,
            onCueTapped: { cue in
                // deepInFlightCueId 不在這裡手動設/清——改由 coordinator.onDeepInFlight 統一驅動
                // (三路共用單一事實來源;auto 也吃得到 spinner/disable)。requestDeep 內部
                // startDeep→onDeepInFlight(cue.id) 會亮 spinner;深答收尾 runDeep→onDeepInFlight(nil) 清掉。
                Task { await coordinator.requestDeep(cue) }
            },
            onImageDeepRequested: { [weak controller] cue in
                Task {
                    controller?.imageDeepError = nil          // 新一次嘗試,先清舊錯誤
                    // 快照「這次要送的圖」;成功後只移除**這批**(深答十餘秒間新截的圖在尾端,保留)。
                    let batch = CopilotScreenshotStore.shared.shots
                    let sent = await coordinator.requestDeepWithImages(cue, images: batch)
                    if sent { CopilotScreenshotStore.shared.removeSent(batch.count) }   // 失敗不清,留著重試
                }
            })

        // 7. 掛 cue pipeline(內含 beginSession,帶執行設定快照)+ 啟動轉錄。
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

        // 8. 筆記索引跟上這場會議前的最新編輯(fire-and-forget,不擋 attach)。
        scheduleNotesReindex(config: config)

        self.transcriber = transcriber
        self.controller = controller
        self.coordinator = coordinator
        self.grounding = grounding
        self.translator = translator
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
        self.translator = nil
    }

    // MARK: - 筆記增量索引(M8)

    /// attach 後排一次筆記增量掃描。**不阻塞 attach**:會議已經在錄,索引晚幾秒到位沒關係;
    /// 失敗只記 log 就算了——檢索不到就是沒接地,跟「沒設 vault」走同一條退路
    /// (與 `MeetingGroundingProvider` 的靜默紀律一致)。
    private func scheduleNotesReindex(config: MeetingCopilotConfigStore) {
        // 兩個開關都關 = 沒人會用到筆記塊 → 連掃都不掃(不平白打 embedding API)。
        // 「要不要檢索筆記」是 meeting-copilot 的消費決定;**索引範圍**(vault／資料夾)
        // 屬筆記管線,FR-6 起一律問 `ObsidianRAGConfigStore`(Ask AI 與這裡的單一權威)。
        guard config.useNotesRAG || config.notesInTechnicalRAG else { return }
        let notesConfig = ObsidianRAGConfigStore.shared
        guard let vaultRoot = notesConfig.effectiveVaultRoot() else { return }
        let includeOnly = notesConfig.includeOnlyFolders
        let excluded = notesConfig.excludedFolders
        Task.detached(priority: .background) { [weak self] in
            await self?.runNotesReindex(vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded)
        }
    }

    private func runNotesReindex(vaultRoot: URL, includeOnly: [String], excluded: [String]) async {
        guard let modelContext,
              let stateURL = try? ObsidianNoteIndexService.defaultStateURL() else { return }
        // sidecar 路徑歸位到索引服務(FR-8):設定頁的「重建筆記庫索引」、Ask AI 的 autoIndex 與
        // 這裡的背景掃描**必須共用同一份**——各記各的 hash 表會讓每邊都看到「全新 vault」,
        // 每次全量重嵌(純燒 embedding 錢)。
        //
        // 走 autoIndex(→ NoteIndexCoordinator)而非自己 new 一個 service:in-flight 是全app
        // 共用的。以前這裡跟 Ask AI 頁各跑各的,「開著 Ask AI 又開會」= 兩份 reindex 同時掃
        // 同一份 sidecar、互相覆蓋 hash 表、同一批檔重複打 embedding API。撞到就 no-op 是對的:
        // 已經有一輪在掃了,這輪本來就沒有新東西可做。失敗照舊靜默 log-only(在 coordinator 內)。
        await ObsidianNoteIndexService.autoIndex(
            vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded,
            stateURL: stateURL, modelContext: modelContext)
    }

    // MARK: - Helpers

    /// fast/deep 串流 completer + 觀測 label。
    ///
    /// **static + internal**:離線覆盤(錄音管理的「產生會議copilot覆盤」)要用與 live **同一套**
    /// 解析規則組 `AnswerCoordinator` —— 兩邊各寫一份,遲早會在「storedModel 為 nil = 跟隨該
    /// provider 目前選定的 model」這種邊角上分岔,覆盤結果就不再與 live 可比,而「可比」正是
    /// 覆盤存在的理由(見 `ReplaySegmentation` 檔頭)。
    static func makeStreamingCompleter(
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

    /// 翻譯用的 completer。
    ///
    /// **串流**(`LiveStreamingChatCompleter`,M8 延遲優化 option 3):使用者要求逐字冒出的即時字幕。
    /// 長句一次回來要等整段(實測十幾秒),串流讓譯文第一秒就開始顯示、逐字補齊——感知延遲差很多。
    ///
    /// model 解析與 fast/deep 走**同一套** `MeetingCopilotModels.resolve`:使用者移掉某 provider
    /// 的 API key 後,翻譯也必須跟著回退預設,不得繼續拿失效 provider 發請求。
    private static func makeTranslationCompleter(
        config: MeetingCopilotConfigStore, aiService: AIService
    ) -> StreamingChatCompleting {
        let resolved = MeetingCopilotModels.resolve(
            storedProvider: config.translationProviderName,
            storedModel: config.translationModelName,
            defaultProvider: aiService.selectedProvider.rawValue,
            available: aiService.connectedProviders.map(\.rawValue))
        let provider = AIProvider(rawValue: resolved.provider) ?? aiService.selectedProvider
        return LiveStreamingChatCompleter(
            aiService: aiService, provider: provider, modelName: resolved.model)
    }
}
