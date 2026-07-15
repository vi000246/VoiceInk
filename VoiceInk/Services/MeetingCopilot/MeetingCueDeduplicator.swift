import Foundation

/// cue 去重(FR-10):正規化 → 字元 bigram Jaccard + 時間窗。
/// 純函式 namespace,房子風格鏡射 `MeetingAudioMixer` / `MeetingChannelSplitter`。
///
/// 為什麼是**字元 bigram**而不是空白斷詞:中文沒有空白斷詞,ASR 逐字稿的
/// 中英混合句(「你會怎麼設計 rate limiter」)用 bigram 對兩種文字都穩健。
/// 門檻/窗大小是具名常數——調校時只動這兩個值,不動演算法。
enum MeetingCueDeduplicator {

    /// Jaccard 相似度門檻:>= 即視為重覆。(SRS Open Question 裁決:0.6)
    static let defaultThreshold: Double = 0.6
    /// 只與此時間窗內的既有 cue 比對。(FR-10:30 秒)
    static let defaultWindow: TimeInterval = 30

    /// 正規化:小寫、去標點/符號、壓空白。
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let stripped = lowered.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }
        return String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// 正規化後的字元 bigram 集合。
    static func tokens(_ normalized: String) -> Set<String> {
        let chars = Array(normalized.replacingOccurrences(of: " ", with: ""))
        guard chars.count >= 2 else {
            return chars.isEmpty ? [] : [String(chars[0])]
        }
        var out = Set<String>()
        out.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            out.insert(String(chars[i]) + String(chars[i + 1]))
        }
        return out
    }

    /// bigram Jaccard(0...1)。任一邊為空 → 0。
    static func jaccard(_ a: String, _ b: String) -> Double {
        let ta = tokens(normalize(a))
        let tb = tokens(normalize(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    /// 相似度 = **max(Jaccard, 包含度)**,包含度 = 交集 / 較短一方的 bigram 數。
    ///
    /// 純 Jaccard 的分母是聯集,長句把聯集撐大 → 短碎片就算完全被長句涵蓋也壓不過門檻
    /// (「e conflict.」⊂「…efforts to resolve the conflict.」的 Jaccard ≈ 0.2)。切碎的殘尾
    /// 因此躲過去重、被當成新問題(2026-07-15 事故)。包含度正是「短片是否被涵蓋」的量,
    /// 取 max 保留 Jaccard 對等長句的判斷力。與 `MeetingReviewSweep.similarity` 同一公式。
    static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(normalize(a))
        let tb = tokens(normalize(b))
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = Double(ta.intersection(tb).count)
        let jaccard = inter / Double(ta.union(tb).count)
        let containment = inter / Double(min(ta.count, tb.count))
        return max(jaccard, containment)
    }

    /// FR-10:與時間窗內任一既有 cue 相似度 >= threshold → 重覆(呼叫端丟棄,不 persist)。
    static func isDuplicate(
        text: String,
        at time: Date,
        existing: [(text: String, askedAt: Date)],
        threshold: Double = defaultThreshold,
        window: TimeInterval = defaultWindow
    ) -> Bool {
        guard !text.isEmpty else { return false }
        for prior in existing where abs(time.timeIntervalSince(prior.askedAt)) <= window {
            if similarity(text, prior.text) >= threshold { return true }
        }
        return false
    }
}
