/// The dictation defaults sit on the key right of "." in the same physical position on every
/// layout (kVK_ANSI_Slash: "-" on German QWERTZ, "/" on US), so read, smart read and dictation
/// are always the three keys right above Option. Hotkeys bind key codes, not characters.
public enum DictationKey {
    /// kVK_ANSI_Slash: the default dictation key.
    public static let ansiSlash = 0x2C
    /// kVK_ANSI_Minus: the old default ("-" on US, "ß" on German), and the key the printed-"-"
    /// default of nightly builds after 1.3.0 picked on a US layout. On German that default was already
    /// ansiSlash.
    public static let ansiMinus = 0x1B

    /// True when a stored dictation shortcut is still an old built-in default (ANSI minus with
    /// the default modifiers). Anything else was recorded by the user, or is already the new
    /// default, and is kept.
    public static func shouldMigrate(storedKeyCode: Int, storedModifiers: Int, defaultModifiers: Int) -> Bool {
        storedKeyCode == ansiMinus && storedModifiers == defaultModifiers
    }
}
