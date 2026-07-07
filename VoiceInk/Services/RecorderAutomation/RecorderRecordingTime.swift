import Foundation

/// Recording time derived from a recorder-device filename. Recorder pens name each file by the
/// moment of capture — e.g. `260701_1258.mp3` = 2026-07-01 12:58 — so the filename, not the
/// import/transcription timestamp, is the true recording time shown in Recording Management.
enum RecorderRecordingTime {
    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyMMdd_HHmm"
        return f
    }()

    private static let titleStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd HHmm"
        return f
    }()

    /// Parse the recording time out of a device filename like `260701_1258.mp3` (also matches a
    /// reprocessed `260701_1258 (2).mp3`). Returns nil when the name carries no `yyMMdd_HHmm` stamp.
    static func parse(fromFileName name: String) -> Date? {
        guard let r = name.range(of: "[0-9]{6}_[0-9]{4}", options: .regularExpression) else { return nil }
        return fileNameFormatter.date(from: String(name[r]))
    }

    /// 解析鏈(iCloud 來源擴充,2026-07-07):
    ///   1. 檔名 `yyMMdd_HHmm`(錄音筆/會議錄製,既有格式) →
    ///   2. 相對路徑的日期資料夾＋時分秒檔名(JPR:`2026-07-06/14-30-22.m4a`) →
    ///   3. 檔案建立日期(Voice Memos 的不透明檔名) →
    ///   4. nil(呼叫端退回匯入時間)。
    static func parse(fileName: String, relativePath: String?, fileCreationDate: Date?) -> Date? {
        if let d = parse(fromFileName: fileName) { return d }
        if let relativePath, let d = parseJPRPath(relativePath) { return d }
        return fileCreationDate
    }

    /// JPR 巢狀路徑:父段 `yyyy-MM-dd` ＋ 檔名段 `HH-mm-ss`(秒可省略 → `HH-mm`)。
    private static func parseJPRPath(_ relativePath: String) -> Date? {
        guard let dateRange = relativePath.range(of: #"(\d{4})-(\d{2})-(\d{2})"#, options: .regularExpression)
        else { return nil }
        let dateString = String(relativePath[dateRange])
        let fileName = (relativePath as NSString).lastPathComponent
        var components = DateComponents()
        let calendar = Calendar.current

        let dateParts = dateString.split(separator: "-").compactMap { Int($0) }
        guard dateParts.count == 3 else { return nil }
        components.year = dateParts[0]; components.month = dateParts[1]; components.day = dateParts[2]

        if let timeRange = fileName.range(of: #"(\d{2})-(\d{2})(-(\d{2}))?"#, options: .regularExpression) {
            let timeParts = String(fileName[timeRange]).split(separator: "-").compactMap { Int($0) }
            if timeParts.count >= 2, timeParts[0] < 24, timeParts[1] < 60 {
                components.hour = timeParts[0]; components.minute = timeParts[1]
                if timeParts.count >= 3, timeParts[2] < 60 { components.second = timeParts[2] }
            }
        }
        return calendar.date(from: components)
    }

    /// `yyyyMMdd HHmm` stamp used as the leading token of an auto-generated recorder display title.
    static func titleStamp(_ date: Date) -> String { titleStampFormatter.string(from: date) }

    /// If `title` is an auto-generated `yyyyMMdd HHmm <summary>` title, return its `<summary>` tail
    /// (possibly empty). Returns nil for user-renamed titles that don't start with that date stamp,
    /// so the caller never rewrites a custom name.
    static func autoTitleSummary(from title: String) -> String? {
        guard let r = title.range(of: "^[0-9]{8} [0-9]{4}", options: .regularExpression) else { return nil }
        return String(title[r.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
}
