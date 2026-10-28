import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "history")

/// One thing VibeFlow did for the user: a text it read aloud, or a follow-up question with
/// Claude's answer.
public struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A read or smart read of a selection or the clipboard.
        case read
        /// A follow-up question and its answer.
        case question
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

    public static let excerptLength = 200

    public init(id: UUID = UUID(), kind: Kind, date: Date, text: String, question: String? = nil, smart: Bool = false,
                sourceBundleID: String? = nil, documentExcerpt: String? = nil) {
        self.id = id
        self.kind = kind
        self.date = date
        self.text = text
        self.question = question
        self.smart = smart
        self.sourceBundleID = sourceBundleID
        self.documentExcerpt = documentExcerpt
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

    /// `fileURL` nil keeps the history in memory only (previews and tests).
    public init(fileURL: URL?, retention: HistoryRetention = .default, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.retention = retention
        self.now = now
        load()
        if prune() { save() }
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

    public func delete(_ id: HistoryEntry.ID) {
        let before = entries.count
        entries.removeAll { $0.id == id }
        if entries.count != before { save() }
    }

    public func clear() {
        entries = []
        save()
    }

    /// Applies the retention limit. Returns whether anything was removed.
    @discardableResult
    private func prune() -> Bool {
        let before = entries.count
        switch retention {
        case .entries(let n):
            if entries.count > n { entries.removeLast(entries.count - n) }
        case .days(let n):
            let cutoff = now().addingTimeInterval(-Double(n) * 86_400)
            entries.removeAll { $0.date < cutoff }
        }
        return entries.count != before
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            entries = try Self.decoder.decode([HistoryEntry].self, from: data).sorted { $0.date > $1.date }
        } catch {
            log.notice("History unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            entries = []
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
