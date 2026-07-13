import XCTest
import Carbon.HIToolbox
@testable import VoiceInk

/// FR-32 + AC-19(資料層半部):三個會議熱鍵皆須參與衝突偵測。
/// 行為驗證走 `ShortcutValidator.validationError`(public 面),不碰 private 的 allStoredActions。
/// ⚠️ host-app 測試讀寫**真** UserDefaults——setUp 快照、tearDown 還原,不得殘留。
final class MeetingShortcutTests: XCTestCase {

    private let meetingActions: [ShortcutAction] = [
        .toggleMeetingRecording,
        .toggleMeetingCopilotOverlay,
        .peekMeetingCopilotOverlay
    ]
    private var savedData: [String: Data?] = [:]

    override func setUp() {
        super.setUp()
        for action in meetingActions {
            savedData[action.userDefaultsKey] = UserDefaults.standard.data(forKey: action.userDefaultsKey)
        }
    }

    override func tearDown() {
        for action in meetingActions {
            ShortcutStore.removeShortcutStorage(for: action)
            if let data = savedData[action.userDefaultsKey] ?? nil {
                UserDefaults.standard.set(data, forKey: action.userDefaultsKey)
            }
        }
        super.tearDown()
    }

    // MARK: - 儲存/監看面（含 M1 既有）

    func testToggleMeetingIsGlobalUtility() {
        XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.toggleMeetingRecording))
        XCTAssertEqual(ShortcutAction.toggleMeetingRecording.storageName, "toggleMeetingRecording")
        XCTAssertTrue(ShortcutAction.toggleMeetingRecording.isStored)
        XCTAssertEqual(ShortcutAction.toggleMeetingRecording.userDefaultsKey, "Shortcut_toggleMeetingRecording")
    }

    func testNewActionStorageNamesAreStable() {
        XCTAssertEqual(ShortcutAction.toggleMeetingCopilotOverlay.storageName, "toggleMeetingCopilotOverlay")
        XCTAssertEqual(ShortcutAction.peekMeetingCopilotOverlay.storageName, "peekMeetingCopilotOverlay")
        XCTAssertTrue(ShortcutAction.toggleMeetingCopilotOverlay.isStored)
        XCTAssertTrue(ShortcutAction.peekMeetingCopilotOverlay.isStored)
    }

    func testNewActionsAreGlobalUtilityActions() {
        XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.toggleMeetingCopilotOverlay))
        XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.peekMeetingCopilotOverlay))
    }

    // MARK: - AC-19:衝突偵測(FR-32 的核心)

    /// build 227 缺陷:.toggleMeetingRecording 的鍵對衝突偵測雙向隱形。修復後:
    /// 給它設一鍵 → 同一鍵指派給其他動作必須被拒(.alreadyUsedBy)。
    func testMeetingRecordingShortcutParticipatesInConflictDetection() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_9), modifierFlags: [.command, .option, .control])
        ShortcutStore.setShortcut(shortcut, for: .toggleMeetingRecording)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .toggleMeetingRecording), "前置:鍵必須真的存進去")

        let error = ShortcutValidator.validationError(for: shortcut, action: .pasteLastTranscription)
        XCTAssertEqual(error, .alreadyUsedBy(ShortcutAction.toggleMeetingRecording.displayName))
    }

    func testOverlayToggleShortcutParticipatesInConflictDetection() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_8), modifierFlags: [.command, .option, .control])
        ShortcutStore.setShortcut(shortcut, for: .toggleMeetingCopilotOverlay)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .toggleMeetingCopilotOverlay))

        let error = ShortcutValidator.validationError(for: shortcut, action: .openHistoryWindow)
        XCTAssertEqual(error, .alreadyUsedBy(ShortcutAction.toggleMeetingCopilotOverlay.displayName))
    }

    func testPeekShortcutParticipatesInConflictDetection() {
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_7), modifierFlags: [.command, .option, .control])
        ShortcutStore.setShortcut(shortcut, for: .peekMeetingCopilotOverlay)
        XCTAssertNotNil(ShortcutStore.shortcut(for: .peekMeetingCopilotOverlay))

        let error = ShortcutValidator.validationError(for: shortcut, action: .toggleMeetingCopilotOverlay)
        XCTAssertEqual(error, .alreadyUsedBy(ShortcutAction.peekMeetingCopilotOverlay.displayName))
    }
}
