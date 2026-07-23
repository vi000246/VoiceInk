import XCTest
@testable import VoiceInk

/// 會後包(M12)純函式層:JSON 解析、截斷、逐字稿三層退階、markdown 組裝、
/// Vikunja 映射、config store round-trip。全離線,不碰 UserDefaults.standard(見 TestDefaults.swift)。
final class MeetingPackExtractionTests: XCTestCase {

    private let taipei = TimeZone(identifier: "Asia/Taipei")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        c.timeZone = taipei
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    // MARK: - Parse

    private let goodJSON = """
    {"short_title": "登入流程改版", "topics": ["OAuth 遷移"], "decisions": ["採方案 B"],
     "my_commitments": [{"title": "寫遷移文件", "due_date": "2026-07-20T09:00:00+08:00", "note": "含 rollback"}],
     "their_actions": [{"title": "更新 SDK", "owner": "小張", "note": ""}],
     "followups": ["QA 環境何時就緒"]}
    """

    func testParseNormalJSON() throws {
        let e = try XCTUnwrap(MeetingPackExtraction.parse(goodJSON))
        XCTAssertEqual(e.shortTitle, "登入流程改版")
        XCTAssertEqual(e.topics, ["OAuth 遷移"])
        XCTAssertEqual(e.decisions, ["採方案 B"])
        XCTAssertEqual(e.myCommitments.count, 1)
        XCTAssertEqual(e.myCommitments[0].title, "寫遷移文件")
        XCTAssertEqual(e.myCommitments[0].note, "含 rollback")
        XCTAssertEqual(e.myCommitments[0].dueDate, date(2026, 7, 20, 9, 0))
        XCTAssertEqual(e.theirActions, [MeetingPackTheirAction(title: "更新 SDK", owner: "小張", note: "")])
        XCTAssertEqual(e.followups, ["QA 環境何時就緒"])
    }

    func testParseStripsMarkdownFence() throws {
        let fenced = "```json\n\(goodJSON)\n```"
        let e = try XCTUnwrap(MeetingPackExtraction.parse(fenced))
        XCTAssertEqual(e.shortTitle, "登入流程改版")
    }

    func testParseBadJSONReturnsNil() {
        XCTAssertNil(MeetingPackExtraction.parse("抱歉,我無法整理這場會議。"))
        XCTAssertNil(MeetingPackExtraction.parse("{broken json"))
    }

    func testParseDueDateSentinelAndNullBecomeNil() throws {
        let raw = """
        {"short_title": "t", "my_commitments": [
          {"title": "a", "due_date": "0001-01-01T00:00:00Z", "note": ""},
          {"title": "b", "due_date": null, "note": ""}]}
        """
        let e = try XCTUnwrap(MeetingPackExtraction.parse(raw))
        XCTAssertEqual(e.myCommitments.map(\.dueDate), [nil, nil])
    }

    func testParseDropsUntitledItemsAndBlankStrings() throws {
        let raw = """
        {"short_title": "t", "topics": ["", "  ", "real"],
         "my_commitments": [{"title": "  ", "due_date": null, "note": "x"}]}
        """
        let e = try XCTUnwrap(MeetingPackExtraction.parse(raw))
        XCTAssertEqual(e.topics, ["real"])
        XCTAssertTrue(e.myCommitments.isEmpty)
    }

    // MARK: - 截斷

    func testTruncateUnderLimitUnchanged() {
        let text = String(repeating: "a", count: 100)
        let (out, truncated) = MeetingPackExtraction.truncate(text, limit: 100)
        XCTAssertEqual(out, text)
        XCTAssertFalse(truncated)
    }

    func testTruncateOverLimitKeepsHeadAndTail() {
        let text = "HEAD" + String(repeating: "x", count: 30_000) + "TAIL"
        let (out, truncated) = MeetingPackExtraction.truncate(text, limit: 900)
        XCTAssertTrue(truncated)
        XCTAssertTrue(out.hasPrefix("HEAD"))
        XCTAssertTrue(out.hasSuffix("TAIL"))
        XCTAssertTrue(out.contains("(中段省略)"))
        // 前後合計不超過 limit(加上省略標記的少量 overhead)。
        XCTAssertLessThan(out.count, 900 + 50)
    }

    // MARK: - 逐字稿三層退階

    func testAssembleTranscriptFromSegmentsSortedByCommittedAt() {
        let segs = [
            MeetingPackSegment(isLocal: true, text: "我晚點補文件", committedAt: date(2026, 7, 17, 10, 5)),
            MeetingPackSegment(isLocal: false, text: "文件誰負責?", committedAt: date(2026, 7, 17, 10, 4)),
        ]
        let out = MeetingPackExtraction.assembleTranscript(
            segments: segs, remoteRaw: "snapshot", localRaw: "snapshot", transcriptionText: "plain")
        XCTAssertEqual(out, "對方:文件誰負責?\n我:我晚點補文件")
    }

    func testAssembleTranscriptFallsBackToRawSnapshots() {
        let out = MeetingPackExtraction.assembleTranscript(
            segments: [], remoteRaw: "對面說的話", localRaw: "我說的話", transcriptionText: "plain")
        XCTAssertTrue(out.contains("對方(全程):\n對面說的話"))
        XCTAssertTrue(out.contains("我(全程):\n我說的話"))
        XCTAssertFalse(out.contains("plain"))
    }

    func testAssembleTranscriptFallsBackToTranscriptionText() {
        // 空白 segment 視同無 segment(不算第一層)。
        let blank = [MeetingPackSegment(isLocal: false, text: "   ", committedAt: date(2026, 1, 1))]
        let out = MeetingPackExtraction.assembleTranscript(
            segments: blank, remoteRaw: "  ", localRaw: "", transcriptionText: "整段逐字稿")
        XCTAssertEqual(out, "整段逐字稿")
    }

    // MARK: - Prompt

    func testBuildUserMessageNotesTruncationAndBrief() {
        let msg = MeetingPackExtraction.buildUserMessage(
            transcript: "T", truncated: true, appName: "會議 · Zoom",
            startedAt: date(2026, 7, 17, 10, 0), endedAt: date(2026, 7, 17, 11, 0),
            brief: "季度規劃", now: date(2026, 7, 17, 11, 1), timeZone: taipei)
        XCTAssertTrue(msg.contains("中段已省略"))
        XCTAssertTrue(msg.contains("會前 brief:季度規劃"))
        XCTAssertTrue(msg.contains("2026-07-17 10:00 ~ 2026-07-17 11:00"))
        XCTAssertTrue(msg.contains("現在時刻:2026-07-17 11:01"))
        XCTAssertFalse(msg.contains("承諾候選"), "沒有會中偵測承諾時不得出現候選段")
    }

    /// M15:會中即時偵測到的承諾當候選提示餵給 LLM(提升 my_commitments 召回率)。
    func testBuildUserMessageIncludesDetectedCommitments() {
        let msg = MeetingPackExtraction.buildUserMessage(
            transcript: "T", truncated: false, appName: "Zoom",
            startedAt: nil, endedAt: nil, brief: "",
            detectedCommitments: ["寄效能報告給 Alex(口頭期限:下週五之前)", "更新 wiki"],
            now: date(2026, 7, 17, 11, 1), timeZone: taipei)
        XCTAssertTrue(msg.contains("承諾候選"))
        XCTAssertTrue(msg.contains("- 寄效能報告給 Alex(口頭期限:下週五之前)"))
        XCTAssertTrue(msg.contains("- 更新 wiki"))
        // 候選段必須在逐字稿之前(prompt 語意:先給提示、再給原文)。
        let candidateRange = msg.range(of: "承諾候選")!
        let transcriptRange = msg.range(of: "逐字稿:")!
        XCTAssertTrue(candidateRange.lowerBound < transcriptRange.lowerBound)
    }

    // MARK: - Markdown 組裝

    private var fullExtraction: MeetingPackExtraction {
        MeetingPackExtraction(
            shortTitle: "登入流程改版",
            topics: ["OAuth 遷移"],
            decisions: ["採方案 B"],
            myCommitments: [MeetingPackCommitment(title: "寫遷移文件", dueDate: date(2026, 7, 20, 9), note: "含 rollback")],
            theirActions: [MeetingPackTheirAction(title: "更新 SDK", owner: "小張", note: "")],
            followups: ["QA 環境何時就緒"])
    }

    func testMarkdownFourSectionOrder() {
        let md = MeetingPackExtraction.buildAnalysisMarkdown(fullExtraction, timeZone: taipei)
        let order = ["## 主題重點", "## 決定", "## 行動項目", "### 我答應的", "### 對方的", "## 待追問"]
        var cursor = md.startIndex
        for heading in order {
            guard let r = md.range(of: heading, range: cursor..<md.endIndex) else {
                return XCTFail("段落順序錯誤或缺段:\(heading)\n\(md)")
            }
            cursor = r.upperBound
        }
    }

    func testMarkdownDataviewInlineFields() {
        let md = MeetingPackExtraction.buildAnalysisMarkdown(fullExtraction, timeZone: taipei)
        XCTAssertTrue(md.contains("- task:: 寫遷移文件 [due:: 2026-07-20]"))
        XCTAssertTrue(md.contains("    - 含 rollback"))
        XCTAssertTrue(md.contains("- task:: 更新 SDK [owner:: 小張]"))
    }

    func testMarkdownNoDueFieldWhenDateNil() {
        var e = fullExtraction
        e.myCommitments = [MeetingPackCommitment(title: "無期限任務", dueDate: nil, note: "")]
        let md = MeetingPackExtraction.buildAnalysisMarkdown(e, timeZone: taipei)
        XCTAssertTrue(md.contains("- task:: 無期限任務\n"))
        XCTAssertFalse(md.contains("[due::"))
    }

    func testMarkdownOmitsEmptySections() {
        let e = MeetingPackExtraction(
            shortTitle: "t", topics: ["唯一主題"], decisions: [],
            myCommitments: [], theirActions: [], followups: [])
        let md = MeetingPackExtraction.buildAnalysisMarkdown(e, timeZone: taipei)
        XCTAssertTrue(md.contains("## 主題重點"))
        XCTAssertFalse(md.contains("## 決定"))
        XCTAssertFalse(md.contains("## 行動項目"))
        XCTAssertFalse(md.contains("## 待追問"))
    }

    // MARK: - Vikunja 映射

    func testVikunjaDraftsPassDueDateAndAppendSourceNote() {
        let due = date(2026, 7, 20, 9)
        let drafts = MeetingPackExtraction.vikunjaDrafts(
            from: [
                MeetingPackCommitment(title: "寫遷移文件", dueDate: due, note: "含 rollback"),
                MeetingPackCommitment(title: "回信給法務", dueDate: nil, note: ""),
            ],
            noteFileName: "2026-07-17 1000 會後包 登入流程改版.md")
        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts[0].title, "寫遷移文件")
        XCTAssertEqual(drafts[0].dueDate, due)
        XCTAssertEqual(drafts[0].priority, 0)
        XCTAssertEqual(drafts[0].description, "含 rollback\n\n來源:2026-07-17 1000 會後包 登入流程改版.md")
        XCTAssertNil(drafts[1].dueDate)
        XCTAssertEqual(drafts[1].description, "來源:2026-07-17 1000 會後包 登入流程改版.md")
    }

    func testBatchResultTitles() {
        XCTAssertEqual(MeetingPackExtraction.batchResultTitle(succeeded: 3, failed: 0), "已加入 Vikunja:3 筆")
        XCTAssertTrue(MeetingPackExtraction.batchResultTitle(succeeded: 0, failed: 2).contains("失敗(2 筆)"))
        let partial = MeetingPackExtraction.batchResultTitle(succeeded: 2, failed: 1)
        XCTAssertTrue(partial.contains("2 筆"))
        XCTAssertTrue(partial.contains("失敗 1 筆"))
        XCTAssertTrue(partial.contains("筆記"))   // 據實回報並指出失敗項不遺失
    }
}

/// config store:預設值與 round-trip(InMemoryDefaults 完全隔離)。
@MainActor
final class MeetingPackConfigStoreTests: XCTestCase {

    private let defaults = InMemoryDefaults()

    func testDefaults() {
        let store = MeetingPackConfigStore(defaults: defaults)
        XCTAssertTrue(store.enabled)                    // 未設定 → true(被動產出預設開)
        XCTAssertEqual(store.subfolder, "會後包")
        XCTAssertFalse(store.vikunjaAutoCreate)
    }

    func testRoundTrip() {
        let store = MeetingPackConfigStore(defaults: defaults)
        store.setEnabled(false)
        store.setSubfolder("Meetings/Packs")
        store.setVikunjaAutoCreate(true)

        let reloaded = MeetingPackConfigStore(defaults: defaults)
        XCTAssertFalse(reloaded.enabled)
        XCTAssertEqual(reloaded.subfolder, "Meetings/Packs")
        XCTAssertTrue(reloaded.vikunjaAutoCreate)
    }

    func testEmptySubfolderRestoresDefault() {
        let store = MeetingPackConfigStore(defaults: defaults)
        store.setSubfolder("自訂")
        store.setSubfolder("   ")
        XCTAssertEqual(store.subfolder, "會後包")
        XCTAssertEqual(MeetingPackConfigStore(defaults: defaults).subfolder, "會後包")
    }
}
