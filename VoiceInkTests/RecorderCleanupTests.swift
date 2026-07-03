import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class RecorderCleanupTests: XCTestCase {
    /// The recorder retention sweep must delete ONLY old, non-starred recorder imports —
    /// starred recordings, dictation history, and fresh imports are all out of its reach.
    func testRecorderSweepDeletesOnlyOldUnstarredImports() async throws {
        let container = try ModelContainer(
            for: Transcription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let beyondRetention = Date().addingTimeInterval(-100 * 24 * 60 * 60)

        let oldImport = Transcription(text: "old-import", duration: 1, importFingerprint: "fp1")
        oldImport.timestamp = beyondRetention
        let starredImport = Transcription(text: "starred-import", duration: 1, importFingerprint: "fp2")
        starredImport.timestamp = beyondRetention
        starredImport.recorderFavorite = true
        let oldDictation = Transcription(text: "old-dictation", duration: 1)
        oldDictation.timestamp = beyondRetention
        let freshImport = Transcription(text: "fresh-import", duration: 1, importFingerprint: "fp3")

        for t in [oldImport, starredImport, oldDictation, freshImport] { context.insert(t) }
        try context.save()

        // Host-app tests share the real app's UserDefaults — set the sweep's gates, restore after.
        let defaults = UserDefaults.standard
        let prevEnabled = defaults.object(forKey: CleanupSettingsKeys.isRecorderCleanupEnabled)
        let prevDays = defaults.object(forKey: CleanupSettingsKeys.recorderRetentionDays)
        defaults.set(true, forKey: CleanupSettingsKeys.isRecorderCleanupEnabled)
        defaults.set(90, forKey: CleanupSettingsKeys.recorderRetentionDays)
        defer {
            if let prevEnabled { defaults.set(prevEnabled, forKey: CleanupSettingsKeys.isRecorderCleanupEnabled) }
            else { defaults.removeObject(forKey: CleanupSettingsKeys.isRecorderCleanupEnabled) }
            if let prevDays { defaults.set(prevDays, forKey: CleanupSettingsKeys.recorderRetentionDays) }
            else { defaults.removeObject(forKey: CleanupSettingsKeys.recorderRetentionDays) }
        }

        await TranscriptionAutoCleanupService.shared.runManualRecorderCleanup(modelContext: context)

        // Assert against a fresh context so we read the store, not this context's cached rows.
        let remaining = try ModelContext(container).fetch(FetchDescriptor<Transcription>())
        XCTAssertEqual(Set(remaining.map { $0.text }),
                       ["starred-import", "old-dictation", "fresh-import"])
    }
}
