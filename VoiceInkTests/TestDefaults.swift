import Foundation
@testable import VoiceInk

/// 純記憶體的設定後端，給需要讀寫 `MeetingCopilotConfigStore` 的測試用。
///
/// 🔴 **測試絕不可以碰 `UserDefaults.standard`。** 兩個獨立的理由，缺一個都會出現與被測程式碼
/// 無關的紅燈（2026-07-14 兩種都踩過）：
///
/// 1. **跨 process 汙染。** VoiceInkTests 的 scheme 是 `parallelizable = "YES"` —— 每個 test class
///    跑在自己的 process，但所有 process **共用同一個 UserDefaults domain**。某個測試寫下
///    `useNotesRAG = false` 的同一瞬間，另一個 process 裡斷言「未設定 → 預設 true」的測試就會
///    讀到 false 而爆掉。而且只要測試排程一變（例如新增一個 test class）就時隱時現。
///
/// 2. **開發機上的真實設定。** 就算改用 `UserDefaults(suiteName:)`，它也只是把 suite **加進**
///    search list —— 讀取仍會 fallthrough 到 app 自己的 domain。於是「未設定 → 預設值」的斷言
///    讀到的其實是**你這台機器上 VoiceInk 的真實偏好設定**（你只要跑過 app 就會有值）。
///
/// 所以隔離必須換掉整個後端，而不是換一個 domain。每個 test method 各自 new 一份（XCTest 每個
/// method 都會重建 test class 的實例，所以宣告成 stored property 就是「每個測試一份新的」）；
/// 同一個測試內的多個 `MeetingCopilotConfigStore(defaults:)` 共用同一份 → round-trip
/// （寫入後重新載入）照樣測得到。
final class InMemoryDefaults: MeetingCopilotDefaults {
    private var storage: [String: Any] = [:]

    func object(forKey key: String) -> Any? { storage[key] }
    func string(forKey key: String) -> String? { storage[key] as? String }
    /// 未設定 → false（鏡射 `UserDefaults.bool(forKey:)`）。
    func bool(forKey key: String) -> Bool { (storage[key] as? Bool) ?? false }
    /// 未設定 → 0（鏡射 `UserDefaults.integer(forKey:)`）。
    func integer(forKey key: String) -> Int { (storage[key] as? Int) ?? 0 }

    func set(_ value: Any?, forKey key: String) {
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }

    func removeObject(forKey key: String) { storage.removeValue(forKey: key) }
}
