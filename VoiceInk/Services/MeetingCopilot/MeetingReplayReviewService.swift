import Foundation

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
