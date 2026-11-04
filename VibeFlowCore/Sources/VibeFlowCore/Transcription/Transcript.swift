import Foundation

/// One transcribed file: a document read and written whole (file transcription D8).
///
/// Speakers have stable ids ("S1", "S2"...) and names; segments point at a speaker id, never a
/// name, and the summary refers to speakers by token ("{S1}"), so renaming or merging speakers
/// never rewrites text (outside voice 6).
public struct Transcript: Codable, Identifiable, Sendable, Equatable {
    public enum Engine: String, Codable, Sendable {
        case scribe, groq, apple

        public var displayName: String {
            switch self {
            case .scribe: "ElevenLabs Scribe"
            case .groq: "Groq Whisper"
            case .apple: "On-device"
            }
        }
    }

    /// Whether everything was transcribed (outside voice 3); shown in the window, the
    /// notification, Copy and Save.
    public enum Completion: Codable, Sendable, Equatable {
        case complete
        case stopped(at: Double, reason: String)
        case cancelled(at: Double)

        /// "Stopped at 30:00: Groq hourly limit", nil when complete.
        public var note: String? {
            switch self {
            case .complete: nil
            case .stopped(let at, let reason): "Stopped at \(Transcript.clock(at)): \(reason)"
            case .cancelled(let at): "Cancelled at \(Transcript.clock(at))"
            }
        }
    }

    public struct Speaker: Codable, Sendable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public struct Segment: Codable, Sendable, Equatable, Identifiable {
        public var id: Int
        public var speakerID: String?
        public var start: Double
        public var end: Double
        public var text: String
        public init(id: Int, speakerID: String?, start: Double, end: Double, text: String) {
            self.id = id
            self.speakerID = speakerID
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public struct ActionItem: Codable, Sendable, Equatable {
        public var ownerID: String?
        public var text: String
        public var segmentID: Int?
        public init(ownerID: String?, text: String, segmentID: Int?) {
            self.ownerID = ownerID
            self.text = text
            self.segmentID = segmentID
        }
    }

    /// Claude's summary (D7). `text` uses speaker tokens ("{S1} wants the shop live...").
    public struct Summary: Codable, Sendable, Equatable {
        public var text: String
        public var actionItems: [ActionItem]
        public init(text: String, actionItems: [ActionItem]) {
            self.text = text
            self.actionItems = actionItems
        }
    }

    /// A run of segments shown as one block: one speaker, no long pause.
    public struct Turn: Sendable, Equatable, Identifiable {
        public var speakerID: String?
        public var start: Double
        public var end: Double
        public var text: String
        public var segmentIDs: [Int]
        public var id: Int { segmentIDs.first ?? 0 }
    }

    public var id: UUID
    public var date: Date
    public var sourceFileName: String
    /// Bookmark to the source file for playback (D9, O3); the audio is never copied.
    public var sourceBookmark: Data?
    public var duration: Double
    public var engine: Engine
    public var language: String?
    public var completion: Completion
    public var speakers: [Speaker]
    public var segments: [Segment]
    public var summary: Summary?

    public init(id: UUID = UUID(), date: Date, sourceFileName: String, sourceBookmark: Data? = nil, duration: Double,
                engine: Engine, language: String? = nil, completion: Completion = .complete,
                speakers: [Speaker], segments: [Segment], summary: Summary? = nil) {
        self.id = id
        self.date = date
        self.sourceFileName = sourceFileName
        self.sourceBookmark = sourceBookmark
        self.duration = duration
        self.engine = engine
        self.language = language
        self.completion = completion
        self.speakers = speakers
        self.segments = segments
        self.summary = summary
    }

    // MARK: Building from engine output

    /// Turns engine segments into a transcript. Engine speaker ids become "S1", "S2"... in order
    /// of first appearance, named "Speaker 1"...; multichannel ids become "Me" and "Other" (D7).
    public static func make(from engineSegments: [SpeakerSegment], date: Date, sourceFileName: String,
                            sourceBookmark: Data? = nil, duration: Double, engine: Engine, language: String? = nil,
                            completion: Completion = .complete) -> Transcript {
        var mapping: [String: String] = [:]
        var speakers: [Speaker] = []
        func speakerID(for raw: String?) -> String? {
            guard let raw else { return nil }
            if let existing = mapping[raw] { return existing }
            let id: String
            let name: String
            switch raw {
            case "channel_0": (id, name) = ("ME", "Me")
            case "channel_1": (id, name) = ("OTHER", "Other")
            default:
                id = "S\(speakers.count + 1)"
                name = "Speaker \(speakers.count + 1)"
            }
            mapping[raw] = id
            speakers.append(Speaker(id: id, name: name))
            return id
        }
        let ordered = engineSegments.sorted { $0.start < $1.start }
        let segments = ordered.enumerated().map { index, s in
            Segment(id: index, speakerID: speakerID(for: s.speaker), start: s.start, end: s.end, text: s.text)
        }
        return Transcript(date: date, sourceFileName: sourceFileName, sourceBookmark: sourceBookmark, duration: duration,
                          engine: engine, language: language, completion: completion, speakers: speakers, segments: segments)
    }

    // MARK: Turns

    /// A pause this long starts a new turn even for the same speaker.
    public static let turnPause: Double = 1.5
    /// Without speakers (memos), a turn is a paragraph of about this length at most.
    public static let paragraphLength: Double = 45

    public var turns: [Turn] {
        var turns: [Turn] = []
        for segment in segments {
            if var last = turns.last,
               last.speakerID == segment.speakerID,
               segment.start - last.end < Self.turnPause,
               segment.speakerID != nil || segment.end - last.start <= Self.paragraphLength {
                last.text += " " + segment.text
                last.end = max(last.end, segment.end)
                last.segmentIDs.append(segment.id)
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(speakerID: segment.speakerID, start: segment.start, end: segment.end,
                                  text: segment.text, segmentIDs: [segment.id]))
            }
        }
        return turns
    }

    // MARK: Speakers

    public func name(of speakerID: String?) -> String? {
        guard let speakerID else { return nil }
        return speakers.first { $0.id == speakerID }?.name
    }

    /// Talk time per speaker, 0 ... 1, in speaker order.
    public var talkShare: [(speaker: Speaker, share: Double)] {
        var time: [String: Double] = [:]
        for s in segments { if let id = s.speakerID { time[id, default: 0] += max(0, s.end - s.start) } }
        let total = time.values.reduce(0, +)
        return speakers.map { ($0, total > 0 ? (time[$0.id] ?? 0) / total : 0) }
    }

    /// Renames one speaker; every turn and the summary follow because they hold ids.
    public mutating func rename(_ speakerID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = speakers.firstIndex(where: { $0.id == speakerID }) else { return }
        speakers[index].name = trimmed
    }

    /// Folds `speakerID` into `target` (one voice split in two): segments, action items and
    /// summary tokens move over, and `speakerID` disappears.
    public mutating func merge(_ speakerID: String, into target: String) {
        guard speakerID != target,
              speakers.contains(where: { $0.id == speakerID }),
              speakers.contains(where: { $0.id == target }) else { return }
        for i in segments.indices where segments[i].speakerID == speakerID { segments[i].speakerID = target }
        speakers.removeAll { $0.id == speakerID }
        if var summary {
            summary.text = summary.text.replacingOccurrences(of: Self.token(speakerID), with: Self.token(target))
            for i in summary.actionItems.indices where summary.actionItems[i].ownerID == speakerID {
                summary.actionItems[i].ownerID = target
            }
            self.summary = summary
        }
    }

    // MARK: Summary

    public static func token(_ speakerID: String) -> String { "{\(speakerID)}" }

    /// Keeps only what refers to this transcript: unknown speaker tokens become "someone",
    /// unknown owners and segment ids are dropped (outside voice 6).
    public func validated(_ summary: Summary) -> Summary {
        let known = Set(speakers.map(\.id))
        let segmentIDs = Set(segments.map(\.id))
        let text = Self.replacingTokens(in: summary.text) { known.contains($0) ? Self.token($0) : "someone" }
        let items = summary.actionItems.compactMap { item -> ActionItem? in
            let itemText = Self.replacingTokens(in: item.text) { known.contains($0) ? Self.token($0) : "someone" }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !itemText.isEmpty else { return nil }
            return ActionItem(ownerID: item.ownerID.flatMap { known.contains($0) ? $0 : nil }, text: itemText,
                              segmentID: item.segmentID.flatMap { segmentIDs.contains($0) ? $0 : nil })
        }
        return Summary(text: text, actionItems: items)
    }

    /// Text with speaker tokens replaced by the current names.
    public func rendered(_ text: String) -> String {
        Self.replacingTokens(in: text) { name(of: $0) ?? "someone" }
    }

    /// Where an action item was said, for "Florian: send the timeline (12:40)".
    public func start(of segmentID: Int?) -> Double? {
        guard let segmentID else { return nil }
        return segments.first { $0.id == segmentID }?.start
    }

    static func replacingTokens(in text: String, with replacement: (String) -> String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else {
                result += rest[open...]
                return result
            }
            let id = String(rest[afterOpen..<close])
            if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                result += replacement(id)
            } else {
                result += rest[open...close]
            }
            rest = rest[rest.index(after: close)...]
        }
        result += rest
        return result
    }

    // MARK: Export

    /// What Copy and Save as Text produce (D9): a header, the completion note when partial, the
    /// summary when there is one, then "Name [mm:ss]: text" per turn.
    public var plainText: String {
        var lines: [String] = []
        lines.append("\(sourceFileName) · \(Self.clock(duration)) · \(engine.displayName)")
        if let note = completion.note { lines.append(note) }
        lines.append("")
        if let summary {
            lines.append("Summary")
            lines.append(rendered(summary.text))
            if !summary.actionItems.isEmpty {
                lines.append("")
                lines.append("Action items")
                for item in summary.actionItems {
                    var line = "- "
                    if let owner = name(of: item.ownerID) { line += "\(owner): " }
                    line += rendered(item.text)
                    if let at = start(of: item.segmentID) { line += " [\(Self.clock(at))]" }
                    lines.append(line)
                }
            }
            lines.append("")
            lines.append("Transcript")
        }
        for turn in turns {
            if let name = name(of: turn.speakerID) {
                lines.append("\(name) [\(Self.clock(turn.start))]: \(turn.text)")
            } else {
                lines.append("[\(Self.clock(turn.start))] \(turn.text)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// History's 200-character excerpt (D8).
    public var excerpt: String {
        let flat = segments.map(\.text).joined(separator: " ")
        return flat.count > HistoryEntry.excerptLength ? String(flat.prefix(HistoryEntry.excerptLength)) : flat
    }

    /// "12:40", or "1:02:05" from an hour on.
    public static func clock(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.rounded(.down)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }

    // MARK: Source file

    /// A plain bookmark: VibeFlow is not sandboxed, so no security scope (D9).
    public static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The source file if it still exists, following moves; nil means "Source file not found".
    public func resolvedSource() -> URL? {
        guard let sourceBookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: sourceBookmark, options: [.withoutUI], relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// One JSON file per transcript (D8), next to History. Writes are atomic and failures are
/// thrown so the caller can show them (outside voice 4).
public struct TranscriptStore: Sendable {
    public let directory: URL

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "VibeFlow/Transcripts")
    }

    public init(directory: URL = TranscriptStore.defaultDirectory) {
        self.directory = directory
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    public func save(_ transcript: Transcript) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = url(for: transcript.id)
        try Self.encoder.encode(transcript).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load(_ id: UUID) throws -> Transcript {
        try Self.decoder.decode(Transcript.self, from: Data(contentsOf: url(for: id)))
    }

    /// Deleting a missing transcript is not an error.
    public func delete(_ id: UUID) throws {
        let url = url(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Every stored transcript id, for the launch sweep that re-adds History entries (R5).
    public func storedIDs() -> [UUID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name in
            guard name.hasSuffix(".json") else { return nil }
            return UUID(uuidString: String(name.dropLast(5)))
        }
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
