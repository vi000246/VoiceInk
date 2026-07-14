import Foundation
import Combine
import os

/// 即時字幕翻譯(M8 FR-62 / AC-43/44/47)。
///
/// # 為什麼是獨立的 consumer
/// 這是 remote committed 的**第二個獨立 consumer**——與 `ResponseCueExtractor` 的 cue 抽取
/// **平行**、互不阻塞:
/// - 翻譯慢(長句十幾秒)不該讓 cue 晚到 overlay,cue 才是這個功能的主線;
/// - 反過來,抽取失敗(fast model 沒 key)也不該讓字幕整個消失。
///
/// 兩者共用同一段 committed 文字,但**不共用呼叫**:cue 抽取要的是判斷力(五分類 JSON),
/// 翻譯要的是便宜、快、量大(每段都打)——硬塞成一次呼叫會讓兩邊的模型選擇互相綁架。
/// 所以 `MeetingCopilotController.handleRemoteCommitted` 開兩條路,而不是串成一條。
///
/// # 失敗紀律
/// 靜默:字幕留原文、錯誤只進 `segment.translationError` 與 🌐 log。會議進行中跳一個
/// 「翻譯失敗」的 UI,比沒有翻譯更糟(與 `MeetingLiveTranscriber` 的 ASR error 同一紀律)。
@MainActor
final class MeetingLiveTranslator: ObservableObject {

    /// overlay 字幕區的一行。
    struct FeedLine: Identifiable, Equatable {
        /// = `MeetingLiveSegment.id`。同一段重譯時取代舊行(見 `insertSorted`),不會出現兩行。
        let id: UUID
        let committedAt: Date
        /// 原文。翻譯失敗時 `translated` 就等於它——字幕寧可顯示聽得懂的原文,也不要空白。
        let original: String
        var translated: String
    }

    /// 字幕來源。**恆按 `committedAt` 排序**,只保留最近 `maxFeedLines` 句。
    @Published private(set) var feed: [FeedLine] = []

    private let chat: ChatCompleting
    private let config: MeetingCopilotConfigStore
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    /// 在途翻譯(每段一個 Task,不等前一段完成)。測試用 `drainForTest()` 等待。
    private var inflight: [Task<Void, Never>] = []

    /// 字幕保留句數。會議兩小時的逐字稿全留在記憶體沒有意義——overlay 一次只看得到最後幾句,
    /// 往前捲的需求由覆盤頁(persist 的 segment)承接。
    private let maxFeedLines = 20

    init(chat: ChatCompleting, config: MeetingCopilotConfigStore = .shared) {
        self.chat = chat
        self.config = config
    }

    // MARK: - 翻譯

    /// 一段 committed 逐字稿進來 → 開一個 Task 翻譯。立即返回,不阻塞轉錄事件迴圈。
    func translate(segment: MeetingLiveSegment) {
        // AC-47(硬需求):關閉 = **零 API 呼叫**。guard 放在這裡而不是呼叫端——
        // 「要不要翻」是翻譯器自己的事,擺在這裡,任何新接的呼叫端都不可能漏掉這道檢查。
        guard config.liveTranslationEnabled else { return }

        // prompt(純函式)與 segment 快照都在 MainActor 上先取好;Task 內只做 await + 回寫。
        let (system, user) = MeetingTranslationPrompt.build(
            text: segment.text,
            sourceLanguage: config.translationSourceLanguage,
            targetLanguage: config.translationTargetLanguage)
        let start = Date()
        let logger = self.logger

        let task = Task { [weak self] in
            guard let self else { return }
            // 先以原文成行:任何失敗路徑都會用到它,不必在 catch 裡重組。
            var line = FeedLine(
                id: segment.id, committedAt: segment.committedAt,
                original: segment.text, translated: segment.text)
            do {
                // complete 為 async——await 期間讓出 main,轉錄與 cue 抽取照跑。
                let reply = try await self.chat.complete(system: system, user: user)
                let translated = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                // 空回覆視同沒翻到:字幕留原文(空白字幕看起來像 app 壞了)。
                if !translated.isEmpty {
                    line.translated = translated
                    segment.translatedText = translated
                }
            } catch {
                // 靜默:不跳 UI、不中斷後續段落。線索只留在 segment 與 log。
                segment.translationError = error.localizedDescription
                logger.error("🌐 即時翻譯失敗: \(error.localizedDescription, privacy: .public)")
            }
            segment.translationElapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            try? segment.modelContext?.save()
            self.insertSorted(line)
        }
        inflight.append(task)
    }

    /// feed 恆按 `committedAt` 排序,**不按完成序**。
    ///
    /// 完成序 ≠ 說話序:短句(「Yes, exactly.」)幾百毫秒就譯完,長句要好幾秒——照完成序 append
    /// 的話,後說的那句會插到前一句上面,字幕前後跳動,讀的人根本對不上剛剛聽到的內容。
    /// 寧可讓晚到的譯文「就定位」補回它該在的位置。
    private func insertSorted(_ line: FeedLine) {
        feed.removeAll { $0.id == line.id }   // 同一段重譯 → 取代,不重複成兩行
        feed.append(line)
        feed.sort { $0.committedAt < $1.committedAt }
        if feed.count > maxFeedLines { feed.removeFirst(feed.count - maxFeedLines) }
    }

    /// 測試用:等待所有在途翻譯完成(照 `MeetingCopilotController.drainInflight`)。
    func drainForTest() async {
        let tasks = inflight
        inflight.removeAll()
        for task in tasks { await task.value }
    }
}
