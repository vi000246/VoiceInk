import XCTest
@testable import VoiceInk

/// M11 會議開始偵測純狀態機的 AC 測試（AC-70~78）。
/// 注入時鐘/訊號，不碰 CoreAudio / CGWindowList / 真通知 / UserDefaults。
final class MeetingStartDetectorCoreTests: XCTestCase {

    private let teams = "com.microsoft.teams2"
    private let chrome = "com.google.Chrome.helper"   // Chrome 音訊 helper（前綴命中 chrome 家族）

    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func config(
        enabled: Bool = true,
        browsers: Bool = true,
        debounce: Double = 3,
        rearm: Double = 30,
        cooldown: Double = 60
    ) -> MeetingStartDetectorCore.Config {
        .init(enabled: enabled, nativeEnabledBundleIds: [teams], browsersEnabled: browsers,
              debounce: debounce, rearm: rearm, cooldown: cooldown)
    }

    private func alwaysMiss(_ family: MeetingDetectionCatalog.BrowserFamily) -> TitleCheckResult { .miss }
    private func alwaysHit(_ family: MeetingDetectionCatalog.BrowserFamily) -> TitleCheckResult { .hit }
    private func alwaysUnavailable(_ family: MeetingDetectionCatalog.BrowserFamily) -> TitleCheckResult { .unavailable }

    private func promptCount(_ effects: [MeetingStartDetectorCore.Effect]) -> Int {
        effects.filter { if case .prompt = $0 { return true } else { return false } }.count
    }

    // MARK: - AC-70

    func testNativeAppPromptsOnceAfterDebounce() {
        var core = MeetingStartDetectorCore()
        let c = config()
        XCTAssertTrue(core.tick(now: at(0), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss).isEmpty)
        let e3 = core.tick(now: at(3), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss)
        XCTAssertEqual(e3, [.prompt(bundleId: teams, displayName: "Microsoft Teams")])
        XCTAssertTrue(core.tick(now: at(6), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss).isEmpty)
    }

    // MARK: - AC-71

    func testShortBlipNeverPrompts() {
        var core = MeetingStartDetectorCore()
        let c = config()
        _ = core.tick(now: at(0), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss)
        let e3 = core.tick(now: at(3), micBundleIds: [], isRecording: false, config: c, titleCheck: alwaysMiss)
        XCTAssertTrue(e3.isEmpty)
    }

    // MARK: - AC-72

    func testBrowserWaitsForTitleHit() {
        var core = MeetingStartDetectorCore()
        let c = config()
        var calls = 0
        let titleCheck: (MeetingDetectionCatalog.BrowserFamily) -> TitleCheckResult = { _ in
            calls += 1
            return calls < 3 ? .miss : .hit
        }
        // t=0：未過 debounce → titleCheck 不被呼叫。
        XCTAssertTrue(core.tick(now: at(0), micBundleIds: [chrome], isRecording: false, config: c, titleCheck: titleCheck).isEmpty)
        // t=3：第一次 miss → 續等（不 prompt），但記一行 no-title（FR-92 觀測性）。
        XCTAssertEqual(
            core.tick(now: at(3), micBundleIds: [chrome], isRecording: false, config: c, titleCheck: titleCheck),
            [.suppressed(bundleId: chrome, reason: .noTitle)])
        // t=6：第二次 miss → 同 session 不再記 → 零 effect。
        XCTAssertTrue(core.tick(now: at(6), micBundleIds: [chrome], isRecording: false, config: c, titleCheck: titleCheck).isEmpty)
        // t=9：hit → prompt。
        let e9 = core.tick(now: at(9), micBundleIds: [chrome], isRecording: false, config: c, titleCheck: titleCheck)
        XCTAssertEqual(e9, [.prompt(bundleId: chrome, displayName: "Google Chrome")])
        XCTAssertEqual(calls, 3)
    }

    // MARK: - AC-73

    func testNoPermissionDegradesBrowserOnly() {
        var core = MeetingStartDetectorCore()
        let c = config()
        _ = core.tick(now: at(0), micBundleIds: [chrome], isRecording: false, config: c, titleCheck: alwaysUnavailable)
        // Chrome 過 debounce → unavailable → consume + 一則 suppressed(noPermission)。
        let e3 = core.tick(now: at(3), micBundleIds: [chrome], isRecording: false, config: c, titleCheck: alwaysUnavailable)
        XCTAssertEqual(e3, [.suppressed(bundleId: chrome, reason: .noPermission)])
        // Teams 稍晚加入。
        let e6 = core.tick(now: at(6), micBundleIds: [chrome, teams], isRecording: false, config: c, titleCheck: alwaysUnavailable)
        XCTAssertTrue(e6.isEmpty)   // Chrome 已 consumed（不再 suppressed）、Teams 尚未過 debounce
        let e9 = core.tick(now: at(9), micBundleIds: [chrome, teams], isRecording: false, config: c, titleCheck: alwaysUnavailable)
        XCTAssertEqual(e9, [.prompt(bundleId: teams, displayName: "Microsoft Teams")])   // 原生照常
    }

    // MARK: - AC-74

    func testRecordingSuppressesAndConsumes() {
        var core = MeetingStartDetectorCore()
        let c = config()
        // 錄音中：Teams 收音 → consume（一則 suppressed(recording)，零 prompt）。
        let e0 = core.tick(now: at(0), micBundleIds: [teams], isRecording: true, config: c, titleCheck: alwaysMiss)
        XCTAssertEqual(e0, [.suppressed(bundleId: teams, reason: .recording)])
        XCTAssertTrue(core.tick(now: at(3), micBundleIds: [teams], isRecording: true, config: c, titleCheck: alwaysMiss).isEmpty)
        XCTAssertTrue(core.tick(now: at(6), micBundleIds: [teams], isRecording: true, config: c, titleCheck: alwaysMiss).isEmpty)
        // 停錄後 mic 未斷 → 仍不補提示（session 已 consumed）。
        XCTAssertTrue(core.tick(now: at(9), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss).isEmpty)
        XCTAssertTrue(core.tick(now: at(12), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss).isEmpty)
    }

    // MARK: - AC-75

    func testRearmWindowGatesReprompt() {
        var core = MeetingStartDetectorCore()
        // cooldown 設 0 以隔離 rearm 行為（本測試只驗 rearm，不驗全域冷卻）。
        let c = config(cooldown: 0)
        _ = core.tick(now: at(0), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss)
        XCTAssertEqual(promptCount(core.tick(now: at(3), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss)), 1)   // prompt #1

        // mic 停 10s（< rearm 30s）→ 同 session 續存，重開不再提示。
        _ = core.tick(now: at(6), micBundleIds: [], isRecording: false, config: c, titleCheck: alwaysMiss)
        XCTAssertTrue(core.tick(now: at(13), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss).isEmpty)
        XCTAssertTrue(core.tick(now: at(16), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss).isEmpty)

        // mic 停 ≥ rearm（此 tick now-lastSeen=50-16=34 ≥ 30）→ session 被 prune，重開為全新 session。
        XCTAssertTrue(core.tick(now: at(50), micBundleIds: [], isRecording: false, config: c, titleCheck: alwaysMiss).isEmpty)
        XCTAssertTrue(core.tick(now: at(53), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss).isEmpty)   // 新 session pending
        XCTAssertEqual(promptCount(core.tick(now: at(56), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysMiss)), 1)   // prompt #2
    }

    // MARK: - AC-76

    func testGlobalCooldownConsumesConcurrentTrigger() {
        var core = MeetingStartDetectorCore()
        let c = config()   // cooldown 60
        _ = core.tick(now: at(0), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysHit)
        XCTAssertEqual(promptCount(core.tick(now: at(3), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysHit)), 1)   // Teams prompt @ t=3

        // Chrome（title hit）於 t=17 加入、t=20 過 debounce：距上次 prompt 17s < 60 → suppressed(cooldown)。
        _ = core.tick(now: at(17), micBundleIds: [teams, chrome], isRecording: false, config: c, titleCheck: alwaysHit)
        let e20 = core.tick(now: at(20), micBundleIds: [teams, chrome], isRecording: false, config: c, titleCheck: alwaysHit)
        XCTAssertEqual(e20, [.suppressed(bundleId: chrome, reason: .cooldown)])

        // 冷卻過後也不補發：Chrome 持續在線（不 rearm）→ 恆 consumed。
        for s in stride(from: 23.0, through: 66.0, by: 3.0) {
            let e = core.tick(now: at(s), micBundleIds: [teams, chrome], isRecording: false, config: c, titleCheck: alwaysHit)
            XCTAssertEqual(promptCount(e), 0, "t=\(s) 不應補發 prompt")
        }
    }

    // MARK: - AC-77（部分：disabled 早退）

    func testDisabledMeansInert() {
        var core = MeetingStartDetectorCore()
        let c = config(enabled: false)
        XCTAssertTrue(core.tick(now: at(0), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysHit).isEmpty)
        XCTAssertTrue(core.tick(now: at(3), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysHit).isEmpty)
        XCTAssertTrue(core.tick(now: at(6), micBundleIds: [teams], isRecording: false, config: c, titleCheck: alwaysHit).isEmpty)
    }

    // MARK: - AC-78

    func testIgnoresNonAllowlistedProcesses() {
        var core = MeetingStartDetectorCore()
        let c = config()   // native = [teams]，browsers on
        let mic: Set<String> = [
            "com.discord.something",          // 非會議 app，不在任何清單
            "com.prakashjoshipax.VoiceInk",   // 自身 bundle id
            "Cisco-Systems.Spark",            // 在目錄但未啟用（config native 只含 teams）
        ]
        _ = core.tick(now: at(0), micBundleIds: mic, isRecording: false, config: c, titleCheck: alwaysHit)
        let e3 = core.tick(now: at(3), micBundleIds: mic, isRecording: false, config: c, titleCheck: alwaysHit)
        XCTAssertTrue(e3.isEmpty)
        let e6 = core.tick(now: at(6), micBundleIds: mic, isRecording: false, config: c, titleCheck: alwaysHit)
        XCTAssertTrue(e6.isEmpty)
    }
}
