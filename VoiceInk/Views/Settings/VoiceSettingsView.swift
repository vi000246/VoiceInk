import SwiftData
import SwiftUI

/// 語音設定（獨立頁面，比照「錄音設定」）——只放語音／聽寫相關設定，不含任何錄音筆匯入的設定。
/// 內容從原本「語音管理」右上角齒輪的 History Settings 搬過來，去掉錄音相關區塊。
struct VoiceSettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @AppStorage(CleanupSettingsKeys.isTranscriptionCleanupEnabled) private var isTranscriptionCleanupEnabled = false
    @AppStorage(CleanupSettingsKeys.transcriptionRetentionMinutes) private var transcriptionRetentionMinutes = 24 * 60
    @AppStorage(CleanupSettingsKeys.isAudioCleanupEnabled) private var isAudioCleanupEnabled = false
    @AppStorage(CleanupSettingsKeys.audioRetentionPeriod) private var audioRetentionPeriod = 7

    @State private var isPerformingAudioCleanup = false
    @State private var isShowingAudioConfirmation = false
    @State private var cleanupInfo: (fileCount: Int, totalSize: Int64, transcriptions: [Transcription]) = (0, 0, [])
    @State private var showAudioCleanupResult = false
    @State private var audioCleanupResult: (deletedCount: Int, errorCount: Int) = (0, 0)
    @State private var showTranscriptCleanupResult = false

    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "語音設定",
                infoMessage: "語音輸入（聽寫）的相關設定：逐字稿歷史與音檔的自動清理。錄音筆匯入的清理設定在「錄音設定」頁，兩者互不影響。",
                infoURL: nil
            ) { EmptyView() }

            Form {
                Section {
                    Toggle("自動刪除逐字稿歷史", isOn: $isTranscriptionCleanupEnabled)
                    if isTranscriptionCleanupEnabled {
                        Picker("刪除時機", selection: $transcriptionRetentionMinutes) {
                            Text("立即").tag(0)
                            Text("1 小時").tag(60)
                            Text("1 天").tag(24 * 60)
                            Text("3 天").tag(3 * 24 * 60)
                            Text("7 天").tag(7 * 24 * 60)
                        }
                        Button("立即清理") {
                            Task {
                                await TranscriptionAutoCleanupService.shared.runManualCleanup(modelContext: modelContext)
                                await MainActor.run { showTranscriptCleanupResult = true }
                            }
                        }
                    }
                } header: {
                    sectionHeader("逐字稿歷史", tip: "超過保留期限的聽寫逐字稿（含音檔）會被刪除。錄音筆匯入的檔案不受影響——它們有自己的設定（在「錄音設定」）。")
                }

                if !isTranscriptionCleanupEnabled {
                    Section {
                        Toggle("自動刪除音檔", isOn: $isAudioCleanupEnabled)
                        if isAudioCleanupEnabled {
                            Picker("音檔保留", selection: $audioRetentionPeriod) {
                                Text("1 天").tag(1)
                                Text("3 天").tag(3)
                                Text("7 天").tag(7)
                                Text("14 天").tag(14)
                                Text("30 天").tag(30)
                            }
                            Button(isPerformingAudioCleanup ? "分析中…" : "立即清理", action: analyzeAudioCleanup)
                                .disabled(isPerformingAudioCleanup)
                        }
                    } header: {
                        sectionHeader("音檔", tip: "只刪舊音檔、保留逐字稿。")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("逐字稿清理", isPresented: $showTranscriptCleanupResult) {
            Button("OK", role: .cancel) { }
        } message: { Text("清理完成。") }
        .alert("音檔清理", isPresented: $isShowingAudioConfirmation) {
            Button("取消", role: .cancel) { }
            if cleanupInfo.fileCount > 0 {
                Button("刪除 \(cleanupInfo.fileCount) 個檔案", role: .destructive) { runAudioCleanup() }
            }
        } message: {
            if cleanupInfo.fileCount > 0 {
                Text("將刪除 \(cleanupInfo.fileCount) 個音檔（\(AudioCleanupManager.shared.formatFileSize(cleanupInfo.totalSize))）。")
            } else {
                Text("找不到超過 \(audioRetentionPeriod) 天的音檔。")
            }
        }
        .alert("清理完成", isPresented: $showAudioCleanupResult) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(audioCleanupResult.errorCount > 0
                 ? "已刪除 \(audioCleanupResult.deletedCount) 個，失敗 \(audioCleanupResult.errorCount) 個。"
                 : "已刪除 \(audioCleanupResult.deletedCount) 個音檔。")
        }
        .onChange(of: isTranscriptionCleanupEnabled) { _, newValue in
            if newValue {
                isAudioCleanupEnabled = false
                AudioCleanupManager.shared.stopAutomaticCleanup()
            } else if isAudioCleanupEnabled {
                AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext)
            }
        }
        .onChange(of: isAudioCleanupEnabled) { _, newValue in
            guard !isTranscriptionCleanupEnabled else {
                if newValue { isAudioCleanupEnabled = false }
                AudioCleanupManager.shared.stopAutomaticCleanup()
                return
            }
            if newValue { AudioCleanupManager.shared.startAutomaticCleanup(modelContext: modelContext) }
            else { AudioCleanupManager.shared.stopAutomaticCleanup() }
        }
    }

    private func sectionHeader(_ title: LocalizedStringKey, tip: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Text(title)
            InfoTip(message: tip, iconSize: .small, iconColor: .secondary, width: 260)
        }
    }

    private func analyzeAudioCleanup() {
        Task {
            await MainActor.run { isPerformingAudioCleanup = true }
            let info = await AudioCleanupManager.shared.getCleanupInfo(modelContext: modelContext)
            await MainActor.run {
                cleanupInfo = info
                isPerformingAudioCleanup = false
                isShowingAudioConfirmation = true
            }
        }
    }

    private func runAudioCleanup() {
        Task {
            await MainActor.run { isPerformingAudioCleanup = true }
            let result = await AudioCleanupManager.shared.runCleanupForTranscriptions(
                modelContext: modelContext, transcriptions: cleanupInfo.transcriptions)
            await MainActor.run {
                audioCleanupResult = result
                isPerformingAudioCleanup = false
                showAudioCleanupResult = true
            }
        }
    }
}
