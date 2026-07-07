import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class ICloudSourcesTests: XCTestCase {

    // Task 1: 舊版 JSON(無新欄位)解碼 → 全部 default 進場,行為不變。
    func testDeviceDecodesLegacyJSONWithDefaults() throws {
        let legacy = """
        [{"id":"\(UUID().uuidString)","displayName":"IC","volumeNameMatch":"IC RECORDER",
          "sourceFolderBookmark":"\(Data([1]).base64EncodedString())","createdAt":0}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([RecorderDevice].self, from: legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].kind, .volume)
        XCTAssertFalse(decoded[0].recursive)
        XCTAssertFalse(decoded[0].isICloudSource)
        XCTAssertNil(decoded[0].presetKind)
        XCTAssertNil(decoded[0].defaultCategoryId)
        XCTAssertFalse(decoded[0].protectsOriginals)
    }

    // Task 5: iCloud/preset 來源即使被(誤)設 deleteAfterImport 也受保護。
    func testProtectsOriginalsFlags() {
        let icloud = RecorderDevice(displayName: "JPR", kind: .folder, volumeNameMatch: "",
                                    sourceFolderBookmark: Data(), deleteAfterImport: true,
                                    isICloudSource: true)
        XCTAssertTrue(icloud.protectsOriginals)
        let preset = RecorderDevice(displayName: "VM", kind: .folder, volumeNameMatch: "",
                                    sourceFolderBookmark: Data(), presetKind: "voiceMemos")
        XCTAssertTrue(preset.protectsOriginals)
        let normal = RecorderDevice(displayName: "IC", volumeNameMatch: "IC", sourceFolderBookmark: Data())
        XCTAssertFalse(normal.protectsOriginals)
    }

    // Task 6: per-device 預設分類解析;分類被刪 → nil(回自動分類)。
    func testDeviceDefaultCategoryResolves() {
        let store = RecorderConfigStore.shared
        let temp = RecorderCategory(name: "ICloudSourcesTests-分類", subfolderName: "icloud-tests-temp")
        store.upsertCategory(temp)
        defer { store.removeCategory(temp.id) }

        let device = RecorderDevice(displayName: "JPR", kind: .folder, volumeNameMatch: "",
                                    sourceFolderBookmark: Data(), defaultCategoryId: temp.id)
        XCTAssertEqual(device.defaultCategory(in: store)?.id, temp.id)

        let dangling = RecorderDevice(displayName: "X", kind: .folder, volumeNameMatch: "",
                                      sourceFolderBookmark: Data(), defaultCategoryId: UUID())
        XCTAssertNil(dangling.defaultCategory(in: store))
    }

    // Task 2: 遞迴掃描找到日期子資料夾內的檔案,relativePath 帶子路徑;關閉遞迴時看不到。
    func testRecursiveScanFindsNestedFilesWithRelativePath() async throws {
        let store = RecorderConfigStore.shared
        let prevValue = store.recorderMinImportSizeValue
        let prevUnit = store.recorderMinImportSizeUnit
        store.setRecorderMinImportSize(value: 0, unit: prevUnit)
        defer { store.setRecorderMinImportSize(value: prevValue, unit: prevUnit) }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-\(UUID())")
        let nested = dir.appendingPathComponent("2026-07-06")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data([1, 2, 3]).write(to: nested.appendingPathComponent("14-30-22.m4a"))

        let ctx = try ModelContext(ModelContainer(for: ImportLedgerEntry.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

        let recursive = await RecorderImportService.shared.newImportableFiles(
            in: dir, context: ctx, recursive: true)
        XCTAssertEqual(recursive.candidates.count, 1)
        XCTAssertEqual(recursive.candidates.first?.relativePath, "2026-07-06/14-30-22.m4a")
        XCTAssertEqual(recursive.candidates.first?.fileName, "14-30-22.m4a")

        let flat = await RecorderImportService.shared.newImportableFiles(
            in: dir, context: ctx, recursive: false)
        XCTAssertTrue(flat.candidates.isEmpty)
    }

    // Task 3: dataless 佔位檔 → defer＋觸發下載;有本地資料或非 iCloud 檔 → 照常。
    func testUbiquityGateDefersNotDownloaded() {
        XCTAssertEqual(RecorderImportService.ubiquityAction(for: .notDownloaded), .deferAndDownload)
        XCTAssertEqual(RecorderImportService.ubiquityAction(for: .current), .proceed)
        XCTAssertEqual(RecorderImportService.ubiquityAction(for: .downloaded), .proceed)
        XCTAssertEqual(RecorderImportService.ubiquityAction(for: nil), .proceed)
    }

    // Task 7: 錄音時間解析鏈的優先序。
    func testLegacyFileNameStampStillWins() {
        let d = RecorderRecordingTime.parse(fileName: "250701_1258.mp3",
                                            relativePath: "2026-07-06/250701_1258.mp3",
                                            fileCreationDate: Date(timeIntervalSince1970: 0))
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2025, 7, 1, 12, 58])
    }

    func testParsesJPRPathDates() {
        let d = RecorderRecordingTime.parse(fileName: "14-30-22.m4a",
                                            relativePath: "2026-07-06/14-30-22.m4a",
                                            fileCreationDate: nil)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d!)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute, c.second], [2026, 7, 6, 14, 30, 22])
    }

    func testFallsBackToCreationDateThenNil() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(RecorderRecordingTime.parse(fileName: "ABC123.m4a",
                                                   relativePath: "no-dates-here/ABC123.m4a",
                                                   fileCreationDate: created), created)
        XCTAssertNil(RecorderRecordingTime.parse(fileName: "ABC123.m4a",
                                                 relativePath: nil,
                                                 fileCreationDate: nil))
    }
}
