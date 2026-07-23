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
    private var watchdogTask: Task<Void, Never>?

    // MARK: - 忘了關的保險

    /// 錄滿這麼久 → 跳確認視窗問要不要繼續。按「繼續」後重新計時,再滿 2 小時會再問一次。
    static let continuePromptInterval: TimeInterval = 2 * 60 * 60
    /// 確認視窗沒人回應這麼久 → 自動停止並匯入(人不在位子上,不該繼續錄下去)。
    static let unattendedStopTimeout: TimeInterval = 5 * 60

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
        startWatchdog()
        if indicator == nil { indicator = MeetingIndicatorWindowManager(controller: self) }
        indicator?.show()

        // meeting-copilot 即時輔助:copilotEnabled 時把 realtime seam 接成 live pipeline
        // (cue 偵測 → 三層回應 → overlay)。ring buffer 恆由 service 建立,
        // 所以也能在會議中途用 setCopilotEnabled 補開。
        if MeetingCopilotConfigStore.shared.copilotEnabled {
            attachCopilotLive()
        }

        // M14 會議脈絡卡：手動開錄也是「會議開始」訊號（第二個觸發入口）。同步 call-out 立即返回、
        // 生成在背景——絕不拖慢錄音/copilot 啟動；與 M11 偵測共用 gate，同一場會只出一張卡。
        MeetingContextCardService.shared.noteRecordingStarted(appName: app)

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
        watchdogTask?.cancel(); watchdogTask = nil
        indicator?.hide()
        panicSnapshot = nil   // 跨場次不殘留 panic 狀態(否則下一場按 panic 會誤還原上一場)
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

    // MARK: - 緊急隱藏(panic;.panicHideMeetingCopilot 熱鍵)

    /// panic 前各面板的可見/釘住快照(nil = 目前不在 panic 隱藏狀態)。
    private var panicSnapshot: (overlayPinned: Bool, presenterPinned: Bool, pillWasVisible: Bool)?

    /// 一鍵收掉**所有**會議浮動視窗(overlay + 讀稿面板 + 錄音指示 pill);**再按一次原樣還原**。
    ///
    /// 要分享整個螢幕時,`sharingType = .none` 在 macOS 15.4+ 擋不住(誠實邊界),`orderOut` 把視窗
    /// 移出 window server 才是唯一可靠的逃生口(不存在的視窗錄不到)。
    ///
    /// 為什麼做成 toggle-restore 而非單向隱藏:pill 一旦藏掉,現場就沒有停止鈕/copilot 開關可按了
    /// (選單列還在,但慌張時要的是一鍵找回)。所以第一次按 = 快照當下可見狀態並全部收起,
    /// 第二次按 = 依快照把「剛才確實顯示的那些」叫回。只還原 panic 前可見的,不會平白多開東西。
    func togglePanicHide() {
        // FR-84:收 vs 放以**當下實際可見狀態**判斷,不靠 `panicSnapshot != nil`——否則 panic 後又用
        // 獨立熱鍵(toggle overlay / presenter)改了可見性,再按 panic 會反向(把東西叫出來而非收掉)。
        let overlayVisible = CopilotOverlayWindowManager.shared.isVisibleOnScreen
        let presenterVisible = PresenterScriptWindowManager.shared.isVisibleOnScreen
        let pillVisible = indicator?.isVisibleOnScreen == true
        let contextCardVisible = MeetingContextCardWindowManager.shared.isVisibleOnScreen

        if overlayVisible || presenterVisible || pillVisible || contextCardVisible {
            // 任一可見 → 快照當下可見狀態並全部收起。
            panicSnapshot = (
                overlayPinned: CopilotOverlayWindowManager.shared.isPinned,
                presenterPinned: PresenterScriptWindowManager.shared.isPinned,
                pillWasVisible: pillVisible
            )
            CopilotOverlayWindowManager.shared.hideAndUnpin()
            PresenterScriptWindowManager.shared.hideAndUnpin()
            indicator?.hide()
            // M14 脈絡卡一併收掉,但**不入快照**:它是會前一次性提示,「上次討論/我答應過的」
            // 在 panic 還原（分享畫面可能還開著）時自動跳回只會再嚇一次,要看的人自己再開。
            MeetingContextCardWindowManager.shared.hideAndUnpin()
            logger.notice("🫥 panic hide")
        } else if let snap = panicSnapshot {
            // 全不可見 → 依快照把 panic 前確實顯示的那些原樣叫回。
            if snap.overlayPinned { CopilotOverlayWindowManager.shared.showAndPin() }
            if snap.presenterPinned { PresenterScriptWindowManager.shared.showAndPin() }
            if snap.pillWasVisible, isRecording { indicator?.show() }
            panicSnapshot = nil
            logger.notice("🫥 panic restore")
        }
        // 全不可見且無快照 → no-op(沒有東西可收、也沒有可還原的)。
    }

    // MARK: - 忘了關的保險(2 小時確認 → 無人回應自動停止)

    /// 每滿 `continuePromptInterval` 問一次「還要繼續嗎」。按繼續 → 重新計時再問;
    /// 按停止、或 `unattendedStopTimeout` 內沒人理它 → 停止並匯入。
    ///
    /// 為什麼需要:會議錄製沒有時間上限,而 copilot 開著時,對方 app 只要在出聲
    /// (忘了關又剛好在看影片),每一段都會走 cue 抽取 → Tier 1 → 自動深答,
    /// 無人看管地燒 token。
    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.continuePromptInterval))
                guard let self, !Task.isCancelled, self.isRecording else { return }

                let keepRecording = await self.askWhetherToContinue()
                guard self.isRecording else { return }   // 期間使用者自己按了停止

                if !keepRecording {
                    await self.stopAndImport()
                    return
                }
                self.logger.notice("Meeting recording: 使用者確認繼續錄製")
            }
        }
    }

    /// 確認視窗。回傳 true = 繼續錄。
    ///
    /// ⚠️ 這個對話框在**分享螢幕時會被對方看到**(overlay 之外唯一會露臉的 UI)。
    /// 文案刻意不提「會議輔助 / copilot」,只說錄音 —— 但它終究是可見的,這是
    /// 「忘了關會一直燒錢」與「完全隱蔽」之間的取捨,使用者明確選了前者。
    private func askWhetherToContinue() async -> Bool {
        let hours = Int(Self.continuePromptInterval / 3600)
        let minutes = Int(Self.unattendedStopTimeout / 60)

        let alert = NSAlert()
        alert.messageText = "Muninn 錄音仍在進行(已錄 \(elapsedText))"
        alert.informativeText = "已經連續錄製超過 \(hours) 小時。要繼續嗎?\n\(minutes) 分鐘內沒有回應會自動停止並匯入這段錄音。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "繼續錄製")
        alert.addButton(withTitle: "停止並匯入")
        NSApp.activate(ignoringOtherApps: true)

        // `runModal` 跑的是 `.modalPanel` 模式的巢狀 run loop —— 計時器**必須註冊在同一個
        // 模式**才會 fire。用 `Timer.scheduledTimer`(只進 .default)的話,人不在位子上時
        // 這個 alert 會永遠停在螢幕上,「無人回應自動停止」的保險等於不存在。
        let timeout = Timer(timeInterval: Self.unattendedStopTimeout, repeats: false) { _ in
            NSApp.abortModal()
        }
        RunLoop.main.add(timeout, forMode: .modalPanel)
        defer { timeout.invalidate() }

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .abort:   // 計時器打斷 = 沒人回應
            logger.notice("Meeting recording: 2 小時確認視窗無人回應 → 自動停止")
            NotificationManager.shared.showNotification(
                title: "錄音已自動停止(2 小時無回應)", type: .info, duration: 6)
            return false
        default:
            return false
        }
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
