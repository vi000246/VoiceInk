import Foundation
import os

@MainActor
final class RecorderConfigStore: ObservableObject {
    static let shared = RecorderConfigStore()
    @Published private(set) var devices: [RecorderDevice] = []
    private let devicesKey = "recorderDevicesV1"
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let decoded = try? JSONDecoder().decode([RecorderDevice].self, from: data) else { return }
        devices = decoded
    }
    private func save() {
        if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: devicesKey) }
    }
    func upsert(_ device: RecorderDevice) {
        if let i = devices.firstIndex(where: { $0.id == device.id }) { devices[i] = device }
        else { devices.append(device) }
        save()
    }
    func remove(_ id: UUID) { devices.removeAll { $0.id == id }; save() }

    /// First auto-import-enabled device whose match string is contained in the mounted volume name.
    func device(forVolumeName name: String) -> RecorderDevice? {
        devices.first { $0.autoImportEnabled && $0.matches(volumeName: name) }
    }
}
