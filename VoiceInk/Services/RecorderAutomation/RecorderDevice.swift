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
    // iCloud 來源擴充(2026-07-07):全部 additive、decodeIfPresent 給預設——刻意不加新 Kind case
    // (舊版解碼未知 raw value 會讓整個元素 decode 失敗)。
    var recursive: Bool               // 遞迴掃描子資料夾(JPR 以日期開子資料夾)
    var isICloudSource: Bool          // iCloud Drive 語意:佔位檔下載、metadata-query 監看、強制不刪原始檔
    var presetKind: String?           // "justPressRecord" | "voiceMemos";nil＝自訂來源
    var defaultCategoryId: UUID?      // 設定時跳過分類器,直接套此分類

    init(id: UUID = UUID(), displayName: String, kind: Kind = .volume, volumeNameMatch: String,
         sourceFolderBookmark: Data, autoImportEnabled: Bool = true,
         deleteAfterImport: Bool = false, createdAt: Date = Date(),
         recursive: Bool = false, isICloudSource: Bool = false,
         presetKind: String? = nil, defaultCategoryId: UUID? = nil) {
        self.id = id; self.displayName = displayName; self.kind = kind
        self.volumeNameMatch = volumeNameMatch
        self.sourceFolderBookmark = sourceFolderBookmark
        self.autoImportEnabled = autoImportEnabled
        self.deleteAfterImport = deleteAfterImport; self.createdAt = createdAt
        self.recursive = recursive; self.isICloudSource = isICloudSource
        self.presetKind = presetKind; self.defaultCategoryId = defaultCategoryId
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
        recursive = try c.decodeIfPresent(Bool.self, forKey: .recursive) ?? false
        isICloudSource = try c.decodeIfPresent(Bool.self, forKey: .isICloudSource) ?? false
        presetKind = try c.decodeIfPresent(String.self, forKey: .presetKind)
        defaultCategoryId = try c.decodeIfPresent(UUID.self, forKey: .defaultCategoryId)
    }

    /// 解析 per-device 預設分類;分類已被刪 → nil(回自動分類)。
    @MainActor
    func defaultCategory(in store: RecorderConfigStore) -> RecorderCategory? {
        defaultCategoryId.flatMap { store.category(byId: $0) }
    }

    /// 此來源的原始檔絕不可刪(iCloud 或任何 preset 一律保護,即使 deleteAfterImport 被誤設)。
    var protectsOriginals: Bool { isICloudSource || presetKind != nil }

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
