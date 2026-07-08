---
linear_issue: null
---
# Plan: 語音模式「編輯後貼上」（外部 MacVim/nvim + 自動貼回）

> Mode B。在 `.paste` 交付前插入外部編輯器 round-trip。複用 Process/ShellCommandEnvironment + 既有貼上管線。

## Summary
語音模式 `.paste` 輸出加「編輯後貼上」：聽寫結果寫暫存檔 → `mvim -f {file}`（可設 nvim/`$EDITOR`）阻塞
編輯 → `:wq` → 讀回 → 貼回原目標框（或放剪貼簿）。真 vim/vimrc，工程量小。

## User Story
As a 常講技術名詞會被聽錯的 vim 使用者, I want 聽寫後用真 vim 快速改再自動貼回, so that 不必手動 copy-paste。

## Problem → Solution
直接貼上→需回頭改 → 貼前先過外部真 vim，讀回編輯結果再貼。

## Metadata
- **Module**: voice-input
- **Parent Plan**: N/A
- **Source Feature SRS**: docs/srs/voice-input-edit-before-paste.srs.md
- **Source Module Spec**: docs/spec/voice-input.spec.md
- **Source Linear Issue**: N/A
- **Type**: feature ｜ **Size**: S ｜ **Complexity**: Small
- **Rigor**: balanced ｜ **Mode**: B ｜ **TDD**: on ｜ **Commit cadence**: per-task
- **Estimated Files**: ~6（4 modified + 1 created + tests）

---

## Mandatory Reading
| Priority | File | Lines | Why |
|---|---|---|---|
| P0 | docs/srs/voice-input-edit-before-paste.srs.md | all | 需求 + AC |
| P0 | VoiceInk/Transcription/Engine/TranscriptionDelivery.swift | 25-52, 150-168 | deliver 分派 + paste 路徑（插入點） |
| P0 | VoiceInk/Transcription/Engine/CustomCommandDeliveryRunner.swift | 52-152 | Process + ShellCommandEnvironment 阻塞執行樣式 |
| P1 | VoiceInk/Services/ShellCommandEnvironment.swift | all | login-shell env |
| P1 | VoiceInk/Modes/ModeConfig.swift | 95, 160, 208 | additive Codable 欄位（editBeforePaste） |
| P1 | VoiceInk/Modes/ModeConfigFormView.swift | outputMode section | Toggle 落點 |
| P1 | VoiceInk/Paste/ClipboardManager.swift + CursorPaster.swift | all | 貼回/剪貼簿 |

## Patterns to Mirror
### BLOCKING_PROCESS（阻塞跑命令 + env）
```swift
// SOURCE: CustomCommandDeliveryRunner.swift:83-89, 102-135
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/zsh")
process.arguments = ["-lc", command]
process.environment = ShellCommandEnvironment.commandEnvironment(additionalEnvironment: [:])
let semaphore = DispatchSemaphore(value: 0)
process.terminationHandler = { _ in semaphore.signal() }
try process.run()
_ = semaphore.wait(timeout: <long/none>)   // 編輯是人操作，等進程結束（不設短逾時）
guard process.terminationStatus == 0 else { throw … }
```
### OUTPUT_DISPATCH（插入點）
```swift
// SOURCE: TranscriptionDelivery.swift:47-51 — 一般貼上路徑
if let text = request.text { await paste(text, output: request.output, actions: actions) }
// 改：若 output.editBeforePaste → 先 review 得 edited，再 paste(edited,…) 或 clipboard
```
### ADDITIVE_MODE_FIELD
```swift
// SOURCE: ModeConfig.swift:160 — selectedPrompt decodeIfPresent
// editBeforePaste = try container.decodeIfPresent(Bool.self, forKey: .editBeforePaste) ?? false
```
### PASTE / CLIPBOARD
```swift
// SOURCE: TranscriptionDelivery.paste:157（CursorPaster.startPasteAtCursor）;ClipboardManager 寫剪貼簿
```

## Files to Change
| File | Action | Justification |
|---|---|---|
| VoiceInk/Transcription/Engine/ExternalEditorReviewRunner.swift | CREATE | 暫存檔 + 阻塞編輯 + 讀回 |
| VoiceInk/Transcription/Engine/TranscriptionDelivery.swift | UPDATE | `.paste` + editBeforePaste 前置 round-trip |
| VoiceInk/Modes/ModeConfig.swift | UPDATE | editBeforePaste 欄位 |
| VoiceInk/Modes/ModeConfigFormView.swift | UPDATE | `.paste` 下 Toggle |
| VoiceInk/Views/Settings/（合適設定頁） | UPDATE | 編輯器命令 + 貼回目標全域設定 |
| VoiceInkTests/ExternalEditorReviewRunnerTests.swift | CREATE | round-trip / 失敗 |

## NOT Building
- 內嵌 vim GUI;詞典;錄音/會議路徑;respond/customCommand。

## Step-by-Step Tasks

### Task 1: `ExternalEditorReviewRunner`
- **ACTION**: 寫檔→阻塞跑編輯器命令（`{file}` 替換）→讀回→清暫存。
- **TEST FIRST**（`ExternalEditorReviewRunnerTests`，用非互動假編輯器命令）:
  ```swift
  func testRoundTripsFileContent() async throws {
      // 命令 `sh -c 'printf "EDITED" > {file}'` 模擬編輯 → 回傳 "EDITED"
      let out = try await ExternalEditorReviewRunner.review(text: "original", command: #"sh -c 'printf EDITED > {file}'"#)
      XCTAssertEqual(out, "EDITED")
  }
  func testNonZeroExitThrows() async {
      // 命令 `sh -c 'exit 3'` → throw
      await XCTAssertThrowsErrorAsync(try await ExternalEditorReviewRunner.review(text: "x", command: "sh -c 'exit 3'"))
  }
  ```
  Run: `xcodebuild test … -only-testing:VoiceInkTests/ExternalEditorReviewRunnerTests` — FAIL
- **IMPLEMENT**（鏡射 BLOCKING_PROCESS）:
  ```swift
  enum ExternalEditorReviewError: Error, LocalizedError { case launchFailed(String); case nonZeroExit(Int32) ; … }
  enum ExternalEditorReviewRunner {
      /// 寫 text 進暫存 .md → 跑 command（{file}→路徑）阻塞 → 讀回內容。清暫存 defer。
      static func review(text: String, command: String) async throws -> String {
          let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
              .appendingPathComponent("com.prakashjoshipax.VoiceInk").appendingPathComponent("VoiceInkEdit")
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          let file = dir.appendingPathComponent("\(UUID().uuidString).md")
          try text.data(using: .utf8)?.write(to: file)
          defer { try? FileManager.default.removeItem(at: file) }
          let resolved = command.replacingOccurrences(of: "{file}", with: "'\(file.path)'")
          try await runBlocking(resolved)   // Process /bin/zsh -lc；等進程結束（無短逾時）
          return (try? String(contentsOf: file, encoding: .utf8)) ?? text
      }
      // runBlocking: 鏡射 CustomCommandDeliveryRunner.execute 的 Process+semaphore（去掉 stdin/timeout；
      // 非零 exit throw）
  }
  ```
  **GOTCHA**: 命令替換用單引號包路徑防空格;`review` 回傳讀回內容（含使用者所有修改）。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(voice-input): external editor review runner`

### Task 2: ModeConfig.editBeforePaste
- **ACTION**: additive 欄位。
- **TEST FIRST**:
  ```swift
  func testModeConfigEditBeforePasteDefaultsFalse() throws {
      // 舊 JSON（無此鍵）decode → false
  }
  ```
  Run — FAIL
- **IMPLEMENT**: `var editBeforePaste: Bool`;CodingKeys 加;`init(from:)` decodeIfPresent ?? false;encode;memberwise init 參數預設 false。
- **VALIDATE**: 測試 PASS。
- **COMMIT**: `feat(voice-input): editBeforePaste mode field`

### Task 3: 交付路徑接線
- **ACTION**: `TranscriptionDelivery` `.paste` 且 editBeforePaste → 先 review 再貼/剪貼。
- **TEST FIRST**: 交付流程含 UI/貼上難純測——以手動 AC-1 為主;可測 `OutputRuntimeConfiguration` 是否帶 editBeforePaste（若該 struct 需加欄位）。
- **IMPLEMENT**:
  - `OutputRuntimeConfiguration` 加 `editBeforePaste: Bool` + `editCommand: String` + `editTarget: String`（從 Mode + 全域設定組出;讀 `ModeRuntimeConfiguration` 組裝處）。
  - `deliver`（:47-51）改：
    ```swift
    if let text = request.text {
        if request.output.editBeforePaste {
            SoundManager.shared.playStopSound(); await actions.dismiss()
            Task { @MainActor in
                do {
                    let edited = try await ExternalEditorReviewRunner.review(text: deliverableText(from: text), command: request.output.editCommand)
                    if request.output.editTarget == "clipboard" {
                        ClipboardManager.copyToClipboard(edited)   // 確認 API 名
                        NotificationManager.shared.showNotification(title: "已複製編輯結果到剪貼簿", type: .success, duration: 3)
                    } else {
                        try? await Task.sleep(nanoseconds: 400_000_000)   // 等焦點還原
                        _ = await CursorPaster.startPasteAtCursor(edited).value
                    }
                } catch {
                    NotificationManager.shared.showNotification(title: "編輯器失敗：\(error.localizedDescription)", type: .error, duration: 6)
                }
            }
        } else {
            await paste(text, output: request.output, actions: actions)
        }
    } else { await actions.dismiss() }
    ```
  - **GOTCHA**: 確認 `ClipboardManager` 複製 API 與 `CursorPaster.startPasteAtCursor` 回傳型別（讀該檔）。焦點還原延遲 0.4s（Open Question，可調）。
- **VALIDATE**: build 綠;手動 AC-1/AC-2/AC-3。
- **COMMIT**: `feat(voice-input): route paste through external editor when enabled`

### Task 4: 設定 UI
- **ACTION**: Mode 編輯 `.paste` 下加「編輯後貼上」Toggle;全域設定加編輯器命令（預設 `mvim -f {file}`）與貼回目標（paste/clipboard）。
- **TEST FIRST**: N/A（UI）。
- **IMPLEMENT**: `ModeConfigFormView` outputMode 為 `.paste` 時顯示 Toggle 綁 `editBeforePaste`;設定頁（合適處）加 TextField（命令）+ Picker（貼回目標），存 UserDefaults `editBeforePasteCommand`/`editBeforePasteTarget`。文案說明 nvim 需可阻塞的終端命令、預設 mvim -f。
- **VALIDATE**: build 綠;手動設定持久。
- **COMMIT**: `feat(voice-input): settings — editor command + paste target`

### Task 5: 收尾
- **ACTION**: build+test;voice-input.spec Change History 加 implemented;bump build;`make deploy`;回報;plan/SRS 移 completed。
- **COMMIT**: `chore(voice-input): bump build, docs, deploy`

## Testing Strategy
| Test | Input | Expected | Edge |
|---|---|---|---|
| RoundTrip | 假編輯命令改檔 | 讀回改後內容 | 空檔 |
| NonZeroExit | exit 3 | throw | launch fail |
| ModeFieldDefault | 舊 JSON | false | — |

### Edge Cases Checklist
- [ ] 編輯器非零離開/找不到命令 → 通知、不貼、retry-last 可用
- [ ] 焦點未還原 → clipboard 模式退路
- [ ] 檔名含空格 → 單引號包路徑
- [ ] 未開 Toggle → 原貼上零回歸

## Validation Commands
```bash
make local
xcodebuild test … -only-testing:VoiceInkTests
make deploy
```
### Manual Validation
- [ ] AC-1：開 Toggle、mvim -f {file} → 聽寫 → MacVim 開啟 → 改 → :wq → 貼回原框
- [ ] AC-2：命令失敗 → 通知、不貼
- [ ] AC-3：clipboard 模式 → 放剪貼簿 + 通知
- [ ] AC-4：未開 Toggle 的 Mode 零回歸

## Acceptance Criteria
- [ ] SRS AC-1〜AC-4;既有交付零回歸

## Risks
| Risk | L | I | Mitigation |
|---|---|---|---|
| 焦點還原不穩 | M | M | 延遲;clipboard 退路 |
| nvim 無終端不阻塞 | M | M | 預設 mvim -f;文案說明 |
| ClipboardManager/CursorPaster API 名不符 | M | L | Task 3 前讀該檔確認 |

## Notes
- 這是獨立小功能;與 v2 四份 plan 無耦合，可任何時間插入。使用者要求：先產文件（本 plan），實作排在 v2 四份之後（或視情況）。
