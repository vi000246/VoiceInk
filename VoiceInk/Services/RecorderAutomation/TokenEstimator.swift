import Foundation

/// Cheap token-count heuristic used to gate long-transcript summarization. Not a real tokenizer
/// — intentionally dependency-free — but CJK-aware: Latin text averages ~4 chars/token, whereas
/// Chinese/Japanese/Korean averages closer to ~1 token per character. Counting CJK as chars/4
/// (the old behaviour) under-counted Chinese transcripts ~4×, so a model's context could be
/// blown without ever tripping the threshold. We count CJK scalars ~1:1 and everything else /4.
enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if isCJK(scalar) { cjk += 1 } else { other += 1 }
        }
        return max(1, cjk + other / 4)
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x303F,    // CJK symbols & punctuation
             0x3040...0x30FF,    // Hiragana + Katakana
             0x3400...0x4DBF,    // CJK Unified Ext A
             0x4E00...0x9FFF,    // CJK Unified Ideographs
             0xF900...0xFAFF,    // CJK Compatibility Ideographs
             0xFF00...0xFFEF,    // Fullwidth forms
             0x20000...0x2FA1F:  // CJK Unified Ext B–F + compatibility supplement
            return true
        default:
            return false
        }
    }
}
