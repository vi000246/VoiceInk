import Foundation
import SwiftData
import OSLog

class TranscriptionAutoCleanupService {
    static let shared = TranscriptionAutoCleanupService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionAutoCleanupService")
    private var modelContext: ModelContext?

    private var appSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
    }

    private var recordingsDirectory: URL {
        appSupportDirectory.appendingPathComponent("Recordings")
    }

    private var recorderImportsDirectory: URL {
        appSupportDirectory.appendingPathComponent("RecorderImports")
    }

    private init() {}

    func startMonitoring(modelContext: ModelContext) {
        self.modelContext = modelContext

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptionCompleted(_:)),
            name: .transcriptionCompleted,
            object: nil
        )

        if UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled) {
            Task { [weak self] in
                guard let self = self, let modelContext = self.modelContext else { return }
                await self.sweepOldTranscriptions(modelContext: modelContext)
                await self.cleanupOrphanAudioFiles(modelContext: modelContext)
            }
        }

        // Always-on, unlike the sweeps above: it only removes files no Transcription references,
        // so no user data is at risk. Without it every recorder import leaks its RecorderImports/
        // staging copy forever, and failed pipeline runs leak transcoded WAVs in Recordings/.
        Task { [weak self] in
            guard let self = self, let modelContext = self.modelContext else { return }
            await self.reclaimUnreferencedAudioFiles(modelContext: modelContext)
        }
    }

    func stopMonitoring() {
        NotificationCenter.default.removeObserver(self, name: .transcriptionCompleted, object: nil)
    }

    func runManualCleanup(modelContext: ModelContext) async {
        await sweepOldTranscriptions(modelContext: modelContext)
    }

    @objc private func handleTranscriptionCompleted(_ notification: Notification) {
        let isEnabled = UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled)
        guard isEnabled else { return }

        let minutes = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes)
        if minutes > 0 {
            if let modelContext = self.modelContext {
                Task { [weak self] in
                    guard let self = self else { return }
                    await self.sweepOldTranscriptions(modelContext: modelContext)
                }
            }
            return
        }

        guard let transcription = notification.object as? Transcription,
              let modelContext = self.modelContext else {
            logger.error("Invalid transcription or missing model context")
            return
        }

        if let urlString = transcription.audioFileURL,
           let url = URL(string: urlString) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                logger.error("Failed to delete audio file: \(error, privacy: .public)")
            }
        }

        modelContext.delete(transcription)

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
        } catch {
            logger.error("Failed to save after transcription deletion: \(error, privacy: .public)")
        }
    }

    private func sweepOldTranscriptions(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled) else {
            return
        }

        let retentionMinutes = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.transcriptionRetentionMinutes)
        let effectiveMinutes = max(retentionMinutes, 0)

        let cutoffDate = Date().addingTimeInterval(TimeInterval(-effectiveMinutes * 60))

        let modelContainer = await MainActor.run { modelContext.container }

        do {
            let backgroundContext = ModelContext(modelContainer)

            let descriptor = FetchDescriptor<Transcription>(
                predicate: #Predicate<Transcription> { transcription in
                    transcription.timestamp < cutoffDate
                }
            )
            let items = try backgroundContext.fetch(descriptor)
            var deletedCount = 0
            for transcription in items {
                if let urlString = transcription.audioFileURL,
                   let url = URL(string: urlString),
                   FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                backgroundContext.delete(transcription)
                deletedCount += 1
            }
            if deletedCount > 0 {
                try backgroundContext.save()
                logger.notice("Cleaned up \(deletedCount, privacy: .public) old transcription(s)")
                await MainActor.run {
                    NotificationCenter.default.post(name: .transcriptionDeleted, object: nil)
                }
            }
        } catch {
            logger.error("Failed during transcription cleanup: \(error, privacy: .public)")
        }
    }

    /// Every audio filename any Transcription references: the main file (`audioFileURL`) AND the
    /// split chunks (`audioChunkPathsRaw`). Chunks 2…N of a long recording are referenced ONLY via
    /// the chunk list — an orphan sweep that ignores it deletes live data.
    private func referencedAudioFileNames(in context: ModelContext) throws -> Set<String> {
        var descriptor = FetchDescriptor<Transcription>()
        descriptor.propertiesToFetch = [\.audioFileURL, \.audioChunkPathsRaw]

        let transcriptions = try context.fetch(descriptor)
        var referenced = Set<String>()
        for transcription in transcriptions {
            if let urlString = transcription.audioFileURL, let url = URL(string: urlString) {
                referenced.insert(url.lastPathComponent)
            }
            if let raw = transcription.audioChunkPathsRaw, !raw.isEmpty {
                for path in raw.split(separator: "\n") {
                    referenced.insert(URL(fileURLWithPath: String(path)).lastPathComponent)
                }
            }
        }
        return referenced
    }

    /// Deletes audio files in Recordings directory that have no corresponding Transcription record
    private func cleanupOrphanAudioFiles(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled) else {
            return
        }

        let modelContainer = await MainActor.run { modelContext.container }

        do {
            let backgroundContext = ModelContext(modelContainer)
            let referencedFiles = try referencedAudioFileNames(in: backgroundContext)

            guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else { return }
            let filesInDirectory = try FileManager.default.contentsOfDirectory(
                at: recordingsDirectory,
                includingPropertiesForKeys: nil
            )

            var deletedCount = 0
            for fileURL in filesInDirectory {
                let fileName = fileURL.lastPathComponent
                if !referencedFiles.contains(fileName) {
                    try? FileManager.default.removeItem(at: fileURL)
                    deletedCount += 1
                }
            }

            if deletedCount > 0 {
                logger.notice("Cleaned up \(deletedCount, privacy: .public) orphan audio file(s)")
            }
        } catch {
            logger.error("Failed during orphan audio cleanup: \(error, privacy: .public)")
        }
    }

    /// Minimum age before an unreferenced file is reclaimed. The transcription queue is in-memory
    /// (doesn't survive relaunch) and this sweep runs at launch, so anything unreferenced AND older
    /// than a day cannot belong to an in-flight import.
    private static let orphanReclaimMinimumAge: TimeInterval = 24 * 60 * 60

    /// Always-on disk reclamation for files no Transcription references:
    /// - `RecorderImports/`: the staging copy of every device recording. Nothing ever referenced or
    ///   deleted these — each import leaked a full recording's worth of disk permanently.
    /// - `Recordings/`: transcoded WAVs whose pipeline failed before creating a row.
    /// Only files older than `orphanReclaimMinimumAge` are touched, so queued/in-flight imports are
    /// never at risk.
    private func reclaimUnreferencedAudioFiles(modelContext: ModelContext) async {
        let modelContainer = await MainActor.run { modelContext.container }

        do {
            let backgroundContext = ModelContext(modelContainer)
            let referencedFiles = try referencedAudioFileNames(in: backgroundContext)
            let cutoff = Date().addingTimeInterval(-Self.orphanReclaimMinimumAge)

            var deletedCount = 0
            var freedBytes: Int64 = 0

            for directory in [recorderImportsDirectory, recordingsDirectory] {
                guard FileManager.default.fileExists(atPath: directory.path) else { continue }
                let files = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )

                for fileURL in files {
                    guard !referencedFiles.contains(fileURL.lastPathComponent) else { continue }
                    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    guard let modified = values?.contentModificationDate, modified < cutoff else { continue }

                    do {
                        try FileManager.default.removeItem(at: fileURL)
                        deletedCount += 1
                        freedBytes += Int64(values?.fileSize ?? 0)
                    } catch {
                        logger.error("Failed to reclaim orphan \(fileURL.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                    }
                }
            }

            if deletedCount > 0 {
                let freed = ByteCountFormatter.string(fromByteCount: freedBytes, countStyle: .file)
                logger.notice("Reclaimed \(deletedCount, privacy: .public) unreferenced audio file(s), freed \(freed, privacy: .public)")
            }
        } catch {
            logger.error("Failed during unreferenced-audio reclamation: \(error, privacy: .public)")
        }
    }
}
