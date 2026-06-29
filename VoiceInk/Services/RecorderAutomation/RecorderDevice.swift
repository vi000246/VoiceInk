import Foundation

struct RecorderDevice: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var volumeNameMatch: String       // matched against mounted volume name, e.g. "IC RECORDER"
    var sourceFolderBookmark: Data    // security-scoped bookmark to the folder ON the device
    var autoImportEnabled: Bool
    var deleteAfterImport: Bool
    var createdAt: Date

    init(id: UUID = UUID(), displayName: String, volumeNameMatch: String,
         sourceFolderBookmark: Data, autoImportEnabled: Bool = true,
         deleteAfterImport: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.displayName = displayName; self.volumeNameMatch = volumeNameMatch
        self.sourceFolderBookmark = sourceFolderBookmark; self.autoImportEnabled = autoImportEnabled
        self.deleteAfterImport = deleteAfterImport; self.createdAt = createdAt
    }

    func matches(volumeName: String) -> Bool {
        volumeName.localizedCaseInsensitiveContains(volumeNameMatch)
    }
}
