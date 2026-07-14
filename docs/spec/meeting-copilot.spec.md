# Spec: meeting-copilot

## Metadata
- **Module**: meeting-copilot
- **Parent Module**: N/A
- **Sub-modules**: N/A
- **Source PRDs**:
  - N/A — 2026-07-12 使用者需求。產品脈絡承接 `docs/prd/meeting-capture-to-obsidian.prd.md`
    中被列為 NOT Building 的「即時字幕／即時摘要 HUD — 串流即時化另案評估」。
- **Source Linear Issue**: N/A
- **Owner**: TBD（personal fork — vi000246/VoiceInk）
- **Status**: ACTIVE — living document
- **Created**: 2026-07-12
- **Last Updated**: 2026-07-14

## Change History

| Date | Source PRD | Feature SRS | Summary |
|------|------------|-------------|---------|
| 2026-07-14 | code-sync（`/prp-spec`） | `docs/srs/meeting-copilot-m8-notes-rag-auto-deep.srs.md` | **M8 implemented（19 commits，302 單元測試全綠，build 綠）** — 本列記錄「實際出貨」與「M8 spec'd 那列的意圖」之間的落差，全部經 code 核對：**(1) 漏抓掃描的匹配演算法改了**——不是原訂的純 bigram Jaccard，而是 `max(Jaccard, 包含度)`（包含度 = 交集/較短方；門檻仍 `MeetingCueDeduplicator.defaultThreshold` 0.6）。純 Jaccard 對「短改寫 vs 長原句」系統性低估（「請自我介紹」vs「自我介紹一下」= 0.50），會把**已經抓到**的題目報成漏抓，漏抓清單混進假漏抓比漏報更糟。**(2) replay 合成時間軸**（`askedAt = startedAt + index × 錄音長度/段數`）：全塞同一個 `Date()` 會讓去重的 30 秒窗退化成「全場去重」，live 留兩則、replay 只留一則 → 兩條路徑不可比，而可比正是覆盤的理由。同理 replay 補寫 `tier0Keywords`（只對非 informational，照抄 live 的觸發條件）、`endedAt` = 錄音長度、`remoteTranscriptRaw` = 逐字稿全文（session 自給自足）、`deepModel` 誠實記空字串。**(3) `MeetingCopilotRunConfig` 的 M8 欄位一律 optional**：Swift 合成的 `Decodable` 不套用屬性預設值，非 optional 新欄位會讓 M8 之前的舊快照整份 decode 失敗（診斷退回純文字，舊 session 變因全不可讀）。**(4) auto-deep 的世代守門**（`deepGeneration` + `deepTaskCueId` 在 spawn 當下即設）：被取消的舊 deep 晚一步醒來時不得抹掉新 deep 的在途標記——同 cue 重跑時 `cue.id` 相同，只有世代分得出來。**(5) 掃描的「尚未掃描」vs「零漏抓」是兩件事**：`reviewSweepRaw == ""` = 未掃／掃描失敗（UI 顯示補跑按鈕），`"[]"` = 掃過且真的零漏抓；把壞回覆寫成「零漏抓」會讓覆盤頁理直氣壯地說謊。**(6) 熱鍵註冊點的既有說法是錯的**（見 Codebase Patterns 修正列）。**(7) 兩個已知缺口進 Risks/Open Questions**：`switchModel` 後筆記不會被重嵌（FR-44 後半未落地）、`MeetingGrounding.userBlock()` 的措辭與 aboutMe 的「唯一事實來源」相衝。 |
| 2026-07-13 | N/A（使用者需求） | `docs/srs/meeting-copilot-m8-notes-rag-auto-deep.srs.md` | **M8 spec'd：筆記 RAG + auto-deep 閱讀保護 + 離線覆盤 + 即時翻譯（四組綁定升級）** — (A) cue 五分類：新增 `aboutMe`（問我本人／我的專案／**績效考核**——行為面試從 informational 搬出），同一次抽取呼叫多輸出 `searchHint` 檢索改寫（零新增 LLM 呼叫）；新 `ObsidianNoteIndexService` 把 Obsidian vault（**重用** `RecorderConfigStore.vaultRootBookmark`）嵌入 `EmbeddingChunk(sourceKind:"obsidian")`，`gather(sources:)` 按 cue 種類路由（aboutMe → 只查筆記；技術 cue 明確排除筆記除非 opt-in）；aboutMe tier prompt 變體＝記憶錨點助記詞、只用筆記不編造。**兩個地雷**：`reconcileOrphans` 須跳過 obsidian chunks、`switchModel` 清索引後須重嵌筆記。(B) auto-deep：最新 cue Tier1 完成自動跑 Tier2 並自動展開；**閱讀保護不變量**（展開中 cue 不被 maxCuesShown 擠出／不被搶展開／in-flight Tier2 不被取消）＋展開 toggle 熱鍵（第四處熱鍵四點註冊）；`expandedCueId` 從 view @State 升級 controller 層。(C) 離線覆盤：錄音管理詳情頁對非即時錄音「產生會議copilot覆盤」——從**逐字稿**（不重跑 ASR）分段餵同一條抽取→tier 管線，session 標 `sourceRaw:"replay"`、可重複產生（configSnapshot A/B）；**漏抓掃描**（無主題過濾通用 prompt 掃全文 → Jaccard 對已偵測 cues → 未匹配＝漏抓）persist 至 `reviewSweepRaw`；覆盤詳情三層排序（有回應→無回應→漏抓）＝分類調校迴圈。(D) 即時翻譯：remote committed 的第二個獨立 consumer，LLM 翻譯（混語自動辨識）譯入 `targetLanguage`（預設繁中）；overlay 上翻譯字幕流／下 cue 回應區明確區隔；所有 tier 回應恆以目標語言輸出；設定頁改 tab（一般／即時翻譯）。FR-41~64 / AC-28~47。Plan：`docs/plans/meeting-copilot-m8-notes-rag-auto-deep.plan.md`（Mode B／balanced，Task 1–20 依 A→B→C→D）。 |
| 2026-07-13 | N/A（使用者需求） | N/A（直接實作） | **觀測資料持久化（調校迴圈的原始資料）** — 目標：讓每則 cue 事後可完整重建「怎麼被偵測到、AI 回應時看到了什麼上下文、花了多久、哪裡失敗」，供持續調校。新增 `@Model MeetingLiveSegment`（每段 committed 一筆：remote/local 時間軸＋remote 段的抽取 provenance——實際 fast model、**原始 LLM 回覆**、耗時、抽出數、**去重丟棄數**、失敗原因；抽出 0 則也留檔＝漏抓分析的基礎）。`MeetingLiveCue` 加觀測欄位（`sourceSegmentId`／`detectionElapsedMs`／tier1・tier2 的**實際 user prompt 全文**（接地內容在內）／原始回覆／耗時／錯誤／接地降級備註）；`fastModelName`/`deepModelName` 從佔位 "fast"/"deep" 改記實名 "provider/model"。`MeetingLiveSession.configSnapshotRaw` 存當場執行設定 JSON（`MeetingCopilotRunConfig`：模型、開關、persona、**三個 system prompt 全文**、去重參數）；`remoteTranscriptRaw`/`localTranscriptRaw` **補上回填**（宣告以來從未寫入，覆盤頁一直空白）。`MeetingGrounding.ragError` 讓 RAG 靜默降級留下原因。覆盤頁新增逐段偵測時間軸、per-cue 診斷收合區、設定快照、**「匯出診斷 JSON」**（`MeetingSessionDiagnostics`，可直接餵 LLM 做漏抓/誤抓/答非所問分析）。行為不變（純記錄）；`recentContext` 欄位照實記錄目前恆空的滑動窗，為 Open Question 的窗口調校預留 A/B 資料。 |
| 2026-07-13 | N/A（使用者需求） | `docs/srs/meeting-copilot-m7-preset-scripts.srs.md` | **M7 spec'd:預設講稿讀稿器（獨立提詞面板）** — 使用者事先寫好多份具名講稿（自我介紹、對某議題的立場…），開會時用一個私人浮動面板看著唸（等同 PowerPoint 簡報者檢視 / 讀稿機）。動機：ADHD 看稿安全感。**硬界線**：只顯示使用者自寫文字，**完全不接 AI/ASR/LLM、不讀 cue 清單、不整合進 cue overlay**；獨立於 `copilotEnabled`，copilot 關閉也可用。新增 `PresenterScript`＋`PresenterScriptStore`（UserDefaults）＋`PresenterScriptPanel/…WindowManager/…View`（複製 overlay 的螢幕分享排除＋不搶焦點＋手動拖曳「視窗技術」，但不持有 controller）＋設定頁講稿管理＋`togglePresenterScript` 熱鍵。FR-33~40 / AC-20~27。 |
| 2026-07-12 | N/A（使用者需求） | `docs/srs/meeting-copilot-live-assist.srs.md` | **新模組 spec'd（未實作）** — 會議即時輔助。核心：(1) 在 `mixToMono` 之前按聲道切開 tap（對方）與 mic（我）→ 雙路串流 ASR，**講者歸屬零成本、免 diarization**；(2) `ResponseCueExtractor` 抓「需要我回應的東西」（含陳述句質疑，非只抓問號）；(3) **三層漸進揭露**——Tier 0 本機關鍵字（<0.5s，不呼叫 LLM）／Tier 1 fast model 產「開口稿」（<1.5s，**最新一則預跑**）／Tier 2 deep model 產結構化 follow-up 預判；(4) 答案接地於**會前 brief + 歷史逐字稿 RAG（重用 Ask AI 的 `RetrievalService`）+ 分享畫面 OCR（重用 `ScreenCaptureService`）**；(5) `sharingType = .none` 的 overlay，toggle + **peek（按住顯示）**雙熱鍵，錨定螢幕上方近鏡頭處，我說話時自動淡出。含不開 Teams/Meet 的離線 replay 驗證 harness。 |

## Summary

`meeting-copilot` 是 VoiceInk 的**即時**會議輔助模組：會議進行中把對方與我的語音分成兩條獨立串流即時轉錄，
從對方的串流偵測「需要我回應的東西」，並以一個不會被螢幕分享擷取的浮動 overlay，用**三層漸進揭露**
（0.5s 方向 → 1.5s 開口稿 → 15s 深度分析）提供回應建議。

**設計第一原則**：瓶頸不是答案品質，是**「開口的頭五秒」**。模型答得再好，若你得先讀完三段文字才敢開口，
那段沉默本身就是破綻。整份架構都在壓縮「從偵測到 cue」到「你能開口」的時間，而非追求最完整的答案。

它與 `recorder-automation` 的關係是**單向借用音源**：後者負責會議錄音的落檔與事後 Obsidian 匯出（行為不變），
前者只在 `MeetingCaptureService` 的 IOProc 中多接一個即時 PCM seam。兩者在延遲需求、失敗語意、
資料生命週期上完全相反，因此刻意分為兩個 bounded context。

---

## Domain Model

### Bounded Context
- **Context Name**: MeetingCopilot（即時會議輔助）
- **Domain Layer**: Supporting Domain
- **Parent Module**: N/A

### Ubiquitous Language

| Term | Definition |
|------|-----------|
| **Remote stream** | Process tap 擷取到的系統音訊聲道 —— **會議中其他人**的聲音。cue 只從這條流偵測。 |
| **Local stream** | Aggregate device 中麥克風 sub-device 的聲道 —— **我自己**的聲音。作上下文與「我在說話」偵測，不抽 cue。 |
| **Channel split** | 在 `MeetingAudioMixer.mixToMono` 把所有聲道等權壓成單聲道**之前**，依 `tapChannelCount` 把 `channelScratch` 切成 remote / local。本模組講者歸屬的唯一來源——**不使用 diarization**。 |
| **Tap channel count** | Process tap 的聲道數（`kAudioTapPropertyFormat` 於 setup 時讀得）。即 channel split 的切點。裝置切換時可能改變。 |
| **Response cue** | 從 remote 流偵測到的**「需要我回應的東西」**。五類（M8 起）：`directQuestion`（直接問句）／`impliedChallenge`（陳述句形式的質疑，如「我對效能有點擔心」）／`assignedToMe`（被點名）／`aboutMe`（問我本人／我做過的專案／績效考核與行為面試——需要「回憶我的經歷」才能答的）／`informational`（不需回應）。**刻意不叫「問題」**——真實會議裡需要回應的多半沒有問號。 |
| **aboutMe cue / 記憶錨點** | 問「我」的 cue 走個人筆記 RAG：檢索 Obsidian 筆記，Tier 1 輸出**記憶錨點**（專案名／我的角色／具體貢獻／量化成果）而非論述句——看到錨點，記憶自己會接上（ADHD 場景的核心交付）。鐵律：只用筆記與 `aboutMeBrief`，沒記載就說沒記。 |
| **searchHint** | cue 抽取對 aboutMe 額外輸出的**檢索改寫**（同一次 fast model 呼叫）：把「哪個專案最有成就感」這類模糊考核題改寫成筆記用語的檢索詞。空則退回 cue 原文。 |
| **auto-deep** | 最新 cue 的 Tier 1 完成後**自動**接跑 Tier 2 並（在無人閱讀時）自動展開。latest-only，鏡射 Tier 1 預跑的成本邊界。 |
| **閱讀保護** | 「展開中 = 閱讀中」的不變量組：展開的 cue 不被 `maxCuesShown` 擠出、展開狀態不被自動展開搶走、其 in-flight Tier 2 不被新 cue 取消、tier 內容寫入後不變。展開由點擊或 **toggle 熱鍵**控制。 |
| **離線覆盤（replay session）** | 對非即時來源的錄音，從**既有逐字稿**（不重跑 ASR）分段重演 cue→tier 管線產生的 session（`sourceRaw:"replay"`）。同一錄音可多次產生，各帶 configSnapshot——分類 prompt 調校的 A/B 基礎。 |
| **漏抓掃描（miss sweep）** | 「偵測器的偵測器」：無主題過濾的通用 prompt 掃全逐字稿列出所有應回應項，與已偵測 cues 做 bigram Jaccard 匹配，**未匹配 = 漏抓候選**，覆盤排最下供調校。本身不觸發 tier。 |
| **即時翻譯** | remote committed 的第二個獨立 consumer：LLM 單句翻譯（天然處理混語）譯入目標語言（預設繁中），overlay 翻譯字幕區與 cue 區明確區隔。等 committed 才譯（partial 會回改）。 |
| **Tier 0** | < 0.5s，**不呼叫 LLM**（關鍵字表 + 本機 embedding 相似度）。輸出領域標籤 + 2-3 關鍵字。任何 LLM 往返都不可能穩定低於 0.5s。 |
| **Tier 1 / 開口稿（opener）** | < 1.5s，fast model SSE。輸出 `opener`（**一句可直接說出口的話**）+ 恰 3 個 bullet。`opener` 不是答案摘要，是**讓你開口、爭取時間的一句話**——整個功能的關鍵欄位。 |
| **Tier 2** | < 15s，deep model SSE，帶入 Tier 1 草稿。輸出 `analysis` + **結構化 `followUps[]`** + `uncertainties[]`。 |
| **Prefetch（預跑）** | 最新一則 cue 的 Tier 1 在使用者按熱鍵之前就已跑完。點擊 → 零等待。全案最便宜的體感升級。 |
| **Grounding（接地）** | 讓答案「針對我們專案正確」而非「教科書正確」的三個上下文來源：**會前 brief**、**歷史逐字稿 RAG**、**分享畫面 OCR**。 |
| **Peek 模式** | **按住熱鍵顯示、放開隱藏**。比 toggle 更貼合「瞄一眼」，且不會忘記關掉。沿用既有 push-to-talk 的 keyDown/keyUp 機制。 |
| **Meeting audio source** | 音源注入協定。`LiveMeetingAudioSource`（CoreAudio）與 `ReplayMeetingAudioSource`（預錄 WAV）為其兩個實作——後者讓完整 pipeline 可在不開會議軟體、不開 CoreAudio 下端到端驗證。 |

### Domain Events

| Event | Trigger Condition | Consumers |
|---|---|---|
| `responseCueDetected`（internal） | `ResponseCueExtractor` 從 remote committed 片段抽出一則新 cue | Tier 0（立即）、Tier 1 預跑（若為最新）、overlay、`MeetingCopilotStore` |
| `tierCompleted`（internal） | Tier 0 / 1 / 2 任一完成 | Overlay 漸進渲染、SwiftData 持久化 |
| `localSpeechActivity`（internal） | local 流 RMS 越過門檻 | Overlay 自動淡出／恢復 |

---

## System Context

### Scope & Boundaries

- **In scope**：即時聲道分流；lock-free ring buffer；雙路串流 ASR；response cue 偵測與四分類；
  三層漸進揭露（含 Tier 1 預跑）；答案接地（brief / RAG / 螢幕 OCR）；兩階段 SSE 串流；
  copilot overlay（螢幕分享排除／點擊穿透／不搶焦點／peek／近鏡頭定位／說話時淡出）；
  「會議錄音管理」頁；本模組設定與熱鍵；離線 replay 驗證 harness。
- **Out of scope**：會議錄音的落檔、匯入、分類、範本、Obsidian 匯出（全數屬 `recorder-automation`，行為不變）；
  批次 diarization（本模組不需要）；會議平台 API／bot 整合（與平台無關，只讀本機音訊輸出）；
  自動偵測會議開始（沿用既有手動啟停）；**會後三欄覆盤**（使用者明確排除）。

### Actors

| Actor | Type | Interaction |
|---|---|---|
| User | Human | 會前填 brief；會議中按熱鍵（toggle 或 peek）召喚 overlay、點擊 cue 取得深度回應 |
| 會議中的其他人 | Human | 其聲音經 process tap 進入 remote stream（**錄音同意為使用者的責任**） |
| 線上會議 app（Teams / Meet / Zoom…） | External app | 音訊輸出被系統級 process tap 擷取；分享的畫面被 OCR。本模組**不**與其 API 互動 |
| Streaming ASR（FluidAudio 本機 / Deepgram 等雲端） | Local ML / Service | 即時逐字稿 |
| LLM provider（Groq / Cerebras / Anthropic…） | Service | cue 抽取＋Tier 1＋Tier 2 |
| Ask AI 向量索引（`EmbeddingChunk`） | Internal（跨模組唯讀） | 歷史逐字稿 RAG 接地 |

### External Dependencies

| Dependency | Purpose | Failure Mode |
|---|---|---|
| CoreAudio process tap + aggregate device | 唯一音源 | TCC 未授權 → 既有 `CaptureError.tapCreationFailed`；copilot 隨會議錄製一併失效 |
| FluidAudio（CoreML，本機） | 預設即時 ASR，免 API key | 模型未下載 → 退回雲端串流模型或停用 copilot |
| LLM provider | cue 抽取＋Tier 1／2 | 斷線／無 key → 該層失敗，**逐層降級**（見下），錄音與逐字稿不受影響 |
| `RetrievalService`（ask-ai 模組） | 歷史逐字稿 RAG | 索引空／無 embedding key → **靜默跳過**，答案照出 |
| `ScreenCaptureService` | 分享畫面 OCR 文字 | 權限未授予／無文字 → **靜默跳過** |

---

## Architecture

### High-Level Diagram

```
                    ┌─ HAL realtime thread ────────────────────────┐
CoreAudio IOProc ──►│ handleIO: deinterleave → channelScratch      │
 (tap ch + mic ch)  │   ├─► MeetingChannelSplitter                 │ ◄── 本模組唯一的
                    │   │      切 remote / local                    │     擷取端侵入點
                    │   │      → 2× SPSC ring buffer (lock-free)   │
                    │   └─► mixToMono → ExtAudioFileWriteAsync     │ ◄── recorder-automation
                    └──────────────────────────────────────────────┘     落檔，行為不變
                              │ consumer Task（離開 realtime context）
                              ▼
                       PCMDownsampler ×2  (Float32 多聲道 → mono 16k Int16 LE)
                              │
              ┌───────────────┴───────────────┐
              ▼ remote（對方）                  ▼ local（我）
    StreamingTranscriptionService     StreamingTranscriptionService
              │ .committed                     │ .committed（上下文）
              │                                │ + RMS → overlay 淡出
              ▼                                │
      ResponseCueExtractor ◄──────────────────┘
       fast model：抽取 + 四分類 + 去重（單次呼叫）
              │ MeetingLiveCue
              │
              ├─► Tier 0  本機關鍵字 + embedding 相似度        <0.5s  ❌無 LLM
              │
              ├─► Tier 1  fast model + SSE → opener + 3 bullets <1.5s  ⚡最新一則預跑
              │      ▲ 接地：brief + RAG(RetrievalService)
              │
              └─► Tier 2  deep model + SSE（點擊才跑）          <15s
                     ▲ 接地：brief + RAG + 螢幕OCR(ScreenCaptureService)
                     │ 帶入 Tier 1 草稿
                     ▼ analysis + followUps[] + uncertainties[]
                              │
                              ▼
                   CopilotOverlayPanel
                   sharingType = .none  ·  ignoresMouseEvents  ·  canBecomeKey = false
                   toggle 熱鍵 + peek 熱鍵（按住顯示）
                   錨定螢幕上方中央（近鏡頭，減少眼球飄移）
                   opener 最大字級 · 我說話時淡出至 0.35
```

### Components

| Component | Responsibility | Interface |
|---|---|---|
| `MeetingChannelSplitter` | 依 `tapChannelCount` 切 remote / local | 純函式（可測） |
| `PresenterScript*`（M7，**獨立子功能**） | 私人提詞面板：顯示使用者自寫講稿；store（UserDefaults CRUD）＋panel/manager/view。**不接 AI/ASR/LLM、不引用 live pipeline 型別** | 複製 overlay 的視窗技術（分享排除／不搶焦點／手動拖曳），非機能耦合 |
| `MeetingPCMRingBuffer` | SPSC lock-free 環形緩衝；滿溢丟最舊並計數 | 預配置指標，原子 head/tail |
| `PCMDownsampler` | Float32 多聲道 → mono 16kHz Int16 LE | 純函式（自 `CoreAudioRecorder.swift:930-1000` 抽出，兩處共用） |
| `MeetingAudioSource`（協定） | 音源注入 seam | `start()` / `stop()` / `frames: AsyncStream<MeetingAudioFrame>` |
| `LiveMeetingAudioSource` / `ReplayMeetingAudioSource` | 正式（CoreAudio）／測試（預錄 WAV） | 實作 `MeetingAudioSource` |
| `ResponseCueExtractor` | 抽 cue + **五分類**（M8 起含 `aboutMe`）+ `searchHint` 檢索改寫 + 去重（fast model **單次**呼叫） | prompt 建構為純函式；aboutMe 的檢索改寫掛在同一次呼叫 = 零新增 LLM 往返 |
| `Tier0Classifier` | 領域標籤 + 關鍵字（**不呼叫 LLM**） | 關鍵字表 + `EmbeddingChunk` 相似度。live 由 `onNewCue` 寫入；**replay 於 `MeetingReplayReviewService` 內補寫**（同樣只對非 informational），否則兩條路徑的 cue 欄位不可比 |
| `MeetingGroundingProvider` | 組裝 brief + RAG 片段 + 螢幕 OCR 文字 | `gather(query:brief:includeRAG:includeScreen:sources:)`。**M8 起 `query` 不等於 cue 原句**（aboutMe 用 `searchHint`）；`sources` = `EmbeddingChunk.sourceKind` 白名單，nil = 不限（等同 M8 前寫死的 `.all`）。唯讀重用 `RetrievalService`、`ScreenCaptureService`；各自靜默降級 |
| `AnswerCoordinator` | Tier 1 → Tier 2；預跑；**auto-deep**；**閱讀保護**；可取消 | 依賴 `StreamingChatCompleting`（可注入）。`groundingPlan(for:)` 按 cue 種類路由檢索範圍；`expandedCueIdProvider` / `onDeepCompleted` 兩個閉包反轉對 controller 的依賴（coordinator 不認識 controller）；`runTier1ForReplay` 是覆盤的入口（不掛 auto-deep、不動 prefetchTask） |
| `ObsidianNoteIndexService`（M8，**唯一的新基建**） | Obsidian vault → 向量索引的增量掃描 | `reindex(vaultRoot:includeOnly:excluded:)`；身分鍵 = 路徑 SHA-256 前 16 bytes 的**確定性 UUID**（塞進 `EmbeddingChunk.transcriptionId`）→ 取代式 upsert 天然冪等；增量比對靠 **sidecar JSON**（`路徑 → 內容 SHA-256`），**先 persist 後記 hash**（中斷只多花錢、不壞資料）。`static let sourceKind = "obsidian"` |
| `MeetingLiveTranslator`（M8） | remote committed 的**第二個獨立 consumer**：逐段翻譯 → overlay 字幕 feed | `translate(segment:)` 開 Task，與 cue 抽取**平行、互不阻塞**。`liveTranslationEnabled` 的 guard 在**它自己內部**（任何新呼叫端都不可能漏掉 → AC-47「關閉＝零 API 呼叫」）；feed 恆按 `committedAt` 排序（**不按完成序**：短句先譯完會插到前面，字幕跳動）、留最近 20 句；失敗／空回覆 → 字幕留原文 |
| `MeetingReplayReviewService`（M8） | 逐字稿 → replay session（分段 → 抽取 → 去重 → Tier 1 → 漏抓掃描） | 序列（避 rate limit）、可取消、**失敗刪整場 session**（不留半套）。`ReplaySegmentation` 為純函式：講者輪次優先（**不加「講者N：」前綴**——cue 抽取吃的是「對方剛說的話」原文，前綴會污染），無輪次則切句群（≤3 句／≤200 字，貼近 live committed 節奏） |
| `MeetingReviewSweep`（M8） | 漏抓掃描：「偵測器的偵測器」 | **無主題過濾**的通用 prompt 掃全逐字稿 → `unmatched()` 與已偵測 cue 比對（`max(Jaccard, 包含度)` ≥ 0.6，**不做時間窗**）→ 未匹配項寫 `session.reviewSweepRaw`。失敗／解析不出 → **留空**（≠ 零漏抓）；本身不觸發 tier |
| `MeetingReviewOrdering`（M8） | 覆盤三層排序（有回應 → 未回應 → 漏抓） | generic over `MeetingReviewOrderable` protocol（判準 `!tier1Opener.isEmpty \|\| !tier2Analysis.isEmpty` 關在純函式內，view 換不掉） |
| `StreamingChatClient` | repo 內自持 SSE client（OpenAI-compatible + Anthropic） | → `AsyncThrowingStream<String, Error>` |
| `CopilotOverlayPanel` / `…WindowManager` | overlay：分享排除、點擊穿透、不搶焦點、peek、近鏡頭定位、說話淡出；**M8：上翻譯字幕區／下 cue 回應區** | clone 自 `MeetingIndicatorPanel`。`CopilotOverlayArranger.arrange(…, pinnedId:id:)` 讓展開中的 cue **不被 `maxCuesShown` 擠出** |
| `MeetingCopilotConfigStore` | 設定（fast/deep/翻譯三組模型、三個熱鍵、各開關、brief、筆記 RAG、翻譯語言） | `ObservableObject` + UserDefaults `…V1` |
| `MeetingCopilotController` | 即時狀態（cue 清單、**展開狀態**、**未讀徽章**）＋ SwiftData 持久化 | `@MainActor ObservableObject`。`expandedCueId` 從 view 的 `@State` **升到這裡**（熱鍵、auto-expand、arranger 三方共讀寫）；`expand(cueId:)` 是**唯一**展開入口（直寫 `expandedCueId` 會漏掉清未讀） |

### Data Flow

**Push，全程串流，無批次**。音訊自 realtime thread 單向推入 ring buffer；consumer Task 汲取後轉換並推入 ASR；
ASR 的 `.committed` 推動 cue 偵測；cue 出現立即觸發 Tier 0，並對**最新一則**預跑 Tier 1；
使用者點擊才觸發 Tier 2。

**任何一環失敗都是逐層降級而非崩潰**，且**失敗必須靜默**（分享螢幕時任何 modal 或系統通知都會暴露本功能）：

| 失敗 | 降級 |
|---|---|
| Tier 2 失敗 | 保留 Tier 1 草稿，overlay 內小字標紅 |
| Tier 1 失敗 | 保留 Tier 0 關鍵字 |
| RAG / 螢幕 OCR 失敗 | **靜默跳過**，答案照出（只是少了接地） |
| ASR 斷線 | 逐字稿停止，**錄音續行且落檔不受影響** |

---

## Data Model

### Entities

| Entity | Owner | Lifecycle |
|---|---|---|
| `MeetingLiveSession` | meeting-copilot | 會議開始建立（含執行設定快照）；結束補 `endedAt` 與雙軌逐字稿；可於「會議錄音管理」頁刪除 |
| `MeetingLiveCue` | meeting-copilot | cue 被偵測時建立；cascade 隨 session 刪除 |
| `MeetingLiveSegment` | meeting-copilot | 每段 committed 逐字稿建立（remote 段帶抽取 provenance）；cascade 隨 session 刪除 |

### Schema（新 store：`meeting.store`，`cloudKitDatabase: .none`）

```
@Model MeetingLiveSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date? = nil
    var appName: String = ""              // 前景 app（沿用既有 sourceLabel 慣例）
    var brief: String = ""                // 會前 brief — 注入所有 tier 的 system prompt
    var remoteTranscriptRaw: String = ""  // 對方逐字稿（stop 後自 transcriber 回填）
    var localTranscriptRaw: String = ""   // 我的逐字稿（同上）
    var importFingerprint: String = ""    // 關聯錄音檔（= Transcription.importFingerprint）
    var configSnapshotRaw: String = ""    // 當場執行設定 JSON（MeetingCopilotRunConfig：
                                          // 模型/開關/persona/三個 system prompt 全文/去重參數）
    var sourceRaw: String = "live"        // [M8] live | replay（離線覆盤 badge）
    var reviewSweepRaw: String = ""       // [M8] 漏抓掃描結果 JSON（未匹配項＋建議分類）
    @Relationship(deleteRule: .cascade, inverse: \MeetingLiveCue.session)
    var cues: [MeetingLiveCue]? = []
    @Relationship(deleteRule: .cascade, inverse: \MeetingLiveSegment.session)
    var segments: [MeetingLiveSegment]? = []
}

@Model MeetingLiveCue {
    var id: UUID = UUID()
    var session: MeetingLiveSession? = nil
    var text: String = ""
    var kindRaw: String = "informational" // directQuestion | impliedChallenge | assignedToMe | aboutMe(M8) | informational
    var searchHint: String = ""           // [M8] aboutMe 的檢索改寫（同次抽取呼叫輸出）
    var tier2TriggerRaw: String = ""      // [M8] auto | manual | 空=未跑（成本歸因）
    var askedAt: Date = Date()
    var contextExcerpt: String = ""       // 觸發 committed 的 300 字節錄
    var statusRaw: String = "detected"    // detected | answered

    var tier0Keywords: String = ""
    var tier1Opener: String = ""          // 一句可直接說出口的話
    var tier1BulletsRaw: String = ""      // JSON [String]（恰 3 個）
    var tier2Analysis: String = ""
    var tier2FollowUpsRaw: String = ""    // JSON [String]（question → oneLineAnswer 顯示行）
    var tier2UncertaintiesRaw: String = ""// JSON [String]

    var fastModelName: String = ""        // 實名 "provider/model"（歷史資料可能是佔位 "fast"）
    var deepModelName: String = ""
    var answeredAt: Date? = nil

    // 觀測欄位（調校迴圈；即時路徑只寫不讀）
    var sourceSegmentId: UUID? = nil      // 觸發本 cue 的 segment
    var detectionElapsedMs: Int = 0       // committed → cue persist（含抽取 LLM 往返）
    var tier1PromptUser: String = ""      // 實際送出的完整 user prompt（接地內容在內）
    var tier1RawReply: String = ""        // 解析前的原始模型回覆
    var tier1ElapsedMs: Int = 0
    var tier1At: Date? = nil
    var tier1Error: String = ""           // 失敗原因（成功清空）
    var tier1GroundingNote: String = ""   // 接地降級備註（RAG 失敗原因）
    var tier2PromptUser: String = ""      // 含 Tier1 草稿＋接地＋螢幕 OCR
    var tier2RawReply: String = ""
    var tier2GroundingElapsedMs: Int = 0
    var tier2StreamElapsedMs: Int = 0
    var tier2Error: String = ""
    var tier2GroundingNote: String = ""
}

@Model MeetingLiveSegment {               // 逐字稿時間軸 + 偵測 provenance
    var id: UUID = UUID()
    var session: MeetingLiveSession? = nil
    var channelRaw: String = "remote"     // remote | local（local 不抽 cue）
    var text: String = ""                 // committed 原文（= cue 抽取的輸入）
    var committedAt: Date = Date()
    var recentContext: String = ""        // 抽取時帶的滑動窗（目前恆空，照實記錄）
    var extractionModel: String = ""      // 實際 fast model "provider/model"
    var extractionReplyRaw: String = ""   // fast model 原始回覆（誤抓/錯分類的覆盤線索）
    var extractionElapsedMs: Int = 0
    var extractedCount: Int = -1          // -1 = 沒跑抽取（local 段）；0 = 跑了沒抽到
    var dedupDroppedCount: Int = 0        // FR-10 去重丟棄數（dedup 調校訊號）
    var extractionError: String = ""
    var translatedText: String = ""       // [M8] 即時翻譯結果（remote 段；覆盤雙語對照）
    var translationElapsedMs: Int = 0     // [M8]
    var translationError: String = ""     // [M8] 失敗原因（該句 overlay 顯示原文）
}
```

診斷匯出：覆盤頁「匯出診斷 JSON」把整場 session（時間軸＋偵測 provenance＋每則 cue 的
三層 prompt/回覆/耗時/錯誤＋設定快照）dump 成一份 JSON（`MeetingSessionDiagnostics`），
可直接餵給 LLM 做「漏抓／誤抓／答非所問」的調校分析。

陣列欄位沿用 repo 慣例的 **JSON-in-raw-String + `@Transient` 快取**
（`Transcription.swift:76-121` 的 `speakerSegmentsRaw` 即此模式）。

### Migration Strategy

- **Forward**：全新 store 檔案，首次啟動即建立。**每個屬性都有預設值** → SwiftData lightweight migration
  （全 repo 慣例；專案內無 `VersionedSchema` / `SchemaMigrationPlan`）。
- **Backward**：刪除 `meeting.store` 即完全還原，**不影響任何既有資料**。
- **Coexistence**：與 `default.store`、`dictionary.store`、`stats.store`、`index.store` 並存。
- **⚠️ 註冊三處**：新 `@Model` 必須同時加入 `VoiceInk.swift` 的 top-level `Schema`、
  `createPersistentContainer`、`createInMemoryContainer`。**漏任一處 = launch-time crash。**

---

## API Contracts

N/A — VoiceInk 是本機 macOS app，無 HTTP API。本模組觸及的**外部**契約有二：

1. **LLM provider 的 SSE 串流端點**。因 `LLMkit` 為遠端不可編輯的 SPM 套件且 `"stream": false` 寫死，
   本模組在 repo 內自持 `StreamingChatClient`（先例：`Transcription/Cloud/ElevenLabsDiarizingClient.swift`
   為 diarization 同樣繞過 LLMkit 自持 client）。支援兩種 frame 格式：
   - OpenAI-compatible：`data: {...}` SSE，`[DONE]` 收尾（Groq / Cerebras / OpenAI / OpenRouter / Mistral / Ollama / custom）
   - Anthropic：`content_block_delta` 事件流
2. **CoreAudio aggregate device 的聲道佈局**——這是一個**未經實測的隱含契約**，見 Risks。

### 內部契約（結構化 LLM 輸出）

Tier 1 / Tier 2 的輸出**必須是結構化欄位，不是散文**——overlay 才能把 `opener` 以最大字級單獨呈現、
把 `followUps[]` 排成可掃視清單。散文會直接摧毀「五秒內能開口」的設計目標。

---

## Non-Functional Requirements

| Category | Target | Measurement | How Achieved |
|---|---|---|---|
| 即時安全 | realtime thread 零配置／零鎖／零 ARC | code review + `droppedFrames` | 預配置 SPSC ring buffer；consumer 在獨立 Task |
| **Tier 0 延遲** | **< 0.5s** | replay harness | **不呼叫 LLM**——關鍵字表 + 本機 embedding |
| **Tier 1 延遲** | **< 1.5s**；預跑後點擊 **~0s** | replay harness + 實機 | Groq `llama-3.1-8b-instant` + SSE + 最新一則預跑 |
| **Tier 2 延遲** | < 15s | 實機 | 序列啟動，不與 Tier 1 爭頻寬 |
| 轉錄延遲 | 說完 → `.partial` < 1s | replay harness | 本機 FluidAudio（免網路往返） |
| 成本 | 預設零 API 成本轉錄；預跑只用 fast model | — | 本機 FluidAudio；Tier 2 點擊才跑 |
| 隱私 | 逐字稿／答案僅存本機 | — | `meeting.store`，`cloudKitDatabase: .none`；ASR 預設本機 |
| 相容性 | 既有會議 → Obsidian 管線零回歸 | 既有 Meeting* 測試 | 落檔位元組不變 |
| **隱蔽性（失敗時）** | 失敗**不得**產生任何可見系統 UI | 人工驗證 | 無 modal／無通知；只在 overlay 內標紅 |

---

## Technology Choices

| Concern | Choice | Alternatives | Rationale |
|---|---|---|---|
| 講者歸屬 | **聲道分流**（mixToMono 之前切） | 即時 diarization；批次 diarization | 音源結構上已分離且 sample-aligned → **100% 準確、零成本、零延遲**。串流路徑無 speaker 欄位；diarization 與串流互斥且有錯誤率。 |
| **回應速度** | **三層漸進揭露** | 等一個完美答案 | 瓶頸是「開口的頭五秒」。Tier 0 不呼叫 LLM 是因為**任何 LLM 往返都不可能穩定低於 0.5s**。 |
| **Tier 1 輸出** | **結構化開口稿**（opener + 3 bullets） | 散文摘要 | `opener` 讓你**立刻開口**，然後邊講邊讀 bullet。這比換更聰明的模型有用得多，且成本為零（只是 prompt 格式）。 |
| **預跑** | **最新一則 cue 的 Tier 1 自動預跑** | 點擊才跑 | 體感從「等 1.5 秒」變「已經在那了」。fast model 極便宜，全案最划算的體感升級。**此決定推翻了初版的「不預跑」。** |
| cue 偵測 | **抓「需要我回應的東西」+ 四分類** | 只抓問號 | 真實會議中需回應的多是陳述句（「我對效能有點擔心」）。只抓問號會漏掉一半，且漏掉的常是最需要接的。 |
| 答案接地 | brief + **歷史逐字稿 RAG** + 螢幕 OCR | 只靠通用模型知識 | RAG 重用既有 `RetrievalService`（零新基建）。**市售任何 meeting copilot 都沒有你的歷史**——這條護城河是現成的。 |
| 螢幕上下文 | `ScreenCaptureService.captureAndExtractText()`（**OCR 文字**） | 送截圖給多模態模型 | 既有 API 回傳的就是 Vision OCR 後的文字 → 比送圖便宜、快，且不需多模態模型。只在 Tier 2 擷取，不拖慢首字延遲。 |
| 即時 ASR | FluidAudio Parakeet（本機，預設） | Deepgram / Speechmatics / Soniox | 免 API key、免往返、隱私。**取捨：本機 ASR 無術語偏置**（見 Risks）。 |
| LLM 串流 | repo 內自持 `StreamingChatClient` | 改 LLMkit（不可行）；不做串流 | LLMkit 為遠端套件；`ElevenLabsDiarizingClient` 已立先例。不做串流則首字延遲體感差。 |
| Tier 1→2 順序 | **序列**，Tier 2 帶入 Tier 1 草稿 | 並行雙發 | Tier 2 站在草稿上補強而非重跑；使用者滿意即可取消，成本可控。 |
| overlay 召喚 | toggle **+ peek（按住顯示）** 雙熱鍵 | 只有 toggle | peek 貼合「瞄一眼」的動作且不會忘記關掉。沿用既有 push-to-talk 的 keyDown/keyUp 機制。 |
| overlay 定位 | **螢幕上方中央（近鏡頭）** | 角落 | 讀 overlay 時**視線方向接近看鏡頭**；放角落則眼球飄移明顯。零成本，但決定了你看起來像不像在讀東西。 |
| 持久化 | 第 5 個 store `meeting.store` | `default.store` | 不可能破壞使用者逐字稿歷史的 migration；schema 崩壞可整檔刪除重來。先例：`index.store`。 |
| 模組歸屬 | **新模組** meeting-copilot | 擴 recorder-automation | 後者 spec 明文 out of scope streaming/real-time；即時與批次的 bounded context 相反。 |

---

## Integration Points

| Touchpoint | Type | Contract | Backwards Compat |
|---|---|---|---|
| `MeetingCaptureService.handleIO` | 程式碼內嵌 seam | 在 `mixToMono` 前推兩組聲道進 ring buffer；`copilotEnabled == false` 時完全不執行 | **Yes** — 落檔位元組不變 |
| `CoreAudioRecorder` | 抽出共用純函式 `PCMDownsampler` | 行為等價重構 | **Yes** — 既有錄音路徑迴歸測試把關 |
| `AIService` | 新增 `streamChat`，與 `completeChat` 並存 | 加法，不改既有簽章 | **Yes** |
| `RetrievalService`（ask-ai） | **唯讀重用**，不改其實作 | 以 cue 文字檢索 top-k | **Yes** |
| `ScreenCaptureService` | **唯讀重用** `captureAndExtractText()` | 取得分享畫面 OCR 文字 | **Yes** |
| `VocabularyWord` 術語表 | 唯讀重用既有 `getCustomVocabularyTerms()` | **僅雲端 ASR provider 支援**；FluidAudio 無此路徑 | **Yes** |
| `ShortcutAction` 等 4 處 | 新增 toggle + peek 兩個熱鍵 | 標準流程 | **Yes**（並順手修 `.toggleMeetingRecording` 缺失的設定 UI） |
| `ContentView` / `AppSidebar` | 新增 `ViewType.meetingCopilot` | 2 檔 6 處；DEBUG assert 強制側欄涵蓋所有 case | **Yes** |
| `VoiceInk.swift` | 新增 `meeting.store` | 三處註冊 | **Yes** — 不觸及既有 store |
| `RecorderConfigStore.vaultRootBookmark`（M8） | **唯讀重用** | 筆記索引的 vault 位置＝錄音匯出的 vault；不新增 vault 設定 | **Yes** |
| `EmbeddingChunk` / `TranscriptIndexService`（M8） | **寫入**（新 sourceKind `"obsidian"`）＋行為修改 | `reconcileOrphans` 跳過 obsidian chunks；`switchModel` 後筆記重嵌 | **Yes** — 轉錄索引行為不變，僅多保護分支 |
| `TranscriptChunker` / `EmbeddingClient`（M8） | 唯讀重用（純函式） | 筆記切塊與嵌入沿用同一套 | **Yes** |
| 錄音管理詳情頁（M8） | 新增「產生會議copilot覆盤」按鈕 | 逐字稿 → replay 管線 → `sourceRaw:"replay"` session（既有 fingerprint 連動顯示覆盤） | **Yes** |
| `ShortcutAction` 等 4 處（M8） | 新增展開 toggle 熱鍵 | 標準四點註冊流程 | **Yes** |

### Rollout Strategy

`copilotEnabled` 總開關預設 **false**。關閉時 realtime seam 完全不執行、無 ASR、無 LLM、無成本——
即「未啟用時，本模組對既有 app 的行為與效能影響為零」。可隨時關閉作為 kill switch。

---

## Codebase Patterns to Follow

| Pattern | Where to Find | Why Follow |
|---|---|---|
| CoreAudio IOProc 即時紀律 | `Services/Meeting/MeetingCaptureService.swift:73-163` | 新 seam 插在這裡，必須遵守無配置紀律 |
| Float32 → 16k Int16 轉換 | `CoreAudioRecorder.swift:930-1000` | 抽成 `PCMDownsampler` 共用；勿寫第二份 |
| 串流轉錄消費 | `Transcription/Streaming/StreamingTranscriptionService.swift`（`sendAudioChunk` 為 `nonisolated`） | 可直接從 CoreAudio 執行緒餵；格式固定 16k mono Int16 LE |
| 術語表注入串流 ASR | `DeepgramStreamingProvider.swift:32`、`SpeechmaticsStreamingProvider.swift:32`（`getCustomVocabularyTerms()`） | **僅雲端支援**；FluidAudio 無此路徑 |
| 繞過 LLMkit 自持 client | `Transcription/Cloud/ElevenLabsDiarizingClient.swift` | SSE client 沿用同一策略的先例 |
| 可注入 LLM seam | `Services/AskAI/AskAIService.swift:6-8`（`ChatCompleting`） | `StreamingChatCompleting` 鏡射之，供 replay 測試注入 fake |
| RAG 檢索 | `Services/AskAI/RetrievalService.swift`；`AskAIError.indexEmpty` 的降級先例 | 唯讀重用；索引空時靜默跳過 |
| 螢幕 OCR 文字 | `Services/ScreenCaptureService.swift:40`（`captureAndExtractText()`） | 回傳文字非圖片；唯讀重用 |
| 雙模型設定（便宜＋強） | `RecorderConfigStore` 的 classifier/analysis 兩組；UI `RecorderModeSettingsView.swift:69-103` | fast/deep 直接複製此形態 |
| 模型解析純函式＋回退 | `Services/AskAI/AskAIConfig.swift:31-38`（`AskAIAnswerModel.resolve`）；`RecorderPostProcessor.resolvedAnalysisModel` | **必須重新驗證 provider 仍 connected** |
| 浮動 NSPanel | `Views/Meeting/MeetingIndicatorView.swift:39-101` | overlay 的 clone 來源 |
| **按住不放的熱鍵** | `RecordingShortcutManager.swift:68, 234-258, 467, 490`（push-to-talk） | peek 模式沿用其 keyDown/keyUp 分派機制 |
| 新增全域熱鍵（**3 處必要 + 1 處 UI**） | `ShortcutAction.swift`（case + storageName + displayName + **兩份動作清單**：`globalUtilityActions` 決定會不會被監看、`legacyKeyboardShortcutActions` 決定會不會進衝突偵測）/ `ShortcutMigration.swift`（exhaustive switch）/ `RecordingShortcutManager.swift`（分派）＋ **一個能設定它的 UI**（`SettingsView` 或 `MeetingCopilotSettingsView`，擇一即可） | 漏 `ShortcutMigration` 的 exhaustive switch **會編譯失敗**（好事）；漏 `ShortcutAction` 的兩份清單則熱鍵**靜默失效**（註冊了但沒人監看／不做衝突偵測）——這才是真正該小心的一處。**⚠️ 2026-07-14 修正舊說法**：本表原本寫「漏 `SettingsView` 則熱鍵無法設定」——經 grep 核對**不成立**：4 個既有會議熱鍵（`toggleMeetingRecording` / `toggleMeetingCopilotOverlay` / peek / `togglePresenterScript`）**一個都不在 `SettingsView`**，全部只在 `MeetingCopilotSettingsView.hotkeySection`，照樣設得了。M8 的 `toggleCopilotCueExpansion` 是唯一**兩邊都有**的 → 目前 UI 不一致，見 Open Questions |
| 新增側欄頁（2 檔 6 處） | `ContentView.swift:4-26` + `AppSidebar.swift`（title / sections / icon / iconStyle） | DEBUG assert 會抓漏 |
| Notion 式列表頁 | `Views/Library/VoiceLibraryView.swift` | 「會議錄音管理」頁的 clone 來源 |
| JSON-in-raw-String + `@Transient` | `Models/Transcription.swift:76-121`（`speakerSegmentsRaw`） | cue 的陣列欄位照此存 |
| SwiftData 新 store | `index.store`（Ask AI）；`VoiceInk.swift:49-60, 245, 302` | **三處註冊，漏了 launch crash** |
| 純 seam 單元測試 | `VoiceInkTests/MeetingAudioMixerTests.swift` | 本模組的純函式全部照此測 |

---

## Risks & Trade-offs

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **聲道順序切反**（tap-first vs subdevice-first，未經實測） | M | **H** | 實機 probe 為 **Task 1**：靜音 mic、播已知單音、量各聲道 RMS；結果鎖進常數＋單元測試。切反會把「我的話」當「對方的問題」，症狀隱晦。 |
| **喇叭情境 mic 收到對方聲音**（回音污染 local 流） | **H** | M | cue 抽取**只讀 remote 流**（設計上已隔離）。但「我說話時淡出」會被誤觸發 → 需 remote-能量互斥閘門（Open Question）。 |
| **本機 ASR 無術語偏置** → 專案代號轉錯 → cue 抽取失準 | **H** | M | 設定頁**明示取捨**：要術語準確度就選雲端 ASR（術語表已接好）；要免費+隱私就接受轉錯風險。無法兩全。 |
| Tier 0 的關鍵字表品質決定其價值 | M | M | 手寫後端／演算法領域種子表 + 既有 `EmbeddingChunk` 相似度補強，非純字面比對 |
| realtime thread 違反即時紀律 → 爆音／drop | M | H | 預配置 ring buffer；`droppedFrames` 可觀測；既有錄音迴歸測試把關 |
| `sharingType = .none` 在某條擷取路徑失效 | L | **H** — **功能前提破功** | 三情境實機驗證（Teams 原生分享／Meet 分享整螢幕／Meet 分享單一視窗）。任一失敗則需重新評估整個功能。 |
| 裝置切換（`rebuildGraphKeepingFile`）改變 `tapChannelCount` → 聲道錯位 | M | H | splitter 須在 rebuild 後重讀 `tapChannelCount`；列為必測路徑 |
| 預跑 + 三層 + RAG 的 token 成本 | M | M | 預跑只用 fast model 且只跑最新一則；Tier 2 點擊才跑；`prefetchEnabled` 可關 |
| **模型自信地講錯**（比答不出來傷害更大） | M | **H** | system prompt 明確禁止捏造數字／論文／公司名；不確定項須進 `uncertainties[]` 並在 overlay 明顯呈現 |
| 自持 SSE client 的維護負擔 | M | M | 只實作兩種 frame 格式；沿用 `ElevenLabsDiarizingClient` 先例 |
| 🔴 **換 embedding 模型後筆記索引不會重建**（M8 已知缺口，**FR-44 後半未落地**） | **H**（只要換一次模型必中） | **H** — 筆記 RAG **靜默失效** | **目前無防護。** `TranscriptIndexService.switchModel` 刪光**所有** `EmbeddingChunk`（含 obsidian 塊）但**不碰 sidecar state 檔**；`ObsidianNoteIndexService.reindex` 只比對**檔案內容 hash**、不看 `embeddingModel` tag → 下次掃描 hash 全部命中 → **全部跳過** → 筆記塊永遠回不來。更糟的是設定頁的「重建筆記索引」按鈕也是走 `reindex`，會回報「0 檔」看起來一切正常。修法（5 行）：sidecar 存一個 top-level `embeddingModel` 欄位，`loadState()` 發現與現行 `model.tag` 不符 → 整份 state 視為空（= 全量重嵌），語意正好對上「換模型＝向量空間不相容＝全量重嵌」。**須補 AC 與測試**（AC-30 只涵蓋 `reconcileOrphans`） |
| 🟠 **`userBlock()` 的措辭與 aboutMe 的鐵律互相拆台**（M8） | M | M | `MeetingGrounding.userBlock()` 對 RAG 片段寫死標題「我過去的相關逐字稿/筆記（**僅供參考，可能過時**）」，而 aboutMe 的 system prompt 說筆記是「**唯一事實來源**、沒記載就說筆記沒記」——同一個 user message 裡兩種語氣。system 較強，實測未必出事；但若 aboutMe 出現「模型不敢引用筆記／動不動說筆記沒記」的症狀，**這行標題是第一嫌疑**。修法：給 `userBlock()` 一個 aboutMe 變體標題（「我的筆記（我自己寫的，可信）」） |
| 覆盤成本（長錄音的 replay） | M | M | 只用 fast model（抽取＋Tier 1＋sweep），**不進 deep**（`runTier1ForReplay` 的契約）；序列執行、有進度、可取消 |
| auto-deep 的 deep model 成本 | M | M | latest-only（掛在 tier1 之後 → prefetch 的「新 cue 取消舊 prefetch」天然保證只有最新一則走到 deep）；`autoDeepEnabled` 可關；`tier2TriggerRaw`（auto/manual）供事後成本歸因 |

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|---|---|---|---|
| 講者歸屬機制 | 聲道分流（mixToMono 之前切） | 即時／批次 diarization | 音源結構上已分離且 sample-aligned → 100% 準確、零成本。串流路徑無 speaker 欄位，diarization 與串流互斥。 |
| **回應架構** | **三層漸進揭露** | 單一完整答案 | 瓶頸是「開口的頭五秒」，不是答案品質。 |
| **Tier 0 不呼叫 LLM** | 關鍵字表 + 本機 embedding | 小模型 | **任何 LLM 往返都不可能穩定低於 0.5s。** |
| **Tier 1 輸出格式** | 結構化 `opener` + 3 bullets | 散文 | `opener` 讓你立刻開口、邊講邊讀。零成本，效果勝過換更強的模型。 |
| **預跑（翻案）** | **最新一則 cue 的 Tier 1 自動預跑** | 不預跑（初版決定） | 初版為省 token 決定不預跑——**推翻**。fast model 極便宜，而「點擊即有」是最大的體感升級。 |
| cue 而非 question | 抓「需要我回應的東西」+ 四分類 | 只抓問號 | 真實會議需回應的多是陳述句；只抓問號漏掉一半。 |
| 答案接地 | brief + 歷史 RAG + 螢幕 OCR | 通用模型知識 | RAG 重用既有 `RetrievalService`，零新基建；歷史是市售 copilot 沒有的護城河。 |
| 螢幕上下文形式 | OCR **文字** | 截圖給多模態模型 | 既有 `captureAndExtractText()` 回傳的就是文字 → 更便宜、更快、不需多模態。 |
| 螢幕擷取時機 | **只在 Tier 2** | 每個 tier | 不拖慢首字延遲。 |
| 術語表 | 雲端 ASR 才有；**明示取捨** | 假裝兩者都行 | FluidAudio 無偏置路徑，這是真實限制，不應隱瞞。 |
| overlay 召喚 | toggle + **peek（按住）** | 只有 toggle | peek 貼合「瞄一眼」且不會忘記關掉。 |
| overlay 定位 | 螢幕上方中央（近鏡頭） | 角落 | 讀它時視線方向接近看鏡頭。 |
| LLM 串流 | repo 內自持 SSE client | 改 LLMkit（不可行）；不做串流 | 先例 `ElevenLabsDiarizingClient`。 |
| Tier 1→2 順序 | 序列，Tier 2 帶入草稿 | 並行雙發 | Tier 2 站在草稿上補強；可取消，成本可控。 |
| 失敗處理 | **靜默 + 逐層降級** | 跳錯誤視窗 | 分享螢幕時任何 modal／通知都會**暴露本功能的存在**。 |
| 持久化位置 | 第 5 個 store `meeting.store` | `default.store` | 不可能破壞使用者逐字稿歷史的 migration。先例：`index.store`。 |
| 音源抽象 | `MeetingAudioSource` 協定 + replay 實作 | 只測純函式；用真會議測 | 讓**真正要上線的 pipeline** 能在不開會議軟體、不開 CoreAudio 下端到端驗證。 |
| 會後三欄覆盤 | **不做** | 做 | 使用者明確排除（2026-07-12）。 |
| 預設講稿讀稿器（M7）的定位 | **獨立提詞面板**，只顯示使用者自寫文字 | 做成 cue overlay 的一個分頁 | 把「顯示我自己的稿」和「AI 即時代答」綁成同一產品不妥；獨立面板既滿足「看稿＋隨時切回自己的講稿清單」，又與 AI 回應乾淨切割（2026-07-13）。 |
| 讀稿器與 AI 的關係（M7） | **零耦合**：不接 ASR/LLM、不讀 cue、獨立於 `copilotEnabled` | 讓讀稿面板也能吃 AI 生成的答案 | 讀稿器的正當性正建立在「內容是你自己準備的」；一旦餵 AI 即時答案就變成另一回事，明確排除（2026-07-13）。 |
| aboutMe 分類的掛載點（M8） | 掛在**既有** cue 抽取呼叫（五分類＋searchHint 同次輸出） | 獨立分類器呼叫；Tier 0 關鍵字判斷 | 零新增 LLM 往返、零新增延遲；fast model 反正每段都看過全文。 |
| 筆記索引儲存（M8） | **重用 `EmbeddingChunk`**（新 sourceKind），非新表 | 獨立 SwiftData model＋獨立檢索 | 檢索層（scope.sources）零改動即支援；代價是 reconcile/switchModel 兩個地雷，顯式處理並鎖測試。 |
| 筆記 vault 位置（M8） | 重用 `RecorderConfigStore.vaultRootBookmark` | 新增獨立 vault 設定 | 使用者已為錄音匯出設定過 vault；兩個 vault 設定必然漂移。 |
| auto-deep 範圍（M8） | **只有最新 cue**（鏡射 prefetch） | 全部 cue 自動；僅 aboutMe 自動 | deep 成本有界、體感與「自動」無異（使用者 2026-07-13 選定）。 |
| 閱讀保護訊號（M8） | **展開 = 閱讀中**＋toggle 熱鍵 | 明確釘選按鈕；hover 偵測 | 零新手勢；自動展開的結果天然受保護（使用者 2026-07-13 選定，並要求熱鍵）。 |
| 離線覆盤的等同性邊界（M8） | 從**逐字稿之後**重演（分段→抽取→tier） | 重播音訊過 ASR | 錄音筆音訊是混音單聲道，重播 ASR 既無聲道歸屬也無新資訊，只有成本。 |
| 漏抓的呈現（M8） | 覆盤內建 miss sweep＋三層排序 | 只靠「匯出診斷 JSON 餵 LLM」 | 調校迴圈要在 app 內閉環：有回應→無回應→漏抓一眼可掃，diagnostics 匯出仍保留為深度分析出口。 |
| 翻譯實作（M8） | 既有 LLM provider 單句非串流、等 committed | 專用翻譯 API；逐 partial 翻譯 | LLM 天然處理混語（中英混講）；partial 會回改、譯了閃爍浪費。 |
| **漏抓匹配的相似度**（M8 實作階段翻案） | **`max(Jaccard, 包含度)`**，門檻仍 0.6 | 純 bigram Jaccard（原訂） | 純 Jaccard 的分母是聯集 → 對「短改寫 vs 長原句」系統性低估（「請自我介紹」vs「自我介紹一下」= **0.50**、「快取要怎麼設計」vs「怎麼設計快取」= **0.571**，兩者都打不到 0.6）。掃描器與抽取器是**兩次獨立的 LLM 改寫**，長度落差是常態 → 純 Jaccard 會把**已經抓到**的題目報成漏抓。漏抓清單混進假漏抓比漏報更糟：會照著虛高的漏抓率去鬆綁分類 prompt。包含度（交集/較短方）正是在問「短的那句是不是被長的涵蓋」，取 max 保留 Jaccard 對等長句的判斷力（2026-07-14 實作時發現，plan 自己的測試資料就證偽了原訂演算法）。 |
| **replay 的時間軸**（M8） | **合成**：`askedAt = startedAt + index × 錄音長度/段數` | 全部塞同一個 `Date()` | 去重的 30 秒窗**需要時間才有意義**。全塞同一刻 → 時間窗退化成「全場去重」：同一問題在第 3 分鐘與第 40 分鐘各問一次，live 留兩則（兩次都要答）、replay 只留一則 → 兩條路徑不可比，而**可比正是覆盤存在的理由**。用錄音長度均分還原真實節奏（快節奏會議一分鐘十段，30 秒窗內就該看到十段）。 |
| **觀測快照的新欄位型別**（M8） | 一律 **optional** | 非 optional + 預設值 | Swift 合成的 `Decodable` **不套用屬性預設值** → 非 optional 新欄位會讓 M8 之前寫下的**所有**舊快照 decode 整份失敗，`MeetingSessionDiagnostics.build` 退回純文字，舊 session 的變因全變不可讀。`nil` 的語意（「那場會議錄製時還沒有這個設定」）也比硬編一個 `false` 誠實。 |
| **auto-deep 的取消守門**（M8） | `deepTaskCueId` 在 **spawn 當下**即設 + `deepGeneration` 世代序號 | 等 task body 進去才設 | Task 是排程後才跑：中間若另一則 cue 的 tier1 剛好完成，它的保護檢查會看到 `nil` 而**誤取消剛掛出的 deep**。世代序號則解決「被取消的舊 deep 晚一步醒來，抹掉新 deep 的在途標記」——同一則 cue 重跑時 `cue.id` 相同，**只有世代分得出誰是最新那條**。兩者都是真實可觸發的競態，非防禦性編程。 |
| **展開保護 vs 恆顯示最新**（M8，`maxCount == 1` 的邊角） | **閱讀保護優先**（讓位者就是最新那則） | 最新永遠不讓位 | 單格 overlay 本來就只能二選一。「讀到一半整段字消失」正是 M8 要修的痛點，而預設 `maxCuesShown = 5`，實務不觸發。 |
| **模型解析規則的單一來源**（M8） | `MeetingCopilotLiveController.makeStreamingCompleter` 提成 **static**，覆盤與 live 共用 | 覆盤頁自己重寫一份解析 | 兩份必然在「storedModel == nil → 跟隨哪個預設」這種邊角上分岔，覆盤結果就不再與 live 可比。 |

---

## Open Questions

- [ ] **聲道順序：tap-first 還是 subdevice-first？** → 實機 probe，**擋在所有事之前**。
- [ ] Tier 0 的領域關鍵字表從何而來？（手寫種子表 vs 從 `EmbeddingChunk` 自動聚類。傾向：手寫種子 + embedding 補強。）
- [ ] cue 去重的 Jaccard 門檻值？不夠用時是否升級為模型判語意重複？
- [ ] `ResponseCueExtractor` 的滑動窗大小（幾句／幾秒）？需以真實會議逐字稿調校。
- [ ] 「我說話時淡出」的 RMS 門檻在**喇叭情境**下會被對方聲音誤觸發 → 是否需要「remote 有能量時不觸發淡出」的互斥閘門？
- [ ] ~~會前 brief 若選 Obsidian 筆記，如何取得？~~ → **M8 已解**：`ObsidianNoteIndexService` 重用 `RecorderConfigStore.vaultRootBookmark`（不新增 vault 設定）。
- [ ] 裝置切換時 `tapChannelCount` 變動的完整處理路徑。

### M8 收尾待辦（2026-07-14 code-sync 發現）

- [ ] 🔴 **修 `switchModel` 後筆記索引不重建**（見 Risks 第一列）——sidecar state 加 `embeddingModel` 欄位，tag 不符即全量重嵌；補 AC + 測試。**這是 FR-44 明文要求但未落地的一半，且失效是靜默的。**
- [ ] 🟠 **`userBlock()` 的 aboutMe 變體標題**（見 Risks 第二列）——現行措辭與「筆記是唯一事實來源」互相拆台。
- [ ] 熱鍵設定 UI 的一致性：`toggleCopilotCueExpansion` 是**唯一**同時出現在 `SettingsView` 與 `MeetingCopilotSettingsView` 的會議熱鍵。要嘛把其餘 4 個也補進 `SettingsView`，要嘛把這一列從 `SettingsView` 拿掉。（不影響功能，純 IA。）
- [ ] `EmbeddingChunk.sourceKind` 的 doc comment 仍寫「dictation | recorder | meeting」，漏了 M8 的 **obsidian**（`AskAIModels.swift:22`）。
- [ ] aboutMe 的 `searchHint` 改寫品質是否需按細類（貢獻／成就／經驗）調校 → 先收覆盤資料再定。
- [ ] 大 vault（>5k 檔）首次全量索引的 rate limit 體驗（backfill 進度 UI 已有前例）。
- [ ] 翻譯字幕在長會議的 overlay 高度／捲動策略（目前固定顯示最近 4 句、feed 留 20 句）。
- [ ] **人工 gate 未跑**：真模型的 aboutMe 品質、離線覆盤的漏抓率、翻譯體感、`make deploy` 實機驗證。
