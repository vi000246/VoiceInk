import Foundation
import SwiftData

@Model
final class ImportLedgerEntry {
    var fingerprint: String = ""   // sha256(content) — primary dedup key
    var fileName: String = ""
    var byteSize: Int = 0
    var sourceDeviceId: UUID?
    var importedAt: Date = Date()
    var transcriptionId: UUID?

    init(fingerprint: String, fileName: String, byteSize: Int,
         sourceDeviceId: UUID?, transcriptionId: UUID? = nil) {
        self.fingerprint = fingerprint
        self.fileName = fileName
        self.byteSize = byteSize
        self.sourceDeviceId = sourceDeviceId
        self.importedAt = Date()
        self.transcriptionId = transcriptionId
    }
}
