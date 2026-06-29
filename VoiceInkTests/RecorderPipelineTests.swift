import XCTest
@testable import VoiceInk

@MainActor
final class RecorderPipelineTests: XCTestCase {

    private func cats() -> (interview: RecorderCategory, talk: RecorderCategory, fallback: RecorderCategory) {
        let interview = RecorderCategory(name: "面試", classifierDescription: "求職/訪談對話", subfolderName: "Interviews")
        let talk = RecorderCategory(name: "演講", classifierDescription: "單向講座", subfolderName: "Talks")
        let fallback = RecorderCategory.makeFallback()
        return (interview, talk, fallback)
    }

    // MARK: - TokenEstimator
    func testTokenEstimateIsCharsOverFour() {
        XCTAssertEqual(TokenEstimator.estimate(String(repeating: "a", count: 400)), 100)
        XCTAssertEqual(TokenEstimator.estimate(""), 1) // floor
    }

    // MARK: - Classification parsing
    func testParseResolvesKnownCategoryId() {
        let (interview, talk, fallback) = cats()
        let all = [interview, talk, fallback]
        let raw = #"{"categoryId": "\#(interview.id.uuidString)", "confidence": 0.83}"#
        let result = TranscriptClassificationService.shared.parse(raw, categories: all)
        XCTAssertEqual(result.categoryId, interview.id)
        XCTAssertEqual(result.confidence, 0.83, accuracy: 0.0001)
    }

    func testParseUncertainYieldsNilId() {
        let (interview, talk, fallback) = cats()
        let result = TranscriptClassificationService.shared.parse(
            #"{"categoryId": "uncertain", "confidence": 0.2}"#, categories: [interview, talk, fallback])
        XCTAssertNil(result.categoryId)
    }

    func testParseUnknownIdYieldsNilButKeepsConfidence() {
        let (interview, talk, fallback) = cats()
        let result = TranscriptClassificationService.shared.parse(
            #"{"categoryId": "\#(UUID().uuidString)", "confidence": 0.4}"#, categories: [interview, talk, fallback])
        XCTAssertNil(result.categoryId)
        XCTAssertEqual(result.confidence, 0.4, accuracy: 0.0001)
    }

    func testParseGarbageYieldsUncertain() {
        let (interview, _, fallback) = cats()
        XCTAssertEqual(TranscriptClassificationService.shared.parse("not json", categories: [interview, fallback]), .uncertain)
    }

    // MARK: - TemplateRouter
    func testRouterUsesCategoryWhenConfident() {
        let (interview, talk, fallback) = cats()
        let decision = TemplateRouter.route(
            result: ClassificationResult(categoryId: interview.id, confidence: 0.9),
            categories: [interview, talk, fallback], prompts: [], confidenceFloor: 0.5)
        XCTAssertEqual(decision.category.id, interview.id)
        XCTAssertFalse(decision.usedFallback)
    }

    func testRouterFallsBackOnUncertain() {
        let (interview, talk, fallback) = cats()
        let decision = TemplateRouter.route(
            result: .uncertain, categories: [interview, talk, fallback], prompts: [], confidenceFloor: 0.5)
        XCTAssertTrue(decision.category.isFallback)
        XCTAssertTrue(decision.usedFallback)
    }

    func testRouterFallsBackBelowConfidenceFloor() {
        let (interview, talk, fallback) = cats()
        let decision = TemplateRouter.route(
            result: ClassificationResult(categoryId: interview.id, confidence: 0.3),
            categories: [interview, talk, fallback], prompts: [], confidenceFloor: 0.5)
        XCTAssertTrue(decision.category.isFallback)
    }

    func testRouterBindsPrompt() {
        let prompt = CustomPrompt(title: "面試分析", promptText: "...")
        var interview = RecorderCategory(name: "面試", subfolderName: "Interviews")
        interview.customPromptId = prompt.id
        let fallback = RecorderCategory.makeFallback()
        let decision = TemplateRouter.route(
            result: ClassificationResult(categoryId: interview.id, confidence: 0.9),
            categories: [interview, fallback], prompts: [prompt], confidenceFloor: 0.5)
        XCTAssertEqual(decision.prompt?.id, prompt.id)
    }

    // MARK: - VaultExportService
    func testBuildMarkdownHasFrontmatterAndCollapsibleRaw() {
        let input = VaultExportService.ExportInput(
            analysis: "## 重點\n- A", rawTranscript: "line one\nline two",
            categoryName: "演講", deviceName: "IC RECORDER", date: Date(timeIntervalSince1970: 0),
            transcriptionModel: "whisper", enhancementModel: "claude", confidence: 0.91)
        let md = VaultExportService.shared.buildMarkdown(input)
        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("category: \"演講\""))
        XCTAssertTrue(md.contains("confidence: 0.91"))
        XCTAssertTrue(md.contains("> [!note]- 原始逐字稿"))
        XCTAssertTrue(md.contains("> line one"))
        XCTAssertTrue(md.contains("> line two"))
    }

    func testSuggestedFileNameSanitizes() {
        let name = VaultExportService.shared.suggestedFileName(
            date: Date(timeIntervalSince1970: 0), categoryName: "a/b", deviceName: "x:y")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix(".md"))
    }

    // MARK: - LongTranscriptSummarizer chunking
    func testChunksRespectMaxSize() {
        let s = LongTranscriptSummarizer.shared
        let long = String(repeating: "word ", count: 6000) // 30k chars
        let parts = s.chunks(long)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= s.maxCharsPerChunk })
    }

    func testShortTextIsSingleChunkAndNotSummarized() {
        let s = LongTranscriptSummarizer.shared
        XCTAssertEqual(s.chunks("hello"), ["hello"])
        XCTAssertFalse(s.needsSummarization("hello"))
    }
}
