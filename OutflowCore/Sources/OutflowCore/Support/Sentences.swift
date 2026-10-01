import Foundation

/// Sentence boundaries over character offsets, used to resume with Apple from the start
/// of the sentence that was playing when an ElevenLabs stream dropped.
public enum Sentences {
    /// Character offset where the sentence containing `offset` begins. 0 for empty text or
    /// an offset before the first sentence; the last sentence's start for offsets past the end.
    public static func startOffset(containing offset: Int, in text: String) -> Int {
        guard !text.isEmpty, offset > 0 else { return 0 }
        let clamped = min(offset, text.count - 1)
        var result = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .substringNotRequired]) { _, range, _, stop in
            let start = text.distance(from: text.startIndex, to: range.lowerBound)
            let end = text.distance(from: text.startIndex, to: range.upperBound)
            if clamped >= start && clamped < end {
                result = start
                stop = true
            } else if clamped >= end {
                result = start // keep advancing; the last sentence wins for trailing offsets
            }
        }
        return result
    }

    /// The text from a character offset to the end, for resume requests.
    public static func suffix(of text: String, from offset: Int) -> String {
        guard offset > 0 else { return text }
        guard offset < text.count else { return "" }
        return String(text.dropFirst(offset))
    }
}
