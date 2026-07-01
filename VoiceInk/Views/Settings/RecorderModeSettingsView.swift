import SwiftUI

/// Recorder Mode — the recorder's own transcription + default-analysis settings, independent of the
/// voice Modes. Only model/language/formatting + the auto-export switch; no triggers, no prompt.
struct RecorderModeSettingsView: View {
    @StateObject private var store = RecorderConfigStore.shared
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var aiService: AIService

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Recorder Mode",
                infoMessage: "錄音筆專用設定：用哪個模型把錄音轉成文字、預設用哪個模型分析。與「語音模式」完全分開——改這裡只影響錄音筆。",
                infoURL: nil
            ) { EmptyView() }

            Form {
                Section("語音轉文字") {
                    Picker("轉錄模型", selection: transcriptionBinding) {
                        Text("自動（第一個可用）").tag(String?.none)
                        ForEach(transcriptionModelManager.usableModels, id: \.name) { m in
                            Text(m.displayName).tag(String?.some(m.name))
                        }
                    }
                    TextField("語言代碼（留空＝自動，例如 zh、en）", text: languageBinding)
                    Toggle(isOn: formattingBinding) {
                        HStack(spacing: 4) {
                            Text("段落分隔（自動分段）")
                            InfoTip("開啟後用智慧格式化自動判斷斷句，把大段文字分成段落。與語音模式的「Paragraph breaks」是同一套機制。")
                        }
                    }
                    Toggle("啟用語者辨識", isOn: diarizationBinding)
                    if store.recorderDiarizationEnabled {
                        Stepper(value: expectedSpeakersBinding, in: 0...12) {
                            Text(store.recorderExpectedSpeakerCount.map { "預期人數：\($0)" } ?? "預期人數：自動")
                        }
                        Text("辨識會議中的說話者並分段標記（講者1／講者2…，可事後改名）。目前原生語者辨識僅 ElevenLabs 等特定雲端模型支援（最準）；其他模型改用本地辨識，首次需下載模型、速度較慢，且分段文字以本地辨識結果為準。")
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
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transcriptionBinding: Binding<String?> {
        Binding(get: { store.recorderTranscriptionModelName },
                set: { store.setRecorderTranscriptionModel($0) })
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
}
