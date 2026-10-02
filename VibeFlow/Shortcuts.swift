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
    /// Dictate (VibeFlow 2): hold to record, release to paste; a quick tap toggles
    /// hands-free recording. Default: Option-Minus. Registered here so new installs and the
    /// Settings recorder already know it; nothing listens to it until dictation ships.
    static let record = Self("record", default: .init(.minus, modifiers: [.option]))
}
