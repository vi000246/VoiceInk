import Foundation

/// 晨間簡報的排程判定——純函式核心,Timer/喚醒 glue 在 `MorningBriefingService`。
///
/// 語意約定(兩函式必須一致,否則正好在設定時刻那一秒會漏或重複):
/// - `nextFireDate`:「現在正好等於設定時刻」歸給**明天**(這一發交給 catch-up);
/// - `shouldCatchUp`:「現在 >= 設定時刻」即成立——timer 準點打進來走的就是這條。
enum BriefingScheduler {

    /// `lastShownDayV1` 的格式:"yyyy-MM-dd"(本地時區)。
    /// 不用 DateFormatter——固定格式的日期 key 手組即可,避免 locale 干擾(如佛曆)。
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 下一次自動觸發時刻:今天的設定時刻還沒到就是今天,否則(含正好等於)明天。
    static func nextFireDate(now: Date, configuredMinutes: Int, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: now)
        guard let todayFire = calendar.date(byAdding: .minute, value: configuredMinutes, to: startOfDay) else {
            return now.addingTimeInterval(24 * 3600)
        }
        if todayFire > now { return todayFire }
        let nextDayStart = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay.addingTimeInterval(24 * 3600)
        return calendar.date(byAdding: .minute, value: configuredMinutes, to: nextDayStart)
            ?? nextDayStart.addingTimeInterval(TimeInterval(configuredMinutes * 60))
    }

    /// catch-up 判定(app 啟動/系統喚醒/timer 命中共用):
    /// 今天還沒顯示過,且現在已到/已過設定時刻 → 立即補顯示。
    static func shouldCatchUp(
        now: Date,
        configuredMinutes: Int,
        lastShownDay: String?,
        calendar: Calendar = .current
    ) -> Bool {
        guard lastShownDay != dayKey(for: now, calendar: calendar) else { return false }
        let startOfDay = calendar.startOfDay(for: now)
        guard let todayFire = calendar.date(byAdding: .minute, value: configuredMinutes, to: startOfDay) else {
            return false
        }
        return now >= todayFire
    }
}
