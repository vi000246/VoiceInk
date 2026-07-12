import XCTest
import SwiftData
@testable import VoiceInk

@MainActor
final class MeetingLiveModelsTests: XCTestCase {

    /// in-memory container(房子風格:AskAIAnswerTests.makeContext)。
    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    /// AC-6:刪 session → cascade 刪全部 cue,無孤兒。
    func testDeletingSessionCascadesCues() throws {
        let ctx = try makeContext()
        let session = MeetingLiveSession(appName: "teams")
        ctx.insert(session)
        for i in 0..<3 {
            ctx.insert(MeetingLiveCue(
                session: session, text: "cue \(i)", kind: .directQuestion))
        }
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 3)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveSession>()).first?.cues?.count, 3)

        ctx.delete(session)
        try ctx.save()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0,
                       ".cascade 應連帶刪除全部 cue")
    }

    /// String-in-raw 列舉:round-trip + 未知值回退不崩(向前相容)。
    func testKindRoundTripsAndUnknownFallsBack() {
        let cue = MeetingLiveCue(session: nil, text: "x", kind: .assignedToMe)
        XCTAssertEqual(cue.kindRaw, "assignedToMe")
        XCTAssertEqual(cue.kind, .assignedToMe)

        cue.kind = .impliedChallenge
        XCTAssertEqual(cue.kindRaw, "impliedChallenge")

        cue.kindRaw = "somethingFromTheFuture"
        XCTAssertEqual(cue.kind, .informational, "未知 kind 回退 informational,不崩")
    }

    /// status 預設 detected。
    func testStatusDefaultsToDetected() {
        let cue = MeetingLiveCue(session: nil, text: "x", kind: .directQuestion)
        XCTAssertEqual(cue.status, .detected)
    }

    /// tier 陣列欄位(M2 宣告不寫入):JSON round-trip + 壞 JSON 回空。
    func testTierArrayAccessorsRoundTripAndTolerateGarbage() {
        let cue = MeetingLiveCue(session: nil, text: "x", kind: .directQuestion)
        XCTAssertEqual(cue.tier1Bullets, [], "預設空")

        cue.tier1Bullets = ["重點一", "重點二", "重點三"]
        XCTAssertEqual(cue.tier1Bullets, ["重點一", "重點二", "重點三"])
        XCTAssertFalse(cue.tier1BulletsRaw.isEmpty)

        cue.tier2FollowUpsRaw = "這不是 JSON"
        XCTAssertEqual(cue.tier2FollowUps, [], "壞 JSON 靜默回空,不崩")
    }
}
