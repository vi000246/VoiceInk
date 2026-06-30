# Implementation Report: Recorder Mode & Manual Recording Management

## Summary
Implemented the M3 Feature SRS: recorder transcription decoupled from voice Modes via a new
**Recorder Mode** (own model/language/formatting + default analysis model), template application +
Obsidian export shifted to a **manual** flow (default), and the recorder log upgraded to a full
**Recording Management** page (apply → preview → export, delete audio / record). Raw transcript +
audio always preserved.

## Assessment vs Reality
| Metric | Predicted | Actual |
|---|---|---|
| Complexity | Large | Large |
| Confidence | 8/10 | single-pass (one trivial unwrap fix) |
| Files Changed | 4 new / 8 modified | 3 new / 8 modified |

## Tasks Completed
| # | Task | Status | Notes |
|---|---|---|---|
| 1 | Recorder Mode settings in store | ✅ | 4 keys + setters |
| 2 | Synthetic transcription config | ✅ | `RecorderTranscriptionConfig` |
| 3 | Recorder uses own model | ✅ | `handleMount` → `RecorderTranscriptionConfig.current()` |
| 4 | Split post-processor + manual/auto branch | ✅ | suggestCategory / applyTemplate / export; reclassify wrapper kept |
| 5 | Recorder Mode page | ✅ | New page; default-model card moved from Recorder Prompts |
| 6 | Recording Management page | ✅ | dropdown + Apply + Export + delete audio/record |

## Validation Results
| Level | Status | Notes |
|---|---|---|
| Static / Build | ✅ Pass | Debug build green |
| Unit Tests | ✅ Pass | 22 recorder tests (4 new RecorderModeTests) |
| Deploy | ✅ Pass | make deploy (Release, stable-signed); launches |
| Manual AC | ⏳ Pending | AC-R1..R7 need a physical recorder |

## Files Changed
| File | Action |
|---|---|
| `RecorderConfigStore.swift` | UPDATED — Recorder Mode settings |
| `RecorderTranscriptionConfig.swift` | CREATED |
| `RecorderPostProcessor.swift` | UPDATED — split into suggest/apply/export + branch |
| `RecorderImportService.swift` | UPDATED — recorder transcription config |
| `RecorderModeSettingsView.swift` | CREATED |
| `RecorderHistoryView.swift` | UPDATED — Recording Management |
| `CategoriesSettingsView.swift` | UPDATED — removed DefaultModelCard |
| `ContentView.swift`, `AppSidebar.swift` | UPDATED — .recorderMode + title renames |
| `Localizable.xcstrings` | UPDATED — 錄音筆模式 / 錄音管理 |
| `RecorderModeTests.swift` | CREATED — 4 tests |

## Deviations from Plan
- Recording Management uses **one** "範本（類別）" dropdown rather than separate category +
  template dropdowns, because in this data model a 錄音筆範本 IS a category (bundles prompt +
  subfolder + model). Cleaner and matches `applyTemplate(category:)`. (Open-Question default.)

## AC Verification Map
| AC | Test | Status |
|----|------|--------|
| AC-R1 transcription uses Recorder Mode | manual | ⏳ hardware |
| AC-R2 manual default (no auto export) | `RecorderModeTests.testRecorderAutoExportDefaultsManual` + manual | 🟢 logic / ⏳ e2e |
| AC-R3 apply preserves raw | manual | ⏳ |
| AC-R4 export to subfolder | manual | ⏳ |
| AC-R5 delete audio vs record | manual | ⏳ |
| AC-R6 recorder audio exempt cleanup | implemented (prior commit) | 🟢 |
| AC-R7 model picker sources | manual | ⏳ |

## Open Questions (deferred per user)
- Auto-export toggle scope: implemented **global** (Recorder Mode).
- Category change → template auto-switch: one unified dropdown, no separate switch.
- Delete record → keep exported .md: **kept** (not deleted from vault).

## Next Steps
- [ ] Manual/hardware AC verification with a physical recorder
- [ ] Push accumulated commits to `origin/main` (user decision)
