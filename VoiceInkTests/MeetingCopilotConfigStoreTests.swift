import XCTest
@testable import VoiceInk

@MainActor
final class MeetingCopilotConfigStoreTests: XCTestCase {

    private let keys = [
        "meetingCopilotFastProviderV1",
        "meetingCopilotFastModelV1",
        "meetingCopilotShowInformationalCuesV1",
        "meetingCopilotAboutMeBriefV1",
        "meetingCopilotUseNotesRAGV1",
        "meetingCopilotNotesInTechnicalRAGV1",
        "meetingCopilotAutoDeepV1",
        "meetingCopilotLiveTranslationV1",
        "meetingCopilotTranslationProviderV1",
        "meetingCopilotTranslationModelV1",
        "meetingCopilotTranslationSourceV1",
        "meetingCopilotTranslationTargetV1",
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

    func testM2FieldDefaultsAndPersistence() {
        let store = MeetingCopilotConfigStore()
        XCTAssertNil(store.fastProviderName, "未設定 → nil = 跟隨預設 provider")
        XCTAssertNil(store.fastModelName)
        XCTAssertFalse(store.showInformationalCues, "FR-11:informational 預設隱藏")

        store.setFastModel(provider: "openai", model: "gpt-4o-mini")
        store.setShowInformationalCues(true)

        // 新實例重新 load() → 值來自 UserDefaults。
        let reloaded = MeetingCopilotConfigStore()
        XCTAssertEqual(reloaded.fastProviderName, "openai")
        XCTAssertEqual(reloaded.fastModelName, "gpt-4o-mini")
        XCTAssertTrue(reloaded.showInformationalCues)

        // 清空 = removeObject(nil 語意,鏡射 RecorderConfigStore.persistString)。
        store.setFastModel(provider: nil, model: nil)
        XCTAssertNil(MeetingCopilotConfigStore().fastProviderName)
        XCTAssertNil(UserDefaults.standard.object(forKey: "meetingCopilotFastProviderV1"))
    }

    /// M8 AC-33:aboutMe tier prompt 注入的自介。未設定 → 空字串(prompt 略過該行)。
    func testAboutMeBriefRoundTrip() {
        let store = MeetingCopilotConfigStore()
        XCTAssertEqual(store.aboutMeBrief, "", "未設定 → 空 = prompt 不插自介行")

        store.setAboutMeBrief("後端工程師,主力專案A")
        XCTAssertEqual(MeetingCopilotConfigStore().aboutMeBrief, "後端工程師,主力專案A")
    }

    /// M8 Task 7:筆記 RAG 的**消費開關**(是否檢索筆記／技術題是否混用)＋自介 round-trip。
    ///
    /// FR-6:include/exclude **資料夾清單**已搬到 `ObsidianRAGConfigStore`(管線設定的單一權威),
    /// 對應斷言隨之搬到 `ObsidianRAGConfigStoreTests`——這裡只留 meeting-copilot 自己還擁有的欄位。
    func testNotesRAGSettingsRoundTrip() {
        let store = MeetingCopilotConfigStore()
        XCTAssertTrue(store.useNotesRAG, "預設開:被問到自己的經歷時,筆記是唯一有答案的來源")
        XCTAssertFalse(store.notesInTechnicalRAG, "預設關:技術答案不被個人筆記污染")

        store.setUseNotesRAG(false)
        store.setNotesInTechnicalRAG(true)
        store.setAboutMeBrief("後端工程師")

        let reloaded = MeetingCopilotConfigStore()
        XCTAssertFalse(reloaded.useNotesRAG)
        XCTAssertTrue(reloaded.notesInTechnicalRAG)
        XCTAssertEqual(reloaded.aboutMeBrief, "後端工程師")
    }

    /// M8 Task 9:auto-deep 開關 round-trip。未設定 → **true**(會議中手點 Tier 2 根本做不到)。
    func testAutoDeepEnabledRoundTrip() {
        XCTAssertTrue(MeetingCopilotConfigStore().autoDeepEnabled, "未設定 → 預設開")

        MeetingCopilotConfigStore().setAutoDeepEnabled(false)
        XCTAssertFalse(MeetingCopilotConfigStore().autoDeepEnabled, "關掉要留得住(false ≠ 沒設定)")

        MeetingCopilotConfigStore().setAutoDeepEnabled(true)
        XCTAssertTrue(MeetingCopilotConfigStore().autoDeepEnabled)
    }

    /// M8 D 組:即時翻譯設定 round-trip(開關＋雙欄 model＋來源/目標語言)。
    func testTranslationSettingsRoundTrip() {
        let store = MeetingCopilotConfigStore()
        store.setLiveTranslationEnabled(true)
        store.setTranslationModel(provider: "groq", model: "llama-3.1-8b-instant")
        store.setTranslationLanguages(source: "auto", target: "zh-TW")

        let reloaded = MeetingCopilotConfigStore()
        XCTAssertTrue(reloaded.liveTranslationEnabled)
        XCTAssertEqual(reloaded.translationProviderName, "groq")
        XCTAssertEqual(reloaded.translationModelName, "llama-3.1-8b-instant")
        XCTAssertEqual(reloaded.translationSourceLanguage, "auto")
        XCTAssertEqual(reloaded.translationTargetLanguage, "zh-TW")

        // 清空 = removeObject(nil 語意,同 setFastModel)。
        store.setTranslationModel(provider: nil, model: nil)
        XCTAssertNil(MeetingCopilotConfigStore().translationProviderName)
        XCTAssertNil(UserDefaults.standard.object(forKey: "meetingCopilotTranslationProviderV1"))
    }

    /// AC-47:翻譯**預設關**——每段一次額外 LLM 呼叫,單語會議純屬浪費。
    /// 語言預設 auto → 繁中(混語會議不假設輸入語言)。
    func testTranslationDefaults() {
        let store = MeetingCopilotConfigStore()
        XCTAssertFalse(store.liveTranslationEnabled, "未設定 → 關(零 API 呼叫)")
        XCTAssertNil(store.translationProviderName, "未設定 → nil = 跟隨預設 provider")
        XCTAssertNil(store.translationModelName)
        XCTAssertEqual(store.translationSourceLanguage, "auto")
        XCTAssertEqual(store.translationTargetLanguage, "zh-TW")
    }
}
