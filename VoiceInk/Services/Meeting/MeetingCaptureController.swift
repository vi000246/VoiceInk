import AppKit
import SwiftUI
import os

/// 會議錄製的 glue 層:啟停 `MeetingCaptureService`、經過時間、浮動指示器、
/// 完成後交給 `RecorderImportService.importMeetingFile` 走既有管線。
/// 與聽寫的 `RecordingState` 狀態機完全解耦——會議錄製與聽寫可同時進行。
@MainActor
final class MeetingCaptureController: ObservableObject {
    static let shared = MeetingCaptureController()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCapture")

    @Published private(set) var isRecording = false
    @Published private(set) var elapsedText = "00:00"
    /// copilot live pipeline 是否正在跑(可在會議中隨時開關;圖示狀態的單一事實來源)。
    @Published private(set) var copilotActive = false

    private let service = MeetingCaptureService.shared
    private var indicator: MeetingIndicatorWindowManager?
    private var timer: Timer?
    private var startedAt: Date?
    private var sourceLabel = "會議"
    /// 本場會議產生過的 copilot session(中途開關會產生多個);匯入時回填 importFingerprint。
    private var copilotSessionIds: [UUID] = []

    private init() {
        // quit 途中盡力保檔:willTerminate 是同步 context,用短暫 runloop spin 等 async 收尾。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                Task { @MainActor in await self.stopAndImport() }
                let deadline = Date().addingTimeInterval(2)
                while self.isRecording && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
        }
    }

    func toggle() async {
        if isRecording { await stopAndImport() } else { await start() }
    }

    func start() async {
        guard !isRecording else { return }
        // 前景 app 名做來源標籤(點選單列不會 activate 自己,通常仍是會議 app)。
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        sourceLabel = app.map { "會議 · \($0)" } ?? "會議"
        do {
            try await service.start(micEnabled: RecorderConfigStore.shared.meetingMicEnabled)
        } catch {
            logger.error("Meeting start failed: \(error.localizedDescription, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: "無法開始會議錄製（可能未授權系統音訊）",
                type: .error, duration: 8,
                actionButton: ("開啟設定", Self.openAudioCapturePrivacySettings))
            return
        }
        startedAt = Date()
        isRecording = true
        elapsedText = "00:00"
        copilotSessionIds = []
        startTimer()
        if indicator == nil { indicator = MeetingIndicatorWindowManager(controller: self) }
        indicator?.show()

        // meeting-copilot 即時輔助:copilotEnabled 時把 realtime seam 接成 live pipeline
        // (cue 偵測 → 三層回應 → overlay)。ring buffer 恆由 service 建立,
        // 所以也能在會議中途用 setCopilotEnabled 補開。
        if MeetingCopilotConfigStore.shared.copilotEnabled {
            attachCopilotLive()
        }

        logger.notice("Meeting recording started — \(self.sourceLabel, privacy: .public)")
    }

    /// 會議中隨時開關即時輔助(選單列 / 錄音指示器)。同步寫回持久設定,
    /// 並在錄音進行中時立即啟停 live pipeline;非錄音中只改設定。
    func setCopilotEnabled(_ on: Bool) {
        MeetingCopilotConfigStore.shared.setCopilotEnabled(on)
        guard isRecording else { return }
        if on {
            attachCopilotLive()
        } else if copilotActive {
            MeetingCopilotLiveController.shared.stop()
            copilotActive = false
            logger.notice("Meeting copilot detached mid-meeting")
        }
    }

    private func attachCopilotLive() {
        guard !copilotActive, let ring = service.copilotRingBuffer else { return }
        // 中途開啟時 ring 裡是至多 8 秒的舊音訊 + 滿載計數 —— 跳到最新再掛 consumer。
        ring.resetToLatest()
        service.noteCopilotConsumerAttached()
        MeetingCopilotLiveController.shared.start(
            ring: ring,
            tapChannelCount: service.copilotTapChannelCount,
            appName: sourceLabel)
        // start() 內部 guard 失敗(未 configure / 無串流 ASR 模型)時不會建 session ——
        // 以 session 是否存在為準,避免圖示亮著但 pipeline 根本沒跑。
        if let id = MeetingCopilotLiveController.shared.currentSessionId {
            copilotSessionIds.append(id)
            copilotActive = true
        }
    }

    func stopAndImport() async {
        guard isRecording else { return }
        timer?.invalidate(); timer = nil
        indicator?.hide()
        isRecording = false

        // 先停 copilot live pipeline(轉錄消費者)再收音訊檔。
        MeetingCopilotLiveController.shared.stop()
        copilotActive = false
        guard let url = await service.stop() else {
            // service 已對「零音訊」情境發出帶引導的通知,這裡不重複彈。
            logger.notice("Meeting stop returned no file (empty recording or no session)")
            return
        }
        RecorderImportService.shared.importMeetingFile(
            url, sourceLabel: sourceLabel, meetingSessionIds: copilotSessionIds)
        copilotSessionIds = []
    }

    // MARK: - 浮動視窗:拖曳 / 移到其他螢幕(錄製列 UI 呼叫)

    /// 錄製列 panel 的螢幕座標原點(整窗拖曳用)。
    var indicatorOrigin: NSPoint? { indicator?.panelOrigin }
    func setIndicatorOrigin(_ origin: NSPoint) { indicator?.setPanelOrigin(origin) }
    /// 錄製列目前所在螢幕(供螢幕選單排除自己)。
    var indicatorScreen: NSScreen? { indicator?.currentScreen }

    /// 把錄製列 + copilot overlay + 讀稿面板一起移到指定螢幕。
    /// overlay / 讀稿面板未顯示時各自 no-op(panel 為 nil)。
    func moveFloatingWindows(to screen: NSScreen) {
        indicator?.move(to: screen)
        CopilotOverlayWindowManager.shared.move(to: screen)
        PresenterScriptWindowManager.shared.move(to: screen)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let startedAt else { return }
        let s = Int(Date().timeIntervalSince(startedAt))
        elapsedText = s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// 系統音訊錄製權限頁。anchor 在部分版本可能無效 → fallback 開 Privacy 根頁。
    private static func openAudioCapturePrivacySettings() {
        let anchored = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        if let anchored, NSWorkspace.shared.open(anchored) { return }
        if let root = URL(string: "x-apple.systempreferences:com.apple.preference.security") {
            NSWorkspace.shared.open(root)
        }
    }
}
