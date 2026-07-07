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

    /// SHA-256 hex of the file's bytes, streamed in 4 MB chunks so a multi-GB recording never
    /// sits fully in RAM. nonisolated static: import scans must hash OFF the main actor — device
    /// files are routinely hundreds of MB and hashing them on main froze the UI on insert.
    nonisolated static func contentFingerprint(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 << 20) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func isImported(fingerprint: String, in context: ModelContext) -> Bool {
        var d = FetchDescriptor<ImportLedgerEntry>(predicate: #Predicate { $0.fingerprint == fingerprint })
        d.fetchLimit = 1
        return ((try? context.fetch(d))?.isEmpty == false)
    }

    /// Any ledger row with this exact fileName (used to pick a unique serial suffix on reprocess).
    func hasFileName(_ fileName: String, in context: ModelContext) -> Bool {
        var d = FetchDescriptor<ImportLedgerEntry>(predicate: #Predicate { $0.fileName == fileName })
        d.fetchLimit = 1
        return ((try? context.fetch(d))?.isEmpty == false)
    }

    /// The stored device filename for an imported fingerprint (nil if not in the ledger). Used to
    /// recover the real recording time (encoded in the filename) after the audio was renamed on import.
    func fileName(forFingerprint fingerprint: String, in context: ModelContext) -> String? {
        var d = FetchDescriptor<ImportLedgerEntry>(predicate: #Predicate { $0.fingerprint == fingerprint })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.fileName
    }

    /// Quick-path: any ledger row with same (fileName, byteSize)?
    func hasQuickMatch(fileName: String, byteSize: Int, in context: ModelContext) -> Bool {
        var d = FetchDescriptor<ImportLedgerEntry>(
            predicate: #Predicate { $0.fileName == fileName && $0.byteSize == byteSize })
        d.fetchLimit = 1
        return ((try? context.fetch(d))?.isEmpty == false)
    }

    /// 該 fingerprint 的來源相對路徑(遞迴來源才有;nil = 平面來源或舊資料)。
    func relativePath(forFingerprint fingerprint: String, in context: ModelContext) -> String? {
        var d = FetchDescriptor<ImportLedgerEntry>(predicate: #Predicate { $0.fingerprint == fingerprint })
        d.fetchLimit = 1
        return (try? context.fetch(d))?.first?.relativePath
    }

    func record(fingerprint: String, fileName: String, byteSize: Int,
                sourceDeviceId: UUID?, transcriptionId: UUID?, relativePath: String? = nil,
                in context: ModelContext) {
        context.insert(ImportLedgerEntry(fingerprint: fingerprint, fileName: fileName,
                                         byteSize: byteSize, sourceDeviceId: sourceDeviceId,
                                         transcriptionId: transcriptionId, relativePath: relativePath))
        do { try context.save() } catch { logger.error("Ledger save failed: \(error, privacy: .public)") }
    }
}
