import Foundation
import Darwin
import os

/// Watches ordinary (`.folder`-kind) recorder source folders for new files and triggers an import.
/// Removable devices (`.volume`) use `RecorderDeviceMonitor` (mount events) instead — those folders
/// only exist while the device is plugged in, so there is nothing to watch between mounts.
///
/// Detection uses a per-folder `DispatchSource` on the directory vnode. A large file can appear as a
/// zero-byte entry and keep growing after the vnode fires, so imports are debounced and the import
/// scan skips files still being written (see `RecorderImportService.newImportableFiles(minimumStableAge:)`),
/// re-checking shortly after via `scheduleRecheck`.
@MainActor
final class RecorderFolderWatcher {
    static let shared = RecorderFolderWatcher()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private var started = false
    private var sources: [UUID: DispatchSourceFileSystemObject] = [:]
    private var debounce: [UUID: DispatchWorkItem] = [:]
    private init() {}

    /// Begin watching. Safe to call once the import service is configured (needs engine + context).
    func start() {
        guard !started else { return }
        started = true
        sync()
        logger.notice("RecorderFolderWatcher started")
    }

    /// Rebuild watchers from the current device list. Called on launch and whenever devices change.
    func sync() {
        guard started else { return }
        for src in sources.values { src.cancel() }
        sources.removeAll()
        for work in debounce.values { work.cancel() }
        debounce.removeAll()
        for device in RecorderConfigStore.shared.devices
        where device.kind == .folder && device.autoImportEnabled {
            startWatching(device)
        }
    }

    /// Re-run an import for a folder shortly — used when the last scan skipped files still settling.
    func scheduleRecheck(deviceId: UUID) {
        guard sources[deviceId] != nil else { return }
        scheduleImport(deviceId: deviceId, delay: 5)
    }

    private func startWatching(_ device: RecorderDevice) {
        guard let url = device.resolveSourceFolder() else {
            logger.error("Folder watcher: cannot resolve bookmark for \(device.displayName, privacy: .public)")
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            logger.error("Folder watcher: open() failed for \(url.path, privacy: .public)")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        let id = device.id
        src.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleImport(deviceId: id) }
        }
        src.setCancelHandler {
            close(fd)
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        src.resume()
        sources[id] = src
        logger.notice("Folder watcher watching \(url.lastPathComponent, privacy: .public)")
        // Initial sweep — import anything already sitting in the folder since last run.
        scheduleImport(deviceId: id, delay: 0.5)
    }

    private func scheduleImport(deviceId: UUID, delay: TimeInterval = 2) {
        debounce[deviceId]?.cancel()
        let work = DispatchWorkItem { Task { @MainActor [weak self] in self?.runImport(deviceId) } }
        debounce[deviceId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runImport(_ deviceId: UUID) {
        debounce[deviceId] = nil
        guard let device = RecorderConfigStore.shared.device(byId: deviceId),
              device.kind == .folder, device.autoImportEnabled else { return }
        RecorderImportService.shared.importNewFiles(device: device)
    }
}
