import Foundation

/// Tells a tap of the smart read shortcut from a hold (docs/designs/smart-read-follow-up.md).
///
/// - Released before `holdThreshold`: `onTap`, on release, exactly like smart read today.
/// - Still down at `holdThreshold`: `onHoldStart`, then `onHoldEnd` on release. A hold never
///   taps, and a tap never starts anything at key down, so it never opens the microphone (D5).
@MainActor
public final class PressClassifier {
    public static let holdThreshold: Duration = .milliseconds(300)

    public enum Press: Sendable, Equatable {
        case tap
        case hold
    }

    private let clock: any SessionClock
    private let onTap: @MainActor () -> Void
    private let onHoldStart: @MainActor () -> Void
    private let onHoldEnd: @MainActor () -> Void
    private var timer: Task<Void, Never>?
    private var holding = false
    private var down = false

    /// The last press, for the log line per classification (eng review D9).
    public private(set) var lastPress: Press?

    public init(clock: any SessionClock,
                onTap: @escaping @MainActor () -> Void,
                onHoldStart: @escaping @MainActor () -> Void,
                onHoldEnd: @escaping @MainActor () -> Void) {
        self.clock = clock
        self.onTap = onTap
        self.onHoldStart = onHoldStart
        self.onHoldEnd = onHoldEnd
    }

    public func keyDown() {
        guard !down else { return } // key repeat
        down = true
        holding = false
        timer = Task { [weak self, clock] in
            do { try await clock.sleep(for: Self.holdThreshold) } catch { return }
            guard let self, self.down, !self.holding else { return }
            self.holding = true
            self.lastPress = .hold
            self.onHoldStart()
        }
    }

    public func keyUp() {
        guard down else { return }
        down = false
        timer?.cancel()
        timer = nil
        if holding {
            holding = false
            onHoldEnd()
        } else {
            lastPress = .tap
            onTap()
        }
    }
}
