import Foundation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "focus")

/// Everything the focus timer keeps: the running session and every completed block.
public struct FocusFile: Codable, Equatable, Sendable {
    public var active: FocusSession?
    public var blocks: [FocusBlock]

    public init(active: FocusSession? = nil, blocks: [FocusBlock] = []) {
        self.active = active
        self.blocks = blocks
    }
}

/// focus.json in Application Support, one atomic write per change so the session and the
/// blocks can never disagree. Save first, then commit: a write that fails leaves both the file
/// and the state in memory as they were. Never pruned: the blocks are the stats.
@MainActor
public final class FocusLog {
    public private(set) var file = FocusFile()
    private let fileURL: URL?

    /// `fileURL` nil keeps everything in memory only (previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        load()
    }

    /// ~/Library/Application Support/VibeFlow/<name>; the app passes focus.json, or
    /// focus-dev.json for VibeFlow Dev, which shares the folder.
    public static func defaultFileURL(named name: String) -> URL {
        URL.applicationSupportDirectory.appending(path: "VibeFlow/\(name)")
    }

    /// Writes `next` and adopts it only if the write succeeded.
    @discardableResult
    public func commit(_ next: FocusFile) -> Bool {
        guard next != file else { return true }
        if let fileURL {
            do {
                let folder = fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try Self.encoder.encode(next).write(to: fileURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                log.notice("Focus not saved: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        file = next
        return true
    }

    private func load() {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            var loaded = try Self.decoder.decode(FocusFile.self, from: Data(contentsOf: fileURL))
            // An update briefly runs the old copy next to the new one; a block both wrote counts once.
            var seen = Set<String>()
            loaded.blocks = loaded.blocks.filter { seen.insert($0.id).inserted }
            file = loaded
        } catch {
            // Unlike starting empty and saving over it, this keeps the old history recoverable.
            let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
                .replacingOccurrences(of: ":", with: "-")
            let aside = fileURL.deletingPathExtension().path + ".broken-\(stamp).json"
            try? FileManager.default.moveItem(atPath: fileURL.path, toPath: aside)
            log.notice("Focus file unreadable, moved aside to \(aside, privacy: .public): \(error.localizedDescription, privacy: .public)")
            file = FocusFile()
        }
    }

    // Dates as seconds since 2001 (the default): exact round trips, like HistoryStore.
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
