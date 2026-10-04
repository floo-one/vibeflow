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
    /// Dictate: hold to record, release to paste; a quick tap records hands-free until the
    /// next press. Default: Option-Minus.
    static let record = Self("record", default: .init(.minus, modifiers: [.option]))
}
