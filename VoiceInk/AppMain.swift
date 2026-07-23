import SwiftUI
import AppKit

/// 自訂入口:單元測試以 app 為 test host,平行測試會同時啟動十幾份完整 app
/// (搶熱鍵/麥克風、各自初始化 CloudKit、Dock 洗版)。在入口就分流,測試時
/// 完全不執行 VoiceInkApp.init,比逐一 guard 每個服務可靠。
/// XCTestConfigurationFilePath 只存在於 unit-test host 程序;UI 測試啟動的
/// 目標 app 沒有這個環境變數,仍走完整 app。
@main
enum AppMain {
    static func main() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            TestHostApp.main()
        } else {
            VoiceInkApp.main()
        }
    }
}

/// 測試 host 專用空殼:無視窗、無 Dock 圖示、不啟動任何服務。
struct TestHostApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.prohibited)
    }

    var body: some Scene {
        Settings { EmptyView() }
    }
}
