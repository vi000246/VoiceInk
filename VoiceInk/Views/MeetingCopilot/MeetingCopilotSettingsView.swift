import SwiftUI
import SwiftData

/// 「會議即時輔助」設定(FR-30)。clone `RecorderModeSettingsView` 的 Form + Binding 模式。
/// 繁中字面;config 的 @Published 是 private(set),每個控制項用 `Binding(get:set:)` 包。
/// 獨立側欄頁(位於「錄音設定」之下);「會議錄音管理」頁的齒輪也導覽到這裡。
struct MeetingCopilotSettingsView: View {
    @StateObject private var store = MeetingCopilotConfigStore.shared
    @StateObject private var scriptStore = PresenterScriptStore.shared
    @StateObject private var packStore = MeetingPackConfigStore.shared
    @StateObject private var ledgerStore = CommitmentLedgerConfigStore.shared
    /// 會後包子資料夾的編輯草稿(失焦/送出才寫回,避免打字中被空值正規化蓋掉)。
    @State private var packSubfolderDraft: String = ""
    @EnvironmentObject private var aiService: AIService
    @Environment(\.modelContext) private var modelContext

    /// 講稿編輯 sheet 的暫存(nil = 未開啟)。
    @State private var scriptDraft: ScriptDraft?

    /// 分頁(M8 Task 19)。設定項一路長到八個 Section,把「即時翻譯」再堆上去只會讓整頁
    /// 更難掃;翻譯是**獨立的一條管線**(自己的模型、自己的語言、自己的成本),分頁比 Section 誠實。
    private enum SettingsTab: String, CaseIterable {
        case general = "一般"
        case prompt = "Prompt"
        case translation = "即時翻譯"
        case detection = "會議偵測"
        case pack = "會後包"
    }

    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "會議copilot設定",
                infoMessage: "開會時偵測對方提出的問題,在浮動視窗給你可直接開口的回應建議。快捷鍵、回應模型、答案接地與浮動視窗行為都在這裡設定。",
                infoURL: nil
            ) { EmptyView() }

            HStack(spacing: 10) {
                Picker("分頁", selection: $tab) {
                    ForEach(SettingsTab.allCases, id: \.self) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            switch tab {
            case .general: generalForm
            case .prompt: promptForm
            case .translation: translationForm
            case .detection: MeetingDetectionSettingsView()
            case .pack: meetingPackForm
            }
        }
    }

    // MARK: - 一般分頁(M8 Task 19 純搬移:Section 內容與 binding 一字未改)

    private var generalForm: some View {
        Form {
            enableSection
            asrSection
            modelSection
            groundingSection
            notesRAGSection
            commitmentLedgerSection
            presetScriptsSection
            overlaySection
            screenshotSection
            hotkeySection
        }
        .formStyle(.grouped)
        .sheet(item: $scriptDraft) { draft in
            ScriptEditorSheet(
                draft: draft,
                onSave: { title, body in
                    if draft.isNew { scriptStore.add(title: title, body: body) }
                    else { scriptStore.update(id: draft.id, title: title, body: body) }
                    scriptDraft = nil
                },
                onCancel: { scriptDraft = nil })
        }
    }

    // MARK: - Sections

    private var enableSection: some View {
        Section {
            Toggle("啟用會議即時輔助", isOn: bind(\.copilotEnabled, store.setCopilotEnabled))
            Text("開會時偵測對方提出的問題,並給你可直接開口的回應建議。關閉時對 app 完全零影響。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var asrSection: some View {
        Section("即時轉錄") {
            Picker("轉錄模型", selection: asrModelBinding) {
                ForEach(streamingModels, id: \.name) { m in
                    Text("\(m.displayName)（\(m.provider.rawValue)）").tag(m.name)
                }
            }
            Picker("語言", selection: asrLanguageBinding) {
                ForEach(asrLanguageOptions, id: \.key) { option in
                    Text(option.value).tag(option.key)
                }
            }
            Toggle("同時轉錄我的麥克風", isOn: bind(\.transcribeLocalMic, store.setTranscribeLocalMic))
            Text("⚠️ 預設的 Parakeet V3 **只支援英文與歐洲語言**——中文會議請改用支援中文的模型(如 ElevenLabs Scribe V2 / Nemotron Multilingual)並明確指定語言;選 Auto-detect 時非目標語言可能整段誤判。雲端模型只列出已設定 API key 的 provider(到「AI Models」頁設定)。本機模型不支援術語偏置,需要專案代號/術語準確請用 Deepgram / Soniox / Speechmatics。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - ASR helpers

    /// 與 `MeetingCopilotLiveController.start` 同一來源(支援串流者),再加一層 UI 過濾:
    /// 雲端模型只列**已設定 API key** 的 provider(keychain key 與各 StreamingProvider
    /// 取用的字串一致 = `ModelProvider.rawValue`);本機模型免 key 恆列。
    /// 目前選用中的模型即使 key 被移除也保留,避免 Picker 選中項懸空。
    private var streamingModels: [any TranscriptionModel] {
        TranscriptionModelRegistry.models.filter { m in
            guard m.supportsStreaming else { return false }
            guard m.provider.usesCloudUpload else { return true }
            return m.name == store.asrModelName
                || APIKeyManager.shared.hasAPIKey(forProvider: m.provider.rawValue)
        }
    }

    private var asrModelBinding: Binding<String> {
        Binding(
            get: { store.asrModelName },
            set: { name in
                store.setASRModelName(name)
                // 換模型後,若目前語言不在新模型的支援清單 → 退回 auto,避免無效語言碼。
                if let m = streamingModels.first(where: { $0.name == name }),
                   m.supportedLanguages[store.asrLanguage] == nil {
                    store.setASRLanguage("auto")
                }
            })
    }

    private var asrLanguageBinding: Binding<String> {
        Binding(get: { store.asrLanguage }, set: { store.setASRLanguage($0) })
    }

    /// 目前所選模型的語言清單(auto 置頂,其餘依顯示名排序)。
    private var asrLanguageOptions: [(key: String, value: String)] {
        let langs = streamingModels.first(where: { $0.name == store.asrModelName })?.supportedLanguages
            ?? ["auto": "Auto-detect"]
        return langs
            .sorted {
                if $0.key == "auto" { return true }
                if $1.key == "auto" { return false }
                return $0.value < $1.value
            }
            .map { (key: $0.key, value: $0.value) }
    }

    private var modelSection: some View {
        Section("回應模型") {
            Picker("即時模型（開口稿＋中度分析）", selection: fastBinding) {
                Text("自動(跟隨預設,建議選 Groq/Gemini flash 低延遲)").tag(RecorderModelChoice?.none)
                ForEach(recorderModelChoices(aiService), id: \.self) { c in
                    Text(c.label).tag(RecorderModelChoice?.some(c))
                }
            }
            Picker("深思模型（深度分析）", selection: deepThinkBinding) {
                Text("自動(跟隨預設)").tag(RecorderModelChoice?.none)
                ForEach(recorderModelChoices(aiService), id: \.self) { c in
                    Text(c.label).tag(RecorderModelChoice?.some(c))
                }
            }
            Picker("深度分析觸發", selection: bind(\.deepTrigger, store.setDeepTrigger)) {
                ForEach(CopilotDeepTrigger.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Toggle("先預跑開口稿(最新一則)", isOn: bind(\.prefetchEnabled, store.setPrefetchEnabled))
            Picker("深度分析密度", selection: bind(\.deepStyle, store.setDeepStyle)) {
                ForEach(MeetingDeepStyle.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("即時模型:開口稿(<1s)＋中度分析(~5s)共用,選低延遲的 flash/Groq 最佳。深思模型:只在需要深入時跑,**請選推理/thinking 類**(預設 gemini-2.5-pro)——它才有真正的推理增量。")
                .font(.caption).foregroundStyle(.secondary)
            Text("深度分析觸發 = 自動:中度分析判定這題需要複雜推理時,自動用深思模型跑(晚幾秒補上、亮徽章)。手動:只有你按「深入分析」才跑。兩種模式下手動按鈕都在。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var groundingSection: some View {
        Section("答案接地") {
            Toggle("參考我的歷史逐字稿(RAG)", isOn: bind(\.useHistoryRAG, store.setUseHistoryRAG))
            Toggle("參考對方分享的畫面(OCR)", isOn: bind(\.useScreenContext, store.setUseScreenContext))
            Text("領域 persona 與回答風格已移到「Prompt」分頁。brief 在各場會議的詳情頁填。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Prompt 分頁(使用者可調快/深模型與分類器的 prompt)

    private var promptForm: some View {
        Form {
            PromptEditorRow(
                title: "領域身分(persona)",
                help: "開口稿、中度、深度三段都以這個身分回答（即時＋深思模型共用）——讓答案針對你的領域,而非教科書。",
                stored: store.domainPersona,
                defaultText: MeetingCopilotConfigStore.defaultDomainPersona,
                editorHeight: 56,
                onSave: store.setDomainPersona)

            PromptEditorRow(
                title: "回答風格與範圍(開口稿＋中度)",
                help: "只套即時模型的**開口稿與中度分析**。預設把答案綁在「軟體 + 你的個人專案」範圍、口語淺白、不用你沒聽過或太難的術語。深度分析的風格另設(下方欄位)。清空 = 不加任何限制。",
                stored: store.answerStyleGuidance,
                defaultText: MeetingCopilotConfigStore.defaultAnswerStyleGuidance,
                editorHeight: 150,
                onSave: store.setAnswerStyleGuidance)

            PromptEditorRow(
                title: "深度分析風格(深思模型)",
                help: "只套**深度分析**這段,與上面的即時風格拆開——即時要短、深度可以更完整有推理,兩份分開設不會互相拉扯。密度(幾條/幾句)另由「回應模型」分頁的「深度分析密度」控制。清空 = 不加。",
                stored: store.deepStyleGuidance,
                defaultText: MeetingCopilotConfigStore.defaultDeepStyleGuidance,
                editorHeight: 150,
                onSave: store.setDeepStyleGuidance)

            PromptEditorRow(
                title: "問題分類器 prompt(即時模型)",
                help: "決定對方哪句話被判成「需要回應」並分類(directQuestion / aboutMe 等)。覆寫時務必保留輸出 {\"cues\":[…]} JSON 的格式指示,否則整場抓不到 cue。清空 = 用內建預設。",
                stored: store.cuePromptOverride,
                defaultText: ResponseCueExtractor.systemPrompt,
                editorHeight: 200,
                onSave: store.setCuePromptOverride)
        }
        .formStyle(.grouped)
    }

    // MARK: - 個人筆記 RAG（M8）

    /// FR-11:這一區只留**消費開關**——「要不要用筆記」是 copilot 的決定;
    /// 「筆記從哪來、索引哪些資料夾、什麼時候重建」是**筆記管線**的設定,歸 Ask AI。
    ///
    /// 為什麼一定要搬走(不是美觀問題):索引是 Ask AI 與 copilot **共用的資產**。兩頁各有一套
    /// 入口時,(1) 這頁的 vault 直接解 `RecorderConfigStore.vaultRootBookmark`,看不見 Ask AI 設的
    /// **筆記 vault override** → 兩頁顯示不同 vault、這頁的「重建索引」建到錯的 vault;
    /// (2) 兩頁寫同一組 UserDefaults 鍵,這頁的資料夾 TextField 只在 onAppear 種一次 @State,
    /// 使用者在 Ask AI 勾完資料夾後,只要這頁還掛著、隨便打一個字,就會把剛存的選擇整組覆寫掉。
    private var notesRAGSection: some View {
        Section("個人筆記 RAG") {
            Toggle("被問到我的經歷/專案時檢索筆記", isOn: bind(\.useNotesRAG, store.setUseNotesRAG))
            Toggle("技術問題也參考筆記", isOn: bind(\.notesInTechnicalRAG, store.setNotesInTechnicalRAG))

            VStack(alignment: .leading, spacing: 4) {
                Text("我的自介(常駐注入,檢索失敗時的保底事實)")
                TextField("例:後端工程師,主力專案 X(訂單系統重構)",
                          text: bind(\.aboutMeBrief, store.setAboutMeBrief), axis: .vertical)
                    .lineLimit(2...4)
            }

            Button {
                AppNavigator.shared.navigate(to: .askAI)
            } label: {
                Label("筆記索引設定（Ask AI）", systemImage: "arrow.up.forward.app")
            }

            Text("被問到「你做過什麼」時,從 Obsidian 筆記撈出事實錨點餵給模型,而不是讓它編。開會時會自動增量掃描(只重嵌改過的檔)。Vault 位置、要索引哪些資料夾、以及手動重建索引,都在 Ask AI 頁的齒輪「筆記來源設定」——索引是兩邊共用的,設定只有一個入口。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 承諾帳本(M15)

    private var commitmentLedgerSection: some View {
        Section("承諾帳本") {
            Toggle("記下我口頭答應的事",
                   isOn: Binding(get: { ledgerStore.enabled }, set: { ledgerStore.setEnabled($0) }))
            Toggle("AI 確認後才記帳",
                   isOn: Binding(get: { ledgerStore.llmConfirmEnabled }, set: { ledgerStore.setLLMConfirmEnabled($0) }))
            Toggle("記帳當下顯示輕量通知",
                   isOn: Binding(get: { ledgerStore.liveToastEnabled }, set: { ledgerStore.setLiveToastEnabled($0) }))
            Text("只聽「我自己」的聲道:會議中說出「我會…」「我來處理」這類承諾時,即時記進承諾帳本(會議copilot覆盤頁最上方),散會後可一鍵建成 Vikunja 任務。需開啟上方「同時轉錄我的麥克風」。關閉「AI 確認」時改為純詞表記帳(零 LLM 成本,會標「未經 AI 確認」)。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var presetScriptsSection: some View {
        Section("預設講稿") {
            ForEach(scriptStore.scripts) { s in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title.isEmpty ? "（未命名）" : s.title)
                            .font(.system(size: 13, weight: .medium))
                        if !s.body.isEmpty {
                            Text(s.body).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Button("編輯") {
                        scriptDraft = ScriptDraft(id: s.id, title: s.title, body: s.body, isNew: false)
                    }
                    .buttonStyle(.borderless)
                    Button(role: .destructive) {
                        scriptStore.delete(id: s.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                scriptDraft = ScriptDraft(id: UUID(), title: "", body: "", isNew: true)
            } label: {
                Label("新增講稿", systemImage: "plus")
            }
            Text("事先寫好你自己的講稿（自我介紹、對某議題的立場…），開會時用讀稿面板（熱鍵或選單列開啟）看著唸。這裡只存你打的文字，**不接任何 AI**——它不會聽對方講話、也不會生成任何內容。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var overlaySection: some View {
        Section("浮動視窗") {
            Toggle("點擊穿透(滑鼠事件穿到底層)", isOn: bind(\.overlayClickThrough, store.setOverlayClickThrough))
            Stepper("最多顯示 \(store.maxCuesShown) 則問題",
                    value: bind(\.maxCuesShown, store.setMaxCuesShown), in: 1...20)
            Text("🔴 分享「整個螢幕」時此視窗**會被錄到**(macOS 15.4+ 限制,無公開 API 可防)。安全模式:只分享單一視窗或分頁。")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var screenshotSection: some View {
        Section("截圖深答（手動視覺）") {
            Picker("截圖對象", selection: bind(\.screenshotTarget, store.setScreenshotTarget)) {
                ForEach(CopilotScreenshotTarget.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Text("按截圖熱鍵累積畫面（最多 \(CopilotScreenshotStore.maxShots) 張），再到浮動視窗展開任一題按「以截圖重新深答」——把畫面當**圖片**送給深答模型，覆蓋原本的文字深答。用在對方分享**圖表／投影片／程式碼**、OCR 讀不出版面時。")
                .font(.caption).foregroundStyle(.secondary)
            Label("需要**支援視覺的深答模型**（如 gpt-4o、claude-sonnet-4、gemini）；不支援時會提示你換模型。純手動觸發，自動深答不會送圖，額外 token 只花在你主動送的那幾張。", systemImage: "photo.badge.checkmark")
                .font(.caption).foregroundStyle(.orange)
            if store.screenshotTarget == .region {
                Text("「框選區域」用系統原生的十字準星（Esc 取消）。框選當下若掃過浮動視窗可能一起入鏡——框對方的內容即可。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var hotkeySection: some View {
        Section("熱鍵") {
            LabeledContent("開/關浮動視窗") {
                ShortcutRecorder(action: .toggleMeetingCopilotOverlay).controlSize(.small)
            }
            LabeledContent("按住瞄一眼") {
                ShortcutRecorder(action: .peekMeetingCopilotOverlay).controlSize(.small)
            }
            LabeledContent("緊急隱藏（再按還原）") {
                ShortcutRecorder(action: .panicHideMeetingCopilot).controlSize(.small)
            }
            LabeledContent("截圖（截圖深答）") {
                ShortcutRecorder(action: .captureCopilotScreenshot).controlSize(.small)
            }
            LabeledContent("展開/收合分析") {
                ShortcutRecorder(action: .toggleCopilotCueExpansion).controlSize(.small)
            }
            LabeledContent("展開/收合翻譯") {
                ShortcutRecorder(action: .toggleTranslationExpansion).controlSize(.small)
            }
            LabeledContent("開/關讀稿面板") {
                ShortcutRecorder(action: .togglePresenterScript).controlSize(.small)
            }
            LabeledContent("開/關會議錄製") {
                ShortcutRecorder(action: .toggleMeetingRecording).controlSize(.small)
            }
        }
    }

    // MARK: - 即時翻譯分頁(M8 FR-62 / AC-46/47)

    private var translationForm: some View {
        Form {
            Section {
                Toggle("即時翻譯對方的話", isOn: bind(\.liveTranslationEnabled, store.setLiveTranslationEnabled))
                Text("對方每講完一段就翻成目標語言,顯示在浮動視窗的**上區**(與「問題與回應」分開,不會混淆)。這是**每段一次**的額外 LLM 呼叫(與問題偵測平行,不是取代它)——關閉時零呼叫、零成本,單語會議不必開。")
                    .font(.caption).foregroundStyle(.secondary)
                Label("⚠️ Token 消耗提醒:為了即時,字幕改採逐字串流、且切段門檻壓低(講者一停就送翻),整場會議會產生大量、頻繁的翻譯呼叫。長會議的 token/費用可能可觀——用付費 API(如 Gemini)時請留意用量。", systemImage: "dollarsign.circle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            Section("翻譯模型") {
                Picker("翻譯模型", selection: translationModelBinding) {
                    Text("自動(跟隨預設,建議選 Groq 低延遲)").tag(RecorderModelChoice?.none)
                    ForEach(recorderModelChoices(aiService), id: \.self) { c in
                        Text(c.label).tag(RecorderModelChoice?.some(c))
                    }
                }
                Text("與快/深模型**各自獨立**:翻譯要的是便宜、快、量大(每段都打),不需要深模型的推理力。字幕跟不上時,先來這裡換更小更快的模型。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("語言") {
                Picker("來源語言", selection: translationSourceBinding) {
                    ForEach(translationSourceOptions, id: \.key) { o in Text(o.value).tag(o.key) }
                }
                Picker("目標語言", selection: translationTargetBinding) {
                    ForEach(translationTargetOptions, id: \.key) { o in Text(o.value).tag(o.key) }
                }
                Text("⚠️ 混語會議請在「一般」分頁選支援多語的即時轉錄模型(Nemotron Multilingual 或雲端)——Parakeet 的 auto 對中文會輸出亂碼。**翻譯再準也救不了轉錯的原文**。")
                    .font(.caption).foregroundStyle(.orange)
                Text("回應(開口稿與深度分析)一律以目標語言輸出——要照著唸的稿子,語言得跟我要開口說的一致。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 會後包分頁(M12)

    private var meetingPackForm: some View {
        Form {
            Section {
                Toggle("會議結束後自動生成會後包",
                       isOn: Binding(get: { packStore.enabled }, set: { packStore.setEnabled($0) }))
                Text("會議錄音匯入完成後,自動整理**主題重點/決定/行動項目/待追問**,連同原始逐字稿寫進 Obsidian vault。AI 生成失敗時仍會匯出僅含逐字稿的筆記——內容不會遺失。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("匯出") {
                TextField("Vault 子資料夾", text: $packSubfolderDraft)
                    .onSubmit { commitPackSubfolder() }
                Text("寫入 Obsidian vault 根目錄下的這個子資料夾(根目錄沿用「錄音設定」的 vault 設定)。清空 = 還原預設「\(MeetingPackConfigStore.defaultSubfolder)」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Vikunja") {
                Toggle("「我答應的」自動建成 Vikunja 任務",
                       isOn: Binding(get: { packStore.vikunjaAutoCreate }, set: { packStore.setVikunjaAutoCreate($0) }))
                Text("關閉時,通知上會出現「加入 Vikunja(N)」按鈕,按了才批次建立;開啟時直接建立並在通知回報結果。需先在 Vikunja 設定頁完成連線設定——未設定時按鈕不出現,行動項目仍完整保留在筆記裡。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { packSubfolderDraft = packStore.subfolder }
        .onDisappear { commitPackSubfolder() }
    }

    private func commitPackSubfolder() {
        packStore.setSubfolder(packSubfolderDraft)
        packSubfolderDraft = packStore.subfolder
    }

    /// 來源語言。auto 置頂:混語(中英夾雜)會議的唯一正解——見 `MeetingTranslationPrompt` 檔頭,
    /// 任何語言偵測器都會在夾雜句上判錯,而判錯的提示會直接害模型硬翻。
    private var translationSourceOptions: [(key: String, value: String)] {
        [("auto", "自動判斷(混語會議建議)"), ("zh-TW", "繁體中文"), ("en", "English"), ("ja", "日本語")]
    }

    /// 目標語言(無 auto——「翻成自動」沒有意義)。
    private var translationTargetOptions: [(key: String, value: String)] {
        [("zh-TW", "繁體中文"), ("en", "English"), ("ja", "日本語")]
    }

    // MARK: - Binding helpers（config @Published 為 private(set)）

    private func bind<T>(_ keyPath: KeyPath<MeetingCopilotConfigStore, T>, _ setter: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: { store[keyPath: keyPath] }, set: { setter($0) })
    }

    private var fastBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.fastProviderName, let m = store.fastModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setFastModel(provider: $0?.provider, model: $0?.model) })
    }

    private var deepBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.deepProviderName, let m = store.deepModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setDeepModel(provider: $0?.provider, model: $0?.model) })
    }

    /// M10 深思模型(僅深度分析)。預設 Gemini/gemini-2.5-pro;nil = 跟隨預設 provider。
    private var deepThinkBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.deepThinkProviderName, let m = store.deepThinkModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setDeepThinkModel(provider: $0?.provider, model: $0?.model) })
    }

    /// 翻譯模型(M8)。形式完全鏡射 `fastBinding`:nil = 跟隨預設 provider。
    private var translationModelBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.translationProviderName,
                      let m = store.translationModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setTranslationModel(provider: $0?.provider, model: $0?.model) })
    }

    /// 來源/目標語言共用 store 的**雙欄 setter**(`setTranslationLanguages(source:target:)`),
    /// 所以每個 Binding 的 set 都必須把另一半的**現值**一起送回去——只送自己那一半,
    /// 另一半就會被覆寫掉(選了目標語言,來源語言當場被清空)。
    private var translationSourceBinding: Binding<String> {
        Binding(
            get: { store.translationSourceLanguage },
            set: { store.setTranslationLanguages(source: $0, target: store.translationTargetLanguage) })
    }

    private var translationTargetBinding: Binding<String> {
        Binding(
            get: { store.translationTargetLanguage },
            set: { store.setTranslationLanguages(source: store.translationSourceLanguage, target: $0) })
    }
}

// MARK: - 講稿編輯 sheet(M7)

/// 講稿編輯 sheet 的暫存 draft。`id` 為既有講稿 id,或新建時的新 UUID。
private struct ScriptDraft: Identifiable {
    let id: UUID
    var title: String
    var body: String
    let isNew: Bool
}

/// 新增/編輯一則講稿。純使用者輸入,存回 `PresenterScriptStore`。
private struct ScriptEditorSheet: View {
    let draft: ScriptDraft
    let onSave: (String, String) -> Void
    let onCancel: () -> Void

    @State private var titleText: String
    @State private var bodyText: String

    init(draft: ScriptDraft,
         onSave: @escaping (String, String) -> Void,
         onCancel: @escaping () -> Void) {
        self.draft = draft
        self.onSave = onSave
        self.onCancel = onCancel
        _titleText = State(initialValue: draft.title)
        _bodyText = State(initialValue: draft.body)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isNew ? "新增講稿" : "編輯講稿").font(.headline)
            TextField("標題（如：自我介紹）", text: $titleText)
                .textFieldStyle(.roundedBorder)
            Text("講稿內容").font(.system(size: 12)).foregroundStyle(.secondary)
            TextEditor(text: $bodyText)
                .font(.system(size: 13))
                .frame(minWidth: 420, minHeight: 240)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
            HStack {
                Spacer()
                Button("取消", action: onCancel)
                Button("儲存") { onSave(titleText, bodyText) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(titleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// Prompt 頁共用的可編輯欄位:草稿編輯 + **儲存 / 恢復預設 / 清空**(有樣式的按鈕)。
///
/// 草稿模式(不即時生效):編輯 TextEditor 只改本地草稿,按「儲存」才寫回設定。恢復預設 / 清空只**填入草稿**,
/// 仍需按「儲存」才套用——單一 commit 入口、不會有東西被默默改掉;有未存變更時顯示橙色「未儲存」提示、
/// 「儲存」才可按。
private struct PromptEditorRow: View {
    let title: String
    let help: String
    /// 目前已儲存的值(判斷 dirty + 首次 seed 草稿)。
    let stored: String
    let defaultText: String
    var editorHeight: CGFloat = 120
    let onSave: (String) -> Void

    @State private var draft: String

    init(title: String, help: String, stored: String, defaultText: String,
         editorHeight: CGFloat = 120, onSave: @escaping (String) -> Void) {
        self.title = title
        self.help = help
        self.stored = stored
        self.defaultText = defaultText
        self.editorHeight = editorHeight
        self.onSave = onSave
        _draft = State(initialValue: stored)   // 首次以已存值 seed;之後由 @State 保留編輯
    }

    private var dirty: Bool { draft != stored }

    var body: some View {
        Section(title) {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $draft)
                    .font(.system(size: 12))
                    .frame(height: editorHeight)
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25)))

                HStack(spacing: 8) {
                    Button("儲存") { onSave(draft) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!dirty)
                    Button("恢復預設") { draft = defaultText }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("清空") { draft = "" }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                    if dirty {
                        Label("未儲存", systemImage: "circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Text(help).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
