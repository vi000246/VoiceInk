import Foundation

/// M11 會議開始偵測的**純狀態機**（本功能的可測核心）。
///
/// 不碰 CoreAudio / CGWindowList / UI / 系統時鐘——所有輸入（現在時間、收音 bundle id 集合、
/// 是否錄音中、設定快照、標題掃描結果）由呼叫端（`MeetingStartDetector`）注入。AC-70~78 全打這一層。
///
/// # 決策規則（見 SRS「整合決策規則」＋ FR-87~90）
/// - 原生會議 app（native 清單）：mic 持續 ≥ debounce → 觸發。
/// - 瀏覽器家族：mic 持續 ≥ debounce **且** 標題掃描 `.hit` → 觸發；`.miss` 續等；`.unavailable` 降級。
/// - 錄音中：consume 當下所有 session（停錄後不追著補提示）。
/// - per-session 一次；mic 停 ≥ rearm 才算新 session。
/// - 全域冷卻：一次 prompt 後 cooldown 秒內的其他觸發直接 consume（不補發）。
///   註：cooldown（60s）> rearm（30s），所以「同一場會很快重開」會被冷卻吃掉——
///   刻意如此（寧可漏報也不騷擾，見 SRS Open Questions）。
struct MeetingStartDetectorCore {

    /// 一次 tick 的設定快照（保持 core 為純函式：設定由呼叫端從 config store 取好傳入）。
    struct Config {
        var enabled: Bool
        var nativeEnabledBundleIds: Set<String>
        var browsersEnabled: Bool
        var debounce: TimeInterval
        var rearm: TimeInterval
        var cooldown: TimeInterval

        static let defaultCooldown: TimeInterval = 60
    }

    enum SuppressReason: String, Equatable {
        case recording      // 錄音中
        case cooldown       // 全域冷卻窗內
        case noPermission   // 瀏覽器路徑無螢幕錄製權限
        case noTitle        // 瀏覽器 mic 使用中但視窗標題未命中會議 pattern（觀測性，不改狀態）
    }

    enum Effect: Equatable {
        case prompt(bundleId: String, displayName: String)
        case suppressed(bundleId: String, reason: SuppressReason)
    }

    // MARK: - 內部 session 狀態

    /// `.pending` = 已見、未處置；`.resolved` = 已提示或已 consume（同一 session 內不再動作，直到 rearm）。
    private enum SessionState { case pending, resolved }

    private struct Session {
        var firstSeen: Date
        var lastSeen: Date
        var state: SessionState
        /// 是否已為本 session 記過一次 no-title（瀏覽器標題未命中）——避免每 tick 重複記。
        var loggedNoTitle = false
    }

    /// key = bundle id。只為「候選」bundle id 建 session（非候選的 mic 使用者——如 Discord——不追蹤）。
    private var sessions: [String: Session] = [:]
    /// 上次 prompt 的時間（全域冷卻用）。
    private var lastPromptAt: Date?

    // MARK: - Tick

    /// 推進一格。回傳本 tick 要執行的 effects（呼叫端據此發通知／記 log）。
    ///
    /// - Parameters:
    ///   - titleCheck: 只對「已過 debounce 的瀏覽器候選」呼叫（每 tick 至多一次/家族），
    ///     由呼叫端實作真正的 CGWindowList 掃描＋權限判斷。
    mutating func tick(
        now: Date,
        micBundleIds: Set<String>,
        isRecording: Bool,
        config: Config,
        titleCheck: (MeetingDetectionCatalog.BrowserFamily) -> TitleCheckResult
    ) -> [Effect] {
        guard config.enabled else {
            reset()
            return []
        }

        var effects: [Effect] = []

        // 只追蹤候選 bundle id（native 已啟用 / 瀏覽器家族）——非候選不建 session（防無界成長 + AC-78）。
        let candidates = micBundleIds.filter {
            MeetingDetectionCatalog.isCandidate(
                bundleId: $0,
                nativeEnabled: config.nativeEnabledBundleIds,
                browsersEnabled: config.browsersEnabled)
        }

        // 1. 建立/更新 session（rearm-aware）：距上次見到 ≥ rearm → 視為全新 session。
        for bundleId in candidates {
            if var session = sessions[bundleId] {
                if now.timeIntervalSince(session.lastSeen) >= config.rearm {
                    sessions[bundleId] = Session(firstSeen: now, lastSeen: now, state: .pending)
                } else {
                    session.lastSeen = now
                    sessions[bundleId] = session
                }
            } else {
                sessions[bundleId] = Session(firstSeen: now, lastSeen: now, state: .pending)
            }
        }

        // 2. 錄音中：consume 當下所有 pending session（FR-90 規則 1）；每個轉 resolved 的 emit 一次。
        if isRecording {
            for bundleId in sessions.keys.sorted() {
                guard var session = sessions[bundleId], session.state == .pending else { continue }
                session.state = .resolved
                sessions[bundleId] = session
                effects.append(.suppressed(bundleId: bundleId, reason: .recording))
            }
            pruneStale(now: now, rearm: config.rearm)
            return effects
        }

        // 3. 評估「本 tick 仍在收音、pending、已過 debounce」的候選（排序 → 決定性，利於測試）。
        for bundleId in candidates.sorted() {
            guard var session = sessions[bundleId], session.state == .pending,
                  now.timeIntervalSince(session.firstSeen) >= config.debounce else { continue }

            let isNative = config.nativeEnabledBundleIds.contains(bundleId)
            let family = config.browsersEnabled
                ? MeetingDetectionCatalog.browserFamily(forBundleId: bundleId)
                : nil

            // 瀏覽器路徑需要標題確認。
            if !isNative, let family {
                switch titleCheck(family) {
                case .miss:
                    // 續等（不改 state，保持 pending，等標題出現/會議真的開始）。
                    // 但第一次 miss 記一行 no-title（FR-92 觀測性：漏報時知道「候選有、標題沒對上」）；
                    // 同 session 之後不再記，避免每 tick 洗版。
                    if !session.loggedNoTitle {
                        session.loggedNoTitle = true
                        sessions[bundleId] = session
                        effects.append(.suppressed(bundleId: bundleId, reason: .noTitle))
                    }
                    continue
                case .unavailable:
                    session.state = .resolved
                    sessions[bundleId] = session
                    effects.append(.suppressed(bundleId: bundleId, reason: .noPermission))
                    continue
                case .hit:
                    break                                      // 落到下方 prompt
                }
            }

            // 全域冷卻。
            if let lastPromptAt, now.timeIntervalSince(lastPromptAt) < config.cooldown {
                session.state = .resolved
                sessions[bundleId] = session
                effects.append(.suppressed(bundleId: bundleId, reason: .cooldown))
                continue
            }

            // 觸發。
            session.state = .resolved
            sessions[bundleId] = session
            lastPromptAt = now
            effects.append(.prompt(
                bundleId: bundleId,
                displayName: MeetingDetectionCatalog.displayName(forBundleId: bundleId)))
        }

        pruneStale(now: now, rearm: config.rearm)
        return effects
    }

    /// 清掉全部狀態（總開關關閉時；讓下次開啟從乾淨狀態起算）。
    mutating func reset() {
        sessions.removeAll()
        lastPromptAt = nil
    }

    /// 距上次見到 ≥ rearm 的 session 移除——下次再出現自然成為全新 pending session（= rearm 語意）。
    private mutating func pruneStale(now: Date, rearm: TimeInterval) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastSeen) < rearm }
    }
}
