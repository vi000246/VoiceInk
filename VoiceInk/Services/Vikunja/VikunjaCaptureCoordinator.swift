import Foundation
import AppKit
import LLMkit
import os

/// LLM 從口述文字抽出的任務欄位(純資料 + 純函式,可完全離線測試)。
struct VikunjaCaptureExtraction: Equatable {
    var title: String
    var description: String
    var dueDate: Date?
    var priority: Int

    static let priorityRange = 0...5
    /// fallback title 的截斷長度(Vikunja title 不宜整段口述塞入;全文保留在 description)。
    static let fallbackTitleLimit = 120

    // MARK: - Prompt

    static let systemPrompt = """
    你是語音待辦捕捉助手。使用者口述一段話,你要把它整理成一筆待辦任務。
    只輸出一個 JSON 物件,不要任何其他文字、解釋或 markdown 圍欄:
    {"title": "...", "description": "...", "due_date": "..." 或 null, "priority": 0}
    規則:
    - title:必填。短任務名,去除語助詞與贅字(「呃」「那個」「幫我記一下」之類)。
    - description:補充細節或原句;沒有就給空字串。
    - due_date:RFC3339 含時區位移(例 "2026-07-18T15:00:00+08:00")。「明天下午三點」「週五前」等\
    相對時間要以下方提供的「現在時刻」換算成絕對時間;只講日期沒講時刻用當天 09:00;完全沒提時間就給 null,\
    絕對不要編造時間。
    - priority:0-5 整數。沒提急迫性給 0;「很急」「馬上」「今天一定要」→ 5;「重要」→ 3。
    """

    /// user message 附上現在時刻(含星期與時區)——沒有這個,「明天」「週五」無從換算。
    static func buildUserMessage(
        transcript: String,
        now: Date = Date(),
        timeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "zh_TW")
        dateFormatter.timeZone = timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        let weekdayFormatter = DateFormatter()
        weekdayFormatter.locale = Locale(identifier: "zh_TW")
        weekdayFormatter.timeZone = timeZone
        weekdayFormatter.dateFormat = "EEEE"

        let offsetSeconds = timeZone.secondsFromGMT(for: now)
        let sign = offsetSeconds >= 0 ? "+" : "-"
        let offset = String(format: "%@%02d:%02d", sign, abs(offsetSeconds) / 3600, abs(offsetSeconds) % 3600 / 60)

        return """
        現在時刻:\(dateFormatter.string(from: now))(\(weekdayFormatter.string(from: now)),時區 \(timeZone.identifier) \(offset))
        口述內容:
        \(transcript)
        """
    }

    // MARK: - Parse

    private struct DTO: Decodable {
        var title: String?
        var description: String?
        var due_date: String?
        /// Double 容忍模型回 3.0 這種浮點。
        var priority: Double?
    }

    /// 剝 ```json 圍欄後 JSONDecoder。**任何解析失敗都退回 `fallback`——捕捉絕不可因 LLM 失敗而遺失。**
    static func parse(_ raw: String, transcript: String) -> VikunjaCaptureExtraction {
        guard let data = extractJSONObject(from: raw)?.data(using: .utf8),
              let dto = try? JSONDecoder().decode(DTO.self, from: data) else {
            return fallback(transcript: transcript)
        }

        let title = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else {
            return fallback(transcript: transcript)
        }

        return VikunjaCaptureExtraction(
            title: title,
            description: dto.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            dueDate: parseDueDate(dto.due_date),
            priority: clampPriority(dto.priority)
        )
    }

    /// LLM 失敗/回垃圾時的保底:title = 原文(trim、截 120 字)、無時間、priority 0。
    static func fallback(transcript: String) -> VikunjaCaptureExtraction {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = String(trimmed.prefix(fallbackTitleLimit))
        // 截斷過就把全文留在 description,一個字都不丟。
        let description = trimmed.count > fallbackTitleLimit ? trimmed : ""
        return VikunjaCaptureExtraction(title: title, description: description, dueDate: nil, priority: 0)
    }

    /// 取第一個 `{` 到最後一個 `}` 之間的子字串——同時吃掉 ```json 圍欄與前後贅字。
    static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end else {
            return nil
        }
        return String(raw[start...end])
    }

    /// RFC3339(含可選小數秒)→ Date。Vikunja 的 "0001-…" 未設定 sentinel 視同 nil,不當真日期。
    static func parseDueDate(_ string: String?) -> Date? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty,
              !string.hasPrefix("0001") else {
            return nil
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    static func clampPriority(_ raw: Double?) -> Int {
        guard let raw, raw.isFinite else { return 0 }
        return min(max(Int(raw.rounded()), priorityRange.lowerBound), priorityRange.upperBound)
    }
}

/// 串「熱鍵 → 一次性錄音 → 轉錄 → LLM 抽取 → 建 Vikunja 任務 → 通知」的編排。
///
/// 紅線:**捕捉內容絕不遺失**——LLM 失敗退 fallback 照建任務;建任務失敗把轉錄文字放剪貼簿;
/// 轉錄本身照舊落進語音歷史(pipeline 存檔先於交付)。
@MainActor
final class VikunjaCaptureCoordinator {

    static let shared = VikunjaCaptureCoordinator()

    private init() {}

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "VikunjaCapture")

    /// 剪貼簿保底的通知標題(純函式供測試)。`copied` 是 `ClipboardManager.copyToClipboard` 的
    /// 實際結果——寫入可能被剪貼簿管理工具搶佔而失敗,失敗時不得謊稱「已複製」,
    /// 改指向語音歷史(pipeline 交付前已存檔,route 覆寫也不走 targetIsSelf 清理,那裡永遠有底)。
    nonisolated static func clipboardRescueTitle(prefix: String, copied: Bool) -> String {
        copied
            ? "\(prefix),轉錄內容已複製到剪貼簿"
            : "\(prefix),複製到剪貼簿失敗——內容仍保留在「語音管理」歷史"
    }

    /// 通知上顯示 due date 用(跟著系統時區走,使用者在哪看就是哪的牆鐘時間)。
    private static let dueDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.dateFormat = "M/d(EEE) HH:mm"
        return formatter
    }()

    /// `.voiceCaptureVikunja` 熱鍵入口(keyUp-only)。第一按啟動錄音,第二按停止並送轉錄。
    func handleHotkey(engine: VoiceInkEngine, recorderUIManager: RecorderUIManager) async {
        switch engine.recordingState {
        case .recording, .starting:
            guard engine.hasTranscriptRouteOverride else {
                // 正在跑的是一般聽寫——不劫持它的內容,提示後放行。
                NotificationManager.shared.showNotification(
                    title: "聽寫進行中,結束後再按語音記待辦", type: .warning)
                return
            }
            // 我方會話的第二按:停止錄音 → pipeline → route handler。
            await recorderUIManager.toggleRecorderPanel()
        case .idle:
            guard !recorderUIManager.isRecorderPanelVisible else {
                NotificationManager.shared.showNotification(
                    title: "錄音面板開啟中,請先關閉再按語音記待辦", type: .warning)
                return
            }
            // readiness 只擋「開新會話」——不能放在函式頂端:錄音中途設定被關掉/token
            // 被清時,第二按仍必須能收尾停止,否則錄音卡在 .recording 只能靠 Esc 逃生。
            guard VikunjaConfigStore.shared.isReadyForCapture else {
                NotificationManager.shared.showNotification(
                    title: "尚未設定 Vikunja(URL / Token / 專案),請先到設定頁完成設定",
                    type: .error,
                    duration: 6,
                    actionButton: ("打開設定", {
                        NSApplication.shared.setActivationPolicy(.regular)
                        _ = WindowManager.shared.showMainWindow()
                        AppNavigator.shared.navigate(to: .settings)
                    })
                )
                return
            }
            let aiService = engine.enhancementService?.getAIService()
            engine.transcriptRouteOverrideForNextRecording = { [weak self] transcript in
                await self?.process(transcript: transcript, aiService: aiService)
            }
            await recorderUIManager.toggleRecorderPanel()
        case .transcribing, .enhancing, .busy:
            // 上一段還在收尾,忽略這一按(跟聽寫熱鍵的 canHandleShortcutAction 同語意)。
            break
        }
    }

    /// 轉錄完成後的下游:抽取 → 建任務 → 通知。`transcript` nil = 轉錄失敗。
    func process(transcript: String?, aiService: AIService?) async {
        guard let transcript = transcript?.trimmingCharacters(in: .whitespacesAndNewlines),
              !transcript.isEmpty else {
            NotificationManager.shared.showNotification(
                title: "轉錄失敗,沒有取得待辦內容", type: .error, duration: 6)
            return
        }

        let extraction = await extract(transcript: transcript, aiService: aiService)

        let config = VikunjaConfigStore.shared
        guard let token = config.token, !token.isEmpty else {
            let copied = ClipboardManager.copyToClipboard(transcript)
            NotificationManager.shared.showNotification(
                title: Self.clipboardRescueTitle(prefix: "Vikunja token 不見了", copied: copied),
                type: .error, duration: 8)
            return
        }

        let service = VikunjaService(baseURL: config.baseURL, token: token)
        do {
            let task = try await service.createTask(
                projectId: config.defaultProjectID,
                title: extraction.title,
                description: extraction.description,
                dueDate: extraction.dueDate,
                priority: extraction.priority
            )

            var title = "已加入 Vikunja:\(extraction.title)"
            if let due = extraction.dueDate {
                title += "  ⏰ \(Self.dueDisplayFormatter.string(from: due))"
            }
            let taskURLString = VikunjaService.uiBaseURL(config.baseURL) + "/tasks/\(task.id)"
            NotificationManager.shared.showNotification(
                title: title,
                type: .success,
                duration: 6,
                actionButton: ("打開", {
                    if let url = URL(string: taskURLString) {
                        NSWorkspace.shared.open(url)
                    }
                })
            )
        } catch {
            // 紅線:建任務失敗內容不丟——放剪貼簿(據實回報結果),使用者可自行貼進 Vikunja。
            let copied = ClipboardManager.copyToClipboard(transcript)
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            logger.error("❌ Vikunja 建任務失敗: \(reason, privacy: .public)(剪貼簿保底 copied=\(copied, privacy: .public))")
            NotificationManager.shared.showNotification(
                title: Self.clipboardRescueTitle(prefix: "建立任務失敗", copied: copied)
                    + ":\(String(reason.prefix(80)))",
                type: .error,
                duration: 8
            )
        }
    }

    /// LLM 抽取;任何失敗(沒設 AI、逾時、回垃圾)都退 fallback,不 throw。
    private func extract(transcript: String, aiService: AIService?) async -> VikunjaCaptureExtraction {
        guard let aiService else {
            return VikunjaCaptureExtraction.fallback(transcript: transcript)
        }
        do {
            let raw = try await aiService.completeChat(
                provider: aiService.selectedProvider,
                modelName: nil,
                messages: [ChatMessage.user(VikunjaCaptureExtraction.buildUserMessage(transcript: transcript))],
                systemPrompt: VikunjaCaptureExtraction.systemPrompt,
                timeout: 30,
                usageFeature: .vikunjaCapture
            )
            return VikunjaCaptureExtraction.parse(raw, transcript: transcript)
        } catch {
            // 靜默降級是刻意的(功能照樣建任務,不用 LLM 細節打擾使用者),但 log 必須留——
            // 不然 AI 設定壞掉(key 過期、模型下架)時「標題永遠沒被整理」在 Console 完全隱形。
            logger.error("❌ Vikunja 抽取 LLM 失敗,退回 fallback: \(error.localizedDescription, privacy: .public)")
            return VikunjaCaptureExtraction.fallback(transcript: transcript)
        }
    }
}
