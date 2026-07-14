import SwiftUI
import SwiftData

/// 「會議即時輔助」設定(FR-30)。clone `RecorderModeSettingsView` 的 Form + Binding 模式。
/// 繁中字面;config 的 @Published 是 private(set),每個控制項用 `Binding(get:set:)` 包。
/// 獨立側欄頁(位於「錄音設定」之下);「會議錄音管理」頁的齒輪也導覽到這裡。
struct MeetingCopilotSettingsView: View {
    @StateObject private var store = MeetingCopilotConfigStore.shared
    @StateObject private var scriptStore = PresenterScriptStore.shared
    /// vault 根目錄是全域錄音設定(「錄音裝置」頁選的),筆記 RAG 直接沿用同一個。
    @StateObject private var recorderStore = RecorderConfigStore.shared
    /// FR-6:筆記索引**範圍**(include/exclude 資料夾)的所有權在筆記管線這邊,
    /// 不再是 meeting-copilot 的設定。(這頁的筆記區塊在 Task 11 會整段瘦身掉。)
    @StateObject private var notesStore = ObsidianRAGConfigStore.shared
    @EnvironmentObject private var aiService: AIService
    @Environment(\.modelContext) private var modelContext

    /// 講稿編輯 sheet 的暫存(nil = 未開啟)。
    @State private var scriptDraft: ScriptDraft?

    /// 分頁(M8 Task 19)。設定項一路長到八個 Section,把「即時翻譯」再堆上去只會讓整頁
    /// 更難掃;翻譯是**獨立的一條管線**(自己的模型、自己的語言、自己的成本),分頁比 Section 誠實。
    private enum SettingsTab: String, CaseIterable {
        case general = "一般"
        case translation = "即時翻譯"
    }

    @State private var tab: SettingsTab = .general

    /// 資料夾清單的**編輯中原字串**。不直接 bind 陣列:逐鍵解析會把使用者剛打的逗號吃掉
    /// (["a"] → get 回 "a" → 逗號當場消失)。原字串留在 @State,解析結果同步寫進 store。
    @State private var includeOnlyText: String = ""
    @State private var excludedText: String = ""
    @State private var indexing = false
    @State private var indexMessage: String?

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
                .frame(maxWidth: 380)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            switch tab {
            case .general: generalForm
            case .translation: translationForm
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
            presetScriptsSection
            overlaySection
            hotkeySection
        }
        .formStyle(.grouped)
        .onAppear {
            includeOnlyText = notesStore.includeOnlyFolders.joined(separator: ", ")
            excludedText = notesStore.excludedFolders.joined(separator: ", ")
        }
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
            Picker("快模型(開口稿)", selection: fastBinding) {
                Text("自動(跟隨預設,建議選 Groq 低延遲)").tag(RecorderModelChoice?.none)
                ForEach(recorderModelChoices(aiService), id: \.self) { c in
                    Text(c.label).tag(RecorderModelChoice?.some(c))
                }
            }
            Picker("深模型(深度分析)", selection: deepBinding) {
                Text("自動(跟隨預設)").tag(RecorderModelChoice?.none)
                ForEach(recorderModelChoices(aiService), id: \.self) { c in
                    Text(c.label).tag(RecorderModelChoice?.some(c))
                }
            }
            Toggle("先預跑開口稿(最新一則)", isOn: bind(\.prefetchEnabled, store.setPrefetchEnabled))
            Toggle("Tier 1 完成後自動深度分析", isOn: bind(\.autoDeepEnabled, store.setAutoDeepEnabled))
            Text("快模型負責「立刻可開口」的草稿(選低延遲的 Groq 最佳);深模型隨後補深度分析與追問預判。")
                .font(.caption).foregroundStyle(.secondary)
            Text("自動深度分析:開口稿一回來就在背景續跑深模型,不必手動點開。分析完成時,沒在讀別則就直接展開,否則只亮未讀徽章(熱鍵「展開/收合分析」可切過去)。關閉則回到點擊才跑。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var groundingSection: some View {
        Section("答案接地") {
            Toggle("參考我的歷史逐字稿(RAG)", isOn: bind(\.useHistoryRAG, store.setUseHistoryRAG))
            Toggle("參考對方分享的畫面(OCR)", isOn: bind(\.useScreenContext, store.setUseScreenContext))
            VStack(alignment: .leading, spacing: 4) {
                Text("領域 persona")
                TextEditor(text: bind(\.domainPersona, store.setDomainPersona))
                    .font(.system(size: 12)).frame(height: 54)
            }
            Text("讓答案針對你的專案,而非教科書。brief 在各場會議的詳情頁填。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - 個人筆記 RAG（M8）

    private var notesRAGSection: some View {
        Section("個人筆記 RAG") {
            LabeledContent("Obsidian Vault") {
                if let path = vaultRoot?.path {
                    Text(path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("尚未設定——到「錄音裝置」設定 Obsidian Vault")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Toggle("被問到我的經歷/專案時檢索筆記", isOn: bind(\.useNotesRAG, store.setUseNotesRAG))
            Toggle("技術問題也參考筆記", isOn: bind(\.notesInTechnicalRAG, store.setNotesInTechnicalRAG))

            VStack(alignment: .leading, spacing: 4) {
                Text("我的自介(常駐注入,檢索失敗時的保底事實)")
                TextField("例:後端工程師,主力專案 X(訂單系統重構)",
                          text: bind(\.aboutMeBrief, store.setAboutMeBrief), axis: .vertical)
                    .lineLimit(2...4)
            }

            TextField("只索引這些資料夾(逗號分隔,空=全部)", text: $includeOnlyText)
                .onChange(of: includeOnlyText) { _, new in
                    notesStore.setIncludeOnlyFolders(Self.parseFolders(new))
                }
            TextField("排除資料夾(逗號分隔)", text: $excludedText)
                .onChange(of: excludedText) { _, new in
                    notesStore.setExcludedFolders(Self.parseFolders(new))
                }

            HStack(spacing: 8) {
                Button("重建筆記索引") { reindexNotes() }
                    .disabled(indexing)
                if indexing { ProgressView().controlSize(.small) }
                if let indexMessage {
                    Text(indexMessage).font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("被問到「你做過什麼」時,從 Obsidian 筆記撈出事實錨點餵給模型,而不是讓它編。開會時會自動增量掃描(只重嵌改過的檔);這個按鈕是要立刻補索引時用的。需要 embedding 金鑰(到「Ask AI」設定)。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// vault 根目錄(未設定 → nil)。與 `RecordersSettingsView.VaultRootCard` 同一條解析路徑。
    private var vaultRoot: URL? {
        guard let bookmark = recorderStore.vaultRootBookmark else { return nil }
        return VaultExportService.shared.resolveVaultRoot(bookmark)
    }

    /// "工作, 專案 ,," → ["工作", "專案"]。空項與前後空白一律丟掉。
    private static func parseFolders(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func reindexNotes() {
        guard let vaultRoot else {
            indexMessage = "尚未設定 Obsidian Vault"
            return
        }
        indexing = true
        indexMessage = nil
        Task {
            do {
                // stateURL 與 live 端的背景掃描、Ask AI 的 autoIndex 共用
                // (見 ObsidianNoteIndexService.defaultStateURL)。
                let index = ObsidianNoteIndexService(
                    modelContext: modelContext,
                    stateURL: try ObsidianNoteIndexService.defaultStateURL())
                let count = try await index.reindex(
                    vaultRoot: vaultRoot,
                    includeOnly: notesStore.includeOnlyFolders,
                    excluded: notesStore.excludedFolders)
                indexMessage = count == 0
                    ? "已是最新(沒有檔案變動)"
                    : "已索引 \(count) 檔"
            } catch EmbeddingError.missingAPIKey {
                indexMessage = "需要 Gemini/OpenAI embedding 金鑰(Ask AI 設定)"
            } catch {
                indexMessage = "索引失敗:\(error.localizedDescription)"
            }
            indexing = false
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

    private var hotkeySection: some View {
        Section("熱鍵") {
            LabeledContent("開/關浮動視窗") {
                ShortcutRecorder(action: .toggleMeetingCopilotOverlay).controlSize(.small)
            }
            LabeledContent("按住瞄一眼") {
                ShortcutRecorder(action: .peekMeetingCopilotOverlay).controlSize(.small)
            }
            LabeledContent("展開/收合分析") {
                ShortcutRecorder(action: .toggleCopilotCueExpansion).controlSize(.small)
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
