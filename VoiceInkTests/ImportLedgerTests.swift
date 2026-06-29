import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class ImportLedgerTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: ImportLedgerEntry.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func testContentFingerprintIsStableSHA256() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID()).bin")
        try Data("hello".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        XCTAssertEqual(try ImportLedger.shared.contentFingerprint(for: tmp),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testIsImportedReflectsRecord() throws {
        let ctx = try makeContext()
        XCTAssertFalse(ImportLedger.shared.isImported(fingerprint: "abc", in: ctx))
        ImportLedger.shared.record(fingerprint: "abc", fileName: "a.wav", byteSize: 3,
                                   sourceDeviceId: nil, transcriptionId: nil, in: ctx)
        XCTAssertTrue(ImportLedger.shared.isImported(fingerprint: "abc", in: ctx))
    }
}
