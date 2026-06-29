import Foundation
import SwiftData
import CryptoKit
import os

@MainActor
final class ImportLedger {
    static let shared = ImportLedger()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() {}

    /// Cheap pre-filter key (no file read).
    func quickKey(fileName: String, byteSize: Int) -> String { "\(fileName)|\(byteSize)" }

    /// SHA-256 hex of the file's bytes.
    func contentFingerprint(for url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isImported(fingerprint: String, in context: ModelContext) -> Bool {
        var d = FetchDescriptor<ImportLedgerEntry>(predicate: #Predicate { $0.fingerprint == fingerprint })
        d.fetchLimit = 1
        return ((try? context.fetch(d))?.isEmpty == false)
    }

    /// Quick-path: any ledger row with same (fileName, byteSize)?
    func hasQuickMatch(fileName: String, byteSize: Int, in context: ModelContext) -> Bool {
        var d = FetchDescriptor<ImportLedgerEntry>(
            predicate: #Predicate { $0.fileName == fileName && $0.byteSize == byteSize })
        d.fetchLimit = 1
        return ((try? context.fetch(d))?.isEmpty == false)
    }

    func record(fingerprint: String, fileName: String, byteSize: Int,
                sourceDeviceId: UUID?, transcriptionId: UUID?, in context: ModelContext) {
        context.insert(ImportLedgerEntry(fingerprint: fingerprint, fileName: fileName,
                                         byteSize: byteSize, sourceDeviceId: sourceDeviceId,
                                         transcriptionId: transcriptionId))
        do { try context.save() } catch { logger.error("Ledger save failed: \(error, privacy: .public)") }
    }
}
