import Foundation
import SwiftData

/// A utility class that manages automatic cleanup of audio files while preserving transcript data
class AudioCleanupManager {
    static let shared = AudioCleanupManager()

    private var cleanupTimer: Timer?
    private let cleanupCheckInterval: TimeInterval = 86400 // Check once per day (in seconds)
    
    private init() {}
    
    /// Start the automatic cleanup schedule.
    func startAutomaticCleanup(modelContext: ModelContext) {
        // Cancel any existing timer
        cleanupTimer?.invalidate()

        // Schedule regular cleanup
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: cleanupCheckInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.runAutomaticCleanupIfNeeded(modelContext: modelContext)
            }
        }
    }

    /// Run automatic cleanup once if it is due. This is safe to call on app/window appear.
    func runAutomaticCleanupIfNeeded(modelContext: ModelContext) async {
        guard UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled),
              !UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isTranscriptionCleanupEnabled),
              shouldRunAutomaticCleanup() else {
            return
        }

        await performCleanup(modelContext: modelContext)
        UserDefaults.standard.set(Date(), forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate)
    }
    
    /// Stop the automatic cleanup process
    func stopAutomaticCleanup() {
        cleanupTimer?.invalidate()
        cleanupTimer = nil
    }
    
    /// Get information about the files that would be cleaned up
    func getCleanupInfo(modelContext: ModelContext) async -> (fileCount: Int, totalSize: Int64, transcriptions: [Transcription]) {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod)

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return (0, 0, [])
        }

        do {
            // SwiftData fetch stays on the main actor; the per-file stat calls run off it —
            // with a large history they were a main-thread hitch on every appear/daily tick.
            let candidates: [(transcription: Transcription, path: String)] = try await MainActor.run {
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate &&
                        transcription.audioFileURL != nil &&
                        transcription.recorderSourceDeviceId == nil
                    }
                )
                return try modelContext.fetch(descriptor).compactMap { t in
                    guard let urlString = t.audioFileURL, let url = URL(string: urlString) else { return nil }
                    return (t, url.path)
                }
            }

            let paths = candidates.map { $0.path }
            let sizeByPath: [String: Int64] = await Task.detached(priority: .utility) {
                var out: [String: Int64] = [:]
                for path in paths {
                    // attributesOfItem throws for missing files, so this doubles as the existence check
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                       let fileSize = attributes[.size] as? Int64 {
                        out[path] = fileSize
                    }
                }
                return out
            }.value

            var fileCount = 0
            var totalSize: Int64 = 0
            var eligibleTranscriptions: [Transcription] = []
            for candidate in candidates {
                if let fileSize = sizeByPath[candidate.path] {
                    totalSize += fileSize
                    fileCount += 1
                    eligibleTranscriptions.append(candidate.transcription)
                }
            }
            return (fileCount, totalSize, eligibleTranscriptions)
        } catch {
            return (0, 0, [])
        }
    }

    /// Deletes the given files off the main actor. Returns the paths actually removed and the
    /// number of failures (missing files count as neither).
    private static func deleteFiles(atPaths paths: [String]) async -> (deleted: Set<String>, errorCount: Int) {
        await Task.detached(priority: .utility) {
            var deleted = Set<String>()
            var errorCount = 0
            for path in paths {
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do {
                    try FileManager.default.removeItem(atPath: path)
                    deleted.insert(path)
                } catch {
                    errorCount += 1
                }
            }
            return (deleted, errorCount)
        }.value
    }
    
    /// Perform the cleanup operation
    private func performCleanup(modelContext: ModelContext) async {
        // Get retention period from UserDefaults
        let effectiveRetentionDays = UserDefaults.standard.integer(forKey: CleanupSettingsKeys.audioRetentionPeriod)

        // Check if automatic cleanup is enabled
        let isCleanupEnabled = UserDefaults.standard.bool(forKey: CleanupSettingsKeys.isAudioCleanupEnabled)
        guard isCleanupEnabled else { return }

        // Calculate the cutoff date
        let calendar = Calendar.current
        guard let cutoffDate = calendar.date(byAdding: .day, value: -effectiveRetentionDays, to: Date()) else {
            return
        }

        do {
            // Fetch on the main actor, delete files off it, then hop back to null the URLs.
            let transcriptionByPath: [String: Transcription] = try await MainActor.run {
                let descriptor = FetchDescriptor<Transcription>(
                    predicate: #Predicate<Transcription> { transcription in
                        transcription.timestamp < cutoffDate &&
                        transcription.audioFileURL != nil &&
                        transcription.recorderSourceDeviceId == nil
                    }
                )
                var map: [String: Transcription] = [:]
                for t in try modelContext.fetch(descriptor) {
                    if let urlString = t.audioFileURL, let url = URL(string: urlString) { map[url.path] = t }
                }
                return map
            }

            let (deleted, _) = await Self.deleteFiles(atPaths: Array(transcriptionByPath.keys))
            guard !deleted.isEmpty else { return }

            await MainActor.run {
                // Only clear audioFileURL for files that were actually removed
                for path in deleted { transcriptionByPath[path]?.audioFileURL = nil }
                try? modelContext.save()
            }
        } catch {
            // Silently fail - cleanup is non-critical
        }
    }
    
    /// Run cleanup manually - can be called from settings
    func runManualCleanup(modelContext: ModelContext) async {
        await performCleanup(modelContext: modelContext)
    }

    private func shouldRunAutomaticCleanup() -> Bool {
        guard let lastCleanupDate = UserDefaults.standard.object(forKey: CleanupSettingsKeys.lastAutomaticAudioCleanupDate) as? Date else {
            return true
        }

        return Date().timeIntervalSince(lastCleanupDate) >= cleanupCheckInterval
    }
    
    /// Run cleanup on the specified transcriptions
    func runCleanupForTranscriptions(modelContext: ModelContext, transcriptions: [Transcription]) async -> (deletedCount: Int, errorCount: Int) {
        // Model access on the main actor, file deletion off it.
        let transcriptionByPath: [String: Transcription] = await MainActor.run {
            var map: [String: Transcription] = [:]
            for t in transcriptions {
                if let urlString = t.audioFileURL, let url = URL(string: urlString) { map[url.path] = t }
            }
            return map
        }

        let (deleted, errorCount) = await Self.deleteFiles(atPaths: Array(transcriptionByPath.keys))

        await MainActor.run {
            for path in deleted { transcriptionByPath[path]?.audioFileURL = nil }
            if !deleted.isEmpty || errorCount > 0 {
                try? modelContext.save()
            }
        }

        return (deleted.count, errorCount)
    }
    
    /// Format file size in human-readable form
    func formatFileSize(_ size: Int64) -> String {
        let byteCountFormatter = ByteCountFormatter()
        byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB]
        byteCountFormatter.countStyle = .file
        return byteCountFormatter.string(fromByteCount: size)
    }
} 
