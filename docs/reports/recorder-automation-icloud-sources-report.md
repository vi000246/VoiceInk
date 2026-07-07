# Feature Implementation Report: iCloud Recorder Sources（JPR / Voice Memos）

## Summary
手錶/iPhone 錄音自動進管線：`RecorderDevice` 四個 additive 欄位、遞迴掃描＋relativePath 入 ledger、dataless 佔位檔「下載→defer→重掃」、`NSMetadataQuery` 監看 iCloud Drive、preset 一鍵設定（JPR／語音備忘錄）、per-source 預設分類、原始檔雙重保護、錄音時間三段解析鏈。Build 230。

## Strategy Used
- Size: M ｜ Mode: B ｜ Rigor: balanced ｜ 主 session 直接實作（無 subagent）
- Tasks 1-8 全數完成；Task 9 收尾本檔

## Tasks Completed
| # | Task | Status | Notes |
|---|------|--------|-------|
| 1 | RecorderDevice additive 欄位＋legacy decode | ✅ | `defaultCategory(in:)` 需 @MainActor（build 時發現） |
| 2 | 遞迴掃描＋relativePath 全鏈 | ✅ | reprocess/deviceFiles 同步遞迴化；cleanup 系列維持平面（v1 界線） |
| 3 | 佔位檔 defer＋批次下載 | ✅ | `ubiquityAction` 純函式 seam |
| 4 | ICloudSourceWatcher | ✅ | folder-URL scope＋wake/activate rescan；recheck 按來源分流（iCloud 8s） |
| 5 | protectsOriginals 雙重防護 | ✅ | originalURLs 不記＋finalizeImport guard |
| 6 | per-device 預設分類 | ✅ | 複用 meeting 的 `process(fixedCategory:)` 縫合點 |
| 7 | 錄音時間解析鏈 | ✅ | 三處查詢收斂到 `recordingDate(for:)`；staging copy 保留 birth time 供 VM fallback |
| 8 | Preset UI＋分類 Picker＋保護鎖 | ✅ | JPR glob 容器名（未硬編）；VM readability probe＋FDA 引導 |

## Integration Checks
| Check | Status | Notes |
|---|---|---|
| Build | ✅ | 一處 actor 隔離修正 |
| Unit tests | ✅ | 8 新測試（decode/protect/category/遞迴/ubiquity/時間鏈×3）＋全套零回歸 |
| 手動 | ⏳ 待使用者 | JPR 容器實名、VM FDA、佔位檔下載循環——見下方驗證清單 |

## Deviations from Plan
1. `defaultCategory(in:)` 標 `@MainActor`（plan 未標，編譯要求）。
2. iCloud recheck 間隔 8s（plan 未定值；下載比本地複製慢）。
3. Preset 按鈕只在「新增」時顯示（編輯既有來源不重套，避免覆蓋使用者調整）。

## Manual Validation（→ Linear 驗證 issue 待授權後建）
- [ ] 錄音裝置 → ＋ → 「快速設定：Just Press Record」→ 找得到容器並預填（找不到時的引導文案正確）
- [ ] JPR 手錶錄一段 → 回 Mac 喚醒 → 自動下載＋匯入＋出筆記；筆記時間＝路徑日期時間（非匯入時間）
- [ ] Finder 對已同步檔「移除下載項目」→ 重掃 → 自動下載後匯入、不重複
- [ ] 「Apple 語音備忘錄」preset：無 FDA 時引導出現；允許後重試成功；iPhone 錄的備忘錄同步後自動匯入，時間＝檔案建立日
- [ ] 受保護來源卡片：刪除開關被鎖定標籤取代；原始檔永存
- [ ] 指定預設分類的來源：request log 零分類呼叫
- [ ] 既有錄音筆/資料夾來源行為零變化

## Follow-ups
- [ ] Linear 驗證 issue（等 `/mcp` 授權 Linear）
- [ ] VM「需開過 app 才同步」的傳言實測後補文件
- [ ] `.qta`（iOS 26 傳言格式）若實際出現 → SupportedMedia 增列
