import Foundation
import SwiftData
import Combine
import os

/// 離線覆盤的逐字稿分段(純函式)。live 路徑的「committed 段」在這裡由逐字稿重建——
/// 這是「等同即時輔助」的起點:分段之後的 cue 抽取/tier 完全共用 live 的元件。
///
/// # 為什麼不重跑 ASR
///
/// 覆盤的輸入是**已完成的錄音 + 既有逐字稿**。重跑 ASR 只會得到同一份文字(甚至更差:
/// 少了 live 的聲道分離),卻要付整段音檔的轉錄成本與時間。覆盤要驗證的是**抽取與回應**
/// 那一段管線,不是轉錄——所以從逐字稿進場。
///
/// # 為什麼分段就是等同性的起點
///
/// live 端每一次 cue 抽取的輸入是「對方剛說完的一段」(`MeetingPartialSegmenter` 以停頓切出的
/// committed 段)。只要 replay 能把逐字稿還原成尺寸相近的段,後面 `ResponseCueExtractor` →
/// 去重 → tier 全部原封不動重用,兩條路徑的行為才可比較(否則段長不同 = 抽取上下文不同,
/// 覆盤結果不能拿來調校 live 的 prompt)。
///
/// 純函式 namespace,房子風格鏡射 `MeetingCueDeduplicator` / `TranscriptChunker`。
enum ReplaySegmentation {

    /// 句群上限字元數。live committed 段是一次停頓內說完的話,通常遠短於此;
    /// 這個上限只是保險——擋住「整段獨白沒有句終符」的極端逐字稿。
    static let maxCharsPerGroup = 200
    /// 句群上限句數。貼近 live:一次停頓內約 1~3 句(`MeetingPartialSegmenter.stallInterval` 1.5s)。
    static let maxSentencesPerGroup = 3

    /// 逐字稿 → 段落清單(等同 live 的 committed 段序列)。
    ///
    /// 有講者輪次 → **一輪一段、內容為該輪原文**。注意這裡刻意**不加「講者N:」前綴**
    /// (與 `TranscriptChunker.makeUnits` 的差異):cue 抽取的輸入語意是「對方剛說的話」原文,
    /// 前綴會混進抽取上下文、污染判斷;chunker 那邊的前綴是給 RAG 檢索看的,目的不同。
    ///
    /// 無輪次 → 以句終符切句後聚成句群(段長貼近 live committed)。
    static func segments(text: String, speakerSegments: [SpeakerSegment]) -> [String] {
        if !speakerSegments.isEmpty {
            return speakerSegments
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }   // 空輪次(純靜默/雜訊)不該觸發一次抽取呼叫
        }
        return sentenceGroups(of: text)
    }

    // MARK: - 純文字回退

    /// 句終符集合鏡射 `TranscriptChunker.trailingSentences`(AskAI/TranscriptChunker.swift:76)——
    /// 同一份逐字稿在兩個模組要用同一套斷句標準,否則同一段話在覆盤與 RAG 會被切在不同地方。
    private static let terminators = CharacterSet(charactersIn: "。．.!?！？\n")

    /// 切句 → 聚成 ≤`maxSentencesPerGroup` 句、≤`maxCharsPerGroup` 字的句群。
    /// 句子保留原標點且不做正規化 —— 所有段串接回去 == 原文(忽略首尾空白),覆盤不丟內容。
    private static func sentenceGroups(of text: String) -> [String] {
        let sentences = splitSentences(text)
        guard !sentences.isEmpty else { return [] }

        var groups: [String] = []
        var current: [String] = []
        var currentChars = 0

        func flush() {
            guard !current.isEmpty else { return }
            let group = current.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !group.isEmpty { groups.append(group) }
            current = []
            currentChars = 0
        }

        for sentence in sentences {
            let count = sentence.count
            // 單句就超長(沒句終符的獨白)→ 自己成一段,不硬切:切斷句子等於毀掉抽取的語意單位。
            if count >= maxCharsPerGroup {
                flush()
                current = [sentence]
                currentChars = count
                flush()
                continue
            }
            if !current.isEmpty,
               current.count >= maxSentencesPerGroup || currentChars + count > maxCharsPerGroup {
                flush()
            }
            current.append(sentence)
            currentChars += count
        }
        flush()
        return groups
    }

    /// 以句終符切句,終符留在句尾(串接可還原原文)。
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if let scalar = ch.unicodeScalars.first, terminators.contains(scalar) {
                sentences.append(current)
                current = ""
            }
        }
        if !current.isEmpty { sentences.append(current) }
        return sentences.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: - 覆盤管線(AC-38、AC-42)

/// 一份既有逐字稿 → 一場 replay `MeetingLiveSession`(逐段抽取 cue + 非 informational 跑 Tier 1)。
///
/// 產物與 live session **同構**(同一組 @Model、同一份 provenance 欄位),只有 `sourceRaw` 不同 ——
/// 所以覆盤頁、診斷匯出、漏抓掃描全部原封不動重用,不必為 replay 開第二套資料結構(FR-59)。
///
/// # 為什麼不重跑 ASR
///
/// 輸入是**已完成的錄音 + 既有逐字稿**;重跑 ASR 只會得到同一份文字(甚至更差:少了 live 的
/// 聲道分離),卻要付整段音檔的轉錄成本與時間。覆盤要驗證的是**抽取與回應**那一段管線,
/// 不是轉錄(詳見 `ReplaySegmentation` 檔頭)。
///
/// # 為什麼全程序列
///
/// 逐段抽取、逐則 Tier 1 都是**序列 await**。一場一小時的會議可以切出上百段,併發打出去必撞
/// provider 的 rate limit —— 429 之後整批重跑,反而比一段一段慢慢跑更久。覆盤是離線的背景工作,
/// 沒有 live 的延遲壓力(那才是要併發的地方),慢一點完全可以接受。
///
/// # 為什麼失敗要刪掉整場 session
///
/// 半套的覆盤比沒有更糟:它看起來像「這份逐字稿只有 3 則 cue」,實際上是跑到一半斷網/被取消,
/// 而事後**沒有任何欄位分得出這兩件事** —— 調校時會把「中斷」誤讀成「抽取漏抓」,照著改 prompt
/// 就是往錯的方向調。所以任何中途失敗一律整場刪掉,重跑即可(replay 本來就可重入,AC-42)。
@MainActor
final class MeetingReplayReviewService: ObservableObject {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    private let extractor: ResponseCueExtractor
    /// nil = 只抽 cue 不跑回應(對照組:單獨調校抽取 prompt 時不必燒 Tier 1 的錢)。
    private let coordinator: AnswerCoordinator?
    private let modelContext: ModelContext
    private let config: MeetingCopilotConfigStore
    /// cue 抽取實際用的 fast model("provider/model",觀測資料;由呼叫端解析後注入)。
    private let extractionModelLabel: String

    /// 進度(done/total;nil = 沒在跑)。分母兩階段才完整:第二階段(Tier 1)的 cue 數要等抽取跑完
    /// 才知道 —— 段落跑完後補進 total,done 續計(不歸零,不然進度條會倒退)。
    @Published private(set) var progress: (done: Int, total: Int)?

    /// 沒有錄音長度可還原節奏時的段落間隔(見 `segmentInterval`)。
    private static let fallbackSegmentInterval: TimeInterval = 8

    init(
        extractorChat: ChatCompleting,
        coordinator: AnswerCoordinator?,
        modelContext: ModelContext,
        extractionModelLabel: String = "",
        config: MeetingCopilotConfigStore = .shared
    ) {
        self.extractor = ResponseCueExtractor(chat: extractorChat)
        self.coordinator = coordinator
        self.modelContext = modelContext
        self.extractionModelLabel = extractionModelLabel
        self.config = config
    }

    // MARK: - 產生覆盤

    /// 逐字稿 → replay session。中途失敗/取消 → 刪掉整場 session 後 rethrow(不留半套)。
    func generateReview(for transcription: Transcription) async throws -> MeetingLiveSession {
        defer { progress = nil }

        // 有人工潤飾過的版本就用它(錯字少 = 抽取判斷更準);native 講者輪次才拿來分段 ——
        // FluidAudio 的 fallback 輪次帶的是本機 Parakeet 的英文文字,與錄音語言可能對不上
        // (見 Transcription.speakerSegmentsAreNative),拿它分段等於餵錯的逐字稿進抽取。
        let sourceText = transcription.enhancedText ?? transcription.text
        let units = ReplaySegmentation.segments(
            text: sourceText,
            speakerSegments: transcription.speakerSegmentsAreNative ? transcription.speakerSegments : [])

        let session = makeSession(for: transcription, sourceText: sourceText)
        modelContext.insert(session)
        logger.notice("🧠 覆盤開始 — 段落 \(units.count, privacy: .public) 段 fingerprint=\(session.importFingerprint, privacy: .public)")

        do {
            try modelContext.save()
            let pending = try await extractCues(units: units, in: session, duration: transcription.duration)
            try await runTier1(for: pending, afterSegments: units.count)
            try modelContext.save()
            logger.notice("🧠 覆盤完成 — cue \((session.cues ?? []).count, privacy: .public) 則(Tier 1 \(pending.count, privacy: .public) 則)")
            return session
        } catch {
            modelContext.delete(session)
            try? modelContext.save()   // 刪不掉也只能認了:再 throw 一次只會蓋掉真正的失敗原因
            logger.error("🧠 覆盤中止:\(error.localizedDescription, privacy: .public) → 已刪除半套 session")
            throw error
        }
    }

    // MARK: - Session

    /// 建 replay session。`sourceRaw` 是列表分辨兩種來源的唯一依據(資料同構,只有產生方式不同)。
    private func makeSession(for transcription: Transcription, sourceText: String) -> MeetingLiveSession {
        let session = MeetingLiveSession(appName: "覆盤")
        session.sourceRaw = "replay"
        // 與錄音的關聯:錄音管理詳情頁靠指紋找到這場覆盤。沒指紋(舊資料/純文字匯入)→ 空字串。
        session.importFingerprint = transcription.importFingerprint ?? ""
        // 逐字稿全文留在 session 上:覆盤 session 要自給自足(診斷匯出、漏抓掃描都吃它),
        // 不必回頭 join 那筆 Transcription —— 它可能先被清理掉。replay 全視為對方聲道(→ remote)。
        session.remoteTranscriptRaw = sourceText
        // endedAt = 錄音長度,**不是**「生成花了多久」:列表的時長欄要顯示這場會議多長。
        // 留 nil 會被 `MeetingRowDisplay.durationText` 當成「進行中」,永遠轉圈。
        session.endedAt = session.startedAt.addingTimeInterval(transcription.duration)
        session.configSnapshotRaw = MeetingCopilotRunConfig.capture(
            config: config,
            // replay 不重跑 ASR —— 照實記錄「這份逐字稿是哪顆模型出的」。
            asrModelDisplayName: transcription.transcriptionModelName ?? "",
            fastModelLabel: extractionModelLabel,
            // replay 不進 deep(成本紅線,見 AnswerCoordinator.runTier1ForReplay)→ 誠實記空字串,
            // 而不是抄一個從頭到尾沒被呼叫的模型名。
            deepModelLabel: "").encodedJSON()
        return session
    }

    // MARK: - 逐段抽取(鏡射 MeetingCopilotController.handleRemoteCommitted + ingest)

    /// 逐段(序列)抽取 → 回寫 provenance → 去重 → persist cue。回傳要跑 Tier 1 的 cue(非 informational)。
    private func extractCues(
        units: [String], in session: MeetingLiveSession, duration: TimeInterval
    ) async throws -> [MeetingLiveCue] {
        let interval = segmentInterval(duration: duration, count: units.count)
        var pending: [MeetingLiveCue] = []
        progress = (0, units.count)

        for (index, text) in units.enumerated() {
            try Task.checkCancellation()

            // 合成時間軸。replay 沒有真實的 committed 時刻(分段只回文字),但**去重的 30 秒窗需要
            // 時間才有意義**:全部塞同一個 `Date()` 會讓時間窗退化成「全場去重」—— 同一個問題在第 3
            // 分鐘與第 40 分鐘各問一次,live 留下兩則(兩次都要答),replay 卻只留一則 → 兩條路徑的
            // 結果不可比,而「可比」正是覆盤存在的理由(見 ReplaySegmentation 檔頭)。
            let at = session.startedAt.addingTimeInterval(Double(index) * interval)

            // 先落 segment(即使抽出 0 則):「這段話當時被看過、模型怎麼回」也要留下 ——
            // 漏抓只能從完整時間軸對照出來(同 live 的 recordSegment)。
            let segment = MeetingLiveSegment(session: session, channel: .remote, text: text, committedAt: at)
            modelContext.insert(segment)
            try modelContext.save()

            let outcome = await extractor.extract(committed: text)
            // await 期間可能被取消 —— 不要再往一場即將被刪掉的 session 寫東西。
            try Task.checkCancellation()

            // 抽取 provenance(含失敗:「抽出 0 則」與「呼叫失敗」對調校是兩件事)。
            segment.extractionModel = extractionModelLabel
            segment.extractionReplyRaw = outcome.rawReply
            segment.extractionError = outcome.errorDescription
            segment.extractionElapsedMs = outcome.elapsedMs
            segment.extractedCount = outcome.cues.count

            var dedupDropped = 0
            for e in outcome.cues {
                let existing = (session.cues ?? []).map { (text: $0.text, askedAt: $0.askedAt) }
                if MeetingCueDeduplicator.isDuplicate(text: e.text, at: at, existing: existing) {
                    dedupDropped += 1
                    continue   // FR-10:相似 cue 不重覆 persist
                }
                let cue = MeetingLiveCue(
                    session: session, text: e.text, kind: e.kind, askedAt: at,
                    contextExcerpt: String(text.prefix(300)))
                cue.searchHint = e.searchHint      // aboutMe 的筆記檢索改寫詞(檢索路由用)
                cue.sourceSegmentId = segment.id   // 完整偵測上下文從那筆 segment 查
                // detectionElapsedMs 不寫:replay 沒有「committed 到 cue 浮上 overlay」的即時延遲。
                // 抽取本身的耗時記在 segment.extractionElapsedMs —— 照實記錄,不編一個假的延遲。
                modelContext.insert(cue)
                // informational 照樣 persist(FR-11),但不觸發回應。
                if e.kind != .informational { pending.append(cue) }
            }
            segment.dedupDroppedCount = dedupDropped
            try modelContext.save()
            progress = (index + 1, units.count)
        }
        return pending
    }

    /// 合成時間軸的段落間隔:以錄音長度均分還原**真實節奏** —— 快節奏的會議一分鐘講十段,
    /// 30 秒窗內就該看到十段;慢節奏的一分鐘兩段,窗內就只有兩段。這樣去重才與 live 等價。
    /// 沒有長度資訊(duration = 0,例如純文字匯入)→ 退回一個貼近 live committed 節奏的常數。
    private func segmentInterval(duration: TimeInterval, count: Int) -> TimeInterval {
        guard duration > 0, count > 0 else { return Self.fallbackSegmentInterval }
        return duration / Double(count)
    }

    // MARK: - Tier 1

    /// 非 informational cue **序列**跑 Tier 1(不進 deep:`runTier1ForReplay` 的契約)。
    /// - Parameter afterSegments: 第一階段已完成的段落數(進度續計的起點)。
    private func runTier1(for cues: [MeetingLiveCue], afterSegments: Int) async throws {
        guard let coordinator, !cues.isEmpty else { return }
        let total = afterSegments + cues.count
        progress = (afterSegments, total)
        for (index, cue) in cues.enumerated() {
            try Task.checkCancellation()
            await coordinator.runTier1ForReplay(cue)
            progress = (afterSegments + index + 1, total)
        }
    }
}
