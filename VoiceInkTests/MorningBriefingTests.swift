import XCTest
@testable import VoiceInk

/// 晨間簡報(M13)的純函式核心:排程/catch-up 判定、任務分桶、內容組裝、config round-trip。
/// 日期一律用固定的台北時區 Calendar 建構——不依賴測試機時區,也絕不碰 `UserDefaults.standard`。

// MARK: - 排程

final class BriefingSchedulerTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private let eightThirty = 8 * 60 + 30

    func testNextFireDateBeforeConfiguredTimeIsToday() {
        let next = BriefingScheduler.nextFireDate(
            now: date(2026, 7, 20, 7, 0), configuredMinutes: eightThirty, calendar: calendar)
        XCTAssertEqual(next, date(2026, 7, 20, 8, 30))
    }

    func testNextFireDateAfterConfiguredTimeIsTomorrow() {
        let next = BriefingScheduler.nextFireDate(
            now: date(2026, 7, 20, 9, 0), configuredMinutes: eightThirty, calendar: calendar)
        XCTAssertEqual(next, date(2026, 7, 21, 8, 30))
    }

    /// 正好等於設定時刻 → 歸明天(這一發由 catch-up 接手;兩函式的邊界約定要互補不重疊)。
    func testNextFireDateExactlyAtConfiguredTimeIsTomorrow() {
        let next = BriefingScheduler.nextFireDate(
            now: date(2026, 7, 20, 8, 30), configuredMinutes: eightThirty, calendar: calendar)
        XCTAssertEqual(next, date(2026, 7, 21, 8, 30))
    }

    func testNextFireDateCrossesMonthBoundary() {
        let next = BriefingScheduler.nextFireDate(
            now: date(2026, 7, 31, 23, 50), configuredMinutes: eightThirty, calendar: calendar)
        XCTAssertEqual(next, date(2026, 8, 1, 8, 30))
    }

    /// 設定在午夜 00:00:過了 00:00 就排明天,不會排出「今天 00:00」這種已過去的時刻。
    func testNextFireDateMidnightConfig() {
        let next = BriefingScheduler.nextFireDate(
            now: date(2026, 7, 20, 0, 0), configuredMinutes: 0, calendar: calendar)
        XCTAssertEqual(next, date(2026, 7, 21, 0, 0))
    }

    func testShouldCatchUpWhenPastTimeAndNotShownToday() {
        XCTAssertTrue(BriefingScheduler.shouldCatchUp(
            now: date(2026, 7, 20, 12, 0), configuredMinutes: eightThirty,
            lastShownDay: "2026-07-19", calendar: calendar))
        XCTAssertTrue(BriefingScheduler.shouldCatchUp(
            now: date(2026, 7, 20, 12, 0), configuredMinutes: eightThirty,
            lastShownDay: nil, calendar: calendar))
    }

    func testShouldCatchUpExactlyAtConfiguredTime() {
        XCTAssertTrue(BriefingScheduler.shouldCatchUp(
            now: date(2026, 7, 20, 8, 30), configuredMinutes: eightThirty,
            lastShownDay: nil, calendar: calendar))
    }

    func testNoCatchUpBeforeConfiguredTime() {
        XCTAssertFalse(BriefingScheduler.shouldCatchUp(
            now: date(2026, 7, 20, 8, 29), configuredMinutes: eightThirty,
            lastShownDay: nil, calendar: calendar))
    }

    func testNoCatchUpWhenAlreadyShownToday() {
        XCTAssertFalse(BriefingScheduler.shouldCatchUp(
            now: date(2026, 7, 20, 12, 0), configuredMinutes: eightThirty,
            lastShownDay: "2026-07-20", calendar: calendar))
    }

    /// 跨午夜:昨天顯示過、現在是新的一天且已過設定時刻 → 要補。
    func testCatchUpAfterMidnightWithYesterdayStamp() {
        XCTAssertTrue(BriefingScheduler.shouldCatchUp(
            now: date(2026, 7, 21, 8, 31), configuredMinutes: eightThirty,
            lastShownDay: "2026-07-20", calendar: calendar))
    }

    func testDayKeyZeroPads() {
        XCTAssertEqual(BriefingScheduler.dayKey(for: date(2026, 1, 5, 3, 0), calendar: calendar),
                       "2026-01-05")
        XCTAssertEqual(BriefingScheduler.dayKey(for: date(2026, 7, 20, 23, 59), calendar: calendar),
                       "2026-07-20")
    }
}

// MARK: - 內容組裝

final class BriefingContentTests: XCTestCase {

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// 台北時間 RFC3339 字串(+08:00)。
    private func taipei(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> String {
        String(format: "%04d-%02d-%02dT%02d:%02d:00+08:00", y, mo, d, h, mi)
    }

    private func task(_ id: Int, _ title: String, due: String? = nil, done: Bool = false) -> VikunjaService.TaskItem {
        VikunjaService.TaskItem(id: id, title: title, done: done, dueDateRaw: due)
    }

    // now = 2026-07-20(一)10:00 台北。
    private var now: Date { date(2026, 7, 20, 10, 0) }

    func testBucketSplitsOverdueTodayAndNoDue() {
        let tasks = [
            task(1, "昨天", due: taipei(2026, 7, 19, 23, 59)),          // 逾期(時區邊界:昨天最後一分鐘)
            task(2, "今天凌晨", due: taipei(2026, 7, 20, 0, 0)),        // 今天(00:00 整,不算逾期)
            task(3, "今天下午", due: taipei(2026, 7, 20, 15, 0)),       // 今天
            task(4, "明天", due: taipei(2026, 7, 21, 9, 0)),            // 未來 → 不進簡報
            task(5, "sentinel", due: "0001-01-01T00:00:00Z"),           // 無期限
            task(6, "無 due"),                                          // 無期限
            task(7, "已完成", due: taipei(2026, 7, 10, 9, 0), done: true), // 防禦性排除
        ]
        let buckets = BriefingContent.bucket(tasks: tasks, now: now, calendar: calendar)
        XCTAssertEqual(buckets.overdue.map(\.id), [1])
        XCTAssertEqual(buckets.dueToday.map(\.id), [2, 3])
        XCTAssertEqual(buckets.noDue.map(\.id), [5, 6])
    }

    func testBucketSortsOverdueOldestFirstAndTodayByTime() {
        let tasks = [
            task(1, "三天前", due: taipei(2026, 7, 17, 9, 0)),
            task(2, "十天前", due: taipei(2026, 7, 10, 9, 0)),
            task(3, "今天 18:00", due: taipei(2026, 7, 20, 18, 0)),
            task(4, "今天 09:00", due: taipei(2026, 7, 20, 9, 0)),
        ]
        let buckets = BriefingContent.bucket(tasks: tasks, now: now, calendar: calendar)
        XCTAssertEqual(buckets.overdue.map(\.id), [2, 1])   // 逾期最久在前
        XCTAssertEqual(buckets.dueToday.map(\.id), [4, 3])  // 今天按時刻先後
    }

    func testParseDueDateSentinelAndEmpty() {
        XCTAssertNil(BriefingContent.parseDueDate("0001-01-01T00:00:00Z"))
        XCTAssertNil(BriefingContent.parseDueDate(nil))
        XCTAssertNil(BriefingContent.parseDueDate(""))
        XCTAssertNotNil(BriefingContent.parseDueDate("2026-07-20T09:00:00+08:00"))
        XCTAssertNotNil(BriefingContent.parseDueDate("2026-07-20T01:00:00Z"))
    }

    func testDaysOverdueIsCalendarDayDifference() {
        // 昨天 23:59 到期、今天 00:01 看 → 1 天(日曆日差,不是 86400 秒差)。
        let due = date(2026, 7, 19, 23, 59)
        XCTAssertEqual(BriefingContent.daysOverdue(
            due: due, now: date(2026, 7, 20, 0, 1), calendar: calendar), 1)
        XCTAssertEqual(BriefingContent.daysOverdue(
            due: date(2026, 7, 17, 9, 0), now: now, calendar: calendar), 3)
    }

    func testBuildModelSubtitlesAreNeutral() {
        let tasks = [
            task(1, "報告", due: taipei(2026, 7, 17, 9, 0)),
            task(2, "回信", due: taipei(2026, 7, 20, 15, 0)),
            task(3, "date-only", due: taipei(2026, 7, 20, 0, 0)),
        ]
        let model = BriefingContent.buildModel(
            tasks: tasks, vikunjaNote: nil, packFileNames: [], aiSuggestion: nil,
            now: now, calendar: calendar)
        XCTAssertEqual(model.overdue.first?.subtitle, "3 天前到期")
        XCTAssertEqual(model.dueToday.map(\.subtitle), ["今天到期", "今天 15:00 到期"])
    }

    func testBuildModelCapsNoDueAtFiveWithOverflow() {
        let tasks = (1...8).map { task($0, "t\($0)") }
        let model = BriefingContent.buildModel(
            tasks: tasks, vikunjaNote: nil, packFileNames: [], aiSuggestion: nil,
            now: now, calendar: calendar)
        XCTAssertEqual(model.noDue.count, 5)
        XCTAssertEqual(model.noDueOverflow, 3)
    }

    func testBuildModelEmptyEverythingHasNoContent() {
        let model = BriefingContent.buildModel(
            tasks: [], vikunjaNote: nil, packFileNames: [], aiSuggestion: nil,
            now: now, calendar: calendar)
        XCTAssertFalse(model.hasAnyContent)
    }

    /// Vikunja 壞掉(note)也算有內容——連線壞了本身就是該讓使用者知道的事,簡報照樣彈。
    func testBuildModelNoteAloneCountsAsContent() {
        let model = BriefingContent.buildModel(
            tasks: nil, vikunjaNote: "Vikunja 未連線", packFileNames: [], aiSuggestion: nil,
            now: now, calendar: calendar)
        XCTAssertTrue(model.hasAnyContent)
        XCTAssertEqual(model.vikunjaNote, "Vikunja 未連線")
        XCTAssertTrue(model.overdue.isEmpty)
    }

    func testBuildModelSortsPacksNewestFirst() {
        let model = BriefingContent.buildModel(
            tasks: nil, vikunjaNote: nil,
            packFileNames: ["2026-07-19 1400 會後包 A.md", "2026-07-20 0930 會後包 B.md"],
            aiSuggestion: nil, now: now, calendar: calendar)
        XCTAssertEqual(model.packs.map(\.fileName),
                       ["2026-07-20 0930 會後包 B.md", "2026-07-19 1400 會後包 A.md"])
    }

    func testIsRecentPackFileTodayOrYesterdayMarkdownOnly() {
        XCTAssertTrue(BriefingContent.isRecentPackFile(
            "2026-07-20 0930 會後包 standup.md", now: now, calendar: calendar))
        XCTAssertTrue(BriefingContent.isRecentPackFile(
            "2026-07-19 1600 會後包 review.md", now: now, calendar: calendar))
        XCTAssertFalse(BriefingContent.isRecentPackFile(
            "2026-07-18 1600 會後包 old.md", now: now, calendar: calendar))
        XCTAssertFalse(BriefingContent.isRecentPackFile(
            "2026-07-20 0930 會後包 note.txt", now: now, calendar: calendar))
        XCTAssertFalse(BriefingContent.isRecentPackFile(".DS_Store", now: now, calendar: calendar))
    }

    func testBuildAIUserMessageNilWhenNoTasks() {
        XCTAssertNil(BriefingContent.buildAIUserMessage(overdue: [], dueToday: [], noDue: []))
    }

    func testBuildAIUserMessageContainsBucketsAndTitles() throws {
        let message = BriefingContent.buildAIUserMessage(
            overdue: ["補報告"], dueToday: ["回信"], noDue: ["整理桌面"])
        let text = try XCTUnwrap(message)
        XCTAssertTrue(text.contains("【已逾期】"))
        XCTAssertTrue(text.contains("- 補報告"))
        XCTAssertTrue(text.contains("【今天到期】"))
        XCTAssertTrue(text.contains("- 回信"))
        XCTAssertTrue(text.contains("【無期限】"))
        XCTAssertTrue(text.contains("- 整理桌面"))
    }
}

// MARK: - Config round-trip

@MainActor
final class MorningBriefingConfigStoreTests: XCTestCase {

    func testDefaults() {
        let store = MorningBriefingConfigStore(defaults: InMemoryDefaults())
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(store.timeMinutes, 8 * 60 + 30)
        XCTAssertTrue(store.aiSuggestionEnabled)
        XCTAssertNil(store.lastShownDay)
    }

    func testRoundTripThroughSameBackend() {
        let defaults = InMemoryDefaults()
        let store = MorningBriefingConfigStore(defaults: defaults)

        store.setEnabled(false)
        store.setTimeMinutes(7 * 60 + 15)
        store.setAISuggestionEnabled(false)
        store.markShown(day: "2026-07-20")

        let reloaded = MorningBriefingConfigStore(defaults: defaults)
        XCTAssertFalse(reloaded.enabled)
        XCTAssertEqual(reloaded.timeMinutes, 7 * 60 + 15)
        XCTAssertFalse(reloaded.aiSuggestionEnabled)
        XCTAssertEqual(reloaded.lastShownDay, "2026-07-20")
    }

    func testTimeMinutesClampedOnSetAndSanitizedOnLoad() {
        let defaults = InMemoryDefaults()
        let store = MorningBriefingConfigStore(defaults: defaults)
        store.setTimeMinutes(-10)
        XCTAssertEqual(store.timeMinutes, 0)
        store.setTimeMinutes(5000)
        XCTAssertEqual(store.timeMinutes, 1439)

        // 後端殘留範圍外的值(手改 plist)→ 載入時回預設,不讓排程器拿到怪時刻。
        defaults.set(99999, forKey: "morningBriefingTimeMinutesV1")
        let reloaded = MorningBriefingConfigStore(defaults: defaults)
        XCTAssertEqual(reloaded.timeMinutes, MorningBriefingConfigStore.defaultTimeMinutes)
    }
}

// MARK: - 熱鍵同步點

final class MorningBriefingShortcutTests: XCTestCase {

    func testShowMorningBriefingRegisteredInActionLists() {
        // 不在 globalUtilityActions → 熱鍵按了沒反應;不在 legacy 清單 → 衝突偵測雙向隱形。
        XCTAssertTrue(ShortcutAction.globalUtilityActions.contains(.showMorningBriefing))
        XCTAssertTrue(ShortcutAction.legacyKeyboardShortcutActions.contains(.showMorningBriefing))
        XCTAssertEqual(ShortcutAction.showMorningBriefing.storageName, "showMorningBriefing")
        XCTAssertTrue(ShortcutAction.showMorningBriefing.isStored)
    }
}
