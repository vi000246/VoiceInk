import XCTest
@testable import VoiceInk

/// 即時字幕翻譯(M8 D 組)。
///
/// 本檔的 golden test 鎖住翻譯 prompt 的三個核心指示——混語照譯、同語言原樣輸出、
/// 只輸出譯文。這三句就是翻譯品質的全部:任何一句被改掉,字幕就會開始出現
/// 「這句話的意思是…」之類的解釋文、或把已經是中文的句子硬翻一次(AC-45)。
final class MeetingTranslationTests: XCTestCase {

    // MARK: - AC-45:翻譯 prompt(純函式)

    /// source="auto"(混語會議的預設):prompt 不假設輸入語言,且要求同語言原樣輸出。
    func testPromptAutoDetectAndSameLanguagePassthrough() {
        let (system, user) = MeetingTranslationPrompt.build(
            text: "Let's discuss the cache design.", sourceLanguage: "auto", targetLanguage: "zh-TW")
        XCTAssertTrue(system.contains("無論輸入"), "混語(中英夾雜)會議:不可假設輸入語言")
        XCTAssertTrue(system.contains("繁體中文"), "目標語言要以人類看得懂的語言名出現")
        XCTAssertTrue(system.contains("原樣輸出"), "已是目標語言 → 不要硬翻")
        XCTAssertTrue(system.contains("只輸出"), "不要解釋、不要引號、不要標註語言")
        XCTAssertTrue(user.contains("cache design"), "user = 原文本身")
    }

    /// 明確指定來源語言時,prompt 要帶上來源提示(auto 時不帶)。
    func testPromptCarriesExplicitSourceHint() {
        let (system, _) = MeetingTranslationPrompt.build(
            text: "x", sourceLanguage: "en", targetLanguage: "zh-TW")
        XCTAssertTrue(system.contains("en"), "指定 source 時 prompt 要帶來源語言提示")
    }

    /// 語言碼 → 人類語言名;未知碼原樣返回(不崩、不硬轉)。
    func testTargetLanguageDisplayName() {
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "zh-TW"), "繁體中文")
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "zh-CN"), "简体中文")
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "en"), "English")
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "ja"), "日本語")
        XCTAssertEqual(MeetingTranslationPrompt.displayName(for: "xx-YY"), "xx-YY", "未知碼原樣返回")
    }
}
