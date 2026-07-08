import SwiftUI

/// Recorder Mode — the recorder's own transcription + default-analysis settings, independent of the
/// voice Modes. Only model/language/formatting + the auto-export switch; no triggers, no prompt.
struct RecorderModeSettingsView: View {
    @StateObject private var store = RecorderConfigStore.shared
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var aiService: AIService
    @Environment(\.modelContext) private var modelContext
    @AppStorage(CleanupSettingsKeys.isRecorderCleanupEnabled) private var isRecorderCleanupEnabled = false
    @AppStorage(CleanupSettingsKeys.recorderRetentionDays) private var recorderRetentionDays = 90
    @State private var showRecorderCleanupResult = false

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "錄音設定",
                infoMessage: "錄音專用設定：用哪個模型把錄音轉成文字、預設用哪個模型分析、自動匯入的檔案大小門檻。與「語音模式」完全分開——改這裡只影響錄音。",
                infoURL: nil
            ) { EmptyView() }

            Form {
                Section("語音轉文字") {
                    LabeledContent("轉錄模型") {
                        Text("ElevenLabs Scribe V2（固定）").foregroundStyle(.secondary)
                    }
                    Text("錄音筆固定使用 ElevenLabs：它能整份錄音一次辨識、講者全程一致，不需切段或本地備援。需在 AI Models 設定 ElevenLabs API 金鑰。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("語言代碼（留空＝自動，例如 zh、en）", text: languageBinding)
                    Toggle(isOn: formattingBinding) {
                        HStack(spacing: 4) {
                            Text("段落分隔（自動分段）")
                            InfoTip("開啟後用智慧格式化自動判斷斷句，把大段文字分成段落。與語音模式的「Paragraph breaks」是同一套機制。")
                        }
                    }
                    Toggle(isOn: convertTraditionalBinding) {
                        HStack(spacing: 4) {
                            Text("輸出繁體中文")
                            InfoTip("用 OpenCC 把逐字稿與講者分段從簡體轉成繁體（台灣正體），只轉字不改用詞。顯示、分析、匯出都會一致。")
                        }
                    }
                    if noVerbatimSupported {
                        Toggle(isOn: noVerbatimBinding) {
                            HStack(spacing: 4) {
                                Text("去除贅字（no_verbatim）")
                                InfoTip("ElevenLabs scribe_v2 原生功能：自動去掉「呃、那個、就是說」等贅字、口頭禪、false start 與非語音雜音，逐字稿更乾淨好讀。免費，僅 scribe_v2 支援。")
                            }
                        }
                    }
                    Toggle("啟用語者辨識", isOn: diarizationBinding)
                    if store.recorderDiarizationEnabled {
                        Label(diarizationModeHint, systemImage: diarizationIsNative ? "sparkles" : "cpu")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Stepper(value: expectedSpeakersBinding, in: 0...12) {
                            Text(store.recorderExpectedSpeakerCount.map { "預期人數：\($0)" } ?? "預期人數：自動")
                        }
                        if diarizationIsNative {
                            Toggle(isOn: detectSpeakerRolesBinding) {
                                HStack(spacing: 4) {
                                    Text("辨識講者角色（客服／客戶）")
                                    InfoTip("ElevenLabs 原生功能 detect_speaker_roles：把講者標記成「客服」與「客戶」而非講者1／2。需搭配語者辨識，費用約 +10%。")
                                }
                            }
                        }
                        Text("辨識會議中的說話者並分段標記（講者1／講者2…，可事後改名）。整份錄音會一次送 ElevenLabs 原生辨識，長錄音的講者編號跨全程一致。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("分析") {
                    Picker("預設分析模型", selection: analysisBinding) {
                        Text("自動（第一個可用）").tag(RecorderModelChoice?.none)
                        ForEach(recorderModelChoices(aiService), id: \.self) { c in
                            Text(c.label).tag(RecorderModelChoice?.some(c))
                        }
                    }
                    Text("套範本分析用的模型;個別類別可在「錄音筆範本」各自覆寫。")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper(value: timeoutBinding, in: 15...600, step: 15) {
                        Text("分析逾時：\(store.recorderAnalysisTimeoutSeconds) 秒")
                    }
                    Text("分析請求的等待上限。用較慢的本地模型（如 32B）產長筆記時，語音預設的 7 秒會逾時，調高即可。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("會議錄製") {
                    Toggle(isOn: meetingMicBinding) {
                        HStack(spacing: 4) {
                            Text("同時收錄麥克風")
                            InfoTip("關閉後只錄系統音訊（對方聲音）。用喇叭開會時麥克風會收到迴音，建議戴耳機。")
                        }
                    }
                    Text("會議錄音併入「錄音輸入」，與錄音筆匯入走相同流程——不自動標「會議」，由你在錄音管理手動選要套的範本。匯出沿用下方「自動化」的「自動匯出」開關。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("分類") {
                    Picker("分類模型", selection: classifierBinding) {
                        Text("跟隨分析模型").tag(RecorderModelChoice?.none)
                        ForEach(recorderModelChoices(aiService), id: \.self) { c in
                            Text(c.label).tag(RecorderModelChoice?.some(c))
                        }
                    }
                    Text("判斷逐字稿屬於哪一類用的模型。每個匯入都會跑一次,選本地 Ollama 可省 token。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("自動匯入") {
                    HStack {
                        Text("略過過小檔案")
                        InfoTip("小於此大小的錄音檔不會自動匯入（避免誤觸產生的極短錄音被轉錄）。設為 0 代表不過濾。手動「重新處理」不受此限制。")
                        Spacer()
                        TextField("", value: minSizeValueBinding, format: .number)
                            .frame(width: 64).multilineTextAlignment(.trailing)
                        Picker("", selection: minSizeUnitBinding) {
                            ForEach(FileSizeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 72)
                    }
                    HStack {
                        Text("略過過短錄音")
                        InfoTip("短於此長度的錄音檔不會自動匯入。設為 0 代表不過濾。手動「重新處理」不受此限制。")
                        Spacer()
                        TextField("", value: minDurationValueBinding, format: .number)
                            .frame(width: 64).multilineTextAlignment(.trailing)
                        Picker("", selection: minDurationUnitBinding) {
                            ForEach(DurationUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden().frame(width: 72)
                    }
                    Text(autoImportFilterSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("自動化") {
                    Toggle("匯入後自動套範本並匯出 Obsidian", isOn: autoExportBinding)
                    Text("關閉（預設）：匯入只轉錄＋建議分類,套範本與匯出在「錄音管理」手動進行。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Obsidian 匯出") {
                    Toggle("匯出時附上原始逐字稿", isOn: includeRawBinding)
                    Text("關閉（預設）：Obsidian 筆記只含分析結果。開啟：在筆記最下方以分隔線附上完整原始逐字稿。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("自動清理") {
                    Toggle("自動清理錄音筆匯入", isOn: $isRecorderCleanupEnabled)
                    if isRecorderCleanupEnabled {
                        Picker("保留期限", selection: $recorderRetentionDays) {
                            Text("30 天").tag(30)
                            Text("90 天").tag(90)
                            Text("180 天").tag(180)
                            Text("1 年").tag(365)
                        }
                        Button("立即清理") {
                            Task {
                                await TranscriptionAutoCleanupService.shared.runManualRecorderCleanup(modelContext: modelContext)
                                showRecorderCleanupResult = true
                            }
                        }
                    }
                    Text("超過保留期限的錄音筆匯入（音檔＋逐字稿）會被刪除。星號 ★ 的錄音永不清理。預設關閉＝永遠保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("錄音筆匯入清理", isPresented: $showRecorderCleanupResult) {
            Button("OK", role: .cancel) { }
        } message: { Text("清理完成。星號標記的錄音不受影響。") }
    }

    private var languageBinding: Binding<String> {
        Binding(get: { store.recorderLanguage ?? "" },
                set: { store.setRecorderLanguage($0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0) })
    }
    private var formattingBinding: Binding<Bool> {
        Binding(get: { store.recorderTextFormattingEnabled }, set: { store.setRecorderTextFormatting($0) })
    }
    private var timeoutBinding: Binding<Int> {
        Binding(get: { store.recorderAnalysisTimeoutSeconds }, set: { store.setRecorderAnalysisTimeout($0) })
    }
    private var minSizeValueBinding: Binding<Int> {
        Binding(get: { store.recorderMinImportSizeValue },
                set: { store.setRecorderMinImportSize(value: $0, unit: store.recorderMinImportSizeUnit) })
    }
    private var minSizeUnitBinding: Binding<FileSizeUnit> {
        Binding(get: { store.recorderMinImportSizeUnit },
                set: { store.setRecorderMinImportSize(value: store.recorderMinImportSizeValue, unit: $0) })
    }
    private var minDurationValueBinding: Binding<Int> {
        Binding(get: { store.recorderMinImportDurationValue },
                set: { store.setRecorderMinImportDuration(value: $0, unit: store.recorderMinImportDurationUnit) })
    }
    private var minDurationUnitBinding: Binding<DurationUnit> {
        Binding(get: { store.recorderMinImportDurationUnit },
                set: { store.setRecorderMinImportDuration(value: store.recorderMinImportDurationValue, unit: $0) })
    }
    /// Human summary of the two OR-combined auto-import filters (whichever matches skips the file).
    private var autoImportFilterSummary: String {
        var clauses: [String] = []
        if store.recorderMinImportSizeValue > 0 {
            clauses.append("小於 \(store.recorderMinImportSizeValue) \(store.recorderMinImportSizeUnit.rawValue)")
        }
        if store.recorderMinImportDurationValue > 0 {
            clauses.append("短於 \(store.recorderMinImportDurationValue) \(store.recorderMinImportDurationUnit.rawValue)")
        }
        guard !clauses.isEmpty else { return "目前未設定過濾，所有錄音檔都會自動匯入。" }
        return "符合任一條件即略過自動匯入：" + clauses.joined(separator: "，或") + "。"
    }
    private var autoExportBinding: Binding<Bool> {
        Binding(get: { store.recorderAutoExportEnabled }, set: { store.setRecorderAutoExport($0) })
    }
    private var includeRawBinding: Binding<Bool> {
        Binding(get: { store.recorderExportIncludeRawTranscript },
                set: { store.setRecorderExportIncludeRawTranscript($0) })
    }
    private var diarizationBinding: Binding<Bool> {
        Binding(get: { store.recorderDiarizationEnabled },
                set: { store.setRecorderDiarizationEnabled($0) })
    }
    private var expectedSpeakersBinding: Binding<Int> {
        Binding(get: { store.recorderExpectedSpeakerCount ?? 0 },
                set: { store.setRecorderExpectedSpeakerCount($0 == 0 ? nil : $0) })
    }
    private var detectSpeakerRolesBinding: Binding<Bool> {
        Binding(get: { store.recorderDetectSpeakerRoles },
                set: { store.setRecorderDetectSpeakerRoles($0) })
    }
    private var convertTraditionalBinding: Binding<Bool> {
        Binding(get: { store.recorderConvertToTraditional },
                set: { store.setRecorderConvertToTraditional($0) })
    }
    private var noVerbatimBinding: Binding<Bool> {
        Binding(get: { store.recorderNoVerbatim },
                set: { store.setRecorderNoVerbatim($0) })
    }
    /// no_verbatim is an ElevenLabs scribe_v2-only parameter; the recorder is hardcoded to it.
    private var noVerbatimSupported: Bool {
        RecorderTranscriptionConfig.transcriptionModelName == "scribe_v2"
    }
    /// The recorder's fixed model diarizes natively (ElevenLabs). Kept as a computed value so the
    /// UI adapts automatically if `RecorderTranscriptionConfig.transcriptionModelName` ever changes.
    private var diarizationIsNative: Bool {
        DiarizationCoordinator.supportsNativeDiarization(modelName: RecorderTranscriptionConfig.transcriptionModelName)
    }
    private var diarizationModeHint: String { "整份錄音一次辨識，講者全程一致（ElevenLabs 原生）" }
    private var analysisBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.defaultAIProviderName, let m = store.defaultAIModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setDefaultModel(provider: $0?.provider, model: $0?.model) })
    }
    private var classifierBinding: Binding<RecorderModelChoice?> {
        Binding(
            get: {
                guard let p = store.recorderClassifierProviderName, let m = store.recorderClassifierModelName else { return nil }
                return RecorderModelChoice(provider: p, model: m)
            },
            set: { store.setClassifierModel(provider: $0?.provider, model: $0?.model) })
    }
    private var meetingMicBinding: Binding<Bool> {
        Binding(get: { store.meetingMicEnabled }, set: { store.setMeetingMicEnabled($0) })
    }
}
