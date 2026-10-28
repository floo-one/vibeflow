import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Read the selection. Default: Option-Period.
    static let read = Self("read", default: .init(.period, modifiers: [.option]))
    /// Smart read the selection. Default: Option-Comma.
    static let smartRead = Self("smartRead", default: .init(.comma, modifiers: [.option]))
    /// Speak the clipboard. Default: Shift-Option-Period.
    static let readClipboard = Self("readClipboard", default: .init(.period, modifiers: [.option, .shift]))
    /// Smart read the clipboard. Default: Shift-Option-Comma.
    static let smartReadClipboard = Self("smartReadClipboard", default: .init(.comma, modifiers: [.option, .shift]))
    /// Dictate, push-to-talk: hold to record, release to transcribe and paste. Default: Option-Minus.
    static let record = Self("record", default: .init(.minus, modifiers: [.option]))
    /// Dictate, toggle: press to start recording hands-free, press again to stop. Default: Shift-Option-Minus.
    static let recordToggle = Self("recordToggle", default: .init(.minus, modifiers: [.option, .shift]))
    /// Paste the last dictation again. Default: Control-Option-V, which types no character, so
    /// typing can never paste by accident.
    static let pasteLastDictation = Self("pasteLastDictation", default: .init(.v, modifiers: [.control, .option]))
    /// Paste the last smart read result. Default: Shift-Control-Option-V. Not "pasteAnswer": an
    /// old build stored that name on Option-Minus, the push-to-talk key.
    static let pasteLastAnswer = Self("pasteLastAnswer", default: .init(.v, modifiers: [.control, .option, .shift]))
}
