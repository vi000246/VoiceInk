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
        let date: Date
        let transcriptionModel: String?
        let enhancementModel: String?
        let confidence: Double?
    }

    /// Pure: build the Markdown document. Frontmatter values are YAML-escaped minimally.
    func buildMarkdown(_ input: ExportInput, dateFormatter: ISO8601DateFormatter = .init()) -> String {
        func esc(_ s: String?) -> String {
            guard let s, !s.isEmpty else { return "\"\"" }
            return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let confidenceLine = input.confidence.map { "confidence: \(String(format: "%.2f", $0))\n" } ?? ""
        return """
        ---
        date: \(dateFormatter.string(from: input.date))
        source_device: \(esc(input.deviceName))
        category: \(esc(input.categoryName))
        transcription_model: \(esc(input.transcriptionModel))
        enhancement_model: \(esc(input.enhancementModel))
        \(confidenceLine)---

        \(input.analysis)

        > [!note]- 原始逐字稿
        \(input.rawTranscript.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n"))
        """
    }

    /// Sanitized, collision-resistant file name: `YYYY-MM-DD HHmm <category> <device>.md`.
    func suggestedFileName(date: Date, categoryName: String, deviceName: String?) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = f.string(from: date)
        let parts = [stamp, categoryName, deviceName].compactMap { $0 }.filter { !$0.isEmpty }
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
    func resolveVaultRoot(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope],
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
