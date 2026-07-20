import AppKit
import Combine
import LLMkit
import os

/// 會後包資料夾掃描結果——在背景執行緒產出,放檔案層級(掛在 @MainActor class 內
/// 的巢狀型別會繼承隔離,detached task 就碰不了)。
private enum PackScan: Sendable {
    case ok(folder: URL, names: [String])
    /// 子資料夾不存在:可能只是還沒匯出過會後包,也可能被刪/改名。
    case folderMissing(path: String)
    /// bookmark 解析失敗:授權失效/vault 被搬移/磁碟未掛載。
    case bookmarkInvalid
    case listFailed(path: String, message: String)
}

/// 晨間簡報(M13)的編排:排程/catch-up → 收集(Vikunja 任務、昨日會後包)→
/// AI「今日第一件事」→ 浮窗 + 通知。
///
/// 紅線:**簡報永不因任何資料源失敗而整個不出現**——Vikunja 未設定/壞掉 → 任務區塊
/// 換成一行中性說明;vault 未設定 → 會後包區塊省略;LLM 失敗 → AI 區塊省略。
/// 唯一不彈的情況:所有區塊皆空且無錯誤(那就今天不彈,log 記錄)。
@MainActor
final class MorningBriefingService: ObservableObject {

    static let shared = MorningBriefingService()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MorningBriefing")

    @Published private(set) var model: MorningBriefingModel?
    @Published private(set) var isGenerating = false
    @Published private(set) var generatedAt: Date?

    private weak var aiService: AIService?
    private let config = MorningBriefingConfigStore.shared
    private var timer: Timer?
    private var started = false
    private var cancellables: Set<AnyCancellable> = []
    /// 昨日會後包所在資料夾(生成時解析;ObsidianLink 開檔用)。
    private var packsFolder: URL?

    private init() {}

    func configure(aiService: AIService) {
        self.aiService = aiService
    }

    /// app 啟動時呼叫一次:排下一發 timer、掛喚醒觀察者、啟動 catch-up
    /// (09:00 才開機 → 稍候即補顯示;延遲幾秒避開啟動高峰,樣式同 ModelPrewarmService)。
    func start() {
        guard !started else { return }
        started = true

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)

        // 設定時刻改了就重排。@Published 在 willSet 發出(此刻屬性還是舊值),
        // 所以繞一圈 Task 等賦值完成後再讀 config.timeMinutes。
        config.$timeMinutes
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleNextTimer()
                    // 把時間改成「今天已過去」的時刻也要立即補顯示——啟動/喚醒入口都會
                    // catch-up,唯獨設定變更不做的話,使用者會以為改了沒生效。
                    await self?.autoShowIfDue()
                }
            }
            .store(in: &cancellables)

        scheduleNextTimer()
        Task {
            try? await Task.sleep(for: .seconds(2))
            await self.autoShowIfDue()
        }
    }

    /// 睡眠期間 Timer 不會準時醒——喚醒後重排下一發 + 立即檢查 catch-up
    /// (Mac 睡到中午,喚醒這一刻就是「今天的簡報」補上的時機)。
    @objc private func handleWake() {
        Task { @MainActor in
            self.scheduleNextTimer()
            await self.autoShowIfDue()
        }
    }

    private func scheduleNextTimer() {
        timer?.invalidate()
        let fireDate = BriefingScheduler.nextFireDate(
            now: Date(), configuredMinutes: config.timeMinutes)
        let newTimer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.autoShowIfDue()
                self.scheduleNextTimer()
            }
        }
        // .common 模式:選單開著、視窗拖曳中也照跑(同 MeetingStartDetector 的教訓)。
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    // MARK: - 顯示入口

    /// 自動路徑(timer 命中/啟動/喚醒 catch-up 共用):每日一次,以 `lastShownDayV1` 為 semaphore。
    func autoShowIfDue() async {
        guard config.enabled else { return }
        let now = Date()
        guard BriefingScheduler.shouldCatchUp(
            now: now,
            configuredMinutes: config.timeMinutes,
            lastShownDay: config.lastShownDay) else { return }
        // 先蓋章再生成——生成中又來一個 wake/timer 不會彈第二次。
        config.markShown(day: BriefingScheduler.dayKey(for: now))

        let generated = await regenerate()
        guard generated.hasAnyContent else {
            logger.notice("☀️ 今日簡報全空(無任務/會後包/錯誤)——不打擾,今天不彈")
            return
        }
        MorningBriefingWindowManager.shared.show()
        // 第二入口:浮窗被切螢幕/漏看時,通知還能把它叫回來。
        NotificationManager.shared.showNotification(
            title: "☀️ 晨間簡報準備好了",
            type: .info,
            duration: 8,
            onTap: { MorningBriefingWindowManager.shared.show() })
    }

    /// 手動路徑(熱鍵/選單列/設定頁):不受每日一次限制、永遠重新生成。
    /// 手動看過也蓋章——同一天稍後的自動觸發不再重複彈(每日一次語意)。
    func showManually() async {
        guard !isGenerating else {
            MorningBriefingWindowManager.shared.show()
            return
        }
        config.markShown(day: BriefingScheduler.dayKey(for: Date()))
        // 先開窗給 loading 狀態——按了沒反應會被當成壞掉。
        MorningBriefingWindowManager.shared.show()
        _ = await regenerate()
    }

    // MARK: - 生成

    /// 舊的 AI 補寫請求不得蓋到新一輪簡報——每次 regenerate 遞增,補寫前比對。
    private var generation = 0

    private func regenerate() async -> MorningBriefingModel {
        isGenerating = true
        defer { isGenerating = false }
        generation += 1
        let currentGeneration = generation
        let now = Date()

        let (base, tasks) = await gather(now: now)
        model = base
        generatedAt = Date()

        // AI 建議事後補上——**簡報不等 AI**:視窗先出現,「今日第一件事」等 LLM 回來
        // 再浮現;失敗/逾時就整塊省略,簡報本體不受影響。
        if config.aiSuggestionEnabled, let aiService, let tasks, !tasks.isEmpty {
            Task { [weak self] in
                guard let self else { return }
                guard let suggestion = await self.fetchAISuggestion(
                    tasks: tasks, now: now, aiService: aiService) else { return }
                guard self.generation == currentGeneration, var updated = self.model else { return }
                updated.aiSuggestion = suggestion
                self.model = updated
            }
        }
        return base
    }

    private func gather(now: Date) async -> (MorningBriefingModel, [VikunjaService.TaskItem]?) {
        // Vikunja 任務(未設定/失敗 → 區塊換一行中性說明,簡報照樣出現)。
        var tasks: [VikunjaService.TaskItem]?
        var note: String?
        let vikunjaConfig = VikunjaConfigStore.shared
        // 只看連線設定(URL/專案/token),不看 `enabled`——那是熱鍵語音記待辦的開關(同會後包)。
        if vikunjaConfig.isConnectionReady, let token = vikunjaConfig.token, !token.isEmpty {
            let service = VikunjaService(baseURL: vikunjaConfig.baseURL, token: token)
            do {
                tasks = try await service.listOpenTasks()
            } catch {
                logger.error("☀️ Vikunja 任務載入失敗: \(error.localizedDescription, privacy: .public)")
                note = "Vikunja 連線失敗，任務清單暫時看不到"
            }
        } else {
            note = "Vikunja 未連線"
        }

        let packFileNames = await scanRecentPacks(now: now)

        let model = BriefingContent.buildModel(
            tasks: tasks,
            vikunjaNote: note,
            packFileNames: packFileNames,
            aiSuggestion: nil,
            now: now)
        return (model, tasks)
    }

    private func fetchAISuggestion(
        tasks: [VikunjaService.TaskItem], now: Date, aiService: AIService
    ) async -> String? {
        let buckets = BriefingContent.bucket(tasks: tasks, now: now)
        guard let userMessage = BriefingContent.buildAIUserMessage(
            overdue: buckets.overdue.map(\.title),
            dueToday: buckets.dueToday.map(\.title),
            noDue: buckets.noDue.map(\.title)) else { return nil }
        do {
            let raw = try await aiService.completeChat(
                provider: aiService.selectedProvider,
                modelName: nil,
                messages: [ChatMessage.user(userMessage)],
                systemPrompt: BriefingContent.aiSystemPrompt,
                timeout: 30,
                usageFeature: .morningBriefing)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(300))
        } catch {
            logger.error("☀️ AI 建議生成失敗(區塊省略): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 掃 vault 會後包資料夾,取檔名日期為昨天/今天的 .md。任何失敗 → 空(區塊省略),
    /// 但每種失敗留下可區分的 log:未設定(正常)/授權失效/資料夾不存在/列舉失敗/逾時。
    /// 磁碟 I/O 走背景執行緒 + 逾時保險——vault 在網路磁碟/睡醒未掛載時可能 block 數秒,
    /// 不得凍結主執行緒,也不得讓簡報永遠等下去。
    private func scanRecentPacks(now: Date) async -> [String] {
        packsFolder = nil
        guard let bookmark = RecorderConfigStore.shared.vaultRootBookmark else {
            logger.info("☀️ vault 未設定,會後包區塊省略")
            return []
        }
        let subfolder = MeetingPackConfigStore.shared.subfolder
        let exporter = VaultExportService.shared

        // 掃描 vs 逾時先到先贏。卡死的 FileManager 呼叫無法取消,所以不能用 task group
        // (group 會等所有 child 收尾,逾時形同虛設)——輸的那邊 finish 會被擋掉,
        // 背景掃描白跑但無害(security scope 由它自己的 defer 收)。
        let outcome: PackScan? = await withCheckedContinuation { (continuation: CheckedContinuation<PackScan?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (PackScan?) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
            }
            Task.detached(priority: .userInitiated) {
                finish(Self.scanPacksFolder(bookmark: bookmark, subfolder: subfolder, exporter: exporter))
            }
            Task {
                try? await Task.sleep(for: .seconds(5))
                finish(nil)
            }
        }

        switch outcome {
        case .ok(let folder, let names):
            packsFolder = folder
            return names.filter { BriefingContent.isRecentPackFile($0, now: now) }
        case .folderMissing(let path):
            // 還沒匯出過任何會後包也走這裡(正常),但資料夾被刪/改名同樣落在這——notice 留痕。
            logger.notice("☀️ 會後包資料夾不存在,區塊省略: \(path, privacy: .public)")
            return []
        case .bookmarkInvalid:
            logger.error("☀️ vault bookmark 解析失敗(授權失效/資料夾被搬移?),會後包區塊省略")
            return []
        case .listFailed(let path, let message):
            logger.error("☀️ 會後包資料夾列舉失敗,區塊省略: \(path, privacy: .public) — \(message, privacy: .public)")
            return []
        case nil:
            logger.error("☀️ 會後包掃描逾時(vault 磁碟沒回應?),區塊省略")
            return []
        }
    }

    /// 背景執行緒上的實際掃描(bookmark 解析與列目錄都可能觸發磁碟 I/O)。
    nonisolated private static func scanPacksFolder(
        bookmark: Data, subfolder: String, exporter: VaultExportService
    ) -> PackScan {
        guard let vaultRoot = exporter.resolveVaultRoot(bookmark) else { return .bookmarkInvalid }
        let accessing = vaultRoot.startAccessingSecurityScopedResource()
        defer { if accessing { vaultRoot.stopAccessingSecurityScopedResource() } }
        let dir = vaultRoot.appendingPathComponent(subfolder, isDirectory: true)
        do {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            return .ok(folder: dir, names: names)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .folderMissing(path: dir.path)
        } catch {
            return .listFailed(path: dir.path, message: error.localizedDescription)
        }
    }

    // MARK: - 開啟動作(簡報視窗的列點擊)

    /// 開 Vikunja Web UI 的任務頁({uiBase}/tasks/{id})。
    func openTask(id: Int) {
        let base = VikunjaService.uiBaseURL(VikunjaConfigStore.shared.baseURL)
        guard !base.isEmpty, let url = URL(string: "\(base)/tasks/\(id)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 用 Obsidian 深連結開會後包筆記(樣式同 PostMeetingPackService 的 onTap)。
    func openPack(fileName: String) {
        guard let folder = packsFolder,
              let url = ObsidianLink.openURL(vaultRoot: folder, relativePath: fileName) else { return }
        NSWorkspace.shared.open(url)
    }
}
