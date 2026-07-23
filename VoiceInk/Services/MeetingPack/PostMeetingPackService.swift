import Foundation
import AppKit
import SwiftData
import LLMkit
import os

/// 會後自動閉環包(M12)的編排:會議匯入完成(fingerprint 已回填)→ 組逐字稿 →
/// LLM 生成結構化會後包 → 寫 Obsidian vault → 通知(可一鍵把「我答應的」建成 Vikunja 任務)。
///
/// 紅線:**內容絕不因 LLM 失敗而不落地**——解析失敗補一次重試,再失敗就匯出
/// 「僅含原始逐字稿 + 失敗註記」的筆記。Vikunja 未設定時按鈕不出現,筆記照樣有完整清單。
@MainActor
final class PostMeetingPackService {

    static let shared = PostMeetingPackService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingPack")

    private init() {}

    /// 會議匯入完成 hook(`AudioFileTranscriptionManager` 的 `.meetingCapture` 收尾呼叫)。
    /// copilot 開著 → 用雙聲道 session 資料;沒開 → 用 Transcription 逐字稿。
    func handleMeetingImportCompleted(
        transcription: Transcription,
        modelContext: ModelContext,
        aiService: AIService?
    ) async {
        let config = MeetingPackConfigStore.shared
        guard config.enabled else { return }
        guard let fp = transcription.importFingerprint, !fp.isEmpty else { return }

        // 本場會議的 live session(中途開關 copilot 會有多個;replay 是事後產物,不混入)。
        let descriptor = FetchDescriptor<MeetingLiveSession>(
            predicate: #Predicate { $0.importFingerprint == fp })
        let fetched: [MeetingLiveSession]
        do {
            fetched = try modelContext.fetch(descriptor)
        } catch {
            // 查詢失敗只是讓會後包退化成「無我/對方標籤」版本,效果跟沒開 copilot 一樣——
            // 不留 log 的話,品質變差完全無從回溯到這裡。
            logger.error("📦 live session 查詢失敗: \(error, privacy: .public)")
            fetched = []
        }
        let sessions = fetched
            .filter { $0.sourceRaw == "live" }
            .sorted { $0.startedAt < $1.startedAt }

        let segments = sessions
            .flatMap { $0.segments ?? [] }
            .map { MeetingPackSegment(isLocal: $0.channel == .local, text: $0.text, committedAt: $0.committedAt) }
        let transcript = MeetingPackExtraction.assembleTranscript(
            segments: segments,
            remoteRaw: sessions.map(\.remoteTranscriptRaw).filter { !$0.isEmpty }.joined(separator: "\n"),
            localRaw: sessions.map(\.localTranscriptRaw).filter { !$0.isEmpty }.joined(separator: "\n"),
            transcriptionText: transcription.text)
        guard !transcript.isEmpty else {
            logger.notice("📦 會後包跳過 — 逐字稿為空 fingerprint=\(fp, privacy: .public)")
            // 靜默跳過會讓使用者以為功能壞了(「這場怎麼沒有會後包?」)——據實告知。
            NotificationManager.shared.showNotification(
                title: "本場會議沒有可用逐字稿,未產生會後包", type: .warning, duration: 6)
            return
        }

        let appName = transcription.recorderSourceLabel
            ?? sessions.first(where: { !$0.appName.isEmpty })?.appName
            ?? "會議"
        let startedAt = sessions.first?.startedAt ?? transcription.timestamp
        let endedAt = sessions.compactMap(\.endedAt).max()
        let brief = sessions.first(where: { !$0.brief.isEmpty })?.brief ?? ""

        // M15:會中即時偵測到的承諾 cue 當候選提示餵給 LLM(合併去重由 prompt 交代)。
        let commitmentCues: [MeetingLiveCue] = sessions
            .flatMap { $0.cues ?? [] }
            .filter { $0.kind == .commitment }
            .sorted { $0.askedAt < $1.askedAt }
        let detectedCommitments: [String] = commitmentCues.map { cue in
            cue.dueHint.isEmpty ? cue.text : "\(cue.text)(口頭期限:\(cue.dueHint))"
        }

        let extraction = await generate(
            transcript: transcript, appName: appName,
            startedAt: startedAt, endedAt: endedAt, brief: brief,
            detectedCommitments: detectedCommitments, aiService: aiService)

        // 寫 vault(vault root 沿用錄音設定)。兩種失敗要分開講:未設定→去設定;
        // bookmark 解析失敗(資料夾搬移/授權被撤銷)→重新選資料夾。混成一句使用者不知道該做哪個。
        guard let bookmark = RecorderConfigStore.shared.vaultRootBookmark else {
            NotificationManager.shared.showNotification(
                title: "會後包未匯出:尚未設定 Obsidian Vault 根目錄", type: .warning, duration: 6)
            return
        }
        guard let vaultRoot = VaultExportService.shared.resolveVaultRoot(bookmark) else {
            NotificationManager.shared.showNotification(
                title: "會後包未匯出:Vault 資料夾授權失效,請到錄音設定重新選擇", type: .warning, duration: 8)
            return
        }
        let analysis = extraction.map { MeetingPackExtraction.buildAnalysisMarkdown($0) }
            ?? MeetingPackExtraction.fallbackAnalysisMarkdown()
        let shortTitle = extraction.flatMap { $0.shortTitle.isEmpty ? nil : $0.shortTitle }
        let input = VaultExportService.ExportInput(
            analysis: analysis,
            rawTranscript: transcript,
            categoryName: "會後包",
            deviceName: nil,
            sourceLabel: transcription.recorderSourceLabel,
            date: startedAt,
            transcriptionModel: transcription.transcriptionModelName,
            // fallback 筆記不得謊報 AI 模型——正文寫「生成失敗」frontmatter 卻列模型,
            // Dataview 用 enhancement_model 篩「已 AI 整理」時會誤中。
            enhancementModel: extraction == nil ? nil
                : aiService.map { "\($0.selectedProvider.rawValue)/\($0.selectedModel(for: $0.selectedProvider))" },
            confidence: nil)
        let markdown = VaultExportService.shared.buildMarkdown(input, includeRawTranscript: true)
        let fileName = VaultExportService.shared.suggestedFileName(
            date: startedAt, categoryName: "會後包", title: shortTitle)
        let exportedURL: URL
        do {
            exportedURL = try VaultExportService.shared.export(
                markdown: markdown, fileName: fileName, vaultRoot: vaultRoot, subfolder: config.subfolder)
        } catch {
            logger.error("📦 會後包匯出失敗: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: "會後包匯出失敗:\(error.localizedDescription)", type: .error, duration: 8)
            return
        }
        logger.notice("📦 會後包已匯出 \(exportedURL.lastPathComponent, privacy: .public)(LLM \(extraction == nil ? "fallback" : "ok", privacy: .public))")

        // 通知:onTap 開 Obsidian 筆記;可選的「加入 Vikunja」按鈕。
        let openNote: () -> Void = {
            if let url = ObsidianLink.openURL(
                vaultRoot: exportedURL.deletingLastPathComponent(),
                relativePath: exportedURL.lastPathComponent) {
                NSWorkspace.shared.open(url)
            }
        }
        guard let extraction else {
            NotificationManager.shared.showNotification(
                title: "會後包已匯出(AI 生成失敗,僅含原始逐字稿)",
                type: .warning, duration: 8, onTap: openNote)
            return
        }

        let title = "會後包已就緒:\(shortTitle ?? appName)"
        let drafts = MeetingPackExtraction.vikunjaDrafts(
            from: extraction.myCommitments, noteFileName: exportedURL.lastPathComponent)
        // 只看連線設定(URL/專案/token),不看 `enabled`——那是熱鍵語音記待辦的開關,
        // 沒開熱鍵也該能從會後包建任務(與設定頁「需先完成連線設定」的文案一致)。
        guard !drafts.isEmpty, VikunjaConfigStore.shared.isConnectionReady else {
            // 沒有承諾項或 Vikunja 連線未設定:按鈕不出現,筆記照樣有完整清單,不阻塞。
            NotificationManager.shared.showNotification(
                title: title, type: .success, duration: 8, onTap: openNote)
            return
        }
        if config.vikunjaAutoCreate {
            let (ok, failed) = await createVikunjaTasks(drafts)
            NotificationManager.shared.showNotification(
                title: "\(title)，\(MeetingPackExtraction.batchResultTitle(succeeded: ok, failed: failed))",
                type: failed == 0 ? .success : .warning, duration: 8, onTap: openNote)
        } else {
            NotificationManager.shared.showNotification(
                title: title, type: .success, duration: 10, onTap: openNote,
                actionButton: ("加入 Vikunja(\(drafts.count))", { [weak self] in
                    Task { @MainActor in
                        guard let self else { return }
                        let (ok, failed) = await self.createVikunjaTasks(drafts)
                        NotificationManager.shared.showNotification(
                            title: MeetingPackExtraction.batchResultTitle(succeeded: ok, failed: failed),
                            type: failed == 0 ? .success : .warning, duration: 8, onTap: openNote)
                    }
                }))
        }
    }

    // MARK: - LLM 生成(補一次重試;任何失敗回 nil → fallback 筆記)

    private func generate(
        transcript: String, appName: String,
        startedAt: Date?, endedAt: Date?, brief: String,
        detectedCommitments: [String] = [],
        aiService: AIService?
    ) async -> MeetingPackExtraction? {
        guard let aiService else {
            // 沒接 AI provider 也要留痕:對外通知與 LLM 失敗共用同一句,只有這裡分得出原因。
            logger.notice("📦 未接 AI provider — 會後包走 fallback(僅逐字稿)")
            return nil
        }
        let (clipped, truncated) = MeetingPackExtraction.truncate(transcript)
        let userMessage = MeetingPackExtraction.buildUserMessage(
            transcript: clipped, truncated: truncated, appName: appName,
            startedAt: startedAt, endedAt: endedAt, brief: brief,
            detectedCommitments: detectedCommitments)
        for attempt in 1...2 {
            do {
                let raw = try await aiService.completeChat(
                    provider: aiService.selectedProvider,
                    modelName: nil,
                    messages: [ChatMessage.user(userMessage)],
                    systemPrompt: MeetingPackExtraction.systemPrompt,
                    timeout: 120,
                    usageFeature: .meetingPack)
                if let parsed = MeetingPackExtraction.parse(raw) { return parsed }
                logger.error("📦 會後包 JSON 解析失敗(attempt \(attempt, privacy: .public))")
            } catch {
                logger.error("📦 會後包 LLM 失敗(attempt \(attempt, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            }
        }
        return nil
    }

    // MARK: - Vikunja 批次建立(部分失敗據實回報;失敗項留在筆記裡不遺失)

    private func createVikunjaTasks(_ drafts: [MeetingPackExtraction.VikunjaDraft]) async -> (succeeded: Int, failed: Int) {
        let config = VikunjaConfigStore.shared
        guard let token = config.token, !token.isEmpty else { return (0, drafts.count) }
        let service = VikunjaService(baseURL: config.baseURL, token: token)
        var ok = 0, failed = 0
        for draft in drafts {
            do {
                _ = try await service.createTask(
                    projectId: config.defaultProjectID,
                    title: draft.title, description: draft.description,
                    dueDate: draft.dueDate, priority: draft.priority)
                ok += 1
            } catch {
                failed += 1
                logger.error("📦 Vikunja 建任務失敗「\(draft.title, privacy: .public)」: \(error.localizedDescription, privacy: .public)")
            }
        }
        return (ok, failed)
    }
}
