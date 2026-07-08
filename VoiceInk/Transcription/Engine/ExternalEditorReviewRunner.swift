import Foundation
import os

enum ExternalEditorReviewError: Error, LocalizedError {
    case emptyCommand
    case launchFailed(String)
    case nonZeroExit(Int32)

    var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return String(localized: "尚未設定編輯器命令。")
        case .launchFailed(let message):
            return String(format: String(localized: "編輯器無法啟動：%@"), message)
        case .nonZeroExit(let status):
            return String(format: String(localized: "編輯器以狀態 %d 結束（可能未存檔）。"), status)
        }
    }
}

/// 「編輯後貼上」的外部編輯器 round-trip：把聽寫結果寫進暫存檔 → 阻塞跑編輯器命令（真 vim/nvim，
/// 支援 vimrc 熱鍵）→ 讀回使用者存檔後的內容。鏡射 CustomCommandDeliveryRunner 的 Process 樣式，
/// 但編輯是人操作，等到進程結束、不設短逾時。
enum ExternalEditorReviewRunner {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ExternalEditorReview")

    /// 檔案路徑以環境變數 `VOICEINK_EDIT_FILE` 傳入，命令中的 `{file}` 會換成 `"$VOICEINK_EDIT_FILE"`
    /// ——比字面插入路徑更安全（暫存目錄含空白的「Application Support」也不會壞，也免去巢狀引號問題）。
    static let filePlaceholder = "{file}"
    static let fileEnvVar = "VOICEINK_EDIT_FILE"

    /// 寫 text 進暫存 .md → 跑 command 阻塞編輯 → 讀回內容。命令零離開 → 回讀回內容;非零 → throw。
    static func review(text: String, command: String) async throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ExternalEditorReviewError.emptyCommand }

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("VoiceInkEdit")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(UUID().uuidString).md")
        try (text.data(using: .utf8) ?? Data()).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let resolved = trimmed.replacingOccurrences(of: filePlaceholder, with: "\"$\(fileEnvVar)\"")
        try await runBlocking(resolved, filePath: file.path)
        return (try? String(contentsOf: file, encoding: .utf8)) ?? text
    }

    private static func runBlocking(_ command: String, filePath: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", command]
                process.environment = ShellCommandEnvironment.commandEnvironment(
                    additionalEnvironment: [fileEnvVar: filePath])

                let semaphore = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in semaphore.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ExternalEditorReviewError.launchFailed(error.localizedDescription))
                    return
                }
                semaphore.wait()   // 人在編輯，等到編輯器進程結束（不設短逾時）
                if process.terminationStatus == 0 {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: ExternalEditorReviewError.nonZeroExit(process.terminationStatus))
                }
            }
        }
    }
}
