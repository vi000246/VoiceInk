import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class MeetingCopilotControllerTests: XCTestCase {

    private let keys = [
        "meetingCopilotEnabledV1",
        "meetingCopilotShowInformationalCuesV1",
    ]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for k in keys {
            saved[k] = UserDefaults.standard.object(forKey: k)
            UserDefaults.standard.removeObject(forKey: k)
        }
    }

    override func tearDown() {
        for k in keys {
            if let v = saved[k] ?? nil { UserDefaults.standard.set(v, forKey: k) }
            else { UserDefaults.standard.removeObject(forKey: k) }
        }
        super.tearDown()
    }

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// AC-4:30 秒窗內兩句相似 committed → 只 persist 一則 cue。
    func testDedupesSimilarCuesWithinWindow() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        defer { config.setCopilotEnabled(false) }

        let fake = KeyedFakeChatCompleting(routes: [
            ("一個 rate limiter",
             #"{"cues":[{"text":"你會怎麼設計一個 rate limiter？","kind":"directQuestion"}]}"#),
            ("rate limiter",
             #"{"cues":[{"text":"你會怎麼設計 rate limiter？","kind":"directQuestion"}]}"#),
        ])
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)
        controller.beginSession(appName: "test")

        controller.handleRemoteCommitted("你會怎麼設計 rate limiter？")
        await controller.drainInflight()
        controller.handleRemoteCommitted("你會怎麼設計一個 rate limiter？")
        await controller.drainInflight()

        let persisted = try ctx.fetch(FetchDescriptor<MeetingLiveCue>())
        XCTAssertEqual(persisted.count, 1, "相似 cue 應被去重,只 persist 第一則")
        XCTAssertEqual(controller.cues.count, 1)
        XCTAssertEqual(fake.callCount, 2, "去重在 persist 層,抽取仍每 committed 一次")
    }

    /// AC-5:informational persist 但預設不暴露;打開開關後出現。
    func testInformationalPersistedButHiddenByDefault() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(true)
        defer { config.setCopilotEnabled(false) }
        XCTAssertFalse(config.showInformationalCues)

        let fake = FakeChatCompleting(
            reply: #"{"cues":[{"text":"我們上週上線了 v2","kind":"informational"}]}"#)
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)
        controller.beginSession(appName: "test")

        controller.handleRemoteCommitted("我們上週上線了 v2")
        await controller.drainInflight()

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 1,
                       "informational 仍要 persist(事後可回顧)")
        XCTAssertTrue(controller.cues.isEmpty, "預設不納入 @Published 暴露面")

        config.setShowInformationalCues(true)
        controller.refreshPublishedCues()
        XCTAssertEqual(controller.cues.count, 1, "打開開關後即暴露")
    }

    /// AC-9:kill switch——extractor 未被呼叫、store 無新 cue、cues 為空。
    func testDisabledCopilotExtractsNothing() async throws {
        let ctx = try makeContext()
        let config = MeetingCopilotConfigStore()
        config.setCopilotEnabled(false)

        let fake = FakeChatCompleting(
            reply: #"{"cues":[{"text":"x?","kind":"directQuestion"}]}"#)
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: fake),
            config: config, modelContext: ctx)

        controller.beginSession(appName: "test")   // no-op
        controller.handleRemoteCommitted("你會怎麼設計 rate limiter？")
        await controller.drainInflight()

        XCTAssertEqual(fake.callCount, 0, "關閉時 ResponseCueExtractor 不得被呼叫")
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSession>()).count, 0,
                       "關閉時連 session 都不建")
        XCTAssertTrue(controller.cues.isEmpty)
    }
}
