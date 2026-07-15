import SwiftUI
import LaunchAtLogin

struct MenuBarView: View {
    @EnvironmentObject var engine: VoiceInkEngine
    @EnvironmentObject var recorderUIManager: RecorderUIManager
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject var whisperModelManager: WhisperModelManager
    @EnvironmentObject var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject var menuBarManager: MenuBarManager
    @EnvironmentObject var updaterViewModel: UpdaterViewModel
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @ObservedObject private var modeManager = ModeManager.shared
    @ObservedObject var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var meetingController = MeetingCaptureController.shared
    @ObservedObject private var copilotConfig = MeetingCopilotConfigStore.shared
    @ObservedObject private var overlayManager = CopilotOverlayWindowManager.shared
    @ObservedObject private var presenterManager = PresenterScriptWindowManager.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = false
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    
    var body: some View {
        VStack {
            if hasCompletedOnboardingV2 {
                completedOnboardingMenu
            } else {
                onboardingMenu
            }
        }
    }

    private var onboardingMenu: some View {
        Group {
            Button("Complete Onboarding") {
                menuBarManager.focusMainWindow()
            }

            Divider()

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var completedOnboardingMenu: some View {
        Group {
            Button({
                switch engine.recordingState {
                case .recording, .starting: return "停止錄音"
                case .transcribing, .enhancing, .busy: return "錄音處理中…"
                case .idle: return "開始錄音"
                }
            }()) {
                recorderUIManager.requestTogglePanel()
            }

            Button(meetingController.isRecording
                   ? "停止會議錄製（\(meetingController.elapsedText)）"
                   : "開始會議錄製") {
                Task { await MeetingCaptureController.shared.toggle() }
            }

            // 會議中也能隨時補開/關閉 —— 立即啟停 live pipeline,同時寫回持久設定。
            Toggle("會議即時輔助", isOn: Binding(
                get: { copilotConfig.copilotEnabled },
                set: { MeetingCaptureController.shared.setCopilotEnabled($0) }))

            // 即時翻譯對方的話 —— 與 Live Pill、設定頁共寫同一 flag;可先開好等下場會議。
            Toggle("即時翻譯對方的話", isOn: Binding(
                get: { copilotConfig.liveTranslationEnabled },
                set: { copilotConfig.setLiveTranslationEnabled($0) }))

            // 即時輔助視窗(overlay)—— 熱鍵之外的按鈕入口;pipeline 沒在跑時停用。
            Toggle("即時輔助視窗", isOn: Binding(
                get: { overlayManager.isPinned },
                set: { _ in overlayManager.toggle() }))
                .disabled(!meetingController.copilotActive)

            // 讀稿面板(預設講稿)—— 獨立功能,與會議錄製/即時輔助無關,永遠可開。
            Toggle("讀稿面板", isOn: Binding(
                get: { presenterManager.isPinned },
                set: { _ in presenterManager.toggle() }))

            #if DEBUG
            Button("Replay 會議音檔…（DEBUG）") {
                Task { await MeetingReplayDebugRunner.shared.run() }
            }
            #endif

            Divider()

            Menu {
                ForEach(modeManager.enabledConfigurations) { config in
                    Button {
                        modeManager.setActiveConfiguration(config)
                    } label: {
                        let isActive = modeManager.currentEffectiveConfiguration?.id == config.id
                        Text(isActive ? "\(config.name)  ✓" : config.name)
                    }
                }

                if modeManager.enabledConfigurations.isEmpty {
                    Text("No modes available")
                        .foregroundColor(.secondary)
                }

                Divider()

                Button("Manage Modes") {
                    menuBarManager.openMainWindowAndNavigate(to: .modes)
                }

                Button("Manage Models") {
                    menuBarManager.openMainWindowAndNavigate(to: .models)
                }
            } label: {
                HStack {
                    Image(systemName: "sparkles.square.fill.on.square")
                        .font(.system(size: 11, weight: .medium))
                    let activeMode = modeManager.currentEffectiveConfiguration
                    Text(String(format: String(localized: "Mode: %@"), activeMode?.name ?? String(localized: "None")))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
            }

            Menu {
                ForEach(audioDeviceManager.availableDevices, id: \.id) { device in
                    Button {
                        audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
                    } label: {
                        let isActive = audioDeviceManager.getCurrentDevice() == device.id
                        Text(isActive ? "\(device.name)  ✓" : device.name)
                    }
                }

                if audioDeviceManager.availableDevices.isEmpty {
                    Text("No devices available")
                        .foregroundColor(.secondary)
                }
            } label: {
                HStack {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 11, weight: .medium))
                    Text("Audio Input")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                }
            }

            Divider()

            Button("Retry Last Transcription") {
                LastTranscriptionService.retryLastTranscription(
                    from: engine.modelContext,
                    transcriptionModelManager: transcriptionModelManager,
                    serviceRegistry: engine.serviceRegistry,
                    enhancementService: enhancementService
                )
            }

            Button("Copy Last Transcription") {
                LastTranscriptionService.copyLastTranscription(from: engine.modelContext)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            
            Button("History") {
                menuBarManager.openHistoryWindow()
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            
            Button(menuBarManager.isMenuBarOnly ? "Show Dock Icon" : "Hide Dock Icon") {
                menuBarManager.toggleMenuBarOnly()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Toggle("Launch at Login", isOn: $launchAtLoginEnabled)
                .onChange(of: launchAtLoginEnabled) { oldValue, newValue in
                    LaunchAtLogin.isEnabled = newValue
                }

            Divider()

            Button("Settings") {
                menuBarManager.openMainWindowAndNavigate(to: .settings)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check for Updates") {
                updaterViewModel.checkForUpdates()
            }
            .disabled(!updaterViewModel.canCheckForUpdates)

            Button("Quit VoiceInk") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
