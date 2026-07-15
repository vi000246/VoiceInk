import Foundation
import SwiftData
import os

/// 筆記索引的**唯一** in-flight 擁有者：誰在跑、跑到哪、能不能取消，全歸這裡。
///
/// 為什麼需要這一層——原本索引由「呼叫端各自 spawn 一個 Task」，四個入口各跑各的
/// （Ask AI 頁 onAppear、筆記 chip 開啟、會議 attach、設定頁手動重建），造成三個問題：
///
/// 1. **進度隨 view 陪葬**：手動重建的 `indexing` / `indexMessage` 是 sheet 的 `@State`，
///    sheet 一關就沒了。工作其實還在背景跑完（unstructured `Task` 不隨 view 取消），
///    但使用者看不到任何進度，也不知道跑完沒——體感等同「一關就斷了」。
/// 2. **重複跑**：single-flight 只護得住 `autoIndex` 那條路。開著 Ask AI 又開會議，
///    就是兩份 `reindex` 同時掃同一份 sidecar：hash 表互相覆蓋、同一批檔重複打 embedding API
///    （真的在燒錢），塊的 delete/insert 交錯。
/// 3. **沒有取消點**：按下去就只能等它跑完。
///
/// 所以 Task 收在單例裡，view 只是觀察者：關掉 sheet／離開頁面索引照跑，回來還看得到進度。
/// **所有**入口一律經過這裡 → 全app 一次只有一份筆記索引在跑。
@MainActor
final class NoteIndexCoordinator: ObservableObject {
    static let shared = NoteIndexCoordinator()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AskAI")

    /// 掃描進度。`scanned` 含「跳過的未變更檔」——所以進度條會一路動，不會卡在某個沒變的資料夾上。
    /// `reembedded` 才是真正花錢的部分,兩個數字都給,使用者才分得出「在掃」跟「在嵌」。
    struct Progress: Equatable {
        var scanned: Int
        var total: Int
        var reembedded: Int
        var currentFile: String?

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, Double(scanned) / Double(total))
        }
    }

    /// 上一輪的結果——**留在單例上**，這樣關掉 sheet 再打開仍看得到「上次索引了什麼」。
    struct RunResult: Equatable {
        var finishedAt: Date
        var reembedded: Int
        var totalFiles: Int
        var cancelled: Bool
        /// nil = 成功。非 nil = 這輪失敗了（訊息已本地化，直接顯示）。
        var errorMessage: String?

        var succeeded: Bool { errorMessage == nil && !cancelled }
    }

    @Published private(set) var progress: Progress?
    @Published private(set) var lastRun: RunResult?

    /// 正在跑（含剛啟動、還沒回報第一筆進度的那一瞬間）。
    var isRunning: Bool { task != nil }

    /// in-flight 的唯一真相。非 nil = 有一輪在跑 → 其他入口一律 no-op。
    private var task: Task<Void, Never>?

    private init() {}

    // MARK: - 入口

    /// 背景啟動，呼叫端不等它。Task 由單例持有 → view 消失、sheet 關閉，索引照跑。
    /// 已經有一輪在跑 → 直接 no-op（呼叫端該做的是去看 `progress`，而不是再開一輪）。
    func start(vaultRoot: URL, includeOnly: [String], excluded: [String], stateURL: URL,
               modelContext: ModelContext, embedder: EmbeddingProviding = LiveEmbedder(),
               force: Bool = false, announce: Bool = true) {
        _ = launch(vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded,
                   stateURL: stateURL, modelContext: modelContext, embedder: embedder,
                   force: force, announce: announce)
    }

    /// 等到跑完的變體（`ObsidianNoteIndexService.autoIndex` 與測試用）。
    /// 撞到 in-flight 一樣是**立刻 no-op**——不是排隊等它跑完（AC-11 的 single-flight 語意）。
    func run(vaultRoot: URL, includeOnly: [String], excluded: [String], stateURL: URL,
             modelContext: ModelContext, embedder: EmbeddingProviding = LiveEmbedder(),
             force: Bool = false, announce: Bool = false) async {
        await launch(vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded,
                     stateURL: stateURL, modelContext: modelContext, embedder: embedder,
                     force: force, announce: announce)?.value
    }

    /// 取消目前這一輪。已經嵌好的檔會記進 sidecar（不會白花），未處理的檔維持舊 hash（下次還會做）。
    func cancel() { task?.cancel() }

    // MARK: - 內部

    /// single-flight 的閘門。**沒有 await**，所以在 MainActor 上是原子的：兩個併發呼叫者中，
    /// 第二個必定看得到第一個設好的 `task`（AC-11 `testAutoIndexSingleFlight` 釘的就是這件事）。
    private func launch(vaultRoot: URL, includeOnly: [String], excluded: [String], stateURL: URL,
                        modelContext: ModelContext, embedder: EmbeddingProviding,
                        force: Bool, announce: Bool) -> Task<Void, Never>? {
        guard task == nil else { return nil }
        progress = Progress(scanned: 0, total: 0, reembedded: 0, currentFile: nil)
        let created = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.perform(vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded,
                               stateURL: stateURL, modelContext: modelContext, embedder: embedder,
                               force: force, announce: announce)
        }
        task = created
        return created
    }

    private func perform(vaultRoot: URL, includeOnly: [String], excluded: [String], stateURL: URL,
                         modelContext: ModelContext, embedder: EmbeddingProviding,
                         force: Bool, announce: Bool) async {
        // 不論成功、失敗、取消，in-flight 與進度都要收乾淨——漏掉任何一條路徑，
        // `task` 就永遠非 nil，之後所有入口全部 no-op（索引從此再也跑不起來，而且無聲無息）。
        defer {
            task = nil
            progress = nil
        }

        let service = ObsidianNoteIndexService(embedder: embedder, modelContext: modelContext,
                                               stateURL: stateURL)
        do {
            let reembedded = try await service.reindex(
                vaultRoot: vaultRoot, includeOnly: includeOnly, excluded: excluded, force: force
            ) { [weak self] update in
                self?.progress = update
            }
            let total = progress?.total ?? 0
            lastRun = RunResult(finishedAt: Date(), reembedded: reembedded, totalFiles: total,
                                cancelled: false, errorMessage: nil)
            logger.notice("🗂️ 筆記索引完成（掃 \(total, privacy: .public) 檔／重嵌 \(reembedded, privacy: .public) 檔）")
            if announce {
                NotificationManager.shared.showNotification(
                    title: reembedded == 0 ? "筆記索引已是最新" : "筆記索引完成（重嵌 \(reembedded) 檔）",
                    type: .success, duration: 3)
            }
        } catch is CancellationError {
            lastRun = RunResult(finishedAt: Date(), reembedded: progress?.reembedded ?? 0,
                                totalFiles: progress?.total ?? 0, cancelled: true, errorMessage: nil)
            logger.notice("🗂️ 筆記索引已取消")
        } catch where Task.isCancelled {
            // 取消時冒出來的**不一定**是 CancellationError：懸在 embedding 請求上被取消，URLSession
            // 丟的是 `URLError(.cancelled)`（再被 EmbeddingClient 包成 `.http(0, …)`）。只認型別的話，
            // 使用者按下取消會換來一則紅色的「筆記索引失敗：Embedding 服務錯誤（0）」——把自己的操作
            // 報成故障。以 `Task.isCancelled` 為準。
            lastRun = RunResult(finishedAt: Date(), reembedded: progress?.reembedded ?? 0,
                                totalFiles: progress?.total ?? 0, cancelled: true, errorMessage: nil)
            logger.notice("🗂️ 筆記索引已取消")
        } catch {
            let message = Self.message(for: error)
            lastRun = RunResult(finishedAt: Date(), reembedded: progress?.reembedded ?? 0,
                                totalFiles: progress?.total ?? 0, cancelled: false,
                                errorMessage: message)
            logger.notice("🗂️ 筆記索引失敗: \(message, privacy: .public)")
            // 自動觸發的失敗維持靜默（log-only，與 MeetingGroundingProvider 同紀律）；
            // 使用者「自己按了按鈕」才值得跳通知——他正在等結果。
            if announce {
                NotificationManager.shared.showNotification(
                    title: "筆記索引失敗：\(message)", type: .error, duration: 5)
            }
        }
    }

    /// 錯誤 → 可行動的中文訊息。缺金鑰是最常見的失敗，光說「尚未設定 X 的 API 金鑰」還不夠——
    /// 補上「去哪設」才是使用者下一步做得到的事。
    static func message(for error: Error) -> String {
        if let embeddingError = error as? EmbeddingError, case .missingAPIKey = embeddingError {
            return "\(embeddingError.localizedDescription)（到「Transcription & AI Models」設定）"
        }
        return error.localizedDescription
    }
}
