import Foundation
import CryptoKit

/// Obsidian 筆記 → 索引塊的純函式（切塊委給既有 TranscriptChunker）。
enum ObsidianNoteChunking {

    /// 去 YAML frontmatter：檔案以 "---\n" 開頭且存在收尾 "\n---" 才剝，否則原樣。
    static func stripFrontmatter(_ md: String) -> String {
        guard md.hasPrefix("---\n") else { return md }
        let afterOpen = md.index(md.startIndex, offsetBy: 4)
        guard let close = md.range(of: "\n---", range: afterOpen..<md.endIndex) else { return md }
        var body = String(md[close.upperBound...])
        if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 每塊前綴《標題》供 LLM 引用出處；切塊沿用 TranscriptChunker（段落、CJK-aware）。
    static func chunks(title: String, body: String) -> [ChunkDraft] {
        TranscriptChunker.chunks(for: body).map {
            ChunkDraft(index: $0.index, text: "《\(title)》\n\($0.text)")
        }
    }

    /// vault 相對路徑 → 確定性 UUID（SHA-256 前 16 bytes）。改名＝新 id＝舊塊變孤兒由 diff 清。
    static func noteId(relativePath: String) -> UUID {
        let digest = SHA256.hash(data: Data(relativePath.utf8))
        let bytes = Array(digest.prefix(16))
        return NSUUID(uuidBytes: bytes) as UUID
    }
}
