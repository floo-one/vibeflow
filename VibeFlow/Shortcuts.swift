import AppKit
import KeyboardShortcuts

/// VibeFlow Dev (the Debug build) adds Control to every default, so it can run next to the
/// installed release without both apps grabbing the same keys.
#if DEBUG
private let defaultModifiers: NSEvent.ModifierFlags = [.option, .control]
#else
private let defaultModifiers: NSEvent.ModifierFlags = [.option]
#endif

extension KeyboardShortcuts.Name {
    /// Read the selection. Default: Option-Period.
    static let read = Self("read", default: .init(.period, modifiers: defaultModifiers))
    /// Smart read the selection. Default: Option-Comma.
    static let smartRead = Self("smartRead", default: .init(.comma, modifiers: defaultModifiers))
    /// Speak the clipboard. Default: Shift-Option-Period.
    static let readClipboard = Self("readClipboard", default: .init(.period, modifiers: defaultModifiers.union(.shift)))
    /// Smart read the clipboard. Default: Shift-Option-Comma.
    static let smartReadClipboard = Self("smartReadClipboard", default: .init(.comma, modifiers: defaultModifiers.union(.shift)))
    /// Dictate, push-to-talk: hold to record, release to transcribe and paste. Default: Option-Minus.
    static let record = Self("record", default: .init(.minus, modifiers: defaultModifiers))
    /// Dictate, toggle: press to start recording hands-free, press again to stop. Default: Shift-Option-Minus.
    static let recordToggle = Self("recordToggle", default: .init(.minus, modifiers: defaultModifiers.union(.shift)))
}
