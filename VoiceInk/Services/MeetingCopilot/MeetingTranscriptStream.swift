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
    /// 轉錄語言碼(nil = 跟隨聽寫路徑的 currentDefaults)。
    private let language: String?
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    /// 停頓切段器(見 `MeetingPartialSegmenter` 的設計說明)。
    private let segmenter: MeetingPartialSegmenterBox
    private var tickTask: Task<Void, Never>?

    nonisolated let events: AsyncStream<StreamingTranscriptionEvent>

    /// - Parameters:
    ///   - label: 診斷用("remote" / "local")。
    ///   - fluidAudioService: **FluidAudio 家族模型必傳**(nemotron / parakeet-unified 之外的
    ///     型號,如預設的 parakeet v2/v3,其 provider 需要它載模型)。漏傳時
    ///     `createProvider(for:)` 會直接 `fatalError` 把整個 app 弄死 —— build 253 的
    ///     會議錄製 crash 就是這裡。remote/local 兩條流應共用同一實例(共用模型快取)。
    init(modelContext: ModelContext, model: any TranscriptionModel, label: String,
         fluidAudioService: FluidAudioTranscriptionService? = nil,
         language: String? = nil) {
        self.model = model
        self.label = label
        self.language = language

        var cont: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont = $0 }
        self.continuation = cont

        let segmenter = MeetingPartialSegmenterBox()
        self.segmenter = segmenter
        // init 內 self 尚未可用,closure 需要自己的 logger 實例。
        let closureLogger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

        // committed 段落 = 停頓切段(`MeetingPartialSegmenter`):partial(已被 service
        // 正規化成累積全文)停止變化 1.5s → 吐出 delta。cue 偵測掛在 committed 事件上,
        // 不能等底層 ASR 的 confirm —— FluidAudio 的 agreement engine 對中文/短會議
        // 幾乎永遠不 confirm(句尾標點只認 ASCII、永遠保留最後 2 句當 hypothesis),
        // 實測整場 31 秒零次 mid-stream confirm。底層真的 confirm 時(雲端 provider
        // 每句觸發)由 onCommittedSegment 立即切段;兩條路共用同一個 emitted 偏移,
        // 結構上不會重複發同一段。
        self.service = StreamingTranscriptionService(
            modelContext: modelContext,
            fluidAudioService: fluidAudioService,
            onPartialTranscript: { text in
                segmenter.observe(partial: text, at: ProcessInfo.processInfo.systemUptime)
                cont.yield(.partial(text: text))
            },
            onCommittedSegment: { _ in
                if let segment = segmenter.forceSegment() {
                    closureLogger.notice("🎼 [\(label, privacy: .public)] ASR confirm 切段 \(segment.count, privacy: .public) 字: \(segment, privacy: .public)")
                    cont.yield(.committed(text: segment))
                }
            }
        )
    }

    func start() async throws {
        // 語言用 meeting 專屬設定覆蓋(auto 對非目標語言會整段誤判,見 MeetingCopilotConfigStore.asrLanguage)。
        let base = TranscriptionRequestContext.currentDefaults
        let context = TranscriptionRequestContext(language: language ?? base.language, prompt: base.prompt)
        try await service.startStreaming(model: model, context: context)
        continuation.yield(.sessionStarted)

        // 停頓偵測 tick:500ms 輪詢遠細於 1.5s 的停頓門檻,不會成為延遲瓶頸。
        let segmenter = self.segmenter
        let cont = self.continuation
        let logger = self.logger
        let label = self.label
        tickTask = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if let segment = segmenter.poll(at: ProcessInfo.processInfo.systemUptime) {
                    logger.notice("🎼 [\(label, privacy: .public)] 停頓切段 \(segment.count, privacy: .public) 字: \(segment, privacy: .public)")
                    cont.yield(.committed(text: segment))
                }
            }
        }
    }

    /// `nonisolated` —— 才能直接從 consumer thread 呼叫,不必繞 MainActor。
    /// 底層的 `StreamingTranscriptionService.sendAudioChunk` 本身就是 `nonisolated`
    /// (`StreamingTranscriptionService.swift:176`),明示可從 CoreAudio/處理執行緒呼叫。
    nonisolated func send(_ pcm16: Data) {
        service.sendAudioChunk(pcm16)
    }

    func finish() async {
        tickTask?.cancel()
        tickTask = nil
        do {
            // 中途段落已由停頓切段/onCommittedSegment 即時發出,這裡**不補發全文**
            // ——否則 cue 偵測會對整份逐字稿重跑一次、累積逐字稿也會整份重複。
            // stop 時 finalize 的最後一段經 onCommittedSegment 切出;flush 收殘餘。
            _ = try await service.stopAndGetFinalText()
        } catch {
            // 失敗必須靜默(分享螢幕時任何 modal 都會暴露本功能)—— 只記 log。
            logger.error("🎧 [\(self.label, privacy: .public)] stopAndGetFinalText failed: \(error.localizedDescription, privacy: .public)")
            continuation.yield(.error(error))
        }
        if let residual = segmenter.flush() {
            continuation.yield(.committed(text: residual))
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
