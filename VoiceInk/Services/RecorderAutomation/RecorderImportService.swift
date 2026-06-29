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
            enqueued.append(copied)
            AudioTranscriptionManager.shared.addToQueue(urls: [copied],
                origin: .recorderImport(deviceId: device.id, fingerprint: c.fingerprint))
        }
        guard !enqueued.isEmpty else { return }
        NotificationManager.shared.showNotification(title: "匯入 \(enqueued.count) 個新檔", type: .info, duration: 3)
        let mode = ModeManager.shared.activeConfiguration ?? ModeManager.shared.configurations.first
        if let mode {
            AudioTranscriptionManager.shared.startProcessing(modelContext: modelContext, engine: engine, mode: mode)
        }
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
        ImportLedger.shared.record(fingerprint: fp, fileName: "", byteSize: 0,
                                   sourceDeviceId: t.recorderSourceDeviceId, transcriptionId: t.id, in: ctx)
        NotificationCenter.default.post(name: .recorderImportCompleted, object: t)
    }
}
