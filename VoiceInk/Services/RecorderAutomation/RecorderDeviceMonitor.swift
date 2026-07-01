import Foundation
import AppKit
import os

@MainActor
final class RecorderDeviceMonitor: NSObject {
    static let shared = RecorderDeviceMonitor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private var started = false
    private override init() { super.init() }

    func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumeDidMount(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        // Catch a device already mounted at launch.
        for url in (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []) {
            evaluate(volumeURL: url)
        }
        logger.notice("RecorderDeviceMonitor started")
    }

    @objc private func volumeDidMount(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        evaluate(volumeURL: url)
    }

    private func evaluate(volumeURL: URL) {
        let name = (try? volumeURL.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? volumeURL.lastPathComponent
        guard let device = RecorderConfigStore.shared.device(forVolumeName: name) else { return }
        logger.notice("Recorder mounted: \(name, privacy: .public)")
        RecorderImportService.shared.importNewFiles(device: device)
    }
}
