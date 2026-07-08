import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class LibraryFilterTests: XCTestCase {

    private func seed() -> [Transcription] {
        let now = Date()
        func t(_ text: String, fp: String?, tag: String?, star: Bool, ts: Date, dur: TimeInterval) -> Transcription {
            let x = Transcription(text: text, duration: dur)
            x.importFingerprint = fp
            x.recorderCategoryName = fp != nil ? tag : nil
            x.manualTag = fp == nil ? tag : nil
            x.recorderFavorite = star
            x.timestamp = ts
            return x
        }
        return [
            t("會議紀錄一", fp: "f1", tag: "會議", star: false, ts: now, dur: 100),
            t("演講內容", fp: "f2", tag: "演講", star: true, ts: now.addingTimeInterval(-10 * 86400), dur: 300),
            t("會議紀錄二", fp: "f3", tag: "會議", star: false, ts: now.addingTimeInterval(-1 * 86400), dur: 50),
            t("語音備忘", fp: nil, tag: "想法", star: false, ts: now, dur: 20),
        ]
    }

    func testRecorderScopeExcludesVoice() {
        let f = LibraryFilter(scope: .recorder)
        let out = f.apply(to: seed())
        XCTAssertEqual(out.count, 3)   // 3 個有 fingerprint
        XCTAssertTrue(out.allSatisfy { $0.importFingerprint != nil })
    }

    func testVoiceScopeExcludesRecorder() {
        let f = LibraryFilter(scope: .voice)
        let out = f.apply(to: seed())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.text, "語音備忘")
    }

    func testTagFilter() {
        var f = LibraryFilter(scope: .recorder); f.tag = "會議"
        XCTAssertEqual(f.apply(to: seed()).count, 2)
    }

    func testStarredAndSortBySizeDesc() {
        var f = LibraryFilter(scope: .recorder)
        f.sort = .size; f.ascending = false
        let sizes = ["f1": 1000, "f2": 5000, "f3": 200]
        let out = f.apply(to: seed(), sizeByFingerprint: sizes)
        XCTAssertEqual(out.map { $0.importFingerprint }, ["f2", "f1", "f3"])   // 大→小
    }

    func testSearchMatchesTextAndTag() {
        var f = LibraryFilter(scope: .recorder); f.searchText = "演講"
        let out = f.apply(to: seed())
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.text, "演講內容")
    }

    func testDeletionSetProtectsStarred() {
        let items = seed()
        let (toDelete, excluded) = LibraryFilter.deletionSet(from: items, includeStarred: false)
        XCTAssertEqual(excluded, 1)   // 「演講內容」有星號
        XCTAssertFalse(toDelete.contains { $0.recorderFavorite })

        let (all, none) = LibraryFilter.deletionSet(from: items, includeStarred: true)
        XCTAssertEqual(none, 0)
        XCTAssertEqual(all.count, items.count)
    }
}
