---
linear_issue: null
---
# SRS: 語音模式「編輯後貼上」（外部 MacVim/nvim + 自動貼回）

## Metadata
- **Module**: `voice-input`
- **Module Spec**: `docs/spec/voice-input.spec.md`
- **Source PRD**: N/A（2026-07-08 使用者需求，方案 A 已定）
- **Source Linear Issue**: N/A
- **Created**: 2026-07-08
- **Grill level**: 1 (standard)

## Feature Summary

在語音模式的貼上路徑前插入一個**編輯步驟**:聽寫（含 AI 改寫）完成後，把結果寫進暫存檔並用
**外部編輯器（預設 MacVim `mvim -f`，可設 nvim/`$EDITOR`）**阻塞開啟，使用者用**真 vim + 自己的
vimrc/plugin** 快速修改技術/專有名詞，`:wq` 後 app 讀回編輯結果並貼進原目標輸入框（或放剪貼簿）。

## Delta from Current Module State

> `voice-input` 為新模組（本 SRS 建立其 Module Spec，逆向自現有 Modes/TranscriptionDelivery）。

### New / Changed Data Models

- **CHANGED** `ModeConfig` 新增 additive 欄位 `editBeforePaste: Bool`（decodeIfPresent ?? false）——
  該 Mode 的貼上路徑是否先過外部編輯器。
- **設定（UserDefaults 全域）**:
  - `editBeforePasteCommand: String`（預設 `"mvim -f {file}"`;`{file}` 佔位符替換為暫存檔路徑）。
  - `editBeforePasteTarget: String`（`"paste"` | `"clipboard"`;預設 `"paste"`——編輯後自動貼回;
    `"clipboard"`——只放剪貼簿由使用者手動 Cmd+V）。

### Changed Business Logic

- `TranscriptionDelivery.deliver`:當 `outputMode == .paste`（一般貼上路徑）且該 Mode `editBeforePaste`
  為真時，**先跑編輯器 round-trip**，用回傳的編輯後文字取代原文，再走既有 `paste`（或改放剪貼簿）。
- 新 `ExternalEditorReviewRunner`:寫暫存檔 → 以 login-shell 執行編輯器命令（阻塞）→ 讀回 → 清暫存。
  命令執行複用 `ShellCommandEnvironment`（取得 PATH，讓 `mvim`/`nvim` 找得到）。
- **焦點還原**:外部 GUI 編輯器關閉後 macOS 通常把焦點還給前一個 app（原目標框）;貼回前加小延遲
  等焦點還原，再 `CursorPaster.startPasteAtCursor`。`clipboard` 模式則只 `ClipboardManager` 寫入 + 通知。
- Mode 編輯 UI（`ModeConfigFormView`）在 `.paste` 輸出時多一個「編輯後貼上」Toggle;全域設定放
  編輯器命令與貼回目標。

### Explicitly Out of Scope

- 內嵌 vim GUI（方案 D）;詞典/詞彙表功能（使用者已明確不做）;錄音輸入/會議路徑（此功能限語音模式貼上）。
- `respond`/`customCommand` 輸出模式不套用（它們不是貼上路徑）。

## Functional Requirements

- [ ] **FR-1** `ModeConfig.editBeforePaste` additive、向後相容（舊資料 false）。
- [ ] **FR-2** `.paste` 輸出且 `editBeforePaste` 為真:聽寫結果先進外部編輯器，`:wq` 後才貼。
- [ ] **FR-3** 編輯器命令可設（`{file}` 佔位符）;預設 `mvim -f {file}`;以 login-shell 執行取得 PATH。
- [ ] **FR-4** 編輯器阻塞執行;非零離開碼或逾時 → 通知 + 不貼（保留原文可 retry-last）。
- [ ] **FR-5** 貼回目標可設:`paste`（自動貼回原框，含焦點還原延遲）或 `clipboard`（放剪貼簿 + 通知）。
- [ ] **FR-6** 編輯器讀回的內容即為最終貼上文字（含使用者所有修改）。
- [ ] **FR-7** 既有 `.paste`（未開此 Toggle）、`.respond`、`.customCommand` 行為零回歸。

## Non-Functional Requirements

| Category | Target | How Achieved |
|---|---|---|
| 保真度 | 100% 真 vim/vimrc/plugin | 跑外部真 vim 進程，非模擬 |
| 相容性 | 舊 Mode 零回歸 | additive 欄位、預設關 |
| 韌性 | 編輯器失敗不遺失聽寫 | 失敗不貼、原文留存可 retry |

## Architecture Notes

- **為何外部而非內嵌**:吃使用者真 vimrc/plugin 只能跑真 vim;內嵌真 nvim＝Neovim GUI 級工程，
  性價比極差（使用者決策 A）。外部 `mvim -f` 阻塞 + 自動讀回把 round-trip 自動化，去掉手動 copy-paste。
- **為何 `mvim -f`**:MacVim 前景（no-fork）模式阻塞到關閉、完整載入 `~/.vimrc`/`~/.gvimrc` 與 plugin
  （即 `git commit` 用的那個）。nvim 需終端機承載才能阻塞承接，故為次選（使用者可自設命令）。
- **焦點還原是主要風險**:編輯器關閉後貼回目標框依賴 macOS 把焦點還給前一 app;不穩時退 `clipboard` 模式。

## Acceptance Criteria

### AC-1: 編輯後貼上（happy path）
- **Given**: 某語音模式 `.paste` 輸出 + 開「編輯後貼上」、命令 `mvim -f {file}`、目標 `paste`
- **When**: 聽寫一段 → MacVim 開啟該文字 → 使用者修改技術名詞 → `:wq`
- **Then**: 修改後的完整文字貼進原目標輸入框
- **Test**: 手動（Linear 驗證清單） + `ExternalEditorReviewRunnerTests::roundTripsFileContent`（用一個非互動的假編輯器命令如 `sed -i` 或 `sh -c 'echo edited > {file}'` 驗證讀回）

### AC-2: 編輯器失敗不遺失
- **Given**: 命令設成會失敗（非零離開碼）或逾時
- **When**: 觸發
- **Then**: 通知失敗、不貼任何文字;原聽寫仍可用 retry-last
- **Test**: `ExternalEditorReviewRunnerTests::nonZeroExitThrows`

### AC-3: 剪貼簿模式
- **Given**: 目標設 `clipboard`
- **When**: 編輯完 `:wq`
- **Then**: 編輯後文字在剪貼簿、出現通知;不自動貼
- **Test**: 手動

### AC-4: 零回歸
- **Given**: 未開此 Toggle 的既有語音模式
- **When**: 聽寫
- **Then**: 直接貼上，與升級前一致
- **Test**: 既有 delivery 行為手動 + 單元

## Open Questions

- [ ] 焦點還原延遲的秒數（預設試 0.3–0.5s，plan 定;`clipboard` 模式免此問題）。
- [ ] 逾時秒數（編輯是人操作，需長逾時如 600s 或不逾時只等進程結束）——傾向不設短逾時，等進程結束。
- [ ] 暫存檔副檔名/filetype（`.md` 讓 vim 有語法;plan 定）。
