import Foundation

// MARK: - Presets

/// The only way to customize the focus timer: each preset carries its whole cadence, so a
/// 90-minute block reaches its long break after two blocks, not four.
public enum FocusPreset: String, CaseIterable, Codable, Sendable {
    case classic
    case long
    case deep

    public var title: String {
        switch self {
        case .classic: return "Classic"
        case .long: return "Long"
        case .deep: return "Deep"
        }
    }

    public var focusMinutes: Int {
        switch self {
        case .classic: return 25
        case .long: return 50
        case .deep: return 90
        }
    }

    public var shortBreakMinutes: Int {
        switch self {
        case .classic: return 5
        case .long: return 10
        case .deep: return 20
        }
    }

    public var longBreakMinutes: Int {
        switch self {
        case .classic: return 15
        case .long: return 20
        case .deep: return 30
        }
    }

    /// Completed focus blocks that earn the long break.
    public var blocksBeforeLong: Int {
        switch self {
        case .classic: return 4
        case .long: return 3
        case .deep: return 2
        }
    }

    /// "Classic 25 / 5" for the menu.
    public var summary: String { "\(title) \(focusMinutes) / \(shortBreakMinutes)" }

    public func minutes(for phase: FocusPhase) -> Int {
        switch phase {
        case .focus: return focusMinutes
        case .shortBreak: return shortBreakMinutes
        case .longBreak: return longBreakMinutes
        }
    }
}

public enum FocusPhase: String, Codable, Sendable {
    case focus
    case shortBreak
    case longBreak

    public var isBreak: Bool { self != .focus }
}

// MARK: - Session

/// The running session, persisted in focus.json next to the blocks so the two never disagree.
/// No session means idle.
public struct FocusSession: Codable, Equatable, Sendable {
    public enum Stage: Codable, Equatable, Sendable {
        case running(FocusPhase, deadline: Date)
        case paused(FocusPhase, remaining: TimeInterval)
        /// A phase ended; the timer waits for a click to start this one.
        case awaiting(FocusPhase)
    }

    /// New on every Start from idle.
    public var id: UUID
    public var stage: Stage
    /// The selected preset. A change applies from the next phase.
    public var preset: FocusPreset
    /// Focus blocks completed in this cycle. Never clamped to the preset, so switching presets
    /// back and forth keeps earned progress; reset after the long break, on Stop and switch-off.
    public var completed: Int
    /// Focus blocks started in this session, skipped ones included. Only goes up, so
    /// `<id>-<blockIndex>` names each block once even across several cycles.
    public var blockIndex: Int
    /// When the current focus block first started (not the last resume).
    public var blockStart: Date
    /// The preset the current focus block started with; its length is what the block logs.
    public var blockPreset: FocusPreset

    public var phase: FocusPhase {
        switch stage {
        case .running(let phase, _), .paused(let phase, _), .awaiting(let phase): return phase
        }
    }

    public var blockID: String { "\(id.uuidString)-\(blockIndex)" }

    /// The break a just-finished or skipped focus block leads to.
    var nextBreak: FocusPhase { completed >= preset.blocksBeforeLong ? .longBreak : .shortBreak }

    /// Time left in a running or paused phase; nil while awaiting.
    public func remaining(at now: Date) -> TimeInterval? {
        switch stage {
        case .running(_, let deadline): return max(deadline.timeIntervalSince(now), 0)
        case .paused(_, let remaining): return remaining
        case .awaiting: return nil
        }
    }
}

/// One completed focus block, the unit of the stats.
public struct FocusBlock: Codable, Equatable, Identifiable, Sendable {
    /// `<sessionID>-<blockIndex>`.
    public var id: String
    /// First start of the block, not the last resume.
    public var start: Date
    /// The deadline the timer reached zero at, not when the expiry was processed after wake.
    public var end: Date
    public var preset: FocusPreset
    /// The preset's focus length; pauses are not counted.
    public var minutes: Int

    public init(id: String, start: Date, end: Date, preset: FocusPreset, minutes: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.preset = preset
        self.minutes = minutes
    }
}

// MARK: - Engine

public enum FocusCommand: Equatable, Sendable {
    /// Start focus from idle, or start the awaited phase.
    case start
    case pause
    case resume
    /// End the current phase without logging it.
    case skip
    /// Back to idle; a partial block is not logged.
    case stop
    case selectPreset(FocusPreset)
    /// Only expires a phase whose deadline has passed (ticker, wake, launch).
    case tick
}

/// What a command did.
public struct FocusTransition: Equatable, Sendable {
    public var session: FocusSession?
    /// A focus block that completed with this command.
    public var logged: FocusBlock?
    /// The phase that just ran out, for the chime and the notification.
    public var ended: FocusPhase?
}

/// The focus timer as a pure state machine: no clock, no storage. Every command first expires
/// a phase whose deadline has passed, with the same `now`, then applies to the result, so a
/// Pause clicked just after zero still logs the block.
public enum FocusEngine {
    /// `preset` is the selected preset; it is used when starting from idle.
    public static func apply(_ command: FocusCommand, to session: FocusSession?, preset: FocusPreset,
                             now: Date, newID: () -> UUID = UUID.init) -> FocusTransition {
        var result = expire(session, now: now)
        guard var current = result.session else {
            if command == .start {
                result.session = FocusSession(
                    id: newID(), stage: .running(.focus, deadline: deadline(.focus, preset, now)),
                    preset: preset, completed: 0, blockIndex: 1, blockStart: now, blockPreset: preset
                )
            }
            return result
        }

        switch command {
        case .start:
            guard case .awaiting(let phase) = current.stage else { break }
            if phase == .focus {
                current.blockIndex += 1
                current.blockStart = now
                current.blockPreset = current.preset
            }
            current.stage = .running(phase, deadline: deadline(phase, current.preset, now))
            result.session = current
        case .pause:
            guard case .running(let phase, let end) = current.stage else { break }
            current.stage = .paused(phase, remaining: end.timeIntervalSince(now))
            result.session = current
        case .resume:
            guard case .paused(let phase, let remaining) = current.stage else { break }
            current.stage = .running(phase, deadline: now.addingTimeInterval(remaining))
            result.session = current
        case .skip:
            result.session = skip(current)
        case .stop:
            result.session = nil
        case .selectPreset(let next):
            current.preset = next
            if case .awaiting(let phase) = current.stage, phase.isBreak {
                current.stage = .awaiting(current.nextBreak)
            }
            result.session = current
        case .tick:
            break
        }
        return result
    }

    /// Whether a notification action for `phase` of block `blockIndex` in `sessionID` still
    /// applies. Anything else (already started from the menu, an older block, a stopped
    /// session) is stale and ignored.
    public static func accepts(sessionID: UUID, blockIndex: Int, phase: FocusPhase, session: FocusSession?) -> Bool {
        guard let session, session.id == sessionID, session.blockIndex == blockIndex else { return false }
        return session.stage == .awaiting(phase)
    }

    /// The one command the start/pause shortcut sends: start from idle or a waiting phase,
    /// pause a running one, resume a paused one.
    public static func toggle(_ session: FocusSession?) -> FocusCommand {
        switch session?.stage {
        case nil, .awaiting?: return .start
        case .running?: return .pause
        case .paused?: return .resume
        }
    }

    /// Filled dots for the menu: the completed count up to the preset's cycle length.
    public static func dots(for session: FocusSession?, preset: FocusPreset) -> (filled: Int, total: Int) {
        let total = session?.preset.blocksBeforeLong ?? preset.blocksBeforeLong
        return (min(session?.completed ?? 0, total), total)
    }

    private static func expire(_ session: FocusSession?, now: Date) -> FocusTransition {
        guard var session, case .running(let phase, let end) = session.stage, end <= now else {
            return FocusTransition(session: session)
        }
        var logged: FocusBlock?
        switch phase {
        case .focus:
            logged = FocusBlock(id: session.blockID, start: session.blockStart, end: end,
                                preset: session.blockPreset, minutes: session.blockPreset.focusMinutes)
            session.completed += 1
            session.stage = .awaiting(session.nextBreak)
        case .shortBreak:
            session.stage = .awaiting(.focus)
        case .longBreak:
            session.completed = 0
            session.stage = .awaiting(.focus)
        }
        return FocusTransition(session: session, logged: logged, ended: phase)
    }

    private static func skip(_ session: FocusSession) -> FocusSession {
        var session = session
        switch session.phase {
        case .focus:
            // Only a running or paused block can be skipped; it is neither logged nor counted.
            if case .awaiting = session.stage { return session }
            session.stage = .awaiting(session.nextBreak)
        case .shortBreak:
            session.stage = .awaiting(.focus)
        case .longBreak:
            // Skipping the long break ends the cycle, the same as finishing it.
            session.completed = 0
            session.stage = .awaiting(.focus)
        }
        return session
    }

    private static func deadline(_ phase: FocusPhase, _ preset: FocusPreset, _ now: Date) -> Date {
        now.addingTimeInterval(Double(preset.minutes(for: phase)) * 60)
    }
}

// MARK: - Stats

/// Focus minutes on one local calendar day.
public struct FocusDay: Equatable, Sendable {
    public var date: Date
    public var minutes: Int
}

/// Today's numbers and the 7-day strip. A whole block counts on the local day of its end,
/// which covers blocks crossing midnight and blocks processed the next morning after sleep.
public enum FocusStats {
    public static func today(_ blocks: [FocusBlock], now: Date, calendar: Calendar = .current) -> (blocks: Int, minutes: Int) {
        let todays = blocks.filter { calendar.isDate($0.end, inSameDayAs: now) }
        return (todays.count, todays.reduce(0) { $0 + $1.minutes })
    }

    /// The last seven days, oldest first, today last.
    public static func week(_ blocks: [FocusBlock], now: Date, calendar: Calendar = .current) -> [FocusDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let minutes = blocks.filter { calendar.isDate($0.end, inSameDayAs: day) }.reduce(0) { $0 + $1.minutes }
            return FocusDay(date: day, minutes: minutes)
        }
    }

    /// "4 h 15 min", "75 min".
    public static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// "18:22" for the label and the popup.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
