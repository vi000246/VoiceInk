import Foundation
import SwiftData

@Model
final class ImportLedgerEntry {
    // fingerprint: content-dedup lookup; (fileName, byteSize): quick-match pre-skip —
    // both run once per device file on every mount/folder scan.
    #Index<ImportLedgerEntry>([\.fingerprint], [\.fileName, \.byteSize])

    var fingerprint: String = ""   // sha256(content) — primary dedup key
    var fileName: String = ""
    var byteSize: Int = 0
    var sourceDeviceId: UUID?
    var importedAt: Date = Date()
    var transcriptionId: UUID?
    /// 來源資料夾下的相對路徑(遞迴來源才有意義,如 JPR 的 "2026-07-06/14-30-22.m4a")。
    /// 錄音時間解析用——日期藏在父資料夾名時,光靠 fileName 拿不回來。additive、輕遷移。
    var relativePath: String?

    init(fingerprint: String, fileName: String, byteSize: Int,
         sourceDeviceId: UUID?, transcriptionId: UUID? = nil, relativePath: String? = nil) {
        self.fingerprint = fingerprint
        self.fileName = fileName
        self.byteSize = byteSize
        self.sourceDeviceId = sourceDeviceId
        self.importedAt = Date()
        self.transcriptionId = transcriptionId
        self.relativePath = relativePath
    }
}
