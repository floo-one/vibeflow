import Foundation

/// The user's clipboard text, taken before VibeFlow writes the pasteboard and put back
/// afterwards. Shared by the Copy fallback (PasteboardCapture) and dictation paste
/// (TextInsertion), design D2 and v1 D10:
///
/// - Plain text only. Non-text content (images, files, rich text) is not restored and the
///   caller shows `nonTextNote`.
/// - Every pasteboard read or write runs through `runBlocking` with a 200 ms deadline,
///   because a lazily provided pasteboard can block until its owner answers.
/// - Restore happens only if changeCount still equals the value right after VibeFlow's own
///   write, and is marked transient so clipboard managers ignore it.
public enum ClipboardSnapshot: Sendable, Equatable {
    case text(String)
    case empty
    case nonText
    case timedOut

    public static let deadline: Duration = .milliseconds(200)
    public static let notRestoredNote = "Clipboard not restored"
    public static let nonTextNote = "Clipboard not restored (non-text content)"

    /// Reads the current clipboard within the deadline.
    public static func take(from pasteboard: any Pasteboard, clock: any SessionClock) async -> ClipboardSnapshot {
        let result: ClipboardSnapshot? = await runBlocking(within: deadline, clock: clock) {
            if pasteboard.isEmpty { return .empty }
            if let text = pasteboard.string() { return .text(text) }
            return .nonText
        }
        return result ?? .timedOut
    }

    /// Puts the snapshot back if nobody else wrote since `expected`. Returns a status note
    /// when the clipboard could not be restored, nil when it was (or nothing was needed).
    public func restore(to pasteboard: any Pasteboard, ifChangeCountIs expected: Int, clock: any SessionClock) async -> String? {
        switch self {
        case .empty:
            return nil
        case .nonText:
            return Self.nonTextNote
        case .timedOut:
            return Self.notRestoredNote
        case .text(let text):
            guard pasteboard.changeCount == expected else { return Self.notRestoredNote }
            let done: Bool? = await runBlocking(within: Self.deadline, clock: clock) {
                pasteboard.setString(text, transient: true)
                return true
            }
            return done == true ? nil : Self.notRestoredNote
        }
    }
}

/// Reads the pasteboard's plain text within the snapshot deadline; nil on timeout or no text.
func readPasteboardText(_ pasteboard: any Pasteboard, clock: any SessionClock) async -> String? {
    let result: String?? = await runBlocking(within: ClipboardSnapshot.deadline, clock: clock) {
        pasteboard.string()
    }
    return result ?? nil
}
