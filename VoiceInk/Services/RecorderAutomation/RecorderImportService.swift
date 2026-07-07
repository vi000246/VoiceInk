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
    /// Devices whose files are being copied into app storage BEFORE they hit the transcription
    /// queue. Copying a large recording takes tens of seconds, during which no queue item exists
    /// yet — the UI watches this so the user sees "準備中" instead of a frozen-looking blank gap.
    @Published private(set) var preparingDeviceIds: Set<UUID> = []

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
    /// - `minimumStableAge`: when > 0 (watched-folder path), skip files modified within that window —
    ///   they may still be copying in — and report them as `deferredCount` so the caller can re-check.
    ///   0 (mount path) keeps the original behaviour: device files are already complete on mount.
    func newImportableFiles(in folder: URL, context: ModelContext,
                            minimumStableAge: TimeInterval = 0) async -> (candidates: [ImportCandidate], deferredCount: Int) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        var out: [ImportCandidate] = []
        var deferred = 0
        let now = Date()
        // Skip tiny stray recordings on auto-import (user-configurable floor, default 500 KB).
        let minSizeBytes = RecorderConfigStore.shared.recorderMinImportSizeBytes
        for url in urls where SupportedMedia.isSupported(url: url) {
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = rv?.fileSize ?? 0
            if minSizeBytes > 0, size > 0, size < minSizeBytes { continue }
            // Cheap (name+size) pre-skip on ALL paths: an already-imported file is skipped WITHOUT
            // hashing. Content-hash confirm still runs for new files, off the main actor (below).
            if ImportLedger.shared.hasQuickMatch(fileName: url.lastPathComponent, byteSize: size, in: context) { continue }
            if minimumStableAge > 0, let mod = rv?.contentModificationDate, now.timeIntervalSince(mod) < minimumStableAge {
                deferred += 1; continue
            }
            guard let fp = try? await Self.fingerprintOffMain(url) else { continue }
            if inFlight.contains(fp) { continue }
            if ImportLedger.shared.isImported(fingerprint: fp, in: context) { continue }
            out.append(ImportCandidate(url: url, fingerprint: fp, fileName: url.lastPathComponent, byteSize: size))
        }
        return (out, deferred)
    }

    /// Content-hash on a background thread. Hashing a new multi-hundred-MB recording on the main
    /// actor froze the UI on device insert — the quick-match pre-skip only spares files that are
    /// ALREADY in the ledger, so every genuinely new file used to pay this cost on main.
    nonisolated private static func fingerprintOffMain(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try ImportLedger.contentFingerprint(for: url)
        }.value
    }

    /// Filter out candidates shorter than the configured auto-import length floor. Files whose
    /// duration can't be read (probe returns 0) are kept — a failed probe must never silently drop a
    /// recording. Returns the input unchanged when the filter is off (threshold 0).
    private func candidatesPassingMinDuration(_ candidates: [ImportCandidate]) async -> [ImportCandidate] {
        let minSeconds = RecorderConfigStore.shared.recorderMinImportDurationSeconds
        guard minSeconds > 0 else { return candidates }
        var kept: [ImportCandidate] = []
        for c in candidates {
            let seconds = await AudioFileMetadata.duration(for: c.url)
            if seconds > 0, seconds < Double(minSeconds) { continue }   // too short → skip auto-import
            kept.append(c)
        }
        return kept
    }

    /// Import any new files sitting in the device's source folder. Triggered by the mount monitor
    /// (`.volume`) or the folder watcher (`.folder`). Copies into app storage, never mutates the source
    /// until a successful delete-after-import.
    func importNewFiles(device: RecorderDevice) {
        guard let modelContext, let engine else { logger.error("Import service not configured"); return }
        guard let folder = resolveSourceFolder(device) else {
            NotificationManager.shared.showNotification(title: "錄音來源資料夾無法存取，請重新授權", type: .warning, duration: 4)
            return
        }
        // Offload the file copies (see reprocess): keep @MainActor state on main, copy off it, and
        // hold the security scope across the whole async span.
        Task { @MainActor in
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

            // Watched folders may hold files mid-copy; give them a few seconds to settle, then re-check.
            let stableAge: TimeInterval = device.kind == .folder ? 4 : 0
            let (sizeFiltered, deferred) = await newImportableFiles(in: folder, context: modelContext, minimumStableAge: stableAge)
            if deferred > 0 { RecorderFolderWatcher.shared.scheduleRecheck(deviceId: device.id) }
            guard !sizeFiltered.isEmpty else { return }

            // Length floor, OR-combined with the size floor already applied in newImportableFiles:
            // skip recordings shorter than the configured minimum. Probing needs an AVAsset load, so
            // it runs only for the files that already passed the (cheap) size test.
            let candidates = await candidatesPassingMinDuration(sizeFiltered)
            guard !candidates.isEmpty else { return }

            // Signal "準備中" while the (possibly large) files copy into app storage — the queue
            // item, and thus the progress bar, only appears once each copy finishes.
            preparingDeviceIds.insert(device.id)
            defer { preparingDeviceIds.remove(device.id) }

            var enqueued: [URL] = []
            for c in candidates {
                if inFlight.contains(c.fingerprint) { continue }
                inFlight.insert(c.fingerprint)   // reserve before the async copy (closes the await gap)
                guard let copied = await copyIntoAppStorage(c.url) else { inFlight.remove(c.fingerprint); continue }
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
    }

    /// Manually (re)process the given device files, regardless of prior import status.
    /// - Never-processed files import normally (real content fingerprint → future dedup works).
    /// - Already-processed files are duplicated as a NEW record: a synthetic unique fingerprint
    ///   bypasses content dedup, and the ledger/display name gets a serial suffix `name (2).ext`.
    /// Copies only into app storage (never writes to the device) and never deletes the original,
    /// even if the device opts into delete-after-import.
    func reprocess(fileNames: Set<String>, device: RecorderDevice) {
        guard let modelContext, let engine else { logger.error("Import service not configured"); return }
        guard !fileNames.isEmpty else { return }
        guard let folder = resolveSourceFolder(device) else {
            NotificationManager.shared.showNotification(title: "錄音筆來源資料夾無法存取，請重新授權", type: .warning, duration: 4)
            return
        }
        // Copy the (possibly large) recordings off the main run loop so the UI doesn't freeze while
        // reprocess is kicked off. All SwiftData / @MainActor state stays on main; only the file copy
        // is offloaded. Security scope is held for the whole async span (it is process-wide).
        Task { @MainActor in
            let accessing = folder.startAccessingSecurityScopedResource()
            defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

            let urls = ((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? [])
                .filter { SupportedMedia.isSupported(url: $0) && fileNames.contains($0.lastPathComponent) }
            guard !urls.isEmpty else { return }

            // Immediate feedback: copying a large recording into app storage takes tens of seconds
            // before it reaches the queue, so signal "準備中" up front instead of a blank gap.
            preparingDeviceIds.insert(device.id)
            defer { preparingDeviceIds.remove(device.id) }
            NotificationManager.shared.showNotification(title: "正在準備 \(urls.count) 個檔案…", type: .info, duration: 3)

            var enqueued = 0
            for url in urls {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let alreadyProcessed = ImportLedger.shared.hasQuickMatch(
                    fileName: url.lastPathComponent, byteSize: size, in: modelContext)

                let fingerprint: String
                let displayName: String
                if alreadyProcessed {
                    fingerprint = "reprocess-\(UUID().uuidString)"   // unique → bypass content dedup
                    displayName = serialNumberedName(base: url.lastPathComponent, in: modelContext)
                } else if let real = try? await Self.fingerprintOffMain(url) {
                    fingerprint = real
                    displayName = url.lastPathComponent
                } else { continue }

                if inFlight.contains(fingerprint) { continue }
                inFlight.insert(fingerprint)   // reserve before the async copy (closes the await gap)
                guard let copied = await copyIntoAppStorage(url) else { inFlight.remove(fingerprint); continue }
                // NOTE: deliberately not setting originalURLs → reprocess never deletes the device original.
                pendingMeta[fingerprint] = (displayName, size)
                AudioTranscriptionManager.shared.addToQueue(urls: [copied],
                    origin: .recorderImport(deviceId: device.id, fingerprint: fingerprint))
                enqueued += 1
            }
            guard enqueued > 0 else { return }
            let recorderMode = RecorderTranscriptionConfig.current()
            AudioTranscriptionManager.shared.startProcessing(modelContext: modelContext, engine: engine, mode: recorderMode)
            NotificationManager.shared.showNotification(title: "重新處理 \(enqueued) 個檔案", type: .info, duration: 3)
        }
    }

    /// Next unused `stem (n).ext` (n≥2) so a reprocessed duplicate doesn't collide in the ledger.
    private func serialNumberedName(base: String, in context: ModelContext) -> String {
        let ns = base as NSString
        let ext = ns.pathExtension
        let stem = ns.deletingPathExtension
        func candidate(_ i: Int) -> String { ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)" }
        var n = 2
        while ImportLedger.shared.hasFileName(candidate(n), in: context) { n += 1 }
        return candidate(n)
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

    // MARK: - Meeting capture import

    struct StagedMeetingFile { let stagedURL: URL; let fingerprint: String; let displayName: String; let byteSize: Int }

    /// 可測純步驟：fingerprint＋複製進 RecorderImports staging。不 enqueue、不動 inFlight。
    func stageMeetingFile(_ src: URL) async throws -> StagedMeetingFile {
        let fp = try await Self.fingerprintOffMain(src)
        let size = (try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard let copied = await copyIntoAppStorage(src) else { throw CocoaError(.fileWriteUnknown) }
        return StagedMeetingFile(stagedURL: copied, fingerprint: fp,
                                 displayName: src.lastPathComponent, byteSize: size)
    }

    /// 會議錄製完成 → 走既有管線。與 importNewFiles 對稱：inFlight 護欄、pendingMeta 供 ledger、
    /// Recorder Mode 轉錄、開始/失敗通知。成功 enqueue 後刪除 capture 暫存原檔（app 內部檔案，非使用者資料）。
    func importMeetingFile(_ src: URL, sourceLabel: String) {
        guard let modelContext, let engine else { logger.error("Import service not configured"); return }
        Task { @MainActor in
            guard let staged = try? await stageMeetingFile(src) else {
                NotificationManager.shared.showNotification(title: "會議錄音匯入失敗", type: .error, duration: 5)
                return
            }
            // Duplicate cases deliberately do NOT delete `src` (capture temp file kept for
            // inspection) — but still note it, mirroring finalizeImport's logger.notice style.
            if inFlight.contains(staged.fingerprint) {
                logger.notice("Meeting capture already in-flight, skipped: \(staged.displayName, privacy: .public)")
                return
            }
            if ImportLedger.shared.isImported(fingerprint: staged.fingerprint, in: modelContext) {
                logger.notice("Meeting capture already imported, skipped: \(staged.displayName, privacy: .public)")
                return
            }
            inFlight.insert(staged.fingerprint)
            pendingMeta[staged.fingerprint] = (staged.displayName, staged.byteSize)
            AudioTranscriptionManager.shared.addToQueue(urls: [staged.stagedURL],
                origin: .meetingCapture(fingerprint: staged.fingerprint, sourceLabel: sourceLabel))
            try? FileManager.default.removeItem(at: src)
            NotificationManager.shared.showNotification(title: "會議錄音已匯入，處理中…", type: .info, duration: 3)
            AudioTranscriptionManager.shared.startProcessing(
                modelContext: modelContext, engine: engine, mode: RecorderTranscriptionConfig.current())
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

    /// Probe the play length (seconds) of every supported file in the device's source folder, keyed
    /// by file name. Each probe is an async AVAsset load, so this is called off the initial (instant)
    /// file-list scan to fill in durations progressively. Files whose length can't be read are omitted.
    func deviceFileDurations(for device: RecorderDevice) async -> [String: Double] {
        guard let folder = resolveSourceFolder(device) else { return [:] }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [:] }
        var map: [String: Double] = [:]
        for url in urls where SupportedMedia.isSupported(url: url) {
            let seconds = await AudioFileMetadata.duration(for: url)
            if seconds > 0 { map[url.lastPathComponent] = seconds }
        }
        return map
    }

    // MARK: - Device capacity & cleanup

    /// Total / available bytes of the volume backing a device's source folder. nil if unreachable.
    struct DeviceCapacity {
        let totalBytes: Int64
        let availableBytes: Int64
        var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    func deviceCapacity(for device: RecorderDevice) -> DeviceCapacity? {
        guard let folder = resolveSourceFolder(device) else { return nil }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: folder.path),
              let rv = try? folder.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = rv.volumeTotalCapacity, let avail = rv.volumeAvailableCapacity else { return nil }
        return DeviceCapacity(totalBytes: Int64(total), availableBytes: Int64(avail))
    }

    /// A source-folder audio file considered for cleanup. `durationSeconds` is nil when not probed
    /// (the caller only probes when a length criterion is active) or when the probe failed.
    struct CleanupFile: Identifiable {
        let id = UUID()
        let fileName: String
        let byteSize: Int
        let modified: Date?
        let durationSeconds: Double?
    }

    /// Enumerate the device's supported audio files for cleanup. Probes each file's duration only
    /// when `probeDuration` is true (a length criterion is active), since that needs an AVAsset load.
    /// Returns nil when the device is unreachable.
    func cleanupScan(for device: RecorderDevice, probeDuration: Bool) async -> [CleanupFile]? {
        guard let folder = resolveSourceFolder(device) else { return nil }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: folder.path),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return nil }
        var out: [CleanupFile] = []
        for url in urls where SupportedMedia.isSupported(url: url) {
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let duration = probeDuration ? await AudioFileMetadata.duration(for: url) : nil
            out.append(CleanupFile(fileName: url.lastPathComponent, byteSize: rv?.fileSize ?? 0,
                                   modified: rv?.contentModificationDate,
                                   durationSeconds: (duration ?? 0) > 0 ? duration : nil))
        }
        return out.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
    }

    /// Delete the named files from the device's source folder. Returns how many were removed and the
    /// total bytes freed. Only matches by exact file name within the resolved source folder.
    @discardableResult
    func deleteDeviceFiles(fileNames: Set<String>, on device: RecorderDevice) -> (deleted: Int, freedBytes: Int64) {
        guard !fileNames.isEmpty, let folder = resolveSourceFolder(device) else { return (0, 0) }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return (0, 0) }
        var deleted = 0
        var freed: Int64 = 0
        for url in urls where fileNames.contains(url.lastPathComponent) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            do {
                try FileManager.default.removeItem(at: url)
                deleted += 1; freed += Int64(size)
            } catch {
                logger.error("Cleanup delete failed for \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            }
        }
        logger.notice("Cleanup removed \(deleted) file(s), freed \(freed) bytes from device \(device.displayName, privacy: .public)")
        return (deleted, freed)
    }

    /// Copy `src` into app storage, running the (potentially large) file copy off the main actor so
    /// the UI never freezes while a recording is copied during import/reprocess. Returns the
    /// destination URL, or nil on failure.
    private func copyIntoAppStorage(_ src: URL) async -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk").appendingPathComponent("RecorderImports")
        let dst = dir.appendingPathComponent("\(UUID().uuidString)-\(src.lastPathComponent)")
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: src, to: dst)
            }.value
            return dst
        } catch {
            logger.error("Copy failed: \(error, privacy: .public)")
            return nil
        }
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
