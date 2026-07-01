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
