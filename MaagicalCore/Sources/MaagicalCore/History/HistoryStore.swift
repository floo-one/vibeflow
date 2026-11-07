import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "history")

/// One thing Maagical did for the user: a text it read aloud, a follow-up question with
/// Claude's answer, or a transcribed file.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A read or smart read of a selection or the clipboard.
        case read
        /// A follow-up question and its answer.
        case question
        /// A transcribed file (file transcription D8); the transcript itself is its own file.
        case transcription
    }

    public var id: UUID
    public var kind: Kind
    public var date: Date
    /// The text that was read, or the answer.
    public var text: String
    /// The question, for `.question` entries.
    public var question: String?
    /// Smart read (brief) rather than a plain read, for `.read` entries.
    public var smart: Bool
    /// The app the text came from; nil for clipboard reads.
    public var sourceBundleID: String?
    /// The start of the text the question was about, for `.question` entries.
    public var documentExcerpt: String?
    /// The transcript file, for `.transcription` entries.
    public var transcriptID: UUID?
    /// "sales-call.m4a", for `.transcription` entries.
    public var sourceFileName: String?

    public static let excerptLength = 200

    public init(id: UUID = UUID(), kind: Kind, date: Date, text: String, question: String? = nil, smart: Bool = false,
                sourceBundleID: String? = nil, documentExcerpt: String? = nil, transcriptID: UUID? = nil,
                sourceFileName: String? = nil) {
        self.id = id
        self.kind = kind
        self.date = date
        self.text = text
        self.question = question
        self.smart = smart
        self.sourceBundleID = sourceBundleID
        self.documentExcerpt = documentExcerpt
        self.transcriptID = transcriptID
        self.sourceFileName = sourceFileName
    }

    /// `text` is the transcript's first 200 characters; the window loads the rest by id.
    public static func transcription(_ transcript: Transcript) -> HistoryEntry {
        HistoryEntry(kind: .transcription, date: transcript.date, text: transcript.excerpt,
                     transcriptID: transcript.id, sourceFileName: transcript.sourceFileName)
    }

    public static func read(_ text: String, smart: Bool, from bundleID: String?, at date: Date) -> HistoryEntry {
        HistoryEntry(kind: .read, date: date, text: text, smart: smart, sourceBundleID: bundleID)
    }

    public static func question(_ question: String, answer: String, about document: String, from bundleID: String?, at date: Date) -> HistoryEntry {
        HistoryEntry(kind: .question, date: date, text: answer, question: question, sourceBundleID: bundleID,
                     documentExcerpt: String(document.prefix(excerptLength)))
    }
}

/// How much history to keep (Settings > General).
public enum HistoryRetention: Hashable, Sendable {
    case days(Int)
    case entries(Int)

    public static let `default` = HistoryRetention.entries(100)
    public static let choices: [HistoryRetention] = [.days(7), .days(30), .days(90), .entries(100), .entries(500)]

    public var title: String {
        switch self {
        case .days(let n): "\(n) days"
        case .entries(let n): "Last \(n) entries"
        }
    }

    /// "days:30" or "entries:100", for UserDefaults.
    public var storageValue: String {
        switch self {
        case .days(let n): "days:\(n)"
        case .entries(let n): "entries:\(n)"
        }
    }

    public init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2, let n = Int(parts[1]), n > 0 else { return nil }
        switch parts[0] {
        case "days": self = .days(n)
        case "entries": self = .entries(n)
        default: return nil
        }
    }
}

/// The history, newest first, in one JSON file on this Mac only (no database: a few hundred
/// entries rewrite in milliseconds). The file is readable by the user's account alone. A file
/// that cannot be read starts an empty history instead of failing the app.
@MainActor
@Observable
public final class HistoryStore {
    public private(set) var entries: [HistoryEntry] = []
    public var retention: HistoryRetention {
        didSet {
            guard retention != oldValue else { return }
            if prune() { save() }
        }
    }

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let now: () -> Date
    /// Where transcription entries keep their transcripts; deleting an entry deletes its file.
    @ObservationIgnored private let transcripts: TranscriptStore?

    /// `fileURL` nil keeps the history in memory only (previews and tests).
    public init(fileURL: URL?, retention: HistoryRetention = .default, transcripts: TranscriptStore? = nil,
                now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.retention = retention
        self.transcripts = transcripts
        self.now = now
        load()
        if prune() { save() }
    }

    public var transcriptCount: Int { entries.filter { $0.kind == .transcription }.count }

    /// Adds a transcript's entry, or refreshes it when the transcript is saved again (summary).
    public func upsertTranscript(_ transcript: Transcript) {
        let entry = HistoryEntry.transcription(transcript)
        if let index = entries.firstIndex(where: { $0.transcriptID == transcript.id }) {
            entries[index].text = entry.text
            entries[index].sourceFileName = entry.sourceFileName
            save()
        } else {
            add(entry)
        }
    }

    /// Launch sweep (eng review R5): a transcript file without an entry (saved, then the app
    /// quit before History was written) gets its entry back.
    public func adoptOrphanTranscripts() {
        guard let transcripts else { return }
        let known = Set(entries.compactMap(\.transcriptID))
        var adopted = false
        for id in transcripts.storedIDs() where !known.contains(id) {
            guard let transcript = try? transcripts.load(id) else { continue }
            entries.append(HistoryEntry.transcription(transcript))
            adopted = true
        }
        if adopted {
            entries.sort { $0.date > $1.date }
            save()
        }
    }

    /// ~/Library/Application Support/VibeFlow/history.json
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "VibeFlow/history.json")
    }

    public func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        entries.sort { $0.date > $1.date }
        prune()
        save()
    }

    /// Deletes an entry; a transcription entry takes its transcript file with it (R5).
    public func delete(_ id: HistoryEntry.ID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        save()
        deleteTranscript(of: entry)
    }

    /// Clears reads and questions. Transcripts stay unless `includingTranscripts`, because they
    /// are documents, not a log (R5); Settings asks first.
    public func clear(includingTranscripts: Bool = false) {
        let removed = includingTranscripts ? entries : entries.filter { $0.kind != .transcription }
        entries = includingTranscripts ? [] : entries.filter { $0.kind == .transcription }
        save()
        removed.forEach(deleteTranscript)
    }

    private func deleteTranscript(of entry: HistoryEntry) {
        guard let id = entry.transcriptID, let transcripts else { return }
        do { try transcripts.delete(id) } catch {
            log.notice("Transcript not deleted: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Applies the retention limit to reads and questions; transcripts are kept until deleted
    /// (eng review R5). Returns whether anything was removed.
    @discardableResult
    private func prune() -> Bool {
        let before = entries.count
        switch retention {
        case .entries(let n):
            var kept = 0
            entries.removeAll { entry in
                guard entry.kind != .transcription else { return false }
                kept += 1
                return kept > n
            }
        case .days(let n):
            let cutoff = now().addingTimeInterval(-Double(n) * 86_400)
            entries.removeAll { $0.kind != .transcription && $0.date < cutoff }
        }
        return entries.count != before
    }

    /// Entries this version cannot decode (a kind from a newer Maagical) are skipped, not the
    /// whole file, so a newer build sharing history.json never empties it here.
    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let lossy = try Self.decoder.decode([Lossy].self, from: data)
            entries = lossy.compactMap(\.entry).sorted { $0.date > $1.date }
            if lossy.count != entries.count {
                log.notice("History: skipped \(lossy.count - self.entries.count, privacy: .public) entries from a newer version")
            }
        } catch {
            log.notice("History unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            entries = []
        }
    }

    private struct Lossy: Decodable {
        let entry: HistoryEntry?
        init(from decoder: Decoder) throws {
            entry = try? HistoryEntry(from: decoder)
        }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Self.encoder.encode(entries).write(to: fileURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            log.notice("History not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Dates as seconds since 2001 (the default): exact round trips, unlike ISO 8601's whole seconds.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
