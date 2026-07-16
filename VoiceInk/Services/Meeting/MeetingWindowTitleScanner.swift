import CoreGraphics
import Foundation

/// M11 訊號 B：讀視窗標題，判斷某瀏覽器家族是否有「會議視窗」（FR-88）。
///
/// `CGWindowListCopyWindowInfo` 讀 owner 名不需權限（同 `CopilotOverlayWindowManager.meetingAppScreen`），
/// 但**讀 `kCGWindowName`（標題）需要「螢幕錄製」權限**——未授權時該 key 直接缺席（不丟錯）。
/// 因此權限判斷（`CGPreflightScreenCaptureAccess`）由呼叫端在 tick 前做一次，掃描本身只負責比對。
///
/// **不擷取畫面、不持久化標題**——標題只在記憶體內做 contains 比對。
struct MeetingWindowTitleScanner {

    /// 是否存在一個「屬於 family、標題命中會議 pattern、尺寸 ≥ 200×200」的螢幕上視窗。
    func hasMeetingWindow(for family: MeetingDetectionCatalog.BrowserFamily) -> Bool {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }

        for entry in info {
            guard let owner = entry[kCGWindowOwnerName as String] as? String,
                  family.windowOwnerNames.contains(owner) else { continue }
            guard let name = entry[kCGWindowName as String] as? String, !name.isEmpty else { continue }
            // 尺寸過濾（照抄 meetingAppScreen）：排除選單列小視窗、tooltip 等非主視窗雜訊。
            guard let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 200, bounds.height >= 200 else { continue }
            if MeetingDetectionCatalog.meetingTitlePatterns.contains(where: { name.contains($0) }) {
                return true
            }
        }
        return false
    }
}
