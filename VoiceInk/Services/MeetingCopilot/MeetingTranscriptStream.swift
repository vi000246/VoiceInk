import Foundation
import SwiftData
import os

/// 一條即時轉錄流。meeting-copilot 開**兩條**:remote(對方)與 local(我)。
///
/// # 講者歸屬 = 事件從哪條流出來
///
/// 不需要 diarization。這是本模組的核心設計——串流轉錄路徑**完全沒有 speaker 欄位**
/// (`StreamingTranscriptionEvent` 只有 text),而 diarization 只存在於批次 ElevenLabs
/// 整檔路徑且與串流互斥。用聲道分流取而代之,講者歸屬是 100% 準確且零成本的。
///
/// # 為什麼要這層包裝,而不直接用 `StreamingTranscriptionService`
///
/// 1. 它的 `createProvider(for:)` 是 **private** 且對不支援串流的 model 直接 `fatalError`
///    (`StreamingTranscriptionService.swift:252-272`)→ 無法在測試中注入 fake。
/// 2. 它服務**聽寫路徑**,改它的風險不成比例。
protocol MeetingTranscriptStream: AnyObject {
    func start() async throws
    /// 送一段音訊。格式契約:**16kHz mono Int16 little-endian**
    /// (見 `StreamingTranscriptionProvider.sendAudioChunk` 的註解)。
    func send(_ pcm16: Data)
    func finish() async
    var events: AsyncStream<StreamingTranscriptionEvent> { get }
}

// MARK: - Live(包住既有的 StreamingTranscriptionService)

@MainActor
final class LiveMeetingTranscriptStream: MeetingTranscriptStream {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private let service: StreamingTranscriptionService
    private let model: any TranscriptionModel
    private let label: String
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation

    nonisolated let events: AsyncStream<StreamingTranscriptionEvent>

    /// - Parameter label: 診斷用("remote" / "local")。
    init(modelContext: ModelContext, model: any TranscriptionModel, label: String) {
        self.model = model
        self.label = label

        var cont: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont = $0 }
        self.continuation = cont

        // `StreamingTranscriptionService` 只透過 closure 回報 partial;committed 由它內部累積,
        // 在 `stopAndGetFinalText()` 時一次交出。因此 partial 直接轉發,committed 於 finish() 補一則。
        self.service = StreamingTranscriptionService(
            modelContext: modelContext,
            onPartialTranscript: { text in
                cont.yield(.partial(text: text))
            }
        )
    }

    func start() async throws {
        try await service.startStreaming(model: model, context: .currentDefaults)
        continuation.yield(.sessionStarted)
    }

    /// `nonisolated` —— 才能直接從 consumer thread 呼叫,不必繞 MainActor。
    /// 底層的 `StreamingTranscriptionService.sendAudioChunk` 本身就是 `nonisolated`
    /// (`StreamingTranscriptionService.swift:176`),明示可從 CoreAudio/處理執行緒呼叫。
    nonisolated func send(_ pcm16: Data) {
        service.sendAudioChunk(pcm16)
    }

    func finish() async {
        do {
            let text = try await service.stopAndGetFinalText()
            if !text.isEmpty {
                continuation.yield(.committed(text: text))
            }
        } catch {
            // 失敗必須靜默(分享螢幕時任何 modal 都會暴露本功能)—— 只記 log。
            logger.error("🎧 [\(self.label, privacy: .public)] stopAndGetFinalText failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.error(error))
        }
        continuation.finish()
    }
}

// MARK: - Fake(測試用;腳本化事件)

/// 測試用轉錄流:**忽略音訊內容**,依腳本吐事件。
///
/// # 為什麼 E2E 測試不用真的 FluidAudio
///
/// SRS 原本寫「本機 FluidAudio → 免 API key → CI 可跑」。**站不住**,三個理由:
///
/// 1. `VoiceInkTests` 是 **host-app** 測試 bundle,專案記憶 `voiceink-running-unit-tests`
///    明載未簽章時 host 開機即 crash,且「**CoreAudio 在 headless 下脆弱**」。
/// 2. FluidAudio 需要先下載 CoreML 模型到磁碟,**不是純程式碼依賴**。
/// 3. 全 repo **沒有任何測試使用 Bundle fixture**,把語音 WAV 塞進測試 bundle 沒有先例。
///
/// 因此 XCTest 用這個 fake 驗證**接線正確性**(分流 → 降頻 → 雙路 → 講者歸屬),
/// 那正是 M1 的風險所在;**真實 ASR 的驗證放在 `#if DEBUG` 選單**,由人工執行。
final class FakeMeetingTranscriptStream: MeetingTranscriptStream, @unchecked Sendable {

    /// 收到第 N 個 chunk 時吐出對應事件(1-based)。
    private let script: [Int: StreamingTranscriptionEvent]
    /// `finish()` 時吐出的 committed 文字。
    private let finalText: String?

    private var chunkCount = 0
    private let lock = NSLock()
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation

    let events: AsyncStream<StreamingTranscriptionEvent>

    /// 觀測用:收到的總位元組數 —— 讓測試能斷言「音訊**真的**流到這條流了」。
    private(set) var receivedBytes = 0
    /// 觀測用:收到的 chunk 數。
    private(set) var receivedChunks = 0

    init(script: [Int: StreamingTranscriptionEvent] = [:], finalText: String? = nil) {
        self.script = script
        self.finalText = finalText

        var cont: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        self.continuation = cont
    }

    func start() async throws {
        continuation.yield(.sessionStarted)
    }

    func send(_ pcm16: Data) {
        lock.lock()
        receivedBytes += pcm16.count
        receivedChunks += 1
        chunkCount += 1
        let event = script[chunkCount]
        lock.unlock()

        if let event {
            continuation.yield(event)
        }
    }

    func finish() async {
        if let finalText, !finalText.isEmpty {
            continuation.yield(.committed(text: finalText))
        }
        continuation.finish()
    }
}
