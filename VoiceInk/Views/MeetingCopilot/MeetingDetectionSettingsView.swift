import SwiftUI
import CoreGraphics
import AppKit

/// M11「會議偵測」設定分頁（FR-91）。獨立子系統：偵測會議開始卻沒在錄音時提示。
/// clone `MeetingCopilotSettingsView` 的 Form + `Binding(get:set:)` 模式（config 是 private(set)）。
struct MeetingDetectionSettingsView: View {
    @StateObject private var store = MeetingDetectionConfigStore.shared
    /// M14 會議脈絡卡設定（掛在偵測設定附近：兩者共用「會議開始」這個時刻）。
    @StateObject private var cardStore = MeetingContextCardConfigStore.shared
    /// 螢幕錄製權限狀態（瀏覽器路徑需要）。onAppear 重讀（使用者可能剛在系統設定裡授權）。
    @State private var screenAccess = CGPreflightScreenCaptureAccess()

    var body: some View {
        Form {
            Section {
                Toggle("偵測會議開始（沒在錄音時提示我）",
                       isOn: Binding(get: { store.enabled }, set: { store.setEnabled($0) }))
                Text("偵測到會議 app 開始使用麥克風、但 Muninn 沒在錄會議時，跳一則通知讓你一鍵開始錄製——只提示，永遠不會自動開始錄音。只讀「哪個 app 在用麥克風」與視窗標題比對，**不讀音訊內容、不儲存標題**。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("原生會議 app") {
                ForEach(MeetingDetectionCatalog.nativeApps) { app in
                    Toggle(app.displayName, isOn: Binding(
                        get: { store.nativeEnabledBundleIds.contains(app.bundleId) },
                        set: { store.setNativeEnabled(app.bundleId, $0) }))
                }
                Text("這些 app 只要開始使用麥克風就視為會議開始（含等候室／裝置預覽——正是提示的最佳時機）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("瀏覽器裡的會議（Google Meet 等）") {
                Toggle("偵測瀏覽器裡的會議",
                       isOn: Binding(get: { store.browsersEnabled }, set: { store.setBrowsersEnabled($0) }))

                HStack(spacing: 8) {
                    Image(systemName: screenAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(screenAccess ? Color.green : Color.orange)
                    Text(screenAccess ? "螢幕錄製權限：已授權" : "螢幕錄製權限：未授權")
                        .font(.system(size: 12))
                    Spacer()
                    if !screenAccess {
                        Button("開啟系統設定") { Self.openScreenRecordingSettings() }
                    }
                }

                if !screenAccess {
                    Text("瀏覽器偵測需要「螢幕錄製」權限（只用來讀視窗標題判斷是不是會議，**不擷取畫面**）。未授權時只有瀏覽器路徑失效，原生 app 偵測照常。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("支援 Chrome / Edge / Arc / Brave / Firefox / Safari / Vivaldi。需要「麥克風使用中」**且**視窗標題命中 Meet/Teams 才提示——避免把網頁語音輸入誤判成會議。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("靈敏度") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("觸發前等待麥克風持續使用")
                        Spacer()
                        Text("\(Int(store.debounceSeconds)) 秒").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(get: { store.debounceSeconds }, set: { store.setDebounceSeconds($0) }),
                        in: MeetingDetectionConfigStore.debounceRange, step: 1)
                }
                Text("麥克風持續使用超過這個秒數才提示。太短容易誤觸，太長會晚提醒。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("會議脈絡卡") {
                Toggle("會議開始時準備脈絡卡（上次討論到哪）",
                       isOn: Binding(get: { cardStore.enabled }, set: { cardStore.setEnabled($0) }))
                Toggle("生成完成後自動浮出（10 秒沒碰自動收起，滑鼠移上去就保留）",
                       isOn: Binding(get: { cardStore.autoShow }, set: { cardStore.setAutoShow($0) }))
                    .disabled(!cardStore.enabled)
                Toggle("找不到相關資料時也顯示空卡",
                       isOn: Binding(get: { cardStore.showWhenEmpty }, set: { cardStore.setShowWhenEmpty($0) }))
                    .disabled(!cardStore.enabled)
                Text("偵測到會議開始（或你按下開始錄製）時，從舊會議逐字稿與 Obsidian 筆記撈出這個主題上次討論的重點、未結事項與你答應過的事，連同可能相關的 Vikunja 任務浮出一張小卡。關掉自動浮出則改發通知，點通知再開卡。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("偵測是 best-effort 提醒，不保證抓到所有會議——標題比對綁 Meet/Teams 目前的介面格式，產品改版可能失效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { screenAccess = CGPreflightScreenCaptureAccess() }
        // 使用者到系統設定授權後切回本頁(app 重獲焦點)時同步刷新——否則狀態列會卡在「未授權」。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            screenAccess = CGPreflightScreenCaptureAccess()
        }
    }

    /// 開「螢幕錄製」隱私設定頁。**不主動觸發權限彈窗**（不呼叫 CGRequestScreenCaptureAccess）。
    private static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
