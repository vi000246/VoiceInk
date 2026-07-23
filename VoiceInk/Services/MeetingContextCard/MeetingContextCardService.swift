import AppKit
import CoreGraphics
import SwiftData
import LLMkit
import os

// MARK: - 可注入 seam（測試 fake；正式實作在檔尾）

/// RAG 檢索。任何失敗回 []（降級不彈 UI，理由同 `MeetingGroundingProvider`：
/// 直呼底層而非 `AskAIService.ask`，空索引/無 key 不得產生可見診斷訊息——
/// 但失敗必須留 log，否則「key 失效」與「真的零命中」事後無從區分）。
@MainActor
protocol ContextCardRetrieving {
    func retrieve(query: String) async -> [ContextChunkInfo]
}

/// Vikunja 未結任務。未設定連線 → 回 []；網路失敗 → throw（呼叫端記 log、區塊省略）。
@MainActor
protocol ContextCardTaskListing {
    func openTasks() async throws -> [VikunjaService.TaskItem]
}

/// LLM 濃縮。
@MainActor
protocol ContextCardCompleting {
    func complete(system: String, user: String) async throws -> String
}

/// 呈現層（浮窗/通知）。抽 seam 讓 service 的編排測試不碰 NSPanel/NotificationManager。
@MainActor
protocol ContextCardPresenting {
    /// autoShow 路徑：直接浮出卡片（帶自動淡出）。
    func showCard()
    /// 通知路徑：發「準備好了」通知，點了才開卡。
    func notifyCardReady()
}

// MARK: - Service

/// M14 會議脈絡卡的編排：觸發去重 → 視窗標題 → query 建構 → RAG + Vikunja → LLM 濃縮 → 呈現。
///
/// 觸發入口有兩個（同場共用 `ContextCardGate` 去重，同一偵測窗只出一張卡）：
/// 1. M11 偵測命中（`MeetingStartDetector` 的 `.prompt` effect——原有「開錄提示」通知照發，卡並行生成）；
/// 2. 使用者開始會議錄音（`MeetingCaptureController.start`）。
///
/// 紅線：**絕不阻塞會議錄音/copilot 啟動**——觸發入口是同步 call-out、立即返回，
/// 生成全部在背景 Task；任何資料源失敗都降級（退化卡/區塊省略），不彈錯誤。
@MainActor
final class MeetingContextCardService: ObservableObject {

    static let shared = MeetingContextCardService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingContextCard")

    /// RAG top-K。
    static let ragK = 8
    /// cosine 下限——碎片/離題 query 在純 top-k 下會硬撈回 k 個不相關塊再被 LLM 當「事實」
    /// 濃縮成自信亂答（沿用 `AnswerCoordinator.aboutMeRAGMinScore` 的教訓與數值）。
    static let ragMinScore: Float = 0.2
    static let llmTimeout: TimeInterval = 45
    /// 觸發後超過這個秒數才生成完 → 會議早已開場（甚至已結束），autoShow 直接彈卡會變成
    /// 「事後突然冒出一張脫節的卡」；降級成通知（可忽略、點了才開）。單步雖各有上限
    ///（LLM 45s、URLSession 預設 ~60s），但三步串行最壞可疊到分鐘級，必須有這道總體閘。
    static let autoShowStaleAfter: TimeInterval = 90

    @Published private(set) var model: MeetingContextCardModel?
    @Published private(set) var isGenerating = false

    private var retriever: ContextCardRetrieving?
    private var taskLister: ContextCardTaskListing?
    private var completer: ContextCardCompleting?
    private var presenter: ContextCardPresenting = LiveContextCardPresenter()
    private let config: MeetingContextCardConfigStore
    private var gate = ContextCardGate()
    /// 舊一輪的生成結果不得蓋掉新一輪（樣式同 `MorningBriefingService.generation`）。
    private var generation = 0
    /// 可注入時鐘——gate 去重與 present 的過期降級都用它（測試控制時間、不 sleep）。
    private var now: () -> Date = { Date() }
    /// 視窗標題讀取（正式走 CGWindowList；測試注入固定值，不碰螢幕錄製權限 API）。
    private var windowTitleProvider: (Set<String>) -> String? = {
        MeetingContextCardService.bestWindowTitle(ownerNames: $0)
    }

    init(config: MeetingContextCardConfigStore = .shared) {
        self.config = config
    }

    /// app 啟動時注入（VoiceInk.swift；mainContext 涵蓋 index.store）。
    func configure(aiService: AIService, modelContext: ModelContext) {
        retriever = LiveContextCardRetriever(modelContext: modelContext)
        taskLister = LiveContextCardTaskLister()
        completer = LiveContextCardCompleter(aiService: aiService)
    }

    func configureForTesting(retriever: ContextCardRetrieving,
                             taskLister: ContextCardTaskListing,
                             completer: ContextCardCompleting,
                             presenter: ContextCardPresenting,
                             now: @escaping () -> Date = { Date() },
                             windowTitle: @escaping (Set<String>) -> String? = { _ in nil }) {
        self.retriever = retriever
        self.taskLister = taskLister
        self.completer = completer
        self.presenter = presenter
        self.now = now
        self.windowTitleProvider = windowTitle
        gate.reset()
        model = nil
    }

    // MARK: - 觸發入口

    /// 入口 1：M11 偵測命中。呼叫端（`MeetingStartDetector`）的提示通知照發——本方法只並行
    /// 生成脈絡卡，立即返回，絕不干擾原有流程。
    func noteMeetingDetected(bundleId: String, displayName: String) {
        trigger(appName: displayName,
                ownerNames: Self.ownerNames(bundleId: bundleId, displayName: displayName))
    }

    /// 入口 2：會議錄音開始（手動或通知按鈕）。appName = 開錄當下的前景 app 名。
    func noteRecordingStarted(appName: String?) {
        let name = (appName?.isEmpty == false) ? appName! : "會議"
        trigger(appName: name, ownerNames: [name])
    }

    private func trigger(appName: String, ownerNames: Set<String>) {
        guard config.enabled else { return }
        guard retriever != nil, completer != nil else {
            // 啟動順序若被調動（detector 先跑、configure 還沒到），命中會整批消失在這——
            // 必須留 log，否則「那次偵測為什麼沒出卡」事後無從查起。
            logger.error("🗂 脈絡卡觸發被丟棄：service 尚未 configure（\(appName, privacy: .public)）")
            return
        }
        let triggeredAt = now()
        guard gate.shouldTrigger(now: triggeredAt) else {
            logger.notice("🗂 脈絡卡去重：cooldown 窗內已觸發過，略過（\(appName, privacy: .public)）")
            return
        }
        // 標題在觸發當下就讀（會議視窗此刻確定在螢幕上；等背景 Task 排到時可能已切走）。
        let windowTitle = windowTitleProvider(ownerNames)
        Task { [weak self] in
            await self?.generateAndPresent(appName: appName, windowTitle: windowTitle,
                                           triggeredAt: triggeredAt)
        }
    }

    // MARK: - 生成

    private func generateAndPresent(appName: String, windowTitle: String?,
                                    triggeredAt: Date) async {
        guard let retriever, let completer else { return }
        generation += 1
        let currentGeneration = generation
        isGenerating = true
        defer { isGenerating = false }

        let contextQuery = ContextCardContent.buildQuery(windowTitle: windowTitle, appName: appName)
        let meetingTitle = (windowTitle?.isEmpty == false) ? windowTitle! : appName
        logger.notice("🗂 脈絡卡生成開始：query=\(contextQuery.query, privacy: .public)")

        let chunks = await retriever.retrieve(query: contextQuery.query)

        var matchedTasks: [VikunjaService.TaskItem] = []
        if let taskLister {
            do {
                matchedTasks = ContextCardContent.matchTasks(
                    try await taskLister.openTasks(), keywords: contextQuery.keywords)
            } catch {
                // .error 對齊 LLM/RAG 失敗的層級——三者都是「區塊憑空消失」級的降級。
                logger.error("🗂 Vikunja 任務載入失敗（區塊省略）: \(error.localizedDescription, privacy: .public)")
            }
        }

        let noteLinks = ContextCardContent.noteLinks(from: chunks)
        let taskLinks = matchedTasks.map { MeetingContextCardModel.TaskLink(id: $0.id, title: $0.title) }

        // 零命中 → 依設定決定「不打擾」或中性空卡（文案中性——第一次開會不是缺陷）。
        if chunks.isEmpty && matchedTasks.isEmpty {
            guard config.showWhenEmpty else {
                logger.notice("🗂 脈絡卡：RAG 零命中且無相關任務——不彈（showWhenEmpty=false）")
                return
            }
            present(MeetingContextCardModel(meetingTitle: meetingTitle, firstMeeting: true),
                    generation: currentGeneration, triggeredAt: triggeredAt)
            return
        }

        var card: MeetingContextCardModel
        do {
            let reply = try await completer.complete(
                system: ContextCardContent.systemPrompt,
                user: ContextCardContent.buildUserBlock(
                    meetingTitle: meetingTitle, chunks: chunks,
                    taskTitles: matchedTasks.map(\.title)))
            if let parsed = ContextCardContent.parseCard(reply) {
                card = MeetingContextCardModel(
                    meetingTitle: meetingTitle,
                    lastSummary: parsed.lastSummary,
                    openItems: parsed.openItems,
                    myPromises: parsed.myPromises,
                    firstMeeting: parsed.firstMeeting)
            } else {
                logger.error("🗂 脈絡卡 JSON 解析失敗 → 退化卡（只列來源，不捏造內容）；回覆前 300 字: \(String(reply.prefix(300)), privacy: .private)")
                card = MeetingContextCardModel(meetingTitle: meetingTitle, isFallback: true)
            }
        } catch {
            logger.error("🗂 脈絡卡 LLM 失敗 → 退化卡: \(error.localizedDescription, privacy: .public)")
            card = MeetingContextCardModel(meetingTitle: meetingTitle, isFallback: true)
        }
        card.noteLinks = noteLinks
        card.tasks = taskLinks
        present(card, generation: currentGeneration, triggeredAt: triggeredAt)
    }

    private func present(_ card: MeetingContextCardModel, generation: Int, triggeredAt: Date) {
        guard self.generation == generation else { return }   // 生成期間又觸發新一輪 → 舊結果丟棄
        model = card
        let elapsed = now().timeIntervalSince(triggeredAt)
        if config.autoShow && elapsed <= Self.autoShowStaleAfter {
            presenter.showCard()
        } else {
            if config.autoShow {
                logger.notice("🗂 脈絡卡遲到（\(Int(elapsed))s > \(Int(Self.autoShowStaleAfter))s）→ 降級為通知，不搶畫面")
            }
            presenter.notifyCardReady()
        }
    }

    // MARK: - 開啟動作（卡片列點擊）

    /// Obsidian 深連結開筆記（鏡射 `CitationPopup.obsidianURL`：vault 解析 + security scope）。
    func openNote(path: String) {
        // 點了沒反應是最難回報的故障——每個失敗分支都要留 log。
        guard let vault = ObsidianRAGConfigStore.shared.effectiveVaultRoot() else {
            logger.error("🗂 開筆記失敗：vault root 無法解析（\(path, privacy: .public)）")
            return
        }
        let accessing = vault.startAccessingSecurityScopedResource()
        defer { if accessing { vault.stopAccessingSecurityScopedResource() } }
        guard let url = ObsidianLink.openURL(vaultRoot: vault, relativePath: path) else {
            logger.error("🗂 開筆記失敗：obsidian URL 組建失敗（\(path, privacy: .public)）")
            return
        }
        if !NSWorkspace.shared.open(url) {
            logger.error("🗂 開筆記失敗：NSWorkspace.open 回 false（Obsidian 未安裝?）")
        }
    }

    /// Vikunja Web UI 的任務頁（鏡射 `MorningBriefingService.openTask`）。
    func openTask(id: Int) {
        let base = VikunjaService.uiBaseURL(VikunjaConfigStore.shared.baseURL)
        guard !base.isEmpty, let url = URL(string: "\(base)/tasks/\(id)") else {
            logger.error("🗂 開任務失敗：uiBaseURL 空或 URL 組建失敗（task \(id, privacy: .public)）")
            return
        }
        if !NSWorkspace.shared.open(url) {
            logger.error("🗂 開任務失敗：NSWorkspace.open 回 false（task \(id, privacy: .public)）")
        }
    }

    // MARK: - 視窗標題（best-effort）

    /// bundle id → 可能的視窗 owner 名集合。CGWindowList 只有 ownerName 可比對
    ///（見 `MeetingDetectionCatalog.BrowserFamily` 註解），所以把目錄顯示名、瀏覽器家族
    /// owner 名、與執行中 app 的 localizedName 全部湊起來。
    nonisolated static func ownerNames(bundleId: String, displayName: String) -> Set<String> {
        var names: Set<String> = [displayName]
        if let family = MeetingDetectionCatalog.browserFamily(forBundleId: bundleId) {
            names.formUnion(family.windowOwnerNames)
        }
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleId) {
            if let name = app.localizedName { names.insert(name) }
        }
        return names
    }

    /// 讀 ownerNames 擁有的螢幕上視窗標題。讀 `kCGWindowName` 需螢幕錄製權限——未授權回 nil
    ///（退用 app 名，功能照常）。命中會議標題 pattern 的視窗優先（瀏覽器分頁多，
    /// 別抓到別的分頁），其次取面積最大者；尺寸過濾同 `MeetingWindowTitleScanner`。
    /// 標題只在記憶體內使用，不持久化。
    nonisolated static func bestWindowTitle(ownerNames: Set<String>) -> String? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        var best: (title: String, area: CGFloat, meetingHit: Bool)?
        for entry in info {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  ownerNames.contains(owner),
                  let name = entry[kCGWindowName as String] as? String, !name.isEmpty,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 200, bounds.height >= 200 else { continue }
            let hit = MeetingDetectionCatalog.meetingTitlePatterns.contains { name.contains($0) }
            let area = bounds.width * bounds.height
            if let current = best {
                if (hit && !current.meetingHit) || (hit == current.meetingHit && area > current.area) {
                    best = (name, area, hit)
                }
            } else {
                best = (name, area, hit)
            }
        }
        return best?.title
    }
}

// MARK: - 正式實作（live seam）

/// query 嵌入（與索引同模型）→ meeting/obsidian 兩來源 top-K。任何失敗 → []（記 log，不彈 UI）。
@MainActor
private final class LiveContextCardRetriever: ContextCardRetrieving {
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingContextCard")
    init(modelContext: ModelContext) { self.modelContext = modelContext }

    func retrieve(query: String) async -> [ContextChunkInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let model = TranscriptIndexService.shared.model
        do {
            let vectors = try await LiveEmbedder().embed(texts: [trimmed], model: model)
            guard let vector = vectors.first else { return [] }
            // 偏好舊會議逐字稿與個人筆記（會後包在 vault 內，已被 obsidian 索引涵蓋）；
            // dictation/recorder 是聽寫與一般錄音，對「上次這場會談到哪」噪音居多。
            let scope = AskAIScope(sources: ["meeting", ObsidianNoteIndexService.sourceKind])
            let scored = RetrievalService.retrieve(
                queryVector: vector, scope: scope, k: MeetingContextCardService.ragK,
                model: model, context: modelContext,
                minScore: MeetingContextCardService.ragMinScore)
            return scored.map {
                ContextChunkInfo(text: $0.chunk.text, sourceKind: $0.chunk.sourceKind,
                                 sourceTitle: $0.chunk.sourceTitle, sourcePath: $0.chunk.sourcePath)
            }
        } catch {
            // 無 embedding key / 網路失敗 → 回空降級（卡片走空卡/純任務路徑），但必須留 log：
            // showWhenEmpty 預設 false 時這條路徑外觀＝什麼都沒發生，沒有這行就無從得知功能默默壞掉
            //（同 `MeetingGroundingProvider` 把 ragError 記進 grounding 的理由）。
            logger.error("🗂 脈絡卡 RAG 檢索失敗（降級為零命中，與真零命中不同源）: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

/// 連線就緒才打 API（`isConnectionReady` 不含 `enabled`——那是熱鍵語音記待辦的開關，同晨間簡報）。
@MainActor
private final class LiveContextCardTaskLister: ContextCardTaskListing {
    func openTasks() async throws -> [VikunjaService.TaskItem] {
        let config = VikunjaConfigStore.shared
        guard config.isConnectionReady, let token = config.token, !token.isEmpty else { return [] }
        return try await VikunjaService(baseURL: config.baseURL, token: token).listOpenTasks()
    }
}

@MainActor
private final class LiveContextCardPresenter: ContextCardPresenting {
    func showCard() {
        MeetingContextCardWindowManager.shared.showWithAutoFade()
    }
    func notifyCardReady() {
        NotificationManager.shared.showNotification(
            title: "🗂 會議脈絡卡準備好了",
            type: .info,
            duration: 8,
            onTap: { MeetingContextCardWindowManager.shared.show() })
    }
}

@MainActor
private final class LiveContextCardCompleter: ContextCardCompleting {
    private weak var aiService: AIService?
    init(aiService: AIService) { self.aiService = aiService }

    func complete(system: String, user: String) async throws -> String {
        guard let aiService else { throw EnhancementError.notConfigured }
        return try await aiService.completeChat(
            provider: aiService.selectedProvider,
            modelName: nil,
            messages: [ChatMessage.user(user)],
            systemPrompt: system,
            timeout: MeetingContextCardService.llmTimeout,
            usageFeature: .meetingContextCard)
    }
}
