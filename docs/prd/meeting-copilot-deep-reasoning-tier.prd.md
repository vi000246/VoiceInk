---
linear_issue: null
---
# 會議 Copilot：三階段回答 + 深思模型分級（deep-reasoning-tier）

> 產品層 PRD，不含架構／資料表／API 細節（那些留給 SRS）。

## Problem Statement

會議 copilot 目前是「開口稿（快模型）→ 深度分析（深模型）」兩段式，但使用者**快、深兩層都設成 gemini flash**——因為深度分析他能接受的等待上限只有 ~5 秒、開口稿要 <1 秒。結果是：所謂「深度分析」只是一顆跑久一點的 flash，**沒有真正的推理增量**（多方案取捨、多步推導、架構/演算法決策一律淺答）。要嘛忍受淺答，要嘛把深模型換成慢的推理模型、卻拖垮每一則的即時性。核心矛盾：**即時性與思考深度被綁在同一顆模型上，只能二選一。**

## Evidence

- 使用者自述（2026-07-16 對談）：快深都用 gemini flash；深模型可接受 5 秒、快模型 1 秒內；「這樣回答沒什深度」。
- 現況程式：`AnswerCoordinator` 的 Tier 2 走 `deepModel`，但 `MeetingCopilotConfigStore` 的 fast/deep 兩個 model 若都指向 flash，Tier 2 與 Tier 1 只差 prompt 長度，無推理差異。
- 會議即時性第一原則（module spec）：瓶頸是「開口的頭五秒」。任何真正的推理模型（10–30s）**不可能**是開口前要讀的東西——但它對「預判追問、可拖延的難題、會後覆盤」極有價值。這要求把「即時」與「深思」拆成不同延遲預算、不同模型。

## Proposed Solution

把回答拆成**三階段**、把模型拆成**兩顆**、把最貴的那顆用**閘門**只在需要時放行：

1. **開口稿**（<1s，即時模型）＝現 Tier 1，照唸一句 + 3 bullets。
2. **中度分析**（~5s，即時模型）＝現 Tier 2 的角色，但改吃即時模型；開口稿完成後**恆自動接續**（不可關）。
3. **深度分析**（10–30s，深思模型）＝**新增**，跑真正的推理模型；**永不阻擋**前兩段，晚點串流進來、掛「● 分析完成」徽章（複用既有機制）。

模型下拉從「快 / 深」整併為：**即時模型**（cue 抽取＋開口稿＋中度分析共用）＋**深思模型**（僅深度分析）。

深度分析兩種**觸發模式**（是模式，不是兩顆模型）：
- **自動**：中度分析**順手自評**這題需不需要複雜推理（`needsDeep`）；判定需要就**自動發起**深度分析（你不用動手），此時「深入」按鈕暫時 disabled（深答已在跑）。
- **手動**：只有你按「深入分析」按鈕才跑。手動按鈕在**兩種模式下都存在**——自動模式只是多了自動放行。

為何是這個做法：即時性由前兩段（同一顆 flash）承載、成本可控；貴的推理模型只在「這題真的難」時才燒，且它的慢天生被「晚到 + 徽章」的 UX 吸收，不傷即時體驗。判斷「難不難」交給一顆**已經看過完整接地、且試答過一次**的模型（中度分析）順手產出，**零額外 LLM 呼叫**。

## Key Hypothesis

我們相信「把即時與深思拆成兩顆模型、深思只在智慧閘門放行時才跑」能讓使用者**同時**得到 <1s 的開口稿與真正有推理增量的深度分析，而不必在兩者間二選一。
當使用者實際把深思模型設成推理模型（而非 flash）、且**多數 cue 只跑到中度、少數難題才自動升級**、深度分析的品質足以應付現場追問時，即驗證成功。

## What We're NOT Building

- **第三顆模型 / 兩顆深思模型**——深度分析只有一顆深思模型，「自動/手動」是**觸發模式**不是模型。
- **中度分析可關的開關**——中度分析恆自動接續（使用者明確表示不需要可關）。
- **並行提早起跑深度分析**（t=0 就判斷、與開口稿並行）——判斷落點採「中度順手吐 `needsDeep`」（較準、零額外呼叫），不做 t=0 並行版（見 Decisions Log）。
- **可調的深思延遲上限 / 逐 tier 的獨立語言/風格再拆設定**——沿用既有 outputLanguage / deepStyle。

## Success Metrics

| Metric | Target | How Measured |
|--------|--------|--------------|
| 深度分析的推理增量 | 難題的深答明顯優於中度（多方案/推導/決策），非只是更長 | 覆盤頁抽查中度 vs 深度同一 cue |
| 自動閘門精準度 | 多數 cue 停在中度；只有真正需要推理的題自動升級 | 覆盤統計 `needsDeep=true` 比例與抽查誤判 |
| 即時性不退化 | 開口稿 <1s、中度 ~5s（與現況相同） | 現有 tier1/tier2 ElapsedMs 觀測欄位 |
| 成本可控 | 深思模型只在放行時被呼叫 | 覆盤 `tier3TriggerRaw` 分佈（auto/manual/image） |

## Open Questions

- [ ] 深思模型的預設具體型號：`gemini-2.5-pro`（ReasoningConfig 認得為 thinking、且支援視覺、使用者已有 Gemini key）為建議預設；是否改用更新的 `gemini-3.1-pro-preview`？→ SRS/實作時定，預設保守取 2.5-pro。
- [ ] 深度分析觸發的**預設模式**：自動 vs 手動。傾向**自動**（使用者要的是「有深度」且不想手動；成本已被閘門壓住）。
- [ ] 中度分析的 `needsDeep` 判準寫進 prompt 的門檻鬆緊（過鬆＝每題都升級燒錢；過嚴＝難題漏升級）→ 實測校準。

---

## Users & Context

**Primary User**
- **Who**: 使用者本人——會議中即時被問技術問題、需要當場有深度回應、本 fork 維護者。
- **Current behavior**: 快深都用 flash，深度分析沒深度；不敢換慢模型怕拖垮即時。
- **Trigger**: 會議中被問到一題需要真正推理/取捨的難題。
- **Success state**: 開口稿 <1s 讓他先接話、中度 ~5s 補要點，難題的深度分析晚幾秒自動補上、標徽章，他用來接招追問。

**Job to Be Done**
當我在會議中被問到難題，我想要先有能立刻照唸的開口稿、幾秒內的要點，再由一顆真正會推理的模型補上深度分析，這樣我不必在「即時」與「有深度」之間二選一。

**Non-Users**
不需要深度分析、只要開口稿的輕量使用者（他們把深度分析觸發設手動、且不按即可）。

---

## Solution Detail

### Core Capabilities (MoSCoW)

| Priority | Capability | Rationale |
|----------|------------|-----------|
| Must | 三階段回答：開口稿 → 中度分析（恆自動）→ 深度分析（閘門） | 產品核心，拆開即時與深思 |
| Must | 模型下拉整併：即時模型（開口稿＋中度）＋深思模型（深度），深思預設推理型號 | 兩顆模型是拆開延遲預算的載體 |
| Must | 深度分析自動閘門：中度順手吐 `needsDeep`，自動模式據此發起 | 貴模型只在需要時燒 |
| Must | 深度分析手動按鈕（兩模式恆存在）；自動發起時按鈕暫 disabled | 使用者可強制深入；避免重複觸發 |
| Must | 截圖深答改接深度分析（深思模型＋多模態） | 視覺＋推理是典型難題，本就該走深思 |
| Must | 修正本輪截圖/panic 已知缺陷（成功判定、在途保護、視覺閘門、panic 還原） | 已被對抗式 review 確認、可重現 |
| Should | 覆盤頁顯示中度 vs 深度、`needsDeep`/觸發來源 | 校準閘門與品質歸因 |
| Won't | 第三顆模型、中度可關、t=0 並行深答 | 見 NOT Building |

### MVP Scope

Must 全部：三階段 + 兩模型 + 自動/手動閘門 + 截圖深答改接深度。缺陷修正併同本 milestone（同一段程式被重寫）。

### User Flow

會議中被問一題 → 開口稿 <1s 冒出（照唸）→ 中度 ~5s 補要點、同時自評 needsDeep → 自動模式且判定需要（或你按深入鈕）→ 深度分析用深思模型跑 → 10–30s 後串流完成、標「● 分析完成」→ 你用它接招追問。對方分享圖表要你分析時：按截圖熱鍵累積畫面 → 按「以截圖重新深答」→ 深思模型帶圖重跑深度分析。

---

## Feasibility

**Verdict**: HIGH — 三階段是把現有 Tier 1/2 重新分工 + 新增 Tier 3，複用既有的 SSE 串流、接地、latest-only 取消、展開保護、未讀徽章、reasoning_effort 注入（`ReasoningConfig` 已支援 gemini-2.5-pro / gpt-5.x）與本輪已建的多模態管線。無新外部依賴、無 sandbox 障礙。主要工作量在 `AnswerCoordinator` 的重構與 config/UI 的模型整併。

> 架構、資料表、API 契約、技術風險細節屬 SRS：`docs/srs/meeting-copilot-m10-deep-reasoning-tier.srs.md`。

---

## Product Milestones

| # | Milestone | User-Visible Value | Status | Depends | SRS | Plan |
|---|-----------|--------------------|--------|---------|-----|------|
| M10 | 三階段回答 + 深思分級 | 開口稿/中度即時不變；難題由真推理模型自動或手動補上深度分析；截圖深答走深思 | planned | M3/M8/M9（tier 引擎、auto-deep、閱讀保護） | docs/srs/meeting-copilot-m10-deep-reasoning-tier.srs.md | docs/plans/meeting-copilot-m10-deep-reasoning-tier.plan.md |

### Milestone Details

**M10: 三階段回答 + 深思分級**
- **User can now**: 即時模型跑開口稿＋中度、深思模型只在智慧閘門放行時跑深度分析；截圖深答走深思模型。
- **Success signal**: 一週實際會議中，多數 cue 停在中度、少數難題自動升級且深答有增量；即時性未退化。
- **Out of scope for this milestone**: 第三顆模型、中度可關、t=0 並行深答。

> Note: 技術分期與並行度在 **SRS**；實作任務在 **Plan**；本 PRD 只捕捉產品價值排序。

---

## Decisions Log

| Decision | Choice | Alternatives | Rationale |
|----------|--------|--------------|-----------|
| 即時/深思拆兩顆模型 | 採用 | 單顆模型調 prompt | 即時與深思的延遲預算天生不同，綁一顆只能二選一 |
| 深度分析判斷落點 | 中度順手吐 `needsDeep` | t=0 抽取時判斷／獨立分類呼叫 | 零額外呼叫、由試答過的模型判斷最準；晚 5s 起跑無所謂（深答本就慢） |
| 觸發語意 | 自動/手動兩模式，手動鈕恆存在 | 只自動／只手動 | 自動省事、手動保留控制；兩者不互斥 |
| 中度是否可關 | 不可關，恆自動接續 | 做成開關 | 使用者明確表示不需要；中度便宜（即時模型） |
| 深思預設型號 | `gemini-2.5-pro` | gemini-3.1-pro-preview / 留空 | 使用者已有 Gemini key；ReasoningConfig 認得為 thinking 且支援視覺；非 preview 較穩 |
| 截圖深答接哪層 | 深度分析（Tier 3） | 維持中度（Tier 2） | 視覺＋複雜推理是典型難題，本就該用深思模型 |
| 本輪缺陷修正時機 | 併入 M10 | 另開 hotfix | 同一段程式（截圖深答/tier 管線）被 M10 重寫，一併修最省 churn |

---

## Research Summary

**Market Context**
即時會議 copilot（Cluely 類）的公認難點正是「深度 vs 即時」：多數產品用單一快模型換即時、犧牲深度。把深思拆成閘門化的第二顆模型是明確的品質差異化，且成本可控（只在難題燒）。

**Technical Context**
複用面在 2026-07-16 recon 確認：`ReasoningConfig` 已對 gemini-2.5-pro / gpt-5.x 注入 thinking 參數；latest-only 取消、展開保護（FR-54）、未讀徽章（FR-51）、SSE 串流、多模態管線（本 session 已建）皆可直接承接到新的 Tier 3。唯一新工程是 `AnswerCoordinator` 的三段重構與 config/UI 的模型整併。

---

*Generated: 2026-07-16*
*Status: DRAFT - needs validation*
*Source Linear Issue: N/A — standalone（`docs/prp.config.yml` → skip: true）*
