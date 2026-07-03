import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class RecorderImportServiceTests: XCTestCase {
    func testScanReturnsOnlyNewSupportedFiles() async throws {
        // Host-app tests share the real app's UserDefaults — zero the user-configurable
        // min-import-size floor so the tiny fixture file isn't filtered out, then restore.
        let store = RecorderConfigStore.shared
        let prevValue = store.recorderMinImportSizeValue
        let prevUnit = store.recorderMinImportSizeUnit
        store.setRecorderMinImportSize(value: 0, unit: prevUnit)
        defer { store.setRecorderMinImportSize(value: prevValue, unit: prevUnit) }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav"); try Data([1,2,3]).write(to: wav)
        let txt = dir.appendingPathComponent("note.txt"); try Data([9]).write(to: txt) // unsupported
        let ctx = try ModelContext(ModelContainer(for: ImportLedgerEntry.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

        let first = await RecorderImportService.shared.newImportableFiles(in: dir, context: ctx)
        XCTAssertEqual(first.candidates.map { $0.url.lastPathComponent }, ["a.wav"]) // txt filtered out

        // Simulate it was imported → ledger record → no longer returned
        let fp = try ImportLedger.contentFingerprint(for: wav)
        ImportLedger.shared.record(fingerprint: fp, fileName: "a.wav", byteSize: 3,
                                   sourceDeviceId: nil, transcriptionId: nil, in: ctx)
        let second = await RecorderImportService.shared.newImportableFiles(in: dir, context: ctx)
        XCTAssertTrue(second.candidates.isEmpty)
    }
}
