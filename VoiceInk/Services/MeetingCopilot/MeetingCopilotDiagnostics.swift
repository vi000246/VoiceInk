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

    // M8:個人筆記 RAG 的三個變因(改了會影響 aboutMe cue 的接地來源與 prompt)。
    //
    // **optional 是刻意的**:Swift 合成的 Decodable **不會**套用屬性預設值——非 optional 的新欄位
    // 會讓所有 M8 之前寫下的舊快照 decode 整份失敗(`MeetingSessionDiagnostics.build` 就退回
    // `configRaw` 純文字,舊 session 的變因全變不可讀)。nil = 那場會議錄製時還沒有這個設定,
    // 這比硬編一個 false 誠實。
    var useNotesRAG: Bool?
    var notesInTechnicalRAG: Bool?
    var aboutMeBrief: String?

    /// M8 FR-53:Tier 1 完成後是否自動接 Tier 2。開關會改變「哪些 cue 有 tier2」與 deep model 的
    /// 呼叫量,是覆盤時解讀 tier2 覆蓋率的關鍵變因。optional 理由同上(舊快照相容)。
    var autoDeepEnabled: Bool?

    /// M8 D 組(即時翻譯)。**目標語言不只決定字幕**——AC-46 讓三層回應也跟著它輸出,
    /// 所以覆盤時看到一則英文開口稿,要分得出是「當時目標語言設成 English」還是模型不聽話。
    /// 翻譯開關則是成本變因(每段 committed 一次額外 LLM 呼叫)。optional 理由同上(舊快照相容)。
    var liveTranslationEnabled: Bool?
    var translationTargetLanguage: String?

    /// M9 FR-73:深答的輸出密度(`MeetingDeepStyle.rawValue`)。覆盤時看到一則條列式 tier2,
    /// 要分得出是「當時設定成 bullets」還是模型自己跑掉的格式。optional 理由同上(舊快照相容)。
    var deepStyle: String?

    /// 從目前設定組快照。`fastModelLabel`/`deepModelLabel` 由呼叫端解析
    /// (需要 AIService 的 connected providers,config store 本身不知道)。
    @MainActor
    static func capture(
        config: MeetingCopilotConfigStore,
        asrModelDisplayName: String,
        fastModelLabel: String,
        deepModelLabel: String
    ) -> MeetingCopilotRunConfig {
        // AC-46:tier prompt 的輸出語言跟著翻譯目標語言走 → 快照存的 prompt 全文必須是
        // 模型當時**真的看到**的那一份(含語言指示),否則快照就不再自足。
        let outputLanguage = MeetingTranslationPrompt.displayName(for: config.translationTargetLanguage)
        return MeetingCopilotRunConfig(
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
            // 使用者可覆寫分類器 prompt / 注入風格守則 → 快照存**當時真的送出去的那份**,
            // 否則調校時對照的是內建預設,而不是實際行為。
            cueSystemPrompt: config.effectiveCuePrompt,
            tier1SystemPrompt: TierPrompts.tier1System(persona: config.domainPersona,
                                                       guidance: config.answerStyleGuidance,
                                                       outputLanguage: outputLanguage),
            // M9 FR-73:風格會改寫 tier2 prompt 的 analysis 格式段 → 快照必須帶 `config.deepStyle`,
            // 否則「快照存的是模型當時真的看到的那份」這個前提就破了(理由同上一段註解)。
            tier2SystemPrompt: TierPrompts.tier2System(persona: config.domainPersona,
                                                       guidance: config.answerStyleGuidance,
                                                       outputLanguage: outputLanguage,
                                                       style: config.deepStyle),
            useNotesRAG: config.useNotesRAG,
            notesInTechnicalRAG: config.notesInTechnicalRAG,
            aboutMeBrief: config.aboutMeBrief,
            autoDeepEnabled: config.autoDeepEnabled,
            liveTranslationEnabled: config.liveTranslationEnabled,
            translationTargetLanguage: config.translationTargetLanguage,
            deepStyle: config.deepStyle.rawValue)
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
