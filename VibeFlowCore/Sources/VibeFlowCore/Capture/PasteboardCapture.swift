import Foundation

/// The Edit > Copy fallback (design: Capture step 3, decisions D9 and D10).
///
/// - Snapshot: plain text only, read in a detached task with a 200 ms timeout, because a
///   lazily provided pasteboard can block until the owning app answers.
/// - Press the source app's Edit > Copy menu item through Accessibility.
/// - Accept the result only if changeCount became exactly N+1 within 300 ms, the source
///   app is still frontmost, and the new string is non-empty after trimming.
/// - Restore the snapshot (transient, so clipboard managers ignore it) only if changeCount
///   is still N+1. Never restore after a timeout, drift or cancellation; never read stale text.
@MainActor
public final class PasteboardCapture {
    public static let snapshotTimeout: Duration = .milliseconds(200)
    public static let copyTimeout: Duration = .milliseconds(300)
    static let pollInterval: Duration = .milliseconds(20)

    public static let notRestoredNote = "Clipboard not restored"
    public static let nonTextNote = "Clipboard not restored (non-text content)"

    private let accessibility: any AccessibilityBridge
    private let pasteboard: any Pasteboard
    private let clock: any SessionClock

    public init(accessibility: any AccessibilityBridge, pasteboard: any Pasteboard, clock: any SessionClock) {
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.clock = clock
    }

    private enum Snapshot {
        case text(String)
        case empty
        case nonText
        case timedOut
    }

    public func capture(from app: FrontmostApp) async -> CaptureResult {
        let snapshot = await readSnapshot()
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

        let copied = pasteboard.string()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !copied.isEmpty else { return .none }

        let note = await restore(snapshot, ifChangeCountIs: expected)
        return CaptureResult(text: copied, note: note)
    }

    private func readSnapshot() async -> Snapshot {
        let pb = pasteboard
        let result: Snapshot? = try? await withTimeout(Self.snapshotTimeout, clock: clock) {
            await Task.detached { () -> Snapshot in
                if pb.isEmpty { return .empty }
                if let text = pb.string() { return .text(text) }
                return .nonText
            }.value
        }
        return result ?? .timedOut
    }

    /// Returns a status note when the clipboard could not be put back.
    private func restore(_ snapshot: Snapshot, ifChangeCountIs expected: Int) async -> String? {
        switch snapshot {
        case .empty:
            return nil
        case .nonText:
            return Self.nonTextNote
        case .timedOut:
            return Self.notRestoredNote
        case .text(let text):
            guard pasteboard.changeCount == expected else { return Self.notRestoredNote }
            let pb = pasteboard
            let done: Bool? = try? await withTimeout(Self.snapshotTimeout, clock: clock) {
                await Task.detached { pb.setString(text, transient: true); return true }.value
            }
            return done == true ? nil : Self.notRestoredNote
        }
    }
}
