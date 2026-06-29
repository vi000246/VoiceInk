import XCTest
@testable import VoiceInk

final class RecorderDeviceTests: XCTestCase {
    func testVolumeNameMatchIsCaseInsensitiveContains() {
        let d = RecorderDevice(displayName: "Sony", volumeNameMatch: "IC RECORDER",
                               sourceFolderBookmark: Data())
        XCTAssertTrue(d.matches(volumeName: "IC RECORDER"))
        XCTAssertTrue(d.matches(volumeName: "ic recorder"))
        XCTAssertFalse(d.matches(volumeName: "USB DRIVE"))
    }

    func testCodableRoundTrip() throws {
        let d = RecorderDevice(displayName: "Sony", volumeNameMatch: "IC RECORDER",
                               sourceFolderBookmark: Data([1,2,3]), autoImportEnabled: true,
                               deleteAfterImport: false)
        let data = try JSONEncoder().encode([d])
        let back = try JSONDecoder().decode([RecorderDevice].self, from: data)
        XCTAssertEqual(back.first, d)
    }
}
