import Foundation
import OSLog

private let log = Logger(subsystem: "one.floo.vibeflow", category: "capture")

/// The Edit > Copy fallback (design: Capture step 3, decisions D9 and D10).
///
/// - Snapshot and restore: ClipboardSnapshot (plain text only, every read bounded at 200 ms
///   because a lazily provided pasteboard can block until the owning app answers).
/// - Press the source app's Edit > Copy menu item through Accessibility.
/// - Accept the result only if changeCount became exactly N+1 within 300 ms, the source
///   app is still frontmost, and the new string is non-empty after trimming. No change within
///   300 ms is "nothing selected": apps that keep Copy enabled with no selection write nothing.
///   Drift, a lost focus or an unreadable clipboard are failures.
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
            log.notice("Copy fallback: pressing Edit > Copy failed (\(String(describing: error), privacy: .public))")
            return .failed
        }

        // Wait for exactly one ownership change.
        let expected = before + 1
        var elapsed: Duration = .zero
        while pasteboard.changeCount < expected {
            if elapsed >= Self.copyTimeout {
                // Chrome and Electron apps keep Edit > Copy enabled with nothing selected and
                // then write nothing, while a real Copy lands in about 50 ms. So an unchanged
                // clipboard means nothing was selected, not that the Copy failed (2026-10-29).
                log.notice("Copy fallback: the clipboard did not change within \(Self.copyTimeout.description, privacy: .public): nothing selected")
                return .none
            }
            do { try await clock.sleep(for: Self.pollInterval) } catch { return .failed } // cancelled
            elapsed += Self.pollInterval
        }
        // One grace poll: a second write landing right after the Copy shows up as N+2 here.
        // Best-effort limit (D9): a foreign write that lands BEFORE the Copy inside the same
        // window is indistinguishable from the Copy itself; the PID and content checks below
        // are the strongest attribution macOS offers.
        do { try await clock.sleep(for: Self.pollInterval) } catch { return .failed }
        guard pasteboard.changeCount == expected else { // drift: someone else wrote too
            log.notice("Copy fallback: the clipboard changed more than once")
            return .failed
        }
        guard accessibility.frontmostApp()?.pid == app.pid else {
            log.notice("Copy fallback: the app lost focus during the Copy")
            return .failed
        }

        guard let raw = await readPasteboardText(pasteboard, clock: clock) else {
            log.notice("Copy fallback: the copied clipboard could not be read as text")
            return .failed
        }
        log.notice("Copy fallback: copied \(raw.count, privacy: .public) characters")
        let copied = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copied.isEmpty else { return .none }

        let note = await snapshot.restore(to: pasteboard, ifChangeCountIs: expected, clock: clock)
        return CaptureResult(text: copied, note: note)
    }
}
