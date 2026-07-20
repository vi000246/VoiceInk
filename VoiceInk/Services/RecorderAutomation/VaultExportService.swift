import Foundation
import os

/// Writes an analysis Markdown file (YAML frontmatter + analysis + collapsible raw transcript)
/// into `{vaultRoot}/{category.subfolder}/`. Markdown building is pure/testable.
@MainActor
final class VaultExportService {
    static let shared = VaultExportService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() {}

    struct ExportInput {
        let analysis: String
        let rawTranscript: String
        let categoryName: String
        let deviceName: String?
        /// 來源標籤（如「會議 · Zoom」）；錄音筆匯入為 nil。
        var sourceLabel: String? = nil
        let date: Date
        let transcriptionModel: String?
        let enhancementModel: String?
        let confidence: Double?
    }

    /// Pure: build the Markdown document. Frontmatter values are YAML-escaped minimally.
    /// When `includeRawTranscript` is true, the full raw transcript is appended below a horizontal
    /// rule at the bottom of the note; when false (default) the note carries only the analysis.
    func buildMarkdown(_ input: ExportInput, includeRawTranscript: Bool = false,
                       dateFormatter: ISO8601DateFormatter = .init()) -> String {
        func esc(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "\"\"" }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let confidenceLine = input.confidence.map { "confidence: \(String(format: "%.2f", $0))\n" } ?? ""
        // 來源標籤（會議擷取才有）；nil 時整行省略，與 confidence 的條件輸出方式一致。
        let sourceLine = input.sourceLabel.map { "來源: \($0)\n" } ?? ""
        var doc = """
        ---
        date: \(dateFormatter.string(from: input.date))
        source_device: \(esc(input.deviceName))
        \(sourceLine)category: \(esc(input.categoryName))
        transcription_model: \(esc(input.transcriptionModel))
        enhancement_model: \(esc(input.enhancementModel))
        \(confidenceLine)---

        \(input.analysis)
        """
        if includeRawTranscript {
            doc += """


            ---

            ## 原始逐字稿

            \(input.rawTranscript)
            """
        }
        return doc
    }

    /// Sanitized, collision-resistant file name: `YYYY-MM-DD HHmm <category> <short title>.md`.
    /// `title` is an AI-generated ≤10-char content summary.
    func suggestedFileName(date: Date, categoryName: String, title: String?) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = f.string(from: date)
        let parts = [stamp, categoryName, title].compactMap { $0 }.filter { !$0.isEmpty }
        let base = parts.joined(separator: " ")
        let safe = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        return safe + ".md"
    }

    /// Write the markdown into `{vaultRoot}/{subfolder}/{fileName}`, returning the file URL.
    func export(markdown: String, fileName: String, vaultRoot: URL, subfolder: String) throws -> URL {
        let accessing = vaultRoot.startAccessingSecurityScopedResource()
        defer { if accessing { vaultRoot.stopAccessingSecurityScopedResource() } }
        let dir = vaultRoot.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dst = dir.appendingPathComponent(fileName)
        // Collision policy: suffix " (n)" before the extension.
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            let stem = fileName.replacingOccurrences(of: ".md", with: "")
            dst = dir.appendingPathComponent("\(stem) (\(n)).md")
            n += 1
        }
        try markdown.data(using: .utf8)?.write(to: dst)
        return dst
    }

    /// Resolve a device's stored vault-root bookmark to a URL.
    /// nonisolated:解析可能觸發磁碟 I/O(vault 在外接/網路磁碟時),晨間簡報要在
    /// 背景執行緒呼叫以免凍結主執行緒;本函式無共享狀態,脫離 MainActor 安全。
    nonisolated func resolveVaultRoot(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
