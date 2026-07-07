---
linear_issue: null
---
# Plan: iCloud Recorder Sources（Just Press Record / Voice Memos 自動匯入）

> **For agentic workers:** `/prp-implement` routes by `Metadata.Type`. Mode B（任務先測）：每個 task 先寫一個鎖行為的測試；iCloud 同步/權限等真機行為以手動 AC＋Linear 驗證清單收尾。
> **前置依賴**：`feat/meeting-capture` 分支的 `RecorderPostProcessor.process(fixedCategory:)` 縫合點（本 plan Task 6 直接複用）。實作本 plan 前先確認該分支已合回 main 或 rebase 其上。

## Summary
讓手錶/iPhone 錄音（Just Press Record 的 iCloud Drive 容器、Voice Memos 的本地群組容器）成為 recorder 來源：`RecorderDevice` 加四個 additive 欄位（不加 Kind case）、遞迴掃描、dataless 佔位檔「觸發下載→deferred→重掃」、`NSMetadataQuery` 監看 iCloud Drive、強制不刪原始檔、per-device 預設分類（跳過分類器）、路徑/建立日期回收錄音時間、設定頁預設集按鈕。

## User Story
As a 隨身用手錶/iPhone 錄想法的使用者, I want 回到 Mac 後錄音自動出現在 Obsidian 對應分類, so that 隨身錄音不再堆積失蹤。

## Problem → Solution
掃描全平面、佔位檔被靜默跳過、vnode 看不到子資料夾、時間解析只認 `yyMMdd_HHmm` → 補齊 iCloud 語意後全走既有管線（去重/轉錄/分類/模板/匯出零改動）。

## Metadata
- **Module**: recorder-automation
- **Parent Plan**: N/A
- **Source PRD**: docs/prd/icloud-recorder-sources.prd.md
- **Source Feature SRS**: docs/srs/recorder-automation-icloud-sources.srs.md
- **Source Module Spec**: docs/spec/recorder-automation.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature ｜ **Size**: M ｜ **Complexity**: Medium
- **Rigor**: balanced ｜ **Mode**: B — 任務先測 ｜ **TDD**: on（task-level）｜ **Commit cadence**: per-task
- **Estimated Files**: ~10（7 modified + 1 created + tests）

---

## Mandatory Reading

| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | `docs/srs/recorder-automation-icloud-sources.srs.md` | all | 需求＋AC＋已驗證的程式碼缺口清單 |
| P0 | `docs/spec/recorder-automation.spec.md` | Key Decisions＋iCloud 相關 delta | 地雷與 watcher 分工決策 |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderImportService.swift` | 36-137（掃描/匯入）、215-224（finalizeImport）、365-382（copy） | 五個平面掃描點、stability gate、delete-after-import 鏈 |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderDevice.swift` | all（53 行） | decodeIfPresent back-compat 樣式（本 plan 的欄位就加在這） |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderFolderWatcher.swift` | all（91 行） | vnode watcher；sync() 要跳過 iCloud 來源 |
| P1 | `VoiceInk/Services/RecorderAutomation/ImportLedger.swift` + `Models/ImportLedgerEntry.swift` | 指紋串流 :18-28；`#Index` :8 | relativePath 欄位落點；record() 簽名 |
| P1 | `VoiceInk/Services/RecorderAutomation/RecorderRecordingTime.swift` | all（regex :23-26） | 時間解析鏈擴充目標 |
| P1 | `VoiceInk/Views/Settings/RecordersSettingsView.swift` | 471-596（editor panel；chooseSourceFolder :562-580；canSave :513-517；類型 Picker :525-531） | 預設集按鈕與欄位落點 |
| P2 | `VoiceInk/Services/AudioFileTranscriptionManager.swift` | 286-307 | `.recorderImport` 後處理呼叫（Task 6 在此帶 fixedCategory） |
| P2 | `VoiceInkTests/RecorderDeviceTests.swift`、`RecorderImportServiceTests.swift` | all | 測試樣式（真 UserDefaults 還原、in-memory container、tmp 資料夾） |
| P2 | 記憶檔 `voiceink-running-unit-tests` 等三則 | — | 測試/建置/部署鐵律 |

## External Documentation

| Topic | Source | Key Takeaway |
|---|---|---|
| iCloud 佔位檔 | FileManager.startDownloadingUbiquitousItem(at:) 官方文件 | 對 dataless 檔先觸發下載；狀態用 `URLResourceKey.ubiquitousItemDownloadingStatusKey`（`.notDownloaded/.downloaded/.current`） |
| NSMetadataQuery | objc.io iCloud document store；FB9631965 | ubiquitous scope 常數只涵蓋自家容器 → **searchScopes 直接放目標資料夾 URL**；結果 callback 在主佇列、會爆量 → 只 schedule、不做工 |
| JPR 容器 | openplanet KB（自動抓取 403，需真機驗證） | 路徑形如 `~/Library/Mobile Documents/iCloud~com~openplanetsoftware~*/Documents/<YYYY-MM-DD>/<HH-MM-SS>.m4a`；格式 m4a/wav/aiff 皆可能；有三種儲存後端（使用者需開 iCloud Drive 模式） |
| Voice Memos | nono.ma／macpaw 交叉來源 | `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/*.m4a`（平面、檔名不透明）；**本地資料夾非 ubiquitous**（CloudKit 同步）→ 沿用 vnode watcher；讀取預期需完整磁碟取用權；iOS 26 可能出現 `.qta`（未證實） |

---

## Patterns to Mirror

### DEVICE_BACKCOMPAT_DECODE（additive 欄位、不加 Kind case）
```swift
// SOURCE: RecorderDevice.swift:29-39 — 舊 JSON 缺 key 時 default 進場；新增欄位照抄這條鏈
init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    ...
    kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .volume
    autoImportEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoImportEnabled) ?? true
    ...
}
// ⚠️ 不新增 Kind case：舊版解碼未知 raw value 會讓整個元素 decode 失敗（SRS 決策）
```

### FLAT_SCAN_AND_DEFER（要改造的掃描核心＋既有 defer 機制）
```swift
// SOURCE: RecorderImportService.swift:36-61 — contentsOfDirectory 平面掃描；
// stability gate（:53-55）與 deferredCount→scheduleRecheck（:106）是佔位檔處理要搭的既有便車
let urls = (try? FileManager.default.contentsOfDirectory(
    at: folder, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
    options: [.skipsHiddenFiles])) ?? []
...
if minimumStableAge > 0, let mod = rv?.contentModificationDate, now.timeIntervalSince(mod) < minimumStableAge {
    deferred += 1; continue
}
guard let fp = try? await Self.fingerprintOffMain(url) else { continue }   // ← dataless 檔今天在這被靜默吃掉
```

### VNODE_WATCHER（保留給 VM；iCloud 走新 watcher）
```swift
// SOURCE: RecorderFolderWatcher.swift:37-41 — sync() 的裝置篩選；iCloud 來源要在此排除
for device in RecorderConfigStore.shared.devices
where device.kind == .folder && device.autoImportEnabled {
    startWatching(device)
}
```

### DELETE_GATE（keep-originals 強制點）
```swift
// SOURCE: RecorderImportService.swift:215-224 — 刪原檔唯一路徑；iCloud 來源在上游就不記 originalURLs
func finalizeImport(fingerprint: String, device: RecorderDevice, exported: Bool) {
    defer { originalURLs[fingerprint] = nil }
    guard device.deleteAfterImport, exported, let original = originalURLs[fingerprint] else { return }
    try FileManager.default.removeItem(at: original)
}
```

### FIXED_CATEGORY_SEAM（meeting 已落地，直接複用）
```swift
// SOURCE: RecorderPostProcessor.process — feat/meeting-capture 分支已加：
// func process(transcription:rawText:device:fixedCategory: RecorderCategory? = nil, modelContext:enhancementService:aiService:)
// fixedCategory != nil → assignCategory（設欄位＋標題，不呼叫分類器）
```

### TEST_STRUCTURE
```swift
// SOURCE: VoiceInkTests/RecorderImportServiceTests.swift:16-25 — tmp 資料夾 + in-memory ledger container
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rec-\(UUID())")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let ctx = try ModelContext(ModelContainer(for: ImportLedgerEntry.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
```

---

## Files to Change

| File | Action | Justification |
|---|---|---|
| `VoiceInk/Services/RecorderAutomation/RecorderDevice.swift` | UPDATE | `recursive`/`isICloudSource`/`presetKind`/`defaultCategoryId` 欄位＋decode 預設 |
| `VoiceInk/Services/RecorderAutomation/RecorderImportService.swift` | UPDATE | 遞迴掃描、佔位檔下載、relativePath 傳遞、keep-originals |
| `VoiceInk/Models/ImportLedgerEntry.swift` + `ImportLedger.swift` | UPDATE | `relativePath: String?` 欄位＋record() 參數＋查詢 helper |
| `VoiceInk/Services/RecorderAutomation/RecorderFolderWatcher.swift` | UPDATE | sync() 排除 iCloud 來源 |
| `VoiceInk/Services/RecorderAutomation/ICloudSourceWatcher.swift` | CREATE | NSMetadataQuery watcher＋wake/activate rescan |
| `VoiceInk/Services/RecorderAutomation/RecorderRecordingTime.swift` | UPDATE | 解析鏈：檔名 → 路徑日期資料夾 → 檔案建立日期 |
| `VoiceInk/Services/RecorderAutomation/RecorderPostProcessor.swift` | UPDATE | 兩處 recordingTime 查詢改走新解析鏈（含 relativePath/creationDate） |
| `VoiceInk/Services/AudioFileTranscriptionManager.swift` | UPDATE | `.recorderImport` 後處理帶 `fixedCategory: device.defaultCategory` |
| `VoiceInk/Views/Settings/RecordersSettingsView.swift` | UPDATE | 預設集按鈕（JPR/VM）、defaultCategory Picker、iCloud 來源隱藏 delete 開關、狀態列 |
| `VoiceInkTests/ICloudSourcesTests.swift` | CREATE | Task 1-3/5-7 的 seam 測試 |

## NOT Building
自製 iOS/watchOS app；回寫/刪除來源資料夾任何檔案；VM 內部標題資料庫讀取；非 Apple 雲；分鐘級即時性保證；`.qta` 支援（Open Question 證實後再加）。

---

## Step-by-Step Tasks

### Task 1: RecorderDevice additive 欄位
- **ACTION**: 四個欄位＋back-compat decode＋`defaultCategory` resolver。
- **TEST FIRST**（`VoiceInkTests/ICloudSourcesTests.swift`）:
  ```swift
  func testDeviceDecodesLegacyJSONWithDefaults() throws {
      // 舊版 JSON：不含新欄位
      let legacy = """
      [{"id":"\(UUID().uuidString)","displayName":"IC","volumeNameMatch":"IC RECORDER",
        "sourceFolderBookmark":"\(Data([1]).base64EncodedString())","createdAt":0}]
      """.data(using: .utf8)!
      let decoded = try JSONDecoder().decode([RecorderDevice].self, from: legacy)
      XCTAssertEqual(decoded[0].kind, .volume)
      XCTAssertFalse(decoded[0].recursive)
      XCTAssertFalse(decoded[0].isICloudSource)
      XCTAssertNil(decoded[0].presetKind)
      XCTAssertNil(decoded[0].defaultCategoryId)
  }
  ```
  （日期解碼：檢查現用 JSONDecoder 是否設 dateDecodingStrategy——RecorderConfigStore 用預設（timeIntervalSinceReferenceDate double），故 `"createdAt":0` 可解；先讀 load() 確認再定 fixture。）
  Run: `xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig SWIFT_ENABLE_EXPLICIT_MODULES=NO -only-testing:VoiceInkTests/ICloudSourcesTests` — FAIL
- **IMPLEMENT**（鏡射 DEVICE_BACKCOMPAT_DECODE）:
  ```swift
  var recursive: Bool            // 遞迴掃描子資料夾（JPR 日期巢狀需要）
  var isICloudSource: Bool       // iCloud Drive 語意：佔位檔下載、metadata-query watcher、強制不刪原始檔
  var presetKind: String?        // "justPressRecord" | "voiceMemos"；nil＝自訂
  var defaultCategoryId: UUID?   // 設定時跳過分類器直接套此分類
  // init 預設 false/false/nil/nil；init(from:) 各加 decodeIfPresent ?? default
  // memberwise init 參數同樣補上（有預設值，既有呼叫點不需改）
  /// 解析預設分類；分類被刪→nil（回自動分類）
  func defaultCategory(in store: RecorderConfigStore) -> RecorderCategory? {
      defaultCategoryId.flatMap { store.category(byId: $0) }
  }
  /// 此來源是否絕不可刪原始檔（iCloud 或任何 preset 一律保護）
  var protectsOriginals: Bool { isICloudSource || presetKind != nil }
  ```
- **VALIDATE**: 測試 PASS＋既有 `RecorderDeviceTests` 綠。
- **COMMIT**: `feat(icloud): additive RecorderDevice fields with legacy-safe decode`

### Task 2: 遞迴掃描＋relativePath 進 ledger
- **ACTION**: `newImportableFiles` 支援 enumerator 遞迴（`device.recursive` 控制——簽名加 `recursive: Bool = false` 由呼叫端傳 device 值）；`ImportCandidate` 加 `relativePath: String`；ledger 存起來供時間解析。
- **TEST FIRST**:
  ```swift
  func testRecursiveScanFindsNestedFilesWithRelativePath() async throws {
      // tmp/2026-07-06/14-30-22.m4a → candidates 含之，relativePath == "2026-07-06/14-30-22.m4a"
      // recursive=false 時同一結構回傳空
  }
  ```
  （fixture 照 TEST_STRUCTURE；斷言兩種模式。）— FAIL
- **IMPLEMENT**:
  - 掃描：`recursive ? FileManager.default.enumerator(at:includingPropertiesForKeys:options:[.skipsHiddenFiles])` 收集檔案 URL（跳過目錄），else 現行 contentsOfDirectory。共用後續過濾迴圈。
  - `ImportCandidate` 加 `let relativePath: String`（`url.path.replacingOccurrences(of: folder.path + "/", with: "")`；平面掃描時＝lastPathComponent）。
  - `ImportLedgerEntry` 加 `var relativePath: String?`（additive，輕遷移）；`ImportLedger.record(...)` 加參數 `relativePath: String? = nil` 並寫入；`RecorderImportService.pendingMeta` value 擴成 `(fileName: String, byteSize: Int, relativePath: String?)`，`onTranscriptionCreated`（:384-394）傳給 record。新增查詢 `ImportLedger.relativePath(forFingerprint:in:)`（比照既有 `fileName(forFingerprint:)`——先讀該檔確認名稱）。
  - `importNewFiles`/`reprocess`/`deviceFiles` 掃描呼叫帶 `recursive: device.recursive`（cleanup 系列 v1 維持平面——註記）。
- **GOTCHA**: enumerator 的 `.skipsHiddenFiles` 仍會走進 `.Trash` 類目錄嗎？JPR 容器無此問題；仍加 `where !url.hasDirectoryPath` 過濾。
- **VALIDATE**: 新測試 PASS＋`RecorderImportServiceTests` 綠（平面路徑行為不變）。
- **COMMIT**: `feat(icloud): recursive scan + relative path through the ledger`

### Task 3: dataless 佔位檔 → 下載＋defer（不再靜默跳過）
- **ACTION**: iCloud 來源掃描時讀 ubiquity 鍵；未下載 → 計入 deferred＋批次觸發下載（off-main、非 callback 內），靠既有 `scheduleRecheck` 迴圈等材料化後匯入。
- **TEST FIRST**（純 seam——抽決策函式再測）:
  ```swift
  func testUbiquityGateDefersNotDownloaded() {
      // RecorderImportService.ubiquityAction(for: status) 純函式：
      XCTAssertEqual(RecorderImportService.ubiquityAction(for: .notDownloaded), .deferAndDownload)
      XCTAssertEqual(RecorderImportService.ubiquityAction(for: .current), .proceed)
      XCTAssertEqual(RecorderImportService.ubiquityAction(for: nil), .proceed)   // 非 iCloud 檔
  }
  ```
  — FAIL
- **IMPLEMENT**:
  ```swift
  enum UbiquityAction: Equatable { case proceed, deferAndDownload }
  nonisolated static func ubiquityAction(for status: URLUbiquitousItemDownloadingStatus?) -> UbiquityAction {
      guard let status else { return .proceed }
      return status == .current || status == .downloaded ? .proceed : .deferAndDownload
  }
  ```
  掃描迴圈（isICloudSource 時）：prefetch keys 加 `.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey`；`case .deferAndDownload: deferred += 1; pendingDownloads.append(url); continue` 置於 fingerprint 之前。迴圈後：
  ```swift
  if !pendingDownloads.isEmpty {
      let urls = pendingDownloads
      Task.detached(priority: .utility) {   // 批次觸發、絕不在 metadata callback / main 上做
          for u in urls { try? FileManager.default.startDownloadingUbiquitousItem(at: u) }
      }
  }
  ```
  呼叫端已有 `deferred > 0 → scheduleRecheck`（:106）——iCloud 來源的 recheck 也要會觸發：Task 4 的 watcher 提供同名 `scheduleRecheck`。
- **VALIDATE**: seam 測試 PASS；真機 AC-2 留 Linear 清單。
- **COMMIT**: `feat(icloud): download-then-import for dataless placeholders`

### Task 4: `ICloudSourceWatcher`＋vnode 分工
- **ACTION**: 新 watcher（NSMetadataQuery per iCloud 來源）＋`RecorderFolderWatcher.sync()` 排除 `isICloudSource`＋wake/activate rescan。
- **TEST FIRST**: N/A（AppKit/Spotlight 整合——手動 AC；debounce 純邏輯若抽出可測則補）。
- **IMPLEMENT**（新檔 `ICloudSourceWatcher.swift`，結構鏡射 `RecorderFolderWatcher`：@MainActor singleton、start()/sync()/scheduleRecheck(deviceId:)、debounce dict）:
  - per-device：`NSMetadataQuery()`；`query.searchScopes = [folderURL]`（resolve bookmark）；`query.predicate = NSPredicate(format: "%K LIKE '*.*'", NSMetadataItemFSNameKey)`（寬鬆——副檔名過濾交給既有 SupportedMedia）；監聽 `.NSMetadataQueryDidFinishGathering` 與 `.NSMetadataQueryDidUpdate` → **只做** `scheduleImport(deviceId:)`（debounce 2s，鏡射 vnode watcher :78-83）→ `RecorderImportService.shared.importNewFiles(device:)`。
  - `RecorderFolderWatcher.sync()` 條件改：`where device.kind == .folder && device.autoImportEnabled && !device.isICloudSource`。
  - rescan 觸發：`NSWorkspace.didWakeNotification` ＋ `NSApplication.didBecomeActiveNotification` → 對所有啟用的 iCloud 來源 `scheduleImport`。
  - `VoiceInk.swift` 啟動處（緊鄰 `RecorderFolderWatcher.shared.start()`——grep 找到該行）加 `ICloudSourceWatcher.shared.start()`；`RecordersSettingsView.save()` 後的 sync 呼叫點同步呼叫兩個 watcher 的 sync()（先 grep `RecorderFolderWatcher.shared.sync` 找齊呼叫點）。
- **GOTCHA**: metadata callback 在主佇列且會爆量——callback 內除 debounce 排程外零工作；`query.start()` 必須主執行緒。
- **VALIDATE**: build 綠；手動：JPR 資料夾丟檔（含子資料夾）→ 自動匯入。
- **COMMIT**: `feat(icloud): NSMetadataQuery watcher for iCloud Drive sources`

### Task 5: keep-originals 強制
- **ACTION**: `protectsOriginals` 的來源絕不進 delete 鏈；UI 端同步隱藏開關（Task 8）。
- **TEST FIRST**:
  ```swift
  func testProtectedSourceNeverRecordsOriginalURL() {
      // 構造 isICloudSource=true 且 deleteAfterImport=true 的 device（惡意 JSON 情境）
      // 斷言 protectsOriginals == true；並以 finalizeImport 直接呼叫驗證原檔仍存在
  }
  ```
  — FAIL
- **IMPLEMENT**: `importNewFiles` 記 `originalURLs[c.fingerprint] = c.url` 處（:125）改成 `if !device.protectsOriginals { originalURLs[...] = ... }`；`finalizeImport` guard 再加 `!device.protectsOriginals`（雙保險）。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(icloud): originals in preset/iCloud sources are untouchable`

### Task 6: per-device 預設分類（複用 fixedCategory 縫）
- **ACTION**: ATM 的 `.recorderImport` 後處理呼叫帶 `fixedCategory: device?.defaultCategory(in: RecorderConfigStore.shared)`。
- **TEST FIRST**:
  ```swift
  func testDeviceDefaultCategoryResolves() {
      // defaultCategoryId 指向存在分類 → resolver 回傳之；指向已刪 UUID → nil
  }
  ```
  — FAIL
- **IMPLEMENT**: `AudioFileTranscriptionManager.swift` `.recorderImport` 後處理 block（:286-293 一帶，meeting 分支旁）：
  ```swift
  let device = RecorderConfigStore.shared.device(byId: deviceId)
  await RecorderPostProcessor.shared.process(
      transcription: transcription, rawText: cleanedText, device: device,
      fixedCategory: device?.defaultCategory(in: RecorderConfigStore.shared),
      modelContext: modelContext, enhancementService: enhancementService, aiService: aiService)
  ```
  （nil → 走原 suggestCategory，行為不變。）
- **VALIDATE**: 測試 PASS＋既有 pipeline 測試綠。
- **COMMIT**: `feat(icloud): per-source default category skips the classifier`

### Task 7: 錄音時間解析鏈
- **ACTION**: `RecorderRecordingTime.parse` 擴充：現行檔名 regex → 路徑日期資料夾＋`HH-mm-ss` 檔名（JPR）→ 檔案建立日期（VM 不透明檔名）→ nil；PostProcessor 兩處查詢（suggestCategory :185-188、recordingDate :311-316）改傳 relativePath＋creationDate。
- **TEST FIRST**:
  ```swift
  func testParsesJPRPathDates() {
      let d = RecorderRecordingTime.parse(fileName: "14-30-22.m4a",
                                          relativePath: "2026-07-06/14-30-22.m4a",
                                          fileCreationDate: nil)
      // 斷言 == 2026-07-06 14:30:22（本地時區——與既有 parse 的時區慣例一致，先讀現行實作確認用 Calendar.current）
  }
  func testFallsBackToCreationDate() { /* relativePath 無日期、檔名不匹配 → 回 creationDate */ }
  func testLegacyFileNameStillWins() { /* "250701_1258.mp3" 優先於 relativePath */ }
  ```
  — FAIL
- **IMPLEMENT**: 新 API `static func parse(fileName: String, relativePath: String?, fileCreationDate: Date?) -> Date?`，內部先呼叫既有 `parse(fromFileName:)`（保留、勿改），再嘗試 `(\d{4})-(\d{2})-(\d{2})` 路徑段＋`(\d{2})-(\d{2})-(\d{2})` 檔名段組合，最後回 creationDate。PostProcessor 端：relativePath 從新 ledger helper 取，creationDate 從 `transcription.audioFileURL` 的檔案屬性取（`.creationDateKey`；檔案可能已被清理→nil 安全）。
- **VALIDATE**: 三測試 PASS。
- **COMMIT**: `feat(icloud): recording-time recovery from path dates and creation date`

### Task 8: 預設集 UI（RecordersSettingsView）
- **ACTION**: editor panel 的 類型 Section（:525-531）下加「快速設定」列：〔Just Press Record〕〔Voice Memos〕按鈕；per-device 預設分類 Picker；`protectsOriginals` 時隱藏 deleteAfterImport Toggle 並顯示鎖定說明；來源卡片顯示 presetKind 標籤。
- **TEST FIRST**: N/A（SwiftUI 宣告）——VALIDATE 手動。
- **IMPLEMENT**:
  - JPR 按鈕：glob `~/Library/Mobile Documents/` 下 `iCloud~com~openplanetsoftware~*` 目錄（`FileManager.contentsOfDirectory` + prefix 過濾）→ 命中：取其 `Documents` 子資料夾，`try? url.bookmarkData(options: [.withSecurityScope])` 直建 bookmark（非 sandbox 可行；失敗則 fallback `chooseSourceFolder()` 並提示手動選取），預填 `displayName="Just Press Record", kind=.folder, recursive=true, isICloudSource=true, presetKind="justPressRecord"`；未命中 → alert「找不到 JPR iCloud 容器——確認 app 已裝且使用 iCloud Drive 儲存」＋open panel fallback。
  - VM 按鈕：固定路徑 `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings`；readability probe（`FileManager.isReadableFile` ＋實際 `contentsOfDirectory` try）；不可讀 → 顯示完整磁碟取用引導（`NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)`——anchor 實測，fallback Privacy 根頁）＋重試按鈕；可讀 → 預填 `recursive=false, isICloudSource=false, presetKind="voiceMemos"`。
  - 預設分類 Picker：比照 RecorderModeSettingsView 會議 Section 的 `Binding<UUID?>` 寫法（tag `UUID?.none`＝自動分類）。
  - editor `@State` 增補新欄位並在 save() 傳入 RecorderDevice（Task 1 的 memberwise init 已有預設值參數）。
- **VALIDATE**: build 綠；手動：兩顆按鈕行為、欄位持久化、delete 開關隱藏。
- **COMMIT**: `feat(icloud): preset source buttons + per-source category picker`

### Task 9: 收尾
- **ACTION**: 全套 Validation Commands → `docs/spec/recorder-automation.spec.md` Change History 加 implemented 行 → bump `CURRENT_PROJECT_VERSION`（兩處）→ `make deploy` → 回報 build 號 → Linear voiceink 專案開驗證 issue（做了什麼＋下方 Manual Validation 逐條 checkbox）→ plan/SRS 移 completed/。
- **VALIDATE**: Settings→About 新 build 號；issue 連結回報。
- **COMMIT**: `chore(icloud): bump build, docs, deploy`

---

## Testing Strategy

| Test | Input | Expected | Edge |
|---|---|---|---|
| LegacyDeviceDecode | 舊 JSON | 新欄位全 default | 缺 key |
| RecursiveScan | 巢狀 fixture | 找到＋relativePath 正確；off 時空 | 深層/隱藏檔 |
| UbiquityGate | 三種 status | proceed/defer 正確 | nil（本地檔） |
| ProtectedOriginals | 惡意 delete=true | 原檔存活 | 雙保險兩層 |
| DefaultCategoryResolve | 存在/已刪 UUID | 分類/nil | — |
| TimeChain ×3 | 檔名/路徑/建立日 | 優先序正確 | 時區 |

### Edge Cases Checklist
- [ ] JPR 容器不存在（未裝/未開 iCloud Drive）→ 引導文案
- [ ] VM 無完整磁碟取用 → 引導＋重試
- [ ] 掃描中 iCloud 正在下載（.downloading）→ defer 不重複觸發下載風暴
- [ ] 同檔重新下載/eviction 循環 → ledger 指紋去重（AC-6）
- [ ] 來源資料夾被整個移除 → watcher 不 crash、狀態列顯示
- [ ] `.qta` 檔出現 → SupportedMedia 不認 → 被跳過（記 log），Open Question 追蹤

## Validation Commands
```bash
make local
xcodebuild test -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
  -derivedDataPath .local-build -xcconfig LocalBuild.xcconfig \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO -only-testing:VoiceInkTests
make deploy   # 手動驗證前
```

### Manual Validation（→ Linear 驗證 issue）
- [ ] AC-1：JPR 巢狀新檔 → 匯入一次、筆記時間＝路徑時間
- [ ] AC-2：Finder「移除下載項目」後掃描 → 觸發下載 → 材料化後自動匯入
- [ ] AC-3：preset 來源原始檔永不被刪
- [ ] AC-4：預設分類來源 → request log 零分類呼叫
- [ ] AC-5：舊來源設定升級後行為不變
- [ ] AC-6：重複同步事件 → 單一 Transcription
- [ ] Open Questions 實測：JPR 容器實名（`ls ~/Library/Mobile\ Documents/ | grep -i openplanet`）、VM FDA 需求與 Tahoe 路徑、VM 需否開過 app 才同步

## Acceptance Criteria
- [ ] SRS AC-1〜AC-6 全過；全部 Validation Commands 綠；零回歸

## Risks
| Risk | L | I | Mitigation |
|---|---|---|---|
| JPR 容器名與 glob 不符 | M | M | 真機驗證後改 glob；open panel fallback 永遠可用 |
| VM 群組容器 FDA 拒絕 | M | M | probe＋引導 UI；不影響 JPR 路徑 |
| NSMetadataQuery 對該容器不出事件 | M | M | wake/activate rescan＋手動「立即掃描」兜底 |
| 下載風暴佔用主執行緒 | L | M | 批次 detached 觸發；callback 零工作 |

## Notes
- cleanup/deviceFiles 系列的遞迴化 v1 只做 `deviceFiles`（狀態列需要）；cleanup 掃描維持平面並在 UI 註明不適用 iCloud 來源。
- 依賴 meeting 分支的 `process(fixedCategory:)`——若該分支尚未合併，Task 6 前先 cherry-pick 或 rebase。
