import Foundation

/// Cheap token-count heuristic (chars/4) used to gate long-transcript summarization.
/// Not a real tokenizer — intentionally conservative and dependency-free.
enum TokenEstimator {
    static func estimate(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
