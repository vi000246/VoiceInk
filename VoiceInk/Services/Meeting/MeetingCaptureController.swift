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

    private let service = MeetingCaptureService.shared
    private var indicator: MeetingIndicatorWindowManager?
    private var timer: Timer?
    private var startedAt: Date?
    private var sourceLabel = "會議"

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
        startTimer()
        if indicator == nil { indicator = MeetingIndicatorWindowManager(controller: self) }
        indicator?.show()

        // meeting-copilot 即時輔助:copilotEnabled 時把 realtime seam 接成 live pipeline
        // (cue 偵測 → 三層回應 → overlay)。ring buffer 只在 copilotEnabled 時由 service 建立。
        if MeetingCopilotConfigStore.shared.copilotEnabled, let ring = service.copilotRingBuffer {
            MeetingCopilotLiveController.shared.start(
                ring: ring,
                tapChannelCount: service.copilotTapChannelCount,
                appName: sourceLabel)
        }

        logger.notice("Meeting recording started — \(self.sourceLabel, privacy: .public)")
    }

    func stopAndImport() async {
        guard isRecording else { return }
        timer?.invalidate(); timer = nil
        indicator?.hide()
        isRecording = false

        // 先停 copilot live pipeline(轉錄消費者)再收音訊檔。
        MeetingCopilotLiveController.shared.stop()
        guard let url = await service.stop() else {
            // service 已對「零音訊」情境發出帶引導的通知,這裡不重複彈。
            logger.notice("Meeting stop returned no file (empty recording or no session)")
            return
        }
        RecorderImportService.shared.importMeetingFile(url, sourceLabel: sourceLabel)
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
