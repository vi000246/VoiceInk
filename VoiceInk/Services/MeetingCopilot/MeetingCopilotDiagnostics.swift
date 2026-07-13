import Foundation
import SwiftData

// MARK: - 執行設定快照

/// 一場 live session 的執行設定快照(persist 到 `MeetingLiveSession.configSnapshotRaw`)。
///
/// 調校迴圈的前提是「知道當時的變因」:模型、開關、persona、prompt、去重參數都會隨時間改,
/// UserDefaults 只有「現在值」。**system prompt 全文也存**——它們是 repo 內會被調校的常數,
/// 快照必須自足,不能假設程式碼沒改過。
struct MeetingCopilotRunConfig: Codable, Equatable {
    var capturedAt: Date = Date()
    var appBuild: String = ""
    var asrModel: String = ""
    var asrLanguage: String = ""
    var transcribeLocalMic: Bool = true
    /// "provider/model"。cue 抽取與 Tier 1 用同一顆 fast model。
    var fastModel: String = ""
    var deepModel: String = ""
    var prefetchEnabled: Bool = true
    var useHistoryRAG: Bool = false
    var useScreenContext: Bool = false
    var showInformationalCues: Bool = false
    var domainPersona: String = ""
    var dedupThreshold: Double = 0
    var dedupWindowSeconds: Double = 0
    var cueSystemPrompt: String = ""
    var tier1SystemPrompt: String = ""
    var tier2SystemPrompt: String = ""

    /// 從目前設定組快照。`fastModelLabel`/`deepModelLabel` 由呼叫端解析
    /// (需要 AIService 的 connected providers,config store 本身不知道)。
    @MainActor
    static func capture(
        config: MeetingCopilotConfigStore,
        asrModelDisplayName: String,
        fastModelLabel: String,
        deepModelLabel: String
    ) -> MeetingCopilotRunConfig {
        MeetingCopilotRunConfig(
            appBuild: (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "",
            asrModel: asrModelDisplayName,
            asrLanguage: config.asrLanguage,
            transcribeLocalMic: config.transcribeLocalMic,
            fastModel: fastModelLabel,
            deepModel: deepModelLabel,
            prefetchEnabled: config.prefetchEnabled,
            useHistoryRAG: config.useHistoryRAG,
            useScreenContext: config.useScreenContext,
            showInformationalCues: config.showInformationalCues,
            domainPersona: config.domainPersona,
            dedupThreshold: MeetingCueDeduplicator.defaultThreshold,
            dedupWindowSeconds: MeetingCueDeduplicator.defaultWindow,
            cueSystemPrompt: ResponseCueExtractor.systemPrompt,
            tier1SystemPrompt: TierPrompts.tier1System(persona: config.domainPersona),
            tier2SystemPrompt: TierPrompts.tier2System(persona: config.domainPersona))
    }

    func encodedJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func decode(_ raw: String) -> MeetingCopilotRunConfig? {
        guard let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingCopilotRunConfig.self, from: data)
    }
}

// MARK: - Session 診斷匯出

/// 一場 session 的完整診斷 dump(JSON)——調校迴圈的交換格式:
/// 逐字稿時間軸 + 每段的抽取 provenance + 每則 cue 的三層 prompt/回覆/耗時/錯誤 + 設定快照。
/// 匯出檔可直接餵給 LLM 做「漏抓/誤抓/答非所問」分析。
struct MeetingSessionDiagnostics: Codable {

    struct Segment: Codable {
        var id: UUID
        var channel: String
        var committedAt: Date
        var text: String
        var recentContext: String
        var extractionModel: String
        var extractionReplyRaw: String
        var extractionElapsedMs: Int
        var extractedCount: Int
        var dedupDroppedCount: Int
        var extractionError: String
    }

    struct Cue: Codable {
        var id: UUID
        var text: String
        var kind: String
        var status: String
        var askedAt: Date
        var contextExcerpt: String
        var sourceSegmentId: UUID?
        var detectionElapsedMs: Int
        var tier0Keywords: String
        var fastModelName: String
        var tier1Opener: String
        var tier1Bullets: [String]
        var tier1PromptUser: String
        var tier1RawReply: String
        var tier1ElapsedMs: Int
        var tier1At: Date?
        var tier1Error: String
        var tier1GroundingNote: String
        var deepModelName: String
        var tier2Analysis: String
        var tier2FollowUps: [String]
        var tier2Uncertainties: [String]
        var tier2PromptUser: String
        var tier2RawReply: String
        var tier2GroundingElapsedMs: Int
        var tier2StreamElapsedMs: Int
        var tier2Error: String
        var tier2GroundingNote: String
        var answeredAt: Date?
    }

    var exportedAt: Date
    var sessionId: UUID
    var appName: String
    var startedAt: Date
    var endedAt: Date?
    var brief: String
    /// 解碼成功時為結構化快照;失敗(未來 schema 改動)退回 `configRaw` 原文。
    var config: MeetingCopilotRunConfig?
    var configRaw: String?
    var remoteTranscript: String
    var localTranscript: String
    var segments: [Segment]
    var cues: [Cue]

    @MainActor
    static func build(from session: MeetingLiveSession) -> MeetingSessionDiagnostics {
        let decodedConfig = MeetingCopilotRunConfig.decode(session.configSnapshotRaw)
        let segments = (session.segments ?? [])
            .sorted { $0.committedAt < $1.committedAt }
            .map { s in
                Segment(
                    id: s.id, channel: s.channelRaw, committedAt: s.committedAt, text: s.text,
                    recentContext: s.recentContext, extractionModel: s.extractionModel,
                    extractionReplyRaw: s.extractionReplyRaw, extractionElapsedMs: s.extractionElapsedMs,
                    extractedCount: s.extractedCount, dedupDroppedCount: s.dedupDroppedCount,
                    extractionError: s.extractionError)
            }
        let cues = (session.cues ?? [])
            .sorted { $0.askedAt < $1.askedAt }
            .map { c in
                Cue(
                    id: c.id, text: c.text, kind: c.kindRaw, status: c.statusRaw,
                    askedAt: c.askedAt, contextExcerpt: c.contextExcerpt,
                    sourceSegmentId: c.sourceSegmentId, detectionElapsedMs: c.detectionElapsedMs,
                    tier0Keywords: c.tier0Keywords,
                    fastModelName: c.fastModelName,
                    tier1Opener: c.tier1Opener, tier1Bullets: c.tier1Bullets,
                    tier1PromptUser: c.tier1PromptUser, tier1RawReply: c.tier1RawReply,
                    tier1ElapsedMs: c.tier1ElapsedMs, tier1At: c.tier1At,
                    tier1Error: c.tier1Error, tier1GroundingNote: c.tier1GroundingNote,
                    deepModelName: c.deepModelName,
                    tier2Analysis: c.tier2Analysis, tier2FollowUps: c.tier2FollowUps,
                    tier2Uncertainties: c.tier2Uncertainties,
                    tier2PromptUser: c.tier2PromptUser, tier2RawReply: c.tier2RawReply,
                    tier2GroundingElapsedMs: c.tier2GroundingElapsedMs,
                    tier2StreamElapsedMs: c.tier2StreamElapsedMs,
                    tier2Error: c.tier2Error, tier2GroundingNote: c.tier2GroundingNote,
                    answeredAt: c.answeredAt)
            }
        return MeetingSessionDiagnostics(
            exportedAt: Date(),
            sessionId: session.id,
            appName: session.appName,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            brief: session.brief,
            config: decodedConfig,
            configRaw: decodedConfig == nil && !session.configSnapshotRaw.isEmpty
                ? session.configSnapshotRaw : nil,
            remoteTranscript: session.remoteTranscriptRaw,
            localTranscript: session.localTranscriptRaw,
            segments: segments,
            cues: cues)
    }

    func encodedJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}
