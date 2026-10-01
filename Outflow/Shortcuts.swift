import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Read the selection. Default: Control-Option-R.
    static let read = Self("read", default: .init(.r, modifiers: [.control, .option]))
    /// Smart read the selection. Default: Control-Option-S.
    static let smartRead = Self("smartRead", default: .init(.s, modifiers: [.control, .option]))
}
