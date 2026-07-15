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

/// 目前這條流的 service + 送出節奏的時間戳 + 休眠期間的音訊暫存。
///
/// 為什麼需要一個 box:`send` 是 `nonisolated`(從音訊 pump thread 直接呼叫),而 service
/// 在**重連/休眠時會被換掉或拿掉**——可變的 @MainActor 屬性不能從 nonisolated 讀。box 把
/// 這些共享狀態收在一個鎖後面,pump thread 與 MainActor 都能安全存取。
private final class MeetingStreamingServiceBox: @unchecked Sendable {

    private let lock = NSLock()
    private var service: StreamingTranscriptionService?
    /// 上次送出任何東西(真音訊或保活靜音)的時刻(`systemUptime`)。keepalive 判斷閒置用。
    private var lastSentAt: TimeInterval = -.infinity
    /// 上次收到**有能量的**音訊的時刻。休眠判斷用 —— 注意這**不是**「上次收到 frame」:
    /// 對方 app 佔住音訊裝置時,即使沒人說話 frame 仍會源源不絕地流進來(全是 0 樣本),
    /// 拿 frame 當活躍訊號的話,忘了關的會議永遠不會休眠。
    private var lastSignalAt: TimeInterval = -.infinity
    /// 沒有 service 可送時(休眠中/重連中)暫存的音訊,接上後補送 —— 否則對方開口的
    /// 第一句話會缺頭。
    private var buffered: [Data] = []
    private var bufferedBytes = 0

    /// 接上一條新的 service,回傳舊的(呼叫端負責 cancel 它)。
    @discardableResult
    func replace(with newService: StreamingTranscriptionService?, at now: TimeInterval) -> StreamingTranscriptionService? {
        lock.lock()
        let old = service
        service = newService
        // 接上的當下視同剛送過:keepalive 從現在起算,不會一接上就先補一段靜音。
        lastSentAt = now
        // **也要重設「上次有聲音」**:否則剛接上時它還是 -infinity,休眠判斷
        // (`now - lastSignalAt >= 5min`)第一個 tick 就成立,整條流會立刻睡死。
        lastSignalAt = now
        // 空窗期暫存的音訊立刻補送(順序不變)。
        let pending = newService == nil ? [] : buffered
        buffered = []
        bufferedBytes = 0
        lock.unlock()

        for chunk in pending {
            newService?.sendAudioChunk(chunk)
        }
        return old
    }

    /// 送真音訊。沒有 service(休眠中/重連中)→ 進暫存,接上後補送。
    ///
    /// - Parameter hasSignal: 這段音訊是否有能量(見 `lastSignalAt` 的說明)。
    func sendAudio(_ pcm16: Data, at now: TimeInterval, hasSignal: Bool) {
        lock.lock()
        if hasSignal { lastSignalAt = now }
        guard let target = service else {
            buffered.append(pcm16)
            bufferedBytes += pcm16.count
            while bufferedBytes > LiveMeetingTranscriptStream.maxBufferedBytes, let oldest = buffered.first {
                buffered.removeFirst()
                bufferedBytes -= oldest.count
            }
            lock.unlock()
            return
        }
        lastSentAt = now
        lock.unlock()
        target.sendAudioChunk(pcm16)
    }

    /// 閒置超過 `idleAfter` → 送一段靜音保活。回傳是否真的送了(測試/log 用)。
    @discardableResult
    func sendKeepAliveIfIdle(_ silence: Data, at now: TimeInterval, idleAfter: TimeInterval) -> Bool {
        lock.lock()
        guard let target = service, now - lastSentAt >= idleAfter else {
            lock.unlock()
            return false
        }
        lastSentAt = now
        lock.unlock()
        target.sendAudioChunk(silence)
        return true
    }

    /// 上次收到有能量音訊的時刻(休眠與喚醒都靠它判斷)。
    func signalTimestamp() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return lastSignalAt
    }
}

@MainActor
final class LiveMeetingTranscriptStream: MeetingTranscriptStream {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    /// 目前的 service(重連時整個換掉 —— 見 `reconnect()` 說明為什麼是「換掉」而不是「重接」)。
    private let serviceBox = MeetingStreamingServiceBox()
    private let model: any TranscriptionModel
    private let label: String
    /// 轉錄語言碼(nil = 跟隨聽寫路徑的 currentDefaults)。
    private let language: String?
    private let modelContext: ModelContext
    private let fluidAudioService: FluidAudioTranscriptionService?
    private let continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation
    /// 停頓切段器(見 `MeetingPartialSegmenter` 的設計說明)。
    private let segmenter: MeetingPartialSegmenterBox
    private var tickTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// `finish()` 之後不再重連(否則會議都收了還在背景重接 socket)。
    private var isRunning = false
    /// 長時間沒聲音 → 收掉 socket 進休眠(不再保活、不再計費),有聲音再自動喚醒。
    private var isDormant = false
    private var dormantSince: TimeInterval = 0

    /// 未定稿尾巴的接點(provisional 即時翻譯,M8 Stage B)。tick 每次尾巴變動時經
    /// `emitProvisionalTail` 回呼;尾巴切成 committed 或斷線 reset 後會變空字串,呼叫端據此收掉
    /// provisional。**在 `start()` 之前設定**(由 `MeetingCopilotLiveController` 接到翻譯器)。
    var onProvisionalTail: ((String) -> Void)?

    /// tick(detached)算出尾巴後 hop 回 MainActor 呼叫回呼。只在尾巴**變動**時被叫到
    /// (partial ~1s 才更新一次),hop 成本可忽略。
    func emitProvisionalTail(_ tail: String) {
        onProvisionalTail?(tail)
    }

    nonisolated let events: AsyncStream<StreamingTranscriptionEvent>

    // MARK: - 保活與重連的常數
    //
    // 2026-07-14 的實測事故:會議 19:52:54 開始,兩條 Scribe V2 串流 19:52:55 連上,
    // 但 process tap 在對方 app 真的出聲前**不給任何 IO callback** —— 前 30 秒零音訊。
    // ElevenLabs 在**閒置整整 15.0 秒**後關掉 socket(兩條流都是連上後 15.0s 報錯);
    // 等 19:53:25 TTS 終於開始播,音訊全部送進死掉的 socket(9,640 次 send 失敗),
    // 沒有 partial → 沒有 committed → 整場 0 cue。
    //
    // 兩道防線,缺一不可:
    //   1. keepalive:沒有音訊流動時定期送靜音,socket 就不會 idle 死。
    //   2. reconnect:socket 還是死了(網路斷、伺服器 session 時間上限)就重建。
    //      光靠 keepalive 擋不住這些;光靠 reconnect 則每次長停頓後都要重連一次,
    //      而重連要 ~0.3s —— 對方問題的開頭幾個字就被吃掉了。

    /// 閒置多久開始補靜音。必須遠小於伺服器的 15s idle timeout。
    static let keepAliveIdleThreshold: TimeInterval = 2.0
    /// keepalive / 休眠 / 喚醒的輪詢間隔。
    static let keepAliveTickInterval: Duration = .milliseconds(500)

    /// **連續這麼久沒有任何「有能量」的音訊** → 收掉 socket 進休眠(停止保活 = 停止計費)。
    /// 有聲音時會自動喚醒(重連 ~0.3s,空窗期的音訊由 box 暫存後補送,不掉字)。
    ///
    /// 這是「會議忘了關」的保險:沒有它,keepalive 會忠實地把一條 socket 養到天荒地老。
    /// 5 分鐘全場鴉雀無聲,幾乎可以確定不是在開會 —— 真的只是在思考的話,喚醒也只要一句話。
    static let idleDormancyThreshold: TimeInterval = 5 * 60

    /// 休眠/重連空窗期最多留幾秒音訊(16kHz mono Int16 → 每秒 32,000 bytes)。
    /// 3 秒足夠蓋住喚醒(~0.5s tick + ~0.3s 連線)的空窗,又不會把記憶體吃掉。
    /// 沒有這個暫存,休眠後對方開口的第一句話會缺頭。
    static let maxBufferedBytes = 3 * 16_000 * MemoryLayout<Int16>.size

    /// 判定「有人在說話」的 RMS 門檻(正規化 Float 樣本)。
    ///
    /// 麥克風底噪實測 ≈ 0.004(見事故 log 的 `LOCAL[0.0043]`),說話 ≈ 0.05~0.25。
    /// 0.01 卡在中間:底噪不會讓會議一直醒著,但一開口就立刻觸發。
    static let signalRMSThreshold: Float = 0.01

    /// 這段 16kHz mono Int16 LE 的音訊有沒有「能量」(= 有人在說話,而不是純靜音/底噪)。
    /// `nonisolated` 純函式:在音訊 pump thread 上逐塊呼叫。
    nonisolated static func hasSignal(_ pcm16: Data, threshold: Float = signalRMSThreshold) -> Bool {
        let sampleCount = pcm16.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return false }

        var sumOfSquares: Double = 0
        pcm16.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<sampleCount {
                // little-endian:`Data` 來自 `PCMDownsampler`,本機就是 LE,直接讀。
                let normalized = Double(samples[i]) / Double(Int16.max)
                sumOfSquares += normalized * normalized
            }
        }
        let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
        return Float(rms) >= threshold
    }
    /// 一次補多少靜音:200ms 的 16kHz mono Int16(= 6,400 bytes 的 0)。
    /// 格式契約同 `send` —— 送進 ASR 的一律是 16kHz mono Int16 LE。
    /// 只在**沒人說話**時送,所以既不會插進句子中間,也不會讓帳單長成整場會議時長
    /// (2 秒才補 200ms,duty cycle 10%)。
    static let silenceChunk = Data(count: 3_200 * MemoryLayout<Int16>.size)

    /// 第 n 次重連前要等多久:0.5s → 1s → 2s → 4s → 封頂 5s。
    /// 不設嘗試上限:會議可能開一小時,網路斷 5 分鐘後回來也該自己接上。
    /// `nonisolated`:純計算,不碰任何 actor 狀態(測試也才能直接叫)。
    nonisolated static func reconnectDelay(attempt: Int) -> TimeInterval {
        let exponential = 0.5 * pow(2.0, Double(max(1, attempt) - 1))
        return min(exponential, 5.0)
    }

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
        self.modelContext = modelContext
        self.fluidAudioService = fluidAudioService

        var cont: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(512)) { cont = $0 }
        self.continuation = cont

        self.segmenter = MeetingPartialSegmenterBox()
    }

    /// 建一條新的底層串流。**重連時整個重建**(而不是對同一個 service 再 connect 一次):
    /// `StreamingTranscriptionService` 的 send loop 與 event consumer 都在 `startStreaming`
    /// 時把當下的 provider **快照**進 detached task,原地重接會留下對著舊 provider 的迴圈。
    /// 重建則讓舊的整組隨 `cancel()` 一起退場,不必動到聽寫路徑共用的那個類別。
    private func makeService() -> StreamingTranscriptionService {
        let segmenter = self.segmenter
        let cont = self.continuation
        let label = self.label
        let closureLogger = self.logger

        // committed 段落 = 停頓切段(`MeetingPartialSegmenter`):partial(已被 service
        // 正規化成累積全文)停止變化 1.5s → 吐出 delta。cue 偵測掛在 committed 事件上,
        // 不能等底層 ASR 的 confirm —— FluidAudio 的 agreement engine 對中文/短會議
        // 幾乎永遠不 confirm(句尾標點只認 ASCII、永遠保留最後 2 句當 hypothesis),
        // 實測整場 31 秒零次 mid-stream confirm。底層真的 confirm 時(雲端 provider
        // 每句觸發)由 onCommittedSegment 立即切段;兩條路共用同一個 emitted 偏移,
        // 結構上不會重複發同一段。
        let service = StreamingTranscriptionService(
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
        service.onStreamError = { [weak self] error in
            self?.handleStreamDeath(error)
        }
        return service
    }

    /// 語言用 meeting 專屬設定覆蓋(auto 對非目標語言會整段誤判,見 MeetingCopilotConfigStore.asrLanguage)。
    private func makeContext() -> TranscriptionRequestContext {
        let base = TranscriptionRequestContext.currentDefaults
        return TranscriptionRequestContext(language: language ?? base.language, prompt: base.prompt)
    }

    func start() async throws {
        let service = makeService()
        try await service.startStreaming(model: model, context: makeContext())
        serviceBox.replace(with: service, at: ProcessInfo.processInfo.systemUptime)
        isRunning = true
        continuation.yield(.sessionStarted)

        startSegmentTick()
        startKeepAlive()
    }

    /// 停頓偵測 tick:200ms 輪詢遠細於 0.8s 的停頓門檻,不成為延遲瓶頸。
    /// (從 500ms 降到 200ms:切段最多提早約 0.3s 送出,近乎零成本的即時字幕優化。)
    /// 同一個 tick 也負責回報**未定稿尾巴**給 provisional 即時翻譯(Stage B):切段後尾巴變空,
    /// 恰好讓 provisional 收掉;只有尾巴變動才 hop 回 MainActor,成本可忽略。
    private func startSegmentTick() {
        let segmenter = self.segmenter
        let cont = self.continuation
        let logger = self.logger
        let label = self.label
        tickTask = Task.detached(priority: .utility) { [weak self] in
            var lastTail = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                if let segment = segmenter.poll(at: ProcessInfo.processInfo.systemUptime) {
                    logger.notice("🎼 [\(label, privacy: .public)] 停頓切段 \(segment.count, privacy: .public) 字: \(segment, privacy: .public)")
                    cont.yield(.committed(text: segment))
                }
                // 未定稿尾巴(切段後 = 空)→ 尾巴變動才回報,provisional 翻譯據此更新/收掉。
                let tail = segmenter.provisionalTail()
                if tail != lastTail {
                    lastTail = tail
                    await self?.emitProvisionalTail(tail)
                }
            }
        }
    }

    /// 保活 / 休眠 / 喚醒的心跳(500ms)。
    ///
    /// 本機模型(FluidAudio)沒有 socket 可以死,補靜音只是白燒 CPU、還可能讓模型對著
    /// 靜音吐出幻覺字;也沒有「計費」可以省 —— 整條心跳直接不開。
    private func startKeepAlive() {
        guard model.provider != .fluidAudio else { return }

        let tick = Self.keepAliveTickInterval
        // `Task`(非 detached)→ 繼承 @MainActor:tick 要能碰 isDormant / 開重連 Task。
        // 500ms 一次的 MainActor 工作,成本可以忽略。
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self, !Task.isCancelled else { return }
                self.keepAliveTick()
            }
        }
    }

    private func keepAliveTick() {
        guard isRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime

        if isDormant {
            // 休眠中只等一件事:有人開口了沒。
            if serviceBox.signalTimestamp() > dormantSince { wake() }
            return
        }

        // 重連中不插手(沒有 service 可以保活,休眠判斷也該等接上再說)。
        guard reconnectTask == nil else { return }

        if now - serviceBox.signalTimestamp() >= Self.idleDormancyThreshold {
            sleepDormant(at: now)
            return
        }

        serviceBox.sendKeepAliveIfIdle(Self.silenceChunk, at: now, idleAfter: Self.keepAliveIdleThreshold)
    }

    /// 長時間無聲 → 收掉 socket。**不再送任何東西 = 不再計費**;音訊繼續進 box 的暫存,
    /// 對方一開口就會被 `wake` 補送出去。
    private func sleepDormant(at now: TimeInterval) {
        let minutes = Int(Self.idleDormancyThreshold / 60)
        logger.notice("🎧 [\(self.label, privacy: .public)] 靜音 \(minutes, privacy: .public) 分鐘 → ASR 休眠(停止串流;有聲音會自動喚醒)")

        let idle = serviceBox.replace(with: nil, at: now)
        idle?.cancel()
        // 休眠前把殘餘吐乾淨,並歸零切段器 —— 喚醒後是一條全新的流(理由同 `handleStreamDeath`)。
        if let residual = segmenter.flush() {
            continuation.yield(.committed(text: residual))
        }
        segmenter.reset()

        isDormant = true
        dormantSince = now
    }

    /// 休眠中偵測到聲音 → 立刻重連(不等退避:對方已經在說話了)。
    private func wake() {
        logger.notice("🎧 [\(self.label, privacy: .public)] 偵測到聲音 → ASR 喚醒")
        isDormant = false
        reconnectTask = Task { [weak self] in
            await self?.connectLoop(immediate: true)
        }
    }

    /// 底層回報這條流死了(伺服器關 socket / 連續送失敗)。
    ///
    /// 在此之前這件事**沒有任何一層看得到** —— service 只把 `.error` log 掉,
    /// send loop 對著死 socket 無限重送。這裡是那條缺掉的線。
    private func handleStreamDeath(_ error: Error) {
        guard isRunning, reconnectTask == nil else { return }
        logger.error("🎧 [\(self.label, privacy: .public)] ASR 串流中斷: \(error.localizedDescription, privacy: .public) — 開始重連")
        // 上層(MeetingLiveTranscriber)只 log,但這行讓「這場的 ASR 曾經斷過」留在事件流裡。
        continuation.yield(.error(error))

        // 死掉的 service 立刻拆掉:留著它的 send loop 只會繼續對死 socket 重送。
        let dead = serviceBox.replace(with: nil, at: ProcessInfo.processInfo.systemUptime)
        dead?.cancel()

        // 斷線前 ASR 真的聽到、但還沒切出來的殘餘字先吐出去,再把切段器歸零 ——
        // 新串流的累積全文從空字串重新長起來,舊座標留著沒有意義。
        if let residual = segmenter.flush() {
            continuation.yield(.committed(text: residual))
        }
        segmenter.reset()

        reconnectTask = Task { [weak self] in
            await self?.connectLoop(immediate: false)
        }
    }

    /// 接一條新流,失敗就指數退避重試,直到接上或會議結束。
    ///
    /// - Parameter immediate: 第一次嘗試不等退避。喚醒走這條(對方已經在說話了,
    ///   每多等 0.5 秒就多吃掉半句);斷線重連則先等一下,避免對著剛掛掉的伺服器猛捶。
    private func connectLoop(immediate: Bool) async {
        var attempt = 0
        while isRunning {
            attempt += 1
            if !(immediate && attempt == 1) {
                try? await Task.sleep(for: .seconds(Self.reconnectDelay(attempt: attempt)))
            }
            guard isRunning, !Task.isCancelled else { break }

            do {
                let service = makeService()
                try await service.startStreaming(model: model, context: makeContext())
                // 會議在我們連線期間結束了 → 這條新流沒人要,直接收掉。
                guard isRunning else {
                    service.cancel()
                    break
                }
                // replace 會把空窗期暫存的音訊補送出去 —— 對方開口的第一句話不掉字。
                serviceBox.replace(with: service, at: ProcessInfo.processInfo.systemUptime)
                logger.notice("🎧 [\(self.label, privacy: .public)] ASR 已接上(第 \(attempt, privacy: .public) 次嘗試)")
                reconnectTask = nil
                return
            } catch {
                logger.error("🎧 [\(self.label, privacy: .public)] ASR 連線失敗(第 \(attempt, privacy: .public) 次): \(error.localizedDescription, privacy: .public)")
            }
        }
        reconnectTask = nil
    }

    /// `nonisolated` —— 才能直接從 consumer thread 呼叫,不必繞 MainActor。
    /// 底層的 `StreamingTranscriptionService.sendAudioChunk` 本身就是 `nonisolated`,
    /// 明示可從 CoreAudio/處理執行緒呼叫。
    ///
    /// 這裡順手算這塊音訊有沒有能量:休眠/喚醒**不能**拿「有沒有 frame 進來」當訊號 ——
    /// 對方 app 佔住音訊裝置時,沒人說話也會有源源不絕的 0 樣本 frame(事故 log 裡那些
    /// `REMOTE[0.0000]`)。拿 frame 判斷的話,忘了關的會議永遠不會休眠。
    nonisolated func send(_ pcm16: Data) {
        serviceBox.sendAudio(
            pcm16,
            at: ProcessInfo.processInfo.systemUptime,
            hasSignal: Self.hasSignal(pcm16))
    }

    func finish() async {
        isRunning = false
        isDormant = false
        reconnectTask?.cancel()
        reconnectTask = nil
        keepAliveTask?.cancel()
        keepAliveTask = nil
        tickTask?.cancel()
        tickTask = nil

        // 重連空窗期收會議 → 根本沒有 service 可以收尾(舊的已 cancel 掉了)。
        if let service = serviceBox.replace(with: nil, at: ProcessInfo.processInfo.systemUptime) {
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
