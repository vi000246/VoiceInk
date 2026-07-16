import SwiftUI

/// 隱蔽 overlay 的內容(FR-26)。繁中字面,不進 xcstrings(近期新頁面慣例)。
///
/// 三層漸進渲染(M3 回寫在 `MeetingLiveCue` 的欄位):
///   Tier 0 關鍵字(tier0Keywords) → Tier 1 opener + 3 bullets → Tier 2 analysis + followUps + uncertainties。
struct CopilotOverlayView: View {
    @ObservedObject var controller: MeetingCopilotController
    /// 即時翻譯字幕源(M8 FR-62)。由 `CopilotOverlayWindowManager` 從 controller 取出後注入。
    ///
    /// optional 而非 `@ObservedObject`:live pipeline 之外(預覽/未接翻譯器)沒有 translator,
    /// 而 `@ObservedObject` 不吃 optional。真正的觀察包在 `TranslationFeedLines` 子視圖裡——
    /// 只有「有 translator」時才建立那個子視圖,feed 更新照樣即時重繪。
    var translator: MeetingLiveTranslator?
    @ObservedObject private var config = MeetingCopilotConfigStore.shared
    /// 已錄時長。錄製列上本來就有,但開會時眼睛在 overlay 上 —— 錄了多久這件事
    /// 要在你正在看的那個視窗裡看得到,否則「忘了關」根本不會被發現。
    @ObservedObject private var capture = MeetingCaptureController.shared
    /// 翻譯字幕展開狀態的來源(Stage B):展開鈕與 `.toggleTranslationExpansion` 熱鍵共用。
    @ObservedObject private var overlayManager = CopilotOverlayWindowManager.shared
    /// 點「深度分析」→ 觸發 Tier 2(接 M3 AnswerCoordinator;click-through 開啟時自然不會觸發)。
    var onCueTapped: ((MeetingLiveCue) -> Void)?
    /// 點「以截圖重新深答」→ 帶累積的截圖重跑 Tier 2(手動視覺;走 requestDeepWithImages)。
    var onImageDeepRequested: ((MeetingLiveCue) -> Void)?
    /// 截圖佇列(截圖深答)。overlay 觀察它顯示張數徽章與按鈕。
    @ObservedObject private var screenshots = CopilotScreenshotStore.shared

    /// 手風琴:使用者手動展開的 cue(`controller.expandedCueId`;nil = 自動展開最新一則)。
    /// 面試官連問兩題時,可點任一題展開、其餘自動收成單行;新題進來仍排最上,
    /// 但不會搶走使用者正在回答的那一題的展開狀態。
    ///
    /// 狀態住在 controller 而非 view 的 `@State`:AnswerCoordinator 的取消判斷與
    /// auto-expand 也要讀「使用者現在在讀哪一則」(AC-37)。
    private var arranged: [(cue: MeetingLiveCue, emphasis: CopilotOverlayEmphasis)] {
        CopilotOverlayArranger.arrange(
            controller.cues,
            askedAt: { $0.askedAt },
            isAnswered: { $0.status == .answered },
            maxCount: config.maxCuesShown,
            // 展開中的那則不被 maxCount 擠出——讀到一半整段消失是 M8 要修的痛點。
            pinnedId: controller.expandedCueId,
            id: { $0.id })
    }

    /// 實際展開者:手動選擇優先(且仍在列表上);否則最新一則。
    private var effectiveExpandedId: UUID? {
        if let id = controller.expandedCueId, arranged.contains(where: { $0.cue.id == id }) { return id }
        return arranged.first?.cue.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            gripBar
            shareWarningBanner
            // M8 FR-62:翻譯開啟時,上區是對方原話的譯文、下區才是「我要開口說的話」。
            // **區隔本身就是需求**:兩種內容混在一起時,現場那一秒根本分不出哪一句是要我唸的
            // (譯文是別人的話,照唸就答非所問)。所以這裡不只是多幾行字,而是加一條分界線
            // 與兩個小標,把 overlay 明確切成「聽到什麼」與「怎麼回」。
            //
            // 翻譯關閉(預設)→ 整段不渲染:沒有小標、沒有分隔線,佈局與 M8 之前**完全相同**。
            if config.liveTranslationEnabled, let translator {
                translationHeader
                TranslationFeedLines(translator: translator, expanded: overlayManager.translationExpanded)
                Divider().padding(.vertical, 2)
                sectionHeader("問題與回應")
            }
            // cue 列表可捲動:文字全面換行後,長分析可能超出卡片高度上限。
            // 把手與警告條留在捲動區外,拖曳手勢才不會和捲動打架。
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    if arranged.isEmpty {
                        Text("等待對方提問…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        let expandedId = effectiveExpandedId
                        ForEach(Array(arranged.enumerated()), id: \.offset) { _, item in
                            if item.cue.id == expandedId {
                                focusCard(item.cue)
                            } else {
                                collapsedRow(item.cue)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)   // 內容少時卡片跟著縮,不留空白
        }
        .padding(14)
        // 寬度由 panel 決定(≈ 螢幕寬 1/3,見 CopilotOverlayWindowManager.hostSize)。
        .frame(maxWidth: .infinity, alignment: .leading)
        // 深色實心底 + 白字高對比(使用者要求:不透明、不跟隨系統淺色主題)。
        // 不用 material——material 半透明,底下畫面透出來會降低可讀性。
        .background(Color(red: 0.09, green: 0.10, blue: 0.12), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .environment(\.colorScheme, .dark)   // .primary/.secondary 一律解析成淺色
        // 整窗拖曳:點任一空白/邊框/標題處都能拖(ScrollView 捲動、cue 點擊、深度分析仍優先)。
        .contentShape(Rectangle())
        .floatingWindowDrag(
            currentOrigin: { CopilotOverlayWindowManager.shared.panelOrigin },
            setOrigin: { CopilotOverlayWindowManager.shared.setPanelOrigin($0) })
    }

    // MARK: - 拖曳把手(視覺提示;實際拖曳由整窗 floatingWindowDrag 處理)

    private var gripBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .semibold))
            Text("會議輔助").font(.system(size: 10, weight: .semibold))
            Spacer()
            // 截圖佇列張數:按了截圖熱鍵後在這裡即時 +1,是 overlay 顯示時唯一的截圖回饋
            // (隱藏時刻意無聲、無通知,不暴露本功能——與誠實邊界的取捨一致)。
            if screenshots.count > 0 {
                Label("\(screenshots.count)", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                    .help("已截 \(screenshots.count) 張,展開任一題按「以截圖重新深答」送出")
            }
            if capture.isRecording {
                // 等寬數字:每秒跳動時字不會左右抖。
                Text(capture.elapsedText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            // 關閉浮動視窗:只 hide + 取消釘住,live pipeline(轉錄/AI/翻譯)照跑,
            // 可再從 Live Pill、選單或熱鍵叫回。用 hideAndUnpin 而非 toggle——關閉的
            // 語意就是「無條件收起」,不該因狀態而意外重開。
            Button {
                CopilotOverlayWindowManager.shared.hideAndUnpin()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("關閉即時輔助視窗（可再從錄製列或熱鍵開啟）")
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 區塊小標(M8 FR-62)

    /// 小標。字級/字重/色彩沿用 overlay 既有的次要標題語言(gripBar 的「會議輔助」、
    /// focusCard 的「可能追問」)——新的區塊分隔不該長得像另一個 app。
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// 即時翻譯區塊的標題列 + 展開鈕(Stage B)。按鈕在標題列 —— 也就是字幕行的**上方**,
    /// 展開字幕(5→30 句)時字幕往下長,標題列位置不動,所以按鈕位置固定、可原地 toggle。
    /// 與 `.toggleTranslationExpansion` 熱鍵共用同一個入口。
    private var translationHeader: some View {
        HStack(spacing: 6) {
            sectionHeader("即時翻譯")
            Spacer()
            Button {
                CopilotOverlayWindowManager.shared.toggleTranslationExpansion()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: overlayManager.translationExpanded ? "chevron.up" : "chevron.down")
                    Text(overlayManager.translationExpanded ? "收合" : "最近 30 句")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(overlayManager.translationExpanded ? "收合翻譯(回最近 5 句)" : "展開翻譯(最近 30 句)")
        }
    }

    // MARK: - 常駐螢幕分享警告(誠實邊界,不得省略)

    private var shareWarningBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.shield.fill").font(.system(size: 9))
            Text("分享「整個螢幕」時此視窗會被錄到——請只分享單一視窗/分頁")
                .font(.system(size: 9))
        }
        .foregroundStyle(.orange)
        .lineLimit(2)
    }

    // MARK: - 單則 cue

    /// 收合列:點擊 = 展開這一題(手風琴——其餘自動收合)。已回答者更淡。
    private func collapsedRow(_ cue: MeetingLiveCue) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(cue.text)
                .font(.system(size: 12, weight: cue.status == .answered ? .regular : .medium))
                .foregroundStyle(cue.status == .answered ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .lineLimit(2)   // 收合列保持精簡,但至少讓長問題看得出在問什麼
                .fixedSize(horizontal: false, vertical: true)
            // FR-51:auto-deep 在背景跑完、但你當時在讀別則 → 這裡是唯一的線索,
            // 沒有徽章的話,那份分析等於不存在(不會有人去逐則點開碰運氣)。
            if controller.unreadDeepCueIds.contains(cue.id) {
                Spacer(minLength: 6)
                Text("● 分析完成")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))   // 同 tier0/深度分析的亮藍
                    .fixedSize()          // 長 cue 也不得把徽章擠到換行/截斷
                    .layoutPriority(1)
            }
        }
        .contentShape(Rectangle())
        // 走 expand(cueId:) 而非直接寫 expandedCueId——未讀標記只在那裡清除。
        .onTapGesture { controller.expand(cueId: cue.id) }
    }

    /// focus cue:opener 最大字級單獨呈現(FR-26 的核心——讓你能直接照著念)。
    @ViewBuilder
    private func focusCard(_ cue: MeetingLiveCue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // cue 原句 + Tier 0 關鍵字
            Text(cue.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)   // 展開的問題全文換行,不截斷
            if !cue.tier0Keywords.isEmpty {
                Text(cue.tier0Keywords)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))   // 深底上可讀的亮藍
            }

            // Tier 1:開口稿(最大字級)+ 3 bullets
            if !cue.tier1Opener.isEmpty {
                Text(cue.tier1Opener)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(cue.tier1Bullets.filter { !$0.isEmpty }, id: \.self) { b in
                    Label(b, systemImage: "circle.fill")
                        .font(.system(size: 12))
                        .labelStyle(BulletLabelStyle())
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("準備開口稿中…").font(.system(size: 12)).foregroundStyle(.secondary)
            }

            // 中度分析(Tier 2,即時模型):有就渲染。它是即時漸進的一部分(像開口稿),不掛未讀徽章。
            if !cue.tier2Analysis.isEmpty {
                Divider()
                Text("中度分析").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(cue.tier2Analysis)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                if !cue.tier2FollowUps.isEmpty {
                    Text("可能追問").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(cue.tier2FollowUps, id: \.self) { f in
                        Text("· \(f)").font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !cue.tier2Uncertainties.isEmpty {
                    ForEach(cue.tier2Uncertainties, id: \.self) { u in
                        Label(u, systemImage: "questionmark.circle")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }

            // 深度分析(Tier 3,深思模型;閘門化)
            deepSection(cue)

            imageDeepControls(cue)
        }
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    /// 深度分析(Tier 3,深思模型)區:有結果就渲染;在途顯示 spinner(等同按鈕 disabled);
    /// 否則(可深答時)顯示「深入分析」按鈕(觸發 requestDeep;needsDeep 時附建議原因)。
    @ViewBuilder
    private func deepSection(_ cue: MeetingLiveCue) -> some View {
        if !cue.tier3Analysis.isEmpty {
            Divider()
            HStack(spacing: 4) {
                Image(systemName: "brain").font(.system(size: 9))
                Text("深度分析").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
            Text(cue.tier3Analysis)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            if !cue.tier3FollowUps.isEmpty {
                Text("可能追問").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(cue.tier3FollowUps, id: \.self) { f in
                    Text("· \(f)").font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !cue.tier3Uncertainties.isEmpty {
                ForEach(cue.tier3Uncertainties, id: \.self) { u in
                    Label(u, systemImage: "questionmark.circle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        } else if controller.deepInFlightCueId == cue.id {
            // 深度分析在跑(深思模型推理)。in-flight 走這條 = 按鈕不出現 = 等同 disabled(FR-77/AC-62)。
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("深度分析中…（深思模型推理，約需十餘~數十秒）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        } else if cue.kind != .aboutMe, cue.kind != .informational {
            // 「深入分析」按鈕:觸發 Tier 3(onCueTapped → AnswerCoordinator.requestDeep)。
            // aboutMe / informational 不進深度分析(deepEligible),不渲染死鈕。
            // 自動模式下 needsDeep 的題通常已自動跑掉;手動模式、或自動判定不需要時,這裡讓你手動深入。
            VStack(alignment: .leading, spacing: 2) {
                Text("▶ 深入分析")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                    .contentShape(Rectangle())
                    .onTapGesture { onCueTapped?(cue) }
                if cue.mediumNeedsDeep, !cue.mediumDeepReason.isEmpty {
                    Text("建議深入：\(cue.mediumDeepReason)")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
        }
    }

    /// 截圖深答的控制(手動視覺):只有累積了截圖才出現「以截圖重新深答」;錯誤時顯示可關閉橫幅。
    @ViewBuilder
    private func imageDeepControls(_ cue: MeetingLiveCue) -> some View {
        // aboutMe / informational 不進深度分析 → 不顯示截圖深答鈕(否則點了只會跳「不適用」)。
        if screenshots.count > 0, cue.kind != .aboutMe, cue.kind != .informational {
            Button {
                onImageDeepRequested?(cue)
            } label: {
                Label("以截圖重新深答（\(screenshots.count) 張）", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1.0))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(controller.deepInFlightCueId == cue.id)   // 深答進行中不重複觸發
            .help("把累積的截圖連同這題送給深答模型重新分析（會覆蓋上面的文字深答，需視覺模型）")
        }
        if let err = controller.imageDeepError {
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
                Text(err).font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button { controller.imageDeepError = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.orange)
        }
    }
}

/// 翻譯字幕的最近幾句(M8 FR-62)。
///
/// 獨立成子視圖的唯一理由:`@ObservedObject` 不接受 optional,而 translator 只有 live 路徑才有。
/// 把觀察關進「有 translator 才會被建立」的子視圖,父層就能維持 optional 注入,
/// 又不失去 `feed` 變動時的即時重繪。
/// 一行可顯示的字幕(committed 定稿或 provisional 在途)。
private struct TranslationDisplayLine: Identifiable, Equatable {
    let id: UUID
    let text: String
    /// 正在講、還沒定稿(顯示得淡一點,示意「還會變」)。
    let provisional: Bool
}

private struct TranslationFeedLines: View {
    @ObservedObject var translator: MeetingLiveTranslator
    /// 收合 = 最近 5 句;展開 = 最近 30 句(可捲動)。
    let expanded: Bool

    /// committed 字幕(依 committedAt 遞增,**舊在前**)+ 最下方的 provisional(正在講、未定稿)。
    /// 舊在上、新在下(使用者指定的字幕方向);取尾 N 句。
    private var lines: [TranslationDisplayLine] {
        var out = translator.feed.map {
            TranslationDisplayLine(id: $0.id, text: $0.translated, provisional: false)
        }
        if let p = translator.provisional {
            out.append(TranslationDisplayLine(id: p.id, text: p.translated, provisional: true))
        }
        return Array(out.suffix(expanded ? 30 : 5))
    }

    var body: some View {
        if expanded {
            // 展開最近 30 句 → 捲動區(高度上限,不擠掉下面的問題與回應),自動貼齊最新那行。
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    rows.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .onChange(of: lines.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: lines.last?.text) { _, _ in
                    if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onAppear {
                    if let id = lines.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        } else {
            rows.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 自帶 VStack(而不是把 ForEach 攤進父層):父層 spacing 是 10pt,那是**區塊之間**的節奏;
    /// 字幕行與行是同一段連續的話,要 4pt 緊密行距才讀得像一段字幕。
    /// 譯文優先於原文:看得懂的那一份才有用;翻譯失敗時 `translated` 本來就等於原文。
    private var rows: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(size: 12))
                    .foregroundStyle(line.provisional ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .opacity(line.provisional ? 0.75 : 1)   // 在途譯文淡一點:示意「還會變」
                    .lineLimit(2)   // 長句截尾,不讓字幕把下面的開口稿擠出畫面
                    .fixedSize(horizontal: false, vertical: true)
                    .id(line.id)
            }
        }
    }
}

private struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(.secondary)
            configuration.title
        }
    }
}
