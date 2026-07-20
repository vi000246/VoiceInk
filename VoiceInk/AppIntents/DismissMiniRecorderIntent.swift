import AppIntents
import Foundation
import AppKit

struct DismissMiniRecorderIntent: AppIntent {
    static var title: LocalizedStringResource = "Dismiss Muninn Recorder"
    static var description = IntentDescription("Dismiss the Muninn recorder and cancel any active recording.")
    
    static var openAppWhenRun: Bool = false
    
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        RecorderUIManager.current?.requestDismissOrCancel()

        let dialog: IntentDialog = "Muninn recorder dismissed"
        return .result(dialog: dialog)
    }
}
