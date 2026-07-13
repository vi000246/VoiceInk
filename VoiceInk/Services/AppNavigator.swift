import Foundation
import Combine

/// Typed navigation requests for the main window's sidebar. Replaces the stringly-typed
/// `.navigateToDestination` notification (`"Transcribe Audio"` etc.) whose receiver was
/// invisible to the compiler. `@Published` replays the latest request on subscription, so a
/// navigation issued before ContentView exists (cold start, window re-open) still lands —
/// the old notification needed asyncAfter delays to paper over that race.
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    /// The not-yet-applied destination. ContentView applies it, then consumes it so a later
    /// re-subscription (window reopen) doesn't replay a stale navigation.
    @Published private(set) var pendingDestination: ViewType?

    /// Row-level focus target consumed by the Recording Library page (Ask AI citations point here).
    /// Section-level nav has no row concept, so this rides alongside `pendingDestination`.
    @Published private(set) var pendingFocusTranscriptionId: UUID?

    /// Consumed by Ask AI: scope the next conversation to a single recording (管理頁「Ask AI」按鈕）。
    @Published private(set) var pendingAskTranscriptionId: UUID?

    /// Consumed by 會議copilot覆盤頁:導頁後直接打開這個 session 的詳情(錄音管理「覆盤」按鈕)。
    @Published private(set) var pendingMeetingSessionId: UUID?

    private init() {}

    /// 開啟會議copilot覆盤頁並展開指定 session 的詳情。
    func openMeetingReview(sessionId: UUID) {
        if Thread.isMainThread {
            pendingMeetingSessionId = sessionId
            pendingDestination = .meetingCopilot
        } else {
            DispatchQueue.main.async {
                self.pendingMeetingSessionId = sessionId
                self.pendingDestination = .meetingCopilot
            }
        }
    }

    func consumePendingMeetingSession() { pendingMeetingSessionId = nil }

    /// Open Ask AI scoped to a single recording.
    func askAI(about id: UUID) {
        if Thread.isMainThread {
            pendingAskTranscriptionId = id
            pendingDestination = .askAI
        } else {
            DispatchQueue.main.async {
                self.pendingAskTranscriptionId = id
                self.pendingDestination = .askAI
            }
        }
    }

    func consumePendingAsk() { pendingAskTranscriptionId = nil }

    /// Navigate to a page AND focus a specific transcription row once it renders.
    func navigate(to destination: ViewType, focusTranscription id: UUID) {
        if Thread.isMainThread {
            pendingFocusTranscriptionId = id
            pendingDestination = destination
        } else {
            DispatchQueue.main.async {
                self.pendingFocusTranscriptionId = id
                self.pendingDestination = destination
            }
        }
    }

    func consumePendingFocus() { pendingFocusTranscriptionId = nil }

    /// Callable from any thread, like the notification it replaces.
    func navigate(to destination: ViewType) {
        if Thread.isMainThread {
            pendingDestination = destination
        } else {
            DispatchQueue.main.async { self.pendingDestination = destination }
        }
    }

    func consumePendingDestination() {
        pendingDestination = nil
    }
}
