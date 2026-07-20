import SwiftUI

/// 設定頁的「晨間簡報」區塊(嵌在 `SettingsView` 的 Form 裡,樣式沿用 `VikunjaSettingsSection`)。
struct MorningBriefingSettingsSection: View {
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @ObservedObject private var config = MorningBriefingConfigStore.shared

    var body: some View {
        Section {
            Toggle("啟用晨間簡報", isOn: Binding(
                get: { config.enabled },
                set: { config.setEnabled($0) }
            ))

            LabeledContent("顯示時間") {
                DatePicker("", selection: timeBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .fixedSize()
            }

            Toggle("AI 建議「今日第一件事」", isOn: Binding(
                get: { config.aiSuggestionEnabled },
                set: { config.setAISuggestionEnabled($0) }
            ))

            LabeledContent("熱鍵") {
                ShortcutRecorder(action: .showMorningBriefing) {
                    recordingShortcutManager.updateShortcutStatus()
                }
                .controlSize(.small)
            }

            HStack {
                Button("立即顯示") {
                    Task { await MorningBriefingService.shared.showManually() }
                }
                Spacer()
            }
        } header: {
            Text("晨間簡報")
        } footer: {
            Text("每天早上把逾期與今天到期的 Vikunja 任務、昨日會後包送到眼前;Mac 睡過設定時間也會在喚醒時補上。")
                .settingsDescription()
        }
    }

    /// 分鐘制設定值 ↔ DatePicker 的 Date(只取時/分;日期部分無意義)。
    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                let startOfDay = calendar.startOfDay(for: Date())
                return calendar.date(byAdding: .minute, value: config.timeMinutes, to: startOfDay)
                    ?? startOfDay
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                config.setTimeMinutes((c.hour ?? 8) * 60 + (c.minute ?? 30))
            })
    }
}
