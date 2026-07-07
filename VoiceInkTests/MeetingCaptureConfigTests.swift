import XCTest
@testable import VoiceInk

@MainActor
final class MeetingCaptureConfigTests: XCTestCase {

    func testMeetingCategorySelectionThreeStates() {
        let store = RecorderConfigStore.shared
        let key = "recorderMeetingFixedCategoryV1"

        // Host-app tests share the real app's UserDefaults — save/restore the raw value so this
        // test doesn't leak state into other tests or the real app.
        let prevRaw = UserDefaults.standard.object(forKey: key) as? String
        defer {
            if let prevRaw { UserDefaults.standard.set(prevRaw, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            store.load()
        }

        // "會議" is only seeded by `seedDefaultTemplates()` (not called from init), so a category
        // with that name isn't guaranteed to exist yet — add a temporary one via the public
        // upsert API and remove it again afterward.
        let tempMeetingCategory = RecorderCategory(name: "會議", subfolderName: "MeetingCaptureConfigTests-temp")
        store.upsertCategory(tempMeetingCategory)
        defer { store.removeCategory(tempMeetingCategory.id) }

        // State 1: key never set (nil) → resolver defaults to the category named "會議".
        UserDefaults.standard.removeObject(forKey: key)
        store.load()
        XCTAssertNil(store.meetingFixedCategorySelection)
        XCTAssertEqual(store.meetingFixedCategory?.name, "會議")

        // State 2: explicitly cleared (empty string) → auto-classify, resolver returns nil.
        store.setMeetingFixedCategoryId(nil)
        XCTAssertEqual(store.meetingFixedCategorySelection, "")
        XCTAssertNil(store.meetingFixedCategory)

        // State 3: a specific category id → resolver returns that exact category.
        let target = store.fallbackCategory
        store.setMeetingFixedCategoryId(target.id)
        XCTAssertEqual(store.meetingFixedCategorySelection, target.id.uuidString)
        XCTAssertEqual(store.meetingFixedCategory?.id, target.id)
    }

    func testMeetingMicEnabledDefaultTrueAndPersists() {
        let store = RecorderConfigStore.shared
        let key = "recorderMeetingMicEnabledV1"

        let prevRaw = UserDefaults.standard.object(forKey: key) as? Bool
        defer {
            if let prevRaw { UserDefaults.standard.set(prevRaw, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
            store.load()
        }

        // Never set → defaults to true.
        UserDefaults.standard.removeObject(forKey: key)
        store.load()
        XCTAssertTrue(store.meetingMicEnabled)

        // Explicit false persists.
        store.setMeetingMicEnabled(false)
        XCTAssertFalse(store.meetingMicEnabled)
    }
}
