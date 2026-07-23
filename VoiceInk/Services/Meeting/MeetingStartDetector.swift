import AppKit
import CoreGraphics
import os

/// M11 會議開始偵測的 glue（@MainActor singleton）。
///
/// 每 `pollInterval` 秒把「現在時間、收音 bundle id 集合、是否錄音中、設定快照、標題掃描結果」
/// 餵進純狀態機 `MeetingStartDetectorCore`，執行回傳的 effects（發通知／記 log）。
///
/// **與 live pipeline 零耦合**：唯一的動作出口是通知按鈕呼叫 `MeetingCaptureController.shared.start()`；
/// 不建立/不引用 `MeetingCopilotController` / transcriber / coordinator。
@MainActor
final class MeetingStartDetector: ObservableObject {

    static let shared = MeetingStartDetector()

    /// 3s 輪詢（見 SRS：debounce 本來就 3s，秒級即時無必要）。
    static let pollInterval: TimeInterval = 3

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingDetection")
    private var core = MeetingStartDetectorCore()
    private let watcher = AudioProcessMicWatcher()
    private let scanner = MeetingWindowTitleScanner()
    private let config: MeetingDetectionConfigStore

    private var timer: Timer?
    private var started = false
    /// 上一 tick 的候選集合（用來只在「新候選出現」時 log 一行，不每 tick 洗版）。
    private var lastCandidates: Set<String> = []

    init(config: MeetingDetectionConfigStore = .shared) {
        self.config = config
    }

    /// app 啟動時呼叫一次。timer 恆跑（每 3s 讀一個 bool）；停用時 tick 早退，不輪詢 CoreAudio。
    func start() {
        guard !started else { return }
        started = true
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // .common 模式：選單開著、視窗拖曳中也照跑（同 MeetingCaptureController 的 continue-prompt 教訓）。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Tick

    func tick() {
        guard config.enabled else {
            core.reset()
            lastCandidates = []
            return
        }

        let snapshot = MeetingStartDetectorCore.Config(
            enabled: true,
            nativeEnabledBundleIds: config.nativeEnabledBundleIds,
            browsersEnabled: config.browsersEnabled,
            debounce: config.debounceSeconds,
            rearm: config.rearmSeconds,
            cooldown: MeetingStartDetectorCore.Config.defaultCooldown)

        let micBundleIds = watcher.currentlyRecordingBundleIds()
        logNewCandidates(micBundleIds: micBundleIds, snapshot: snapshot)

        let isRecording = MeetingCaptureController.shared.isRecording
        // 權限判斷每 tick 做一次；標題掃描只在 core 認為某瀏覽器候選過了 debounce 時才被呼叫。
        let screenAccess = CGPreflightScreenCaptureAccess()
        let scanner = self.scanner
        let effects = core.tick(
            now: Date(),
            micBundleIds: micBundleIds,
            isRecording: isRecording,
            config: snapshot,
            titleCheck: { family in
                guard screenAccess else { return .unavailable }
                return scanner.hasMeetingWindow(for: family) ? .hit : .miss
            })

        for effect in effects { execute(effect) }
    }

    // MARK: - Effects

    private func execute(_ effect: MeetingStartDetectorCore.Effect) {
        switch effect {
        case let .prompt(bundleId, displayName):
            logger.notice("📡 會議偵測觸發 → 提示：\(displayName, privacy: .public)（\(bundleId, privacy: .public)）")
            NotificationManager.shared.showNotification(
                title: "偵測到會議（\(displayName)）— 要開始會議錄製嗎？",
                type: .info,
                duration: 10,
                actionButton: ("開始會議錄製", {
                    Task { @MainActor in await MeetingCaptureController.shared.start() }
                }))
            // M14 會議脈絡卡：與上面的提示**並行**（內部自行去重＋背景生成，同步入口立即返回，
            // 絕不影響提示通知；使用者稍後按「開始會議錄製」的第二個觸發點會被同場 gate 吃掉）。
            MeetingContextCardService.shared.noteMeetingDetected(
                bundleId: bundleId, displayName: displayName)
        case let .suppressed(bundleId, reason):
            logger.notice("📡 會議偵測抑制（\(reason.rawValue, privacy: .public)）：\(bundleId, privacy: .public)")
        }
    }

    /// 只在「新候選 bundle id 出現」時記一行 notice（FR-92 觀測性，不洗版）。
    private func logNewCandidates(micBundleIds: Set<String>, snapshot: MeetingStartDetectorCore.Config) {
        let candidates = micBundleIds.filter {
            MeetingDetectionCatalog.isCandidate(
                bundleId: $0,
                nativeEnabled: snapshot.nativeEnabledBundleIds,
                browsersEnabled: snapshot.browsersEnabled)
        }
        for bundleId in candidates.subtracting(lastCandidates).sorted() {
            logger.notice("📡 偵測到候選（mic 使用中）：\(MeetingDetectionCatalog.displayName(forBundleId: bundleId), privacy: .public)")
        }
        lastCandidates = candidates
    }
}
