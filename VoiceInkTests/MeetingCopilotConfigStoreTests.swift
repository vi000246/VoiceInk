import XCTest
@testable import VoiceInk

@MainActor
final class MeetingCopilotConfigStoreTests: XCTestCase {

    /// 每個測試一份隔離的 UserDefaults（見 TestDefaults.swift）——測試不得寫 `.standard`。
    ///
    /// 取代了原本「setUp 備份 `.standard` 的 13 個 key、tearDown 還原」的做法:那個做法擋得住
    /// **同一個 process 內**的殘留,擋不住 `parallelizable = YES` 下**別的 process** 在你斷言
    /// 「未設定 → 預設值」的同一瞬間寫進同一個 domain（2026-07-14 就是這樣紅的:
    /// `MeetingReplayReviewTests` 寫 `useNotesRAG = false`,這裡的
    /// `testNotesRAGSettingsRoundTrip` 剛好讀到）。隔離 suite 讓這條路整個消失。
    private let defaultsSuite = InMemoryDefaults()

    func testM2FieldDefaultsAndPersistence() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertNil(store.fastProviderName, "未設定 → nil = 跟隨預設 provider")
        XCTAssertNil(store.fastModelName)
        XCTAssertFalse(store.showInformationalCues, "FR-11:informational 預設隱藏")

        store.setFastModel(provider: "openai", model: "gpt-4o-mini")
        store.setShowInformationalCues(true)

        // 新實例重新 load() → 值來自 UserDefaults。
        let reloaded = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertEqual(reloaded.fastProviderName, "openai")
        XCTAssertEqual(reloaded.fastModelName, "gpt-4o-mini")
        XCTAssertTrue(reloaded.showInformationalCues)

        // 清空 = removeObject(nil 語意,鏡射 RecorderConfigStore.persistString)。
        store.setFastModel(provider: nil, model: nil)
        XCTAssertNil(MeetingCopilotConfigStore(defaults: defaultsSuite).fastProviderName)
        XCTAssertNil(defaultsSuite.object(forKey: "meetingCopilotFastProviderV1"))
    }

    /// M8 AC-33:aboutMe tier prompt 注入的自介。未設定 → 空字串(prompt 略過該行)。
    func testAboutMeBriefRoundTrip() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertEqual(store.aboutMeBrief, "", "未設定 → 空 = prompt 不插自介行")

        store.setAboutMeBrief("後端工程師,主力專案A")
        XCTAssertEqual(MeetingCopilotConfigStore(defaults: defaultsSuite).aboutMeBrief, "後端工程師,主力專案A")
    }

    /// M8 Task 7:筆記 RAG 的**消費開關**(是否檢索筆記／技術題是否混用)＋自介 round-trip。
    ///
    /// FR-6:include/exclude **資料夾清單**已搬到 `ObsidianRAGConfigStore`(管線設定的單一權威),
    /// 對應斷言隨之搬到 `ObsidianRAGConfigStoreTests`——這裡只留 meeting-copilot 自己還擁有的欄位。
    func testNotesRAGSettingsRoundTrip() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertTrue(store.useNotesRAG, "預設開:被問到自己的經歷時,筆記是唯一有答案的來源")
        XCTAssertFalse(store.notesInTechnicalRAG, "預設關:技術答案不被個人筆記污染")

        store.setUseNotesRAG(false)
        store.setNotesInTechnicalRAG(true)
        store.setAboutMeBrief("後端工程師")

        let reloaded = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertFalse(reloaded.useNotesRAG)
        XCTAssertTrue(reloaded.notesInTechnicalRAG)
        XCTAssertEqual(reloaded.aboutMeBrief, "後端工程師")
    }

    /// M8 Task 9:auto-deep 開關 round-trip。未設定 → **true**(會議中手點 Tier 2 根本做不到)。
    func testAutoDeepEnabledRoundTrip() {
        XCTAssertTrue(MeetingCopilotConfigStore(defaults: defaultsSuite).autoDeepEnabled, "未設定 → 預設開")

        MeetingCopilotConfigStore(defaults: defaultsSuite).setAutoDeepEnabled(false)
        XCTAssertFalse(MeetingCopilotConfigStore(defaults: defaultsSuite).autoDeepEnabled, "關掉要留得住(false ≠ 沒設定)")

        MeetingCopilotConfigStore(defaults: defaultsSuite).setAutoDeepEnabled(true)
        XCTAssertTrue(MeetingCopilotConfigStore(defaults: defaultsSuite).autoDeepEnabled)
    }

    /// M8 D 組:即時翻譯設定 round-trip(開關＋雙欄 model＋來源/目標語言)。
    func testTranslationSettingsRoundTrip() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        store.setLiveTranslationEnabled(true)
        store.setTranslationModel(provider: "groq", model: "llama-3.1-8b-instant")
        store.setTranslationLanguages(source: "auto", target: "zh-TW")

        let reloaded = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertTrue(reloaded.liveTranslationEnabled)
        XCTAssertEqual(reloaded.translationProviderName, "groq")
        XCTAssertEqual(reloaded.translationModelName, "llama-3.1-8b-instant")
        XCTAssertEqual(reloaded.translationSourceLanguage, "auto")
        XCTAssertEqual(reloaded.translationTargetLanguage, "zh-TW")

        // 清空 = removeObject(nil 語意,同 setFastModel)。
        store.setTranslationModel(provider: nil, model: nil)
        XCTAssertNil(MeetingCopilotConfigStore(defaults: defaultsSuite).translationProviderName)
        XCTAssertNil(defaultsSuite.object(forKey: "meetingCopilotTranslationProviderV1"))
    }

    /// AC-47:翻譯**預設關**——每段一次額外 LLM 呼叫,單語會議純屬浪費。
    /// 語言預設 auto → 繁中(混語會議不假設輸入語言)。
    func testTranslationDefaults() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertFalse(store.liveTranslationEnabled, "未設定 → 關(零 API 呼叫)")
        XCTAssertNil(store.translationProviderName, "未設定 → nil = 跟隨預設 provider")
        XCTAssertNil(store.translationModelName)
        XCTAssertEqual(store.translationSourceLanguage, "auto")
        XCTAssertEqual(store.translationTargetLanguage, "zh-TW")
    }

    /// M9 FR-73 / AC-58:深答風格**預設條列式**——現行段落式分析在會議中讀不完,
    /// 這是刻意的行為變更(不是 detailed 保守預設)。並且要能持久化 round-trip。
    func testDeepStyleDefaultsToBulletsAndRoundTrips() {
        XCTAssertEqual(MeetingCopilotConfigStore(defaults: defaultsSuite).deepStyle, .bullets, "預設條列式＝本需求的目的")

        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        store.setDeepStyle(.detailed)
        XCTAssertEqual(MeetingCopilotConfigStore(defaults: defaultsSuite).deepStyle, .detailed, "round-trip")

    }

    // MARK: - Prompt 設定(2026-07-15 可調 prompt)

    /// 風格守則預設 = 內建守則(軟體+個人專案範圍、口語淺白);可 round-trip、可清空。
    func testAnswerStyleGuidanceDefaultsAndRoundTrips() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertEqual(store.answerStyleGuidance, MeetingCopilotConfigStore.defaultAnswerStyleGuidance,
                       "未設定 → 內建守則(限定軟體+個人專案、口語淺白)")

        store.setAnswerStyleGuidance("只講白話")
        XCTAssertEqual(MeetingCopilotConfigStore(defaults: defaultsSuite).answerStyleGuidance, "只講白話", "round-trip")

        // 明確清空 = 不注入(power user 完全放開),不可被當成「未設定」而彈回預設。
        store.setAnswerStyleGuidance("")
        XCTAssertEqual(MeetingCopilotConfigStore(defaults: defaultsSuite).answerStyleGuidance, "",
                       "清空是刻意的意圖,reload 後仍為空")
    }

    /// 分類器 prompt 覆寫:空 → 用內建預設;非空 → 完整取代。effectiveCuePrompt 據此切換。
    func testCuePromptOverrideRoundTripAndEffective() {
        let store = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertEqual(store.cuePromptOverride, "", "未設定 → 空 = 用內建預設")
        XCTAssertEqual(store.effectiveCuePrompt, ResponseCueExtractor.systemPrompt, "空覆寫 → 內建分類器 prompt")

        store.setCuePromptOverride("自訂分類器")
        let reloaded = MeetingCopilotConfigStore(defaults: defaultsSuite)
        XCTAssertEqual(reloaded.cuePromptOverride, "自訂分類器", "round-trip")
        XCTAssertEqual(reloaded.effectiveCuePrompt, "自訂分類器", "非空 → 完整取代")
    }
}
