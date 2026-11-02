import Foundation
import Observation

/// How long a keep-awake session lasts (the Amphetamine replacement).
public enum KeepAwakeDuration: Hashable, Sendable {
    case indefinitely
    case minutes(Int)

    /// The choices in the menu, shortest first after Indefinitely.
    public static let presets: [KeepAwakeDuration] = [
        .indefinitely, .minutes(15), .minutes(30), .minutes(60), .minutes(120), .minutes(180), .minutes(300), .minutes(480),
    ]

    /// "Indefinitely", "15 minutes", "1 hour", "2 hours".
    public var title: String {
        switch self {
        case .indefinitely: return "Indefinitely"
        case .minutes(let minutes) where minutes % 60 == 0:
            let hours = minutes / 60
            return hours == 1 ? "1 hour" : "\(hours) hours"
        case .minutes(let minutes): return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
    }
}

/// An IOPM power assertion behind a protocol so KeepAwake is tested without IOKit.
@MainActor
public protocol PowerAssertion: AnyObject {
    /// Holds the assertion until `end`. `keepsDisplayOn` false lets the display sleep while
    /// the Mac itself stays awake. Returns false when macOS refused it.
    func begin(keepsDisplayOn: Bool) -> Bool
    /// Releases it. Idempotent.
    func end()
}

/// Keeps the Mac awake indefinitely or for a while, with or without the display.
/// The assertion is held for exactly as long as `isActive` is true.
@MainActor
@Observable
public final class KeepAwake {
    /// nil while off, `.distantFuture` for Indefinitely.
    public private(set) var endsAt: Date?
    /// The display stays on too (Amphetamine's default). Changing it re-takes the assertion.
    public var keepsDisplayOn: Bool {
        didSet {
            guard oldValue != keepsDisplayOn, isActive else { return }
            assertion.end()
            if !assertion.begin(keepsDisplayOn: keepsDisplayOn) { stop() }
        }
    }

    private let assertion: any PowerAssertion
    private let now: () -> Date
    @ObservationIgnored private var expiry: Task<Void, Never>?

    public init(assertion: any PowerAssertion, keepsDisplayOn: Bool, now: @escaping () -> Date = Date.init) {
        self.assertion = assertion
        self.keepsDisplayOn = keepsDisplayOn
        self.now = now
    }

    public var isActive: Bool { endsAt != nil }
    public var isIndefinite: Bool { endsAt == .distantFuture }

    /// Starts a session, or replaces the running one. Returns false when macOS refused.
    @discardableResult
    public func start(_ duration: KeepAwakeDuration) -> Bool {
        stop()
        guard assertion.begin(keepsDisplayOn: keepsDisplayOn) else { return false }
        switch duration {
        case .indefinitely:
            endsAt = .distantFuture
        case .minutes(let minutes):
            let deadline = now().addingTimeInterval(TimeInterval(minutes * 60))
            endsAt = deadline
            // The continuous clock keeps counting through a lid close, so a session that ran
            // out while asleep ends right after wake.
            expiry = Task { [weak self] in
                while let self, let endsAt = self.endsAt {
                    let wait = endsAt.timeIntervalSince(self.now())
                    if wait <= 0 { break }
                    try? await Task.sleep(for: .seconds(min(wait, 60)))
                    if Task.isCancelled { return }
                }
                self?.expireIfDue()
            }
        }
        return true
    }

    public func stop() {
        expiry?.cancel()
        expiry = nil
        guard endsAt != nil else { return }
        endsAt = nil
        assertion.end()
    }

    /// Ends a timed session whose time is up.
    public func expireIfDue() {
        guard let endsAt, !isIndefinite, endsAt <= now() else { return }
        stop()
    }
}

public enum KeepAwakeFormat {
    /// Menu bar label: "1:05" (hours and minutes left, rounded up), "" while indefinite or off.
    public static func remaining(until endsAt: Date?, now: Date) -> String {
        guard let endsAt, endsAt != .distantFuture else { return "" }
        let minutes = max(0, Int((endsAt.timeIntervalSince(now) / 60).rounded(.up)))
        return "\(minutes / 60):\(String(format: "%02d", minutes % 60))"
    }

    /// Menu status line: "Awake until 14:30", "Awake indefinitely", "Not keeping awake".
    public static func status(until endsAt: Date?, in zone: TimeZone = .current) -> String {
        guard let endsAt else { return "Not keeping awake" }
        if endsAt == .distantFuture { return "Awake indefinitely" }
        return "Awake until \(ClockFormat.time(endsAt, in: zone))"
    }
}
