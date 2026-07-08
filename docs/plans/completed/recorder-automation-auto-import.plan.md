---
linear_issue: null
---
# Plan: Recorder Auto-Import (M1)

> **For agentic workers:** `/prp-implement` routes this plan by `Metadata.Type` (feature). Steps use checkbox (`- [ ]`) tracking. Mode B — task-level test-first, balanced rigor: pure-logic units get a failing test first; mount/queue/UI tasks are verified manually (see Manual Validation).

## Summary
Milestone 1 of the recorder-automation module: plug in a configured recorder (volume like
"IC RECORDER"), and new audio files are auto-imported into the existing transcription queue,
transcribed **raw** (no Mode enhancement), and saved to VoiceInk history — zero clicks. Includes
idempotent dedup and a minimal "Recorders" settings page to register one device. Classification,
template routing, vault export, polished card UI, and diarization are **later milestones**.

## User Story
As a recorder owner, I want new recordings to auto-transcribe into VoiceInk the moment I plug in
the device, so that I never manually import or click transcribe.

## Problem → Solution
Today: manually drag files into Transcribe Audio and click Start. → M1: mount detection +
auto-import + auto-start transcription, with exactly-once dedup.

## Metadata
- **Module**: recorder-automation
- **Parent Plan**: N/A
- **Source PRD**: `docs/prd/recorder-auto-import-and-template-routing.prd.md`
- **Source Feature SRS**: `docs/srs/recorder-automation-auto-import-template-routing.srs.md`
- **Source Module Spec**: `docs/spec/recorder-automation.spec.md`
- **Source Linear Issue**: N/A
- **Type**: feature
- **Size**: M (M1 slice of an XL feature)
- **Complexity**: Medium
- **Rigor**: balanced
- **Mode**: B — 任務先測
- **TDD**: on (unit-testable logic); manual for hardware/UI
- **Commit cadence**: per-task
- **Estimated Files**: 7 new, 5 modified

---

## UX Design

### Before
```
Plug in recorder → open Finder → drag files into VoiceInk "Transcribe Audio"
→ pick mode → click Start → wait → results in History
```

### After
```
Plug in recorder → (notification "匯入 N 個新檔") → auto-transcribe in background
→ (notification "完成") → results in History.   Zero clicks.
One-time setup: Settings → Recorders → Add this device → pick source folder.
```

### Interaction Changes
| Touchpoint | Before | After | Notes |
|---|---|---|---|
| Import | Manual drag + Start click | Automatic on mount | Gated by per-device `autoImportEnabled` |
| Enhancement | Active Mode prompt applied | **Skipped** for recorder items (raw) | Classification/routing arrives in M2 |
| Config | N/A | New "Recorders" settings page | Minimal in M1; full card UI in M4 |

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/recorder-automation-auto-import-template-routing.srs.md` | all | FR/AC for M1 (FR-1..5,11,13,14; AC-1,2,3,8) |
| P0 | `docs/spec/recorder-automation.spec.md` | Components, Data Model, Patterns | Authoritative architecture |
| P0 | `VoiceInk/Services/AudioFileTranscriptionManager.swift` | 8-115, 181-266 | Queue lifecycle + enhancement block to bypass |
| P0 | `VoiceInk/Models/AudioFileQueueItem.swift` | 26-44 | Add `origin` tag |
| P0 | `VoiceInk/VoiceInk.swift` | 39-80, 119-121 | Schema array; manager `configure(...)` wiring pattern |
| P1 | `VoiceInk/Modes/ModeConfig.swift` | 259-287, 485-492 | `ModeManager.shared.activeConfiguration`; JSON-in-UserDefaults persistence to mirror |
| P1 | `VoiceInk/Views/AudioTranscribeView.swift` | 320-322, 347-355 | `startProcessing` call; NSOpenPanel + security-scoped pattern |
| P1 | `VoiceInk/Views/ContentView.swift` | 4-16, 67-88 | `ViewType` enum + `detailView(for:)` routing |
| P1 | `VoiceInk/Views/Sidebar/AppSidebar.swift` | 69-126 | Sidebar arrays + `icon`/`sidebarIconStyle` + `assertSidebarItemsCoverAllCases()` |
| P1 | `VoiceInk/Notifications/NotificationManager.swift` | 12-81 | Floating notification API |
| P1 | `VoiceInk/Notifications/AppNotifications.swift` | 3-23 | `Notification.Name` extension pattern |
| P2 | `VoiceInk/Models/Transcription.swift` | 12-66 | Additive optional fields + lightweight migration |
| P2 | `VoiceInk/Services/SupportedMedia.swift` | 1-20 | `SupportedMedia.isSupported(url:)` |

## External Documentation

| Topic | Source | Key Takeaway |
|---|---|---|
| Volume mount events | `NSWorkspace.didMountNotification` / `.didUnmountNotification` (AppKit) | Posted on `NSWorkspace.shared.notificationCenter`; `userInfo["NSWorkspaceVolumeURLKey"]` holds the volume URL |
| File hashing | `CryptoKit.SHA256` | `SHA256.hash(data:)`; map bytes to hex string |
| Security-scoped bookmarks | Apple File System Programming Guide | `url.bookmarkData(options: .withSecurityScope)`; resolve with `.withSecurityScope` + `startAccessingSecurityScopedResource()` |

> No external research beyond Apple frameworks — feature uses established internal patterns.

---

## Patterns to Mirror

### NAMING_CONVENTION
```swift
// SOURCE: VoiceInk/Services/AudioFileTranscriptionManager.swift:8-21
@MainActor
class AudioTranscriptionManager: ObservableObject {
    static let shared = AudioTranscriptionManager()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AudioTranscriptionManager")
    private init() {}
}
```

### CONFIG_PERSISTENCE (JSON in UserDefaults)
```swift
// SOURCE: VoiceInk/Modes/ModeConfig.swift:262-287
private let configKey = "modeConfigurationsV2"
func saveConfigurations() {
    if let data = try? JSONEncoder().encode(configurations) {
        UserDefaults.standard.set(data, forKey: configKey)
    }
}
```

### SWIFTDATA_MODEL + ADDITIVE_FIELDS
```swift
// SOURCE: VoiceInk/Models/Transcription.swift:11-31
@Model
final class Transcription {
    var id: UUID = UUID()
    var text: String = ""
    var enhancedText: String?
    @Attribute(originalName: "powerModeName") var modeName: String?  // safe rename/migration
}
```

### SCHEMA_REGISTRATION
```swift
// SOURCE: VoiceInk/VoiceInk.swift:48-49
let schema = Schema([
    Transcription.self,
    // ... add ImportLedgerEntry.self here
])
```

### QUEUE_ENQUEUE + DEDUP-BY-PATH
```swift
// SOURCE: VoiceInk/Services/AudioFileTranscriptionManager.swift:28-43
func addToQueue(urls: [URL]) {
    for url in urls {
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        guard SupportedMedia.isSupported(url: url) else { continue }
        let path = url.standardizedFileURL.path
        if queue.contains(where: { $0.url.standardizedFileURL.path == path && !$0.status.isTerminal }) { continue }
        queue.append(AudioFileQueueItem(url: url))
    }
}
```

### AUTO-START_TRANSCRIPTION
```swift
// SOURCE: VoiceInk/Views/AudioTranscribeView.swift:320-322
private func startProcessing() {
    transcriptionManager.startProcessing(modelContext: modelContext, engine: engine, mode: selectedMode)
}
```

### NOTIFICATION_NAME + TOAST
```swift
// SOURCE: VoiceInk/Notifications/AppNotifications.swift:3-23
extension Notification.Name {
    static let transcriptionCompleted = Notification.Name("transcriptionCompleted")
}
// SOURCE: VoiceInk/Notifications/NotificationManager.swift:12
NotificationManager.shared.showNotification(title: "完成", type: .success, duration: 3)
```

### SECURITY_SCOPED_BOOKMARK (capture + resolve)
```swift
// SOURCE pattern: VoiceInk/Views/AudioTranscribeView.swift:347-355 (NSOpenPanel)
//                 VoiceInk/Services/AudioFileTranscriptionManager.swift:138-139 (start/stop access)
let accessing = url.startAccessingSecurityScopedResource()
defer { if accessing { url.stopAccessingSecurityScopedResource() } }
```

### MANAGER_CONFIGURE_WIRING (inject engine/context at launch)
```swift
// SOURCE: VoiceInk/VoiceInk.swift:119-121
recorderUIManager.configure(engine: engine, recorder: engine.recorder)
engine.recorderUIManager = recorderUIManager
```

### TEST_STRUCTURE (XCTest + in-memory SwiftData)
```swift
// SOURCE: VoiceInkTests/VoiceInkTests.swift (template) — extend with real tests
import XCTest
import SwiftData
@testable import VoiceInk

final class ImportLedgerTests: XCTestCase {
    func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: ImportLedgerEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }
}
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Models/ImportLedgerEntry.swift` | CREATE | SwiftData dedup ledger entity |
| `VoiceInk/Services/RecorderAutomation/ImportLedger.swift` | CREATE | Fingerprint + dedup service |
| `VoiceInk/Services/RecorderAutomation/RecorderDevice.swift` | CREATE | Device config struct |
| `VoiceInk/Services/RecorderAutomation/RecorderConfigStore.swift` | CREATE | Persist devices (UserDefaults JSON) |
| `VoiceInk/Services/RecorderAutomation/RecorderImportService.swift` | CREATE | Scan/dedup/copy/enqueue/auto-start |
| `VoiceInk/Services/RecorderAutomation/RecorderDeviceMonitor.swift` | CREATE | NSWorkspace mount observer |
| `VoiceInk/Views/Settings/RecordersSettingsView.swift` | CREATE | Minimal device registration UI |
| `VoiceInk/Models/AudioFileQueueItem.swift` | UPDATE | Add `origin` tag |
| `VoiceInk/Services/AudioFileTranscriptionManager.swift` | UPDATE | `addToQueue(urls:origin:)`; bypass enhancement for recorder items; stamp metadata |
| `VoiceInk/Models/Transcription.swift` | UPDATE | Add `recorderSourceDeviceId`, `importFingerprint` |
| `VoiceInk/VoiceInk.swift` | UPDATE | Register `ImportLedgerEntry`; start monitor at launch |
| `VoiceInk/Views/ContentView.swift` + `VoiceInk/Views/Sidebar/AppSidebar.swift` | UPDATE | New `recorders` ViewType + routing + sidebar |
| `VoiceInk/Notifications/AppNotifications.swift` | UPDATE | New `recorderImportCompleted` name |
| `VoiceInk.xcodeproj/project.pbxproj` | UPDATE | Add new files + test files to targets |

## NOT Building (M1)
- Content classification / confidence scoring (M2).
- Template routing to a category's CustomPrompt (M2).
- Markdown export to Obsidian vault (M3).
- Categories page; polished card + 400pt side-panel device UI (M4).
- Real speaker diarization (M5).
- Long-transcript map-reduce summarization (M2/M3).
- Auto-retry of a failed recorder transcription within the same session (see Risks).

---

## Step-by-Step Tasks

### Task 1: Import ledger (model + dedup service)

**Files:**
- Create: `VoiceInk/Models/ImportLedgerEntry.swift`, `VoiceInk/Services/RecorderAutomation/ImportLedger.swift`
- Modify: `VoiceInk/VoiceInk.swift:48` (Schema)
- Test: `VoiceInkTests/ImportLedgerTests.swift`

- [ ] **TEST FIRST**
```swift
import XCTest
import SwiftData
@testable import VoiceInk

final class ImportLedgerTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let c = try ModelContainer(for: ImportLedgerEntry.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(c)
    }

    func testContentFingerprintIsStableSHA256() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID()).bin")
        try Data("hello".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // sha256("hello") = 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
        XCTAssertEqual(try ImportLedger.shared.contentFingerprint(for: tmp),
                       "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    func testIsImportedReflectsRecord() throws {
        let ctx = try makeContext()
        XCTAssertFalse(ImportLedger.shared.isImported(fingerprint: "abc", in: ctx))
        ImportLedger.shared.record(fingerprint: "abc", fileName: "a.wav", byteSize: 3,
                                   sourceDeviceId: nil, transcriptionId: nil, in: ctx)
        XCTAssertTrue(ImportLedger.shared.isImported(fingerprint: "abc", in: ctx))
    }
}
```
  Run: `xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS' -only-testing:VoiceInkTests/ImportLedgerTests` — expect FAIL (types don't exist).

- [ ] **IMPLEMENT** — `ImportLedgerEntry.swift`:
```swift
import Foundation
import SwiftData

@Model
final class ImportLedgerEntry {
    var fingerprint: String = ""   // sha256(content) — primary dedup key
    var fileName: String = ""
    var byteSize: Int = 0
    var sourceDeviceId: UUID?
    var importedAt: Date = Date()
    var transcriptionId: UUID?

    init(fingerprint: String, fileName: String, byteSize: Int,
         sourceDeviceId: UUID?, transcriptionId: UUID? = nil) {
        self.fingerprint = fingerprint
        self.fileName = fileName
        self.byteSize = byteSize
        self.sourceDeviceId = sourceDeviceId
        self.importedAt = Date()
        self.transcriptionId = transcriptionId
    }
}
```
  `ImportLedger.swift`:
```swift
import Foundation
import SwiftData
import CryptoKit
import os

@MainActor
final class ImportLedger {
    static let shared = ImportLedger()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private init() {}

    /// Cheap pre-filter key (no file read).
    func quickKey(fileName: String, byteSize: Int) -> String { "\(fileName)|\(byteSize)" }

    /// SHA-256 hex of the file's bytes.
    func contentFingerprint(for url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isImported(fingerprint: String, in context: ModelContext) -> Bool {
        var d = FetchDescriptor<ImportLedgerEntry>(predicate: #Predicate { $0.fingerprint == fingerprint })
        d.fetchLimit = 1
        return ((try? context.fetch(d))?.isEmpty == false)
    }

    /// Quick-path: any ledger row with same (fileName, byteSize)?
    func hasQuickMatch(fileName: String, byteSize: Int, in context: ModelContext) -> Bool {
        var d = FetchDescriptor<ImportLedgerEntry>(
            predicate: #Predicate { $0.fileName == fileName && $0.byteSize == byteSize })
        d.fetchLimit = 1
        return ((try? context.fetch(d))?.isEmpty == false)
    }

    func record(fingerprint: String, fileName: String, byteSize: Int,
                sourceDeviceId: UUID?, transcriptionId: UUID?, in context: ModelContext) {
        context.insert(ImportLedgerEntry(fingerprint: fingerprint, fileName: fileName,
                                         byteSize: byteSize, sourceDeviceId: sourceDeviceId,
                                         transcriptionId: transcriptionId))
        do { try context.save() } catch { logger.error("Ledger save failed: \(error, privacy: .public)") }
    }
}
```
  In `VoiceInk.swift:48` add `ImportLedgerEntry.self` to the `Schema([...])` array (the default/transcript store).
- [ ] **MIRROR**: SWIFTDATA_MODEL, SCHEMA_REGISTRATION, NAMING_CONVENTION.
- [ ] **VALIDATE**: re-run the Task-1 test command — expect PASS.
- [ ] **COMMIT**: `feat(recorder): add import ledger model + dedup service`

---

### Task 2: Recorder device config + store

**Files:**
- Create: `VoiceInk/Services/RecorderAutomation/RecorderDevice.swift`, `RecorderConfigStore.swift`
- Test: `VoiceInkTests/RecorderDeviceTests.swift`

- [ ] **TEST FIRST**
```swift
import XCTest
@testable import VoiceInk

final class RecorderDeviceTests: XCTestCase {
    func testVolumeNameMatchIsCaseInsensitiveContains() {
        let d = RecorderDevice(displayName: "Sony", volumeNameMatch: "IC RECORDER",
                               sourceFolderBookmark: Data())
        XCTAssertTrue(d.matches(volumeName: "IC RECORDER"))
        XCTAssertTrue(d.matches(volumeName: "ic recorder"))
        XCTAssertFalse(d.matches(volumeName: "USB DRIVE"))
    }

    func testCodableRoundTrip() throws {
        let d = RecorderDevice(displayName: "Sony", volumeNameMatch: "IC RECORDER",
                               sourceFolderBookmark: Data([1,2,3]), autoImportEnabled: true,
                               deleteAfterImport: false)
        let data = try JSONEncoder().encode([d])
        let back = try JSONDecoder().decode([RecorderDevice].self, from: data)
        XCTAssertEqual(back.first, d)
    }
}
```
  Run: `... -only-testing:VoiceInkTests/RecorderDeviceTests` — expect FAIL.

- [ ] **IMPLEMENT** — `RecorderDevice.swift`:
```swift
import Foundation

struct RecorderDevice: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    var volumeNameMatch: String       // matched against mounted volume name, e.g. "IC RECORDER"
    var sourceFolderBookmark: Data    // security-scoped bookmark to the folder ON the device
    var autoImportEnabled: Bool
    var deleteAfterImport: Bool
    var createdAt: Date

    init(id: UUID = UUID(), displayName: String, volumeNameMatch: String,
         sourceFolderBookmark: Data, autoImportEnabled: Bool = true,
         deleteAfterImport: Bool = false, createdAt: Date = Date()) {
        self.id = id; self.displayName = displayName; self.volumeNameMatch = volumeNameMatch
        self.sourceFolderBookmark = sourceFolderBookmark; self.autoImportEnabled = autoImportEnabled
        self.deleteAfterImport = deleteAfterImport; self.createdAt = createdAt
    }

    func matches(volumeName: String) -> Bool {
        volumeName.localizedCaseInsensitiveContains(volumeNameMatch)
    }
}
```
  `RecorderConfigStore.swift`:
```swift
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
```
- [ ] **MIRROR**: CONFIG_PERSISTENCE, NAMING_CONVENTION.
- [ ] **VALIDATE**: re-run Task-2 test — expect PASS.
- [ ] **COMMIT**: `feat(recorder): add device config + UserDefaults-backed store`

---

### Task 3: Transcription additive fields

**Files:** Modify `VoiceInk/Models/Transcription.swift:12-66`

- [ ] **ACTION**: add two optional properties (default-safe → SwiftData lightweight migration) and accept them in the initializer.
- [ ] **TEST**: covered indirectly by Task 5 integration + manual; no standalone unit test (model is a data holder). Balanced rigor: skip dedicated test.
- [ ] **IMPLEMENT**: after `var transcriptionStatus: String?` (line ~31) add:
```swift
    var recorderSourceDeviceId: UUID?
    var importFingerprint: String?
```
  Add matching params to `init(...)` with defaults `recorderSourceDeviceId: UUID? = nil, importFingerprint: String? = nil` and assign them. (Existing call sites unaffected — defaults preserve them.)
- [ ] **MIRROR**: SWIFTDATA_MODEL + ADDITIVE_FIELDS.
- [ ] **VALIDATE**: `xcodebuild ... build` — expect compile success; existing `Transcription(...)` calls still compile.
- [ ] **COMMIT**: `feat(recorder): add recorder metadata fields to Transcription`

---

### Task 4: Queue origin tag + enhancement bypass

**Files:**
- Modify: `VoiceInk/Models/AudioFileQueueItem.swift:26-44`, `VoiceInk/Services/AudioFileTranscriptionManager.swift:28-43,115,181-248`

- [ ] **ACTION**: tag queue items with an origin; for `.recorderImport`, skip Mode enhancement and stamp recorder metadata.
- [ ] **TEST**: manual/integration (touches the live transcription engine) — verified in Task 5 + Manual Validation. Balanced rigor: no isolated unit test for the engine branch.
- [ ] **IMPLEMENT** — `AudioFileQueueItem.swift`: add above the class:
```swift
enum QueueItemOrigin: Equatable {
    case manual
    case recorderImport(deviceId: UUID, fingerprint: String)
}
```
  In `AudioFileQueueItem` add `let origin: QueueItemOrigin` and update init:
```swift
    init(url: URL, origin: QueueItemOrigin = .manual) {
        self.url = url
        self.filename = url.lastPathComponent
        self.origin = origin
    }
```
  `AudioFileTranscriptionManager.swift` — overload `addToQueue` (keep existing for manual drops):
```swift
    func addToQueue(urls: [URL], origin: QueueItemOrigin) {
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard SupportedMedia.isSupported(url: url) else { continue }
            let path = url.standardizedFileURL.path
            if queue.contains(where: { $0.url.standardizedFileURL.path == path && !$0.status.isTerminal }) { continue }
            queue.append(AudioFileQueueItem(url: url, origin: origin))
        }
    }
```
  In `processItem` (line 195), change the enhancement guard so recorder items skip it:
```swift
            if case .manual = item.origin,
               let enhancementService = engine.enhancementService,
               let enhancementConfiguration,
               enhancementConfiguration.isEnabled,
               enhancementService.isConfigured(for: enhancementConfiguration) {
                // ... existing enhancement branch unchanged (lines 199-233) ...
            } else {
                // ... existing raw-transcription branch unchanged (lines 235-244) ...
            }
```
  Immediately before `modelContext.insert(transcription)` (line 247) stamp recorder metadata:
```swift
            if case let .recorderImport(deviceId, fingerprint) = item.origin {
                transcription.recorderSourceDeviceId = deviceId
                transcription.importFingerprint = fingerprint
            }
```
- [ ] **GOTCHA**: recorder items must land in the `else` branch — do not also gate the `else` on origin. The `if case .manual` is the only added condition.
- [ ] **MIRROR**: QUEUE_ENQUEUE.
- [ ] **VALIDATE**: `xcodebuild ... build` — expect success.
- [ ] **COMMIT**: `feat(recorder): tag queue items by origin and bypass enhancement for imports`

---

### Task 5: Recorder import service (scan → dedup → copy → enqueue → auto-start → ledger)

**Files:**
- Create: `VoiceInk/Services/RecorderAutomation/RecorderImportService.swift`
- Test: `VoiceInkTests/RecorderImportServiceTests.swift`

- [ ] **TEST FIRST** (the pure scan+dedup decision over a temp directory; engine/enqueue injected as closures):
```swift
import XCTest
import SwiftData
@testable import VoiceInk

final class RecorderImportServiceTests: XCTestCase {
    func testScanReturnsOnlyNewSupportedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("a.wav"); try Data([1,2,3]).write(to: wav)
        let txt = dir.appendingPathComponent("note.txt"); try Data([9]).write(to: txt) // unsupported
        let ctx = try ModelContext(ModelContainer(for: ImportLedgerEntry.self,
                                   configurations: ModelConfiguration(isStoredInMemoryOnly: true)))

        let first = RecorderImportService.shared.newImportableFiles(in: dir, context: ctx)
        XCTAssertEqual(first.map { $0.url.lastPathComponent }, ["a.wav"]) // txt filtered out

        // Simulate it was imported → ledger record → no longer returned
        let fp = try ImportLedger.shared.contentFingerprint(for: wav)
        ImportLedger.shared.record(fingerprint: fp, fileName: "a.wav", byteSize: 3,
                                   sourceDeviceId: nil, transcriptionId: nil, in: ctx)
        let second = RecorderImportService.shared.newImportableFiles(in: dir, context: ctx)
        XCTAssertTrue(second.isEmpty)
    }
}
```
  Run: `... -only-testing:VoiceInkTests/RecorderImportServiceTests` — expect FAIL.

- [ ] **IMPLEMENT** — `RecorderImportService.swift`:
```swift
import Foundation
import SwiftData
import os

struct ImportCandidate { let url: URL; let fingerprint: String; let fileName: String; let byteSize: Int }

@MainActor
final class RecorderImportService: ObservableObject {
    static let shared = RecorderImportService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private var inFlight = Set<String>()           // fingerprints enqueued this session
    private weak var engine: VoiceInkEngine?
    private var modelContext: ModelContext?
    private init() {
        // Record ledger entry once a recorder transcription succeeds.
        NotificationCenter.default.addObserver(self, selector: #selector(onTranscriptionCreated(_:)),
                                               name: .transcriptionCreated, object: nil)
    }

    func configure(engine: VoiceInkEngine, modelContext: ModelContext) {
        self.engine = engine; self.modelContext = modelContext
    }

    /// Pure decision: supported + not-yet-imported (ledger) + not in-flight.
    func newImportableFiles(in folder: URL, context: ModelContext) -> [ImportCandidate] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        var out: [ImportCandidate] = []
        for url in urls where SupportedMedia.isSupported(url: url) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard let fp = try? ImportLedger.shared.contentFingerprint(for: url) else { continue }
            if inFlight.contains(fp) { continue }
            if ImportLedger.shared.isImported(fingerprint: fp, in: context) { continue }
            out.append(ImportCandidate(url: url, fingerprint: fp, fileName: url.lastPathComponent, byteSize: size))
        }
        return out
    }

    /// Triggered by the monitor when a configured device mounts.
    func handleMount(device: RecorderDevice) {
        guard let modelContext, let engine else { logger.error("Import service not configured"); return }
        guard let folder = resolveSourceFolder(device) else {
            NotificationManager.shared.showNotification(title: "錄音筆來源資料夾無法存取，請重新授權", type: .warning, duration: 4)
            return
        }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }

        let candidates = newImportableFiles(in: folder, context: modelContext)
        guard !candidates.isEmpty else { return }

        var enqueued: [URL] = []
        for c in candidates {
            guard let copied = copyIntoAppStorage(c.url) else { continue }
            inFlight.insert(c.fingerprint)
            enqueued.append(copied)
            AudioTranscriptionManager.shared.addToQueue(urls: [copied],
                origin: .recorderImport(deviceId: device.id, fingerprint: c.fingerprint))
        }
        guard !enqueued.isEmpty else { return }
        NotificationManager.shared.showNotification(title: "匯入 \(enqueued.count) 個新檔", type: .info, duration: 3)
        let mode = ModeManager.shared.activeConfiguration ?? ModeManager.shared.configurations.first
        if let mode {
            AudioTranscriptionManager.shared.startProcessing(modelContext: modelContext, engine: engine, mode: mode)
        }
    }

    private func resolveSourceFolder(_ device: RecorderDevice) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: device.sourceFolderBookmark,
                        options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func copyIntoAppStorage(_ src: URL) -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.prakashjoshipax.VoiceInk").appendingPathComponent("RecorderImports")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dst = dir.appendingPathComponent("\(UUID().uuidString)-\(src.lastPathComponent)")
        do { try FileManager.default.copyItem(at: src, to: dst); return dst }
        catch { logger.error("Copy failed: \(error, privacy: .public)"); return nil }
    }

    @objc private func onTranscriptionCreated(_ note: Notification) {
        guard let t = note.object as? Transcription, let fp = t.importFingerprint,
              let ctx = modelContext else { return }
        guard !ImportLedger.shared.isImported(fingerprint: fp, in: ctx) else { return }
        ImportLedger.shared.record(fingerprint: fp, fileName: "", byteSize: 0,
                                   sourceDeviceId: t.recorderSourceDeviceId, transcriptionId: t.id, in: ctx)
        NotificationCenter.default.post(name: .recorderImportCompleted, object: t)
    }
}
```
- [ ] **GOTCHA**: ledger is recorded only on `.transcriptionCreated` (success). A failed transcription leaves the fingerprint in `inFlight` (blocks retry until app restart) but **not** in the persisted ledger — accepted M1 limitation (see Risks).
- [ ] **GOTCHA**: `newImportableFiles` is the unit-tested seam; `handleMount` is integration (engine/notifications) and verified manually.
- [ ] **MIRROR**: QUEUE_ENQUEUE, AUTO-START_TRANSCRIPTION, SECURITY_SCOPED_BOOKMARK, NAMING_CONVENTION.
- [ ] **VALIDATE**: re-run Task-5 test — expect PASS.
- [ ] **COMMIT**: `feat(recorder): import service — scan, dedup, copy, enqueue, auto-start`

---

### Task 6: Mount monitor

**Files:** Create `VoiceInk/Services/RecorderAutomation/RecorderDeviceMonitor.swift`

- [ ] **ACTION**: observe `NSWorkspace` mount notifications; on a configured-device match, call `RecorderImportService.handleMount`.
- [ ] **TEST**: manual (hardware event) — see Manual Validation AC-1.
- [ ] **IMPLEMENT**:
```swift
import Foundation
import AppKit
import os

@MainActor
final class RecorderDeviceMonitor {
    static let shared = RecorderDeviceMonitor()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")
    private var started = false
    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumeDidMount(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        // Catch a device already mounted at launch.
        for url in (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []) {
            evaluate(volumeURL: url)
        }
        logger.notice("RecorderDeviceMonitor started")
    }

    @objc private func volumeDidMount(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        evaluate(volumeURL: url)
    }

    private func evaluate(volumeURL: URL) {
        let name = (try? volumeURL.resourceValues(forKeys: [.volumeNameKey]).volumeName)
            ?? volumeURL.lastPathComponent
        guard let device = RecorderConfigStore.shared.device(forVolumeName: name) else { return }
        logger.notice("Recorder mounted: \(name, privacy: .public)")
        RecorderImportService.shared.handleMount(device: device)
    }
}
```
- [ ] **GOTCHA**: `NSWorkspace.volumeURLUserInfoKey` is the correct key on the workspace notification (not `.fileURLUserInfoKey`).
- [ ] **MIRROR**: NAMING_CONVENTION.
- [ ] **VALIDATE**: `xcodebuild ... build`; functional check in Manual Validation.
- [ ] **COMMIT**: `feat(recorder): NSWorkspace mount monitor`

---

### Task 7: Notification name

**Files:** Modify `VoiceInk/Notifications/AppNotifications.swift:3-23`

- [ ] **IMPLEMENT**: add to the `Notification.Name` extension:
```swift
    static let recorderImportCompleted = Notification.Name("recorderImportCompleted")
```
- [ ] **MIRROR**: NOTIFICATION_NAME.
- [ ] **VALIDATE**: `xcodebuild ... build`.
- [ ] **COMMIT**: `feat(recorder): add recorderImportCompleted notification name`

---

### Task 8: Minimal Recorders settings page + sidebar wiring

**Files:**
- Create: `VoiceInk/Views/Settings/RecordersSettingsView.swift`
- Modify: `VoiceInk/Views/ContentView.swift:4-16,67-88`, `VoiceInk/Views/Sidebar/AppSidebar.swift:69-126`

- [ ] **ACTION**: add a `recorders` ViewType + a simple Form page to register one device (pick a mounted volume + source folder → security-scoped bookmark, toggles).
- [ ] **TEST**: manual (UI) — see Manual Validation.
- [ ] **IMPLEMENT** — `ContentView.swift`: add `case recorders = "Recorders"` to `ViewType`; in `detailView(for:)` add `case .recorders: RecordersSettingsView()`.
  `AppSidebar.swift`: add `.recorders` to `secondaryItems`; add to **both** `icon` and `sidebarIconStyle` switches:
```swift
        case .recorders: return "recordingtape"          // in icon
        case .recorders: return .init(background: AppTheme.Sidebar.fallback)  // in sidebarIconStyle
```
  `RecordersSettingsView.swift`:
```swift
import SwiftUI
import AppKit

struct RecordersSettingsView: View {
    @StateObject private var store = RecorderConfigStore.shared

    var body: some View {
        Form {
            Section("已設定的錄音筆") {
                if store.devices.isEmpty { Text("尚未設定。插入錄音筆後點下方新增。").foregroundStyle(.secondary) }
                ForEach(store.devices) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.displayName).font(.headline)
                            Text("符合磁碟名稱：\(d.volumeNameMatch)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("自動匯入", isOn: bindingAutoImport(d))
                        Button(role: .destructive) { store.remove(d.id) } label: { Image(systemName: "trash") }
                    }
                }
            }
            Section { Button("新增目前插入的裝置…") { addCurrentDevice() } }
        }
        .formStyle(.grouped)
    }

    private func bindingAutoImport(_ d: RecorderDevice) -> Binding<Bool> {
        Binding(get: { d.autoImportEnabled },
                set: { var x = d; x.autoImportEnabled = $0; store.upsert(x) })
    }

    private func addCurrentDevice() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "選擇錄音筆上存放錄音的資料夾"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let volumeName = (try? folder.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? folder.lastPathComponent
        guard let bookmark = try? folder.bookmarkData(options: [.withSecurityScope],
                                                      includingResourceValuesForKeys: nil, relativeTo: nil) else {
            NotificationManager.shared.showNotification(title: "無法建立資料夾授權", type: .error, duration: 4); return
        }
        store.upsert(RecorderDevice(displayName: volumeName, volumeNameMatch: volumeName, sourceFolderBookmark: bookmark))
    }
}
```
- [ ] **GOTCHA**: `AppSidebar.assertSidebarItemsCoverAllCases()` asserts every `ViewType` appears in `primaryItems + secondaryItems`. Adding the enum case **without** adding it to a sidebar array crashes DEBUG builds. Update all five sites: enum, secondaryItems, icon, sidebarIconStyle, ContentView routing.
- [ ] **GOTCHA**: the source folder lives on the device volume; `NSOpenPanel` directory selection yields a security-scoped URL whose bookmark re-resolves on later mounts. Confirm the app's entitlements permit user-selected read access (see Risks / SRS open question).
- [ ] **MIRROR**: SECURITY_SCOPED_BOOKMARK; settings Form pattern at `AudioCleanupSettingsView.swift`.
- [ ] **VALIDATE**: `xcodebuild ... build`; UI check in Manual Validation.
- [ ] **COMMIT**: `feat(recorder): minimal Recorders settings page + sidebar entry`

---

### Task 9: Bootstrap — start monitor at launch

**Files:** Modify `VoiceInk/VoiceInk.swift` (around the manager wiring at :119-121 and the launch path)

- [ ] **ACTION**: configure the import service with the engine + main `ModelContext`, then start the monitor.
- [ ] **TEST**: manual (launch) — see Manual Validation.
- [ ] **IMPLEMENT**: where the engine + `sharedModelContainer` are available at startup (mirror the `recorderUIManager.configure(...)` wiring at :119-121), add:
```swift
        RecorderImportService.shared.configure(engine: engine, modelContext: sharedModelContainer.mainContext)
        RecorderDeviceMonitor.shared.start()
```
- [ ] **GOTCHA**: this must run on the main actor after the engine and container exist. Place it alongside the existing `recorderUIManager.configure(...)` call, not in a property initializer.
- [ ] **MIRROR**: MANAGER_CONFIGURE_WIRING.
- [ ] **VALIDATE**: `xcodebuild ... build`; full functional check in Manual Validation.
- [ ] **COMMIT**: `feat(recorder): start mount monitor at app launch`

---

## Testing Strategy

### Unit Tests
| Test | Input | Expected Output | Edge Case? |
|---|---|---|---|
| `testContentFingerprintIsStableSHA256` | known bytes file | fixed sha256 hex | no |
| `testIsImportedReflectsRecord` | empty ctx → record → query | false → true | no |
| `testVolumeNameMatchIsCaseInsensitiveContains` | various volume names | case-insensitive contains | yes |
| `testCodableRoundTrip` | RecorderDevice | equal after encode/decode | no |
| `testScanReturnsOnlyNewSupportedFiles` | temp dir w/ wav + txt | only new supported, then empty after ledger | yes (unsupported filtered, dedup) |

### Edge Cases Checklist
- [ ] Empty source folder → no notification, no enqueue
- [ ] Unsupported file types filtered (`note.txt`)
- [ ] Re-mount of same device → already-ledgered files skipped (AC-2)
- [ ] Device already mounted at launch → caught by `mountedVolumeURLs` sweep
- [ ] Stale/again-denied bookmark → warning notification, no crash
- [ ] `deleteAfterImport` is off by default → originals retained (AC-8); delete itself is M-later wiring, default-off path verified

---

## Validation Commands

### Static Analysis / Build
```bash
xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build
```
EXPECT: build succeeds (zero errors).

### Unit Tests
> NOTE: VoiceInkTests is a **host-app** test bundle — the test runner launches `VoiceInk.app`.
> A plain unsigned `xcodebuild test` crashes the host on launch (SwiftData `dictionary` store
> uses `.private` CloudKit → `PFCloudKitContainerProvider` `_os_crash` without an iCloud
> entitlement). Run tests with the `make local` settings (ad-hoc sign + `LOCAL_BUILD` flag, which
> sets dictionary CloudKit to `.none`, + local entitlements). Also pass
> `SWIFT_ENABLE_EXPLICIT_MODULES=NO` to dodge the Xcode 16+ "`@testable` module not compatible" bug.
```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath "$(pwd)/.local-build" \
  -xcconfig LocalBuild.xcconfig \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM="" \
  CODE_SIGN_ENTITLEMENTS="$(pwd)/VoiceInk/VoiceInk.local.entitlements" \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  -only-testing:VoiceInkTests/ImportLedgerTests \
  -only-testing:VoiceInkTests/RecorderDeviceTests \
  -only-testing:VoiceInkTests/RecorderImportServiceTests
```
EXPECT: all pass. ✅ Verified 2026-06-29 — 5/5 passing (`** TEST SUCCEEDED **`).

### Full Test Suite
```bash
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -destination 'platform=macOS'
```
EXPECT: no regressions.

### Manual Validation (functional / AC)
- [ ] **AC-1**: Configure a device (Settings → Recorders → add, pick the recorder's audio folder). Unplug, plug in → "匯入 N 個新檔" toast appears within ~3 s; items show in Transcribe Audio queue and transcribe with no click; "完成" on finish; results in History.
- [ ] **AC-2**: Re-plug the same device → already-imported files are not re-transcribed.
- [ ] **AC-3**: Confirm recorder transcriptions have **no** enhanced text (raw only) and `recorderSourceDeviceId` set (inspect History / DB).
- [ ] **AC-8**: With `deleteAfterImport` off (default), originals remain on the device after import.

---

## Acceptance Criteria
- [x] All tasks completed (Tasks 1–9 implemented)
- [x] Build succeeds; unit tests pass (5/5); no regressions
- [ ] AC-1, AC-2, AC-3, AC-8 verified manually (requires physical recorder — pending)
- [x] Recorder items skip Mode enhancement (raw transcript) — `if case .manual = item.origin` guard
- [x] Dedup is idempotent across re-mounts — sha256 ledger + in-flight set

## Completion Checklist
- [ ] Code follows discovered patterns (`@MainActor` singletons, Logger subsystem, JSON-in-UserDefaults)
- [ ] Error handling logs via `os.Logger` category `RecorderAutomation`; no silent crashes on denied access
- [ ] New files added to the correct Xcode targets (app vs VoiceInkTests) in `project.pbxproj`
- [ ] `assertSidebarItemsCoverAllCases()` still holds (all five ViewType sites updated)
- [ ] No hardcoded paths beyond the established App Support convention
- [ ] Self-contained — no questions needed during implementation

## Risks
| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| App sandbox blocks reading the device folder despite bookmark | M | H | Verify entitlements early (Task 8 GOTCHA + SRS open question); user-granted folder bookmark is the supported path |
| New files not added to Xcode targets → link/test failures | M | M | Explicit pbxproj step in Completion Checklist; build after each task |
| Failed recorder transcription stays in `inFlight`, no auto-retry until restart | M | L | Documented M1 limitation; ledger only records on success so restart re-imports |
| `assertSidebarItemsCoverAllCases()` crash if ViewType case half-wired | M | L | Task 8 GOTCHA enumerates all five edit sites |
| Volume-name match too broad/narrow | L | M | `localizedCaseInsensitiveContains`; refine to exact match in M4 if needed |

## Notes
- Mode B + balanced: pure-logic seams (`contentFingerprint`, `isImported`, `matches`, Codable
  round-trip, `newImportableFiles`) are test-first; mount/queue/UI/bootstrap are manual since the
  project has no existing test harness for those and they depend on hardware/AppKit.
- The fingerprint flows source → `QueueItemOrigin.recorderImport(deviceId:fingerprint:)` →
  `processItem` stamps it on `Transcription` → `RecorderImportService` records the ledger on
  `.transcriptionCreated`. This keeps dedup decoupled from the engine.
- M2 will add the classification call + `RecorderPostProcessor` between transcription and
  enhancement; the `origin` tag and raw-transcription bypass added here are its foundation.
