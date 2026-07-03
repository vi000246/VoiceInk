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

    private init() {}

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
