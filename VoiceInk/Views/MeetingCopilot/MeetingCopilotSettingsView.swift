import SwiftUI

/// 「會議即時輔助」設定(FR-30)。clone `RecorderModeSettingsView` 的 Form + Binding 模式。
/// 繁中字面;config 的 @Published 是 private(set),每個控制項用 `Binding(get:set:)` 包。
struct MeetingCopilotSettingsView: View {
    @StateObject private var store = MeetingCopilotConfigStore.shared
    @EnvironmentObject private var aiService: AIService
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AppPanelHeader(title: "會議即時輔助設定", onClose: onClose)
            Divider()
            Form {
                enableSection
                asrSection
                modelSection
                groundingSection
                overlaySection
                hotkeySection
            }
            .formStyle(.grouped)
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
            Toggle("同時轉錄我的麥克風", isOn: bind(\.transcribeLocalMic, store.setTranscribeLocalMic))
            Text("⚠️ 預設用本機模型(免費、隱私、不上傳),但**本機模型不支援術語偏置**——專案代號、\("服務名")容易被轉錯,進而讓問題偵測失準。需要術語準確度請在「錄音設定」改用雲端轉錄模型(Deepgram / Soniox / Speechmatics)。")
                .font(.caption).foregroundStyle(.secondary)
        }
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
            Text("快模型負責「立刻可開口」的草稿(選低延遲的 Groq 最佳);深模型隨後補深度分析與追問預判。")
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

    private var overlaySection: some View {
        Section("浮動視窗") {
            Toggle("點擊穿透(滑鼠事件穿到底層)", isOn: bind(\.overlayClickThrough, store.setOverlayClickThrough))
            HStack {
                Text("我說話時淡出")
                Slider(value: bind(\.speakingOpacity, store.setSpeakingOpacity), in: 0.05...1.0)
                Text(String(format: "%.0f%%", store.speakingOpacity * 100)).monospacedDigit().frame(width: 44)
            }
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
            LabeledContent("開/關會議錄製") {
                ShortcutRecorder(action: .toggleMeetingRecording).controlSize(.small)
            }
        }
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
}
