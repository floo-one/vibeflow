import Foundation

/// Where dictated text should go: the app and, when the app exposes one, the exact text field
/// that had focus at key down (D10).
public struct PasteTarget: Sendable, Equatable {
    public var app: FrontmostApp
    public var field: FocusedElement?
    public init(app: FrontmostApp, field: FocusedElement?) {
        self.app = app
        self.field = field
    }
}

public enum InsertionResult: Sendable, Equatable {
    /// Pasted; `note` explains a clipboard that could not be restored.
    case pasted(note: String?)
    /// Not pasted; the text was put on the clipboard so it is not lost.
    case copiedInstead(reason: String)
}

/// Pastes text at the cursor through the clipboard and puts the user's clipboard back
/// (design D2, D6, D10):
///
/// 1. Immediately before pasting, the target must still be valid: Accessibility granted, same frontmost app, same
///    focused field (when one was captured), and no secure input. Otherwise the text goes to
///    the clipboard and nothing is pasted.
/// 2. Snapshot the clipboard text (ClipboardSnapshot, 200 ms bound), write the dictation
///    (transient, so clipboard managers ignore it), press the plain Cmd-V menu item or post a
///    synthesized Cmd-V when the app has none. Text ending in punctuation gets a trailing space.
/// 3. After 750 ms, restore the snapshot only if nobody wrote the clipboard since.
@MainActor
public final class TextInsertion {
    public static let restoreDelay: Duration = .milliseconds(750)

    private let accessibility: any AccessibilityBridge
    private let pasteboard: any Pasteboard
    private let clock: any SessionClock

    public init(accessibility: any AccessibilityBridge, pasteboard: any Pasteboard, clock: any SessionClock) {
        self.accessibility = accessibility
        self.pasteboard = pasteboard
        self.clock = clock
    }

    public func insert(_ text: String, into target: PasteTarget) async -> InsertionResult {
        if let reason = invalidTargetReason(target) {
            await copyToClipboard(text)
            return .copiedInstead(reason: reason)
        }

        let snapshot = await ClipboardSnapshot.take(from: pasteboard, clock: clock)
        let pb = pasteboard
        let pasted = Self.spacedAfterPunctuation(text)
        let wrote: Bool? = await runBlocking(within: ClipboardSnapshot.deadline, clock: clock) {
            pb.setString(pasted, transient: true)
            return true
        }
        guard wrote == true else {
            return .copiedInstead(reason: "the clipboard did not respond")
        }
        let afterOwnWrite = pasteboard.changeCount

        do {
            try accessibility.pressPasteMenuItem(in: target.app)
        } catch {
            accessibility.postPasteKeystroke()
        }

        try? await clock.sleep(for: Self.restoreDelay)
        let note = await snapshot.restore(to: pasteboard, ifChangeCountIs: afterOwnWrite, clock: clock)
        return .pasted(note: note)
    }

    /// Dictation that ends a sentence gets a trailing space so the next dictation or typing
    /// does not run into the dot.
    public static func spacedAfterPunctuation(_ text: String) -> String {
        guard let last = text.last, ".!?…:;,".contains(last) else { return text }
        return text + " "
    }

    /// nil = safe to paste.
    func invalidTargetReason(_ target: PasteTarget) -> String? {
        // Both the menu press and the synthesized Cmd-V need the Accessibility grant.
        guard accessibility.isTrusted else { return "Accessibility access is off" }
        guard accessibility.frontmostApp()?.pid == target.app.pid else { return "the app lost focus" }
        if accessibility.isSecureInputActive { return "a password field has focus" }
        if let field = target.field {
            guard let current = accessibility.focusedElement(), current == field else { return "the text field changed" }
        }
        return nil
    }

    private func copyToClipboard(_ text: String) async {
        let pb = pasteboard
        _ = await runBlocking(within: ClipboardSnapshot.deadline, clock: clock) {
            pb.setString(text, transient: false)
            return true
        }
    }
}
