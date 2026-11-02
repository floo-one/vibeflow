import Foundation

/// One Send Feedback report (docs/designs/feedback.md). Everything it hands out (message,
/// tags, log file, preview) is already scrubbed, so the app can never send or show an
/// unscrubbed report; the preview is exactly what leaves the Mac (F5).
///
/// Logs ship with feedback, so never log user text: selected or dictated text, smart read
/// answers, vocabulary words, meeting titles. VibeFlow reading its own log gets every value
/// in clear, even ones marked private, so this rule is what keeps reports clean (D4).
public struct FeedbackReport: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case bug
        case idea
        case loveIt = "love-it"

        public var title: String {
            switch self {
            case .bug: return "Bug"
            case .idea: return "Idea"
            case .loveIt: return "Love it"
            }
        }
    }

    /// The build that is running, not the update channel it will move to next (D5).
    public enum Environment: String, Sendable {
        case dev
        case nightly
        case stable

        /// Debug is VibeFlow Dev; release.sh stamps VFGitCommit only on nightlies.
        public static func of(isDebug: Bool, commit: String?) -> Environment {
            if isDebug { return .dev }
            if let commit, !commit.isEmpty { return .nightly }
            return .stable
        }
    }

    /// One line of the settings snapshot, from an explicit allowlist.
    public struct Setting: Equatable, Sendable {
        public let name: String
        public let value: String

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// What the app knows about itself when the form opens.
    public struct Facts: Equatable, Sendable {
        public var version: String
        public var build: String
        public var environment: Environment
        /// The Stable / Nightly setting (update.newestMain), sent as its own tag.
        public var nightlyChannel: Bool
        public var stamp: BuildStamp?
        /// The Settings pane on screen, nil when Settings is closed.
        public var pane: String?
        public var macOS: String
        public var keyboardLayout: String?
        public var accessibilityGranted: Bool
        public var microphoneGranted: Bool
        public var settings: [Setting]

        public init(version: String, build: String, environment: Environment, nightlyChannel: Bool,
                    stamp: BuildStamp? = nil, pane: String? = nil, macOS: String, keyboardLayout: String? = nil,
                    accessibilityGranted: Bool, microphoneGranted: Bool, settings: [Setting] = []) {
            self.version = version
            self.build = build
            self.environment = environment
            self.nightlyChannel = nightlyChannel
            self.stamp = stamp
            self.pane = pane
            self.macOS = macOS
            self.keyboardLayout = keyboardLayout
            self.accessibilityGranted = accessibilityGranted
            self.microphoneGranted = microphoneGranted
            self.settings = settings
        }
    }

    /// The log lines captured when the form opened, oldest first, or why there are none.
    public enum Logs: Equatable, Sendable {
        case lines([String])
        case unavailable(reason: String)
    }

    /// The attached log keeps the newest lines within this many UTF-8 bytes.
    public static let logCap = 200_000
    public static let logFileName = "vibeflow-log.txt"

    public let kind: Kind
    public let environment: Environment
    /// "vibeflow@1.4.0+3.52"
    public let release: String
    /// "[Bug] smart read stops after…"
    public let message: String
    public let tags: [String: String]
    /// The attachment's contents, nil when the logs could not be read.
    public let logFile: String?

    private let summary: String
    private let logsNote: String

    public init(kind: Kind, note: String, facts: Facts, logs: Logs, home: String = NSHomeDirectory()) {
        let scrub = { Self.scrub($0, home: home) }
        self.kind = kind
        environment = facts.environment
        release = Self.release(version: facts.version, build: facts.build)
        message = scrub("[\(kind.title)] \(note.trimmingCharacters(in: .whitespacesAndNewlines))")

        var tags = [
            "kind": kind.rawValue,
            "channel": facts.nightlyChannel ? "nightly" : "stable",
            "macos": facts.macOS,
            "accessibility": facts.accessibilityGranted ? "granted" : "missing",
            "microphone": facts.microphoneGranted ? "granted" : "missing",
        ]
        tags["pane"] = facts.pane
        tags["layout"] = facts.keyboardLayout
        self.tags = tags.mapValues(scrub)

        var lines = ["VibeFlow \(facts.version) (\(facts.build)), \(facts.environment.rawValue)"]
        if let stamp = facts.stamp {
            lines.append("Built from \(stamp.branch) @ \(stamp.commit), \(stamp.built.formatted(.iso8601))")
        }
        lines.append("Update channel: \(self.tags["channel"]!)")
        lines.append("macOS \(facts.macOS)" + (facts.keyboardLayout.map { ", keyboard \($0)" } ?? ""))
        lines.append("Settings pane: \(facts.pane ?? "closed")")
        lines.append("Accessibility \(self.tags["accessibility"]!), microphone \(self.tags["microphone"]!)")
        if !facts.settings.isEmpty {
            lines.append("")
            lines.append("Settings")
            lines += facts.settings.map { "  \($0.name): \($0.value)" }
        }
        summary = scrub(lines.joined(separator: "\n"))

        switch logs {
        case .lines(let raw):
            let (kept, dropped) = Self.cap(raw.map(scrub), bytes: Self.logCap)
            var file = kept.joined(separator: "\n")
            if dropped > 0 { file = "… \(dropped) older lines dropped\n" + file }
            logFile = file
            logsNote = "Logs (last 10 minutes, \(kept.count) lines, attached as \(Self.logFileName))"
        case .unavailable(let reason):
            logFile = nil
            logsNote = scrub("Logs unavailable: \(reason)")
        }
    }

    /// Sentry's release name, shared by feedback and crash events.
    public static func release(version: String, build: String) -> String {
        "vibeflow@\(version)+\(build)"
    }

    /// The feedback text Sentry receives: note, build facts, settings and a line about the
    /// logs. The logs themselves go as the attachment.
    public var text: String {
        message + "\n\n" + summary + "\n\n" + logsNote
    }

    /// The exact text the form shows under "What gets sent": `text` plus the attachment.
    public func render() -> String {
        guard let logFile, !logFile.isEmpty else { return text }
        return text + "\n" + logFile
    }

    // MARK: Scrubbing

    /// Built per call: Regex is not Sendable, so it cannot be a stored static.
    private static var secretPatterns: [Regex<Substring>] { [
        /sk-[A-Za-z0-9_\-]{16,}/,           // OpenAI, Anthropic (sk-ant-…)
        /gsk_[A-Za-z0-9]{16,}/,             // Groq
        /sk_[A-Za-z0-9]{16,}/,              // ElevenLabs
        /ya29\.[A-Za-z0-9._\-]+/,           // Google access token
        /1\/\/[A-Za-z0-9._\-]{16,}/,        // Google refresh token
        /[A-Za-z0-9+_=\-]{40,}/,            // any other long key-like run (no "/" so paths survive)
    ] }
    public static let redacted = "‹redacted›"

    /// Replaces anything shaped like a key or token and the home folder path. Also runs as
    /// the crash reporter's beforeSend, so crash events follow the same rules.
    public static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        var text = text
        for pattern in secretPatterns {
            text.replace(pattern, with: redacted)
        }
        if home.count > 1 {
            text.replace(home, with: "~")
        }
        return text
    }

    /// The newest lines that fit in `bytes`, and how many older ones did not.
    static func cap(_ lines: [String], bytes: Int) -> (kept: [String], dropped: Int) {
        var total = 0
        var start = lines.endIndex
        while start > lines.startIndex {
            let size = lines[start - 1].utf8.count + 1
            if total + size > bytes { break }
            total += size
            start -= 1
        }
        return (Array(lines[start...]), start - lines.startIndex)
    }
}

extension FeedbackReport {
    /// The settings a report carries: an allowlist, never the vocabulary words or calendar
    /// ids themselves (both are personal), only how many there are.
    @MainActor
    public static func settings(from preferences: Preferences) -> [Setting] {
        func on(_ flag: Bool) -> String { flag ? "on" : "off" }
        return [
            Setting("voice model", preferences.voiceModel),
            Setting("smart read model", preferences.smartReadModel),
            Setting("smart read speed", String(format: "%.2f", preferences.smartReadSpeed)),
            Setting("transcription model", preferences.transcriptionModel),
            Setting("cleanup model", preferences.cleanupModel),
            Setting("vocabulary", "\(preferences.vocabularyTerms.count) terms"),
            Setting("history", preferences.historyRetention.storageValue),
            Setting("dictation sounds", on(preferences.dictationSounds)),
            Setting("notch indicator", on(preferences.notchIndicator)),
            Setting("listening style", preferences.listeningStyle.rawValue),
            Setting("color mode", preferences.colorMode.rawValue),
            Setting("world clocks", preferences.worldClocks.map(\.zoneID).joined(separator: ", ")),
            Setting("meetings", on(preferences.meetingsEnabled)),
            Setting("meetings lead", "\(preferences.meetingsLeadMinutes) min"),
            Setting("meeting calendars", preferences.meetingsCalendars.map { "\($0.count)" } ?? "own calendar"),
            Setting("launch at login", on(preferences.launchAtLogin)),
        ]
    }
}
