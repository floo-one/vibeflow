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

    /// Characters up to the end of the last finished sentence (0 when none has finished), so a
    /// streamed answer can be passed on a whole sentence at a time.
    public static func completeLength(_ text: String) -> Int {
        var end = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences]) { sentence, range, _, _ in
            let trimmed = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let last = trimmed.last, ".!?…".contains(last) else { return }
            // The sentence range includes trailing spaces; stop at the punctuation.
            var stop = range.upperBound
            while stop > range.lowerBound, text[text.index(before: stop)].isWhitespace { stop = text.index(before: stop) }
            end = stop
        }
        return text.distance(from: text.startIndex, to: end)
    }

    /// The text up to the end of its last finished sentence, for answers cut off at max_tokens.
    /// Empty when not even the first sentence finished.
    public static func complete(_ text: String) -> String {
        var end = text.startIndex
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences]) { sentence, range, _, _ in
            let trimmed = sentence?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let last = trimmed.last, ".!?…".contains(last) { end = range.upperBound }
        }
        return String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text from a character offset to the end, for resume requests.
    public static func suffix(of text: String, from offset: Int) -> String {
        guard offset > 0 else { return text }
        guard offset < text.count else { return "" }
        return String(text.dropFirst(offset))
    }
}
