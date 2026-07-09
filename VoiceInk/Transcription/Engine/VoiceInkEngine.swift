import Foundation
import SwiftUI
import AVFoundation
import SwiftData
import AppKit
import os

private final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ data: Data) {
        let callback = state.withLock { state -> ((Data) -> Void)? in
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return nil
            }
            return state.callback
        }
        callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

@MainActor
class VoiceInkEngine: NSObject, ObservableObject {
    private enum RecordingUseCase {
        case newSession
        case assistantFollowUp

        var isAssistantFollowUp: Bool {
            self == .assistantFollowUp
        }
    }

    @Published var recordingState: RecordingState = .idle
    @Published var shouldCancelRecording = false
    @Published var partialTranscript: String = ""
    var currentSession: TranscriptionSession?
    private var currentSessionTranscriptionConfiguration: TranscriptionRuntimeConfiguration?
    private var activeRecordingStartID: UUID?
    private var activePipelineTranscriptionID: UUID?
    private var canceledPipelineTranscriptionIDs = Set<UUID>()
    private var activeRecordingUseCase: RecordingUseCase = .newSession
    private var activePipelineUseCase: RecordingUseCase = .newSession
    private var activeRecordingContextStore: RecordingContextSnapshotStore?
    private var activeRecordingContextTasks: [Task<Void, Never>] = []

    let recorder = Recorder()
    var recordedFile: URL? = nil
    let recordingsDirectory: URL

    // Injected managers
    let whisperModelManager: WhisperModelManager
    let transcriptionModelManager: TranscriptionModelManager
    weak var recorderUIManager: RecorderPanelPresenting?
    // Injected behind protocols (default to the app singletons) so the recording state
    // machine can be exercised in tests with fakes.
    private let modeManager: any ModeSelecting
    private let activeWindowService: any ModeApplying

    let modelContext: ModelContext
    internal let serviceRegistry: TranscriptionServiceRegistry
    let enhancementService: AIEnhancementService?
    let assistantSession = AssistantSession()
    let assistantChat: AssistantChatService?
    private let pipeline: TranscriptionPipeline

    let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VoiceInkEngine")

    init(
        modelContext: ModelContext,
        whisperModelManager: WhisperModelManager,
        transcriptionModelManager: TranscriptionModelManager,
        enhancementService: AIEnhancementService? = nil,
        modeManager: any ModeSelecting = ModeManager.shared,
        activeWindowService: any ModeApplying = ActiveWindowService.shared
    ) {
        self.modelContext = modelContext
        self.whisperModelManager = whisperModelManager
        self.transcriptionModelManager = transcriptionModelManager
        self.enhancementService = enhancementService
        self.modeManager = modeManager
        self.activeWindowService = activeWindowService
        if let aiService = enhancementService?.getAIService() {
            self.assistantChat = AssistantChatService(
                modelContext: modelContext,
                aiService: aiService
            )
        } else {
            self.assistantChat = nil
        }

        let appSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
        self.recordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings")

        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext
        )
        self.pipeline = TranscriptionPipeline(
            modelContext: modelContext,
            serviceRegistry: serviceRegistry,
            enhancementService: enhancementService
        )

        super.init()

        setupNotifications()
        createRecordingsDirectoryIfNeeded()
    }

    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true, attributes: nil)
        } catch {
            logger.error("❌ Error creating recordings directory: \(error, privacy: .public)")
        }
    }

    func getEnhancementService() -> AIEnhancementService? {
        return enhancementService
    }

    // MARK: - Toggle Record

    func toggleRecord(modeId: UUID? = nil, isAssistantFollowUp: Bool = false) async {
        if recordingState == .starting {
            await cancelRecording()
            return
        }

        if recordingState == .recording {
            await stopRecordingAndTranscribe()
        } else {
            prepareNewRecording(isAssistantFollowUp: isAssistantFollowUp)
            requestRecordPermission { [self] granted in
                guard granted else {
                    logger.error("Recording permission denied")
                    return
                }
                Task { @MainActor [self] in
                    await self.beginRecording(modeId: modeId)
                }
            }
        }
    }

    /// The `.recording` → stop path: hand the recorded file to the pipeline, or finish the
    /// cancellation that was requested mid-recording.
    private func stopRecordingAndTranscribe() async {
        activePipelineUseCase = activeRecordingUseCase
        activeRecordingUseCase = .newSession
        activeRecordingStartID = nil
        partialTranscript = ""
        recordingState = .transcribing
        await recorder.stopRecording()

        guard let recordedFile else {
            cancelCurrentSession()
            if !shouldCancelRecording {
                logger.error("❌ No recorded file found after stopping recording")
            }
            recordingState = .idle
            await cleanupResources()
            return
        }

        if shouldCancelRecording {
            await finishActiveRecorderCancellation()
            return
        }

        // 對著 VoiceInk 自己的視窗聽寫（例如把問題講進 Ask AI 輸入框）→ 照常轉錄＋貼上，
        // 但不留進「語音管理」歷史（那是使用者操作 App 的內容，不是要保存的語音筆記）。
        let targetIsSelf = ActiveWindowService.shared.currentApplication?.bundleIdentifier == Bundle.main.bundleIdentifier

        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: "",
            duration: 0,
            transcriptionStatus: .pending
        )
        modelContext.insert(transcription)
        try? modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)

        await runPipeline(
            on: transcription,
            audioURL: recordedFile,
            contextStore: activeRecordingContextStore
        )

        if targetIsSelf {
            TranscriptIndexService.shared.deleteChunks(transcriptionId: transcription.id)
            RecordingAudioFiles.removeAll(for: transcription)   // 先清音檔（還讀得到路徑）
            modelContext.delete(transcription)
            try? modelContext.save()
        }
    }

    /// Resets per-recording state ahead of a new start.
    private func prepareNewRecording(isAssistantFollowUp: Bool) {
        let canContinueAssistantSession = isAssistantFollowUp && assistantSession.canSendFollowUp
        activePipelineTranscriptionID = nil
        shouldCancelRecording = false
        partialTranscript = ""
        activeRecordingUseCase = canContinueAssistantSession ? .assistantFollowUp : .newSession
        clearActiveRecordingContext()

        if !activeRecordingUseCase.isAssistantFollowUp {
            assistantSession.reset()
        }
    }

    /// The single unwind path for a failed or model-less recording start: stops the recorder,
    /// clears every piece of per-recording state back to idle, optionally deletes the recording
    /// file and shows an error, then dismisses the panel. These steps used to be copy-pasted at
    /// each early exit with slight differences — the breeding ground for lingering-state bugs.
    private func abortStart(deletingFile fileURL: URL?, notifying errorTitle: String? = nil) async {
        await recorder.stopRecording()
        cancelCurrentSession()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        recordedFile = nil
        recordingState = .idle
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        await cleanupResources()
        if let errorTitle {
            NotificationManager.shared.showNotification(title: errorTitle, type: .error)
        }
        await recorderUIManager?.dismissRecorderPanel()
    }

    private func beginRecording(modeId: UUID?) async {
        let startID = UUID()
        activeRecordingStartID = startID
        let activeModeTask = activeWindowService.beginApplyingConfiguration(modeId: modeId, shouldApply: { [weak self] in
            guard let self else { return false }
            return self.activeRecordingStartID == startID && !self.shouldCancelRecording
        })

        do {
            let fileName = "\(UUID().uuidString).wav"
            let permanentURL = recordingsDirectory.appendingPathComponent(fileName)
            recordedFile = permanentURL

            let realtimeAudioGate = RealtimeAudioChunkGate()
            recorder.onAudioChunk = realtimeAudioGate.receive

            recordingState = .starting

            try await recorder.startRecording(toOutputFile: permanentURL)

            // Ownership guard: this start may have been superseded, canceled, or its panel
            // closed while the recorder spun up. Only the still-owning start unwinds shared
            // state, and a user-requested cancel keeps the file so the canceled recording can
            // still be saved.
            guard activeRecordingStartID == startID,
                  recorderUIManager?.isRecorderPanelVisible ?? false,
                  !shouldCancelRecording else {
                activeModeTask.cancel()
                let shouldKeepRecordingFile = shouldCancelRecording
                if activeRecordingStartID == startID {
                    await recorder.stopRecording()
                    if !shouldKeepRecordingFile {
                        recordedFile = nil
                    }
                    recordingState = .idle
                    activeRecordingStartID = nil
                }
                return
            }

            recordingState = .recording

            await activeModeTask.value

            guard recordingState == .recording,
                  activeRecordingStartID == startID,
                  !shouldCancelRecording else {
                return
            }

            startRecordingContextCapture()

            guard let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            ) else {
                await abortStart(deletingFile: permanentURL, notifying: String(localized: "No AI Model Selected"))
                return
            }

            try await prepareRealtimeSession(
                configuration: transcriptionConfiguration,
                gate: realtimeAudioGate,
                startID: startID
            )

            preloadSelectedModelInBackground()
        } catch {
            activeModeTask.cancel()
            logger.error("Recording failed to start: \(error, privacy: .public)")
            await abortStart(deletingFile: recordedFile, notifying: String(localized: "Recording failed to start"))
        }
    }

    /// Wires up realtime streaming when the configuration asks for it; otherwise clears the
    /// audio-chunk path so file-based transcription runs at stop time.
    private func prepareRealtimeSession(
        configuration: TranscriptionRuntimeConfiguration,
        gate: RealtimeAudioChunkGate,
        startID: UUID
    ) async throws {
        guard serviceRegistry.shouldUseRealtimeTranscription(for: configuration) else {
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            recorder.onAudioChunk = nil
            _ = gate.reset()
            return
        }

        let session = serviceRegistry.createSession(
            for: configuration,
            onPartialTranscript: { [weak self] partial in
                Task { @MainActor in
                    guard let self,
                          self.activeRecordingStartID == startID,
                          self.recordingState == .recording else {
                        return
                    }
                    self.partialTranscript = partial
                }
            }
        )
        currentSession = session
        currentSessionTranscriptionConfiguration = configuration
        let realCallback = try await session.prepare(configuration: configuration)

        if let realCallback {
            let droppedStartupChunks = gate.activate(realCallback)
            if droppedStartupChunks > 0 {
                logger.warning("Realtime startup audio gate dropped \(droppedStartupChunks, privacy: .public) chunks before streaming became active")
            }
        } else {
            _ = gate.reset()
            recorder.onAudioChunk = nil
        }
    }

    /// Kicks off a background load of the selected local model so transcription at stop time
    /// doesn't pay the model init.
    private func preloadSelectedModelInBackground() {
        Task { @MainActor [weak self] in
            guard let self else { return }

            let currentModel = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: self.transcriptionModelManager
            )?.model

            if let model = currentModel,
               model.provider == .whisper {
                if let localWhisperModel = self.whisperModelManager.availableModels.first(where: { $0.name == model.name }),
                   self.whisperModelManager.whisperContext == nil {
                    do {
                        try await self.whisperModelManager.loadModel(localWhisperModel)
                    } catch {
                        self.logger.error("❌ Model loading failed: \(error, privacy: .public)")
                    }
                }
            } else if let fluidAudioModel = currentModel as? FluidAudioModel {
                try? await self.serviceRegistry.fluidAudioTranscriptionService.loadModel(for: fluidAudioModel)
            }
        }
    }

    private func requestRecordPermission(response: @escaping (Bool) -> Void) {
        response(true)
    }

    // MARK: - Recording Context

    private func startRecordingContextCapture() {
        clearActiveRecordingContext()

        let store = RecordingContextSnapshotStore()
        activeRecordingContextStore = store
        activeRecordingContextTasks = RecordingContextCaptureService.startCapture(into: store)
    }

    private func clearActiveRecordingContext() {
        activeRecordingContextTasks.forEach { $0.cancel() }
        activeRecordingContextTasks.removeAll()
        activeRecordingContextStore = nil
    }

    // MARK: - Pipeline Dispatch

    private func runPipeline(
        on transcription: Transcription,
        audioURL: URL,
        contextStore: RecordingContextSnapshotStore?
    ) async {
        guard let transcriptionConfiguration = currentSessionTranscriptionConfiguration ??
            ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: transcriptionModelManager) else {
            transcription.text = String(localized: "Transcription Failed: No model selected")
            transcription.transcriptionStatus = TranscriptionStatus.failed.rawValue
            try? modelContext.save()
            recordingState = .idle
            activePipelineUseCase = .newSession
            return
        }

        let session = currentSession
        let transcriptionID = transcription.id
        activePipelineTranscriptionID = transcriptionID

        await pipeline.run(
            transcription: transcription,
            audioURL: audioURL,
            transcriptionConfiguration: transcriptionConfiguration,
            formattingConfiguration: {
                ModeRuntimeResolver.transcriptionFormattingConfiguration()
            },
            session: session,
            triggerWordModeSelection: { [weak self] text in
                self?.selectTriggerWordModeIfNeeded(for: text)
            },
            enhancementConfiguration: { [weak self] in
                guard let self,
                      let enhancementService = self.enhancementService,
                      let aiService = enhancementService.getAIService() else {
                    return nil
                }
                return ModeRuntimeResolver.currentEnhancementConfiguration(
                    enhancementService: enhancementService,
                    aiService: aiService
                )
            },
            recordingContextSnapshot: {
                await MainActor.run {
                    contextStore?.snapshot
                }
            },
            outputConfiguration: {
                ModeRuntimeResolver.outputConfiguration()
            },
            onStateChange: { [weak self] state in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                self.recordingState = state
            },
            shouldCancel: { [weak self] in
                guard let self else { return false }
                return self.canceledPipelineTranscriptionIDs.contains(transcriptionID)
                    || (self.activePipelineTranscriptionID == transcriptionID && self.shouldCancelRecording)
            },
            onCancel: { [weak self, session] in
                guard let self else { return }
                self.cancelPipelineSession(transcriptionID: transcriptionID, session: session)
            },
            onDismiss: { [weak self] in
                guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                await self.recorderUIManager?.dismissRecorderPanel()
            },
            assistant: TranscriptionPipeline.AssistantHooks(
                isFollowUp: activePipelineUseCase.isAssistantFollowUp,
                sendFollowUp: { [weak self] text, transcription in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.sendAssistantFollowUp(text, transcription: transcription)
                },
                startResponse: { [weak self] transcript, configuration in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.beginInitialResponse(
                        transcript: transcript,
                        provider: configuration.provider,
                        modelName: configuration.modelName ?? configuration.provider?.defaultModel,
                        modeName: configuration.mode?.name,
                        modeEmoji: configuration.mode?.icon.value,
                        promptName: configuration.prompt?.title
                    )
                },
                showResponse: { [weak self] response, systemPrompt in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    await self.completeAssistantResponse(response, systemPrompt: systemPrompt)
                },
                failResponse: { [weak self] message in
                    guard let self, self.activePipelineTranscriptionID == transcriptionID else { return }
                    self.assistantSession.fail(message)
                }
            )
        )

        let didFinishActivePipeline = activePipelineTranscriptionID == transcriptionID
        if didFinishActivePipeline {
            await finishRecorderSession()
            await cleanupResources()
            activePipelineTranscriptionID = nil
            currentSession = nil
            currentSessionTranscriptionConfiguration = nil
            recordedFile = nil
            shouldCancelRecording = false
            activePipelineUseCase = .newSession
            clearActiveRecordingContext()
        }
        canceledPipelineTranscriptionIDs.remove(transcriptionID)

        if didFinishActivePipeline &&
            (recordingState == .transcribing || recordingState == .enhancing || recordingState == .busy) {
            recordingState = .idle
        }
    }

    private func selectTriggerWordModeIfNeeded(for text: String) -> String? {
        guard let (triggeredMode, processedText) = modeManager.getConfigurationForTriggerWord(text) else {
            return nil
        }

        modeManager.setActiveConfiguration(triggeredMode)
        return processedText
    }

    // MARK: - Cancellation

    func cancelRecording() async {
        let shouldFinishSessionImmediately: Bool
        switch recordingState {
        case .starting, .recording:
            requestRecordingCancellation()
            await finishActiveRecorderCancellation()
            shouldFinishSessionImmediately = true
        case .transcribing, .enhancing:
            requestRecordingCancellation()
            partialTranscript = ""
            recordingState = .idle
            shouldFinishSessionImmediately = false
        case .idle, .busy:
            partialTranscript = ""
            shouldCancelRecording = false
            recordingState = .idle
            shouldFinishSessionImmediately = true
        }

        if shouldFinishSessionImmediately {
            await finishRecorderSession()
        }
    }

    func resetRecordingSession() async {
        cancelCurrentSession()
        activeRecordingStartID = nil
        activePipelineTranscriptionID = nil
        canceledPipelineTranscriptionIDs.removeAll()
        shouldCancelRecording = false
        partialTranscript = ""
        assistantSession.reset()
        activeRecordingUseCase = .newSession
        activePipelineUseCase = .newSession
        clearActiveRecordingContext()
        await recorder.stopRecording()
        recordedFile = nil
        recordingState = .idle
        await cleanupResources()
        await finishRecorderSession()
    }

    private func requestRecordingCancellation() {
        shouldCancelRecording = true

        if (recordingState == .transcribing || recordingState == .enhancing),
           let activePipelineTranscriptionID {
            canceledPipelineTranscriptionIDs.insert(activePipelineTranscriptionID)
        }

        cancelCurrentSession()
    }

    private func finishActiveRecorderCancellation() async {
        activeRecordingStartID = nil
        clearActiveRecordingContext()
        await recorder.stopRecording()
        await saveCanceledRecording()
        recordedFile = nil
        partialTranscript = ""
        recordingState = .idle
        await cleanupResources()
    }

    private func saveCanceledRecording() async {
        guard let recordedFile,
              FileManager.default.fileExists(atPath: recordedFile.path)
        else { return }

        let duration = await AudioFileMetadata.duration(for: recordedFile)
        let transcription = makeRecordingTranscription(
            for: recordedFile,
            text: Transcription.canceledTranscriptionText,
            duration: duration,
            transcriptionStatus: .canceled
        )

        modelContext.insert(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
        } catch {
            logger.error("Failed to save canceled recording: \(error, privacy: .public)")
        }
    }

    private func makeRecordingTranscription(
        for audioURL: URL,
        text: String,
        duration: TimeInterval,
        transcriptionStatus: TranscriptionStatus
    ) -> Transcription {
        let modeMetadata = currentModeMetadata()

        return Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model.displayName,
            modeName: modeMetadata.name,
            modeEmoji: modeMetadata.emoji,
            transcriptionStatus: transcriptionStatus
        )
    }

    private func currentModeMetadata() -> (name: String?, emoji: String?) {
        guard let mode = modeManager.currentEffectiveConfiguration,
              mode.isEnabled else {
            return (nil, nil)
        }

        return (mode.name, mode.icon.value)
    }

    // MARK: - Resource Cleanup

    private func cancelPipelineSession(transcriptionID: UUID, session: TranscriptionSession?) {
        session?.cancel()

        guard activePipelineTranscriptionID == transcriptionID else {
            logger.notice("Skipping stale pipeline cleanup")
            return
        }

        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func cancelCurrentSession() {
        currentSession?.cancel()
        currentSession = nil
        currentSessionTranscriptionConfiguration = nil
    }

    private func finishRecorderSession() async {
        enhancementService?.clearCapturedContexts()
    }

    func cleanupResources() async {
        logger.notice("cleanupResources: releasing model resources")
        activeRecordingStartID = nil
        activeRecordingUseCase = .newSession
        await whisperModelManager.cleanupResources()
        await serviceRegistry.cleanup()
        logger.notice("cleanupResources: completed")
    }

    // MARK: - Notification Handling

    func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePromptChange),
            name: .promptDidChange,
            object: nil
        )
    }

    @objc func handlePromptChange() {
        Task {
            let currentPrompt = UserDefaults.standard.string(forKey: "TranscriptionPrompt")
                ?? whisperModelManager.whisperPrompt.transcriptionPrompt
            if let context = whisperModelManager.whisperContext {
                await context.setPrompt(currentPrompt)
            }
        }
    }
}

enum AudioFileMetadata {
    static func duration(for url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite ? seconds : 0
    }
}
