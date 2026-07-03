import Foundation
import OpenCC
import os

/// Simplified → Traditional Chinese conversion (Taiwan standard) via OpenCC.
///
/// Deterministic, character/variant level with Taiwan standard variants but WITHOUT idiom
/// rephrasing (no `.twIdiom`), so the transcript stays faithful to what was said — only the script
/// changes, not the wording. Used to normalize recorder transcripts + speaker segments to 繁中 so
/// display, analysis, and Obsidian export are all consistent.
enum TraditionalChineseConverter {
    private static let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecorderAutomation")

    /// OpenCC's converter init is throwing + loads dictionaries, so build once and reuse. nil if
    /// OpenCC fails to initialize (then conversion is a no-op and the original text is kept).
    private static let converter: OpenCC.ChineseConverter? = {
        // SwiftyOpenCC (SPM) ships no dictionaries, so we vendor its prebuilt `OpenCCDictionary.bundle`
        // (Contents/Resources/Dictionary/*.ocd) into the app and point the loader at it.
        guard let url = Bundle.main.url(forResource: "OpenCCDictionary", withExtension: "bundle"),
              let dictBundle = Bundle(url: url) else {
            logger.error("OpenCC dictionary bundle not found in app resources")
            return nil
        }
        do {
            return try OpenCC.ChineseConverter(bundle: dictBundle, option: [.traditionalize, .TWStandard])
        } catch {
            logger.error("OpenCC init failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }()

    /// Convert Simplified → Traditional (Taiwan). Returns the input unchanged when empty or when
    /// OpenCC is unavailable; idempotent on already-Traditional text.
    static func toTraditional(_ text: String) -> String {
        guard !text.isEmpty, let converter else { return text }
        return converter.convert(text)
    }
}
