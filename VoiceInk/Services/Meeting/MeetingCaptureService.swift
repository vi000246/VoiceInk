import Foundation
import AppKit
import Combine
import CoreAudio
import AudioToolbox
import os

// MARK: - MeetingCaptureService
//
// 會議錄音服務:用 CoreAudio process tap 抓「所有系統音訊輸出」,(可選)混入麥克風,
// 即時等權混成 mono 寫進一個 AAC .m4a。
//
// 設計 / Design(呼叫序列比照 insidegui/AudioCap 的 ProcessTap.swift):
//
// 1. CATapDescription(stereoGlobalTapButExcludeProcesses: [自己]) 建立 system-wide tap,
//    排除自身行程避免把 VoiceInk 的提示音錄進去;`isPrivate = true` 不讓 tap 曝露給其他
//    行程,muteBehavior 維持 `.unmuted`(使用者照常聽得到聲音)。
//    AudioHardwareCreateProcessTap 失敗即視為未授權(TCC「系統音訊錄製」)或系統拒絕。
// 2. Tap 本身不能直接掛 IOProc,必須包進一個 private aggregate device:tap 進
//    kAudioAggregateDeviceTapListKey,micEnabled 時把預設輸入裝置以 sub-device 進
//    kAudioAggregateDeviceSubDeviceListKey,兩者都開 drift compensation。同一個
//    IOProc callback 會同時拿到 tap 與 mic 的所有 input stream,逐輪混音天生對齊,
//    不需要事後對時間軸。
// 3. 用 raw HAL(AudioDeviceCreateIOProcIDWithBlock + AudioDeviceStart)而不是
//    AVAudioEngine:AVAudioEngine 對 tap-backed aggregate 會默默忽略 tap stream
//    (input node 只給 mic 或無聲),所以這裡完全繞開它。
// 4. Tap 的 stream format 跟著預設輸出裝置走;使用者插拔耳機/切換喇叭時,舊 tap 可能
//    停止供資料或格式失效。因此監聽 kAudioHardwarePropertyDefaultOutputDevice,一觸發
//    就把 IOProc、aggregate、tap「整組拆掉重建」(單獨換零件不可靠),但沿用同一個
//    ExtAudioFile 續寫 —— 使用者最後拿到的仍是完整單一檔案。
// 5. 寫檔用 ExtAudioFile:檔案格式 AAC mono,client 格式 Float32 mono(aggregate 取樣率),
//    IOProc 內用 ExtAudioFileWriteAsync(資料會被複製進內部佇列、由背景執行緒編碼寫入,
//    是 Apple 官方認可的 realtime-safe 寫檔方式)。
//
// Teardown 順序(嚴格照 AudioCap):AudioDeviceStop → AudioDeviceDestroyIOProcID →
// AudioHardwareDestroyAggregateDevice → AudioHardwareDestroyProcessTap → 移除 listener →
// ExtAudioFileDispose(flush 剩餘 async 資料)。

// MARK: - Realtime capture context

/// IOProc 在 HAL 的 realtime thread 上執行,不可觸碰 @MainActor 狀態;callback 需要的
/// 一切(ExtAudioFile、scratch、峰值)都集中在這個小 class,由 IO block 直接捕捉,
/// 完全不經過 service 的 self。刻意放在頂層(而非巢狀於 @MainActor class 內),
/// 確保它的方法不會被推導成 MainActor-isolated。
private final class MeetingCaptureContext: @unchecked Sendable {
    let extFile: ExtAudioFileRef

    /// Deinterleave 用 scratch。首個 callback 依實際聲道數/frame 數配置,之後重複使用;
    /// 只有格式改變(裝置重建、buffer size 改變)才重新配置。只在 IOProc thread 上觸碰。
    private var channelScratch: [[Float]] = []
    private var scratchFrames: Int = 0

    /// 累積的輸入訊號峰值(所有聲道,含 mic),zero-signal 探測用。
    /// IOProc 寫、主執行緒讀,刻意不加鎖:這只是啟發式判斷,32-bit Float 的
    /// 對齊讀寫在 arm64/x86_64 上不會撕裂,讀到稍舊的值無妨。
    var tapPeak: Float = 0

    /// ExtAudioFileWriteAsync 失敗統計(IOProc thread 累加,finalize 時回報一次,
    /// 避免在 realtime thread 上打 log)。
    var asyncWriteErrorCount: UInt64 = 0
    var lastAsyncWriteStatus: OSStatus = noErr

    init(extFile: ExtAudioFileRef) {
        self.extFile = extFile
    }

    /// IOProc 主體:把這一輪的所有 input stream(tap + 可選 mic)deinterleave 成
    /// 逐聲道緩衝 → 等權混成 mono → 非同步寫入 AAC 檔。
    func handleIO(_ inInputData: UnsafePointer<AudioBufferList>) {
        let ablPointer = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        guard ablPointer.count > 0 else { return }

        // 這一輪的 frame 數(各 stream 應一致,以第一個有效 buffer 為準)與總聲道數。
        var frameCount = 0
        var totalChannels = 0
        for buffer in ablPointer {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float32>.size)
            if frameCount == 0 { frameCount = frames }
            totalChannels += channels
        }
        guard frameCount > 0, totalChannels > 0 else { return }

        // Scratch 只在格式改變時重新配置;正常情況整段錄音只配置一次。
        if channelScratch.count != totalChannels || scratchFrames != frameCount {
            channelScratch = Array(
                repeating: [Float](repeating: 0, count: frameCount),
                count: totalChannels
            )
            scratchFrames = frameCount
        }

        var chIndex = 0
        var peak = tapPeak
        for buffer in ablPointer {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            let bufferFrames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float32>.size)
            let frames = min(bufferFrames, frameCount)

            guard let mData = buffer.mData else {
                // 沒資料的 stream 補 0,避免殘留上一輪樣本。
                for c in 0..<channels where chIndex + c < channelScratch.count {
                    channelScratch[chIndex + c].withUnsafeMutableBufferPointer { dst in
                        for i in 0..<frameCount { dst[i] = 0 }
                    }
                }
                chIndex += channels
                continue
            }

            let samples = mData.assumingMemoryBound(to: Float32.self)
            for c in 0..<channels {
                guard chIndex + c < channelScratch.count else { break }
                channelScratch[chIndex + c].withUnsafeMutableBufferPointer { dst in
                    var i = 0
                    while i < frames {
                        let value = samples[i * channels + c]
                        dst[i] = value
                        let magnitude = abs(value)
                        if magnitude > peak { peak = magnitude }
                        i += 1
                    }
                    while i < frameCount {
                        dst[i] = 0
                        i += 1
                    }
                }
            }
            chIndex += channels
        }
        tapPeak = peak

        var mono = MeetingAudioMixer.mixToMono(channelBuffers: channelScratch, frameCount: frameCount)
        guard mono.count == frameCount else { return }

        let writeStatus: OSStatus = mono.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return noErr }
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(frameCount * MemoryLayout<Float32>.size),
                    mData: UnsafeMutableRawPointer(base)
                )
            )
            // ExtAudioFileWriteAsync 會把資料複製進內部佇列再由背景執行緒寫入,
            // mono 緩衝可安全地逐輪重用。
            return ExtAudioFileWriteAsync(extFile, UInt32(frameCount), &abl)
        }
        if writeStatus != noErr {
            asyncWriteErrorCount += 1
            lastAsyncWriteStatus = writeStatus
        }
    }
}

@MainActor
final class MeetingCaptureService: ObservableObject {

    static let shared = MeetingCaptureService()

    // MARK: - State

    enum State: Equatable {
        case idle
        case recording(started: Date)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    enum CaptureError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case fileCreationFailed(OSStatus)
        case ioProcFailed(OSStatus)
        case notRecording

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                return "無法建立系統音訊 tap(狀態碼 \(status))—— 可能尚未授權「系統音訊錄製」"
            case .aggregateCreationFailed(let status):
                return "無法建立聚合音訊裝置(狀態碼 \(status))"
            case .fileCreationFailed(let status):
                return "無法建立會議錄音檔(狀態碼 \(status))"
            case .ioProcFailed(let status):
                return "無法啟動音訊擷取(狀態碼 \(status))"
            case .notRecording:
                return "目前沒有進行中的會議錄音"
            }
        }
    }

    // MARK: - Properties

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCapture")

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var captureContext: MeetingCaptureContext?
    private var outputURL: URL?
    private var micEnabled = true
    /// 目前 ExtAudioFile client format 的取樣率;重建後若 aggregate 取樣率改變要跟著更新。
    private var fileClientSampleRate: Double = 0
    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var probeTask: Task<Void, Never>?
    private var isRebuilding = false

    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    // MARK: - Public API

    /// 開始會議錄音。`micEnabled` 決定是否把預設輸入裝置(麥克風)一併混入。
    func start(micEnabled: Bool) async throws {
        if case .recording = state {
            logger.notice("🎬 start() ignored — already recording")
            return
        }

        self.micEnabled = micEnabled

        // 1. 輸出檔:<yyMMdd_HHmm> 會議<前景 App 名>.m4a(stamp 格式有既有解析器依賴,勿改)
        let url = try makeOutputURL()

        do {
            // 2–4. system-wide tap + private aggregate
            let rates = try createTapAndAggregate(micEnabled: micEnabled)

            // 5. ExtAudioFile(AAC mono .m4a;client = aggregate 取樣率的 Float32 mono)
            let extFile = try createOutputFile(
                at: url,
                fileSampleRate: rates.tapSampleRate,
                clientSampleRate: rates.aggregateSampleRate
            )
            let context = MeetingCaptureContext(extFile: extFile)
            captureContext = context
            fileClientSampleRate = rates.aggregateSampleRate

            // 6–7. IOProc + AudioDeviceStart
            try installIOProcAndStart(context: context)
        } catch {
            // 把已建立的部分拆乾淨;start 失敗時檔案沒有內容,順手刪掉。
            destroyGraph()
            finalizeFileIfNeeded()
            try? FileManager.default.removeItem(at: url)
            outputURL = nil
            state = .failed(error.localizedDescription)
            logger.error("🎬 Meeting capture start failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }

        outputURL = url

        // 8. 預設輸出裝置變更 → 整組重建(沿用同一檔案)
        installOutputDeviceListener()

        state = .recording(started: Date())
        scheduleZeroSignalProbe()
        logger.notice("🎬 Meeting capture started → \(url.lastPathComponent, privacy: .public) mic=\(micEnabled, privacy: .public)")
    }

    /// 停止錄音並收檔。回傳完成的檔案 URL;沒有進行中的 session 時回傳 nil。
    /// 從任何失敗路徑呼叫都安全(全部步驟都有 idempotent guard)。
    func stop() async -> URL? {
        let hasSession = captureContext != nil
            || tapID != kAudioObjectUnknown
            || aggregateID != kAudioObjectUnknown
        guard hasSession else { return nil }

        probeTask?.cancel()
        probeTask = nil

        // AudioDeviceStop → DestroyIOProcID → DestroyAggregateDevice → DestroyProcessTap
        destroyGraph()
        removeOutputDeviceListener()
        // ExtAudioFileDispose 會 flush 佇列中尚未寫完的 async 資料
        finalizeFileIfNeeded()

        let url = outputURL
        outputURL = nil
        state = .idle

        if let url {
            logger.notice("🎬 Meeting capture stopped → \(url.lastPathComponent, privacy: .public)")
        }
        return url
    }

    // MARK: - Graph construction (steps 2–4, 6–7)

    private struct GraphRates {
        var tapSampleRate: Double
        var aggregateSampleRate: Double
    }

    /// 步驟 2–4:建 tap、讀 tap 格式、建 private aggregate。
    /// 失敗時「不」自行清理,由呼叫端統一走 destroyGraph()(它對半成品也安全)。
    private func createTapAndAggregate(micEnabled: Bool) throws -> GraphRates {
        // 2. system-wide tap,排除自身行程(pid → CoreAudio process object)
        var excludedProcesses: [NSNumber] = []
        do {
            let ownProcessObject = try translatePIDToProcessObject(
                pid: ProcessInfo.processInfo.processIdentifier
            )
            excludedProcesses = [NSNumber(value: ownProcessObject)]
        } catch {
            // 拿不到自身 process object 仍可錄,只是自家提示音也會入鏡。
            logger.warning("🎬 Failed to translate own pid to process object — not excluding self")
        }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            // TCC(系統音訊錄製權限)被拒也會走到這裡。
            logger.error("🎬 AudioHardwareCreateProcessTap failed: \(status, privacy: .public)")
            throw CaptureError.tapCreationFailed(status)
        }
        tapID = newTapID
        logger.notice("🎬 Created process tap #\(newTapID, privacy: .public)")

        // 3. tap 的 stream format(取樣率/聲道數)
        let tapFormat = try readTapStreamFormat(tapID: newTapID)
        logger.notice("🎬 Tap format: rate=\(tapFormat.mSampleRate, privacy: .public) channels=\(tapFormat.mChannelsPerFrame, privacy: .public)")

        // 4. private aggregate:tap list + (可選) mic sub-device,皆開 drift compensation
        var composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoiceInk Meeting",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        if micEnabled {
            if let micUID = defaultInputDeviceUID() {
                composition[kAudioAggregateDeviceSubDeviceListKey] = [
                    [
                        kAudioSubDeviceUIDKey: micUID,
                        kAudioSubDeviceDriftCompensationKey: true
                    ]
                ]
            } else {
                logger.warning("🎬 micEnabled but no default input device — capturing system audio only")
            }
        }

        var newAggregateID: AudioObjectID = kAudioObjectUnknown
        status = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            logger.error("🎬 AudioHardwareCreateAggregateDevice failed: \(status, privacy: .public)")
            throw CaptureError.aggregateCreationFailed(status)
        }
        aggregateID = newAggregateID
        logger.notice("🎬 Created aggregate device #\(newAggregateID, privacy: .public)")

        let aggregateRate = readNominalSampleRate(deviceID: newAggregateID) ?? tapFormat.mSampleRate
        return GraphRates(tapSampleRate: tapFormat.mSampleRate, aggregateSampleRate: aggregateRate)
    }

    /// 步驟 6–7:掛 IOProc(queue 傳 nil → HAL realtime thread)並啟動 aggregate。
    private func installIOProcAndStart(context: MeetingCaptureContext) throws {
        var newProcID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) { _, inInputData, _, _, _ in
            // realtime thread:只透過 context 工作,絕不碰 @MainActor 的 self。
            context.handleIO(inInputData)
        }
        guard status == noErr, let procID = newProcID else {
            logger.error("🎬 AudioDeviceCreateIOProcIDWithBlock failed: \(status, privacy: .public)")
            throw CaptureError.ioProcFailed(status)
        }
        ioProcID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            logger.error("🎬 AudioDeviceStart failed: \(status, privacy: .public)")
            throw CaptureError.ioProcFailed(status)
        }
    }

    // MARK: - File (step 5)

    private func makeOutputURL() throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyMMdd_HHmm"
        let stamp = formatter.string(from: Date())

        let rawAppName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        let appName = Self.sanitizeForFilename(rawAppName)

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("MeetingCaptures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory.appendingPathComponent("\(stamp) 會議\(appName).m4a")
    }

    /// 去掉檔名不合法字元(/ 與 : 是 macOS 檔名禁字,順帶清掉控制字元與換行)。
    private static func sanitizeForFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
            .union(.newlines)
        return name.components(separatedBy: illegal).joined()
    }

    private func createOutputFile(
        at url: URL,
        fileSampleRate: Double,
        clientSampleRate: Double
    ) throws -> ExtAudioFileRef {
        // 檔案格式:AAC mono。除取樣率/聲道數外全留 0,讓編碼器自行補齊。
        var aacFormat = AudioStreamBasicDescription(
            mSampleRate: fileSampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var fileRef: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            kAudioFileM4AType,
            &aacFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &fileRef
        )
        guard status == noErr, let extFile = fileRef else {
            logger.error("🎬 ExtAudioFileCreateWithURL failed: \(status, privacy: .public)")
            throw CaptureError.fileCreationFailed(status)
        }

        // Client 格式:aggregate 取樣率的 packed Float32 mono(mono 下 interleaved 與
        // non-interleaved 等價);與檔案取樣率不同時 ExtAudioFile 會自動做 SRC。
        var clientFormat = Self.makeClientFormat(sampleRate: clientSampleRate)
        status = ExtAudioFileSetProperty(
            extFile,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else {
            ExtAudioFileDispose(extFile)
            logger.error("🎬 Failed to set client data format: \(status, privacy: .public)")
            throw CaptureError.fileCreationFailed(status)
        }

        // 在非即時執行緒上先呼叫一次 0-frame 的 async write,讓 ExtAudioFile 把內部
        // 佇列/背景執行緒準備好,之後 IOProc 內的呼叫才不會觸發首次配置。
        status = ExtAudioFileWriteAsync(extFile, 0, nil)
        if status != noErr {
            logger.warning("🎬 Priming ExtAudioFileWriteAsync returned \(status, privacy: .public)")
        }

        return extFile
    }

    private static func makeClientFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float32>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float32>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    // MARK: - Device-change rebuild (step 8)

    private func installOutputDeviceListener() {
        guard outputDeviceListenerBlock == nil else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Listener 已指定派送到 main queue;再經 Task 回到 MainActor 執行重建。
            Task { @MainActor [weak self] in
                await self?.rebuildGraphKeepingFile()
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            outputDeviceListenerBlock = block
        } else {
            logger.warning("🎬 AudioObjectAddPropertyListenerBlock failed: \(status, privacy: .public)")
        }
    }

    private func removeOutputDeviceListener() {
        guard let block = outputDeviceListenerBlock else { return }
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            logger.warning("🎬 AudioObjectRemovePropertyListenerBlock failed: \(status, privacy: .public)")
        }
        outputDeviceListenerBlock = nil
    }

    /// 預設輸出裝置改變:拆掉 IOProc → aggregate → tap,原地重建整組,續寫同一個檔案。
    /// 任何一步失敗 → 收檔並進入 .failed,發通知讓使用者知道錄音中斷(已寫入的內容保留)。
    private func rebuildGraphKeepingFile() async {
        guard case .recording = state, !isRebuilding, let context = captureContext else { return }
        isRebuilding = true
        defer { isRebuilding = false }

        logger.notice("🎬 Default output device changed — rebuilding tap + aggregate (keeping file)")

        destroyGraph()

        do {
            let rates = try createTapAndAggregate(micEnabled: micEnabled)

            // 新 aggregate 取樣率若改變,更新 client format,ExtAudioFile 會自動 SRC 到檔案格式。
            if rates.aggregateSampleRate != fileClientSampleRate {
                var clientFormat = Self.makeClientFormat(sampleRate: rates.aggregateSampleRate)
                let status = ExtAudioFileSetProperty(
                    context.extFile,
                    kExtAudioFileProperty_ClientDataFormat,
                    UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                    &clientFormat
                )
                guard status == noErr else {
                    throw CaptureError.fileCreationFailed(status)
                }
                logger.notice("🎬 Client format updated: \(self.fileClientSampleRate, privacy: .public) → \(rates.aggregateSampleRate, privacy: .public)")
                fileClientSampleRate = rates.aggregateSampleRate
            }

            try installIOProcAndStart(context: context)
            logger.notice("🎬 Rebuild complete")
        } catch {
            logger.error("🎬 Rebuild failed: \(error.localizedDescription, privacy: .public)")

            // 收尾(等同 stop 的 finalize 路徑),保留已寫入的檔案內容。
            destroyGraph()
            removeOutputDeviceListener()
            probeTask?.cancel()
            probeTask = nil
            finalizeFileIfNeeded()
            state = .failed(error.localizedDescription)

            NotificationManager.shared.showNotification(
                title: "會議錄音已中斷:\(error.localizedDescription)",
                type: .warning,
                duration: 6
            )
        }
    }

    // MARK: - Teardown helpers (idempotent)

    /// 拆掉音訊圖(不動檔案):AudioDeviceStop → AudioDeviceDestroyIOProcID →
    /// AudioHardwareDestroyAggregateDevice → AudioHardwareDestroyProcessTap。
    /// 對半成品(部分為 unknown)呼叫也安全。
    private func destroyGraph() {
        if aggregateID != kAudioObjectUnknown {
            if let procID = ioProcID {
                var status = AudioDeviceStop(aggregateID, procID)
                if status != noErr {
                    logger.warning("🎬 AudioDeviceStop returned \(status, privacy: .public)")
                }
                status = AudioDeviceDestroyIOProcID(aggregateID, procID)
                if status != noErr {
                    logger.warning("🎬 AudioDeviceDestroyIOProcID returned \(status, privacy: .public)")
                }
            }
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr {
                logger.warning("🎬 AudioHardwareDestroyAggregateDevice returned \(status, privacy: .public)")
            }
            aggregateID = kAudioObjectUnknown
        }
        ioProcID = nil

        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                logger.warning("🎬 AudioHardwareDestroyProcessTap returned \(status, privacy: .public)")
            }
            tapID = kAudioObjectUnknown
        }
    }

    /// 關檔(ExtAudioFileDispose 會 flush 佇列中的 async 資料)。重複呼叫安全。
    private func finalizeFileIfNeeded() {
        guard let context = captureContext else { return }
        if context.asyncWriteErrorCount > 0 {
            logger.warning("🎬 \(context.asyncWriteErrorCount, privacy: .public) async writes failed (last status \(context.lastAsyncWriteStatus, privacy: .public))")
        }
        let status = ExtAudioFileDispose(context.extFile)
        if status != noErr {
            logger.warning("🎬 ExtAudioFileDispose returned \(status, privacy: .public)")
        }
        captureContext = nil
    }

    // MARK: - Zero-signal probe

    /// 開錄 5 秒後檢查:若所有輸入聲道的累積峰值仍趨近 0,很可能是沒授權或當下沒聲音,
    /// 提醒使用者。注意:mic 有訊號時峰值不為 0,偵測不到「只有 tap 無聲」的情況 ——
    /// 這是刻意的簡化(啟發式 v1)。
    private func scheduleZeroSignalProbe() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard case .recording = self.state, let context = self.captureContext else { return }

            if context.tapPeak < 0.0005 {
                self.logger.warning("🎬 Zero-signal probe fired: peak=\(context.tapPeak, privacy: .public)")
                NotificationManager.shared.showNotification(
                    title: "未收到系統音訊——可能未授權或目前沒有聲音",
                    type: .warning,
                    duration: 6
                )
            }
        }
    }

    // MARK: - CoreAudio property helpers

    /// kAudioHardwarePropertyTranslatePIDToProcessObject:pid → CoreAudio process object
    /// (qualifier 傳 pid,讀回 AudioObjectID;比照 AudioCap 的 helper)。
    private func translatePIDToProcessObject(pid: pid_t) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifierPID = pid
        var processObject: AudioObjectID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifierPID) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &dataSize,
                &processObject
            )
        }
        guard status == noErr, processObject != kAudioObjectUnknown else {
            throw CaptureError.tapCreationFailed(status)
        }
        return processObject
    }

    /// kAudioTapPropertyFormat:tap 供應下游的 stream 格式。
    private func readTapStreamFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &dataSize, &format)
        guard status == noErr, format.mSampleRate > 0 else {
            logger.error("🎬 Failed to read tap stream format: \(status, privacy: .public)")
            throw CaptureError.tapCreationFailed(status)
        }
        return format
    }

    /// 預設輸入裝置 UID:kAudioHardwarePropertyDefaultInputDevice → kAudioDevicePropertyDeviceUID。
    private func defaultInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString?
        var uidSize = UInt32(MemoryLayout<CFString>.size)
        status = AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)
        guard status == noErr, let uid else { return nil }
        return uid as String
    }

    /// 裝置目前的 nominal sample rate(kAudioDevicePropertyNominalSampleRate)。
    private func readNominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &rate)
        guard status == noErr, rate > 0 else { return nil }
        return rate
    }
}
