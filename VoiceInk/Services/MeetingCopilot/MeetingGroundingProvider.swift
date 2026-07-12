import Foundation
import SwiftData

/// 螢幕擷取的可注入介面(測試注入 fake;正式為 `ScreenCaptureService`)。
protocol MeetingScreenCapturing: AnyObject {
    func captureAndExtractText() async -> String?
}

extension ScreenCaptureService: MeetingScreenCapturing {}

/// 答案接地(FR-18/19/20):brief + 歷史逐字稿 RAG + 分享畫面 OCR。**全部靜默降級**。
///
/// # 為什麼直呼底層,不走 `AskAIService.ask`(canon §3.2 / M3 SRS)
/// `AskAIService.ask()` 在空索引/embed 失敗時會 **persist 一則可見診斷 `AskAIMessage`** 到聊天 UI。
/// M3 改為直呼 `LiveEmbedder().embed` + `RetrievalService.retrieve`:
/// - `RetrievalService.retrieve` 空索引回 `[]`,**不 throw**;
/// - `embed` 無 key 時 throw `EmbeddingError.missingAPIKey`——包在自己的 do/catch 內吞掉回無接地。
///
/// # 螢幕 OCR(FR-20)
/// `captureAndExtractText()` 每個失敗路徑都回 nil(silent-nil,正好滿足「失敗靜默」)。
/// **只在 Tier 2 呼叫一次**(caller 傳 `includeScreen`)——不拖慢 Tier 0/1 首字延遲。
/// 持有**單一** `ScreenCaptureService` 實例:`isCapturing` reentrancy guard 是 per-instance。
@MainActor
final class MeetingGroundingProvider {

    private let embedder: EmbeddingProviding
    private let screen: MeetingScreenCapturing
    private let modelContext: ModelContext
    private let ragK: Int

    init(
        embedder: EmbeddingProviding = LiveEmbedder(),
        screen: MeetingScreenCapturing,
        modelContext: ModelContext,
        ragK: Int = 6
    ) {
        self.embedder = embedder
        self.screen = screen
        self.modelContext = modelContext
        self.ragK = ragK
    }

    /// 組接地快照。任何來源失敗都靜默(回空),不阻斷答案。
    /// - Parameters:
    ///   - includeRAG: 通常 = `config.useHistoryRAG`
    ///   - includeScreen: 通常 Tier 2 才為 true(= `config.useScreenContext`)
    func gather(cueText: String, brief: String, includeRAG: Bool, includeScreen: Bool) async -> MeetingGrounding {
        var ragExcerpts: [String] = []

        if includeRAG {
            let model = TranscriptIndexService.shared.model
            do {
                let vectors = try await embedder.embed(texts: [cueText], model: model)
                if let vector = vectors.first {
                    // retrieve 為 @MainActor 同步;本類已在 @MainActor,直接呼叫。
                    // scope = .all:個人會議即時場景,搜全部歷史(含 dictation/recorder/meeting)最大召回。
                    let scored = RetrievalService.retrieve(
                        queryVector: vector, scope: .all, k: ragK,
                        model: model, context: modelContext)
                    ragExcerpts = scored.map { String($0.chunk.text.prefix(800)) }
                }
            } catch {
                // 無 embedding key / 網路失敗 → 靜默,回無 RAG 接地(FR-19)。
                ragExcerpts = []
            }
        }

        var screenText: String?
        if includeScreen {
            // silent-nil:每個失敗路徑都回 nil,無需額外處理(FR-20)。
            screenText = await screen.captureAndExtractText()
        }

        return MeetingGrounding(brief: brief, ragExcerpts: ragExcerpts, screenText: screenText)
    }
}
