import Cocoa
import SwiftUI
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    weak var menuBarManager: MenuBarManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager?.applyActivationPolicy()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let menuBarManager = menuBarManager, !menuBarManager.isMenuBarOnly {
            if WindowManager.shared.showMainWindow() != nil {
                return false
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    // Stash URL when app cold-starts to avoid spawning a new window/tab
    var pendingOpenFileURL: URL?
    
    func application(_ application: NSApplication, open urls: [URL]) {
        if let commandURL = urls.first(where: { $0.scheme?.lowercased() == "voiceink" }) {
            handleCommandURL(commandURL)
            return
        }

        guard let url = urls.first(where: { SupportedMedia.isSupported(url: $0) }) else {
            return
        }
        
        NSApplication.shared.activate(ignoringOtherApps: true)
        
        if WindowManager.shared.currentMainWindow() == nil {
            // Cold start: do NOT create a window here to avoid extra window/tab.
            // Defer to SwiftUI’s WindowGroup-created ContentView and let it process this later.
            pendingOpenFileURL = url
        } else {
            // Running: focus current window and route in-place to Transcribe Audio
            menuBarManager?.focusMainWindow()
            AppNavigator.shared.navigate(to: .transcribeAudio)
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .openFileForTranscription, object: nil, userInfo: ["url": url])
            }
        }
    }

    /// voiceink://record[?mode=<uuid|name>] — external trigger (Raycast, scripts).
    /// Deliberately does not activate the app: recording output should land in the
    /// app that is frontmost when the URL fires.
    private func handleCommandURL(_ url: URL) {
        guard url.host?.lowercased() == "record" else { return }

        var modeId: UUID?
        let modeParam = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "mode" })?
            .value

        if let modeParam, !modeParam.isEmpty {
            let modes = ModeManager.shared.configurations.filter(\.isEnabled)
            if let uuid = UUID(uuidString: modeParam) {
                modeId = modes.first(where: { $0.id == uuid })?.id
            } else {
                modeId = modes.first(where: {
                    $0.name.compare(modeParam, options: [.caseInsensitive]) == .orderedSame
                })?.id
            }

            guard modeId != nil else {
                Task { @MainActor in
                    NotificationManager.shared.showNotification(
                        title: String(localized: "Mode \"\(modeParam)\" not found"),
                        type: .error
                    )
                }
                return
            }
        }

        let resolvedModeId = modeId
        Task { @MainActor in
            RecorderUIManager.current?.requestTogglePanel(modeId: resolvedModeId)
        }
    }
}
