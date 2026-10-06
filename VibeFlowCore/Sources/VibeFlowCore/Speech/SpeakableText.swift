import Foundation

/// Rewrites selected text for listening before it reaches a voice. Copied text is often
/// Markdown or a spreadsheet: read verbatim, a voice says every pipe, dash, bracket and URL.
///
/// - Tables (Markdown pipes or tab-separated rows) become one sentence per row of
///   "Header: value" pairs.
/// - Links keep their text; bare URLs become their domain.
/// - Emphasis, inline code, headings, bullets, quotes, rules and code fences lose their marks;
///   headings and list items end with a pause.
///
/// Plain prose passes through unchanged.
public enum SpeakableText {
    public static func make(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        lines = rewriteTables(lines)
        lines = lines.compactMap(rewriteLine)
        var out = lines.joined(separator: "\n")
        out = rewriteInline(out)
        out = out.replacing(#"[ \t]{2,}"#, with: " ")
        out = out.replacing(#"\n{3,}"#, with: "\n\n")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Tables

    private static func rewriteTables(_ lines: [String]) -> [String] {
        var out: [String] = []
        var i = 0
        while i < lines.count {
            if let (rows, next) = tableBlock(lines, from: i) {
                out.append(contentsOf: speak(rows))
                i = next
            } else {
                out.append(lines[i])
                i += 1
            }
        }
        return out
    }

    /// A table starting at `start`: two or more pipe rows, or two or more tab rows with the
    /// same cell count. Returns the parsed rows (header first when there is one) and the next line.
    private static func tableBlock(_ lines: [String], from start: Int) -> (rows: Table, next: Int)? {
        var end = start
        while end < lines.count, isPipeRow(lines[end]) { end += 1 }
        if end - start >= 2 {
            var cells = lines[start..<end].map(pipeCells)
            var hasHeader = false
            if cells.count > 1, cells[1].allSatisfy(isSeparatorCell) {
                cells.remove(at: 1)
                hasHeader = true
            }
            cells.removeAll { row in row.allSatisfy(isSeparatorCell) }
            return (Table(rows: cells, hasHeader: hasHeader), end)
        }

        let width = tabCells(lines[start]).count
        guard width >= 2 else { return nil }
        end = start
        while end < lines.count, tabCells(lines[end]).count == width { end += 1 }
        guard end - start >= 2 else { return nil }
        return (Table(rows: lines[start..<end].map(tabCells), hasHeader: true), end)
    }

    private struct Table {
        var rows: [[String]]
        var hasHeader: Bool
    }

    private static func isPipeRow(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.dropFirst().contains("|")
    }

    private static func pipeCells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func tabCells(_ line: String) -> [String] {
        guard line.contains("\t") else { return [] }
        return line.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isSeparatorCell(_ cell: String) -> Bool {
        !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" } && cell.contains("-")
    }

    /// One sentence per data row: "Campaign: X, Ad set: Y." Empty cells are skipped.
    private static func speak(_ table: Table) -> [String] {
        guard table.hasHeader, let header = table.rows.first else {
            return table.rows.map { sentence($0.filter { !$0.isEmpty }.joined(separator: ", ")) }.filter { !$0.isEmpty }
        }
        return table.rows.dropFirst().compactMap { row in
            let pairs = row.enumerated().compactMap { index, value -> String? in
                guard !value.isEmpty else { return nil }
                let name = index < header.count ? header[index] : ""
                return name.isEmpty ? value : "\(name): \(value)"
            }
            return pairs.isEmpty ? nil : sentence(pairs.joined(separator: ", "))
        }
    }

    // MARK: Lines

    /// nil drops the line (fences, rules).
    private static func rewriteLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return nil }
        if trimmed.matches(#"^([-*_])( ?\1){2,}$"#) { return nil }

        var t = trimmed
        var pause = false
        if let stripped = t.removingPrefix(#"^#{1,6}\s+"#) { t = stripped; pause = true }
        while let stripped = t.removingPrefix(#"^>\s?"#) { t = stripped }
        if let stripped = t.removingPrefix(#"^[-*+•]\s+(\[[ xX]\]\s+)?"#) { t = stripped; pause = true }
        if let stripped = t.removingPrefix(#"^\d{1,3}[.)]\s+"#) { t = stripped; pause = true }
        if t == trimmed { return line }
        return pause ? sentence(t) : t
    }

    /// Ends with punctuation so the voice pauses before the next line.
    private static func sentence(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return t }
        return ".!?:;,".contains(last) ? t : t + "."
    }

    // MARK: Inline

    private static func rewriteInline(_ text: String) -> String {
        var t = protectEscapes(text)
        t = t.replacing(#"!\[([^\]]*)\]\([^)]*\)"#, with: "$1")                        // images: alt text
        t = t.replacing(#"\[([^\]]+)\]\(\s*<?[^)\s>]+>?(?:\s+"[^"]*")?\s*\)"#, with: "$1") // [text](url)
        t = t.replacing(#"\[([^\]]+)\]\[[^\]]*\]"#, with: "$1")                        // [text][ref]
        t = replaceURLs(t)
        t = t.replacing(#"`{1,3}([^`\n]+)`{1,3}"#, with: "$1")
        t = t.replacing(#"\*\*(?=\S)(.+?)(?<=\S)\*\*"#, with: "$1")
        t = t.replacing(#"__(?=\S)(.+?)(?<=\S)__"#, with: "$1")
        t = t.replacing(#"~~(?=\S)(.+?)(?<=\S)~~"#, with: "$1")
        t = t.replacing(#"(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])"#, with: "$1")
        t = t.replacing(#"(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])"#, with: "$1")
        t = t.replacing(#"</?[a-zA-Z][a-zA-Z0-9]*(\s[^<>]*)?/?>"#, with: "")             // HTML tags
        t = t.replacing(#"\s+(->|→|=>)\s+"#, with: " to ")
        t = t.replacing(#"\s+&\s+"#, with: " and ")
        t = t.replacing(#"\s+/\s+"#, with: " or ")
        t = t.replacing(#"\s+\|\s+"#, with: ", ")
        for (entity, char) in ["&amp;": "&", "&nbsp;": " ", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'"] {
            t = t.replacingOccurrences(of: entity, with: char)
        }
        return restoreEscapes(t)
    }

    /// Markdown escapes (\*, \_, \[ ...) mean the literal character. They are swapped for
    /// private-use characters so the emphasis and link rules skip them, then restored.
    private static let escapable = Set("\\`*_{}[]()#+-.!|>")
    private static let privateBase: UInt32 = 0xE000

    private static func protectEscapes(_ text: String) -> String {
        var out = ""
        var iterator = text.makeIterator()
        while let c = iterator.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let next = iterator.next() else { out.append(c); break }
            if escapable.contains(next), let ascii = next.asciiValue, let hidden = Unicode.Scalar(privateBase + UInt32(ascii)) {
                out.unicodeScalars.append(hidden)
            } else {
                out.append(c)
                out.append(next)
            }
        }
        return out
    }

    private static func restoreEscapes(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            let v = scalar.value
            guard v >= privateBase, v < privateBase + 128, let ascii = Unicode.Scalar(v - privateBase) else { return scalar }
            return ascii
        }))
    }

    /// A bare or angle-bracketed URL reads as its domain: "github.com".
    private static func replaceURLs(_ text: String) -> String {
        var result = text.replacing(#"<(https?://[^\s>]+)>"#, with: "$1")
        guard let regex = try? NSRegularExpression(pattern: #"\bhttps?://[^\s<>()\[\]]+"#) else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var url = String(result[range])
            var trailing = ""
            while let last = url.last, ".,;:!?'\"".contains(last) { trailing = String(url.removeLast()) + trailing }
            var host = URL(string: url)?.host ?? url
            if host.hasPrefix("www.") { host.removeFirst(4) }
            result.replaceSubrange(range, with: host + trailing)
        }
        return result
    }
}

private extension String {
    func replacing(_ pattern: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }

    func matches(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }

    /// The string without a leading match of `pattern` (anchored with ^), or nil if none.
    func removingPrefix(_ pattern: String) -> String? {
        guard let r = range(of: pattern, options: .regularExpression), r.lowerBound == startIndex else { return nil }
        return String(self[r.upperBound...])
    }
}
