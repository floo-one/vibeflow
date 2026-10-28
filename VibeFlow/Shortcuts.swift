import AppKit
import KeyboardShortcuts

/// VibeFlow Dev (the Debug build) adds Control to every default, and Command to the paste
/// shortcuts that already use Control, so it can run next to the installed release without
/// both apps grabbing the same keys.
#if DEBUG
private let defaultModifiers: NSEvent.ModifierFlags = [.option, .control]
private let pasteModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
#else
private let defaultModifiers: NSEvent.ModifierFlags = [.option]
private let pasteModifiers: NSEvent.ModifierFlags = [.control, .option]
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
    /// Paste the last dictation again. Default: Control-Option-V, which types no character, so
    /// typing can never paste by accident.
    static let pasteLastDictation = Self("pasteLastDictation", default: .init(.v, modifiers: pasteModifiers))
    /// Paste the last smart read result. Default: Shift-Control-Option-V. Not "pasteAnswer": an
    /// old build stored that name on Option-Minus, the push-to-talk key.
    static let pasteLastAnswer = Self("pasteLastAnswer", default: .init(.v, modifiers: pasteModifiers.union(.shift)))
}
