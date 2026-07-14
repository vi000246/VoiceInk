import Foundation
import SwiftData
import Combine
import os

/// M9 FR-70：一筆錄音的覆盤按鈕該長什麼樣，由「這筆錄音現有哪些 session」決定。
///
/// 規則：live 場已經存在時，**不提供補做**——live 是當下真的跑過的那一場，事後再補一份
/// replay 只會讓兩份同構資料互相冒充「這場會議的覆盤」。所以有 live → 只給「查看」。
/// 只有 replay（沒 live）→ 查看＋重新產生：同一份逐字稿的多次 replay 並存，正是 prompt
/// 調校的 A/B 對照（FR-59），要留著。
///
/// **這是狀態判斷，不是永久規則**：live 場被刪掉（覆盤頁批次刪除）之後，這筆錄音就回到
/// 「沒有 live」的狀態，「產生」按鈕自然回來——不需要任何解鎖旗標或例外路徑。
enum CopilotReviewButtons {
    enum State: Equatable {
        /// 這筆錄音沒有任何 copilot session → 只給「產生」。
        case generate
        /// 有 live 場 → 只給「查看」（開 `latest` 那場）。
        case viewOnly(latest: UUID)
        /// 只有 replay → 「查看」＋「重新產生」（舊 replay 不覆蓋，A/B 保留）。
        case viewAndRegenerate(latest: UUID)
    }

    /// - Parameter sessions: 同一 `importFingerprint` 底下的全部 session（不必先排序）。
    static func state(sessions: [(id: UUID, sourceRaw: String, startedAt: Date)]) -> State {
        // 「查看」一律開最新那場——不論它是 live 還是後補的 replay。
        guard let latest = sessions.max(by: { $0.startedAt < $1.startedAt }) else { return .generate }
        let hasLive = sessions.contains { $0.sourceRaw == "live" }
        return hasLive ? .viewOnly(latest: latest.id) : .viewAndRegenerate(latest: latest.id)
    }
}

/// M9 FR-71：覆盤背景佇列。
///
/// # 為什麼要有這層
///
/// 覆盤原本跑在錄音詳情 sheet 的 `@State` 裡——sheet 一關，view 連同 service 一起被丟掉，
/// 跑到一半的覆盤跟著沒了；跑完又硬把使用者拉去覆盤頁。一件要跑好幾分鐘的事綁在一個隨手
/// 會關掉的視窗上，本身就是設計錯誤。改成 app 級單例後：**關 sheet 不中斷，跑完不跳頁**，
/// 進度只是兩頁 badge 上的一個狀態（FR-72）。
///
/// # 分工
///
/// `MeetingReplayReviewService` 仍是「跑完整一場覆盤」的執行者（失敗刪整場的語意原封不動）；
/// 這裡只管排程與狀態廣播。序列（一次一場）不是偷懶——service 檔頭那條 rate-limit 紅線說明了
/// 為什麼連段落都要序列跑，兩場平行只會更快撞牆。
@MainActor
final class MeetingReplayQueue: ObservableObject {
    static let shared = MeetingReplayQueue()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingCopilot")

    /// 排隊中＋跑動中的錄音 id（錄音列「覆盤中」badge 的單一來源）。**一按下去就進來**——
    /// 排隊也是「覆盤中」，不然按了鈕卻沒有任何反應，使用者只會再按一次。
    @Published private(set) var inFlight: Set<UUID> = []
    /// 跑動中那場的 session id（覆盤頁列 badge 用；service 一 insert session 就有值）。
    @Published private(set) var activeSessionId: UUID?
    /// 跑動中那場的段數進度（nil = 排隊中或閒置）。
    @Published private(set) var progress: (done: Int, total: Int)?

    private var pending: [Transcription] = []
    private var working = false
    private var cancellables: Set<AnyCancellable> = []

    /// 注入 seam：測試給 fake（可以卡在任意瞬間斷言排程行為）；正式為 nil → 走 `runReal`。
    private let runner: ((Transcription) async throws -> Void)?

    init(runner: ((Transcription) async throws -> Void)? = nil) {
        self.runner = runner
    }

    func isBusy(_ transcriptionId: UUID) -> Bool { inFlight.contains(transcriptionId) }

    /// 排一場覆盤。同一筆錄音已在佇列裡 → no-op（AC-57：連按不會排出兩場一樣的覆盤）。
    func enqueue(_ transcription: Transcription, aiService: AIService? = nil, modelContext: ModelContext? = nil) {
        guard !inFlight.contains(transcription.id) else { return }
        inFlight.insert(transcription.id)
        pending.append(transcription)
        pump(aiService: aiService, modelContext: modelContext)
    }

    /// FIFO，一次一場。跑完（成功或失敗）清狀態再遞迴叫自己拉下一場。
    private func pump(aiService: AIService?, modelContext: ModelContext?) {
        guard !working, !pending.isEmpty else { return }
        let next = pending.removeFirst()

        // `pending` 持的是 @Model 參照：排隊期間錄音可能已被刪（刪除會連帶 sweep 掉 session）。
        // 對已刪的 model 讀 `text`/`duration` 是未定義行為 —— 直接跳過，換下一場。
        guard !next.isDeleted else {
            logger.notice("🧠 覆盤佇列：錄音已刪除,跳過這場")
            inFlight.remove(next.id)
            pump(aiService: aiService, modelContext: modelContext)
            return
        }

        working = true
        Task { [weak self] in
            guard let self else { return }
            do {
                if let runner = self.runner {
                    try await runner(next)
                } else {
                    try await self.runReal(next, aiService: aiService, modelContext: modelContext)
                }
            } catch {
                // 失敗 = service 已經把半套 session 整場刪掉（不留半套）；背景跑沒有 sheet 可以顯示
                // 錯誤，所以改用 toast —— 靜默失敗會讓使用者以為還在跑。
                logger.error("🧠 覆盤失敗:\(error.localizedDescription, privacy: .public)")
                NotificationManager.shared.showNotification(
                    title: "覆盤失敗：\(error.localizedDescription)", type: .error, duration: 5)
            }
            self.inFlight.remove(next.id)
            self.activeSessionId = nil
            self.progress = nil
            self.cancellables.removeAll()   // 這場的 service 訂閱隨它一起退場
            self.working = false
            self.pump(aiService: aiService, modelContext: modelContext)
        }
    }

    /// 真跑一場（工廠邏輯自 `RecorderHistoryView.generateReview` 原樣搬入）。
    ///
    /// coordinator 的 fast/deep 一律走 `MeetingCopilotLiveController.makeStreamingCompleter`
    /// —— 與 live **同一套**模型解析規則，兩邊各寫一份遲早分岔，覆盤結果就不再與 live 可比。
    /// deep 在 replay 不會被呼叫（`AnswerCoordinator.runTier1ForReplay` 的成本紅線），但建構子
    /// 要求它：給真的那顆，而不是一個從頭到尾不會被打到的假 stub。
    private func runReal(_ transcription: Transcription, aiService: AIService?, modelContext: ModelContext?) async throws {
        guard let aiService, let modelContext else { return }
        let config = MeetingCopilotConfigStore.shared
        let fast = MeetingCopilotLiveController.makeStreamingCompleter(
            provider: config.fastProviderName, model: config.fastModelName, aiService: aiService)
        let deep = MeetingCopilotLiveController.makeStreamingCompleter(
            provider: config.deepProviderName, model: config.deepModelName, aiService: aiService)
        let coordinator = AnswerCoordinator(
            fast: fast.completer,
            deep: deep.completer,
            grounding: MeetingGroundingProvider(screen: ScreenCaptureService(), modelContext: modelContext),
            config: config,
            fastLabel: fast.label,
            deepLabel: deep.label)
        let service = MeetingReplayReviewService(
            extractorChat: MeetingCopilotController.makeFastCompleter(aiService: aiService, config: config),
            coordinator: coordinator,
            modelContext: modelContext,
            extractionModelLabel: fast.label,
            config: config)

        // 兩頁 badge 只讀佇列的 @Published——view 從此不必持有 service（持有它就會被它的生命週期綁住）。
        service.$progress.sink { [weak self] in self?.progress = $0 }.store(in: &cancellables)
        service.$currentSessionId.sink { [weak self] in self?.activeSessionId = $0 }.store(in: &cancellables)

        _ = try await service.generateReview(for: transcription)
    }
}
