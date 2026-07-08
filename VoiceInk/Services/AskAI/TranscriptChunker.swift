import Foundation

/// Ask AI 索引的切塊單位。
struct ChunkDraft: Equatable {
    let index: Int
    let text: String
}

/// 把一筆轉錄切成 ~targetTokens 的塊:講者輪次優先(輪次不切斷)、無輪次時按段落,
/// 尺寸用 CJK-aware 的 `TokenEstimator` 控制;塊間帶 overlapRatio 的尾句重疊。
/// 純函式——IOProc 般的零依賴,索引服務與測試共用。
enum TranscriptChunker {

    static func chunks(for text: String,
                       speakerSegments: [SpeakerSegment] = [],
                       targetTokens: Int = 450,
                       maxTokens: Int = 512,
                       overlapRatio: Double = 0.1) -> [ChunkDraft] {
        let units = makeUnits(text: text, speakerSegments: speakerSegments)
        guard !units.isEmpty else { return [] }

        var drafts: [ChunkDraft] = []
        var current: [String] = []
        var currentTokens = 0
        var overlapTail = ""

        func flush() {
            guard !current.isEmpty else { return }
            let body = current.joined(separator: "\n\n")
            let chunkText = overlapTail.isEmpty ? body : overlapTail + "\n\n" + body
            drafts.append(ChunkDraft(index: drafts.count, text: chunkText))
            overlapTail = trailingSentences(of: body, upToTokens: Int(Double(targetTokens) * overlapRatio))
            current = []; currentTokens = 0
        }

        for unit in units {
            let unitTokens = TokenEstimator.estimate(unit)
            if unitTokens > maxTokens {
                // 單一單位就超限 → 先收前面,再對這個單位硬切(保守:CJK 1 char≈1 token)。
                flush()
                var rest = Substring(unit)
                while !rest.isEmpty {
                    let piece = String(rest.prefix(maxTokens))
                    rest = rest.dropFirst(piece.count)
                    drafts.append(ChunkDraft(index: drafts.count, text: piece))
                }
                overlapTail = ""   // 硬切段落不做 overlap,避免重複爆量
                continue
            }
            if currentTokens + unitTokens > targetTokens, !current.isEmpty {
                flush()
            }
            current.append(unit)
            currentTokens += unitTokens
        }
        flush()
        return drafts
    }

    /// 切塊單位:native 講者輪次("講者N：text",一輪一單位、不可切斷)或段落。
    private static func makeUnits(text: String, speakerSegments: [SpeakerSegment]) -> [String] {
        if !speakerSegments.isEmpty {
            return speakerSegments
                .map { "講者\($0.speaker)：\($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
                .filter { !$0.hasSuffix("：") }
        }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 取字串尾端的完整句子,直到約 upToTokens(供塊間 overlap)。
    private static func trailingSentences(of text: String, upToTokens: Int) -> String {
        guard upToTokens > 0 else { return "" }
        let terminators = CharacterSet(charactersIn: "。．.!?！？\n")
        var sentences: [String] = []
        var currentSentence = ""
        for ch in text {
            currentSentence.append(ch)
            if let scalar = ch.unicodeScalars.first, terminators.contains(scalar) {
                sentences.append(currentSentence); currentSentence = ""
            }
        }
        if !currentSentence.isEmpty { sentences.append(currentSentence) }

        var tail: [String] = []
        var tokens = 0
        for sentence in sentences.reversed() {
            let t = TokenEstimator.estimate(sentence)
            if tokens + t > upToTokens, !tail.isEmpty { break }
            tail.insert(sentence, at: 0)
            tokens += t
            if tokens >= upToTokens { break }
        }
        return tail.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
