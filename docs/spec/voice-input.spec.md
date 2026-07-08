# Spec: Voice Input（語音模式 / 聽寫輸出）

## Metadata
- **Module**: voice-input
- **Parent Module**: N/A
- **Sub-modules**: N/A
- **Source PRDs**: N/A — 2026-07-08 使用者需求（編輯後貼上）
- **Owner**: TBD（vi000246/VoiceInk）
- **Status**: ACTIVE — living document
- **Created**: 2026-07-08
- **Last Updated**: 2026-07-08

## Change History

| Date | Source PRD | Feature SRS | Summary |
|------|------------|-------------|---------|
| 2026-07-08 | N/A | `docs/srs/voice-input-edit-before-paste.srs.md` | Created from brownfield analysis — 語音模式（Modes + TranscriptionDelivery）的輕量模組視圖;新增「編輯後貼上」:貼上前用外部 MacVim/nvim 阻塞編輯暫存檔、`:wq` 後讀回並貼回（或放剪貼簿）。尚未實作。 |

## Summary

`voice-input` 涵蓋 VoiceInk 的語音聽寫輸出路徑:錄音 → 轉錄 →（可選 AI 改寫）→ 依 Mode 的 `outputMode`
交付（貼上 / 對話回覆 / 自訂命令）。本模組 spec 目前聚焦「交付（delivery）」層與「編輯後貼上」增強;
其餘（錄音引擎、Modes 觸發、AI 改寫）為既有實作，需要時再逆向補充。

---

## Domain Model

### Bounded Context
- **Context Name**: VoiceInput
- **Domain Layer**: Core Domain（app 主功能:聽寫並交付到目標 app）

### Ubiquitous Language
| Term | Definition |
|------|-----------|
| Output Mode | Mode 的交付方式:`.paste`（貼進目標框）/ `.respond`（顯示 AI 回覆）/ `.customCommand`（管線過 shell）。 |
| 編輯後貼上 | `.paste` 的變體:貼上前先用外部編輯器（真 vim）修改，`:wq` 後讀回再貼。 |
| 交付（Delivery） | `TranscriptionDelivery.deliver` 依 outputMode 分派的最終輸出動作。 |
| 外部編輯器 round-trip | 寫暫存檔 → 阻塞跑編輯器命令 → 讀回內容 → 清暫存。 |

---

## System Context

### Scope & Boundaries
- **In scope（本 spec 目前）**: delivery 層（`TranscriptionDelivery`）、`ModeOutputMode`、編輯後貼上。
- **Out of scope**: 錄音引擎、Modes 觸發/情境、AI 改寫細節（既有，未在此 spec 展開）;詞典（不做）。

### Actors
| Actor | Type | Interaction |
|---|---|---|
| 使用者 | Human | 聽寫;若開編輯後貼上，在外部 vim 修改後 `:wq` |
| 外部編輯器（MacVim/nvim） | External process | 阻塞編輯暫存檔;載入使用者 vimrc/plugin |
| 目標 app | External | 接收貼上（焦點還原後） |

### External Dependencies
| Dependency | Purpose | Failure Mode |
|---|---|---|
| MacVim `mvim -f` / nvim / `$EDITOR` | 阻塞編輯 | 非零離開/逾時 → 通知、不貼、原文留存 |
| `ShellCommandEnvironment` | login-shell PATH 執行命令 | 命令找不到 → 失敗通知 |
| `CursorPaster` / `ClipboardManager` | 貼回 / 剪貼簿 | 焦點未還原 → 退 clipboard 模式 |

---

## Architecture

### Components
| Component | Responsibility | Interface |
|---|---|---|
| `TranscriptionDelivery`（改） | 依 outputMode 分派;`.paste` + editBeforePaste → 先 round-trip | `deliver(_:actions:)`（`:25`） |
| `ExternalEditorReviewRunner`（新） | 暫存檔 + 阻塞跑編輯器 + 讀回 | `static func review(text:command:) async throws -> String` |
| `ModeConfig`（改） | 加 `editBeforePaste: Bool` | additive Codable |
| `ModeConfigFormView`（改） | `.paste` 下的 Toggle | UI |
| 全域設定 | 編輯器命令 + 貼回目標 | UserDefaults |

### Data Flow
`deliver` → 若 `.paste` 且 `editBeforePaste`：`ExternalEditorReviewRunner.review(text:command:)`（寫檔→阻塞
編輯→讀回）→ 以編輯後文字走 `paste()`（延遲等焦點還原）或 `ClipboardManager` 寫入 → 通知。

---

## Data Model

### Schema (new / changed)
```swift
// CHANGED ModeConfig — additive:
//   var editBeforePaste: Bool   // decodeIfPresent ?? false
// 全域 UserDefaults:
//   "editBeforePasteCommand": String  // 預設 "mvim -f {file}"
//   "editBeforePasteTarget":  String  // "paste" | "clipboard"（預設 paste）
```

### Migration Strategy
- **Forward**: `editBeforePaste` additive、decodeIfPresent → 舊 Mode false。
- **Backward**: 移除欄位無破壞。
- **Coexistence**: 未開者走原 `.paste`。

---

## Non-Functional Requirements

| Category | Target | Measurement | How Achieved |
|---|---|---|---|
| 保真度 | 真 vimrc/plugin | 手動 | 跑真 vim 進程 |
| 相容 | 舊 Mode 零回歸 | 單元+手動 | additive、預設關 |
| 韌性 | 失敗不遺失聽寫 | 單元 | 失敗不貼、retry-last 可用 |

---

## Technology Choices

| Concern | Choice | Alternatives | Rationale |
|---|---|---|---|
| 編輯器 | 外部真 vim（`mvim -f` 預設） | 內嵌 nvim GUI / 模擬 vim 鍵位 | 真 vimrc 只能跑真 vim;內嵌＝Neovim GUI 級工程（使用者決策 A） |
| round-trip | 暫存檔 + 阻塞進程 + 讀回 | stdin/stdout 管線 | 編輯器要檔案 + 阻塞;複用 ShellCommandEnvironment |
| 貼回 | 焦點還原延遲後 paste（可切 clipboard） | 只 clipboard | 自動化去掉手動 copy;焦點不穩時退 clipboard |

---

## Integration Points

| Touchpoint | Type | Contract | Backwards Compat |
|---|---|---|---|
| `TranscriptionDelivery.deliver`（`:25-52`） | 分派 | `.paste` + editBeforePaste 前置 round-trip | Yes — 未開者不變 |
| `ShellCommandEnvironment` | 執行 | login-shell 跑命令 | Yes |
| `CursorPaster`/`ClipboardManager` | 貼上/剪貼 | 既有 API | Yes |
| `ModeConfig` / `ModeConfigFormView` | schema/UI | 加欄位 + Toggle | Yes — additive |

### Rollout Strategy
無 flag;預設關（`editBeforePaste=false`）。Rollback = 移欄位/設定。

---

## Codebase Patterns to Follow

| Pattern | Where to Find | Why Follow |
|---|---|---|
| outputMode 分派 | `TranscriptionDelivery.swift:25-52` | 插入 round-trip 的位置 |
| shell 命令 + login-shell env | `Services/ShellCommandEnvironment.swift`、`CustomCommandDeliveryRunner.swift` | 阻塞跑編輯器 |
| 貼上路徑 | `TranscriptionDelivery.paste:150-168`（CursorPaster） | 編輯後貼回 |
| additive Codable Mode 欄位 | `Modes/ModeConfig.swift:95,160,208`（selectedPrompt 等 decodeIfPresent） | `editBeforePaste` |

---

## Risks & Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| 編輯器關閉後焦點未還原到目標框 | M | M | 貼前延遲;可切 clipboard 模式 |
| 使用者設 nvim 但無終端承載 → 不阻塞 | M | M | 預設 mvim -f;文件說明 nvim 需可阻塞的終端命令 |
| 命令找不到（PATH） | L | M | login-shell env;失敗通知 |

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|---|---|---|---|
| 編輯器承載 | 外部真 vim | 內嵌 GUI | 使用者決策 A;真 vimrc |
| 觸發 | 每 Mode `editBeforePaste` Toggle | 全域開關 | 只在需要的 Mode 開 |
| 貼回 | paste（可切 clipboard） | 只 clipboard | 自動化;焦點風險退路 |

---

## Open Questions

- [ ] 焦點還原延遲秒數。
- [ ] 逾時策略（傾向不設短逾時，等進程結束）。
- [ ] 暫存檔 filetype。
