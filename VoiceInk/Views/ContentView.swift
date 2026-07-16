import SwiftUI
import OSLog

enum ViewType: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case aiUsage = "AI Usage"
    case modes = "Modes"
    case prompts = "Prompts"
    case models = "AI Models"
    case transcribeAudio = "Transcribe Audio"
    case history = "History"
    case voiceSettings = "Voice Settings"
    case audio = "Audio"
    case dictionary = "Dictionary"
    case recorders = "Recorders"
    case recorderMode = "Recorder Mode"
    case categories = "Categories"
    case recorderLog = "Recorder Log"
    case systemTemplate = "System Template"
    case templateGuide = "Template Guide"
    case askAI = "Ask AI"
    case askAITemplates = "Ask AI Templates"
    case meetingCopilot = "Meeting Copilot"
    case meetingCopilotSettings = "Meeting Copilot Settings"
    case settings = "Settings"
    case license = "VoiceInk Pro"

    var id: String { rawValue }
}

struct ContentView: View {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ContentView")
    private static let detailBackgroundTintOpacity = 0.50
    @State private var selectedView: ViewType = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            AppSidebar(selectedView: $selectedView)

            detailContent
        }
        .frame(minWidth: AppWindowLayout.minimumWidth, maxWidth: .infinity)
        .frame(minHeight: AppWindowLayout.minimumHeight, maxHeight: .infinity)
        .onAppear {
            logger.notice("ContentView appeared")
        }
        .onDisappear {
            logger.notice("ContentView disappeared")
        }
        .onReceive(AppNavigator.shared.$pendingDestination) { destination in
            guard let destination else { return }
            logger.notice("navigate to \(destination.rawValue, privacy: .public)")
            selectedView = destination
            // Consume asynchronously: mutating the publisher inside its own emission would
            // re-enter, and a consumed value must not replay on the next window re-open.
            DispatchQueue.main.async { AppNavigator.shared.consumePendingDestination() }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        detailView(for: selectedView)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(detailBackground)
    }

    private var detailBackground: some View {
        ZStack {
            VisualEffectView(
                material: .sidebar,
                blendingMode: .behindWindow
            )

            AppTheme.Surface.window
                .opacity(Self.detailBackgroundTintOpacity)
        }
        .ignoresSafeArea(.container, edges: .top)
    }
    
    @ViewBuilder
    private func detailView(for viewType: ViewType) -> some View {
        switch viewType {
        case .dashboard:
            DashboardView()
        case .aiUsage:
            AIUsageDashboardView()
        case .models:
            ModelManagementView()
        case .transcribeAudio:
            AudioTranscribeView()
        case .history:
            VoiceLibraryView()
        case .voiceSettings:
            VoiceSettingsView()
        case .audio:
            AudioSetupView()
        case .dictionary:
            DictionarySettingsView()
        case .modes:
            ModeView()
        case .prompts:
            PromptsManagementView()
        case .recorders:
            RecordersSettingsView()
        case .recorderMode:
            RecorderModeSettingsView()
        case .categories:
            CategoriesSettingsView()
        case .recorderLog:
            RecorderHistoryView()
        case .systemTemplate:
            SystemTemplateSettingsView()
        case .templateGuide:
            TemplateWritingGuideView()
        case .askAI:
            AskAIView()
        case .askAITemplates:
            AskAITemplatesView()
        case .meetingCopilot:
            MeetingCopilotPageView()
        case .meetingCopilotSettings:
            MeetingCopilotSettingsView()
        case .settings:
            SettingsView()
        case .license:
            LicenseManagementView()
        }
    }
}
