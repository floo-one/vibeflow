import Foundation

// MARK: - Rhythm

/// The whole cadence of a Pomodoro: focus length, the break, the longer break and how many
/// rounds earn it. The fixed presets each carry one; Custom carries the user's own.
public struct FocusRhythm: Codable, Equatable, Sendable {
    public var focusMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    /// Completed rounds that earn the longer break.
    public var rounds: Int

    public init(focusMinutes: Int, shortBreakMinutes: Int, longBreakMinutes: Int, rounds: Int) {
        self.focusMinutes = focusMinutes
        self.shortBreakMinutes = shortBreakMinutes
        self.longBreakMinutes = longBreakMinutes
        self.rounds = rounds
    }

    public static let classic = FocusRhythm(focusMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, rounds: 4)

    // The Custom steppers' ranges and steps.
    public static let focusRange = 5...180
    public static let focusStep = 5
    public static let shortBreakRange = 1...60
    public static let longBreakRange = 5...60
    public static let longBreakStep = 5
    public static let roundsRange = 1...8

    /// Every value pulled into its stepper's range, for values read from storage.
    public var clamped: FocusRhythm {
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
        return FocusRhythm(focusMinutes: clamp(focusMinutes, Self.focusRange),
                           shortBreakMinutes: clamp(shortBreakMinutes, Self.shortBreakRange),
                           longBreakMinutes: clamp(longBreakMinutes, Self.longBreakRange),
                           rounds: clamp(rounds, Self.roundsRange))
    }

    public func minutes(for phase: FocusPhase) -> Int {
        switch phase {
        case .focus: return focusMinutes
        case .shortBreak: return shortBreakMinutes
        case .longBreak: return longBreakMinutes
        }
    }

    /// "focus, then 5 min break"
    public var breakLine: String { "focus, then \(shortBreakMinutes) min break" }
    /// "Longer 15 min break every 4 rounds"
    public var longBreakLine: String {
        "Longer \(longBreakMinutes) min break every \(rounds == 1 ? "round" : "\(rounds) rounds")"
    }
    /// "25 min focus, 5 min break" for the popup's menu.
    public var summary: String { "\(focusMinutes) min focus, \(shortBreakMinutes) min break" }
}

/// The only way to customize the timer: three fixed rhythms, each with its whole cadence so a
/// 90-minute round reaches its longer break after two rounds, not four, and Custom.
public enum FocusPreset: String, CaseIterable, Codable, Sendable {
    case classic
    case long
    case deep
    case custom

    public var title: String {
        switch self {
        case .classic: return "Classic"
        case .long: return "Long"
        case .deep: return "Deep"
        case .custom: return "Custom"
        }
    }

    /// nil for Custom, whose rhythm lives in Preferences.
    public var fixedRhythm: FocusRhythm? {
        switch self {
        case .classic: return .classic
        case .long: return FocusRhythm(focusMinutes: 50, shortBreakMinutes: 10, longBreakMinutes: 20, rounds: 3)
        case .deep: return FocusRhythm(focusMinutes: 90, shortBreakMinutes: 20, longBreakMinutes: 30, rounds: 2)
        case .custom: return nil
        }
    }

    public func rhythm(custom: FocusRhythm) -> FocusRhythm { fixedRhythm ?? custom }
}

public enum FocusPhase: String, Codable, Sendable {
    case focus
    case shortBreak
    case longBreak

    public var isBreak: Bool { self != .focus }
}

// MARK: - Session

/// The running session, persisted in focus.json next to the rounds so the two never disagree.
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
    /// The selected preset and its rhythm. A change applies from the next phase.
    public var preset: FocusPreset
    public var rhythm: FocusRhythm
    /// Rounds completed in this cycle. Never clamped to the rhythm, so switching presets
    /// back and forth keeps earned progress; reset after the longer break, on Stop and switch-off.
    public var completed: Int
    /// Focus rounds started in this session, skipped ones included. Only goes up, so
    /// `<id>-<blockIndex>` names each round once even across several cycles.
    public var blockIndex: Int
    /// When the current focus round first started (not the last resume).
    public var blockStart: Date
    /// The preset and focus length the current round started with; that is what it logs, even
    /// if the preset or the Custom rhythm changes while it runs.
    public var blockPreset: FocusPreset
    public var blockMinutes: Int

    public init(id: UUID, stage: Stage, preset: FocusPreset, rhythm: FocusRhythm, completed: Int,
                blockIndex: Int, blockStart: Date, blockPreset: FocusPreset, blockMinutes: Int) {
        self.id = id
        self.stage = stage
        self.preset = preset
        self.rhythm = rhythm
        self.completed = completed
        self.blockIndex = blockIndex
        self.blockStart = blockStart
        self.blockPreset = blockPreset
        self.blockMinutes = blockMinutes
    }

    // Sessions saved before Custom had no rhythm or round length; their fixed preset supplies both.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        stage = try c.decode(Stage.self, forKey: .stage)
        preset = try c.decode(FocusPreset.self, forKey: .preset)
        rhythm = try c.decodeIfPresent(FocusRhythm.self, forKey: .rhythm) ?? preset.fixedRhythm ?? .classic
        completed = try c.decode(Int.self, forKey: .completed)
        blockIndex = try c.decode(Int.self, forKey: .blockIndex)
        blockStart = try c.decode(Date.self, forKey: .blockStart)
        blockPreset = try c.decode(FocusPreset.self, forKey: .blockPreset)
        blockMinutes = try c.decodeIfPresent(Int.self, forKey: .blockMinutes)
            ?? (blockPreset.fixedRhythm ?? .classic).focusMinutes
    }

    public var phase: FocusPhase {
        switch stage {
        case .running(let phase, _), .paused(let phase, _), .awaiting(let phase): return phase
        }
    }

    public var blockID: String { "\(id.uuidString)-\(blockIndex)" }

    /// The break a just-finished or skipped focus round leads to.
    var nextBreak: FocusPhase { completed >= rhythm.rounds ? .longBreak : .shortBreak }

    /// Time left in a running or paused phase; nil while awaiting.
    public func remaining(at now: Date) -> TimeInterval? {
        switch stage {
        case .running(_, let deadline): return max(deadline.timeIntervalSince(now), 0)
        case .paused(_, let remaining): return remaining
        case .awaiting: return nil
        }
    }
}

/// One completed focus round, the unit of the stats.
public struct FocusBlock: Codable, Equatable, Identifiable, Sendable {
    /// `<sessionID>-<blockIndex>`.
    public var id: String
    /// First start of the round, not the last resume.
    public var start: Date
    /// The deadline the timer reached zero at, not when the expiry was processed after wake.
    public var end: Date
    public var preset: FocusPreset
    /// The round's focus length; pauses are not counted.
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
    /// Back to idle; a partial round is not logged.
    case stop
    /// A new preset, or new Custom values; applies from the next phase.
    case select(FocusPreset, FocusRhythm)
    /// Only expires a phase whose deadline has passed (ticker, wake, launch).
    case tick
}

/// What a command did.
public struct FocusTransition: Equatable, Sendable {
    public var session: FocusSession?
    /// A focus round that completed with this command.
    public var logged: FocusBlock?
    /// The phase that just ran out, for the chime and the notification.
    public var ended: FocusPhase?
}

/// The Pomodoro timer as a pure state machine: no clock, no storage. Every command first
/// expires a phase whose deadline has passed, with the same `now`, then applies to the result,
/// so a Pause clicked just after zero still logs the round.
public enum FocusEngine {
    /// `preset` and `rhythm` are the current selection; they are used when starting from idle.
    public static func apply(_ command: FocusCommand, to session: FocusSession?, preset: FocusPreset,
                             rhythm: FocusRhythm, now: Date, newID: () -> UUID = UUID.init) -> FocusTransition {
        var result = expire(session, now: now)
        guard var current = result.session else {
            if command == .start {
                result.session = FocusSession(
                    id: newID(), stage: .running(.focus, deadline: deadline(.focus, rhythm, now)),
                    preset: preset, rhythm: rhythm, completed: 0, blockIndex: 1, blockStart: now,
                    blockPreset: preset, blockMinutes: rhythm.focusMinutes
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
                current.blockMinutes = current.rhythm.focusMinutes
            }
            current.stage = .running(phase, deadline: deadline(phase, current.rhythm, now))
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
        case .select(let preset, let rhythm):
            current.preset = preset
            current.rhythm = rhythm
            if case .awaiting(let phase) = current.stage, phase.isBreak {
                current.stage = .awaiting(current.nextBreak)
            }
            result.session = current
        case .tick:
            break
        }
        return result
    }

    /// Whether a notification action for `phase` of round `blockIndex` in `sessionID` still
    /// applies. Anything else (already started from the menu, an older round, a stopped
    /// session) is stale and ignored.
    public static func accepts(sessionID: UUID, blockIndex: Int, phase: FocusPhase, session: FocusSession?) -> Bool {
        guard let session, session.id == sessionID, session.blockIndex == blockIndex else { return false }
        return session.stage == .awaiting(phase)
    }

    /// Filled dots for the menu: the completed count up to the rhythm's rounds.
    public static func dots(for session: FocusSession?, rhythm: FocusRhythm) -> (filled: Int, total: Int) {
        let total = session?.rhythm.rounds ?? rhythm.rounds
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
                                preset: session.blockPreset, minutes: session.blockMinutes)
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
            // Only a running or paused round can be skipped; it is neither logged nor counted.
            if case .awaiting = session.stage { return session }
            session.stage = .awaiting(session.nextBreak)
        case .shortBreak:
            session.stage = .awaiting(.focus)
        case .longBreak:
            // Skipping the longer break ends the cycle, the same as finishing it.
            session.completed = 0
            session.stage = .awaiting(.focus)
        }
        return session
    }

    private static func deadline(_ phase: FocusPhase, _ rhythm: FocusRhythm, _ now: Date) -> Date {
        now.addingTimeInterval(Double(rhythm.minutes(for: phase)) * 60)
    }
}

// MARK: - Stats

/// Focus minutes and rounds on one local calendar day.
public struct FocusDay: Equatable, Sendable {
    public var date: Date
    public var minutes: Int
    /// That day's rounds, newest first (empty in `days`, filled in `history`).
    public var blocks: [FocusBlock] = []

    public init(date: Date, minutes: Int, blocks: [FocusBlock] = []) {
        self.date = date
        self.minutes = minutes
        self.blocks = blocks
    }
}

/// Today's numbers, the charts, the streak and the history. A whole round counts on the local
/// day of its end, which covers rounds crossing midnight and rounds processed the next
/// morning after sleep.
public enum FocusStats {
    public static func today(_ blocks: [FocusBlock], now: Date, calendar: Calendar = .current) -> (blocks: Int, minutes: Int) {
        let todays = blocks.filter { calendar.isDate($0.end, inSameDayAs: now) }
        return (todays.count, todays.reduce(0) { $0 + $1.minutes })
    }

    /// The last seven days, oldest first, today last.
    public static func week(_ blocks: [FocusBlock], now: Date, calendar: Calendar = .current) -> [FocusDay] {
        days(blocks, last: 7, now: now, calendar: calendar)
    }

    /// The last `count` days including empty ones, oldest first, today last.
    public static func days(_ blocks: [FocusBlock], last count: Int, now: Date, calendar: Calendar = .current) -> [FocusDay] {
        let minutes = minutesByDay(blocks, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return FocusDay(date: day, minutes: minutes[day] ?? 0)
        }
    }

    /// Days in a row with at least one round, ending today, or yesterday when today has none
    /// yet, so the streak doesn't break before you've had a chance to start.
    public static func streak(_ blocks: [FocusBlock], now: Date, calendar: Calendar = .current) -> Int {
        let active = Set(blocks.map { calendar.startOfDay(for: $0.end) })
        var day = calendar.startOfDay(for: now)
        if !active.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while active.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    /// Days that have rounds, newest first, each with its rounds newest first.
    public static func history(_ blocks: [FocusBlock], calendar: Calendar = .current) -> [FocusDay] {
        Dictionary(grouping: blocks) { calendar.startOfDay(for: $0.end) }
            .map { day, blocks in
                FocusDay(date: day, minutes: blocks.reduce(0) { $0 + $1.minutes },
                         blocks: blocks.sorted { $0.end > $1.end })
            }
            .sorted { $0.date > $1.date }
    }

    /// "4 h 15 min", "75 min".
    public static func duration(minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// "1 round", "3 rounds".
    public static func rounds(_ count: Int) -> String { count == 1 ? "1 round" : "\(count) rounds" }

    /// "18:22" for the label and the popup.
    public static func countdown(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func minutesByDay(_ blocks: [FocusBlock], calendar: Calendar) -> [Date: Int] {
        blocks.reduce(into: [:]) { $0[calendar.startOfDay(for: $1.end), default: 0] += $1.minutes }
    }
}
