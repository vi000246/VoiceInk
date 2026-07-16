import CoreAudio
import Foundation
import os

/// M11 訊號 A：讀「哪些行程正在使用麥克風」（FR-86）。
///
/// 只讀 CoreAudio process-object 的**中繼資料**（bundle id、是否收音）——**不建 tap、不碰 PCM、
/// 不觸發 TCC**（沒有權限彈窗）。輪詢設計（非 property listener）：process object 隨行程生滅，
/// 對每個掛/拆 listener 繁瑣易漏；每 3s 讀一次清單＋每行程兩個屬性是微秒級中繼資料讀取。
///
/// 屬性讀法照 `MeetingCaptureService.translatePIDToProcessObject`（同一族 CoreAudio API）。
final class AudioProcessMicWatcher {
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingDetection")

    /// 自身的 process object（排除自己；lazy 解析一次）。翻譯失敗 → nil，改以 bundle id 兜底。
    private lazy var selfProcessObject: AudioObjectID? =
        Self.translatePIDToProcessObject(ProcessInfo.processInfo.processIdentifier)
    private let selfBundleId = Bundle.main.bundleIdentifier

    /// 目前正在使用麥克風輸入的所有行程 bundle id（已排除自身）。
    func currentlyRecordingBundleIds() -> Set<String> {
        var result: Set<String> = []
        for object in Self.processObjectList() {
            if let selfProcessObject, object == selfProcessObject { continue }
            guard Self.isRunningInput(object) else { continue }
            guard let bundleId = Self.bundleID(object), !bundleId.isEmpty else { continue }
            if bundleId == selfBundleId { continue }   // 兜底：pid 翻譯失敗時仍排除自己
            result.insert(bundleId)
        }
        return result
    }

    // MARK: - CoreAudio reads

    private static func processObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.stride
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &ids)
        guard status == noErr else { return [] }
        return ids
    }

    private static func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return false }
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value)
        return status == noErr && value != 0
    }

    private static func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        // 該屬性回傳一個 +1（Create rule）的 CFString。用 Unmanaged + takeRetainedValue
        // 正確接管所有權（避免每次輪詢洩漏一個 CFString）。
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var qualifierPID = pid
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &qualifierPID) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &dataSize,
                &processObject)
        }
        guard status == noErr, processObject != kAudioObjectUnknown else { return nil }
        return processObject
    }
}
