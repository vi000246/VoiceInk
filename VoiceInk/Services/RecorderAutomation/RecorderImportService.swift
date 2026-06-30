import Foundation
import SwiftData
import os

struct ImportCandidate { let url: URL; let fingerprint: String; let fileName: String; let byteSize: Int }

@MainActor
final class RecorderImportService: NSObject, ObservableObject {
    static let shared = RecorderImportService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private var inFlight = Set<String>()           // fingerprints enqueued this session
    private var originalURLs: [String: URL] = [:]  // fingerprint → original on-device file (for delete-after-import)
    private var pendingMeta: [String: (fileName: String, byteSize: Int)] = [:]  // fingerprint → ledger display meta
    private weak var engine: VoiceInkEngine?
    private var modelContext: ModelContext?

    private override init() {
        super.init()
        // Record ledger entry once a recorder transcription succeeds.
        NotificationCenter.default.addObserver(self, selector: #selector(onTranscriptionCreated(_:)),
                                               name: .transcriptionCreated, object: nil)
    }

    func configure(engine: VoiceInkEngine, modelContext: ModelContext) {
        self.engine = engine; self.modelContext = modelContext
    }

    /// Pure decision: supported + not-yet-imported (ledger) + not in-flight.
    func newImportableFiles(in folder: URL, context: ModelContext) -> [ImportCandidate] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        var out: [ImportCandidate] = []
        for url in urls where SupportedMedia.isSupported(url: url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard let fp = try? ImportLedger.shared.contentFingerprint(for: url) else { continue }
            if inFlight.contains(fp) { continue }
            if ImportLedger.shared.isImported(fingerprint: fp, in: context) { continue }
            out.append(ImportCandidate(url: url, fingerprint: fp, fileName: url.lastPathComponent, byteSize: size))
        }
        return out
    }

    /// Triggered by the monitor when a configured device mounts.
    func handleMount(device: RecorderDevice) {
        guard let modelContext, let engine else { logger.error("Import service not configured"); return }
        guard let folder = resolveSourceFolder(device) else {
            NotificationManager.shared.showNotification(title: "錄音筆來源資料夾無法存取，請重新授權", type: .warning, duration: 4)
            return
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let candidates = newImportableFiles(in: folder, context: modelContext)
        guard !candidates.isEmpty else { return }

        var enqueued: [URL] = []
        for c in candidates {
            guard let copied = copyIntoAppStorage(c.url) else { continue }
            inFlight.insert(c.fingerprint)
            originalURLs[c.fingerprint] = c.url
            pendingMeta[c.fingerprint] = (c.fileName, c.byteSize)
            enqueued.append(copied)
            AudioTranscriptionManager.shared.addToQueue(urls: [copied],
                origin: .recorderImport(deviceId: device.id, fingerprint: c.fingerprint))
        }
        guard !enqueued.isEmpty else { return }
        NotificationManager.shared.showNotification(title: "匯入 \(enqueued.count) 個新檔", type: .info, duration: 3)
        // Recorder transcription uses Recorder Mode (its own model), NOT the active voice Mode.
        let recorderMode = RecorderTranscriptionConfig.current()
        AudioTranscriptionManager.shared.startProcessing(modelContext: modelContext, engine: engine, mode: recorderMode)
    }

    /// Called by the post-processor once an item finishes. Deletes the on-device original only when
    /// the device opts into `deleteAfterImport` AND every stage (import + transcribe + export) succeeded.
    func finalizeImport(fingerprint: String, device: RecorderDevice, exported: Bool) {
        defer { originalURLs[fingerprint] = nil }
        guard device.deleteAfterImport, exported, let original = originalURLs[fingerprint] else { return }
        do {
            try FileManager.default.removeItem(at: original)
            logger.notice("Deleted on-device original after successful import: \(original.lastPathComponent, privacy: .public)")
        } catch {
            logger.error("Delete-after-import failed: \(error, privacy: .public)")
        }
    }

    private func resolveSourceFolder(_ device: RecorderDevice) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: device.sourceFolderBookmark,
                        options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    /// True if the device's source folder is currently reachable (device plugged in / bookmark valid).
    func isDeviceConnected(_ device: RecorderDevice) -> Bool {
        guard let folder = resolveSourceFolder(device) else { return false }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        return FileManager.default.fileExists(atPath: folder.path)
    }

    /// One supported file on the device + whether it's already been imported (ledger quick-match).
    struct DeviceFileStatus: Identifiable {
        let id = UUID()
        let fileName: String
        let modified: Date?
        let byteSize: Int
        let processed: Bool
    }

    /// List the device's supported audio files with processed/unprocessed status. Returns nil when
    /// the device isn't reachable. Uses the cheap (fileName,byteSize) ledger match — no hashing.
    func deviceFiles(for device: RecorderDevice, context: ModelContext) -> [DeviceFileStatus]? {
        guard let folder = resolveSourceFolder(device) else { return nil }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: folder.path),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return nil }
        var out: [DeviceFileStatus] = []
        for url in urls where SupportedMedia.isSupported(url: url) {
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = rv?.fileSize ?? 0
            let processed = ImportLedger.shared.hasQuickMatch(
                fileName: url.lastPathComponent, byteSize: size, in: context)
            out.append(DeviceFileStatus(fileName: url.lastPathComponent,
                                        modified: rv?.contentModificationDate, byteSize: size,
                                        processed: processed))
        }
        return out.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    private func copyIntoAppStorage(_ src: URL) -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk").appendingPathComponent("RecorderImports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("\(UUID().uuidString)-\(src.lastPathComponent)")
        do { try FileManager.default.copyItem(at: src, to: dst); return dst }
        catch { logger.error("Copy failed: \(error, privacy: .public)"); return nil }
    }

    @objc private func onTranscriptionCreated(_ note: Notification) {
        guard let t = note.object as? Transcription, let fp = t.importFingerprint,
              let ctx = modelContext else { return }
        guard !ImportLedger.shared.isImported(fingerprint: fp, in: ctx) else { return }
        let meta = pendingMeta[fp]
        ImportLedger.shared.record(fingerprint: fp, fileName: meta?.fileName ?? "",
                                   byteSize: meta?.byteSize ?? 0,
                                   sourceDeviceId: t.recorderSourceDeviceId, transcriptionId: t.id, in: ctx)
        pendingMeta[fp] = nil
        NotificationCenter.default.post(name: .recorderImportCompleted, object: t)
    }
}
