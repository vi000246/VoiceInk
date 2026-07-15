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

    /// 目前正在講、還沒 committed 的**在途譯文**(Stage B provisional):趁講者還沒停就先翻,
    /// 顯示在字幕最下方(最新)。句子 committed 後由 feed 的定稿取代、這裡收成 nil;
    /// 翻譯關閉時恆為 nil(AC-47)。
    @Published private(set) var provisional: FeedLine?

    /// 串流翻譯:逐 token 回來就地更新該行(M8 延遲優化,option 3)。改用串流的理由是**感知延遲**——
    /// 長句一次回來要等整段(實測十幾秒),逐字冒出來讓使用者第一秒就看到譯文開頭。
    private let chat: StreamingChatCompleting
    private let config: MeetingCopilotConfigStore
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    /// 在途翻譯(每段一個 Task,不等前一段完成)。測試用 `drainForTest()` 等待。
    private var inflight: [Task<Void, Never>] = []

    /// provisional 的在途翻譯(每次尾巴變動就取消重跑)。與 committed 的 `inflight` 分開——
    /// 它會被頻繁取消,不該混進測試 drain。
    private var provisionalTask: Task<Void, Never>?
    /// provisional 那一行的固定 id(就地更新,SwiftUI diff 才穩定)。
    private let provisionalId = UUID()

    /// 字幕保留句數。展開檢視要能回看最近 30 句,故保留 40 留點緩衝;會議兩小時的逐字稿全留
    /// 在記憶體沒有意義——更早的往前捲需求由覆盤頁(persist 的 segment)承接。
    private let maxFeedLines = 40

    init(chat: StreamingChatCompleting, config: MeetingCopilotConfigStore = .shared) {
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
            // 先以原文成行:任何失敗路徑都會用到它,不必在 catch 裡重組。第一個 delta 到之前
            // 字幕先顯示原文(空白字幕看起來像 app 壞了),有譯文再逐步取代。
            var line = FeedLine(
                id: segment.id, committedAt: segment.committedAt,
                original: segment.text, translated: segment.text)
            var accumulated = ""
            do {
                // 串流:await 期間讓出 main,轉錄與 cue 抽取照跑;每個 delta 就地更新該行,
                // 譯文逐字冒出來(不必等整段回來)。
                for try await delta in self.chat.stream(system: system, user: user) {
                    if Task.isCancelled { break }
                    accumulated += delta
                    let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        line.translated = trimmed
                        self.insertSorted(line)   // feed 依 id 取代同一行 → 就地刷新,不新增行
                    }
                }
                // 收尾:最終譯文回寫 segment(空回覆視同沒翻到,字幕留原文/已收到的部分)。
                let finalText = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                if !finalText.isEmpty {
                    line.translated = finalText
                    segment.translatedText = finalText
                }
            } catch {
                // 靜默:不跳 UI、不中斷後續段落。已收到的部分譯文保留(比整段回退原文好),
                // 什麼都沒收到才留原文。線索只留在 segment 與 log。
                segment.translationError = error.localizedDescription
                logger.error("🌐 即時翻譯失敗: \(error.localizedDescription, privacy: .public)")
            }
            segment.translationElapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            try? segment.modelContext?.save()
            self.insertSorted(line)
        }
        inflight.append(task)
    }

    // MARK: - Provisional 即時翻譯(Stage B)

    /// 未定稿尾巴進來(講者正在講、還沒停頓切段)→ debounce 後**串流翻譯**,顯示成 provisional
    /// (字幕最下方最新那行)。這是「連續講話也追得上」的關鍵:不必等講者停頓把句子切成 committed。
    ///
    /// - AC-47(硬需求):翻譯關閉 = 零 API 呼叫(guard 在最前)。
    /// - 尾巴為空(該句已 committed / 靜音 / 斷線 reset)→ 收掉 provisional。
    /// - 尾巴每變一次就取消在途、重排 250ms debounce:partial ~1s 才更新一次,coalesce 掉微調,
    ///   避免每次微幅修正都打一發 API。
    func observePartialTail(_ tail: String) {
        guard config.liveTranslationEnabled else {
            provisionalTask?.cancel(); provisionalTask = nil
            provisional = nil
            return
        }
        let trimmed = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            provisionalTask?.cancel(); provisionalTask = nil
            provisional = nil
            return
        }
        // 太短不值得翻(尾音、單字雜訊)。
        guard trimmed.count >= 2 else { return }

        provisionalTask?.cancel()
        let (system, user) = MeetingTranslationPrompt.build(
            text: trimmed,
            sourceLanguage: config.translationSourceLanguage,
            targetLanguage: config.translationTargetLanguage)
        let stream = self.chat
        let pid = self.provisionalId
        provisionalTask = Task { [weak self] in
            // debounce:等 250ms;期間又有新尾巴就會 cancel 掉這個 Task(連 network 一起收)。
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            // 先擺原文尾巴佔位(還沒譯文時字幕顯示原文,不空白)。
            self.provisional = FeedLine(id: pid, committedAt: Date(), original: trimmed, translated: trimmed)
            var acc = ""
            do {
                for try await delta in stream.stream(system: system, user: user) {
                    if Task.isCancelled { return }
                    acc += delta
                    let t = acc.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty {
                        self.provisional = FeedLine(id: pid, committedAt: Date(), original: trimmed, translated: t)
                    }
                }
            } catch {
                // 靜默:provisional 失敗留原文尾巴,不吵(比照 committed 的失敗紀律)。
            }
        }
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

    /// 測試用:等待目前的 provisional 翻譯(含 250ms debounce)跑完。
    func drainProvisionalForTest() async {
        await provisionalTask?.value
    }
}
