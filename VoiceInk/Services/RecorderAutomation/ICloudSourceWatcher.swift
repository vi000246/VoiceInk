import AppKit
import Foundation
import os

/// 監看 iCloud 來源(`isICloudSource == true` 的 `.folder` 裝置)。
/// vnode watcher 看不到 iCloud Drive 的同步事件與子資料夾變化,改用 `NSMetadataQuery`,
/// searchScopes 直接放來源資料夾 URL(ubiquitous scope 常數只涵蓋自家 app 容器,涵蓋不了
/// JPR 這種第三方容器;明確資料夾 scope 則跟著行程的檔案讀取權限走)。
/// 事件語意與 `RecorderFolderWatcher` 一致:callback 只 debounce 排程,匯入交給
/// `RecorderImportService.importNewFiles`(它會處理 dataless 佔位檔的下載與 defer)。
/// 另掛 wake / app-activate rescan——metadata query 對部分容器可能漏事件,睡醒補掃兜底。
@MainActor
final class ICloudSourceWatcher {
    static let shared = ICloudSourceWatcher()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private var started = false
    private var queries: [UUID: NSMetadataQuery] = [:]
    private var queryObservers: [UUID: [NSObjectProtocol]] = [:]
    private var accessingURLs: [UUID: URL] = [:]
    private var debounce: [UUID: DispatchWorkItem] = [:]
    private var wakeObservers: [NSObjectProtocol] = []
    private init() {}

    func start() {
        guard !started else { return }
        started = true
        sync()

        // 睡醒 / 回到前景 → 對所有 iCloud 來源補掃一次(metadata query 漏事件的兜底)。
        let center = NSWorkspace.shared.notificationCenter
        wakeObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in ICloudSourceWatcher.shared.rescanAll() } })
        wakeObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in ICloudSourceWatcher.shared.rescanAll() } })

        logger.notice("ICloudSourceWatcher started")
    }

    /// 依目前裝置清單重建 query。啟動與裝置增刪時呼叫。
    func sync() {
        guard started else { return }
        stopAllQueries()
        for device in RecorderConfigStore.shared.devices
        where device.kind == .folder && device.autoImportEnabled && device.isICloudSource {
            startWatching(device)
        }
    }

    /// 佔位檔下載中 → 稍後重掃(與 RecorderFolderWatcher.scheduleRecheck 對等,匯入層按來源分流)。
    func scheduleRecheck(deviceId: UUID) {
        guard queries[deviceId] != nil else { return }
        scheduleImport(deviceId: deviceId, delay: 8)   // iCloud 下載比本地複製慢,間隔放寬
    }

    private func rescanAll() {
        for id in queries.keys { scheduleImport(deviceId: id, delay: 1) }
    }

    private func startWatching(_ device: RecorderDevice) {
        guard let url = device.resolveSourceFolder() else {
            logger.error("iCloud watcher: cannot resolve bookmark for \(device.displayName, privacy: .public)")
            return
        }
        let accessing = url.startAccessingSecurityScopedResource()
        if accessing { accessingURLs[device.id] = url }

        let query = NSMetadataQuery()
        query.searchScopes = [url]                    // 明確資料夾 scope(非 ubiquitous 常數)
        query.predicate = NSPredicate(format: "%K LIKE '*'", NSMetadataItemFSNameKey)
        query.operationQueue = .main

        let id = device.id
        var observers: [NSObjectProtocol] = []
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: query, queue: .main
            ) { _ in
                // callback 可能一次帶進大批項目——這裡零工作,只 debounce 排程。
                Task { @MainActor in ICloudSourceWatcher.shared.scheduleImport(deviceId: id) }
            })
        }
        queryObservers[id] = observers
        queries[id] = query
        query.start()
        logger.notice("iCloud watcher watching \(url.lastPathComponent, privacy: .public)")
        // 初掃:上次關 app 之後同步下來的檔案。
        scheduleImport(deviceId: id, delay: 1)
    }

    private func scheduleImport(deviceId: UUID, delay: TimeInterval = 2) {
        debounce[deviceId]?.cancel()
        let work = DispatchWorkItem { Task { @MainActor [weak self] in self?.runImport(deviceId) } }
        debounce[deviceId] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runImport(_ deviceId: UUID) {
        debounce[deviceId] = nil
        guard let device = RecorderConfigStore.shared.device(byId: deviceId),
              device.kind == .folder, device.autoImportEnabled, device.isICloudSource else { return }
        RecorderImportService.shared.importNewFiles(device: device)
    }

    private func stopAllQueries() {
        for (id, query) in queries {
            query.stop()
            for observer in queryObservers[id] ?? [] { NotificationCenter.default.removeObserver(observer) }
            if let url = accessingURLs[id] { url.stopAccessingSecurityScopedResource() }
        }
        queries.removeAll(); queryObservers.removeAll(); accessingURLs.removeAll()
        for work in debounce.values { work.cancel() }
        debounce.removeAll()
    }
}
