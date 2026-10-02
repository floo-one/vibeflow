import Foundation

/// The Edit > Copy fallback (design: Capture step 3, decisions D9 and D10).
///
/// - Snapshot and restore: ClipboardSnapshot (plain text only, every read bounded at 200 ms
///   because a lazily provided pasteboard can block until the owning app answers).
/// - Press the source app's Edit > Copy menu item through Accessibility.
/// - Accept the result only if changeCount became exactly N+1 within 300 ms, the source
///   app is still frontmost, and the new string is non-empty after trimming.
/// - Restore the snapshot (transient, so clipboard managers ignore it) only if changeCount
///   is still N+1. Never restore after a timeout, drift or cancellation; never read stale text.
@MainActor
public final class PasteboardCapture {
    public static let snapshotTimeout = ClipboardSnapshot.deadline
    public static let copyTimeout: Duration = .milliseconds(300)
    static let pollInterval: Duration = .milliseconds(20)

    public static let notRestoredNote = ClipboardSnapshot.notRestoredNote
    public static let nonTextNote = ClipboardSnapshot.nonTextNote

    private let accessibility: any AccessibilityBridge
    private let pasteboard: any Pasteboard
    private let clock: any SessionClock

    public init(accessibility: any AccessibilityBridge, pasteboard: any Pasteboard, clock: any SessionClock) {
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.clock = clock
    }

    public func capture(from app: FrontmostApp) async -> CaptureResult {
        let snapshot = await ClipboardSnapshot.take(from: pasteboard, clock: clock)
        let before = pasteboard.changeCount

        do {
            try accessibility.pressCopyMenuItem(in: app)
        } catch {
            return .none
        }

        // Wait for exactly one ownership change.
        let expected = before + 1
        var elapsed: Duration = .zero
        while pasteboard.changeCount < expected {
            if elapsed >= Self.copyTimeout { return .none }
            do { try await clock.sleep(for: Self.pollInterval) } catch { return .none } // cancelled
            elapsed += Self.pollInterval
        }
        // One grace poll: a second write landing right after the Copy shows up as N+2 here.
        // Best-effort limit (D9): a foreign write that lands BEFORE the Copy inside the same
        // window is indistinguishable from the Copy itself; the PID and content checks below
        // are the strongest attribution macOS offers.
        do { try await clock.sleep(for: Self.pollInterval) } catch { return .none }
        guard pasteboard.changeCount == expected else { return .none } // drift: someone else wrote too
        guard accessibility.frontmostApp()?.pid == app.pid else { return .none }

        let copied = await readPasteboardText(pasteboard, clock: clock)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !copied.isEmpty else { return .none }

        let note = await snapshot.restore(to: pasteboard, ifChangeCountIs: expected, clock: clock)
        return CaptureResult(text: copied, note: note)
    }
}
