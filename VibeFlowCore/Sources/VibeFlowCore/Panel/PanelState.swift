import Foundation

/// What the menu bar panel shows, decided from plain values so every rule is tested here
/// (docs/designs/menu-bar-popover.md, eng review R2). The SwiftUI panel only renders it.
///
/// Rules, in order:
/// - Top slot: anything running (dictation first, then a read) outranks every problem (D3, D4).
///   Otherwise the most important problem shows: Accessibility, Microphone, then the last
///   error of the session the user last used (dictation or read), then the other one (D4).
///   Otherwise "Ready".
/// - "Read anyway" only for a long selection read from the menu; a long selection from a
///   shortcut is confirmed by pressing the shortcut again, so the card only offers Stop (R4.4).
/// - Dictation error actions are disabled while a dictation runs (a paste owns the clipboard,
///   R4.2).
/// - Footer: Send Feedback only with a Sentry DSN; an "Update to x" pill only once Sparkle has
///   an update waiting; a nightly offers Back to Stable; Debug shows its build stamp (D7, R4.8–9).
public struct PanelState: Sendable, Equatable {
    public var top: TopSlot
    public var footer: Footer

    public init(_ input: Input) {
        top = Self.topSlot(input)
        footer = Self.footer(input)
    }

    // MARK: Input

    public enum Build: Sendable, Equatable {
        case release
        case nightly
        case debug
    }

    public struct Input: Sendable, Equatable {
        public var readState: SessionState
        public var readStatus: String
        public var readError: LastError?
        public var dictationState: DictationState
        public var dictationStatus: String
        public var dictationError: DictationError?
        /// The user last used dictation, so its status and error come first (as the old menu).
        public var showsDictation: Bool
        public var accessibilityTrusted: Bool
        public var microphoneDenied: Bool
        public var feedbackEnabled: Bool
        /// The version Sparkle downloaded and holds for install, nil when none waits.
        public var updateWaiting: String?
        public var build: Build
        /// "Maagical 1.5.0" for a release; only the commit ("87d0257") for a nightly or Debug build.
        public var version: String

        public init(readState: SessionState = .idle, readStatus: String = "Ready", readError: LastError? = nil,
                    dictationState: DictationState = .idle, dictationStatus: String = "Ready",
                    dictationError: DictationError? = nil, showsDictation: Bool = false,
                    accessibilityTrusted: Bool = true, microphoneDenied: Bool = false,
                    feedbackEnabled: Bool = true, updateWaiting: String? = nil,
                    build: Build = .release, version: String = "1.5.0") {
            self.readState = readState
            self.readStatus = readStatus
            self.readError = readError
            self.dictationState = dictationState
            self.dictationStatus = dictationStatus
            self.dictationError = dictationError
            self.showsDictation = showsDictation
            self.accessibilityTrusted = accessibilityTrusted
            self.microphoneDenied = microphoneDenied
            self.feedbackEnabled = feedbackEnabled
            self.updateWaiting = updateWaiting
            self.build = build
            self.version = version
        }
    }

    // MARK: Top slot

    public enum Tone: Sendable, Equatable {
        case read, smart, dictation
        /// Missing setup (orange) and a failure (red).
        case setup, failure
    }

    public enum Action: Sendable, Equatable {
        case stop
        case readAnyway
        case grantAccessibility
        case openMicrophoneSettings
        case read(ErrorAction)
        case dictation(DictationAction)
    }

    public struct Card: Sendable, Equatable {
        public var title: String
        public var detail: String
        public var tone: Tone
        /// The main button first; at most two (the old menu's limit, R3-6).
        public var actions: [Action]
        public var actionsEnabled: Bool
        /// Live microphone or speech bars next to the title.
        public var showsMeter: Bool
    }

    public enum TopSlot: Sendable, Equatable {
        case ready
        case activity(Card)
        case problem(Card)

        public var card: Card? {
            switch self {
            case .ready: return nil
            case .activity(let card), .problem(let card): return card
            }
        }
    }

    static func topSlot(_ input: Input) -> TopSlot {
        if let activity = dictationActivity(input) ?? readActivity(input) { return .activity(activity) }
        if !input.accessibilityTrusted {
            return .problem(Card(title: "Allow Accessibility access", detail: "Maagical needs it to read the text you select.",
                                 tone: .setup, actions: [.grantAccessibility], actionsEnabled: true, showsMeter: false))
        }
        if input.microphoneDenied {
            return .problem(Card(title: "Allow Microphone access", detail: "Dictation needs the microphone.",
                                 tone: .setup, actions: [.openMicrophoneSettings], actionsEnabled: true, showsMeter: false))
        }
        let errors = input.showsDictation
            ? [dictationProblem(input), readProblem(input)]
            : [readProblem(input), dictationProblem(input)]
        if let problem = errors.compactMap({ $0 }).first { return .problem(problem) }
        return .ready
    }

    private static func dictationActivity(_ input: Input) -> Card? {
        let title: String
        switch input.dictationState {
        case .idle: return nil
        case .recording: title = "Listening"
        case .transcribing: title = "Transcribing"
        case .cleaning: title = "Cleaning up"
        case .pasting: title = "Pasting"
        }
        return Card(title: title, detail: input.dictationStatus, tone: .dictation,
                    actions: input.dictationState.isCancellable ? [.stop] : [], actionsEnabled: true, showsMeter: true)
    }

    private static func readActivity(_ input: Input) -> Card? {
        switch input.readState {
        case .idle:
            return nil
        case .awaitingConfirm(_, let origin, let characters):
            let actions: [Action] = origin == .menu ? [.readAnyway, .stop] : [.stop]
            return Card(title: "Long selection", detail: "\(characters.formatted()) characters. \(input.readStatus)",
                        tone: .read, actions: actions, actionsEnabled: true, showsMeter: false)
        case .capturing:
            return Card(title: "Reading selection", detail: input.readStatus, tone: .read, actions: [.stop],
                        actionsEnabled: true, showsMeter: false)
        case .transforming:
            return Card(title: "Thinking", detail: input.readStatus, tone: .smart, actions: [.stop],
                        actionsEnabled: true, showsMeter: true)
        case .buffering, .speaking:
            return Card(title: "Speaking", detail: input.readStatus, tone: .read, actions: [.stop],
                        actionsEnabled: true, showsMeter: true)
        }
    }

    private static func readProblem(_ input: Input) -> Card? {
        guard let error = input.readError else { return nil }
        return Card(title: "Read failed", detail: error.message, tone: .failure,
                    actions: Array(error.actions.prefix(2)).map { .read($0) }, actionsEnabled: true, showsMeter: false)
    }

    /// The dictation error card even while an activity hides it (tests R4.2).
    static func dictationProblemForTesting(_ input: Input) -> Card? { dictationProblem(input) }

    private static func dictationProblem(_ input: Input) -> Card? {
        guard let error = input.dictationError else { return nil }
        return Card(title: "Dictation failed", detail: error.message, tone: .failure,
                    actions: Array(error.actions.prefix(2)).map { .dictation($0) },
                    actionsEnabled: !input.dictationState.isBusy, showsMeter: false)
    }

    // MARK: Footer

    public struct Footer: Sendable, Equatable {
        public var showsFeedback: Bool
        /// The plain version text, or "Update to 1.6.0" when `isUpdatePill`.
        public var label: String
        public var isUpdatePill: Bool
        /// Clicking the version opens Check for Updates and Back to Stable.
        public var offersBackToStable: Bool
        /// Debug builds never update, so the version is only text.
        public var checksForUpdates: Bool
    }

    static func footer(_ input: Input) -> Footer {
        let pill = input.build != .debug ? input.updateWaiting : nil
        return Footer(showsFeedback: input.feedbackEnabled,
                      label: pill.map { "Update to \($0)" } ?? input.version,
                      isUpdatePill: pill != nil,
                      offersBackToStable: input.build == .nightly,
                      checksForUpdates: input.build != .debug)
    }
}

// MARK: - Keep Awake tile (D11)

public enum KeepAwakeTile {
    /// "Off", "On" (indefinite) or "1:45 left".
    public static func subtitle(isActive: Bool, endsAt: Date?, now: Date) -> String {
        guard isActive else { return "Off" }
        let left = KeepAwakeFormat.remaining(until: endsAt, now: now)
        return left.isEmpty ? "On" : "\(left) left"
    }

    /// A tile click starts the duration picked last; the first time, Indefinitely.
    public static func duration(lastMinutes: Int?) -> KeepAwakeDuration {
        guard let lastMinutes, lastMinutes > 0 else { return .indefinitely }
        return .minutes(lastMinutes)
    }

    /// What `duration(lastMinutes:)` reads back: 0 for Indefinitely.
    public static func minutes(of duration: KeepAwakeDuration) -> Int {
        switch duration {
        case .indefinitely: return 0
        case .minutes(let minutes): return minutes
        }
    }
}

// MARK: - Hold tip in the notch (D17)

public enum HoldTip {
    public static let limit = 3

    /// The notch shows "Hold it next time to ask a question" on the first three smart read
    /// taps, and never once the user has held the key.
    public static func shows(tapsSoFar: Int, hasHeld: Bool) -> Bool {
        !hasHeld && tapsSoFar < limit
    }
}
