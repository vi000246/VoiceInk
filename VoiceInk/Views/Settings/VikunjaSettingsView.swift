import SwiftUI

/// 設定頁的「Vikunja 語音待辦」區塊(嵌在 `SettingsView` 的 Form 裡,樣式沿用其他 Section)。
///
/// URL / token 在按「測試連線」「載入專案」或欄位送出時才寫入(token 進 Keychain,不進 UserDefaults)。
struct VikunjaSettingsSection: View {
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @ObservedObject private var config = VikunjaConfigStore.shared

    @State private var baseURLText = ""
    @State private var tokenText = ""
    @State private var projects: [VikunjaService.Project] = []
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isBusy = false

    var body: some View {
        Section {
            Toggle("啟用語音記待辦", isOn: Binding(
                get: { config.enabled },
                set: { config.setEnabled($0) }
            ))

            LabeledContent("Vikunja URL") {
                TextField("https://vikunja.example.com", text: $baseURLText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit { commitFields() }
            }

            LabeledContent("API Token") {
                SecureField("", text: $tokenText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                    .onSubmit { commitFields() }
            }

            LabeledContent("熱鍵") {
                ShortcutRecorder(action: .voiceCaptureVikunja) {
                    recordingShortcutManager.updateShortcutStatus()
                }
                .controlSize(.small)
            }

            LabeledContent("預設專案") {
                Picker("", selection: Binding(
                    get: { config.defaultProjectID },
                    set: { id in
                        let name = projects.first(where: { $0.id == id })?.title
                            ?? (id == config.defaultProjectID ? config.defaultProjectName : "")
                        config.setDefaultProject(id: id, name: name)
                    }
                )) {
                    Text("未選擇").tag(0)
                    // 清單未載入時仍顯示已儲存的專案,不然重開設定頁會看到空白選項。
                    if !projects.contains(where: { $0.id == config.defaultProjectID }),
                       config.defaultProjectID > 0 {
                        Text(config.defaultProjectName.isEmpty
                             ? "#\(config.defaultProjectID)"
                             : config.defaultProjectName)
                            .tag(config.defaultProjectID)
                    }
                    ForEach(projects) { project in
                        Text(project.title).tag(project.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            HStack(spacing: 8) {
                Button("測試連線") { runVerify() }
                    .disabled(isBusy)
                Button("載入專案") { runLoadProjects() }
                    .disabled(isBusy)
                if isBusy {
                    ProgressView().controlSize(.small)
                }
                if let statusMessage {
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(statusIsError ? .red : .secondary)
                }
                Spacer()
            }
        } header: {
            Text("Vikunja 語音待辦")
        } footer: {
            Text("按熱鍵口述一句話,轉錄後由 AI 抽出任務名與時間,直接建進 Vikunja(有時間會同步到行事曆)。")
                .settingsDescription()
        }
        .onAppear {
            baseURLText = config.baseURL
            tokenText = config.token ?? ""
        }
    }

    /// 回傳 token 是否成功落地 Keychain。失敗要當場擋下並顯示原因——否則後面的
    /// 「連線成功」會蓋掉錯誤,讓使用者以為設定完成,實際上熱鍵永遠拿不到 token。
    @discardableResult
    private func commitFields() -> Bool {
        config.setBaseURL(baseURLText)
        guard config.setToken(tokenText) else {
            statusIsError = true
            statusMessage = "Token 寫入 Keychain 失敗,請重試(必要時重啟 App)"
            return false
        }
        return true
    }

    private func runVerify() {
        guard commitFields() else { return }
        runRequest(successMessage: "連線成功") { service in
            try await service.verifyConnection()
        }
    }

    private func runLoadProjects() {
        guard commitFields() else { return }
        runRequest(successMessage: nil) { service in
            let loaded = try await service.listProjects()
            projects = loaded
            statusMessage = "已載入 \(loaded.count) 個專案"
        }
    }

    private func runRequest(successMessage: String?, _ work: @escaping (VikunjaService) async throws -> Void) {
        isBusy = true
        statusMessage = nil
        statusIsError = false
        let service = VikunjaService(baseURL: baseURLText, token: tokenText)
        Task { @MainActor in
            defer { isBusy = false }
            do {
                try await work(service)
                if let successMessage { statusMessage = successMessage }
            } catch {
                statusIsError = true
                statusMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
