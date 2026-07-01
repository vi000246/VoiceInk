import Foundation

struct RecorderDevice: Codable, Identifiable, Equatable {
    /// How this source is detected:
    /// - `.volume`: a removable recorder — matched by mounted volume name, imported on mount.
    /// - `.folder`: an ordinary always-present folder — watched for new files and imported live.
    enum Kind: String, Codable { case volume, folder }

    let id: UUID
    var displayName: String
    var kind: Kind
    var volumeNameMatch: String       // matched against mounted volume name, e.g. "IC RECORDER" (.volume only)
    var sourceFolderBookmark: Data    // security-scoped bookmark to the source folder
    var autoImportEnabled: Bool
    var deleteAfterImport: Bool
    var createdAt: Date

    init(id: UUID = UUID(), displayName: String, kind: Kind = .volume, volumeNameMatch: String,
         sourceFolderBookmark: Data, autoImportEnabled: Bool = true,
         deleteAfterImport: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.displayName = displayName; self.kind = kind
        self.volumeNameMatch = volumeNameMatch
        self.sourceFolderBookmark = sourceFolderBookmark
        self.autoImportEnabled = autoImportEnabled
        self.deleteAfterImport = deleteAfterImport; self.createdAt = createdAt
    }

    // Backwards-compatible decode: devices stored before the `kind` field default to `.volume`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .volume
        volumeNameMatch = try c.decodeIfPresent(String.self, forKey: .volumeNameMatch) ?? ""
        sourceFolderBookmark = try c.decode(Data.self, forKey: .sourceFolderBookmark)
        autoImportEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoImportEnabled) ?? true
        deleteAfterImport = try c.decodeIfPresent(Bool.self, forKey: .deleteAfterImport) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Resolve the security-scoped source folder bookmark to a URL (does not start access).
    func resolveSourceFolder() -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: sourceFolderBookmark, options: [.withSecurityScope],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    func matches(volumeName: String) -> Bool {
        kind == .volume && !volumeNameMatch.isEmpty
            && volumeName.localizedCaseInsensitiveContains(volumeNameMatch)
    }
}
