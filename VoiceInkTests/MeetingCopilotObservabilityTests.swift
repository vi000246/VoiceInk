import XCTest
import SwiftData
@testable import VoiceInk

/// 觀測資料持久化(調校迴圈的原始資料):
/// segment 時間軸 + 偵測 provenance + session 收尾快照 + 診斷匯出。
/// fakes 沿用 ResponseCueExtractorTests 的 FakeChatCompleting / KeyedFakeChatCompleting。
@MainActor
final class MeetingCopilotObservabilityTests: XCTestCase {

    /// 每個測試一份 in-memory 設定後端（見 TestDefaults.swift）——測試不得碰 `.standard`。
    private let defaultsSuite = InMemoryDefaults()

    // 原本這裡有一組 setUp/tearDown 備份還原 `.standard` 的 copilot 設定 key。設定後端改成注入
    // 之後它不只是多餘,而是**有害**:那組 bracket 本身就在**寫**全域 domain,而 test target 是
    // `parallelizable = YES`(每個 class 一個 process、共用同一個 domain)——別的 process 正在
    // 斷言「未設定 → 預設值」時撞上這裡的 removeObject/set,就是一顆與程式碼無關的紅燈。

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: MeetingLiveSession.self, MeetingLiveCue.self, MeetingLiveSegment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    private func makeEnabledConfig() -> MeetingCopilotConfigStore {
        let config = MeetingCopilotConfigStore(defaults: defaultsSuite)
        config.setCopilotEnabled(true)
        return config
    }

    /// 每段 remote committed 都要留下 segment + 偵測 provenance(原始回覆/耗時/模型/抽出數),
    /// cue 要能連回來源 segment(sourceSegmentId + detectionElapsedMs)。
    func testRemoteCommittedPersistsSegmentWithProvenance() async throws {
        let ctx = try makeContext()
        let config = makeEnabledConfig()
        defer { config.setCopilotEnabled(false) }

        let json = #"{"cues":[{"text":"你會怎麼設計 rate limiter？","kind":"directQuestion"}]}"#
        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: FakeChatCompleting(reply: json)),
            config: config, modelContext: ctx,
            extractionModelLabel: "groq/llama-3.1-8b-instant")
        controller.beginSession(appName: "test")

        controller.handleRemoteCommitted("你會怎麼設計 rate limiter？")
        await controller.drainInflight()

        let segments = try ctx.fetch(FetchDescriptor<MeetingLiveSegment>())
        XCTAssertEqual(segments.count, 1)
        let seg = try XCTUnwrap(segments.first)
        XCTAssertEqual(seg.channel, .remote)
        XCTAssertEqual(seg.text, "你會怎麼設計 rate limiter？")
        XCTAssertEqual(seg.extractionReplyRaw, json, "fast model 原始回覆必須完整保留")
        XCTAssertEqual(seg.extractedCount, 1)
        XCTAssertEqual(seg.extractionModel, "groq/llama-3.1-8b-instant")
        XCTAssertTrue(seg.extractionError.isEmpty)
        XCTAssertGreaterThanOrEqual(seg.extractionElapsedMs, 0)

        let cue = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).first)
        XCTAssertEqual(cue.sourceSegmentId, seg.id, "cue 必須連回觸發它的 segment")
        XCTAssertGreaterThanOrEqual(cue.detectionElapsedMs, 0)
    }

    /// 抽出 0 則也要留 segment(漏抓只能從完整時間軸對照出來);失敗要留 extractionError。
    func testZeroCueAndFailureStillPersistSegments() async throws {
        let ctx = try makeContext()
        let config = makeEnabledConfig()
        defer { config.setCopilotEnabled(false) }

        // 0 則
        let zeroController = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: FakeChatCompleting(reply: #"{"cues":[]}"#)),
            config: config, modelContext: ctx)
        zeroController.beginSession(appName: "test")
        zeroController.handleRemoteCommitted("我們上週天氣不錯")
        await zeroController.drainInflight()

        var segments = try ctx.fetch(FetchDescriptor<MeetingLiveSegment>())
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].extractedCount, 0, "0 則 ≠ 沒跑:extractedCount 必須是 0")
        XCTAssertTrue(segments[0].extractionError.isEmpty)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 0)

        // LLM 失敗
        let failController = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: FakeChatCompleting(shouldThrow: true)),
            config: config, modelContext: ctx)
        failController.beginSession(appName: "test")
        failController.handleRemoteCommitted("這句抽取會失敗")
        await failController.drainInflight()

        segments = try ctx.fetch(FetchDescriptor<MeetingLiveSegment>())
            .sorted { $0.committedAt < $1.committedAt }
        XCTAssertEqual(segments.count, 2)
        XCTAssertFalse(segments[1].extractionError.isEmpty, "呼叫失敗原因必須 persist")
        XCTAssertEqual(segments[1].extractedCount, 0)
    }

    /// FR-10 去重丟棄的數量記在 segment 上(dedup 過猛/過鬆的調校訊號)。
    func testDedupDropCountRecordedOnSegment() async throws {
        let ctx = try makeContext()
        let config = makeEnabledConfig()
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

        XCTAssertEqual(try ctx.fetch(FetchDescriptor<MeetingLiveCue>()).count, 1, "相似 cue 仍去重")
        let segments = try ctx.fetch(FetchDescriptor<MeetingLiveSegment>())
            .sorted { $0.committedAt < $1.committedAt }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].dedupDroppedCount, 0)
        XCTAssertEqual(segments[0].extractedCount, 1)
        XCTAssertEqual(segments[1].dedupDroppedCount, 1, "被去重丟棄的數量要留下")
        XCTAssertEqual(segments[1].extractedCount, 1, "抽出數記「模型抽了幾則」,與去重無關")
    }

    /// local committed 也落入時間軸(不抽取:extractedCount 保持 -1)。
    func testLocalSegmentRecordedWithoutExtraction() async throws {
        let ctx = try makeContext()
        let config = makeEnabledConfig()
        defer { config.setCopilotEnabled(false) }

        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: FakeChatCompleting()),
            config: config, modelContext: ctx)
        controller.beginSession(appName: "test")

        controller.recordSegment(channel: .local, text: "我剛才回答了快取策略")

        let segments = try ctx.fetch(FetchDescriptor<MeetingLiveSegment>())
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].channel, .local)
        XCTAssertEqual(segments[0].extractedCount, -1, "-1 = 沒跑抽取(local 段)")
    }

    /// session 收尾:設定快照在 begin 時寫入,雙軌逐字稿在 end 時回填
    /// (覆盤頁原本讀 remoteTranscriptRaw 但從沒有人寫——這是回歸鎖)。
    func testSessionSnapshotAndTranscriptsPersisted() async throws {
        let ctx = try makeContext()
        let config = makeEnabledConfig()
        defer { config.setCopilotEnabled(false) }

        let controller = MeetingCopilotController(
            extractor: ResponseCueExtractor(chat: FakeChatCompleting()),
            config: config, modelContext: ctx)
        controller.beginSession(appName: "test", configSnapshot: #"{"fastModel":"groq/x"}"#)
        controller.endSession(remoteTranscript: "對方說了 A B C", localTranscript: "我說了 D")

        let session = try XCTUnwrap(try ctx.fetch(FetchDescriptor<MeetingLiveSession>()).first)
        XCTAssertEqual(session.configSnapshotRaw, #"{"fastModel":"groq/x"}"#)
        XCTAssertEqual(session.remoteTranscriptRaw, "對方說了 A B C")
        XCTAssertEqual(session.localTranscriptRaw, "我說了 D")
        XCTAssertNotNil(session.endedAt)
    }

    /// 設定快照:模型/開關/persona/prompt/去重參數全帶到,JSON round-trip 不掉欄位。
    func testRunConfigCaptureRoundTrips() {
        let config = MeetingCopilotConfigStore(defaults: defaultsSuite)
        config.setDomainPersona("你是資深 iOS 工程師。")
        let snapshot = MeetingCopilotRunConfig.capture(
            config: config, asrModelDisplayName: "Nemotron Multilingual",
            fastModelLabel: "groq/llama-3.1-8b-instant", deepModelLabel: "anthropic/claude-sonnet-4")

        XCTAssertEqual(snapshot.asrModel, "Nemotron Multilingual")
        XCTAssertEqual(snapshot.fastModel, "groq/llama-3.1-8b-instant")
        XCTAssertEqual(snapshot.dedupThreshold, MeetingCueDeduplicator.defaultThreshold)
        XCTAssertEqual(snapshot.dedupWindowSeconds, MeetingCueDeduplicator.defaultWindow)
        XCTAssertTrue(snapshot.cueSystemPrompt.contains("directQuestion"), "cue 偵測 prompt 全文入快照")
        XCTAssertTrue(snapshot.tier1SystemPrompt.contains("你是資深 iOS 工程師。"), "persona 已渲染進 tier prompt")

        // M8:筆記 RAG 三件套也是變因(改了會影響 aboutMe cue 的接地與 prompt)→ 必須進快照。
        XCTAssertEqual(snapshot.useNotesRAG, config.useNotesRAG)
        XCTAssertEqual(snapshot.notesInTechnicalRAG, config.notesInTechnicalRAG)
        XCTAssertEqual(snapshot.aboutMeBrief, config.aboutMeBrief)
        // M8 Task 9:auto-deep 開關決定「哪些 cue 會有 tier2」→ 解讀覆蓋率時的關鍵變因。
        XCTAssertEqual(snapshot.autoDeepEnabled, config.autoDeepEnabled)
        // M8 Task 18/19:翻譯開關(成本變因)+ 目標語言。目標語言同時是**回應語言**(AC-46),
        // 所以它必須進快照——否則覆盤時看到英文開口稿,分不出是設定如此還是模型不聽話。
        XCTAssertEqual(snapshot.liveTranslationEnabled, config.liveTranslationEnabled)
        XCTAssertEqual(snapshot.translationTargetLanguage, config.translationTargetLanguage)
        // 期待值由 config 推出(而非硬編「繁體中文」):斷言的是「prompt 的語言**跟著設定走**」,
        // 而不是某個當下的預設值——後者會被其他測試留在 UserDefaults 的目標語言弄成偽失敗。
        let expectedLanguage = MeetingTranslationPrompt.displayName(for: config.translationTargetLanguage)
        XCTAssertTrue(snapshot.tier1SystemPrompt.contains("以\(expectedLanguage)回答"),
                      "AC-46:快照存的 prompt 全文必須含當時的輸出語言指示")
        XCTAssertTrue(snapshot.tier2SystemPrompt.contains("以\(expectedLanguage)回答"))

        let json = snapshot.encodedJSON()
        XCTAssertFalse(json.isEmpty)
        let decoded = MeetingCopilotRunConfig.decode(json)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.fastModel, snapshot.fastModel)
        XCTAssertEqual(decoded?.cueSystemPrompt, snapshot.cueSystemPrompt)
        XCTAssertEqual(decoded?.useNotesRAG, snapshot.useNotesRAG)
        XCTAssertEqual(decoded?.aboutMeBrief, snapshot.aboutMeBrief)
    }

    /// 快照加了 M8 欄位後,**M8 之前寫下的舊快照必須仍解得開**。
    /// Swift 合成的 Decodable 不會套用屬性預設值——非 optional 新欄位會讓整份 decode 失敗,
    /// 覆盤頁就從結構化設定退回 configRaw 純文字,舊 session 的變因全變不可讀。
    func testRunConfigDecodesLegacySnapshotMissingM8Fields() throws {
        let snapshot = MeetingCopilotRunConfig.capture(
            config: MeetingCopilotConfigStore(defaults: defaultsSuite), asrModelDisplayName: "m",
            fastModelLabel: "groq/x", deepModelLabel: "d")

        // 從現行快照剝掉 M8 欄位 = 模擬 M8 之前的 JSON(其餘欄位齊全)。
        var dict = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(snapshot.encodedJSON().utf8)) as? [String: Any])
        for key in ["useNotesRAG", "notesInTechnicalRAG", "aboutMeBrief", "autoDeepEnabled",
                    "liveTranslationEnabled", "translationTargetLanguage"] {
            dict.removeValue(forKey: key)
        }
        let legacy = try XCTUnwrap(String(
            data: try JSONSerialization.data(withJSONObject: dict), encoding: .utf8))

        let decoded = try XCTUnwrap(MeetingCopilotRunConfig.decode(legacy), "舊快照必須仍可解碼")
        XCTAssertEqual(decoded.fastModel, "groq/x", "舊欄位照常還原")
        XCTAssertNil(decoded.useNotesRAG, "舊 session 當時沒有這個設定 → nil,不是硬編一個 false 出來")
        XCTAssertNil(decoded.aboutMeBrief)
        XCTAssertNil(decoded.autoDeepEnabled, "M8 之前沒有 auto-deep → nil(不是「當時關著」)")
        XCTAssertNil(decoded.liveTranslationEnabled, "M8 之前沒有即時翻譯 → nil")
        XCTAssertNil(decoded.translationTargetLanguage)
    }

    /// 診斷匯出:一場 session 的時間軸/偵測/三層觀測資料組成一份可解析的 JSON。
    func testDiagnosticsExportContainsFullPicture() throws {
        let ctx = try makeContext()
        let session = MeetingLiveSession(appName: "zoom", brief: "系統設計面試")
        session.remoteTranscriptRaw = "對方逐字稿全文"
        session.configSnapshotRaw = MeetingCopilotRunConfig.capture(
            config: MeetingCopilotConfigStore(defaults: defaultsSuite), asrModelDisplayName: "m",
            fastModelLabel: "f", deepModelLabel: "d").encodedJSON()
        ctx.insert(session)

        let seg = MeetingLiveSegment(session: session, channel: .remote, text: "你會怎麼設計快取？")
        seg.extractedCount = 1
        seg.extractionReplyRaw = #"{"cues":[...]}"#
        ctx.insert(seg)

        let cue = MeetingLiveCue(session: session, text: "你會怎麼設計快取？", kind: .directQuestion)
        cue.sourceSegmentId = seg.id
        cue.tier1PromptUser = "對方問/說:你會怎麼設計快取？"
        cue.tier1RawReply = "OPENER: 先分讀寫比"
        cue.tier1ElapsedMs = 1200
        ctx.insert(cue)
        try ctx.save()

        let data = try XCTUnwrap(MeetingSessionDiagnostics.build(from: session).encodedJSON())
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["appName"] as? String, "zoom")
        XCTAssertEqual(dict["remoteTranscript"] as? String, "對方逐字稿全文")
        XCTAssertNotNil(dict["config"], "設定快照要以結構化形式(非 escaped 字串)進匯出檔")

        let segments = try XCTUnwrap(dict["segments"] as? [[String: Any]])
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0]["text"] as? String, "你會怎麼設計快取？")
        XCTAssertEqual(segments[0]["extractedCount"] as? Int, 1)

        let cues = try XCTUnwrap(dict["cues"] as? [[String: Any]])
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0]["tier1PromptUser"] as? String, "對方問/說:你會怎麼設計快取？")
        XCTAssertEqual(cues[0]["tier1ElapsedMs"] as? Int, 1200)
        XCTAssertEqual(cues[0]["sourceSegmentId"] as? String, seg.id.uuidString,
                       "cue → segment 的連結要進匯出檔")
    }
}
