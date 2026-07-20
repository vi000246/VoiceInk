import AppIntents
import Foundation
import AppKit

struct ToggleMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Muninn Recorder"
    static var description = IntentDescription("Start or stop the Muninn recorder for voice transcription.")
    
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        RecorderUIManager.current?.requestTogglePanel()

        let dialog: IntentDialog = "Muninn recorder toggled"
        return .result(dialog: dialog)
    }
}

enum IntentError: Error, LocalizedError {
    case appNotAvailable
    case serviceNotAvailable
    
    var errorDescription: String? {
        switch self {
        case .appNotAvailable:
            return String(localized: "Muninn app is not available")
        case .serviceNotAvailable:
            return String(localized: "Muninn recording service is not available")
        }
    }
}
