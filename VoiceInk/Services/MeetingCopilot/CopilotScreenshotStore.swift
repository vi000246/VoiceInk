import Foundation
import Combine

/// 「截圖深答」的暫存佇列(手動視覺功能)。
///
/// # 為什麼是 session 全域、住記憶體
/// - 全域:截圖與「送出重生」是兩個獨立動作(先按熱鍵累積、再按 overlay 按鈕送出);切換正在讀的
///   cue 時佇列不清(使用者可以邊看 A 邊截圖、決定配到 B)。送出後才 `clear()`。
/// - 記憶體:截圖含畫面內容,**不落 SwiftData**(隱私 + 體積)。會議結束、app 關閉就沒了,正確。
///
/// # 為什麼 auto-deep 不碰
/// 圖片深答一次燒 1~1.6k token/張,且只在使用者「決定要送這幾張」時才有意義——auto-deep 是背景
/// 加值,不該擅自把畫面截下來上傳。閘門就是這個 store:只有熱鍵會 `captureAndAdd`,只有 overlay
/// 的按鈕會 `send`。
@MainActor
final class CopilotScreenshotStore: ObservableObject {

    static let shared = CopilotScreenshotStore()

    /// 佇列上限。多圖 token 隨張數線性增長,4 張足以覆蓋「一頁截不完、捲動補幾張」的常見情況。
    static let maxShots = 4

    /// 已累積的截圖(JPEG)。overlay 觀察 `count` 顯示徽章與按鈕。
    @Published private(set) var shots: [Data] = []
    /// 擷取進行中(避免熱鍵連按重入;region 模式期間會一直為 true 直到使用者完成/取消選取)。
    @Published private(set) var isCapturing = false

    /// 每次擷取各自建一個 `ScreenCaptureService`——它的 `isCapturing` reentrancy guard 是 per-instance,
    /// 與 grounding 持有的那個實例互不干擾(截圖不會卡住 Tier 2 的 OCR 接地)。
    private let capture = ScreenCaptureService()

    private init() {}

    var count: Int { shots.count }
    var isEmpty: Bool { shots.isEmpty }

    /// `.captureCopilotScreenshot` 熱鍵入口:依設定的擷取對象截一張、加入佇列(滿了丟最舊)。
    func captureAndAdd() async {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        let target = MeetingCopilotConfigStore.shared.screenshotTarget
        guard let jpeg = await capture.captureImageData(target: target) else { return }
        shots.append(jpeg)
        if shots.count > Self.maxShots {
            shots.removeFirst(shots.count - Self.maxShots)
        }
    }

    /// 送出後清空(由 overlay 的送出流程在**成功送出**時呼叫;失敗不清,截圖留著讓使用者重試)。
    func clear() {
        shots.removeAll()
    }

    /// 只移除**已送出的前 count 張**(佇列前端 = 較舊 = 送出的那批)。深答進行中新截的圖在尾端,
    /// 不受影響——避免「送出後 clear 整個佇列」把在途期間新截的圖一起清掉(截圖白截)。
    func removeSent(_ count: Int) {
        guard count > 0 else { return }
        shots.removeFirst(min(count, shots.count))
    }
}
