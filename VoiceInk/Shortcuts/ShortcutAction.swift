import Foundation

enum ShortcutAction: Hashable {
    case primaryRecording
    case secondaryRecording
    case pasteLastTranscription
    case pasteLastEnhancement
    case retryLastTranscription
    case cancelRecorder
    case openHistoryWindow
    case quickAddToDictionary
    case toggleMeetingRecording
    case toggleMeetingCopilotOverlay
    case peekMeetingCopilotOverlay
    case togglePresenterScript
    case toggleCopilotCueExpansion
    case mode(UUID)
    case recorderPanelEscape
    case recorderPanelMode(Int)

    var userDefaultsKey: String {
        "Shortcut_\(storageName)"
    }

    var isStored: Bool {
        switch self {
        case .recorderPanelEscape, .recorderPanelMode:
            return false
        default:
            return true
        }
    }

    var storageName: String {
        switch self {
        case .primaryRecording:
            return "primaryRecording"
        case .secondaryRecording:
            return "secondaryRecording"
        case .pasteLastTranscription:
            return "pasteLastTranscription"
        case .pasteLastEnhancement:
            return "pasteLastEnhancement"
        case .retryLastTranscription:
            return "retryLastTranscription"
        case .cancelRecorder:
            return "cancelRecorder"
        case .openHistoryWindow:
            return "openHistoryWindow"
        case .quickAddToDictionary:
            return "quickAddToDictionary"
        case .toggleMeetingRecording:
            return "toggleMeetingRecording"
        case .toggleMeetingCopilotOverlay:
            return "toggleMeetingCopilotOverlay"
        case .peekMeetingCopilotOverlay:
            return "peekMeetingCopilotOverlay"
        case .togglePresenterScript:
            return "togglePresenterScript"
        case .toggleCopilotCueExpansion:
            return "toggleCopilotCueExpansion"
        case .mode(let id):
            return "mode_\(id.uuidString)"
        case .recorderPanelEscape:
            return "recorderPanelEscape"
        case .recorderPanelMode(let index):
            return "recorderPanelMode_\(index)"
        }
    }

    var displayName: String {
        switch self {
        case .primaryRecording:
            return String(localized: "Primary Shortcut")
        case .secondaryRecording:
            return String(localized: "Secondary Shortcut")
        case .pasteLastTranscription:
            return String(localized: "Paste Last Transcription")
        case .pasteLastEnhancement:
            return String(localized: "Paste Last Enhanced Transcription")
        case .retryLastTranscription:
            return String(localized: "Retry Last Transcription")
        case .cancelRecorder:
            return String(localized: "Cancel Recording")
        case .openHistoryWindow:
            return String(localized: "Open History Window")
        case .quickAddToDictionary:
            return String(localized: "Quick Add to Dictionary")
        case .toggleMeetingRecording:
            return String(localized: "Toggle Meeting Recording")
        case .toggleMeetingCopilotOverlay:
            return String(localized: "Toggle Meeting Copilot Overlay")
        case .peekMeetingCopilotOverlay:
            return String(localized: "Peek Meeting Copilot Overlay")
        case .togglePresenterScript:
            return String(localized: "Toggle Presenter Script")
        case .toggleCopilotCueExpansion:
            return String(localized: "展開/收合分析")
        case .mode(let id):
            if let config = ModeManager.shared.getConfiguration(with: id) {
                return String(format: String(localized: "%@ Mode"), config.name)
            }

            if let template = StarterModeCatalog.templates.first(where: { $0.id == id }) {
                return String(format: String(localized: "%@ Mode"), template.name)
            }

            return String(localized: "Mode")
        case .recorderPanelEscape:
            return String(localized: "Recorder Cancel")
        case .recorderPanelMode(let index):
            return String(format: String(localized: "Select Mode %@"), Self.displayNumber(forRecorderPanelIndex: index))
        }
    }

    static let globalUtilityActions: [Self] = [
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .openHistoryWindow,
        .quickAddToDictionary,
        .toggleMeetingRecording,
        .toggleMeetingCopilotOverlay,
        .peekMeetingCopilotOverlay,
        .togglePresenterScript,
        .toggleCopilotCueExpansion
    ]

    static let recorderPanelStoredActions: [Self] = [
        .cancelRecorder
    ]

    static let legacyKeyboardShortcutActions: [Self] = [
        .primaryRecording,
        .secondaryRecording,
        .pasteLastTranscription,
        .pasteLastEnhancement,
        .retryLastTranscription,
        .cancelRecorder,
        .openHistoryWindow,
        .quickAddToDictionary,
        // FR-32:自 build 227 起 .toggleMeetingRecording 不在此清單 → 其鍵逃過
        // ShortcutValidator 的衝突偵測(雙向隱形)。加入修復;三者皆為新動作,
        // legacyKeyboardShortcutsNames 回 []、migrate no-op。
        .toggleMeetingRecording,
        .toggleMeetingCopilotOverlay,
        .peekMeetingCopilotOverlay,
        .togglePresenterScript,
        // 同理:新動作也要進這裡,否則它的鍵對 ShortcutValidator 的衝突偵測雙向隱形。
        .toggleCopilotCueExpansion
    ]

    private static func displayNumber(forRecorderPanelIndex index: Int) -> String {
        index == 9 ? "10" : "\(index + 1)"
    }
}
